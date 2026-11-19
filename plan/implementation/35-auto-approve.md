# Story 35 implementation plan — opt-in auto-approval

Status: Complete; covered by the editor fixture and smoke visibility check.

Parent: [35 — Opt-in auto-approval for assistant actions](../work-items/35-auto-approve.md).

## Setting

In `_register_settings`, after `allow_shell_commands`:

```gdscript
if not settings.has_setting("tiiny_ai/advanced/auto_approve_assistant_actions"):
    settings.set_setting("tiiny_ai/advanced/auto_approve_assistant_actions", false)
settings.add_property_info({
    "name": "tiiny_ai/advanced/auto_approve_assistant_actions",
    "type": TYPE_BOOL,
    "hint": PROPERTY_HINT_NONE,
    "hint_string": "Skip assistant confirmation dialogs for file edits and host commands. This can change or delete files and run project code without review. Unsaved-scene discard confirmations remain.",
})
```

It is a normal editor setting, so it persists like `allow_shell_commands`. It is off by default.

## Approval checks

Add a helper:

```gdscript
func _auto_approve_assistant_actions() -> bool:
    var settings := EditorInterface.get_editor_settings()
    return settings.has_setting("tiiny_ai/advanced/auto_approve_assistant_actions") and bool(settings.get_setting("tiiny_ai/advanced/auto_approve_assistant_actions"))
```

- `_approve_file_edit`: return true at the top when `_auto_approve_assistant_actions()`.
- `_approve_shell_command`: after the `allow_shell_commands` check, return true when auto-approval is on.
- `_approve_headless_run`: after the `allow_shell_commands` check, return true when auto-approval is on.
- `_approve_scene_discard`: unchanged. It always asks; auto-approval does not cover discarding unsaved user edits.

The story 34 scoped grant remains below the auto-approval check. When the setting is off, behavior is unchanged. When it is on, no grant is needed and none is recorded.

## Boundaries

- Auto-approval does not flip `allow_shell_commands`. A user must enable host execution separately to use `run_command`, `run_godot_headless`, or `verify_scene_runtime`.
- It covers move and delete because the user explicitly opted into assistant file management without review.
- It does not cover scene discard, project-wide settings changes, model Apply operations, or any future operation that does not route through these approval callbacks.
- The existing dirty-scene and unsaved-script-buffer checks still fail closed before an edit; auto-approval only removes the human confirmation, not the safety checks.

## Tests

Extend the approval test in `editor_workspace_tools.gd`:

1. Assert the setting exists and defaults to false.
2. Enable shell execution and auto-approval.
3. Use the counting fake approval chat:
   - create, move, delete, headless, and shell calls return true;
   - `dialog_calls` stays unchanged.
4. Disable shell execution while auto-approval is still on:
   - headless and shell return false;
   - file create still returns true;
   - no dialog is shown.
5. Call `_approve_scene_discard` with auto-approval on:
   - the dialog counter increments;
   - the fake returns true.
6. Restore the previous shell and auto-approval values.

## Verification

- Editor fixture.
- Workspace pure/editor, transaction, 20-case selection, runtime verification, smoke, and Jobs.
- Rebuild and record the duration.
