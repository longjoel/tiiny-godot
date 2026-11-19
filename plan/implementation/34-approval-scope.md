# Story 34 implementation plan — scoped approval

Status: Complete; covered by the editor fixture.

Parent: [34 — Scoped approval for assistant authoring and headless verification](../work-items/34-approval-scope.md).

## Decision

Keep approvals for project authoring and headless verification, but make the consent scope explicit. A plan or chat turn is a bounded unit the user can evaluate once. Arbitrary shell commands and destructive file operations stay per-action.

The grant is in memory only. It is not a setting and never survives an editor restart. A user who wants to stop the assistant can still cancel the dialog or stop the job.

## State

In the dock:

```gdscript
var approval_grants := {}
var approval_scope_granted := false

func _approval_scope_key() -> String:
    var plan_root := str(queued_chat_parameters.get("plan_root", ""))
    if not plan_root.is_empty():
        return "plan:" + plan_root
    if not turn_id.is_empty():
        return "turn:" + turn_id
    return ""

func _approval_granted(kind: String) -> bool:
    var scope := _approval_scope_key()
    return not scope.is_empty() and bool(approval_grants.get(kind + "|" + scope, false))

func _grant_approval(kind: String) -> void:
    var scope := _approval_scope_key()
    if not scope.is_empty():
        approval_grants[kind + "|" + scope] = true
```

`queued_chat_parameters["plan_root"]` is present on every plan child job. `turn_id` is restored with the continuation state, so a grant follows a turn across model rounds.

## Dialog

`_approval_dialog` gains an optional scope action:

```gdscript
func _approval_dialog(title: String, text: String, ok_text: String, scope_text := "") -> bool
```

- OK button: **Allow once**.
- Optional right button: **Allow for this plan** or **Allow for this turn**.
- Cancel: no grant.
- `custom_action` sets `approval_scope_granted = true`, hides the dialog, and emits `approval_closed(true)`.
- The member is reset at the start of each dialog and read by the caller after the await.

Existing callers pass no scope text and keep their current one-shot behavior. The fixture's `approval_closed.emit(true)` path still works.

## File creation

In `_approve_file_edit`:

- Only `action == "create"` is covered.
- If `_approval_granted("authoring")`, return true without a dialog.
- Otherwise show a dialog that explains the combined authoring grant:

```text
The assistant wants to create <path>.

Allow it to create project files and run project code headlessly for this
plan? One approval covers script creation and verification runs until the
plan finishes. Move, delete, and host shell commands still ask separately.

This is a workspace file edit; it is not recorded in scene Undo.
```

- On the scope choice, grant `authoring`.
- `move` and `delete` use the existing one-shot dialog with no scope button.

## Headless runs

In `_approve_headless_run`:

- Keep the `allow_shell_commands` gate. If off, return false without a dialog.
- If `_approval_granted("authoring")`, return true without a dialog.
- Otherwise show the same combined explanation, with the concrete arguments and working directory, and offer the plan/turn scope.
- On the scope choice, grant `authoring`.

`run_command` keeps `_approve_shell_command` unchanged: arbitrary host code is never covered by the authoring grant.

## Scope examples

- Plan `plan-abc`, task 1 creates `res://player.gd` → prompt → **Allow for this plan**.
- Task 1 calls `verify_scene_runtime` → no prompt.
- Task 2 creates `res://platform_manager.gd` → no prompt.
- Task 2 calls `run_godot_headless` → no prompt.
- Task 2 retries after a failure → same `plan_root`, no prompt.
- A new plan `plan-def` → prompt once.
- A normal chat turn with no plan creates a file → prompt → **Allow for this turn**; later rounds in the same turn reuse it, the next turn prompts again.
- A `delete` in the same plan → prompt (not covered).
- A `run_command` in the same plan → prompt (not covered).
- `allow_shell_commands` off → headless run is unavailable and does not prompt.

## Tests

Extend `integrations/tiiny/tests/editor_workspace_tools.gd` with a fake chat whose `_approval_dialog` counts calls and optionally simulates the scope button by setting `approval_scope_granted = true`.

Assertions:

- First `create` in a plan prompts once; a second `create` with the same `plan_root` does not.
- A headless run with the same `plan_root` does not prompt after the grant.
- A new `plan_root` prompts again.
- A turn-scoped grant does not apply to a new `turn_id`.
- A plan-scoped grant does not apply to a different plan.
- `move` and `delete` still call the dialog.
- Cancel leaves no grant and returns false.
- With `allow_shell_commands` disabled, the headless approval returns false without prompting.

The fake chat uses the extracted `chat.gd` from `editor/tiiny_ai_dock_source.h`, so the test exercises the same code the editor build embeds.

## Verification

- Editor fixture.
- Workspace pure/editor, transaction, 20-case selection, runtime verification, smoke, and Jobs.
- Rebuild and record the duration.
