# Progress Logging: Rich Terminal Output

> **Priority**: Low
> **Estimated Effort**: 2-4 hours
> **Dependencies**: None (optional: `owl` library for advanced features)

## Current State

GEPA uses basic `Logger` calls:

```elixir
# lib/gepa/engine.ex
Logger.info("Stop condition met at iteration #{state.i}")
Logger.debug("Starting iteration #{state.i}")
Logger.info("Accepting #{proposal.tag} proposal at iteration #{state.i}")
```

This provides functional logging but lacks:
- Progress visualization
- Real-time metric display
- Color-coded status indicators
- ETA estimation

---

## Python Reference

Python GEPA uses `rich` for progress display:

```python
from rich.progress import Progress, SpinnerColumn, BarColumn, TextColumn
from rich.console import Console

console = Console()

with Progress(
    SpinnerColumn(),
    BarColumn(),
    TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
    TextColumn("•"),
    TextColumn("[blue]Score: {task.fields[score]:.4f}"),
    TextColumn("•"),
    TextColumn("[green]Pareto: {task.fields[pareto]}"),
) as progress:
    task = progress.add_task("Optimizing...", total=max_calls, score=0.0, pareto=1)

    while not stopped:
        # ... iteration ...
        progress.update(task, advance=1, score=best_score, pareto=pareto_size)
```

---

## Proposed Implementation

### Option 1: Pure Elixir (No Dependencies)

