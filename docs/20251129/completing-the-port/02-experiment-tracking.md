# Experiment Tracking: W&B and MLflow Integration

> **Priority**: Medium
> **Estimated Effort**: 8-12 hours
> **Dependencies**: Telemetry (already wired)

## Current State

GEPA has Telemetry dependency but no event emission or handlers:

```elixir
# mix.exs
{:telemetry, "~> 1.2"}
```

The Engine logs via `Logger` but doesn't emit structured telemetry events.

---

## Python Reference

The Python implementation in `logging/experiment_tracker.py` provides:

### 1. W&B Integration

```python
class WandBTracker:
    def __init__(self, project: str, config: dict):
        wandb.init(project=project, config=config)

    def log_iteration(self, iteration: int, metrics: dict):
        wandb.log({"iteration": iteration, **metrics})

    def log_artifact(self, name: str, path: str):
        artifact = wandb.Artifact(name, type="model")
        artifact.add_file(path)
        wandb.log_artifact(artifact)

    def finish(self):
        wandb.finish()
```

### 2. MLflow Integration

```python
class MLflowTracker:
    def __init__(self, experiment_name: str, tracking_uri: str):
        mlflow.set_tracking_uri(tracking_uri)
        mlflow.set_experiment(experiment_name)
        self.run = mlflow.start_run()

    def log_param(self, key: str, value: Any):
        mlflow.log_param(key, value)

    def log_metric(self, key: str, value: float, step: int):
        mlflow.log_metric(key, value, step=step)

    def log_artifact(self, path: str):
        mlflow.log_artifact(path)

    def finish(self):
        mlflow.end_run()
```

### 3. Tracked Metrics

```python
TRACKED_METRICS = {
    # Per iteration
    "iteration": int,
    "best_score": float,
    "pareto_front_size": int,
    "total_evals": int,

    # Proposal metrics
    "proposal_accepted": bool,
    "proposal_type": str,  # "reflective" or "merge"
    "subsample_improvement": float,

    # Validation metrics
    "val_mean_score": float,
    "val_min_score": float,
    "val_max_score": float,

    # Resource metrics
    "elapsed_time": float,
    "llm_calls": int,
}
```

---

## Proposed Implementation

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    GEPA.Engine                               │
│  (emits :telemetry events)                                  │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              :telemetry handlers                             │
│  (attached at application start or by user)                 │
└────────────────────────┬────────────────────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
   ┌──────────┐   ┌──────────┐   ┌──────────┐
   │  W&B     │   │  MLflow  │   │  Custom  │
   │ Handler  │   │ Handler  │   │ Handler  │
   └──────────┘   └──────────┘   └──────────┘
