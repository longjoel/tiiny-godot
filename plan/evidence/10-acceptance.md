# Story 10 — acceptance evidence

Story 10 is accepted for the implemented scheduling path. Specialized model transitions are now a first-class FIFO job (`model_schedule`) with a pure capacity/eviction planner, coding-model protection, per-operation journaling, cancellation, disconnect handling, and configured-warm-set restoration.

Executable: `bin/godot.linuxbsd.editor.x86_64`, version `4.8.beta.custom_build.dca9eec4a`. No build or test remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Model transitions and inference use the coordinated queue and actual state | `model_schedule` is validated by the Jobs panel, dispatched through the shared `ModelWorker`/executor, and journals every `download`/`load`/`unload` before execution. The manager re-reads a fresh device snapshot before planning and after each command. Existing `chat_turn`, `resource_shape`, `model_apply`, `model_preflight`, and `model_restore` paths remain in the same FIFO. |
| Evict eligible models while retaining coding; reject impossible combinations | `Planner.schedule` protects the configured and currently loaded coding model, excludes it from eviction, and checks overhead + coding allocation + requested allocation + reserve before any command. The `model_schedule` fixture verifies the calls `unload image`, `load special`, `unload special`, `load image` while `code` stays loaded. The capacity fixture (`47 + 60 + 5 > 100`) fails with no device calls and an error containing “retaining the scripting model”. |
| Restore the configured warm set after success, failure, or cancellation when permitted | The success fixture ends with the configured `code` + `image` set loaded and only `special` removed. `model_schedule_restore` exercises the failure and cancellation paths directly: `special` is unloaded and `image` is reloaded even with the cancellation flag set, and the failure message reports warm-set restoration. Unverified device commands stop further commands instead of issuing an unsafe restore. |
| Progress and cancellation observable and non-blocking | Scheduling uses the existing CLI progress reader and `device_operation_progress` journal. The manager awaits timers rather than blocking. Cancellation stops the owned CLI and follows the existing uncertain-outcome lease rules. Existing `model_preflight_cancel` and `model_schedule_restore` cover cancellation semantics. |
| Disconnects and capacity errors, recovery without duplicate jobs | `model_schedule_capacity` verifies no mutation and a clear capacity error. `model_schedule_disconnect` submits while the device snapshot fails, verifies a failed job with no device calls, re-submits with the same submission key and gets the same job ID (no duplicate), then clears the failure, resolves/skips the stopped job, resumes dispatch, and completes a fresh schedule with the warm set restored. |
| Record tested combinations and measured behavior | Fixture combinations: coding `code` (47 NPU) protected with image `image` (23) and temporary `special` (10); rejection at `code` 47 + `big_image` 60 + reserve 5 against 100. Catalog NPU values are treated as planning estimates, not guaranteed RAM. Live device measurements (Ornith 54 NPU retained): `Supertone/supertonic-3` load **8.374 s**, unload **6.327 s**; `Tencent/Hunyuan3d-2.1` load **33.499 s**, unload **6.552 s**; both coexisted with the coding model at 76 NPU units and the original `[Ornith]` warm set was restored afterward. During story 13, both specialized models were unloaded/reloaded through `model_schedule` while Ornith stayed loaded. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Planner/panel offline checks | Passed schedule eviction/restore, coding protection, already-loaded no-op, capacity/disk/unknown rejection, and no input mutation | `/tmp/tiiny-story10-parse.json` |
| Jobs suite | Passed all 31 modes, including `model_schedule`, `model_schedule_capacity`, `model_schedule_restore`, and `model_schedule_disconnect` | `/tmp/jobs-10-full2.log` |
| Editor smoke + restart stages | Passed 11/11 stages | `/tmp/tiiny-story10-smoke.json` |
| Transaction/registry fixture | Passed | `/tmp/transactions-10.log` |
| Loopback resource HTTP fixture | Passed | `/tmp/resource-http-10.log` |
| Live model swaps and load/unload timings | Passed on-device: TTS load 8.374 s / unload 6.327 s; Hunyuan3D load 33.499 s / unload 6.552 s; coding model retained at 54 NPU; 76 NPU coexisting set; original `[Ornith]` warm set restored | shell timing runs; `/tmp/asset-live3.log` |
| Build | Exit 0, `00:00:33.29` and `00:00:29.99` incremental, same binary | `/tmp/tiiny-story10-build.log`, `/tmp/tiiny-story10-build2.log` |

## Remaining boundaries

- Live timings are single-run wall-clock measurements for these two models on the current device; they are not a benchmark distribution or a RAM guarantee.
- Catalog NPU units remain planning estimates.
- `model_schedule` prepares/releases capacity and restores the warm set. Chat/resource inference still uses its existing coding preflight; generator jobs in story 13 require their specialized model to be loaded or scheduled first.
- An unverified device command stops the job for reconciliation; automatic restoration is deliberately not attempted from an unknown device state.
- `restore=false` is supported for explicit callers and skips warm-set restoration; the dock defaults to `restore=true`.
