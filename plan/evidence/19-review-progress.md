# Story 19 — review progress

Story 19 remains in progress. This is working evidence, not an acceptance report.

## Task catalog audit

| Task | Task-specific evidence | Result and boundary |
| --- | --- | --- |
| PROJECT-096: “Step over the next line and continue” | `integrations/tiiny/tests/check_debugger.py` runs `editor_debugger.gd`, which pauses a real GDScript session at line 8, invokes `debug_next`, checks that the first frame pauses on a later line, and invokes `debug_continue`. | Passed on 2026-11-16 using `bin/godot.linuxbsd.editor.x86_64`; the catalog tool mapping now names `debug_next`. This establishes the stated step-over/continue prompt, not live step-into or a successful pause of a running session. The sandboxed run could not open the debugger socket; the same command passed outside the sandbox. |
| 2D-004: “Move the player to (200, 300) and scale it to 1.5” | `editor_workspace_transactions.gd` applies both properties to the existing Player in one typed transaction and checks the result, undo and redo. | `python3 integrations/tiiny/tests/check_workspace_transactions.py` passed on 2026-11-16 against the built editor. |
| 2D-009: “Add a Start button to the scene” | The transaction fixture creates a Button named StartButton and asserts its type and `Start` text. | Same editor fixture passed on 2026-11-16. |
| 3D-067: “Add a warm omni light for the torch” | The transaction fixture creates an OmniLight3D and asserts its warm RGB color. | Same editor fixture passed on 2026-11-16; visual lighting quality was not assessed. |
| 3D-071: “Make the metal crate metallic and rough” | The fixture assigns a StandardMaterial3D to Crate and checks both metallic and roughness values. | Same editor fixture passed on 2026-11-16; visual appearance was not assessed. |
| PROJECT-098: “Generate a spoken line and add an audio player” | The previously run `editor_asset_generation.gd` verified generation and imported AudioStream duration; `editor_workspace_transactions.gd` independently tested importing a fixture WAV into a player. The live asset fixture now opens a scene and attaches the actual generated artifact through `import_generated_audio`, asserting the player's stream path. | Reclassified partial until the extended live fixture is run; separate previous passing stages do not establish their handoff. The fixture includes model unload/load operations and was not run as part of this edit. |
| 3D-061: “Bake a navigation region for enemies” | `editor_workspace_transactions.gd` checks creation of a NavigationRegion3D and NavigationMesh. `add_navigation_region` explicitly does not bake. | Reclassified partial; creating an unbaked region does not satisfy the prompt. |
| 3D-080: “Blend idle and run animations” | The fixture checks creation of an AnimationTree with one state; `add_animation_tree` creates a one-state state machine. | Reclassified partial; neither blending nor both animations are covered. |
| 3D-086: “Check that this generated model has good topology and PBR maps” | The fixture asserts mesh counts and that quality is `unverified`; the tool reports map presence rather than quality. | Reclassified partial; the test correctly avoids claiming quality but does not establish the requested assessment. |

Other supported tasks have not yet been audited against their actual assertions. The validator's test-file existence count is not task-level passing evidence. The fixture also checks that the new Camera2D is enabled, but does not yet demonstrate it becoming the current camera when another is active.

## Headless execution approval

`workspace.gd::_run_godot_headless` applies the host-execution setting and approval callback after validating arguments and before spawning, independently of which allowed flags are supplied. `test_workspace_tools.gd` exercises disabled and denied `--script`, `--quit`, `--import`, and `--check-only --script` calls, plus an approved script that prints its marker. `python3 integrations/tiiny/tests/check_workspace_tools.py` passed the pure and editor fixtures on 2026-11-16. Project code remains host code; the argument allowlist is not a sandbox.

## Approval-window path changes

Move and delete now resolve their paths again after the approval callback. The pure workspace fixture replaces a source or destination parent with a symlink while approval is pending and checks that all three cases fail without modifying outside files. `check_workspace_tools.py` passed after the incremental editor build on 2026-11-16. Path and hash rechecks are still separate from the final filesystem operation, so this is not a guarantee against an uncooperative writer racing the final commit.

