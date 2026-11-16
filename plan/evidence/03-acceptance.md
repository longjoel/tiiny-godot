# Story 03 — acceptance evidence

Story 03 is accepted on deterministic/fake-device and live evidence. A later story 04 verification run sent real coding inference and performed one download-only Apply; no model was loaded, unloaded, or deleted. The device warm set was preserved.

Executable: `bin/godot.linuxbsd.editor.x86_64`, version `4.8.beta.custom_build.d7494670c`. Final build PID 689347 exited 0 in 31.29s with `scons platform=linuxbsd target=editor use_static_cpp=no -j8`. No build remains running.

## Criterion matrix

| Parent criterion | Evidence | Limits |
| --- | --- | --- |
| Bind management and inference to the intended device | The two-endpoint loopback fixture reaches only the configured endpoint and checks the fake CLI's `--device-address`. Live runs reached the real Tiiny through the configured address and credentials, sent real chat and polygon inference, and performed a download through the FIFO. `inference_connection()` rejects an API URL on a different device. `test_stabilization.gd` also rejects readiness after an address or key change. | None for the bound-device path. |
| Validate and persist the coding model | `check_model_configuration.py --editor-smoke` passes fake Apply rejection for incompatible or Tool-Use-less coding models before mutation. Verified preferences are persisted only after the final device check. The new catalog cache lets startup explain a saved model that disappeared from the catalog or lost Tool Use without mutating the device. The FIFO built-in Jobs fixture checks restoration and persistence. | No real deliberate coding-model replacement was attempted. |
| Confirm download/load from device state | Fake-device fixtures reject zero-exit downloads without `installed`, zero-exit loads without `loaded`, and loads whose observed NPU allocation differs from the catalog. Built-in Jobs fixtures record each device operation in the FIFO journal and clear it only after inventory verification. A real download-only Apply confirmed `installed` and reported seven device progress updates. | No real load ran. |
| Restore and protect the coding model | Built-in Jobs covers startup/reconnect restoration, download-then-load, capacity rejection, stale restore, and preflight restoration for chat, resource, and Apply jobs. The planner and restoration path never unload another model to make room. Live chat and polygon inference used the existing warm coding model. | Live restoration could not proceed: the configured kept set needs 101 NPU units plus 5 reserved against 100 available. No model was evicted. |
| Recoverable failure without false readiness | Fake-device checks cover disconnect, authentication, capacity, partial results, cancellation, read-only observation, and explicit acknowledgement. `check_device_lease.py` passes process-kill recovery for model work and inference, cross-project blocking, explicit recovery, and a corrupt marker. Built-in Jobs passes interruption, inspection, acknowledgement, and no-blind-retry cases. | An observation still cannot prove a remote process stopped; the UI keeps the job stopped. |

## Runs

| Check | Result | Report/log |
| --- | --- | --- |
| Planner/panel, embedded-script parse, invalid-script rejection | Passed | `/tmp/tiiny-story04-final-live-displayed.json`, `/tmp/tiiny-story04-final-editor.json` |
| `check_model_configuration.py --editor-smoke` | Passed, including fake inventory failures, chat protocol, staged Apply contract, CLI lifecycle, native dialogs, and editor-tree shutdown | `/tmp/tiiny-story04-final-editor.json`, `/tmp/tiiny-story04-final-editor.log` |
| `check_model_configuration.py --live-readonly` | Passed inventory and Check Config; capacity rejection `Keep-loaded models need 101 NPU units plus 5 reserved; only 100 exist`; no Apply | `/tmp/tiiny-story04-final-live-displayed.json` |
| `check_device_lease.py` | Passed | command output: `Cross-process device lease passed` |
| `check_builtin_jobs.py`, all 24 modes | Passed on build `d7494670c` | `/tmp/tiiny-story04-final-jobs.log` |
| `--live-inference` | Passed earlier on `d7494670c`: real chat and polygon; warm set unchanged. Two final retries timed out during classification with residency unchanged. | `/tmp/tiiny-story04-live-inference.json` |
| `--live-apply` download-only | Passed; `Supertone/supertonic-3`, 225,936,268 bytes, seven device progress updates, warm set unchanged | `/tmp/tiiny-story04-live-apply.log`, `/tmp/tiiny-story04-final-live-apply-verify.json` |

## Residual hardware boundary

The live device's current kept set leaves no NPU headroom for restoration without unloading a model the user did not ask to remove. Real warm-set-changing load/unload and restoration remain explicitly skipped rather than passed. Story 04's download-only Apply did not change residency. Story 10 extends on-demand specialized-model scheduling; DEV-01's specialized-model swap and post-job restoration remain outside story 03.