```

### Step 1: Define Telemetry Events

```elixir
defmodule GEPA.Telemetry do
  @moduledoc """
  Telemetry events emitted by GEPA.

  ## Events

  ### `[:gepa, :optimization, :start]`
  Emitted when optimization begins.

  Measurements: `%{system_time: integer()}`
  Metadata: `%{config: map()}`

  ### `[:gepa, :optimization, :stop]`
  Emitted when optimization completes.

  Measurements: `%{duration: integer(), iterations: integer()}`
  Metadata: `%{result: GEPA.Result.t()}`

  ### `[:gepa, :iteration, :start]`
  Emitted at the start of each iteration.

  Measurements: `%{system_time: integer()}`
  Metadata: `%{iteration: integer(), state: GEPA.State.t()}`

  ### `[:gepa, :iteration, :stop]`
  Emitted at the end of each iteration.

  Measurements: `%{duration: integer()}`
  Metadata: `%{
    iteration: integer(),
    proposal_accepted: boolean(),
    proposal_type: String.t() | nil,
    best_score: float(),
    pareto_front_size: integer()
  }`

  ### `[:gepa, :proposal, :generated]`
  Emitted when a proposal is generated.

  Measurements: `%{subsample_improvement: float()}`
  Metadata: `%{
    type: String.t(),
    accepted: boolean(),
    parent_ids: list(integer())
  }`

  ### `[:gepa, :evaluation, :complete]`
  Emitted after evaluation batch completes.

  Measurements: `%{duration: integer(), batch_size: integer()}`
  Metadata: `%{scores: list(float()), mean_score: float()}`
  """

  @doc """
  Emit optimization start event.
  """
  def emit_optimization_start(config) do
    :telemetry.execute(
      [:gepa, :optimization, :start],
      %{system_time: System.system_time()},
      %{config: sanitize_config(config)}
    )
  end

  @doc """
  Emit optimization stop event.
  """
  def emit_optimization_stop(result, start_time) do
    :telemetry.execute(
      [:gepa, :optimization, :stop],
      %{
        duration: System.system_time() - start_time,
        iterations: result.state.i
      },
      %{result: result}
    )
  end

  @doc """
  Emit iteration start event.
  """
  def emit_iteration_start(iteration, state) do
    :telemetry.execute(
      [:gepa, :iteration, :start],
      %{system_time: System.system_time()},
      %{iteration: iteration, state: state}
    )
  end

  @doc """
  Emit iteration stop event.
  """
  def emit_iteration_stop(iteration, state, proposal, accepted, start_time) do
    {best_score, _} = GEPA.State.get_best_program(state)
    pareto_size = map_size(state.program_at_pareto_front_valset)

    :telemetry.execute(
      [:gepa, :iteration, :stop],
      %{duration: System.system_time() - start_time},
      %{
        iteration: iteration,
        proposal_accepted: accepted,
        proposal_type: if(proposal, do: proposal.tag, else: nil),
        best_score: best_score,
        pareto_front_size: pareto_size
      }
    )
  end

  @doc """
  Emit proposal generated event.
  """
  def emit_proposal_generated(proposal, accepted) do
    improvement =
      Enum.sum(proposal.subsample_scores_after) -
      Enum.sum(proposal.subsample_scores_before)

    :telemetry.execute(
      [:gepa, :proposal, :generated],
      %{subsample_improvement: improvement},
      %{
        type: proposal.tag,
        accepted: accepted,
        parent_ids: proposal.parent_program_ids
      }
    )
  end

  @doc """
  Emit evaluation complete event.
  """
  def emit_evaluation_complete(scores, duration) do
    :telemetry.execute(
      [:gepa, :evaluation, :complete],
      %{
        duration: duration,
        batch_size: length(scores)
      },
      %{
        scores: scores,
        mean_score: Enum.sum(scores) / max(length(scores), 1)
      }
    )
  end

  # Remove sensitive data from config
  defp sanitize_config(config) do
    config
    |> Map.drop([:adapter])  # May contain credentials
    |> Map.update(:trainset, nil, fn _ -> "[DataLoader]" end)
    |> Map.update(:valset, nil, fn _ -> "[DataLoader]" end)
  end
end
```

### Step 2: Update Engine to Emit Events

```elixir
defmodule GEPA.Engine do
  alias GEPA.Telemetry

  def run(config) do
    start_time = System.system_time()
    Telemetry.emit_optimization_start(config)

    state = initialize_state(config)
    final_state = optimization_loop(state, config)

    result = GEPA.Result.from_state(final_state)
    Telemetry.emit_optimization_stop(result, start_time)

    {:ok, result}
  end

  def run_iteration(state, config) do
    iter_start = System.system_time()
    Telemetry.emit_iteration_start(state.i + 1, state)

    # ... existing iteration logic ...

    case result do
      {:cont, new_state, new_config} ->
        Telemetry.emit_iteration_stop(
          new_state.i, new_state, proposal, accepted, iter_start
        )
        {:cont, new_state, new_config}

      {:stop, final_state} ->
        Telemetry.emit_iteration_stop(
          final_state.i, final_state, nil, false, iter_start
        )
        {:stop, final_state}
    end
  end
