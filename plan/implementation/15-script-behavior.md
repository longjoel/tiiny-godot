# Story 15 implementation plan — first-class script and behavior workflow

Status: Accepted. Attach/save and behavior evidence implemented; see acceptance evidence.

Parent: [15 — First-class script and behavior workflow](../work-items/15-script-behavior.md).

## Goal

Make gameplay behavior a supported primary path. Do not force movement, spin, bounce, jump, camera follow, doors, or input into native editor recipes.

## Tools

- `attach_script(path, node_path)` — attach an existing validated `.gd` to an owned scene node; one undo action.
- `create_node_with_script` or a creator that accepts `script_path` — create a node and attach a new/existing script atomically where practical.
- `save_edited_scene()` — explicit scene save; reports path and dirty state. No undo entry for the file write.
- Existing `read_project_file`, `replace_in_gdscript`, `create_gdscript` remain the behavior-edit primitives.

## Rules

- Script must exist, load as `GDScript`, parse successfully, and be a `res://` path without traversal.
- Target must exist, be owned by the edited scene, and not be an instanced-child target.
- Attachment records one undo action restoring the previous script.
- Creating a new script and attaching are separate effects; if attachment fails, report the file created and scene unchanged rather than claiming an atomic rollback.
- Save only on explicit request; never auto-save.
- Behavior prompts are classified as script/behavior work and reported that way.

## Slices

1. Attach existing script with validation/undo/tests.
2. Create-and-attach flow with truthful partial-effect reporting.
3. Explicit scene save with save/reopen/stale tests.
4. Behavior catalog reclassification and live batch handoff to story 16.

## Gates

- No script path traversal, overwrite, or parser-invalid attach.
- One undo for attachment; file writes are visibly non-scene-undoable.
- Save is explicit and reports the actual path.
- Behavior tasks are no longer counted as missing native editor tools.

All gates verified; see [acceptance evidence](../evidence/15-acceptance.md).

## Handoff

Accepted. `attach_script` and `save_edited_scene` pass deterministic attach/undo/save/reload. Live behavior evidence remains the velocity/spin script edits; a live attach/save model turn was not recorded.
