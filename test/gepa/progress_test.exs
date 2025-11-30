defmodule GEPA.ProgressTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  import ExUnit.CaptureIO

  alias GEPA.Progress

  describe "new/1" do
    test "creates with defaults" do
      progress = Progress.new()

      assert progress.width == 40
      assert progress.max_calls == nil
      assert is_boolean(progress.color)
      assert is_integer(progress.start_time)
    end

    test "accepts custom options" do
      progress = Progress.new(width: 60, max_calls: 100, color: false)

      assert progress.width == 60
      assert progress.max_calls == 100
      assert progress.color == false
    end
  end

  describe "start/1" do
    test "displays start banner" do
      progress = Progress.new(color: false)

      output =
        capture_io(fn ->
          Progress.start(progress)
        end)

      assert output =~ "GEPA Optimization"
      assert output =~ "─"
    end
  end

  describe "update/2" do
    test "displays progress bar with max_calls" do
      progress = Progress.new(max_calls: 100, color: false)

      output =
        capture_io(fn ->
          Progress.update(progress, %{
            iteration: 10,
            best_score: 0.85,
            pareto_size: 5,
            total_evals: 50,
            accepted: true,
            proposal_type: "reflective"
          })
        end)

      assert output =~ "50%"
      assert output =~ "Score: 0.85"
      assert output =~ "Pareto: 5"
      assert output =~ "✓"
    end

    test "shows spinner for indeterminate progress" do
      progress = Progress.new(max_calls: nil, color: false)

      output =
        capture_io(fn ->
          Progress.update(progress, %{
            iteration: 10,
            best_score: 0.5,
            total_evals: 25
          })
        end)

      assert output =~ "Evals: 25"
    end

    test "shows rejection indicator" do
      progress = Progress.new(max_calls: 100, color: false)

      output =
        capture_io(fn ->
          Progress.update(progress, %{
            iteration: 5,
            best_score: 0.7,
            pareto_size: 3,
            total_evals: 20,
            accepted: false,
            proposal_type: nil
          })
        end)

      assert output =~ "✗"
    end

    test "shows ETA when max_calls is known" do
      # Create progress with a start_time in the past to simulate elapsed time
      progress = %Progress{
        max_calls: 100,
        width: 40,
        color: false,
        start_time: System.monotonic_time(:millisecond) - 10_000,
        last_update: 0
      }

      output =
        capture_io(fn ->
          Progress.update(progress, %{
            iteration: 10,
            best_score: 0.8,
            pareto_size: 2,
            total_evals: 50
          })
        end)

      assert output =~ "ETA:"
    end

    test "returns updated progress struct" do
      progress = Progress.new(max_calls: 100, color: false)
      initial_last_update = progress.last_update

      # Use StringIO to suppress output and capture return value
      {:ok, io} = StringIO.open("")

      _output =
        ExUnit.CaptureIO.capture_io(io, fn ->
          result = Progress.update(progress, %{iteration: 1, total_evals: 10})
          send(self(), {:updated, result})
        end)

      receive do
        {:updated, result} ->
          # last_update should have changed from its initial value
          assert result.last_update != initial_last_update
      after
        100 -> flunk("Did not receive updated progress")
      end
    end
  end

  describe "finish/2" do
    test "displays completion summary" do
      progress = Progress.new(color: false)

      result = mock_result(iterations: 50, best_score: 0.92)

      output =
        capture_io(fn ->
          Progress.finish(progress, result)
        end)

      assert output =~ "Optimization Complete"
      assert output =~ "Iterations:  50"
      assert output =~ "0.92"
    end

    test "formats duration correctly" do
      # Create progress with start time 5 seconds ago
      progress = %Progress{
        max_calls: nil,
        width: 40,
        color: false,
        start_time: System.monotonic_time(:millisecond) - 5_000,
        last_update: 0
      }

      result = mock_result(iterations: 10, best_score: 0.75)

      output =
        capture_io(fn ->
          Progress.finish(progress, result)
        end)

      assert output =~ "Duration:"
      # Should show seconds
      assert output =~ "s"
    end
  end

  describe "format_duration (via finish)" do
    test "formats milliseconds" do
      progress = %Progress{
        max_calls: nil,
        width: 40,
        color: false,
        start_time: System.monotonic_time(:millisecond) - 500,
        last_update: 0
      }

      result = mock_result(iterations: 1, best_score: 0.5)

      output =
        capture_io(fn ->
          Progress.finish(progress, result)
        end)

      assert output =~ "ms"
    end
  end

  # Helper to create mock result
  defp mock_result(opts) do
    iterations = Keyword.get(opts, :iterations, 0)
    best_score = Keyword.get(opts, :best_score, 0.0)

    %GEPA.Result{
      candidates: [%{"instruction" => "test"}],
      val_aggregate_scores: [best_score],
      val_subscores: [%{0 => best_score}],
      per_val_instance_best_candidates: %{0 => MapSet.new([0])},
      parents: [[nil]],
      total_num_evals: iterations * 2,
      num_full_ds_evals: 1,
      i: iterations
    }
  end
end
