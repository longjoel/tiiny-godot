# Tiiny prototype verification

The in-progress job queue has additional Linux editor checks (they do not yet
cover the story 02 acceptance scenarios):

```sh
mkdir -p /tmp/tiiny-job-test
TIINY_QUEUE_TEST_DIR=/tmp/tiiny-job-test bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_job_queue.gd
TIINY_QUEUE_TEST_DIR=/tmp/tiiny-job-test bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_job_executor.gd
bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_live_turn_wait.gd
TIINY_QUEUE_TEST_DIR=/tmp/tiiny-job-test bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_job_publication.gd
TIINY_QUEUE_TEST_DIR=/tmp/tiiny-job-test bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_tree_worker.gd
python3 integrations/tiiny/tests/check_job_process.py
python3 integrations/tiiny/tests/check_editor_tree.py
python3 integrations/tiiny/tests/check_builtin_jobs.py
python3 integrations/tiiny/tests/check_resource_http.py
python3 integrations/tiiny/tests/check_workspace_inspector.py
python3 integrations/tiiny/tests/check_workspace_transactions.py
python3 integrations/tiiny/tests/check_workspace_tools.py
python3 integrations/tiiny/tests/check_workspace_bakeoff.py
python3 integrations/tiiny/tests/check_workspace_displayed.py
python3 integrations/tiiny/tests/check_workspace_coding_live.py
python3 integrations/tiiny/tests/check_plan_live.py
python3 integrations/tiiny/tests/check_workspace_live.py
bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_workspace_tools.gd
bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_workspace_inspector.gd
```

The process test owns its temporary directory, kills its own fixture processes,
checks exclusive locking, and checks recovery after a journaled publication. The
native storage currently supports Unix platforms only; unsupported platforms
fail closed. Do not delete a queue's permanent `.lock` file while an editor
may be using it.

The standalone tree fixture uses a test-only copy callback and checks malformed
and symlink outputs. The disposable headless editor fixture connects the tree
worker to the journaled Unix publisher, validates a `Texture2D` after import,
checks a destination conflict, and reconciles a published file after reopening
the queue. Hard links require staging and destination on one filesystem. These
The built-in Jobs fixture opens the embedded panel in disposable projects,
submits a tree and explicit scene attachment, verifies import, save, undo/redo
and hidden queue storage, and reopens the project to check persisted history.
It checks stale-scene and skipped-producer failures, scene reconciliation after
reopening the queue and restarting the editor, and rejection of an ambiguous
scene. A fake queued chat also
checks paused dispatch, direct dispatch, captured scene/selection
context, credential exclusion, tail appends, completion and a timed-out request
that remains interrupted. A separate abandon fixture verifies that a
device-uncertain interruption blocks the lease, can be abandoned with the
recorded uncertainty released, and is not replayed. A `chat_protocol` mode
verifies that a completed HTTP response rejected for multiple tool calls ends
as a confirmed failure and releases the device lease instead of becoming an
interrupted device job. Story 20 adds `chat_chain` (a three-step turn with two tool rounds, restored counters, and duplicate-response rejection) and a `chat_chain_prepare`/`chat_chain_restore` pair that persists a continuation's turn state across an editor restart. Story 21 adds `chat_image_handoff`/`chat_image_failure`/`chat_image_abandon` and `chat_shell_handoff`/`chat_shell_failure`/`chat_shell_approval`/`chat_shell_headless`: a long image or shell tool ends the chat step, runs as its own FIFO job, and resumes the turn with the real result, the actual failure, or an unknown-outcome error after an explicit resolution. The shell modes also assert pre-approval denial queues nothing, the headless job records its normalized arguments and owned pid, and cancellation stops the process group before resuming. Story 22 removes the classification round-trip and adds `chat_project_instructions` and `chat_instruction_injection`; every chat mode now treats the first submission as the real request, and the injection mode proves project text cannot enable shell execution, alter the tool payload, or reach approval. Story 23 adds `plan_success`, `plan_failure_retry`, `plan_planner_retry`, `plan_skip`, `plan_cancel`, `plan_dependency`, `plan_invalid`, and `plan_overclaim` for atomic child append, deferred join, dependency injection, contained failure, retry/skip/cancel (including cancelling the running child), planner proposals, invalid-plan rejection, overclaim downgrade, and plan card/details content. Resource checks
cover FIFO ordering, callback after commit, cancellation and a late response;
the focused HTTP check opens a loopback-only fixture, answers direct dispatch, and verifies that a stale device snapshot revalidates inside a
chat turn instead of requiring a manual Refresh. The reviewed worker append
fixture checks tail ordering, retained IDs, replay deduplication and invalid
request rejection. Displayed layout and real device coordination remain separate
checks.

