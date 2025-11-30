defmodule GEPA.Proposer.Reflective do
  @moduledoc """
  Reflective mutation proposer.

  Generates new candidates through reflection on execution traces.
  When an `instruction_proposal` is configured, uses LLM-based improvement.
  Otherwise falls back to a simple placeholder improvement.

  ## With LLM-based Instruction Proposal

      llm = GEPA.LLM.ReqLLM.new(provider: :openai)
      instruction_proposal = GEPA.Proposer.InstructionProposal.new(llm: llm)

      proposer = Reflective.new(
        adapter: my_adapter,
        trainset: trainset,
        instruction_proposal: instruction_proposal
      )

  ## Without LLM (Fallback Mode)

      proposer = Reflective.new(
        adapter: my_adapter,
        trainset: trainset
      )
      # Uses simple "[Optimized]" marker - for testing only
  """

  alias GEPA.Proposer.InstructionProposal

  defstruct [
    :adapter,
    :trainset,
    :candidate_selector,
    :perfect_score,
    :skip_perfect_score,
    :minibatch_size,
    :instruction_proposal
  ]

  @type t :: %__MODULE__{
          adapter: term(),
          trainset: GEPA.DataLoader.t(),
          candidate_selector: module(),
          perfect_score: float(),
          skip_perfect_score: boolean(),
          minibatch_size: pos_integer(),
          instruction_proposal: InstructionProposal.t() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      adapter: opts[:adapter],
      trainset: opts[:trainset],
      candidate_selector: opts[:candidate_selector] || GEPA.Strategies.CandidateSelector.Pareto,
      perfect_score: opts[:perfect_score] || 1.0,
      skip_perfect_score: Keyword.get(opts, :skip_perfect_score, true),
      minibatch_size: opts[:minibatch_size] || 3,
      instruction_proposal: opts[:instruction_proposal]
    }
  end

  @doc """
  Propose a new candidate through reflective mutation.

  Algorithm:
  1. Select candidate from Pareto front
  2. Sample minibatch from training set
  3. Evaluate with trace capture
  4. Check for perfect scores (optional skip)
  5. Generate improved version:
     - If `instruction_proposal` configured: use LLM with reflective dataset
     - Otherwise: use simple fallback (for testing)
  6. Evaluate new candidate
  7. Return proposal if improved
  """
  def propose(%__MODULE__{} = proposer, state) do
    # Step 1: Select candidate
    rand_state = :rand.seed(:exsss, {state.i, 42, state.total_num_evals})

    {candidate_idx, _new_rand} = proposer.candidate_selector.select(state, rand_state)
    candidate = Enum.at(state.program_candidates, candidate_idx)

    # Step 2: Sample minibatch (simplified - just take first N)
    trainset_ids =
      GEPA.DataLoader.all_ids(proposer.trainset)
      |> Enum.take(proposer.minibatch_size)

    minibatch = GEPA.DataLoader.fetch(proposer.trainset, trainset_ids)

    # Step 3: Evaluate current candidate with traces
    adapter = proposer.adapter
    capture_traces = proposer.instruction_proposal != nil

    case adapter.__struct__.evaluate(adapter, minibatch, candidate, capture_traces) do
      {:ok, eval_curr} ->
        # Step 4: Check for perfect score
        if proposer.skip_perfect_score and all_perfect?(eval_curr.scores, proposer.perfect_score) do
          :none
        else
          # Step 5: Generate improved candidate
          case generate_improved_candidate(proposer, candidate, eval_curr) do
            {:ok, new_candidate} ->
              # Step 6: Evaluate new candidate
              case adapter.__struct__.evaluate(adapter, minibatch, new_candidate, false) do
                {:ok, eval_new} ->
                  # Return proposal
                  {:ok,
                   %GEPA.CandidateProposal{
                     candidate: new_candidate,
                     parent_program_ids: [candidate_idx],
                     subsample_indices: trainset_ids,
                     subsample_scores_before: eval_curr.scores,
                     subsample_scores_after: eval_new.scores,
                     tag: "reflective_mutation",
                     metadata: %{
                       new_instructions: changed_components(candidate, new_candidate),
                       trajectories?: capture_traces
                     }
                   }}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, {:proposal_generation_failed, reason}}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helpers

  defp all_perfect?(scores, perfect_score) do
    Enum.all?(scores, &(&1 >= perfect_score))
  end

  defp generate_improved_candidate(proposer, candidate, eval_batch) do
    case proposer.instruction_proposal do
      nil ->
        # Fallback: simple improvement (for testing without LLM)
        {:ok, simple_improve(candidate)}

      instruction_proposal ->
        # Use LLM-based instruction proposal
        components = Map.keys(candidate)

        # Build reflective dataset from adapter
        adapter = proposer.adapter

        case adapter.__struct__.make_reflective_dataset(
               adapter,
               candidate,
               eval_batch,
               components
             ) do
          {:ok, reflective_dataset} ->
            InstructionProposal.propose_batch(
              instruction_proposal,
              candidate,
              reflective_dataset,
              components
            )

          {:error, reason} ->
            {:error, {:reflective_dataset_failed, reason}}
        end
    end
  end

  defp simple_improve(candidate) do
    # Simplified fallback - append improvement marker
    # Only used when instruction_proposal is nil (testing)
    for {key, value} <- candidate, into: %{} do
      {key, value <> "\n[Optimized]"}
    end
  end

  defp changed_components(original, updated) do
    for {key, value} <- updated, Map.get(original, key) != value, into: %{} do
      {key, value}
    end
  end
end