```elixir
defmodule GEPA.Progress do
  @moduledoc """
  Simple progress display for GEPA optimization.

  ## Usage

      # Enable progress display
      {:ok, result} = GEPA.optimize(
        # ... options ...
        progress: true
      )

      # Or with custom configuration
      {:ok, result} = GEPA.optimize(
        # ... options ...
        progress: [width: 60, color: true]
      )
  """

  defstruct [
    :max_calls,
    :width,
    :color,
    :start_time,
    :last_update
  ]

  @type t :: %__MODULE__{
    max_calls: pos_integer() | nil,
    width: pos_integer(),
    color: boolean(),
    start_time: integer(),
    last_update: integer()
  }

  # ANSI color codes
  @green "\e[32m"
  @yellow "\e[33m"
  @blue "\e[34m"
  @red "\e[31m"
  @reset "\e[0m"
  @bold "\e[1m"
  @clear_line "\e[2K\r"

  @doc """
  Create a new progress tracker.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_calls: opts[:max_calls],
      width: opts[:width] || 40,
      color: Keyword.get(opts, :color, IO.ANSI.enabled?()),
      start_time: System.monotonic_time(:millisecond),
      last_update: 0
    }
  end

  @doc """
  Display optimization start banner.
  """
  @spec start(t()) :: :ok
  def start(%__MODULE__{} = progress) do
    divider = String.duplicate("─", progress.width + 30)

    IO.puts("")
    IO.puts(colorize(progress, "#{divider}", :blue))
    IO.puts(colorize(progress, " GEPA Optimization", :bold))
    IO.puts(colorize(progress, "#{divider}", :blue))
    IO.puts("")

    :ok
  end

  @doc """
  Update progress display for an iteration.
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = progress, metrics) do
    iteration = metrics[:iteration] || 0
    best_score = metrics[:best_score] || 0.0
    pareto_size = metrics[:pareto_size] || 1
    accepted = metrics[:accepted]
    proposal_type = metrics[:proposal_type]

    # Build progress bar
    bar = build_bar(progress, iteration)

    # Build status indicator
    status = build_status(progress, accepted, proposal_type)

    # Build metrics display
    metrics_str = build_metrics(progress, best_score, pareto_size)

    # Build ETA
    eta = build_eta(progress, iteration)

    # Compose full line
    line = "#{bar} #{status} #{metrics_str} #{eta}"

    # Write with carriage return (overwrite previous line)
    IO.write("#{@clear_line}#{line}")

    %{progress | last_update: System.monotonic_time(:millisecond)}
  end

  @doc """
  Display optimization completion summary.
  """
  @spec finish(t(), GEPA.Result.t()) :: :ok
  def finish(%__MODULE__{} = progress, result) do
    elapsed = System.monotonic_time(:millisecond) - progress.start_time
    elapsed_str = format_duration(elapsed)

    best_score = GEPA.Result.best_score(result)
    iterations = result.state.i

    IO.puts("")  # New line after progress bar
    IO.puts("")

    divider = String.duplicate("─", progress.width + 30)
    IO.puts(colorize(progress, divider, :green))
    IO.puts(colorize(progress, " ✓ Optimization Complete", :green))
    IO.puts(colorize(progress, divider, :green))
    IO.puts("")
    IO.puts("   Iterations:  #{iterations}")
    IO.puts("   Duration:    #{elapsed_str}")
    IO.puts("   Best Score:  #{colorize(progress, Float.round(best_score, 4), :bold)}")
    IO.puts("")

    :ok
  end

  # Private functions

  defp build_bar(%__MODULE__{max_calls: nil, width: width}, iteration) do
    # Indeterminate progress (spinner style)
    spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    idx = rem(iteration, length(spinner))
    char = Enum.at(spinner, idx)
    "[#{char}] Iter #{iteration}"
  end

  defp build_bar(%__MODULE__{max_calls: max, width: width} = progress, iteration) do
    bar_width = min(width, 40)
    percentage = min(iteration / max, 1.0)
    filled = round(percentage * bar_width)
    empty = bar_width - filled

    filled_bar = String.duplicate("█", filled)
    empty_bar = String.duplicate("░", empty)
    pct = round(percentage * 100)

    bar = "[#{filled_bar}#{empty_bar}]"
    colorize(progress, bar, :blue) <> " #{pct}%"
  end

  defp build_status(progress, true, type) do
    symbol = colorize(progress, "✓", :green)
    type_str = if type, do: "(#{type})", else: ""
    "#{symbol} #{type_str}"
  end

  defp build_status(progress, false, _type) do
    colorize(progress, "✗", :yellow)
  end

  defp build_status(progress, nil, _type) do
    colorize(progress, "○", :blue)
  end

  defp build_metrics(progress, best_score, pareto_size) do
    score_str = Float.round(best_score, 4) |> to_string()
    [
      "Score: #{colorize(progress, score_str, :bold)}",
      "Pareto: #{pareto_size}"
    ]
    |> Enum.join(" │ ")
  end

  defp build_eta(%__MODULE__{max_calls: nil}, _iteration), do: ""

  defp build_eta(%__MODULE__{max_calls: max, start_time: start}, iteration)
       when iteration > 0 do
    elapsed = System.monotonic_time(:millisecond) - start
    rate = iteration / elapsed  # iterations per ms
    remaining = max - iteration
    eta_ms = if rate > 0, do: remaining / rate, else: 0

    "ETA: #{format_duration(round(eta_ms))}"
  end

  defp build_eta(_progress, _iteration), do: ""

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000 do
    "#{Float.round(ms / 1000, 1)}s"
  end
  defp format_duration(ms) when ms < 3_600_000 do
    mins = div(ms, 60_000)
    secs = rem(ms, 60_000) |> div(1000)
    "#{mins}m #{secs}s"
  end
  defp format_duration(ms) do
    hours = div(ms, 3_600_000)
    mins = rem(ms, 3_600_000) |> div(60_000)
    "#{hours}h #{mins}m"
  end

  defp colorize(%__MODULE__{color: false}, text, _color), do: to_string(text)

  defp colorize(%__MODULE__{color: true}, text, :green), do: "#{@green}#{text}#{@reset}"
  defp colorize(%__MODULE__{color: true}, text, :yellow), do: "#{@yellow}#{text}#{@reset}"
  defp colorize(%__MODULE__{color: true}, text, :blue), do: "#{@blue}#{text}#{@reset}"
  defp colorize(%__MODULE__{color: true}, text, :red), do: "#{@red}#{text}#{@reset}"
  defp colorize(%__MODULE__{color: true}, text, :bold), do: "#{@bold}#{text}#{@reset}"
end
```

### Option 2: Using Owl Library (Rich Features)