Build once, then run from the repository root:

```sh
python3 integrations/tiiny/tests/check_model_configuration.py --editor-smoke --report /tmp/tiiny-story01-offline.json
python3 integrations/tiiny/tests/check_model_configuration.py --http-smoke --displayed --report /tmp/tiiny-story01-displayed.json
python3 integrations/tiiny/tests/check_model_configuration.py --live-inference --report /tmp/tiiny-story01-live.json
python3 integrations/tiiny/tests/check_model_configuration.py --live-apply --report /tmp/tiiny-story04-live-apply.json
```

## Modes and isolation

Without flags, the runner extracts the exact embedded manager/chat scripts, checks delimiters and parsing, exercises pure planner/panel/migration tests, and runs a separate invalid-generated-script rejection test. `--editor-smoke` adds the real editor, native resource/node dialogs, fake transport/tool protocol checks, and local CLI lifecycle tests. Offline modes replace HOME and XDG directories and clear inherited TIINY variables, including caller-provided live flags. They do not read normal SDK credentials or execute the real Tiiny CLI.

`--http-smoke` starts a loopback-only Python HTTP fixture and exercises production HTTPRequest paths, catalog/capacity reads, real socket timeout and HTTP/JSON errors, image decoding/import, and polygon generation. It starts a fixture scene and verifies Tiiny messages reach the real Output control while playing. It requires permission to open local sockets. No outside server is contacted.

`--displayed` runs the editor on the attached display, using X11 by default; choose `--display-driver wayland` to test Wayland. It saves settings/chat PNG captures beside the JSON report in `tiiny-story01-captures/` (under `/tmp` without a report), plus `models-<state>-<width>.png` and `models-plan-details.png` for fresh, stale, incompatible, applying, and failed Models states at 1400 and 600 px. Captures contain fixture settings/data, never real credentials. Headless checks alone do not establish displayed layout.

`--live-readonly` explicitly reads the real SDK config/device and runs Check Config without inference or Apply. `--live-inference` instead sends real chat/polygon requests and optionally image generation if an image model is already warm. It selects a compatible warm coding model in temporary settings, saves/reopens the polygon, verifies image import if generated, and compares the final loaded set with the initial set even after failure. An unavailable live image model is reported as a skip, not a passed live image check.

`--live-apply` is the only mutating mode. It uses temporary editor settings, requires an already-warm compatible coding model, selects the smallest not-downloaded Text-to-Speech model, checks that the plan is a single download, then performs one real Apply through the FIFO with device-reported progress. It never loads or unloads a model and verifies that the warm set is unchanged. The downloaded model remains on the device; this mode is not run as part of offline checks. Set `TIINY_TEST_LIVE_APPLY_MODEL=<id>` to verify an already-installed target without another download.

## Coverage and reporting

