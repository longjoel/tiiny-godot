# 07 — Workspace-first prompt and tool orchestration

Status: Planning complete; implementation is gated on stories 02, 03, 05, and 06. Slices A–C can be built against fake tools before 05/06 land.

Feature: Workspace-first prompt and tool orchestration

Sequence: 07

Stream: `integration`

Dependencies: 02, 03, 05, 06

Implementation: [plan](../implementation/07-orchestrator.md). Visuals: [tool orchestration diagrams](../mockups/07-tool-orchestration-diagrams.md).

## Scope

Use the shared job manager from item 02 for long-running work, dependencies, state, and logs. Extend its worker interfaces rather than introducing another queue.

Coordinate implemented Godot tools through the coding model with structured results and bounded multi-step execution.

## Acceptance criteria

- [ ] The base prompt prefers native workspace operations and explains GDScript fallback; user extras and project context have distinct roles.
- [ ] Tool schemas describe implemented inputs/outputs; availability reflects current capabilities.
- [ ] Malformed arguments, unknown tools, duplicate/multiple calls, and execution limits are handled deterministically.
- [ ] Tool outputs return to the model with correct call identifiers; success claims match actual executor results.
- [ ] An end-to-end macro completes with a real Tiiny coding model and can be undone in the editor.
- [ ] Conversation errors and cancellation do not corrupt subsequent requests or conceal completed partial actions.

## Concrete scenarios

Use WS-13, WS-14, WS-15, DEV-03 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Pending. Record changed files, validation commands and results, editor/device observations, remaining limitations, and the next action. Update [STATUS.md](../STATUS.md) when handing off.