## Script attachment

`attach_script` previously rejected the edited scene root and did not validate the target against the script's native base class. It now accepts the root and rejects incompatible target classes before mutation. The rebuilt editor's transaction fixture passed on 2026-11-16, including incompatible-root rejection without history or dirty-state changes, compatible-root undo/redo, and existing player attach/save/reload. This does not implement or establish the combined create-and-attach flow.

`create_and_attach_gdscript` validates a new script and existing owned target before approval, rechecks scene identity and revision after approval, creates the file without overwrite, and attaches through one typed scene transaction. It reports a created file explicitly if later attachment fails. On 2026-11-16 `check_workspace_tools.py` passed on the rebuilt editor with registry-dispatched denial, incompatible target rejection, a scene edit during approval, successful attachment, undo/redo, and save/reload. File deletion is not part of scene undo.

The tool now also accepts `node_class` and `node_name` to create a child and attach the script in one scene transaction. The editor fixture passed for an incompatible new-node class, an instanced-child parent, successful new-node creation and attachment, undo/redo, and save/reload. It also injects a scene edit after file creation and verifies the tool reports the remaining file and leaves the intervening scene change intact. `check_workspace_tools.py` passed on the rebuilt editor on 2026-11-16. File creation remains outside scene undo.

The fixture additionally rejects invalid GDScript, a non-GDScript extension, missing target, stale scene context, existing destination, and both attaching to and creating under an instanced child without creating a file or changing the scene. `check_workspace_tools.py` passed on 2026-11-16; its one expected parse diagnostic is explicitly counted. This is editor-fixture evidence, not a live-model run.

## Image-to-3D reference validation

The asset worker previously read and posted arbitrary bytes from `image_path`. It now checks the project path and symlinks, bounds the file and PNG dimensions, decodes the PNG, and computes its SHA-256 before submitting. The rebuilt editor fixture passed valid-image/hash, malformed, traversal, denied-path, missing, absolute-path, oversized, and symlink cases, and checked that malformed input cannot reach HTTP. This is a prerequisite, not evidence that a generated producer artifact is passed between queued stages; that workflow and device check remain open.

The queued asset worker now also supports Tiiny image generation as a producer. A fake endpoint-response fixture validates and imports a PNG, then checks the resulting artifact ID and SHA-256; the Jobs validator accepts that job. `check_workspace_tools.py` passed on the rebuilt editor on 2026-11-16. The image model must be loaded or scheduled first; no on-device producer test is claimed.

The 3D job can now reference the producer by `image_artifact_id`; append checks the producer type, and submission requires an earlier completed producer, matching ID/hash, and a valid PNG. The producer verifies the hash of its original validated bytes through import. The rebuilt editor fixture passed FIFO append, fake-record resolution, wrong hash, changed PNG, skipped and out-of-order producer rejection, and an invalid-reference no-HTTP/intermediate-preservation check. The composed path has not been tested on-device.

`check_asset_pipeline.py` subsequently passed an end-to-end editor fixture using the actual FIFO and controlled Tiiny responses. An image producer generated and imported a PNG; the 3D worker received those bytes and failed on the first response. Retrying the same consumer succeeded and imported a GLB containing a mesh, with two consumer attempts, one image attempt, unchanged intermediate hash, and matching artifact ID/hash in the final result. No Tiiny device was used; real model scheduling and device behavior for this composed sequence remain unverified.

## Concurrent-edit commit checks

`_delete_file` now calls the `before_commit` hook before its final hash check, matching the write, patch, and move paths. The pure fixture adds deterministic interleavings for every mutating route:

| Route | Interleaving | Result |
| --- | --- | --- |
| `write_file` overwrite | external edit before commit | `stale_hash`; external text preserved |
| `apply_patch` | external edit before commit | `stale_hash`; external text preserved |
| `write_file(create:true)` | destination created during approval | `file_exists`; external file preserved |
| `create_file` | destination created during approval | `file_exists`; external file preserved |
| `move_file` | destination created during approval | `file_exists`; source and destination preserved |
| `move_file` | destination created at commit time | `file_exists`; source and destination preserved |
| `move_file` | source changed during approval | `stale_hash`; source preserved |
| `delete_file` | file changed during approval | `stale_hash`; file preserved |
| `delete_file` | file changed at commit time | `stale_hash`; file preserved |

