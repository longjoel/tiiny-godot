# 08 — Chat action history, previews, and recovery

Status: Accepted. Action cards, navigation, guarded undo, retry, file-change labeling, queued-job links, 320px layout, and running-scene behavior are implemented and tested. See [acceptance evidence](../evidence/08-acceptance.md).

Feature: Chat action history, previews, and recovery

Sequence: 08

Stream: `ui`

Dependencies: 02, 07

Implementation: [plan](../implementation/08-chat-actions.md).

## Scope

Use the shared job manager from item 02 for long-running work, dependencies, state, and logs. Extend its worker interfaces rather than introducing another queue.

Make workspace operations understandable from the side dock, with visible targets, results, and recovery.

## Acceptance criteria

- [x] Chat shows meaningful queued/running/completed/failed actions with affected nodes or resources.
- [x] Users can inspect proposed changes when appropriate and navigate to the resulting object or asset.
- [x] Undo availability matches actual Godot undo support; file creation is not falsely shown as scene-undoable.
- [x] Long operations remain responsive; cancel semantics explain what stopped and what already completed.
- [x] A failed step reports partial work clearly and provides a usable retry or recovery path.
- [x] Test the dock in a small editor window and while running a scene.

## Concrete scenarios

Use WS-09, WS-13, WS-14 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Accepted. Implementation: dock action-card rendering and navigation in `editor/tiiny_ai_dock_source.h`, guarded undo using transaction `action_name`, Jobs `show_job`, retry and file-change labeling. Final binary `fe5ab2a84` passed the transaction/action-card fixture, 11-stage editor smoke, and all 27 Jobs modes. See [acceptance evidence](../evidence/08-acceptance.md).