Planner/panel fixtures cover incompatible capabilities, unknown metadata, allocation/SSD headroom, staging/reserves, protected coding replacement, duplicates, context limits, stale checks, compact cells at 600/1400 pixels, horizontal overflow, Info popups, and a single inventory table. Story 04 adds `operation_state()`/`panel_state()` assertions for fresh, stale, and unavailable states, unknown capacity, disabled no-compatible role entries, role explanations, downloaded/loaded vocabulary, plan-expiry text, a bounded partial-result view after a stopped Apply, and a resizable copyable Info dialog. A further fixture proves that an already-loaded compatible coding model is adopted, stale queued restores are cancelled, and no replacement restore is queued. The Jobs suite adds queued-card cancellation, cancel-all, hiding a cancelled queued card, and queue restart retention. DEV-03 covers an image-only catalog rejecting scripting with no planned mutation. A three-process editor restart fixture proves applied warm selections and context survive while an unapplied draft is session-only. Settings migration preserves existing Advanced values. Progress fixtures cover terminal chunking/escapes, device percentages, CLI percentages, and duplicate suppression.

The editor fixture covers invalid/empty catalogs and capacity errors, fake Apply verification/failure, missing/slow SDK commands, cancellation, manager exit, and owned child cleanup. Native resource tests exercise Image/material/blank polygon creation, malformed/degenerate/oversized/nonfinite polygon responses, valid save/reopen, wrong resource types, selection changes away and back, cancellation/reopen and late callbacks. Ordinary node creation uses the native Add Node flow and confirms the dock context reports the edited scene, selected node, and its basic properties.

The provider and editor fixtures cover story 05's read-only workspace tools. Pure checks use an injectable `EditorApi` and cover scene identity, bounds, errors, value encoding, property filtering, resources, signals, turn-context staleness, deleted targets, and a 16 KiB result budget. The editor fixture opens authored, instanced, inherited, dirty, and running-scene cases; verifies real undo `get_version()` changes and dirty state; checks that inspection leaves the scene hash, node count, and undo version unchanged; and confirms the inspector script is injected into the dock without being advertised to the model.

The transaction fixture covers the class-agnostic executor, one-undo recipe, save/reload, stale/dirty rejection, conflict and incompatible-resource rollback, and test-only Marker2D/Capsule recipes. It also exercises the tool registry: schema rejection, availability filtering, prompt sections, ledger entries, chat tool dispatch, structured call IDs, unknown-tool errors, and a recipe through the chat path. Story 09 adds assertions for available/planned resource-recipe metadata, exact output type support, exclusion of planned recipes from the tool payload, dock/dialog eligibility agreement, and generated-image artifact links in action cards. The live mode is explicitly gated and uses the real warm coding model plus undo.

The resource HTTP fixture also checks story 09's image path: the generated PNG must decode, import as a `Texture2D`, and satisfy the import-readiness check, while a deliberately invalid PNG must not be reported as importable.

Story 09 adds live coverage with `check_chat_multicall_live.py`: the configured downloaded `Tongyi-MAI/Z-Image-Turbo` is loaded on demand, a soccer-ball image is generated/imported, the configured warm set is restored, and `add_sprite_from_image` creates a `SoccerBall` Sprite2D. The generated texture is captured at `/tmp/tiiny-live-sprite.png`.

`check_task_catalog.py` validates `plan/task-catalog.json` v2 and reports coverage for 100 common 2D/3D/project tasks. It checks unique IDs/prompts, solution classes, status consistency, tool existence against the embedded tool surface, a test reference for every supported task, and a task-specific `test_assertion` that must appear in that test file. Current result: 100 tasks, 32 supported / 68 partial / 0 specialized-missing, 32/32 supported tasks with a present assertion; solution classes are native_macro 30, composed_primitives 56, script_behavior 14, specialized_missing 0. Story 19 reclassified 2D-006, 2D-044, 3D-082, and 3D-083 to partial after auditing their assertions against the prompt. Report: `/tmp/tiiny-task-coverage.json`; table: `plan/TASK_CATALOG.md`.

