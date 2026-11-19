# 35 — Opt-in auto-approval for assistant actions

Status: Complete.

Feature: Add an Advanced setting that skips the assistant’s file-edit, headless-run, and host-command confirmation dialogs for users who explicitly choose to auto-approve.

Sequence: 35

Stream: `integration`

Dependencies: 18, 34. Extends the approval path; it does not change tool capabilities or the shell gate.

Implementation: [plan](../implementation/35-auto-approve.md).

## Why

Story 34 reduces prompts to one per plan or turn, but some users want no prompts at all. That is a deliberate risk choice, so it should be explicit, off by default, and clearly labeled rather than implied by another setting.

## Scope

- Register `tiiny_ai/advanced/auto_approve_assistant_actions` in **Tiiny AI > Advanced**, default `false`.
- When enabled:
  - assistant file creation, move, and delete are approved without a dialog;
  - `run_godot_headless` and `verify_scene_runtime` are approved without a dialog when `allow_shell_commands` is enabled;
  - `run_command` is approved without a dialog when `allow_shell_commands` is enabled.
- When disabled, the story 34 plan/turn grants and one-shot dialogs behave exactly as before.
- `allow_shell_commands` remains a separate master gate. Auto-approval never enables host execution by itself.
- The unsaved-scene discard confirmation remains manual even when auto-approval is enabled. It protects user work that is not the assistant’s to discard.
- The setting hint explains that it can change or delete files and run project code without review.
- Existing scoped grants are unaffected; auto-approval is checked first and simply removes the remaining prompt.

## Acceptance criteria

- [x] The setting is registered, visible in Advanced, defaults to `false`, and has a warning hint.
- [x] With auto-approval on and shell execution enabled, file create/move/delete, headless verification, and host commands return true without opening a dialog.
- [x] With auto-approval on and shell execution disabled, file actions are approved but headless/host commands remain unavailable and unapproved.
- [x] With auto-approval off, the story 34 scoped grant and one-shot dialogs still work.
- [x] Unsaved-scene discard still opens its confirmation dialog when auto-approval is on.
- [x] The setting is session-persistent like other editor settings; no project file is changed.
- [x] Focused workspace, transaction, selection, runtime, smoke, and Jobs suites rerun on the final build.
- [x] Build recorded with no build left running.

## Evidence

- Editor fixture uses the counting fake approval chat: with auto-approval and shell enabled, create, move, delete, headless, and shell calls make no dialog calls; with shell disabled, headless and shell return false; scene discard still increments the dialog count.
- Workspace pure/editor, transaction, 20-case selection, runtime verification, and editor smoke (13) passed; full Jobs passed 66 modes. The first smoke run caught that the new setting was still hidden by the editor allowlist; `editor_node.cpp` now includes it and the rerun passed 13. Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:30.94`. No build remains running.
- Build recorded: exit 0, `00:00:30.94`; no build remains running.
