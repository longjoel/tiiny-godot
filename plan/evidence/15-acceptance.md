# Story 15 — acceptance evidence

Story 15 is accepted. Gameplay behavior remains a first-class script path; existing scripts can be attached to owned nodes, and the edited scene can be saved explicitly without fabricating a scene-undo action.

Executable: `bin/godot.linuxbsd.editor.x86_64`. No build or test remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Attach an existing `.gd` to an owned node in one undo action | `apply_editor_transaction` now accepts `attach_script` with `target` and `path`. It validates a `res://` `.gd`, loads a `GDScript`, requires an owned target, records the previous script, and applies the script property in the transaction. The fixture attaches `attach_fixture.gd` to `Player`, verifies the script, undo restores null, and redo restores it. |
| Create a new script and attach it without false atomicity | Story 19 added `create_and_attach_gdscript`: it validates source and an existing or new owned target, requests file approval, rechecks scene identity, creates without overwrite, and attaches in one scene action. The editor fixture covers validation failures before creation and reports a file left behind if attachment later fails. File creation is not scene-undoable. |
| Save only through an explicit tool call; report path/dirty state | Added `save_edited_scene`, which calls `EditorInterface.save_scene()`, returns the actual `res://` path and dirty state, and is labeled as a file change with no scene undo. The fixture saves after attachment, verifies the scene is clean and undo count unchanged, reloads the scene, and confirms the script persisted. |
| Behavior prompts complete through scripts, not missing native tools | Live Ornith traces for “pick up velocity” and “spin on every wall” read and edited `bounce_script.gd` through `read_project_file`/`replace_in_gdscript`. The generated spin script (`/tmp/tiiny-live-edited.gd`) contains continuous rotation and flips direction on every wall. |
| Hash-guarded, parse-validated, bounded editing | Existing `read_project_file`/`replace_in_gdscript` tests cover stale hashes, duplicate snippets, invalid scripts, and file-change action cards; `attach_script` validates the script resource and parse status before mutation. |
| Deterministic attachment/save/reload coverage | `check_workspace_transactions.py` covers attachment, undo/redo, explicit save with unchanged history, and reload persistence. It also covers stale/dirty/unowned rejection through the shared transaction context. |
| Live behavior evidence | Spin and velocity prompts previously completed on-device with script read/edit and final responses. Attachment/save were not driven by a live model turn in this slice; the behavior path itself is live-tested through script edits. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Transaction/registry/action-card fixture | Passed attach/undo/redo/save/reload plus generic transaction suite | `/tmp/transactions-15.log` |
| Jobs suite | Passed all 31 modes | `/tmp/jobs-14.log` |
| Editor smoke | Passed 11/11 on the story 14 rerun | `/tmp/tiiny-story14-smoke3.json` |
| Debugger fixture | Passed | `/tmp/debugger-14.log` |
| Build | Exit 0, `00:00:33.41` | `/tmp/tiiny-story15-build.log` |

## Remaining boundaries

- File creation and attachment are separate effects. Scene undo does not remove the file, and an attachment failure after creation reports the surviving file rather than claiming a file+scene rollback.
- `save_edited_scene` saves the current scene path only; Save As and unsaved scenes are rejected.
- Script attachment does not configure exported properties, signals, or script parameters; use `connect_signal`/`set_property` or a script edit as appropriate.
- A live model turn for attach/save is not recorded; deterministic editor coverage is used.

## Story 19 reconciliation

`create_and_attach_gdscript` now has editor-fixture evidence for validation before approval, scene recheck after approval, no-overwrite file creation, typed attachment, undo/redo, save/reload, instanced-child boundaries, and a failure after file creation that reports the surviving file and preserves the intervening scene edit. File creation remains outside scene undo. See [story 19 progress](19-review-progress.md).
