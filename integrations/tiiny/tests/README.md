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
recorded uncertainty released, and is not replayed. Resource checks
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
```

## Modes and isolation

Without flags, the runner extracts the exact embedded manager/chat scripts, checks delimiters and parsing, exercises pure planner/panel/migration tests, and runs a separate invalid-generated-script rejection test. `--editor-smoke` adds the real editor, native resource/node dialogs, fake transport/tool protocol checks, and local CLI lifecycle tests. Offline modes replace HOME and XDG directories and clear inherited TIINY variables, including caller-provided live flags. They do not read normal SDK credentials or execute the real Tiiny CLI.

`--http-smoke` starts a loopback-only Python HTTP fixture and exercises production HTTPRequest paths, catalog/capacity reads, real socket timeout and HTTP/JSON errors, image decoding/import, and polygon generation. It starts a fixture scene and verifies Tiiny messages reach the real Output control while playing. It requires permission to open local sockets. No outside server is contacted.

`--displayed` runs the editor on the attached display, using X11 by default; choose `--display-driver wayland` to test Wayland. It saves settings/chat PNG captures beside the JSON report in `tiiny-story01-captures/` (under `/tmp` without a report). Captures contain fixture settings/data, never real credentials. Headless checks alone do not establish displayed layout.

`--live-readonly` explicitly reads the real SDK config/device and runs Check Config without inference or Apply. `--live-inference` instead sends real chat/polygon requests and optionally image generation if an image model is already warm. It selects a compatible warm coding model in temporary settings, saves/reopens the polygon, verifies image import if generated, and compares the final loaded set with the initial set even after failure. No mode invokes real model-management Apply or changes user editor settings. An unavailable live image model is reported as a skip, not a passed live image check.

## Coverage and reporting

Planner/panel fixtures cover incompatible capabilities, unknown metadata, allocation/SSD headroom, staging/reserves, protected coding replacement, duplicates, context limits, stale checks, compact cells at 600/1400 pixels, horizontal overflow, Info popups, and a single inventory table. Settings migration preserves existing Advanced values. Progress fixtures cover terminal chunking/escapes, device percentages, CLI percentages, and duplicate suppression.

The editor fixture covers invalid/empty catalogs and capacity errors, fake Apply verification/failure, missing/slow SDK commands, cancellation, manager exit, and owned child cleanup. Native resource tests exercise Image/material/blank polygon creation, malformed/degenerate/oversized/nonfinite polygon responses, valid save/reopen, wrong resource types, selection changes away and back, cancellation/reopen and late callbacks. Ordinary node creation uses the native Add Node flow and confirms the dock context reports the edited scene, selected node, and its basic properties.

The fake chat protocol fixture also submits a reviewed tree job through the
real built-in Jobs service, checks the returned acceptance and status, rejects
an invalid path, and waits for the fixture to complete. It uses no device.

`fake_chat.gd` replaces only the HTTP submission boundary. Protocol fixtures cover text, normal tool/result/final text, malformed/multiple/repeated calls and limits, matched unknown/failed tools, traversal, duplicate create, real temporary script creation, completed-artifact retention, subsequent-turn recovery, history reset and error redaction. The built-in dock also rejects an invalid call to detect stale binaries. Chat history checks read the dock's message log rather than a text-output widget.

JSON reports contain revision/dirty-file list, binary version/SHA-256, source hashes and bounded per-stage outcomes/diagnostic counts, without environment values, credentials, bodies or raw logs. Timeouts, nonzero exits, missing success markers and unexpected GDScript diagnostics fail the run. The invalid-generated-script stage alone requires exactly one expected parse diagnostic and verifies no file was written. Other engine diagnostics are counted separately.

Known upstream/environment diagnostics: restricted debug-server sockets and dummy popup positions under sandboxed/headless runs; an expected numeric-overflow warning in the nonfinite polygon fixture. The MultiplayerPeerExtension/WebRTCDataChannelExtension required-virtual diagnostics no longer occur (see the fix note in `plan/STATUS.md`). See [completion evidence](../../../plan/evidence/01-completion.md) for actual tested configurations and any additional observations. No broad engine test-enabled rebuild is required.
