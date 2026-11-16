# Story 04 — acceptance evidence

Story 04 is accepted. The Models screen stages a capability-filtered draft, checks it against fresh device capacity, and applies only after explicit review. One real download-only Apply was performed with temporary editor settings; it downloaded `Supertone/supertonic-3` (225,936,268 bytes), reported seven device progress updates, completed from device state, and left the warm set unchanged. No model was loaded, unloaded, or deleted.

Executable: `bin/godot.linuxbsd.editor.x86_64`, version `4.8.beta.custom_build.d7494670c`. Final build PID 689347 exited 0 in 31.29s with `scons platform=linuxbsd target=editor use_static_cpp=no -j8`. No build remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Roles filtered by verified capabilities; unavailable roles explained | Capability-filtered pickers add a disabled `No compatible model` entry and an explanation; DEV-03 images-only catalog rejects scripting with no actions; captured at 1400/600 px. |
| Installed/downloaded and loaded states distinct; warm persists; coding required | One-table vocabulary `Loaded` / `Downloaded` / `Not downloaded` / `Unavailable`; coding keep-loaded is disabled-checked; three-process restart fixture proves applied warm selections and context survive and an unapplied draft does not. |
| NPU/SSD capacity includes refresh time and unavailable/stale states | Fresh/stale/unavailable panel states, dimmed bars, Check/Apply gating, unknown shown as unknown, live refresh timestamp; captured at both widths. |
| Initiate selected download; see progress/completion/failure | Real `--live-apply` chose a not-downloaded Text-to-Speech model, queued one download, showed device-reported progress, and verified completion from inventory. Fake Apply fixtures cover zero-exit false positives, partial loads, cancellation, and actionable failure. |
| Apply/refresh explicit; no separate settings tabs | Existing staged Check Config/Apply, expiry, draft invalidation, and one Models panel; editor smoke confirms Models and Advanced sections and no obsolete tabs. |
| Real Tiiny with incompatible catalog types; no unsupported sound effects | Live catalog contains Text Classification, Image-to-3D, Text-to-Video, TTS, Music, embeddings, and rerankers; role pickers expose only declared role types. No sound-effects role or claim exists. |
| Current/projected NPU and SSD headroom; no RAM/throughput invention | Current/projected bars, planner forecast fields, `Not measured` throughput, and unknown-capacity labels; captures and planner comparisons. |
| Draft edits invalidate plan; Apply requires fresh passing unexpired check | Existing invalidation/expiry tests; 60-second countdown rendered and expired state blocks Apply. |
| Forecast downloads/staging/reserves/protected replacement; no auto-delete | Planner fixtures and plan Details; protected coding switch error explains no unload; restore path never evicts. |
| Context meaning and chat enforcement | Context tooltip/plan warning says client-side request budget and chat budget rejects oversized requests; no runtime-memory claim. |
| Failed operation stops plan, exposes partial results, saves nothing | Fake Apply contract checks stop/verification failure/no preference save; panel shows bounded attempted-operation tail and states no preferences were saved; captured failed state. |
| One table, Info per row, headroom collapsed, details/warnings in plan | Panel-state and table-count checks; copyable `TextEdit` Info; collapsed headroom; plan Details dialog captured. |
| Output percentages/elapsed, deduplicated, sanitized, not completion | Real download progress used device percentages and elapsed time; progress fixtures cover ANSI/chunking/dedup; verification requires device inventory. |
| Models/Advanced organization and migration | Story 01/03 regression checks and editor smoke; Advanced retains connection/device/prompt/request settings. |

## Runs

