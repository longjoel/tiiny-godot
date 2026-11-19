# 34 — Scoped approval for assistant authoring and headless verification

Status: Complete.

Feature: Let one deliberate approval cover assistant-created project files and headless project runs for the rest of the current plan or chat turn, instead of prompting for every script and every run.

Sequence: 34

Stream: `integration`

Dependencies: 18, 23, 24, 32. Does not change file hashing, tool execution, or the queue.

Implementation: [plan](../implementation/34-approval-scope.md).

## Why

The assistant currently asks twice for the normal authoring loop:

- once for every `create_gdscript` / `create_and_attach_gdscript` / `create: true` file;
- once for every `run_godot_headless` or `verify_scene_runtime` call.

A plan that creates three scripts and verifies two of them can produce five dialogs. The dialogs are single-use (`Run once`, `Create`, `Overwrite`), so the user cannot say “yes, for this plan” and let the assistant finish a bounded piece of work.

The existing safety model is still useful: project scripts are host code, and file creation is not scene-undoable. The problem is the scope, not the existence, of the consent.

## Scope

- Add an in-memory approval grant scoped to:
  - `plan:<plan_root>` when the current job belongs to a plan;
  - `turn:<turn_id>` otherwise.
- One `authoring` grant covers:
  - `create` file actions from the assistant (`create_gdscript`, `create_and_attach_gdscript`, `write_file` with `create: true`, and plan task file creation);
  - headless project runs (`run_godot_headless`, `verify_scene_runtime`).
- The first prompt explains both effects and offers **Allow once**, **Allow for this plan** (or **this turn**), and **Cancel**.
- A grant survives continuation steps, plan child tasks, and task retries within the same plan. A new plan or a new turn prompts again.
- Grants are session-only. No setting, no project file, no persistence across editor restarts.
- Move, delete, scene discard, and host `run_command` stay individually approved. `run_command` is arbitrary host code and is not covered by the authoring grant.
- If no turn or plan is active, the dialog remains one-shot; no session-wide grant is created.
- `allow_shell_commands` remains the master gate. When it is off, headless runs are unavailable and do not prompt.

## Acceptance criteria

- [x] The first assistant file creation in a plan prompts; a second creation in the same plan does not.
- [x] After the first grant, a headless project run in the same plan does not prompt.
- [x] The grant is shared across plan child tasks and continuation steps with the same `plan_root`, and across continuation steps with the same `turn_id`.
- [x] A different plan or a new turn prompts again.
- [x] Cancel records no grant and the action is denied.
- [x] Move, delete, scene discard, and `run_command` still prompt individually and are not covered by the authoring grant.
- [x] `allow_shell_commands = false` still disables headless runs without a dialog.
- [x] Focused workspace, transaction, selection, runtime, smoke, and Jobs suites rerun on the final build.
- [x] Build recorded with no build left running.

## Evidence

- Editor fixture uses a fake chat with a counting `_approval_dialog` to prove one prompt per plan, no prompt for the second create or the headless run, and a fresh prompt for a new plan.
- Editor fixture verifies that a turn-scoped grant does not leak into another turn.
- Editor fixture verifies that `move` and `delete` are not covered by the authoring grant.
- Workspace pure/editor, transaction, 20-case selection, runtime verification, and editor smoke (13) passed on the final build; full Jobs passed 66 modes. Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:31.72`. No build remains running.