end
```

### Step 3: W&B Handler

```elixir
defmodule GEPA.Tracking.WandB do
  @moduledoc """
  Weights & Biases integration for GEPA experiment tracking.

  ## Setup

      # In your application.ex or test setup
      GEPA.Tracking.WandB.attach(
        project: "my-gepa-experiments",
        entity: "my-team",
        config: %{model: "gpt-4o-mini"}
      )

  ## Requirements

  - Python with `wandb` installed
  - `WANDB_API_KEY` environment variable
  - `erlport` or `Pythonx` for Python interop
  """

  @handler_id :gepa_wandb_handler

  @doc """
  Attach W&B telemetry handlers.
  """
  def attach(opts) do
    project = opts[:project] || "gepa"
    entity = opts[:entity]
    config = opts[:config] || %{}

    # Initialize W&B run
    init_wandb(project, entity, config)

    # Attach handlers
    :telemetry.attach_many(
      @handler_id,
      [
        [:gepa, :optimization, :start],
        [:gepa, :iteration, :stop],
        [:gepa, :optimization, :stop]
      ],
      &handle_event/4,
      %{project: project}
    )
  end

  @doc """
  Detach handlers and finish W&B run.
  """
  def detach do
    :telemetry.detach(@handler_id)
    finish_wandb()
  end

  # Event handlers

  def handle_event([:gepa, :optimization, :start], _measurements, metadata, _config) do
    log_config(metadata.config)
  end

  def handle_event([:gepa, :iteration, :stop], measurements, metadata, _config) do
    log_metrics(%{
      "iteration" => metadata.iteration,
      "best_score" => metadata.best_score,
      "pareto_front_size" => metadata.pareto_front_size,
      "proposal_accepted" => if(metadata.proposal_accepted, do: 1, else: 0),
      "iteration_duration_ms" => measurements.duration / 1_000_000
    })
  end

  def handle_event([:gepa, :optimization, :stop], measurements, metadata, _config) do
    log_summary(%{
      "total_iterations" => measurements.iterations,
      "total_duration_s" => measurements.duration / 1_000_000_000,
      "final_best_score" => GEPA.Result.best_score(metadata.result)
    })
    finish_wandb()
  end

  # Python interop (via Port or Pythonx)

  defp init_wandb(project, entity, config) do
    # Option 1: Via shell command
    python_code = """
    import wandb
    wandb.init(
      project="#{project}",
      #{if entity, do: "entity=\"#{entity}\",", else: ""}
      config=#{Jason.encode!(config)}
    )
    """
    System.cmd("python3", ["-c", python_code])
  end

  defp log_config(config) do
    python_code = """
    import wandb
    wandb.config.update(#{Jason.encode!(config)})
    """
    System.cmd("python3", ["-c", python_code])
  end

  defp log_metrics(metrics) do
    python_code = """
    import wandb
    wandb.log(#{Jason.encode!(metrics)})
    """
    System.cmd("python3", ["-c", python_code])
  end

  defp log_summary(summary) do
    python_code = """
    import wandb
    for k, v in #{Jason.encode!(summary)}.items():
        wandb.run.summary[k] = v
    """
    System.cmd("python3", ["-c", python_code])
  end

  defp finish_wandb do
    System.cmd("python3", ["-c", "import wandb; wandb.finish()"])
  end
end
```

### Step 4: MLflow Handler

```elixir
defmodule GEPA.Tracking.MLflow do
  @moduledoc """
  MLflow integration for GEPA experiment tracking.

  ## Setup

      GEPA.Tracking.MLflow.attach(
        experiment_name: "gepa-optimization",
        tracking_uri: "http://localhost:5000"
      )

  ## Requirements

  - MLflow server running
  - `mlflow` Python package installed
  """

  @handler_id :gepa_mlflow_handler

  def attach(opts) do
    experiment = opts[:experiment_name] || "gepa"
    tracking_uri = opts[:tracking_uri] || "http://localhost:5000"

    # Start MLflow run
    start_run(experiment, tracking_uri)

    :telemetry.attach_many(
      @handler_id,
      [
        [:gepa, :optimization, :start],
        [:gepa, :iteration, :stop],
        [:gepa, :optimization, :stop]
      ],
      &handle_event/4,
      %{}
    )
  end

  def detach do
    :telemetry.detach(@handler_id)
    end_run()
  end

  def handle_event([:gepa, :optimization, :start], _measurements, metadata, _config) do
    log_params(metadata.config)
  end

  def handle_event([:gepa, :iteration, :stop], _measurements, metadata, _config) do
    log_metrics(%{
      "best_score" => metadata.best_score,
      "pareto_front_size" => metadata.pareto_front_size
    }, metadata.iteration)
  end

  def handle_event([:gepa, :optimization, :stop], measurements, metadata, _config) do
    # Log final artifacts
    log_artifact_json("result.json", %{
      best_candidate: GEPA.Result.best_candidate(metadata.result),
      best_score: GEPA.Result.best_score(metadata.result),
      iterations: measurements.iterations
    })
    end_run()
  end

  # MLflow Python interop

  defp start_run(experiment, tracking_uri) do
    python_code = """
    import mlflow
    mlflow.set_tracking_uri("#{tracking_uri}")
    mlflow.set_experiment("#{experiment}")
    mlflow.start_run()
    """
    System.cmd("python3", ["-c", python_code])
  end

  defp log_params(params) do
    for {key, value} <- params, is_loggable?(value) do
      python_code = """
      import mlflow
      mlflow.log_param("#{key}", #{inspect(value)})
      """
      System.cmd("python3", ["-c", python_code])
    end
  end

  defp log_metrics(metrics, step) do
    for {key, value} <- metrics do
      python_code = """
      import mlflow
      mlflow.log_metric("#{key}", #{value}, step=#{step})
      """
      System.cmd("python3", ["-c", python_code])
    end
  end

  defp log_artifact_json(name, data) do
    path = Path.join(System.tmp_dir!(), name)
    File.write!(path, Jason.encode!(data, pretty: true))

    python_code = """
    import mlflow
    mlflow.log_artifact("#{path}")
    """
    System.cmd("python3", ["-c", python_code])
  end

  defp end_run do
    System.cmd("python3", ["-c", "import mlflow; mlflow.end_run()"])
  end

  defp is_loggable?(value) when is_binary(value), do: true
  defp is_loggable?(value) when is_number(value), do: true
  defp is_loggable?(value) when is_atom(value), do: true
  defp is_loggable?(_), do: false
