defmodule GEPA.Progress do
  @moduledoc """
  Simple progress display for GEPA optimization.

  Provides terminal-based visualization of optimization progress including:
  - Progress bar with percentage (when max_calls known)
  - Spinner for indeterminate progress
  - Real-time score and Pareto size display
  - ETA estimation
  - Colored status indicators

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

  ## Options

  - `:max_calls` - Maximum number of metric calls (for progress bar)
  - `:width` - Progress bar width in characters (default: 40)
  - `:color` - Enable/disable ANSI colors (default: auto-detect)
  """

  @type t :: %__MODULE__{
          max_calls: pos_integer() | nil,
          width: pos_integer(),
          color: boolean(),
          start_time: integer(),
          last_update: integer()
        }

  defstruct [
    :max_calls,
    :width,
    :color,
    :start_time,
    :last_update
  ]

  # ANSI color codes
  @green "\e[32m"
  @yellow "\e[33m"
  @blue "\e[34m"
  @reset "\e[0m"
  @bold "\e[1m"
  @clear_line "\e[2K\r"

  # Spinner frames for indeterminate progress
  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  @doc """
  Create a new progress tracker.

  ## Options

  - `:max_calls` - Maximum metric calls (enables progress bar)
  - `:width` - Bar width in characters (default: 40)
  - `:color` - Enable colors (default: auto-detect TTY)
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
    IO.puts(colorize(progress, divider, :blue))
    IO.puts(colorize(progress, " GEPA Optimization", :bold))
    IO.puts(colorize(progress, divider, :blue))
    IO.puts("")

    :ok
  end

  @doc """
  Update progress display for an iteration.

  ## Metrics Map

  - `:iteration` - Current iteration number
  - `:best_score` - Best score achieved so far
  - `:pareto_size` - Number of programs on Pareto front
  - `:total_evals` - Total metric evaluations
  - `:accepted` - Whether last proposal was accepted (true/false/nil)
  - `:proposal_type` - Type of proposal ("reflective", "merge", etc.)
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = progress, metrics) do
    iteration = metrics[:iteration] || 0
    best_score = metrics[:best_score] || 0.0
    pareto_size = metrics[:pareto_size] || 1
    total_evals = metrics[:total_evals] || iteration
    accepted = metrics[:accepted]
    proposal_type = metrics[:proposal_type]

    # Build progress bar
    bar = build_bar(progress, total_evals)

    # Build status indicator
    status = build_status(progress, accepted, proposal_type)

    # Build metrics display
    metrics_str = build_metrics(progress, best_score, pareto_size)

    # Build ETA
    eta = build_eta(progress, total_evals)

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
    iterations = result.i

    # New line after progress bar
    IO.puts("")
    IO.puts("")

    divider = String.duplicate("─", progress.width + 30)
    IO.puts(colorize(progress, divider, :green))
    IO.puts(colorize(progress, " ✓ Optimization Complete", :green))
    IO.puts(colorize(progress, divider, :green))
    IO.puts("")
    IO.puts("   Iterations:  #{iterations}")
    IO.puts("   Duration:    #{elapsed_str}")
    IO.puts("   Best Score:  #{colorize(progress, format_score(best_score), :bold)}")
    IO.puts("")

    :ok
  end

  # Private functions

  defp build_bar(%__MODULE__{max_calls: nil, width: _width}, total_evals) do
    # Indeterminate progress (spinner style)
    idx = rem(total_evals, length(@spinner_frames))
    char = Enum.at(@spinner_frames, idx)
    "[#{char}] Evals: #{total_evals}"
  end

  defp build_bar(%__MODULE__{max_calls: max, width: width} = progress, total_evals) do
    bar_width = min(width, 40)
    percentage = min(total_evals / max, 1.0)
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
    score_str = format_score(best_score)

    [
      "Score: #{colorize(progress, score_str, :bold)}",
      "Pareto: #{pareto_size}"
    ]
    |> Enum.join(" │ ")
  end

  defp build_eta(%__MODULE__{max_calls: nil}, _total_evals), do: ""

  defp build_eta(%__MODULE__{max_calls: max, start_time: start}, total_evals)
       when total_evals > 0 do
    elapsed = System.monotonic_time(:millisecond) - start

    # Guard against division by zero when test runs too fast
    if elapsed > 0 do
      # evals per ms
      rate = total_evals / elapsed
      remaining = max - total_evals

      if rate > 0 and remaining > 0 do
        eta_ms = remaining / rate
        "ETA: #{format_duration(round(eta_ms))}"
      else
        ""
      end
    else
      ""
    end
  end

  defp build_eta(_progress, _total_evals), do: ""

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

  defp format_score(score) when is_float(score) do
    Float.round(score, 4) |> to_string()
  end

  defp format_score(score), do: to_string(score)

  defp colorize(%__MODULE__{color: false}, text, _color), do: to_string(text)
  defp colorize(%__MODULE__{color: true}, text, :green), do: "#{@green}#{text}#{@reset}"
  defp colorize(%__MODULE__{color: true}, text, :yellow), do: "#{@yellow}#{text}#{@reset}"
  defp colorize(%__MODULE__{color: true}, text, :blue), do: "#{@blue}#{text}#{@reset}"
  defp colorize(%__MODULE__{color: true}, text, :bold), do: "#{@bold}#{text}#{@reset}"
end