Story 10 adds `Planner.schedule` offline assertions for coding-model protection, eligible eviction, restore actions, already-loaded no-op, and capacity/disk/unknown rejection. The Jobs suite adds `model_schedule` (evict → load → restore with four verified operations), `model_schedule_capacity` (no mutation, clear retained-coding error), `model_schedule_restore` (failure and cancellation restoration), and `model_schedule_disconnect` (same-key dedupe, explicit resolve/resume, recovered schedule).

The `model_preflight_stale` and `model_resource_preflight_stale` Jobs fixtures verify that a stale snapshot is refreshed before attempting restoration: an already-warm compatible coding model can serve the job without an applied configuration or any load command. The `test_live_turn_wait.gd` fixture checks that the live trace follows continuation jobs and rejects a failed final step; it does not contact the device.

`check_asset_pipeline.py` also covers assistant-submitted image jobs with on-demand loading: successful generation/restoration, restoration after a known HTTP failure, preserved image plus interrupted recovery when restoration is uncertain, no restoration after an uncertain image request, and cancellation during model loading. `check_managed_image_planner.py` exercises the production planner and device journal with fake transport, including eviction and restoration of another warm model. These fixtures do not contact Tiiny. The chat handoff to the image job is covered by `chat_image_handoff` and the failure/abandon modes; it remains fake-transport evidence, not a live device trace.

Story 11 adds transaction-fixture coverage for native torch-flicker animation (light discovery, value track path/keys, `tiiny/flicker` library/autoplay, preserved existing animations, undo/redo, missing-light rejection) and slippery PhysicsMaterial assignment (values, shared-material preservation and explicit replacement summary, undo/redo, non-physics rejection). The registry payload must advertise both recipes.

Story 12 adds `check_debugger.py`, which starts a real fixture scene, pauses at a breakpoint, and verifies session/state, stack frames, `Members/counter=7`, `Locals/doubled=null`, frame selection, runtime tree identities, continue/stale-frame rejection, session-end errors, and breakpoint set/removal. Runtime property values remain explicitly unavailable without a selected remote node.

Story 13 adds transaction-fixture coverage for `import_generated_model` (real generated GLB, mesh/material metadata, topology/PBR unverified, undo/redo, missing-downstream artifact preserves the stage-1 PNG hash) and `import_generated_audio` (real WAV, positive duration, loop unverified, undo/redo). It also asserts the registry advertises both import recipes and no sound-effect recipe.

Story 13 also adds `check_asset_generation.py`, a live-device fixture for queued `asset_generate` jobs: real TTS via `/v1/audio/speech`, real shape-only image-to-3D via `/v1/3d/tasks`, imported AudioStream/MeshInstance3D verification, specialized-model unload/reload through `model_schedule` while the coding model stays resident, a confirmed missing-reference failure with lease release and successful retry, and a cancelled 3D job that becomes `interrupted` and requires acknowledgement. It requires the real Tiiny device and installed models.

Story 14 adds `apply_editor_transaction`: bounded typed create/set/resource/assign/remove/reparent/duplicate/instantiate/connect operations, one undo, stale-scene checks, and atomic rollback. The transaction fixture covers all operations plus invalid class/property/reference/cap cases. `check_editor_primitives_live.py` verifies a live Ornith turn composing Camera2D, Label, and a PBR StandardMaterial3D; the resulting scene is captured in `/tmp/tiiny-live-primitives.txt`.

Story 15 adds `attach_script` to `apply_editor_transaction` and an explicit `save_edited_scene` file tool. The transaction fixture attaches a script with undo/redo, saves without adding a fake undo entry, reloads the scene, and verifies persistence. Live behavior evidence remains the velocity/spin script edits.

Story 17 adds TileMapLayer, GridMap, AnimatedSprite2D, theme/font, audio loop/bus, NavigationRegion3D, AnimationTree/playback, Trail3D, 3D weather, particles, imported-mesh collision, and mesh-quality validation; the transaction fixture covers structure, typed properties, and undo/redo.

