# Story 01 implementation plan — establish a verified baseline

Status: Ready to execute; implementation and runtime acceptance pending.

Parent: [01 — Stabilize the existing prototype](../work-items/01-integration-stabilize.md)

## Backlog review and boundary

Keep story 01 active. Story 02 is the first foundational feature, but it should inherit a functioning editor and tested transport boundaries rather than unverified prototype behavior. Its initial slices should be persistence/state, fake workers/dependencies, then real headless execution and Jobs UI. Stories 03–04 expand lifecycle and settings; do not pull those complete features into stabilization.

Story 01 verifies the behavior already exposed: startup, settings and chat placement, parsing and transport failures, bounded tool execution, ordinary resource creation, and the supported polygon experiment. Add only the minimal test seams and fixes required for that baseline. Do not implement the job manager, workspace scene editing, undo/redo, new model adapters, or a broad UI redesign here. General gameplay-script generation remains a prototype tool, not the preferred product direction.

## Verified starting evidence

- The outstanding SCons session `45249` completed with exit code 0 and linked `bin/godot.linuxbsd.editor.x86_64`.
- Reported build duration: `00:35:11.72`.
- Command: `scons platform=linuxbsd target=editor use_static_cpp=no bin/godot.linuxbsd.editor.x86_64 -j2`.
- This establishes a successful build only. It does not establish embedded-script parsing, editor startup, UI correctness, or real Tiiny tool execution.
- Build evidence was checked while preparing this plan. No new build or hardware mutation was started.

## Inspection findings to reproduce

These are specific test targets, not a declaration that every risk is a confirmed runtime defect.

1. **Catalog failure can loop:** in `editor/tiiny_ai_manager_source.h`, failed online catalog plus auto-apply falls back to installed models, which advances to capacity and then online catalog again. Test that sequence and make fallback finite.
2. **Readiness has more than one success path:** `_next()` can announce readiness for an empty applying queue, while a separate verify phase reads loaded models. Require readiness to follow verified required-model state.
3. **Shutdown can block:** `_exit_tree()` waits for a thread executing the SDK process. Reproduce with a delayed fake CLI; establish bounded shutdown/failure behavior without building the future scheduler.
4. **Tools have durable effects before a final reply:** a created script/image may exist even if the next model call fails. Surface that result and keep later conversation state usable; never retry a mutation blindly.
5. **The resource dialog is shared:** check ordinary node/resource creation, blank prompts, changed selection, cancellation, and late responses. AI additions must not hijack unrelated creation flows.
6. **Settings and workers are initialized by embedded scripts:** check fresh settings, no configured device, manager disabled, and offline startup. Absence of a Tiiny must not prevent the editor from opening or closing.

## Implementation sequence

### 1. Capture and reproduce the baseline

- Record the build identity, source revision plus dirty-file list, compiler/build options, and command in a sanitized evidence report.
- Confirm no build is running before scheduling another. Reuse the successful editor for script checks; do not enable all engine tests and trigger a second broad rebuild merely to validate this prototype.
- Add a small extraction/check runner for the exact GDScript embedded in the two source headers. Parse it using this editor and fail on missing delimiters, parse errors, or a nonzero exit. Do not hand-maintain copied script fixtures that can drift from the binary source.
- Create a disposable minimal Godot project. Give it isolated editor data/settings using a verified supported mechanism; avoid the user's normal project and saved credentials.

Deliverables: repeatable parser/startup commands, fixture project, baseline failure list. Gate: reproduce failures before modifying behavior where practical.

### 2. Introduce narrow offline test seams

- Make HTTP and SDK execution replaceable at their boundaries; retain the real production path. A lightweight localhost fake inference service and fake CLI executable are sufficient.
- Ensure test startup disables real device mutations before manager initialization. The fake CLI should implement only the commands and output shapes consumed by current code.
- Supply fixtures for installed/remote/loaded tables, empty lists, status/capacity, SDK error exits, and slow commands. Unknown output must produce an explicit failure rather than being treated as an empty valid inventory.
- Supply inference responses for text, one supported tool call/result/continuation, malformed responses, unsupported calls, tool errors, HTTP failures, and timeouts. Use a tiny fixture PNG instead of real image generation.

Deliverables: fixtures and an offline test command with bounded execution, a useful exit code, and sanitized logs. Gate: this command cannot contact or unload the real Tiiny, even with normal credentials present.

### 3. Repair startup and manager defects

