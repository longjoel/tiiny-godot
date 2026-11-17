# Story 18 — acceptance evidence

Story 18 is accepted for deterministic, editor, displayed-mode, and fixed-solution bake-off evidence. It is not a live-model coding-mode success rate, and no Tiiny device operation was required.

Executable: `bin/godot.linuxbsd.editor.x86_64` (`4.8.beta.custom_build.fd12e814e`). No build remains running.

## Implemented surface

`editor/tiiny/tools/workspace.gd` provides 16 tools:

- Files: `list_files`, `read_file`, `search_text`, `file_info`.
- Edits: `write_file`, `apply_patch`, `create_file`, `move_file`, `delete_file` (the last three require explicit approval).
- Git: `git_status`, `git_diff`, `git_log`.
- Execution: `run_godot_headless`, `run_command` (both require `tiiny_ai/advanced/allow_shell_commands` and per-run approval).
- Bridge: `reload_scene`, `scan_filesystem`; `save_edited_scene` remains the story 15 tool.

`tiiny_ai/advanced/tool_mode` selects `editor` (default), `workspace`, or `hybrid`. The registry filters the tool payload, rejects execution of tools outside the mode, and names the mode in the prompt/capability summary. The dock shows the active mode and labels workspace edits as not scene-undoable.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Root-confined file tools; absolute escapes, `..`, symlinks, editor-data/credential paths rejected | Pure fixture rejects `../outside`, `res://../outside`, `/etc/passwd`, `user://`, `.git/config`, `id_rsa`, `.godot`, and symlinks to inside/outside the project. Paths are canonicalized, components checked for links, and the resolved absolute path must stay under the project root. |
| Bounded, binary-safe reads/searches/listings; truncation reported without binary context | Pure fixture covers binary PNG metadata-only reads, a 300 KB file limited to 4 KB with `truncated`, offset/limit line reads, recursive listing caps/truncation, literal and explicit-regex search with binary skipping, and match truncation. |
| Writes/patches require current SHA-256; atomic writes prevent partial files; stale/concurrent edits unchanged | Pure fixture covers missing/stale hash, successful overwrite with before/after hashes, invalid GDScript rejection, external change after read, and a change injected at commit time. New files require `create:true` plus approval and are committed with a hard link so an existing destination is never overwritten. Temp files are removed or committed; none remain. |
| Deterministic patches, ambiguous-context rejection, unrelated content preserved, invalid GDScript checked | Exact old/new blocks and unified diffs apply; duplicate/ambiguous blocks and mismatched context return `patch_conflict` without change; unrelated lines survive; invalid patched GDScript is not committed; reused hashes are rejected. |
| Git status/diff/log read-only, root-confined, bounded, no credentials | Git pathspecs exclude `.env`, keys, `.ssh`, `.gnupg`, and `.git`; status output is filtered; token-like values are redacted. Tests cover unstaged, staged, and unfiltered diffs plus status for denied files. Git uses an argv allowlist (`status`, `diff`, `log`) and no shell. |
| Headless commands non-blocking, timeouts, output caps, owned-process cleanup | Pure fixture runs a real headless Godot script, verifies output, rejects unallowlisted flags and outside scripts, times out a slow script, verifies its pid is gone, caps noisy output at 256 KiB, and verifies a timed-out `sleep` process group is gone. |
| `run_command` off by default, explicit setting/approval, host-code description | Pure fixture checks `command_disabled`, `approval_required`, approved execution, project-root cwd, credential redaction, output cap, timeout, and process-group cleanup. The tool description and approval dialog state that this is host code execution. Headless project scripts are gated the same way. |
| Explicit scene save/reload; dirty scenes refused or saved; no silent loss | Editor fixture opens a scene, makes it dirty through the undo manager, verifies the file write and reload are refused, verifies the unsaved label text and file bytes are unchanged, saves explicitly, writes a renamed scene, reloads it, and verifies the editor now shows `ReloadedRoot`. The bridge reports dirty state from all open scene tabs via `get_unsaved_scenes()`, and discard reload requires a user approval callback. |
| Separate bounded mode payloads; visible switching | Editor fixture verifies editor mode hides workspace tools, workspace mode hides editor-only tools, hybrid exposes both, `run_command`/`run_godot_headless` stay hidden until the setting is enabled, unknown modes are rejected, and the dock label text changes. Displayed X11 captures show the workspace and hybrid labels. |
| File changes use file-change cards and diff review; never scene Undo; scene transactions keep one undo | Editor fixture appends a workspace write result and finds the `File change · not scene-undoable` label and `Review diff` button. The transaction fixture confirms typed recipes still create exactly one undo action and that script-edit cards do not offer scene undo. |
| Deterministic coverage of traversal, symlink, binary/large, stale hashes, patch conflicts, dirty scenes, reload, command limits, mode filtering | `test_workspace_tools.gd` (112 checks) and `editor_workspace_tools.gd` cover each listed case. |
| ≥10-task bake-off on correctness, time, corruption/recovery, review effort | `editor_workspace_bakeoff.gd` solves 10 fixed tasks twice: script speed patch, script jump edit, collision shape, Marker2D, Label text, Camera2D, OmniLight3D, PBR material, slippery platform, and reparent. All 20 solutions verified. Recovery checks cover stale write preservation, no temp files, and editor undo/redo. A supplementary two-turn live trace with the warm Ornith model exercised workspace mode (`read_project_file` → hash-guarded `replace_in_gdscript`) and hybrid mode (`apply_editor_transaction`); it is one trace, not a rate. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Build | Exit 0, `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, `00:00:31.20`, `bin/godot.linuxbsd.editor.x86_64` | STATUS records the run; no build log retained |
| Pure + editor workspace fixture | Passed: 112 pure checks; editor dirty/reload/mode/card integration | `/tmp/ws-pure-10.log`, `/tmp/ws-tools-final9.log` |
| Displayed mode capture | Passed: workspace and hybrid X11 labels visible | `/tmp/story18-displayed5.log`, `/tmp/tiiny-story18-mode-workspace.png`, `/tmp/tiiny-story18-mode-hybrid.png` |
| Bake-off | 10/10 workspace, 10/10 editor; recovery checks all true | `/tmp/story18-bakeoff-6.log`, `/tmp/tiiny-story18-bakeoff.json` |
| Transaction/registry fixture | Passed | `/tmp/story18-tx3.log` |
| Workspace inspector fixture | Passed | `/tmp/story18-insp3.log` |
| Debugger fixture | Passed | `/tmp/story18-debug3.log` |
| Built-in Jobs suite | Passed all modes | `/tmp/story18-jobs4.log` |
| Editor smoke | Passed 11/11 stages | `/tmp/story18-smoke5.log` |
| Catalog validator | 100 tasks, 64 native tools, 40 supported / 60 partial / 0 missing, 40/40 supported tests | `/tmp/tiiny-story18-catalog.json` |
| Live tool-choice trace | Passed with `ornith-ai/Ornith-1.5-35B-A3B-Turbo`: workspace read/edit and hybrid typed transaction; warm set unchanged | `/tmp/story18-coding-live2.log` |

## Bake-off

Fixed scripted solutions in one disposable editor; times cover only the solution tool calls, not verification or scene opening. This compares solution paths, not model planning.

| Task | Workspace ms | Editor ms | Workspace diff lines | Editor undo actions |
| --- | ---: | ---: | ---: | ---: |
| script_speed | 0.81 | 0.40 | 2 | 0 |
| script_jump | 0.77 | 0.41 | 2 | 0 |
| collision | 0.44 | 2.42 | 16 | 1 |
| marker | 0.54 | 2.98 | 3 | 1 |
| label | 0.54 | 2.35 | 2 | 1 |
| camera | 0.45 | 2.36 | 4 | 1 |
| light | 0.57 | 2.78 | 3 | 1 |
| material | 0.49 | 3.81 | 31 | 1 |
| slippery | 0.53 | 2.19 | 38 | 1 |
| reparent | 0.53 | 1.96 | 2 | 1 |

Median: workspace 0.5345 ms, editor 2.353 ms. Review effort: 103 workspace diff lines versus 8 editor undo actions. The workspace path is faster for these fixed text edits but has no undo; the editor path is slower but reversible and structurally validated. The material and slippery tasks show the largest generated-text diff, which is where typed editor tools add the most review value.

## Boundaries

- No live-model 10-task rate. The fixed bake-off uses scripted solutions; one supplementary two-turn live trace records tool choice for a workspace edit and a hybrid transaction, not a success rate.
- No device or Tiiny model operation. Asset/device tool behavior is unchanged.
- Atomic overwrite narrows the race with a commit-time hash check but is not an OS compare-and-swap; a change in the final check-to-rename window is not detectable without native support. New-file and move destinations use a no-overwrite hard link on Unix; unsupported filesystems report failure rather than falling back to overwrite.
- Script-editor unsaved buffers are not visible through `get_unsaved_scenes()`; dirty-scene protection covers scene tabs, not in-memory script editor edits. Workspace scripts are expected to be loaded/saved through the editor or edited while closed.
- Git credential protection is a denied-path allowlist plus token redaction. It does not classify every possible secret in allowed files; review is still required.
- The mode label is a dock hint, not a permission system; registry filtering and per-tool validation enforce behavior.
- The displayed captures use the fixture editor at 1280×820; the mode label is visible in the dock, but no broader responsive-layout sweep was run.
