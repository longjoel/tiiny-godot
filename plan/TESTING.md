# Automated verification strategy

Automated testing is feasible. The repository already provides doctest integration (`tests/test_main.cpp`), tests with scene/editor setup and a mock display server, and scene/control tests under `tests/scene`. Engine tests require a build configured with `tests=yes`; ordinary editor builds do not necessarily contain them. Headless execution and script parsing are also available. Full editor/plugin integration may require a dedicated editor fixture rather than assuming the unit-test fixture initializes every editor subsystem.

Do not start a new test-enabled build while the existing build is running. Record build configuration and result. Consider a separate output/worktree strategy before maintaining multiple build configurations; do not let builds share mutable artifacts concurrently.

## Layers

1. **Deterministic executor and validators:** fixed typed requests exercise classes, ownership, resource compatibility, stale targets, undo/redo, and no-partial-change guarantees. No device or language model is required. Prefer native engine tests for native logic; use editor integration fixtures where EditorNode and undo services are required.
2. **Fake Tiiny service and SDK adapter:** return catalog/status fixtures, valid tool calls and artifacts, and controlled failures. Test role selection, parsing, retries, queueing, resource generation, and tool-result messages. Never require network credentials for these tests. Make the transport injectable so tests do not accidentally contact or unload a real device.
3. **Disposable Godot project:** launch a test editor/headless process where supported; inspect resulting scenes and resources, save/reopen, run controlled scenes, and assert outcomes. Reset editor settings into an isolated test directory. Use a displayed test editor for focus, layout, dock, and dialog behavior that headless checks cannot establish.
4. **Real Tiiny integration:** explicitly selected hardware suite verifies installed SDK behavior, downloads, loads, actual capability, capacity, disconnect/recovery, and model outputs. Use a dedicated test configuration, save the intended warm set, and report restoration success or failure. These checks may change the exclusively managed device and should not run as an incidental unit test.
5. **Model-quality evaluations:** run natural-language scenarios repeatedly and score the final workspace state, allowed operations, unnecessary script creation, completion, and latency. Test paraphrases and record exact model/service/settings. Deterministic executor checks remain strict; inference quality is measured statistically.

## Evidence

Each acceptance run records scenario IDs, test command/configuration, pass/fail/skipped status, relevant model/service versions, and artifact/tool-trace locations. A skipped hardware test is not a passing hardware test. Avoid storing API keys, unrelated project files, or private prompts in committed logs. Small fixture assets and sanitized protocol examples can be checked in.

For visual/audio quality, use structural checks first (valid imports, dimensions, material slots, duration, sample rate) and human review where necessary. A screenshot pixel comparison cannot establish that a generated material is physically appropriate; audio decoding cannot establish musical quality. Keep those criteria explicit.

## Initial rollout

During active item 01, extract the embedded scripts for parsing, establish a small project fixture, and add fake responses for a successful chat/tool result and a malformed/failed request. Run the real-device chat/resource smoke checks separately. During items 05–06, add deterministic scene-operation and undo/redo tests before connecting those operations to model planning. Expand the fake service and scenario coverage with the corresponding implementation items; do not build the entire future harness ahead of the active milestone.

The test harness described here is planned; this document does not claim it has been implemented or run.

## Early job-manager tests

Item 02 uses fake workers to prove durable append order, one-job execution, append-during-run, pause/failure stopping, retry at the stopped position, explicit skip semantics, and restart reconciliation. Use controlled crashes around promotion/import boundaries and a real reviewed headless Godot fixture generator. No dependency-graph or parallel-lane tests belong to the first FIFO version. Fake-worker success does not establish real-device behavior or filesystem isolation.
