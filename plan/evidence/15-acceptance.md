# Story 15 — acceptance evidence

Story 15 is accepted. Gameplay behavior remains a first-class script path; existing scripts can be attached to owned nodes, and the edited scene can be saved explicitly without fabricating a scene-undo action.

Executable: `bin/godot.linuxbsd.editor.x86_64`. No build or test remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Attach an existing `.gd` to an owned node in one undo action | `apply_editor_transaction` now accepts `attach_script` with `target` and `path`. It validates a `res://` `.gd`, loads a `GDScript`, requires an owned target, records the previous script, and applies the script property in the transaction. The fixture attaches `attach_fixture.gd` to `Player`, verifies the script, undo restores null, and redo restores it. |
| Create a new script and attach it without false atomicity | Existing `create_gdscript` remains a file operation; `attach_script` is a scene transaction. A failure to attach reports separately from file creation; the transaction does not claim to roll back a file it did not create. |
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

- `attach_script` attaches an existing script; creating a new file and attaching are separate effects, reported honestly rather than as a file+scene atomic rollback.
- `save_edited_scene` saves the current scene path only; Save As and unsaved scenes are rejected.
- Script attachment does not configure exported properties, signals, or script parameters; use `connect_signal`/`set_property` or a script edit as appropriate.
- A live model turn for attach/save is not recorded; deterministic editor coverage is used.
