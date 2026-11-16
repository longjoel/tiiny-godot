# Tiiny prototype verification

The in-progress job queue has additional Linux editor checks (they do not yet
cover the story 02 acceptance scenarios):

```sh
mkdir -p /tmp/tiiny-job-test
TIINY_QUEUE_TEST_DIR=/tmp/tiiny-job-test bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_job_queue.gd
TIINY_QUEUE_TEST_DIR=/tmp/tiiny-job-test bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_job_executor.gd
TIINY_QUEUE_TEST_DIR=/tmp/tiiny-job-test bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_job_publication.gd
TIINY_QUEUE_TEST_DIR=/tmp/tiiny-job-test bin/godot.linuxbsd.editor.x86_64 --headless --path . --script integrations/tiiny/tests/test_tree_worker.gd
python3 integrations/tiiny/tests/check_job_process.py
python3 integrations/tiiny/tests/check_editor_tree.py
python3 integrations/tiiny/tests/check_builtin_jobs.py
python3 integrations/tiiny/tests/check_resource_http.py
python3 integrations/tiiny/tests/check_workspace_inspector.py
python3 integrations/tiiny/tests/check_workspace_transactions.py
python3 integrations/tiiny/tests/check_workspace_live.py
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
checks paused dispatch, automatic classification, captured scene/selection
context, credential exclusion, tail appends, completion and a timed-out request
that remains interrupted. A separate abandon fixture verifies that a
device-uncertain interruption blocks the lease, can be abandoned with the
recorded uncertainty released, and is not replayed. A `chat_protocol` mode
verifies that a completed HTTP response rejected for multiple tool calls ends
as a confirmed failure and releases the device lease instead of becoming an
interrupted device job. Resource checks
cover FIFO ordering, callback after commit, cancellation and a late response;
the focused HTTP check opens a loopback-only fixture, answers automatic
classification, and verifies that a stale device snapshot revalidates inside a
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

Story 10 adds `Planner.schedule` offline assertions for coding-model protection, eligible eviction, restore actions, already-loaded no-op, and capacity/disk/unknown rejection. The Jobs suite adds `model_schedule` (evict → load → restore with four verified operations), `model_schedule_capacity` (no mutation, clear retained-coding error), `model_schedule_restore` (failure and cancellation restoration), and `model_schedule_disconnect` (same-key dedupe, explicit resolve/resume, recovered schedule).

Story 11 adds transaction-fixture coverage for native torch-flicker animation (light discovery, value track path/keys, `tiiny/flicker` library/autoplay, preserved existing animations, undo/redo, missing-light rejection) and slippery PhysicsMaterial assignment (values, shared-material preservation and explicit replacement summary, undo/redo, non-physics rejection). The registry payload must advertise both recipes.

The fake chat protocol fixture also submits a reviewed tree job through the
real built-in Jobs service, checks the returned acceptance and status, rejects
an invalid path, and waits for the fixture to complete. It uses no device.

`fake_chat.gd` replaces only the HTTP submission boundary. Protocol fixtures cover text, normal tool/result/final text, malformed/multiple/repeated calls and limits, matched unknown/failed tools, traversal, duplicate create, real temporary script creation, completed-artifact retention, subsequent-turn recovery, history reset and error redaction. The built-in dock also rejects an invalid call to detect stale binaries. Chat history checks read the dock's message log rather than a text-output widget.

JSON reports contain revision/dirty-file list, binary version/SHA-256, source hashes and bounded per-stage outcomes/diagnostic counts, without environment values, credentials, bodies or raw logs. Timeouts, nonzero exits, missing success markers and unexpected GDScript diagnostics fail the run. The invalid-generated-script stage alone requires exactly one expected parse diagnostic and verifies no file was written. Other engine diagnostics are counted separately.

Known upstream/environment diagnostics: restricted debug-server sockets and dummy popup positions under sandboxed/headless runs; an expected numeric-overflow warning in the nonfinite polygon fixture. The MultiplayerPeerExtension/WebRTCDataChannelExtension required-virtual diagnostics no longer occur (see the fix note in `plan/STATUS.md`). See [completion evidence](../../../plan/evidence/01-completion.md) for actual tested configurations and any additional observations. No broad engine test-enabled rebuild is required.
