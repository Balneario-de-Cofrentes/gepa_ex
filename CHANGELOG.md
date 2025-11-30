# Changelog

# Changelog

## v0.1.2 · 2025-11-29

### Added
- `GEPA.Progress` module - terminal progress display with ANSI colors, progress bar, spinner, ETA estimation
- `progress` option to `GEPA.optimize/1` - enable rich terminal output during optimization (`true` or `[width: 60, color: true]`)
- `GEPA.Strategies.CandidateSelector.EpsilonGreedy` with configurable epsilon/decay/minimum and reset helpers
- Candidate selector behaviour now supports stateful selectors that return updated structs each selection
- Reflective proposer and engine propagate updated selector state so epsilon decay persists across iterations
- `GEPA.Telemetry` event schema with lifecycle/iteration/proposal/evaluation emitters for tracker integrations
- `GEPA.Proposer.InstructionProposal` module - LLM-based instruction proposal with configurable templates
- `reflection_llm` option to `GEPA.optimize/1` - enables LLM-powered instruction improvement
- `proposal_template` option to `GEPA.optimize/1` - custom prompt templates for instruction proposal
- `instruction_proposal` field to `GEPA.Proposer.Reflective` struct
- `GEPA.SupertesterCase` test harness and `supertester` dependency for fully isolated async test runs
- Comprehensive test coverage for instruction proposal feature
- Integration tests for the full instruction proposal pipeline
- Documentation plans for completing the port (docs/20251129/completing-the-port/) and telemetry-first tracking (docs/20251129/experiment-tracking-generalized/)

### Changed
- `GEPA.Engine.run_iteration/2` now returns `{:cont, state, config, accepted?, proposal_type}` tuple for progress tracking
- `GEPA.Proposer.Reflective` now uses LLM-based improvement when `instruction_proposal` is configured
- `GEPA.Engine` passes `instruction_proposal` configuration to the reflective proposer and emits telemetry at run/iteration boundaries
- Fallback to simple "[Optimized]" marker only when no LLM is configured (testing mode)

## v0.1.1 · 2025-11-29

### Changed
- Release v0.1.1 - documentation cleanup and tagging

## v0.1.0 · 2025-10-29

- Initial release of GEPA for Elixir. Core optimization engine, reflective proposer, Pareto state management, batch sampling, adapters, and production documentation delivered.
