# Story 01 baseline — initial stabilization slice

Recorded November 14, 2026 (America/Chicago). Story 01 remains active; this report does not accept the whole story.

Baseline revision: `f4905e0242852415cf22e8daeed18e4fd960eb85`. The dirty worktree for this slice contains test harness/fixture and planning/documentation changes only; no production editor source changed. The JSON report records the exact per-run file list.

Reused binary: `bin/godot.linuxbsd.editor.x86_64`, version `4.8.beta.custom_build.960f4db5b`. The version's upstream revision predates the integration commit; record hashes rather than treating the version string as the current checkout revision.

| Identity | SHA-256 |
| --- | --- |
| Editor executable | `c6af2064517f807a5499ed466940f6b5e817ab3e73f5eedff9e4ce2c3614db0a` |
| Manager source header | `f4ade6eace7a586552298e24c8e70c5993c247ed1daccbe82f73c7c4e6f9f375` |
| Chat source header | `0fa8a8617a1b61da0e9c2c06fca4a38694e81163c58cdcd72de20d3b9ff9c3b4` |

Last linked build: session `23308`, exit 0, 30.90 seconds, `scons platform=linuxbsd target=editor use_static_cpp=no -j8`. Full compiler invocation was not retained for that historical build. Current available `c++ --version` reports GCC 16.2.1 20261029 (Red Hat 16.2.1-3); this observation alone does not prove the historical compiler invocation. No build was started for this test/documentation slice.

Reproduce the baseline:

```sh
python3 integrations/tiiny/tests/check_model_configuration.py --editor-smoke --report /tmp/tiiny-story01-baseline.json
```

An additional isolation check ran the same command with deliberately inherited fixture values `TIINY_TEST_LIVE_READONLY=1` and `TIINY_API_KEY=fixture-inherited-key`. It still took the offline branch, passed unconfigured-device startup, and invoked only the local fake CLI. Offline runs use a temporary HOME and XDG directories, clear inherited Tiiny environment variables, and do not read normal SDK configuration. This is test configuration isolation, not an operating-system network or filesystem sandbox.

| Check | Result |
| --- | --- |
| Exact embedded manager/chat parsing | Passed; zero GDScript errors |
| Planner, migration, panel geometry, popup and progress checks | Passed |
| Embedded scripts initialize in the real editor | Passed; one chat dock and manager |
| Fresh unconfigured startup/refresh | Passed; not ready, no pending Apply, not busy |
| Catalog failure on refresh and Check Config | Passed; finite error, no SDK execution |
| Empty catalog | Passed; available inventory but not ready; required-model check fails |
| Invalid catalog envelope and capacity failure | Passed; unavailable, busy cleared, no Apply |
| Fake Apply, stale/expired checks and false SDK success | Passed |
| Nonblocking CLI with local percentage stub | Passed; no real SDK invocation |
| Actual settings Models panel | Passed headless; displayed layout not established |

The runner records stage exit codes, elapsed time, source/binary hashes, and diagnostic counts, without environment values or request payloads. The editor smoke exits 0 with its explicit success marker and zero GDScript errors. It also emits nine engine error diagnostics: required virtual methods in MultiplayerPeerExtension/WebRTCDataChannelExtension, sandbox debug-server sockets, and secondary null-image errors while displaying those diagnostics. These remain recorded limitations; the passing fixture result is not a clean engine-startup claim.

Remaining gates: inference transport/response fixtures, chat/tool validation and continuation recovery, slow/missing CLI and shutdown, readiness staleness behavior, ordinary resource creation and dialog cancellation/late responses, displayed UI review, and separately selected real-device chat/polygon checks. No actual model download/load/unload or inference ran in this slice. Do not start item 02 until the parent acceptance criteria pass.