end
```

### Step 5: Console Progress Handler

```elixir
defmodule GEPA.Tracking.Console do
  @moduledoc """
  Console-based progress tracking with live updates.

  ## Usage

      GEPA.Tracking.Console.attach()

  Displays:
  - Progress bar for iterations
  - Current best score
  - Proposals accepted/rejected
  - ETA based on elapsed time
  """

  @handler_id :gepa_console_handler

  def attach(opts \\ []) do
    width = opts[:width] || 50

    :telemetry.attach_many(
      @handler_id,
      [
        [:gepa, :optimization, :start],
        [:gepa, :iteration, :stop],
        [:gepa, :optimization, :stop]
      ],
      &handle_event/4,
      %{width: width, start_time: nil, max_calls: nil}
    )
  end

  def detach do
    :telemetry.detach(@handler_id)
  end

  def handle_event([:gepa, :optimization, :start], _measurements, metadata, config) do
    max_calls = get_in(metadata.config, [:stop_conditions]) |> extract_max_calls()

    IO.puts("\n" <> String.duplicate("=", config.width))
    IO.puts("GEPA Optimization Started")
    IO.puts(String.duplicate("=", config.width))

    # Update config with runtime state
    Process.put(:gepa_console_state, %{
      start_time: System.monotonic_time(:millisecond),
      max_calls: max_calls
    })
  end

  def handle_event([:gepa, :iteration, :stop], _measurements, metadata, config) do
    state = Process.get(:gepa_console_state, %{})

    # Calculate progress
    progress = metadata.iteration
    elapsed = System.monotonic_time(:millisecond) - (state.start_time || 0)

    # Build progress bar
    bar = build_progress_bar(progress, state.max_calls, config.width)

    # Status line
    status = if metadata.proposal_accepted, do: "✓", else: "✗"

    IO.write("\r#{bar} | #{status} Score: #{Float.round(metadata.best_score, 4)} | Pareto: #{metadata.pareto_front_size}")
  end

  def handle_event([:gepa, :optimization, :stop], measurements, metadata, config) do
    IO.puts("\n" <> String.duplicate("=", config.width))
    IO.puts("Optimization Complete!")
    IO.puts("  Iterations: #{measurements.iterations}")
    IO.puts("  Duration: #{Float.round(measurements.duration / 1_000_000_000, 2)}s")
    IO.puts("  Best Score: #{GEPA.Result.best_score(metadata.result)}")
    IO.puts(String.duplicate("=", config.width) <> "\n")
  end

  defp build_progress_bar(current, max, width) when is_integer(max) and max > 0 do
    bar_width = width - 10
    filled = round(current / max * bar_width)
    empty = bar_width - filled

    "[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}] #{current}/#{max}"
  end

  defp build_progress_bar(current, _max, _width) do
    "[Iter #{current}]"
  end

  defp extract_max_calls(stop_conditions) when is_list(stop_conditions) do
    Enum.find_value(stop_conditions, fn
      %GEPA.StopCondition.MaxCalls{max_calls: max} -> max
      _ -> nil
    end)
  end

  defp extract_max_calls(_), do: nil
