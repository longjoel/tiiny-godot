# Story 01 — offline chat protocol and continuation recovery

Recorded November 14, 2026 (America/Chicago). Continues [the initial baseline](01-baseline.md); story 01 remains active.

Reproduced before repair: fixture session `35895` failed because a tool call with an empty ID created a script. No real device was contacted; the file was inside the temporary test project. The pre-fix JSON report is `/tmp/tiiny-story01-protocol-before.json` for this workspace session.

Production fixes in `editor/tiiny_ai_dock_source.h` validate assistant envelopes, one function call per response, nonempty/bounded/unique call IDs, argument types/JSON, and the four-round limit before dispatch. Unknown tools or invalid supported arguments produce matched tool errors. Both initial chat and tool continuation use `_submit_chat`, which fixtures replace without opening inference sockets. Completed tool results immediately appear in chat and are retained in conversation context, even if continuation fails. HTTP error bodies are not copied into Output.

Final build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, session `32216`, exit 0, 39.55 seconds. No build remains running. Binary version is `4.8.beta.custom_build.f4905e024`; worktree production changes are included despite the unchanged HEAD.

| Identity | SHA-256 |
| --- | --- |
| Editor executable | `d1c08cc790194c3447f4534d8b728b4c40852f9a85d9ebe69839237dec491d84` |
| Chat header | `ed6e3af0801765a9d825d688107bd5ef75ab54a828a37e1125283a189689ff97` |
| Manager header (unchanged) | `f4ade6eace7a586552298e24c8e70c5993c247ed1daccbe82f73c7c4e6f9f375` |

Reproduce:

```sh
python3 integrations/tiiny/tests/check_model_configuration.py --editor-smoke --report /tmp/tiiny-story01-protocol.json
```

Final test session `71369` exited 0. Exact-source parsing, planner/panel checks, invalid-code rejection, inventory failures, chat protocol, fake Apply/CLI, and the actual settings panel passed. The built-in dock separately rejects the empty-ID mutation, guarding against testing extracted fixes with a stale embedded script.

| Protocol scenario | Result |
| --- | --- |
| Plain text, including null tool_calls | Passed |
| Normal create-script → matched result → final text | Passed; real temporary GDScript written |
| Invalid/empty envelopes, invalid JSON, wrong role | Passed; controls recover and subsequent turn succeeds |
| Empty/oversized IDs, malformed calls/arguments, multiple calls | Passed; no target file written, no continuation dispatched |
| Repeated ID and exhausted round budget | Passed; second mutation rejected |
| Unsupported tool and traversal | Passed; matched error result, no mutation |
| Duplicate create | Passed; original script preserved |
| Simulated timeout, HTTP 401, initial submission failure | Passed; controls recover and next turn succeeds |
| Completed file followed by HTTP 503 or continuation-start error | Passed; file/result remain visible and in context; next turn succeeds |
| Backend error body echoes fixture key/image payload | Passed; neither reaches Output |
| Invalid generated script | Passed in separate process; no file written and exactly one expected parse diagnostic |

All other stages report zero GDScript diagnostics. The headless editor retains the nine known engine initialization diagnostics described in the initial report. Fake completions test application response handling; they do not establish actual HTTP timeouts, inference service behavior, image-generation adapter correctness, real-device generation, or displayed UI quality.

Remaining story gates include slow/missing SDK process cleanup and shutdown, readiness staleness, resource-dialog compatibility and late responses, image adapter/real HTTP testing, displayed UI, and separately selected hardware chat/polygon checks. Long-session context reset/overflow behavior also needs coverage; this slice proves recovery for bounded fixture conversations. Item 02 stays queued.