```elixir
# Add to mix.exs:
# {:owl, "~> 0.11"}

defmodule GEPA.Progress.Owl do
  @moduledoc """
  Rich progress display using the Owl library.

  Provides:
  - Live-updating progress bars
  - Multi-line status displays
  - Spinners and animations
  - Table-based metric display
  """

  alias Owl.ProgressBar
  alias Owl.LiveScreen

  defstruct [
    :live_screen,
    :progress_bar,
    :max_calls,
    :start_time
  ]

  def new(opts \\ []) do
    max_calls = opts[:max_calls]

    live_screen = LiveScreen.start()

    progress_bar = if max_calls do
      ProgressBar.new(total: max_calls)
    else
      nil
    end

    %__MODULE__{
      live_screen: live_screen,
      progress_bar: progress_bar,
      max_calls: max_calls,
      start_time: System.monotonic_time(:millisecond)
    }
  end

  def update(%__MODULE__{} = progress, metrics) do
    content = render_content(progress, metrics)
    LiveScreen.update(progress.live_screen, content)

    if progress.progress_bar do
      %{progress | progress_bar: ProgressBar.inc(progress.progress_bar)}
    else
      progress
    end
  end

  def finish(%__MODULE__{live_screen: live_screen} = progress, result) do
    LiveScreen.stop(live_screen)
    print_summary(progress, result)
    :ok
  end

  defp render_content(progress, metrics) do
    [
      render_header(),
      render_progress_bar(progress),
      render_metrics_table(metrics),
      render_status(metrics)
    ]
    |> Enum.join("\n")
  end

  defp render_header do
    Owl.Box.new("GEPA Optimization", padding: 1)
    |> Owl.Data.to_ansidata()
    |> IO.iodata_to_binary()
  end

  defp render_progress_bar(%{progress_bar: nil}), do: ""
  defp render_progress_bar(%{progress_bar: bar}) do
    ProgressBar.render(bar)
    |> IO.iodata_to_binary()
  end

  defp render_metrics_table(metrics) do
    Owl.Table.new([
      ["Metric", "Value"],
      ["Iteration", metrics[:iteration]],
      ["Best Score", Float.round(metrics[:best_score] || 0.0, 4)],
      ["Pareto Size", metrics[:pareto_size]],
      ["Total Evals", metrics[:total_evals]]
    ])
    |> Owl.Data.to_ansidata()
    |> IO.iodata_to_binary()
  end

  defp render_status(metrics) do
    status = if metrics[:accepted] do
      Owl.Tag.new("ACCEPTED", :green)
    else
      Owl.Tag.new("REJECTED", :yellow)
    end

    Owl.Data.to_ansidata(status)
    |> IO.iodata_to_binary()
  end

  defp print_summary(progress, result) do
    elapsed = System.monotonic_time(:millisecond) - progress.start_time

    IO.puts(Owl.Box.new([
      "Optimization Complete!",
      "",
      "  Iterations: #{result.state.i}",
      "  Duration:   #{Float.round(elapsed / 1000, 2)}s",
      "  Best Score: #{Float.round(GEPA.Result.best_score(result), 4)}"
    ], title: "Results", padding: 1))
  end
end
```

### Integration with Engine

```elixir
defmodule GEPA.Engine do
  # Add progress tracking to run/1

  def run(config) do
    progress = maybe_start_progress(config)

    state = initialize_state(config)
    final_state = optimization_loop(state, config, progress)

    result = GEPA.Result.from_state(final_state)

    maybe_finish_progress(progress, result)

    {:ok, result}
  end

  defp maybe_start_progress(%{progress: false}), do: nil
  defp maybe_start_progress(%{progress: nil}), do: nil

  defp maybe_start_progress(%{progress: true} = config) do
    max_calls = extract_max_calls(config.stop_conditions)
    progress = GEPA.Progress.new(max_calls: max_calls)
    GEPA.Progress.start(progress)
    progress
  end

  defp maybe_start_progress(%{progress: opts} = config) when is_list(opts) do
    max_calls = extract_max_calls(config.stop_conditions)
    progress = GEPA.Progress.new([{:max_calls, max_calls} | opts])
    GEPA.Progress.start(progress)
    progress
  end

  defp maybe_update_progress(nil, _state, _proposal, _accepted), do: nil

  defp maybe_update_progress(progress, state, proposal, accepted) do
    {best_score, _} = GEPA.State.get_best_program(state)

    GEPA.Progress.update(progress, %{
      iteration: state.i,
      best_score: best_score,
      pareto_size: map_size(state.program_at_pareto_front_valset),
      total_evals: state.total_num_evals,
      accepted: accepted,
      proposal_type: if(proposal, do: proposal.tag, else: nil)
    })
  end

  defp maybe_finish_progress(nil, _result), do: :ok
  defp maybe_finish_progress(progress, result) do
    GEPA.Progress.finish(progress, result)
  end

  defp extract_max_calls(stop_conditions) do
    Enum.find_value(stop_conditions, fn
      %GEPA.StopCondition.MaxCalls{max_calls: max} -> max
      _ -> nil
    end)
  end
end
```