Story 18 adds `check_workspace_tools.py` (pure and editor fixtures) for root confinement, symlinks, binary/large reads, bounded searches, hash-guarded atomic writes, commit-time rechecks, creation/move/delete approval, patch conflicts, GDScript validation, git denied-path/credential filtering, headless and shell timeouts/output caps/process-group cleanup, all-open-scene dirty checks, explicit discard approval, mode payload filtering, and file-change action cards. Story 19 adds deterministic interleavings for write, patch, create, move, and delete, including changes during approval and destinations appearing at commit time. `check_workspace_displayed.py` captures the workspace and hybrid mode labels in a real X11 editor (`/tmp/tiiny-story18-mode-*.png`). `check_workspace_bakeoff.py` solves 10 fixed tasks once through workspace files and once through typed editor tools, verifies all 20 results, records times/review effort, and checks stale-write and undo/redo recovery. These are fixed solutions, not a live-model planning rate. `check_workspace_coding_live.py` is a gated real-device trace: the warm coding model edits a script in workspace mode, then creates a Label through a hybrid typed transaction; it records one tool-choice trace, not a success rate. `check_plan_live.py` is a gated real-device trace for a dependent two-task `submit_plan` turn: it waits for both task jobs, the injected dependency result, the deferred join, and the final answer. See [story 18 acceptance](../../../plan/evidence/18-acceptance.md).

`check_jobs_displayed.py` launches a displayed X11 editor and captures `/tmp/tiiny-jobs-displayed.png` after a completed `create_tree` job, verifying the Jobs dock is visible with its queued/running/attention/completed/failed columns and card.

`check_authoring_batch_live.py` runs live Ornith prompts for torch flicker, a slippery platform, and a 32×48 collision shape, verifying the resulting AnimationPlayer, PhysicsMaterial, and RectangleShape2D. It is part of the catalogs live coverage batch, along with the velocity/spin/sprite, primitives/PBR, TTS, and image-to-3D traces.

The fake chat protocol fixture also submits a reviewed tree job through the
real built-in Jobs service, checks the returned acceptance and status, rejects
an invalid path, and waits for the fixture to complete. It uses no device.

`fake_chat.gd` replaces only the HTTP submission boundary. Protocol fixtures cover text, normal tool/result/final text, malformed/multiple/repeated calls and limits, matched unknown/failed tools, traversal, duplicate create, real temporary script creation, completed-artifact retention, subsequent-turn recovery, history reset and error redaction. Well-formed multiple calls now execute sequentially with matched `tool_call_id` results; strict Hermes-style `<tool_call>` markup is parsed only when the whole response is markup, while malformed/duplicate calls are rejected atomically. Chat history checks read the dock's message log rather than a text-output widget. The safe script-edit path is covered by `read_project_file` (bounded text + SHA-256) and `replace_in_gdscript` (stale-hash, duplicate-snippet, invalid-script rejection, valid edit, and file-change action card). Live Ornith traces cover the velocity and spin prompts, including failed-snippet retries.

JSON reports contain revision/dirty-file list, binary version/SHA-256, source hashes and bounded per-stage outcomes/diagnostic counts, without environment values, credentials, bodies or raw logs. Timeouts, nonzero exits, missing success markers and unexpected GDScript diagnostics fail the run. The invalid-generated-script stage alone requires exactly one expected parse diagnostic and verifies no file was written. Other engine diagnostics are counted separately.

Known upstream/environment diagnostics: restricted debug-server sockets and dummy popup positions under sandboxed/headless runs; an expected numeric-overflow warning in the nonfinite polygon fixture. The MultiplayerPeerExtension/WebRTCDataChannelExtension required-virtual diagnostics no longer occur (see the fix note in `plan/STATUS.md`). See [completion evidence](../../../plan/evidence/01-completion.md) for actual tested configurations and any additional observations. No broad engine test-enabled rebuild is required.
