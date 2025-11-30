defmodule GEPA.Engine do
  @moduledoc """
  Main optimization engine for GEPA.

  Orchestrates the optimization loop: propose → evaluate → accept/reject → repeat.
  """

  require Logger
  alias GEPA.Telemetry

  @doc """
  Run optimization until stop condition met.

  ## Parameters

  - `config`: Configuration map with all necessary settings

  ## Returns

  `{:ok, final_state}` on success
  """
  @spec run(map()) :: {:ok, GEPA.State.t()}
  def run(config) do
    run_start_ms = System.monotonic_time(:millisecond)
    Telemetry.emit_run_start(config)

    # Start progress display if enabled
    progress = maybe_start_progress(config)

    # Initialize or load state
    state = initialize_state(config)

    # Run optimization loop
    final_state = optimization_loop(state, config, progress)

    # Save final state if run_dir configured
    if config[:run_dir] do
      save_state(final_state, config.run_dir)
    end

    Telemetry.emit_run_stop(final_state, run_start_ms)

    # Finish progress display
    maybe_finish_progress(progress, final_state)

    {:ok, final_state}
  end

  @doc """
  Run a single optimization iteration.

  Returns `{:cont, new_state}` to continue or `{:stop, state}` to stop.
  """
  @spec run_iteration(GEPA.State.t(), map()) ::
          {:cont, GEPA.State.t(), map(), boolean(), term()} | {:stop, GEPA.State.t()}
  def run_iteration(state, config) do
    # Check stop conditions
    if should_stop?(state, config.stop_conditions) do
      Logger.info("Stop condition met at iteration #{state.i}")
      {:stop, state}
    else
      prev_best = best_score(state)
      iter_start_ms = System.monotonic_time(:millisecond)

      # Increment iteration
      state = %{state | i: state.i + 1}
      iteration = state.i
      Logger.debug("Starting iteration #{iteration}")

      # Try merge proposer first (if configured and conditions met)
      {proposal, state, config} =
        case Map.fetch(config, :merge_proposer) do
          {:ok, nil} ->
            {reflective, new_state, new_config} = try_reflective_proposal(state, config)
            {reflective, new_state, new_config}

          {:ok, merge_proposer} ->
            {merge_proposal, updated_proposer} =
              GEPA.Proposer.Merge.propose(merge_proposer, state)

            merge_config = %{config | merge_proposer: updated_proposer}

            if merge_proposal do
              {merge_proposal, state, merge_config}
            else
              {reflective, new_state, new_config} = try_reflective_proposal(state, merge_config)
              {reflective, new_state, new_config}
            end

          :error ->
            {reflective, new_state, new_config} = try_reflective_proposal(state, config)
            {reflective, new_state, new_config}
        end

      selected_candidate = proposal && List.first(proposal.parent_program_ids)
      Telemetry.emit_iteration_start(iteration, selected_candidate)

      proposal_tag = proposal && proposal.tag
      subsample_before_sum = (proposal && Enum.sum(proposal.subsample_scores_before || [])) || 0.0
      subsample_after_sum = (proposal && Enum.sum(proposal.subsample_scores_after || [])) || 0.0
      subsample_ids = proposal && proposal.subsample_indices

      {result_tag, new_state, new_config, accepted?} =
        case proposal do
          %GEPA.CandidateProposal{} ->
            Logger.debug("Proposal generated for iteration #{state.i} (#{proposal.tag})")
            Telemetry.emit_proposal_generated(proposal, iteration)

            # Update eval counter
            num_subsample_evals =
              length(proposal.subsample_scores_before) + length(proposal.subsample_scores_after)

            state = %{state | total_num_evals: state.total_num_evals + num_subsample_evals}

            if GEPA.CandidateProposal.should_accept?(proposal) do
              Logger.info("Accepting #{proposal.tag} proposal at iteration #{state.i}")
              new_state = accept_proposal(state, proposal, config, iteration)

              Telemetry.emit_proposal_decision(
                proposal,
                iteration,
                true,
                :accepted,
                subsample_after_sum - subsample_before_sum,
                proposal.parent_program_ids
              )

              new_config =
                case Map.fetch(config, :merge_proposer) do
                  {:ok, nil} ->
                    config

                  {:ok, merge_proposer} ->
                    updated_merge = %{merge_proposer | last_iter_found_new_program: true}
                    updated_merge = GEPA.Proposer.Merge.schedule_if_needed(updated_merge)
                    %{config | merge_proposer: updated_merge}

                  :error ->
                    config
                end

              {:cont, new_state, new_config, true}
            else
              Logger.debug("Rejecting proposal at iteration #{state.i}")

              Telemetry.emit_proposal_decision(
                proposal,
                iteration,
                false,
                :not_improved,
                subsample_after_sum - subsample_before_sum,
                proposal.parent_program_ids
              )

              {:cont, state, config, false}
            end

          nil ->
            Logger.debug("No proposal generated at iteration #{state.i}")
            state = %{state | total_num_evals: state.total_num_evals + 1}

            Telemetry.emit_proposal_decision(
              nil,
              iteration,
              false,
              :schedule_skip,
              0.0,
              nil
            )

            {:cont, state, config, false}
        end

      iter_duration_ms = System.monotonic_time(:millisecond) - iter_start_ms

      Telemetry.emit_iteration_stop(
        new_state,
        iteration,
        prev_best,
        accepted?,
        subsample_before_sum,
        subsample_after_sum,
        proposal_tag,
        proposal && proposal.parent_program_ids,
        subsample_ids,
        iter_duration_ms
      )

      {result_tag, new_state, new_config, accepted?, proposal_tag}
    end
  end

  defp try_reflective_proposal(state, config) do
    # Use configured reflective proposer or create one
    proposer = config[:reflective_proposer] || create_proposer(config)

    case GEPA.Proposer.Reflective.propose(proposer, state) do
      {:ok, proposal, selector} ->
        new_config = put_candidate_selector(config, selector)
        {proposal, state, new_config}

      {:none, selector} ->
        new_config = put_candidate_selector(config, selector)
        {nil, state, new_config}

      {:error, reason, selector} ->
        Logger.warning("Reflective proposal failed: #{inspect(reason)}")
        new_config = put_candidate_selector(config, selector)
        {nil, state, new_config}
    end
  end

  # Private functions

  defp initialize_state(config) do
    # Try to load existing state if run_dir provided
    if config[:run_dir] do
      case load_state(config.run_dir) do
        {:ok, state} ->
          Logger.info("Loaded existing state from #{config.run_dir}")
          state

        {:error, _} ->
          create_initial_state(config)
      end
    else
      create_initial_state(config)
    end
  end

  defp create_initial_state(config) do
    # Evaluate seed candidate on validation set
    valset_ids = GEPA.DataLoader.all_ids(config.valset)
    valset_batch = GEPA.DataLoader.fetch(config.valset, valset_ids)

    adapter = config.adapter

    eval_start = System.monotonic_time(:millisecond)

    {:ok, eval_batch} =
      adapter.__struct__.evaluate(adapter, valset_batch, config.seed_candidate, false)

    duration_ms = System.monotonic_time(:millisecond) - eval_start

    Telemetry.emit_evaluation_batch(
      0,
      :val,
      length(valset_ids),
      duration_ms,
      eval_batch.scores,
      0,
      "seed"
    )

    Telemetry.emit_baseline(eval_batch, length(valset_ids))

    GEPA.State.new(config.seed_candidate, eval_batch, valset_ids)
  end

  defp optimization_loop(state, config, progress, max_iters \\ 1000) do
    # Safety guard against infinite loops
    if state.i >= max_iters do
      Logger.warning("Reached max iterations (#{max_iters}), stopping")
      state
    else
      case run_iteration(state, config) do
        {:cont, new_state, new_config, accepted?, proposal_type} ->
          # Update progress display
          progress = maybe_update_progress(progress, new_state, accepted?, proposal_type)

          # Save state periodically
          if config[:run_dir] && rem(new_state.i, 5) == 0 do
            save_state(new_state, config.run_dir)
          end

          optimization_loop(new_state, new_config, progress, max_iters)

        {:stop, final_state} ->
          Logger.info("Optimization stopped at iteration #{final_state.i}")
          final_state
      end
    end
  end

  defp should_stop?(state, stop_conditions) do
    Enum.any?(stop_conditions, fn condition ->
      condition.__struct__.should_stop?(condition, state)
    end)
  end

  defp accept_proposal(state, proposal, config, iteration) do
    # Evaluate on full validation set
    valset_ids = GEPA.DataLoader.all_ids(config.valset)
    valset_batch = GEPA.DataLoader.fetch(config.valset, valset_ids)

    adapter = config.adapter

    eval_start = System.monotonic_time(:millisecond)

    case adapter.__struct__.evaluate(adapter, valset_batch, proposal.candidate, false) do
      {:ok, eval_batch} ->
        duration_ms = System.monotonic_time(:millisecond) - eval_start

        # Create scores map
        val_scores =
          valset_ids
          |> Enum.zip(eval_batch.scores)
          |> Enum.into(%{})

        # Add to state
        {new_state, new_idx} =
          GEPA.State.add_program(
            state,
            proposal.candidate,
            proposal.parent_program_ids,
            val_scores
          )

        Telemetry.emit_evaluation_batch(
          iteration,
          :val,
          length(valset_ids),
          duration_ms,
          eval_batch.scores,
          new_idx,
          proposal.tag
        )

        Telemetry.emit_valset_update(new_state, iteration, new_idx, val_scores)

        Logger.info(
          "Accepted new program #{new_idx} with avg score #{elem(GEPA.State.get_program_score(new_state, new_idx), 0)}"
        )

        new_state

      {:error, reason} ->
        Logger.error("Failed to evaluate proposal: #{inspect(reason)}")
        state
    end
  end

  defp candidate_selector_from_config(config) do
    Map.get(config, :candidate_selector, GEPA.Strategies.CandidateSelector.Pareto)
  end

  defp put_candidate_selector(config, selector) do
    Map.put(config, :candidate_selector, selector || candidate_selector_from_config(config))
  end

  defp create_proposer(config) do
    GEPA.Proposer.Reflective.new(
      adapter: config.adapter,
      trainset: config.trainset,
      candidate_selector: candidate_selector_from_config(config),
      perfect_score: config[:perfect_score] || 1.0,
      skip_perfect_score: Keyword.get(config |> Map.to_list(), :skip_perfect_score, true),
      minibatch_size: config[:reflection_minibatch_size] || 3,
      instruction_proposal: config[:instruction_proposal]
    )
  end

  defp save_state(state, run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")
    File.mkdir_p!(run_dir)

    data = :erlang.term_to_binary(state, [:compressed])
    File.write!(path, data)
  end

  defp load_state(run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")

    with {:ok, data} <- File.read(path),
         state <- :erlang.binary_to_term(data) do
      {:ok, state}
    end
  end

  defp best_score(state) do
    state.prog_candidate_val_subscores
    |> Enum.map(fn scores ->
      if map_size(scores) == 0 do
        0.0
      else
        Enum.sum(Map.values(scores)) / map_size(scores)
      end
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  # Progress tracking helpers

  defp maybe_start_progress(%{progress: false}), do: nil
  defp maybe_start_progress(%{progress: nil}), do: nil

  defp maybe_start_progress(%{progress: true} = config) do
    max_calls = extract_max_calls(config[:stop_conditions] || [])
    progress = GEPA.Progress.new(max_calls: max_calls)
    GEPA.Progress.start(progress)
    progress
  end

  defp maybe_start_progress(%{progress: opts} = config) when is_list(opts) do
    max_calls = extract_max_calls(config[:stop_conditions] || [])
    progress = GEPA.Progress.new([{:max_calls, max_calls} | opts])
    GEPA.Progress.start(progress)
    progress
  end

  defp maybe_start_progress(_config), do: nil

  defp maybe_update_progress(nil, _state, _accepted?, _proposal_type), do: nil

  defp maybe_update_progress(progress, state, accepted?, proposal_type) do
    GEPA.Progress.update(progress, %{
      iteration: state.i,
      best_score: best_score(state),
      pareto_size: map_size(state.program_at_pareto_front_valset),
      total_evals: state.total_num_evals,
      accepted: accepted?,
      proposal_type: proposal_type
    })
  end

  defp maybe_finish_progress(nil, _state), do: :ok

  defp maybe_finish_progress(progress, state) do
    result = GEPA.Result.from_state(state)
    GEPA.Progress.finish(progress, result)
  end

  defp extract_max_calls(stop_conditions) do
    Enum.find_value(stop_conditions, fn
      %GEPA.StopCondition.MaxCalls{max_calls: max} -> max
      _ -> nil
    end)
  end
end
