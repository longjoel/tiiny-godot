# 08 — Chat action history, previews, and recovery

Status: Queued

Feature: Chat action history, previews, and recovery

Sequence: 08

Stream: `ui`

Dependencies: 02, 07

## Scope

Use the shared job manager from item 02 for long-running work, dependencies, state, and logs. Extend its worker interfaces rather than introducing another queue.

Make workspace operations understandable from the side dock, with visible targets, results, and recovery.

## Acceptance criteria

- [ ] Chat shows meaningful queued/running/completed/failed actions with affected nodes or resources.
- [ ] Users can inspect proposed changes when appropriate and navigate to the resulting object or asset.
- [ ] Undo availability matches actual Godot undo support; file creation is not falsely shown as scene-undoable.
- [ ] Long operations remain responsive; cancel semantics explain what stopped and what already completed.
- [ ] A failed step reports partial work clearly and provides a usable retry or recovery path.
- [ ] Test the dock in a small editor window and while running a scene.

## Concrete scenarios

Use WS-09, WS-13, WS-14 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Pending. Record changed files, validation commands and results, editor/device observations, remaining limitations, and the next action. Update [STATUS.md](../STATUS.md) when handing off.
