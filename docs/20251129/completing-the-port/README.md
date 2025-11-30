# Completing the GEPA Elixir Port

> **Date**: 2025-11-29
> **Status**: Planning Document
> **Priority**: Medium-High

This document outlines the remaining work to achieve full feature parity with the Python GEPA implementation, with a focus on the partially ported components.

## Table of Contents

1. [Overview](#overview)
2. [Integration Architecture](#integration-architecture)
3. [Partially Ported Components](#partially-ported-components)
4. [Implementation Plans](#implementation-plans)
5. [Integration with Ecosystem](#integration-with-ecosystem)

---

## Overview

### Current Status

| Category | Python | Elixir | Parity |
|----------|--------|--------|--------|
| Core Engine | 100% | 100% | ✅ |
| Proposers | 100% | 100% | ✅ |
| Strategies | 100% | ~85% | ⚠️ |
| Stop Conditions | 100% | ~70% | ⚠️ |
| Observability | 100% | ~30% | ❌ |
| Adapters | 5 adapters | 1 adapter | ❌ |

### Gaps Summary

| Component | Python | Elixir Status | Gap |
|-----------|--------|---------------|-----|
| **Instruction Proposal** | `instruction_proposal.py` (custom templates) | Hardcoded in Reflective | No custom prompt templates |
| **Experiment Tracking** | W&B + MLflow integration | Telemetry wired, not implemented | No W&B/MLflow export |
| **Epsilon-Greedy Selector** | Implemented | Missing | Not critical |
| **Progress Logging** | Rich logging | Basic | No fancy progress bars |

---

## Integration Architecture

### Can gepa_ex Be Used as a Dependency?

**Yes, with caveats.** The architecture is modular enough for integration:

```
┌─────────────────────────────────────────────────────────────┐
│                    Your Application                          │
│  (ds_ex, CrucibleFramework, or custom)                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Integration Layer (you write this)                 │    │
│  │  • Adapter implementation                           │    │
│  │  • DataLoader wrapper                               │    │
│  │  • Result transformation                            │    │
│  └─────────────────────────────────────────────────────┘    │
│                         │                                    │
│                         ▼                                    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  gepa_ex (dependency)                               │    │
│  │  • GEPA.optimize/1 - main entry                     │    │
│  │  • GEPA.Adapter behaviour - your integration point  │    │
│  │  • GEPA.Result - optimization results               │    │
│  │  • GEPA.State - Pareto front, genealogy             │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Key Integration Points

1. **`GEPA.Adapter` behaviour** - Primary extension point
   - Implement `evaluate/3` to run your system
   - Implement `make_reflective_dataset/3` for feedback extraction
   - Optionally implement `propose_new_texts/3` for custom proposal

2. **`GEPA.DataLoader` behaviour** - Data abstraction
   - Wrap your datasets (Crucible, ds_ex, custom)
   - Provides `all_ids/1`, `fetch/2`, `size/1`

3. **`GEPA.StopCondition` behaviour** - Termination control
   - Use built-in: MaxCalls, Timeout, NoImprovement
   - Or implement custom conditions

4. **`GEPA.Result`** - Results access
   - `best_candidate/1`, `best_score/1`, `best_idx/1`
   - Access to full Pareto front via state

### Example Integration with ds_ex

```elixir
defmodule MyApp.GEPADSPExAdapter do
  @behaviour GEPA.Adapter

  defstruct [:program, :metric_fn, :client]

  def new(program, metric_fn, client) do
    %__MODULE__{program: program, metric_fn: metric_fn, client: client}
  end

  @impl true
  def evaluate(%__MODULE__{} = adapter, batch, candidate, capture_traces) do
    # Update program with candidate instructions
    program = update_program_instructions(adapter.program, candidate)

    # Run ds_ex evaluation
    results = Enum.map(batch, fn example ->
      {:ok, output} = DSPEx.Program.forward(program, example.inputs)
      score = adapter.metric_fn.(example, output)
      {output, score}
    end)

    outputs = Enum.map(results, &elem(&1, 0))
    scores = Enum.map(results, &elem(&1, 1))

    {:ok, %GEPA.EvaluationBatch{
      outputs: outputs,
      scores: scores,
      trajectories: if(capture_traces, do: build_traces(results), else: nil)
    }}
  end

  @impl true
  def make_reflective_dataset(%__MODULE__{}, _candidate, eval_batch, components) do
    # Extract feedback from ds_ex traces
    dataset = for component <- components, into: %{} do
      feedback = extract_component_feedback(eval_batch, component)
      {component, feedback}
    end
    {:ok, dataset}
  end
end
```

### Example Integration with CrucibleFramework

```elixir
defmodule Crucible.Stage.GEPAOptimize do
  @behaviour Crucible.Stage

  @impl true
  def run(%Crucible.Context{} = ctx, opts) do
    # Build adapter from context
    adapter = build_adapter_from_context(ctx, opts)

    # Run GEPA optimization
    {:ok, result} = GEPA.optimize(
      seed_candidate: opts[:seed_candidate],
      trainset: ctx.dataset.train,
      valset: ctx.dataset.val,
      adapter: adapter,
      max_metric_calls: opts[:max_metric_calls] || 100
    )

    # Update context with results
    ctx = ctx
      |> Crucible.Context.put_metric(:gepa_best_score, GEPA.Result.best_score(result))
      |> Crucible.Context.put_metric(:gepa_iterations, result.state.i)
      |> Crucible.Context.assign(:gepa_result, result)

    {:ok, ctx}
  end
end
```

---

## Partially Ported Components

### 1. Instruction Proposal (Custom Templates)

**Current State**: Hardcoded improvement logic in `GEPA.Proposer.Reflective`

**Python Implementation** (`instruction_proposal.py`):
- Configurable prompt templates
- Placeholder validation
- Custom formatting options
- Multi-component joint proposals

**Gap**: No way to customize the LLM prompt used for proposing improvements.

**See**: [01-instruction-proposal.md](./01-instruction-proposal.md)

---

### 2. Experiment Tracking (W&B + MLflow)

**Current State**: Telemetry events wired but no exporters

**Python Implementation**:
- Weights & Biases integration
- MLflow integration
- Automatic metric logging
- Artifact tracking
- Hyperparameter logging

**Gap**: No way to export optimization runs to experiment tracking platforms.

**See**: [02-experiment-tracking.md](./02-experiment-tracking.md)

---

### 3. Epsilon-Greedy Selector

**Current State**: Not implemented

**Python Implementation**:
- Epsilon probability: random candidate
- 1-epsilon probability: best candidate
- Configurable epsilon decay

**Gap**: Missing exploration/exploitation balance option.

**See**: [03-epsilon-greedy-selector.md](./03-epsilon-greedy-selector.md)

---

### 4. Progress Logging

**Current State**: Basic Logger calls

**Python Implementation**:
- Rich progress bars
- Real-time metric display
- Color-coded status
- ETA estimation

**Gap**: No user-friendly progress visualization.

**See**: [04-progress-logging.md](./04-progress-logging.md)

---

## Implementation Plans

Each component has a dedicated implementation plan:

| Document | Component | Estimated Effort | Priority |
|----------|-----------|------------------|----------|
| [01-instruction-proposal.md](./01-instruction-proposal.md) | Custom Templates | 4-6 hours | High |
| [02-experiment-tracking.md](./02-experiment-tracking.md) | W&B/MLflow | 8-12 hours | Medium |
| [03-epsilon-greedy-selector.md](./03-epsilon-greedy-selector.md) | Epsilon-Greedy | 1-2 hours | Low |
| [04-progress-logging.md](./04-progress-logging.md) | Rich Progress | 2-4 hours | Low |

---

## Integration with Ecosystem

### Using gepa_ex with Your Stack

```elixir
# In mix.exs
defp deps do
  [
    {:gepa_ex, "~> 0.1.1"},
    # or from path during development:
    {:gepa_ex, path: "../gepa_ex"}
  ]
end
```

### Recommended Integration Patterns

#### Pattern 1: GEPA as Optimization Backend

Use GEPA's Pareto optimization while keeping your own evaluation:

```elixir
# Your adapter wraps your system
adapter = MySystem.GEPAAdapter.new(my_program, my_metric)

# GEPA handles optimization loop
{:ok, result} = GEPA.optimize(
  seed_candidate: initial_prompts,
  trainset: train_data,
  valset: val_data,
  adapter: adapter,
  max_metric_calls: 200
)

# Use optimized prompts in your system
optimized = GEPA.Result.best_candidate(result)
```

#### Pattern 2: GEPA as Crucible Stage

Integrate GEPA into Crucible pipelines:

```elixir
experiment = %CrucibleIR.Experiment{
  pipeline: [
    %StageDef{name: :data_load},
    %StageDef{name: :gepa_optimize, options: %{max_calls: 100}},
    %StageDef{name: :bench},
    %StageDef{name: :report}
  ]
}
```

#### Pattern 3: GEPA Algorithms in ds_ex

Extract GEPA's Pareto utilities for ds_ex:

```elixir
# Use GEPA's Pareto front management
alias GEPA.Utils.Pareto

# In your teleprompter
defmodule DSPEx.Teleprompter.ParetoSIMBA do
  def select_candidate(candidates, scores_matrix) do
    pareto_front = Pareto.find_pareto_front(candidates, scores_matrix)
    Pareto.select_from_pareto_front(pareto_front)
  end
end
```

---

## Next Steps

1. **Immediate**: Review implementation plans for each component
2. **Short-term**: Implement instruction proposal templates (highest value)
3. **Medium-term**: Add experiment tracking for production use
4. **Long-term**: Consider merging GEPA algorithms into ds_ex

---

## Related Documents

- [../PROJECT_SUMMARY.md](../../PROJECT_SUMMARY.md) - Overall project status
- [../TECHNICAL_DESIGN.md](../../TECHNICAL_DESIGN.md) - Architecture details
- [Python GEPA](../../../gepa/) - Reference implementation
