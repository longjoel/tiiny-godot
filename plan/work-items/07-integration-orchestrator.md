# 07 — Workspace-first prompt and tool orchestration

Status: Accepted. The unified registry, schema/availability layer, structured executor, prompt assembly, action ledger, chat dispatch, and recipe-first integration are implemented and tested. One real Ornith run completed and undid the collision-shape recipe. See [acceptance evidence](../evidence/07-acceptance.md).

Feature: Workspace-first prompt and tool orchestration

Sequence: 07

Stream: `integration`

Dependencies: 02, 03, 05, 06

Implementation: [plan](../implementation/07-orchestrator.md). Visuals: [tool orchestration diagrams](../mockups/07-tool-orchestration-diagrams.md).

## Scope

Use the shared job manager from item 02 for long-running work, dependencies, state, and logs. Extend its worker interfaces rather than introducing another queue.

Coordinate implemented Godot tools through the coding model with structured results and bounded multi-step execution.

## Acceptance criteria

- [x] The base prompt prefers native workspace operations and explains GDScript fallback; user extras and project context have distinct roles.
- [x] Tool schemas describe implemented inputs/outputs; availability reflects current capabilities.
- [x] Malformed arguments, unknown tools, duplicate/multiple calls, and execution limits are handled deterministically.
- [x] Tool outputs return to the model with correct call identifiers; success claims match actual executor results.
- [x] An end-to-end macro completes with a real Tiiny coding model and can be undone in the editor.
- [x] Conversation errors and cancellation do not corrupt subsequent requests or conceal completed partial actions.

## Concrete scenarios

Use WS-13, WS-14, WS-15, DEV-03 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Accepted. Implementation: `editor/tiiny/tools/registry.gd`, injected registry in the chat dock, structured chat dispatcher and ledger, workspace-first prompt/availability, and recipe-first execution. Final build `da3b7c67a` (PID 816681) passed the transaction/registry/chat fixture, 11-stage editor smoke, all 27 Jobs modes, workspace inspector, and a live Ornith recipe run with undo and unchanged residency. See [acceptance evidence](../evidence/07-acceptance.md). Story 08 can build richer action UI on the ledger.