end
```

---

## Usage Examples

### Basic Console Progress

```elixir
# Attach before optimization
GEPA.Tracking.Console.attach()

{:ok, result} = GEPA.optimize(
  seed_candidate: %{"instruction" => "..."},
  trainset: trainset,
  valset: valset,
  adapter: adapter,
  max_metric_calls: 100
)

# Output:
# ==================================================
# GEPA Optimization Started
# ==================================================
# [████████████░░░░░░░░░░░░░░░░░░░░░░░░] 35/100 | ✓ Score: 0.8543 | Pareto: 12
```

### W&B Integration

```elixir
# Attach W&B tracking
GEPA.Tracking.WandB.attach(
  project: "prompt-optimization",
  entity: "my-team",
  config: %{
    model: "gpt-4o-mini",
    task: "math-reasoning"
  }
)

{:ok, result} = GEPA.optimize(...)

# Automatically logs to W&B dashboard
```

### MLflow Integration

```elixir
# Start MLflow server: mlflow server --host 0.0.0.0 --port 5000

GEPA.Tracking.MLflow.attach(
  experiment_name: "gepa-experiments",
  tracking_uri: "http://localhost:5000"
)

{:ok, result} = GEPA.optimize(...)

# View in MLflow UI at http://localhost:5000
```

### Multiple Handlers

```elixir
# Combine handlers
GEPA.Tracking.Console.attach()
GEPA.Tracking.WandB.attach(project: "my-project")

{:ok, result} = GEPA.optimize(...)
# Logs to both console and W&B
```

---

## Testing Plan

### Unit Tests

```elixir
defmodule GEPA.TelemetryTest do
  use ExUnit.Case

  test "emits optimization start event" do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "test-handler",
      [:gepa, :optimization, :start],
      fn _event, measurements, metadata, _config ->
        send(parent, {:event, ref, measurements, metadata})
      end,
      nil
    )

    GEPA.Telemetry.emit_optimization_start(%{seed_candidate: %{}})

    assert_receive {:event, ^ref, %{system_time: _}, %{config: _}}

    :telemetry.detach("test-handler")
  end
end
```

### Integration Tests

```elixir
defmodule GEPA.Tracking.ConsoleTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  test "displays progress during optimization" do
    GEPA.Tracking.Console.attach()

    output = capture_io(fn ->
      {:ok, _} = GEPA.optimize(
        seed_candidate: %{"test" => "value"},
        trainset: [%{input: "a", answer: "b"}],
        valset: [%{input: "a", answer: "b"}],
        adapter: GEPA.Adapters.Basic.new(),
        max_metric_calls: 5
      )
    end)

    assert output =~ "GEPA Optimization Started"
    assert output =~ "Optimization Complete!"

    GEPA.Tracking.Console.detach()
  end
end
```

---

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/gepa/telemetry.ex` | Create | Event definitions and emitters |
| `lib/gepa/tracking/wandb.ex` | Create | W&B handler |
| `lib/gepa/tracking/mlflow.ex` | Create | MLflow handler |
| `lib/gepa/tracking/console.ex` | Create | Console progress handler |
| `lib/gepa/engine.ex` | Modify | Add telemetry emission |
| `test/gepa/telemetry_test.exs` | Create | Unit tests |
| `test/gepa/tracking/*_test.exs` | Create | Handler tests |

---

## Dependencies to Add

```elixir
# mix.exs
defp deps do
  [
    # ... existing deps ...

    # For W&B/MLflow Python interop (optional)
    {:pythonx, "~> 0.2", optional: true}
  ]
end
```

---

## Future Enhancements

1. **Native Elixir MLflow client** - Avoid Python interop overhead
2. **OpenTelemetry export** - Standard observability format
3. **LiveView dashboard** - Real-time web-based monitoring
4. **Prometheus metrics** - For production alerting
