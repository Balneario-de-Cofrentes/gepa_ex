# Telemetry-First Experiment Tracking (Generalized W&B/MLflow)

> Date: 2025-11-29  
> Status: Finalized design for Elixir port  
> Scope: Replace the Python-style W&B/MLflow coupling with an Elixir-native, telemetry-only contract that Crucible (or any host) can extend via pluggable connectors such as `crucible_wb` and `crucible_mlflow`.

## Findings From Review

- Python GEPA hard-couples to W&B/MLflow: `ExperimentTracker` imports both libraries directly and fans out `log_metrics/2`, `start_run/0`, `end_run/0`. All metrics are pushed as a flat dict (numbers and sometimes strings) with a `step`. There is no abstraction layer.
- Metrics logged in Python span: iteration bookkeeping, subsample sums, reflective proposals (including `new_instruction_*` strings), valset Pareto aggregates, and base program scores. Artifacts/params/hparams are not modeled separately.
- Elixir `gepa_ex` currently: telemetry dependency is present but unused; the existing `02-experiment-tracking.md` drafts handlers that shell out to Python, which violates the Elixir-native requirement.
- Desired state: GEPA emits well-defined telemetry events only. External connectors translate events to W&B/MLflow (or anything else) without any Python dependency or tracker-specific code in `gepa_ex`.

## Goals and Non-Goals

- Goals
  - Elixir-native observability: only `:telemetry` in `gepa_ex`.
  - Stable event schema that captures the full Python metric surface.
  - Simple to build connectors (`crucible_wb`, `crucible_mlflow`, Prometheus, OpenTelemetry, console) without touching GEPA core.
  - Preserve ability to log richer structures (Pareto fronts, instruction text) as params/artifacts while keeping numeric metrics clean.
- Non-Goals
  - No direct W&B/MLflow deps or Python shims in `gepa_ex`.
  - No baked-in assumption that W&B/MLflow are the only trackers.
  - No UI/dashboard in this layer (only signals).

## Architecture (Telemetry Spine)

```
gepa_ex (pure Elixir)
└─ GEPA.Engine / proposers emit :telemetry events (schema below)
   └─ Optional in-repo console handler (progress-only, no third-party calls)

Integration surface (out of tree)
└─ Crucible attaches handlers:
   ├─ crucible_wb: translate events -> W&B HTTP/API
   ├─ crucible_mlflow: translate events -> MLflow REST
   ├─ other sinks: OpenTelemetry, Prometheus, file, LiveView, etc.
```

## Event Contract (authoritative)

All events follow `:telemetry.execute(event_name, measurements, metadata)`. Measurements MUST be numeric/boolean-only; structured/textual data goes into metadata and can be serialized by connectors as params or artifacts. Every event includes `:iteration` when applicable to allow `step` mapping. When no handlers are attached, events are fire-and-forget and effectively zero cost.

- `[:gepa, :run, :start]`
  - Measurements: `%{system_time: native_time}`
  - Metadata: `%{config: sanitized_config, schema_version: "1.0.0"}` (drop adapter instances, replace datasets with `"[DataLoader]"`, keep stop-condition settings)
- `[:gepa, :run, :stop]`
  - Measurements: `%{duration_ms, iterations, total_metric_calls, valset_size, pareto_front_size, best_score}`
  - Metadata: `%{best_idx, best_candidate: optional, result_summary: optional map}`
- `[:gepa, :iteration, :start]` (emitted once per loop before proposal work)
  - Measurements: `%{iteration, system_time: native_time}`
  - Metadata: `%{selected_program_candidate}` (captures Python’s early log of selected candidate for timing/step parity)
- `[:gepa, :iteration, :stop]` (emitted once per loop)
  - Measurements: `%{
      iteration,
      proposal_accepted: boolean,
      best_score,
      best_score_delta,
      pareto_front_size,
      subsample_before_sum,
      subsample_after_sum,
      total_metric_calls,
      iteration_duration_ms
    }`
  - Metadata: `%{proposal_type, selected_program_candidate, parent_program_ids, subsample_ids}`
- `[:gepa, :proposal, :generated]` (reflective or merge)
  - Measurements: `%{iteration, subsample_before_sum, subsample_after_sum, subsample_delta}`
  - Metadata: `%{tag, new_instructions: map(component => text), trajectories?: boolean}`
- `[:gepa, :proposal, :decision]` (accepted or rejected decision point)
  - Measurements: `%{iteration, accepted: boolean, subsample_delta}`
  - Metadata: `%{tag, reason?: :not_improved | :error | :schedule_skip | :accepted, parent_program_ids, selected_program_candidate}`