`python3 integrations/tiiny/tests/test_workspace_tools.gd` (run directly with the built editor) passed all cases on 2026-11-16. The final hash check and the rename/remove remain separate filesystem operations, so an uncooperative writer can still race the last syscall; the integration README states this limit rather than claiming atomic compare-and-swap.

## Catalog task-specific evidence

The catalog now carries a `test_assertion` for every supported task, and `check_task_catalog.py` fails if the marker is absent from the referenced test file. The audit reclassified four tasks whose assertions did not cover the prompt:

- 2D-006: the fixture asserts `enabled` but not that the camera becomes active.
- 2D-044: loop mode is verified, but low volume and an OGG music stream are not.
- 3D-082: sparks are created under `World`, not attached to an anvil.
- 3D-083: the trail is created under `World`, not behind a projectile.

The fixture also gained task-specific assertions for 2D-008 (HUD position), 2D-016 (particles parented to `Player`), and 3D-051 (1×1×1 `BoxMesh` size). `check_workspace_transactions.py` passed on 2026-11-16. The catalog validator reports 32 supported / 68 partial / 0 missing with 32/32 supported tasks carrying a present assertion. Live-only tasks (3D-064, PROJECT-091) map to their live runners and the recorded story 07/13 runs; they were not re-run in this session.

## Finding dispositions

| Finding | Disposition | Evidence |
| --- | --- | --- |
| Headless execution approval bypass | Fixed: setting plus per-run approval gate every invocation | Pure fixture disabled/denied `--script`, `--quit`, `--import`, `--check-only`; approved run |
| Dirty state across all tabs | Fixed: bridge reports all unsaved scenes; writes/moves/deletes/reloads refuse | Pure and editor fixtures, both tabs, denied/approved discard |
| Check-to-commit conflicts | Fixed with commit-time rechecks; residual final-syscall race documented | Pure fixture interleavings above |
| Creation approval policy | Fixed for `create_file`, `write_file(create:true)`, `create_gdscript`, `create_and_attach_gdscript` | Pure and editor fixtures, denial and approval |
| Git credential/denied-path exposure | Fixed: shared denied lists, case-insensitive pathspecs, output filtering, token redaction | Pure fixture staged/unstaged/unfiltered, case variants, editor dirs, log redaction |
| Story 13 composed image→3D | Verified deterministically; device not tested | `check_asset_pipeline.py` |
| Story 15 create-and-attach | Verified in editor fixture; file creation outside scene undo | `check_workspace_tools.py` |
| Story 16 task-specific evidence | Audited; assertions enforced; four tasks reclassified | `check_task_catalog.py` |

## Verification runs (2026-11-16, rebuilt editor)

Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, 35.88 s, `bin/godot.linuxbsd.editor.x86_64`. No build remains running.

| Check | Result | Log |
| --- | --- | --- |
| `check_workspace_tools.py` (pure + editor) | passed | `/tmp/s19-ws-tools.log` |
| `check_workspace_transactions.py` | passed | `/tmp/s19-tx.log` |
| `check_asset_pipeline.py` | passed | `/tmp/s19-pipeline.log` |
| `check_workspace_inspector.py` | passed | `/tmp/s19-inspector.log` |
| `check_debugger.py` | passed | `/tmp/s19-debugger.log` |
| `check_builtin_jobs.py` (27 modes) | passed | `/tmp/s19-jobs.log` |
| `check_model_configuration.py --editor-smoke` (includes `test_chat_protocol.gd`) | passed | `/tmp/s19-smoke.log` |
| `check_task_catalog.py` | passed, 32 supported / 68 partial / 0 missing | `/tmp/tiiny-task-coverage.json` |

Not run in this session: `check_asset_generation.py` and `check_chat_multicall_live.py` (live device/model). Their task mappings rely on the recorded story 13 and story 07 runs.