- Reproduce and fix the catalog fallback cycle; installed-only/offline handling must terminate in a clear verified-ready or unavailable state.
- Consolidate readiness reporting behind actual required-model verification. Errors must leave operations disabled or retryable, never falsely ready.
- Test a slow/missing CLI and editor shutdown. Implement only the bounded process/lifecycle handling needed to avoid an indefinite startup/shutdown hang. Record the interface that story 02 will replace or reuse.
- Check fresh settings and persisted settings. Preserve compatible values; report invalid role selections rather than silently selecting a different model.

Gate: offline startup/shutdown, catalog failure, malformed SDK data, and missing required model pass deterministic checks. Do not add reconnect scheduling or per-task model swaps here.

### 4. Stabilize the existing chat/tool protocol

- Validate response envelopes, tool names, argument shapes, call IDs, and execution limits before dispatch.
- Exercise normal text → tool → tool-result → final-text flow, plus unsupported/malformed/multiple calls and exhausted step limits according to the current supported protocol.
- Assert that no unsupported tool mutates fixture files; a duplicate create request cannot overwrite a file. Check traversal/invalid script paths and invalid generated script content.
- Simulate a successful file/image creation followed by a failed continuation. Keep a visible record of the completed artifact and allow the next chat request to work.
- Ensure controls recover from HTTP, parse, timeout, and tool errors. Logs should identify failures without exposing credentials or image payloads.

Gate: WS-15 relevant baseline cases pass with a fake service, including a subsequent successful request after each failure. More capable planning and generalized orchestration remain story 07.

### 5. Validate resource-dialog compatibility and UI placement

- Exercise ordinary node creation and unsupported-resource creation without invoking AI.
- For ConvexPolygonShape2D, test blank prompt, valid points, invalid/degenerate/non-finite/oversized data, and save/reopen of the accepted resource.
- Test cancellation, selection changes, and late responses. A result must never be assigned to another target or reopen a cancelled dialog unexpectedly.
- In a displayed editor, confirm one Tiiny Chat side dock, configuration under Editor Settings > Tiiny AI, and no standalone Tiiny Assistant or Tiiny Models settings tabs.
- Confirm status/errors reach Output while a fixture scene runs. Record UI assertions/screenshots where useful; headless success alone does not establish visual layout.

Gate: WS-07 baseline passes, along with the ordinary creation regression checks. Avoid new resource types or UI features.

### 6. Run explicit real-device smoke checks

- Snapshot the intended Tiiny warm set and service/model versions without logging credentials. Verify that inference and SDK management address the same device.
- Run one real chat request and one valid polygon-resource request with the selected coding model. Validate the saved resource in Godot; do not score a model's exact prose.
- If image tooling is advertised as working, run one real image-tool smoke check with a configured image model already warm, record the real response format, and verify import. If blocked, label it experimental/unverified rather than imply coverage.
- Check the final loaded set and restore the intended warm configuration if testing changed it. Report restoration success or failure explicitly.

Gate: real chat and supported shape creation have evidence. Unavailable hardware is a recorded blocker for those acceptance checks, not a substitute passing result from fake inference. Test failures unrelated to the prototype's baseline remain separate backlog entries.

### 7. Rebuild only when needed and close the story

- Announce any required build and its scope/command; use consistent options and suitable parallelism (start with `-j8` on this machine if memory remains suitable). Never overlap builds in the shared checkout.
- If C++ or embedded production scripts changed, rebuild and rerun relevant checks against the resulting executable. If only fixtures/docs changed, reuse the existing editor.
- Update the integration README from observed results. Record what is built, parsed, runtime-tested, and device-tested separately.
- Complete the evidence matrix below and update STATUS.md. Start story 02 only after all parent-story criteria pass; record rather than hide blockers.

## Acceptance evidence matrix

| Parent criterion | Evidence required | Starting state |
| --- | --- | --- |
| Reproducible linked editor | SCons command, build identity, exit code, binary | Passed build observed; retain report |
| Both scripts parse and load | Exact-source parser output plus editor startup log | Pending |
| Settings and chat placement | Displayed-editor observations and ordinary creation check | Pending |
| Real chat, failure cases, shape creation | Offline regression report plus separate device smoke report | Pending |
| README matches observed behavior | Review against verification report and known limitations | Pending |

Suggested implementation locations (create only as needed): `integrations/tiiny/tests/` for the runner, fake service/CLI and fixtures; `integrations/tiiny/tests/project/` for the disposable project template; an ignored per-run directory for logs, settings and generated artifacts. Keep API keys and private captures out of version control. Production fixes are expected in the existing editor source/header files rather than an unrelated refactor.
