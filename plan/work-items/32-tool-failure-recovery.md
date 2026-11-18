# 32 — Recoverable tool failures and actionable validation errors

Status: Complete.

Feature: Let a recoverable tool failure (stale scene) take its documented retry, and return the real parser line and message for every rejected GDScript candidate, so the model can correct the script instead of guessing.

Sequence: 32

Stream: `integration`

Dependencies: 23, 25, 31. Extends the chat tool loop and script validation. It does not change the plan-tree contract, add a queue, or relax the read-only guard.

Implementation: [plan](../implementation/32-tool-failure-recovery.md).

## Why

Two traces showed the model spending calls on failures that already had a clear recovery:

- Job `72c8722b02a5-00000014` submitted a three-task plan. After the deferred join, the model called `get_scene_tree` with `max_depth: 6`; the tool returned `stale_scene`, and the loop refreshed `turn_scene_context`. The model immediately repeated the identical call, but the repeat guard treated it as a repeated call, wrapped up the turn, and returned the generic "This exact tool call already ran" result. The one retry the stale-scene result asks for was never executed.
- Job `72c8722b02a5-00000035` ran `replace_in_gdscript` and got only "The edited script failed validation; the file was not changed." The model had no line or parser message, guessed at the cause, and needed several more `check_gdscript` rounds (`move_lerp`, `move_and_slide(velocity)`, `velocity.move_and_slide()`) before it recovered.

The engine still prints its own `SCRIPT ERROR` parser diagnostics when an in-memory candidate fails to compile. Those are expected validation output, not an editor crash, and the tool result is the authoritative message.

## Scope

- **Stale-scene retry:** when a tool result is `stale_scene`, erase that call signature and the last-signature marker after the context has been refreshed. The model may execute the same inspection once more against the fresh revision. Other signature counts are left alone, and the existing task budget remains the outer bound.
- **Actionable validation:** `_validate_script` and the dock's compile paths return the parser line, kind, and message for:
  - `write_file`, `create_file`, and `apply_patch` through the workspace provider;
  - `replace_in_gdscript`;
  - `create_gdscript`;
  - `create_and_attach_gdscript`.
- **Shared detail helper:** the dock uses one `_script_error_detail` function, so all script-creating paths report the same shape. The workspace provider includes `data.line` and `data.kind` for fixtures and traces.
- The filename and edit-approval behavior are unchanged; a rejected candidate still writes nothing.

## Acceptance criteria

- [x] A stale `get_scene_tree` result followed by the identical call executes the retry and returns a successful inspection; it is not reported as `repeated_call`.
- [x] A successful edit or a stale refresh does not weaken the task read-only guard.
- [x] Invalid `write_file` and `apply_patch` results report the parser line and message, and leave the file unchanged.
- [x] Invalid `replace_in_gdscript` reports the parser line and message instead of a generic validation error, and leaves the file unchanged.
- [x] The shared detail path is covered by the editor fixture's `replace_in_gdscript` case.
- [x] Focused workspace, transaction, selection, runtime, smoke, and Jobs suites rerun on the final build.
- [x] Build recorded with no build left running.

## Evidence

- `editor_workspace_tools.gd` sets a stale scene revision, calls `get_scene_tree`, asserts the first result is `stale_scene`, calls it again with identical arguments, and asserts the second result is successful and not `repeated_call`.
- `test_workspace_tools.gd` asserts invalid `write_file` and `apply_patch` results include the parse line and that the original file is unchanged.
- `editor_workspace_tools.gd` asserts `replace_in_gdscript` returns "failed validation at line 4" plus the parser message and leaves the file unchanged.
- Workspace pure/editor, transaction, 20-case selection, runtime verification, and editor smoke (13) passed on the final build; full Jobs passed 66 modes. The first smoke attempt hit the known headless resource-dialog crash; the rerun passed 13. Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:31.70`. No build remains running.
