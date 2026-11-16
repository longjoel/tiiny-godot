# 15 — First-class script and behavior workflow

Status: Accepted. `attach_script` and explicit `save_edited_scene` are implemented; deterministic attachment/undo/save/reload tests pass, and script behavior is live-tested through spin/velocity edits. See [acceptance evidence](../evidence/15-acceptance.md).

Feature: Script behavior, attachment, and explicit scene saving

Sequence: 15

Stream: `workspace`

Dependencies: 07, 08, 14

Implementation: [plan](../implementation/15-script-behavior.md).

## Scope

Treat gameplay behavior as a supported primary path, not a fallback. Movement, spin, bounce response, jumping, camera follow, door logic, input handling, and similar behavior belong in GDScript.

Extend the existing read/edit/create script tools with native script attachment and an explicit save operation. Do not pretend these are missing native editor recipes.

## Acceptance criteria

- [x] Attach an existing `.gd` script to an owned scene node in one undo action; validate the script resource, target, ownership, and instanced-scene boundary.
- [x] Create a new script and attach it to a new or existing node without partial state when validation fails; file creation and scene attachment report their separate effects honestly.
- [x] Save the edited scene only through an explicit tool call; report the saved path, dirty state, and that no undo entry represents the file write.
- [x] Behavior prompts (spin, bounce, jump, camera follow, door, input) complete through the script path and are not counted as missing native tools.
- [x] Script edits remain hash-guarded, parse-validated, bounded, and non-overwriting.
- [x] Deterministic fixtures cover attachment, create-and-attach, save/reopen, stale scene, unowned/instanced targets, non-GDScript rejection, and undo/redo boundaries.
- [x] A live behavior batch records the script path, tool trace, and final response.

## Concrete scenarios

Add WS-17: “Implement gameplay behavior through a script” and WS-18: “Save the edited scene explicitly” to [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md).

## Evidence and handoff

Accepted. `attach_script` is part of `apply_editor_transaction`; `save_edited_scene` is a separate explicit file tool. Fixture covers attach/undo/redo/save/reload; live spin/velocity script edits remain the behavior evidence. Catalog reclassification follows in story 16. See [acceptance evidence](../evidence/15-acceptance.md).