---

## Usage Examples

### Enable Progress Display

```elixir
{:ok, result} = GEPA.optimize(
  seed_candidate: %{"instruction" => "Answer questions."},
  trainset: trainset,
  valset: valset,
  adapter: adapter,
  max_metric_calls: 100,
  progress: true  # Enable progress display
)
```

### Custom Width and Colors

```elixir
{:ok, result} = GEPA.optimize(
  # ... options ...
  progress: [
    width: 60,      # Wider progress bar
    color: true     # Force colors (even in non-TTY)
  ]
)
```

### Disable Colors (CI/Logs)

```elixir
{:ok, result} = GEPA.optimize(
  # ... options ...
  progress: [color: false]
)
```

---

## Output Examples

### Basic Progress

```
──────────────────────────────────────────────────────────────────
 GEPA Optimization
──────────────────────────────────────────────────────────────────

[████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░] 30% ✓ (reflective) Score: 0.8234 │ Pareto: 5 ETA: 2m 15s
```

### Completion Summary

```
──────────────────────────────────────────────────────────────────
 ✓ Optimization Complete
──────────────────────────────────────────────────────────────────

   Iterations:  100
   Duration:    5m 32s
   Best Score:  0.9123
```

### With Owl (Rich Display)

```
╭─────────────────────────────────────╮
│       GEPA Optimization             │
╰─────────────────────────────────────╯

 ███████████████░░░░░░░░░░░░░  52%

┌──────────────┬─────────────┐
│ Metric       │ Value       │
├──────────────┼─────────────┤
│ Iteration    │ 52          │
│ Best Score   │ 0.8765      │
│ Pareto Size  │ 8           │
│ Total Evals  │ 156         │
└──────────────┴─────────────┘

 Status: ACCEPTED
```

---

## Testing Plan

```elixir
defmodule GEPA.ProgressTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  describe "new/1" do
    test "creates with defaults" do
      progress = GEPA.Progress.new()
      assert progress.width == 40
      assert progress.max_calls == nil
    end

    test "accepts custom options" do
      progress = GEPA.Progress.new(width: 60, max_calls: 100)
      assert progress.width == 60
      assert progress.max_calls == 100
    end
  end

  describe "update/2" do
    test "displays progress bar" do
      progress = GEPA.Progress.new(max_calls: 100, color: false)

      output = capture_io(fn ->
        GEPA.Progress.update(progress, %{
          iteration: 50,
          best_score: 0.85,
          pareto_size: 5,
          accepted: true,
          proposal_type: "reflective"
        })
      end)

      assert output =~ "50%"
      assert output =~ "Score: 0.85"
      assert output =~ "Pareto: 5"
    end

    test "shows spinner for indeterminate progress" do
      progress = GEPA.Progress.new(max_calls: nil, color: false)

      output = capture_io(fn ->
        GEPA.Progress.update(progress, %{iteration: 10, best_score: 0.5})
      end)

      assert output =~ "Iter 10"
    end
  end

  describe "finish/2" do
    test "displays summary" do
      progress = GEPA.Progress.new(color: false)
      result = mock_result(iterations: 50, best_score: 0.92)

      output = capture_io(fn ->
        GEPA.Progress.finish(progress, result)
      end)

      assert output =~ "Optimization Complete"
      assert output =~ "Iterations:  50"
      assert output =~ "0.92"
    end
  end

  defp mock_result(opts) do
    %GEPA.Result{
      state: %GEPA.State{i: opts[:iterations]},
      # ... mock best_score accessor ...
    }
  end
end
```

---

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/gepa/progress.ex` | Create | Progress display module |
| `lib/gepa/progress/owl.ex` | Create (optional) | Owl-based rich display |
| `lib/gepa/engine.ex` | Modify | Add progress option handling |
| `lib/gepa.ex` | Modify | Document progress option |
| `test/gepa/progress_test.exs` | Create | Tests |

---

## Optional Dependencies

```elixir
# mix.exs - Optional for rich features
defp deps do
  [
    # ... existing deps ...
    {:owl, "~> 0.11", optional: true}
  ]
end
```