| Check | Result | Report/log |
| --- | --- | --- |
| Planner/panel, catalog-cache status, DEV-03, freshness/hints/vocabulary/expiry/partial result/copyable Info/projected shortfall | Passed | `/tmp/tiiny-story04-final-live-apply-verify.json` |
| `--editor-smoke` including three restart stages | Passed | `/tmp/tiiny-story04-final-editor.json`, `/tmp/tiiny-story04-final-editor.log` |
| `--displayed` fixture state captures at 1400/600 px | Passed; fresh, stale, incompatible, applying, failed, plan details | `/tmp/tiiny-story04-final-live-displayed.log`, images in `/tmp/tiiny-story01-captures/` |
| `--live-readonly --displayed` real catalog capture | Passed; real role filtering and `Projected · insufficient by 1 / 5 reserved`; no Apply | `/tmp/tiiny-story04-final-live-displayed.json`, `settings-models.png` |
| `check_builtin_jobs.py`, all 24 modes | Passed | `/tmp/tiiny-story04-final-jobs.log` |
| `check_device_lease.py` | Passed | `Cross-process device lease passed` |
| `--live-inference` | Passed earlier on `d7494670c`: real chat and polygon, warm set unchanged. Two final retries after the UI-only rebuild timed out during request classification with the warm set still unchanged. | `/tmp/tiiny-story04-live-inference.json`; failed retries in `/tmp/tiiny-story04-final-live-inference.log` and `...2.log` |
| `--live-apply` real download | Passed mutation: `Supertone/supertonic-3`, 225,936,268 bytes, 7 progress lines, sample `100.0% (device) · 24s elapsed`, warm set unchanged | `/tmp/tiiny-story04-live-apply.log` |
| `--live-apply` post-state verification on final build | Passed; target already installed, coding ready, warm set unchanged | `/tmp/tiiny-story04-final-live-apply-verify.json` |

Note: the real download mutation ran on build `d7494670c` before the final UI-only projection-wording change; the final build passed the full planner/editor/Jobs suite and the no-mutation post-state verification. The first live-apply process completed the download successfully but the runner looked for the non-live smoke marker and labeled the stage failed; the marker check was corrected. The downloaded model remains installed on the device; the device's warm set was not changed and no user editor settings were modified because the run used temporary XDG settings.

## Captures

| State | Wide (1400 px) | Narrow (600 px) |
| --- | --- | --- |
| Fresh + plan | [04-models-fresh-1400.png](04-models-fresh-1400.png) | [04-models-fresh-600.png](04-models-fresh-600.png) |
| Stale | [04-models-stale-1400.png](04-models-stale-1400.png) | [04-models-stale-600.png](04-models-stale-600.png) |
| Incompatible scripting | [04-models-incompatible-1400.png](04-models-incompatible-1400.png) | [04-models-incompatible-600.png](04-models-incompatible-600.png) |
| Applying with progress | [04-models-applying-1400.png](04-models-applying-1400.png) | [04-models-applying-600.png](04-models-applying-600.png) |
| Failed with partial results | [04-models-failed-1400.png](04-models-failed-1400.png) | [04-models-failed-600.png](04-models-failed-600.png) |
| Plan details | [04-models-plan-details.png](04-models-plan-details.png) | — |
| Real catalog (live read-only) | [04-models-real-catalog.png](04-models-real-catalog.png) | — |

## Follow-up fixes

- **Model stickiness:** when a different compatible coding model is already loaded, `_schedule_coding_restore` adopts it and updates the editor setting, draft, and applied configuration instead of queuing the older saved model. Queued `model_restore` jobs for the replaced model are cancelled, and a restore that reaches dispatch while another coding model is loaded adopts it and completes without a device switch.
- **Queued cancellation:** pre-start jobs can be marked `cancelled` without stopping later work. Queued cards have **Cancel**; the Queued column has **Cancel all**; pre-start cancelled cards can be cleared without pausing dispatch. Store validation and retry/clear paths handle cancellations with no attempt.
- Verification: build PID `715916` (exit 0, 34.77s); `test_job_queue.gd` reports 0 failures; `check_builtin_jobs.py` passes all 25 modes including `queued_cancel`; `check_model_configuration.py --editor-smoke` passes the adoption/queued-restore fixture (`/tmp/tiiny-fix-editor2.json`); real `--live-readonly` now reports `Live coding model after refresh: ornith-ai/Ornith-1.5-35B-A3B-Turbo` and Check Config passes without Apply (`/tmp/tiiny-fix-live-readonly2.log`).

## Remaining boundaries

Real warm-set-changing load/unload and restoration remain outside story 04 and belong to story 10's scheduling work or a separately approved hardware run. Image generation quality remains story 09. Story 02's two deferred criteria remain unrelated to this acceptance.
