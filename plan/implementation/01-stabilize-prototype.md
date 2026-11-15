# Story 01 implementation plan — establish a verified baseline

Status: Complete — accepted prototype baseline. [Completion evidence](../evidence/01-completion.md) records all parent criteria, commands, identities, displayed UI and hardware results, and explicit later-story limitations.

Parent: [01 — Stabilize the existing prototype](../work-items/01-integration-stabilize.md)

## Backlog review and boundary

Story 01 is accepted. Story 02 is the next foundational feature and can inherit the verified baseline and transport boundaries. It remains queued; no job-manager code was implemented here. Its initial slices follow its implementation plan: durable append/state, serial dispatch with fake workers, real generator validation, Jobs UI/append tools, then restart/retry/retention. No dependency graph or parallel dispatch belongs to the first FIFO version. Stories 03–04 expand lifecycle and settings. Their existing prototype code is part of the baseline to stabilize; completing their broader acceptance is separate work.

Story 01 verifies the behavior already exposed: startup, settings and chat placement, parsing and transport failures, bounded tool execution, ordinary resource creation, and the supported polygon experiment. Add only the minimal test seams and fixes required for that baseline. Do not implement the job manager, workspace scene editing, undo/redo, new model adapters, or a broad UI redesign here. General gameplay-script generation remains a prototype tool, not the preferred product direction.

## Current baseline and carried evidence

- Initial Tiiny integration commit: `f4905e0242` on `master` (pushed to the fork).
- Latest linked editor: SCons session `23308`, exit 0, duration `00:00:30.90`; command `scons platform=linuxbsd target=editor use_static_cpp=no -j8`.
- Existing `integrations/tiiny/tests/check_model_configuration.py` extracts both embedded scripts, parses them, runs planner/panel tests, and optionally opens the real settings screen with fake Apply/CLI fixtures. Reuse and strengthen it rather than introduce a competing harness.
- Prior headless checks pass, including settings migration into Models/Advanced, capacity validation, draft expiry, false-positive SDK exits, and percentage forwarding. These establish bounded automated behavior, not displayed UI quality or real-device success.
- Keep build, exact-source parser, embedded-binary startup, offline protocol, displayed UI, and hardware evidence separate. A changed header parsing under the old executable does not prove that executable contains it.

## Inspection targets against current code

1. **Catalog failure:** the former auto-apply fallback cycle no longer exists. Exercise `_fetch_snapshot`, `refresh_device`, and `check_config` failure paths; each must finish without device mutation, clear busy state, and disable Apply/readiness appropriately.
2. **Readiness:** `_next()` is gone. Verify `is_ready()` against the configured coding model, connected state, and snapshot age, separately from successful CLI exit and verified Apply.
3. **Shutdown:** the manager now uses nonblocking `OS.execute_with_pipe` and a bounded `timeout` process, not a joined worker thread. Test slow/missing CLI and shutdown without assuming those changes establish process cleanup.
4. **Completed tool effects:** a script/image may survive a failed continuation. Surface the actual completed artifact and keep later chat usable; never retry a mutation blindly.
5. **Shared resource dialog:** test ordinary node/resource creation, blank prompts, selection changes, cancellation, and late responses.
6. **Offline initialization:** fresh settings expose Models and Advanced, with one Tiiny Chat dock. No automatic model mutations, obsolete settings tabs, or reliance on real credentials in offline tests. A missing Tiiny must not prevent opening or closing the editor.

## Implementation sequence

### 1. Capture and reproduce the baseline — initial gate passed

- Record the build identity, source revision plus dirty-file list, compiler/build options, and command in a sanitized evidence report.
- Confirm no build is running before scheduling another. Reuse the successful editor for script checks; do not enable all engine tests and trigger a second broad rebuild merely to validate this prototype.
- Extend the existing extraction/check runner for the exact GDScript embedded in the two source headers. Parse it using this editor and fail on missing delimiters, parse errors, or a nonzero exit. Do not hand-maintain copied script fixtures that can drift from the binary source.
- Reuse the runner’s disposable minimal Godot project. Give it isolated editor data/settings using a verified supported mechanism; avoid the user's normal project and saved credentials.

Deliverables: repeatable parser/startup commands, fixture project, baseline failure list. Gate: reproduce failures before modifying behavior where practical.

### 2. Introduce narrow offline test seams — passed

- Make HTTP and SDK execution replaceable at their boundaries; retain the real production path. A lightweight localhost fake inference service and fake CLI executable are sufficient.
- Ensure test startup disables real device mutations before manager initialization. The fake CLI should implement only the commands and output shapes consumed by current code.
- Supply fixtures for installed/remote/loaded tables, empty lists, status/capacity, SDK error exits, and slow commands. Unknown output must produce an explicit failure rather than being treated as an empty valid inventory.
- Supply inference responses for text, one supported tool call/result/continuation, malformed responses, unsupported calls, tool errors, HTTP failures, and timeouts. Use a tiny fixture PNG instead of real image generation.

Deliverables: fixtures and an offline test command with bounded execution, a useful exit code, and sanitized logs. Gate: this command cannot contact or unload the real Tiiny, even with normal credentials present.

### 3. Repair startup and manager defects — passed