- `[:gepa, :valset, :update]` (after full eval/new program)
  - Measurements: `%{
      iteration,
      val_program_average,
      val_coverage,
      valset_pareto_front_agg,
      best_valset_agg_score
    }`
  - Metadata: `%{
      new_program_idx,
      linear_pareto_front_program_idx,
      pareto_front_programs,        # map(val_idx => [program_idx])
      valset_scores_new_program?,   # optional map for artifact logging
      pareto_front_scores?          # optional map for artifact logging
    }`
- `[:gepa, :evaluation, :batch]` (train/val batch evals)
  - Measurements: `%{iteration, batch_size, duration_ms, mean_score}`
  - Metadata: `%{scores, dataset: :train | :val, candidate_idx?, candidate_tag?}`
- `[:gepa, :baseline, :computed]` (initial seed program full-val eval)
  - Measurements: `%{iteration: 0, base_program_full_valset_score, base_program_val_coverage}`
  - Metadata: `%{valset_size}`

Notes:
- This covers all Python metrics (subsample sums, candidate selection, new_program_idx, Pareto aggregates, new_instruction text) without forcing tracker-specific code paths. Instruction text now lives in `new_instructions` metadata on `:proposal, :generated`; no separate text-log escape hatch is needed.
- Connectors should treat metadata blobs as artifacts/params, not metrics.

## Connector Expectations (Crucible or others)

- Attach to the above events with a single handler ID per connector.
- Maintain per-run context (run_id, project, tags) inside connector state; GEPA never stores it.
- Mapping guidance:
  - W&B: `measurements` → `wandb.log(..., step=iteration)`, metadata text → `wandb.config.update/1` or `wandb.run.log_text`/artifact.
  - MLflow: numeric measurements → `log_metric(..., step=iteration)`, metadata text → `log_param` or `log_dict` artifact, structured maps → `log_artifact` JSON.
  - Console: emit a concise progress line on `:iteration, :stop`; print summaries on `:run, :start/stop`.
- Error isolation: connector failures must not crash GEPA; handlers should rescue and log.

## Implementation Plan (gepa_ex)

1) Add `GEPA.Telemetry` module with helpers `emit_run_start/1`, `emit_run_stop/2`, `emit_iteration_start/2`, `emit_iteration_stop/2`, `emit_proposal_generated/2`, `emit_proposal_decision/2`, `emit_valset_update/3`, `emit_evaluation_batch/3`, `emit_baseline/2`, and `schema_version/0` returning `"1.0.0"`.  
2) Instrument `GEPA.Engine`, `GEPA.Proposer.Reflective`, `GEPA.Proposer.Merge`, and state updates to call the helpers at the same points where Python calls `experiment_tracker.log_metrics/2` (including rejected proposals).  
3) Ship a lightweight `GEPA.Tracking.Console` handler (no third-party deps) for local visibility.  
4) Document the event schema in hexdocs and `docs/` (this file).  
5) Add tests that assert events fire with the expected measurement/metadata keys for: run start/stop, iteration start/stop, proposal decision (accept/reject), valset updates, baseline eval.

## Connector Plan (out of tree)

- `crucible_wb`: pure Elixir client for W&B HTTP API with minimal footprint (auth, run lifecycle, log metrics, log config, upload JSON artifacts).  
- `crucible_mlflow`: pure Elixir MLflow REST client (tracking URI, experiment ID/name, run lifecycle, log_metric, log_param, log_batch, log_artifact).  
- Both connectors:
  - Implement a behaviour `Crucible.Tracking.Handler` (`handle_event/4`) usable across stages (GEPA is one event source among many).
  - Provide `attach/1` to register telemetry handlers and start supervised state (run_id, buffers, retry/backoff).
  - Normalize measurements vs metadata (numbers → metrics; text/structs → params/artifacts).

## Risks and Mitigations

- **String-in-metrics from Python (`new_instruction_*`)**: kept as `new_instructions` metadata on `:proposal, :generated`; connectors log as params or text artifacts, not metrics.  
- **Payload size for Pareto maps**: emit in metadata; connectors should stream as JSON artifact instead of metric spam.  
- **Schema drift**: expose `schema_version/0` in `GEPA.Telemetry`, include it in `:run, :start` metadata, and assert expected keys in tests.  
- **Backpressure**: if connectors buffer, cap queue size and drop with warning rather than blocking GEPA loop.

## Ready-to-Ship Criteria

- No W&B/MLflow/Python references in `gepa_ex` runtime deps or code.  
- Telemetry events present for every place Python previously called `log_metrics/2`.  
- Console handler works and does not crash the run if detached.  
- Connector samples (or tests with a fake handler) demonstrate correct measurement/metadata splitting and step mapping.