- Verify catalog/capacity failure terminates in a clear unavailable state; the retired fallback cycle is not an implementation target. Fix current defects reproduced by the fixtures.
- Consolidate readiness reporting behind actual required-model verification. Errors must leave operations disabled or retryable, never falsely ready.
- Test a slow/missing CLI and editor shutdown. Implement only the bounded process/lifecycle handling needed to avoid an indefinite startup/shutdown hang. Record the interface that story 02 will replace or reuse.
- Check fresh settings and persisted settings. Preserve compatible values; report invalid role selections rather than silently selecting a different model.

Gate: offline startup/shutdown, catalog failure, malformed SDK data, and missing required model pass deterministic checks. Do not add reconnect scheduling or per-task model swaps here.

### 4. Stabilize the existing chat/tool protocol — passed offline/HTTP baseline

- Validate response envelopes, tool names, argument shapes, call IDs, and execution limits before dispatch.
- Exercise normal text → tool → tool-result → final-text flow, plus unsupported/malformed/multiple calls and exhausted step limits according to the current supported protocol.
- Assert that no unsupported tool mutates fixture files; a duplicate create request cannot overwrite a file. Check traversal/invalid script paths and invalid generated script content.
- Simulate a successful file/image creation followed by a failed continuation. Keep a visible record of the completed artifact and allow the next chat request to work.
- Ensure controls recover from HTTP, parse, timeout, and tool errors. Logs should identify failures without exposing credentials or image payloads.

Gate: WS-15 relevant baseline cases pass with a fake service, including a subsequent successful request after each failure. More capable planning and generalized orchestration remain story 07.

### 5. Validate resource-dialog compatibility and UI placement — passed

- Exercise ordinary node creation and unsupported-resource creation without invoking AI.
- For ConvexPolygonShape2D, test blank prompt, valid points, invalid/degenerate/non-finite/oversized data, and save/reopen of the accepted resource.
- Test cancellation, selection changes, and late responses. A result must never be assigned to another target or reopen a cancelled dialog unexpectedly.
- In a displayed editor, confirm one Tiiny Chat side dock, configuration under Editor Settings > Tiiny AI, and no standalone Tiiny Assistant or Tiiny Models settings tabs.
- Confirm status/errors reach Output while a fixture scene runs. Record UI assertions/screenshots where useful; headless success alone does not establish visual layout.

Gate: WS-07 baseline passes, along with the ordinary creation regression checks. Avoid new resource types or UI features.

### 6. Run explicit real-device smoke checks — chat/polygon passed; image explicitly unverified

- Snapshot the intended Tiiny warm set and service/model versions without logging credentials. Verify that inference and SDK management address the same device.
- Run one real chat request and one valid polygon-resource request with the selected coding model. Validate the saved resource in Godot; do not score a model's exact prose.
- If image tooling is advertised as working, run one real image-tool smoke check with a configured image model already warm, record the real response format, and verify import. If blocked, label it experimental/unverified rather than imply coverage.
- Check the final loaded set and restore the intended warm configuration if testing changed it. Report restoration success or failure explicitly.

Gate: real chat and supported shape creation have evidence. Unavailable hardware is a recorded blocker for those acceptance checks, not a substitute passing result from fake inference. Test failures unrelated to the prototype's baseline remain separate backlog entries.

### 7. Rebuild only when needed and close the story — passed

- Announce any required build and its scope/command; use consistent options and suitable parallelism (start with `-j8` on this machine if memory remains suitable). Never overlap builds in the shared checkout.
- If C++ or embedded production scripts changed, rebuild and rerun relevant checks against the resulting executable. If only fixtures/docs changed, reuse the existing editor.
- Update the integration README from observed results. Record what is built, parsed, runtime-tested, and device-tested separately.
- Complete the evidence matrix below and update STATUS.md. Start story 02 only after all parent-story criteria pass; record rather than hide blockers.

## Acceptance evidence matrix

| Parent criterion | Evidence required | Starting state |
| --- | --- | --- |
| Reproducible linked editor | SCons command, build identity, exit code, binary | Passed build observed; retain report |
| Both scripts parse and load | Exact-source parser output plus editor startup log | Passed baseline run; see evidence report |
| Settings and chat placement | Displayed-editor observations and ordinary creation check | Passed displayed X11/Wayland, normal settings view, native node/resource creation |
| Offline startup/inventory failures | Credential-isolated startup and fake HTTP boundary checks | Passed; no SDK execution |
| Offline tool protocol/recovery | Fake response/tool error report | Passed script-tool/response fixtures; see protocol evidence |
| Real chat and shape creation | Separate device smoke and saved resource report | Passed real Tiiny chat and four-vertex polygon save/reopen; unchanged warm set |
| README matches observed behavior | Review against verification report and known limitations | Reviewed; live image generation and mutating Apply explicitly unverified |

Suggested implementation locations (create only as needed): `integrations/tiiny/tests/` for the runner, fake service/CLI and fixtures; `integrations/tiiny/tests/project/` for the disposable project template; an ignored per-run directory for logs, settings and generated artifacts. Keep API keys and private captures out of version control. Production fixes are expected in the existing editor source/header files rather than an unrelated refactor.

Closure: [completion evidence](../evidence/01-completion.md) supersedes the earlier partial baseline/protocol reports. Final build `7620` and final UI/hardware reports pass. Process cleanup, readiness freshness, native resource compatibility/late responses, loopback HTTP timeouts/image import, running-scene Output, and displayed UI are verified. Real chat and polygon generation pass with the original loaded set preserved. No image model was warm; real image generation remains experimental rather than being counted as a passed check. No model-management Apply was executed. Story 02 may begin from this baseline; its implementation has not started.
