# Story 10 implementation plan — on-demand specialized-model scheduling

Status: Accepted for the implemented path. Planner, queued execution, exposure, and deterministic verification are complete; live hardware load measurements remain unverified.

Parent: [10 — On-demand specialized-model scheduling](../work-items/10-device-scheduling.md).

## Execution contract

Every model transition goes through the persistent FIFO and the shared device lease. The scheduler never runs a second queue or mutates the device from the editor UI thread. A schedule is a reviewable job with a durable submission key, actual pre/post device snapshots, per-operation journal entries, progress, cancellation, and recovery.

The coding model is protected in every plan. A schedule may unload other loaded models to make room, but it must never unload the configured or currently loaded coding model; if the requested model cannot fit alongside the coding model, the plan is rejected before any mutation.

## Schedule model

`Planner.schedule(snapshot, saved_config, role, requested, active_coding)` is pure and returns:

- `temporary`: `unload` eligible loaded models (not the coding model, not the requested model), optional `download`, then `load` the requested model.
- `restore`: the actions from `Planner.check()` on a simulated post-schedule snapshot, i.e. the exact path back to the configured warm set.
- `errors`/`warnings`, `protected` coding ID, and projected NPU.

Rules:

- The requested model must be catalogued and compatible with its role.
- The configured coding model must exist and support tool use.
- Capacity is checked against the coding model plus overhead and reserve before any eviction.
- Disk headroom includes the download plus staging allowance.
- An already-loaded requested model returns an empty plan with a warning; no device change is made.
- The restore plan is validated before the temporary plan runs, so an impossible return trip is rejected up front.
- `warm` is the configured coding model plus role warm flags plus `extra_warm`. A temporary model that is not warm is unloaded during restore; configured warm models that were evicted are loaded again.

## Queued operation

New `model_schedule` job parameters:

```json
{
  "role": "image_model",
  "model": "vendor/model-id",
  "connection": "<identity hash>",
  "restore": true,
  "timeout_ms": 7200000
}
```

The validated worker maps to `ModelWorker`, and the manager dispatches `_execute_model_schedule()`.

Execution:

1. Revalidate connection identity and fetch a fresh snapshot.
2. Require a valid applied configuration and build the pure schedule plan.
3. Execute temporary actions one at a time, journaling `begin` before each CLI command and `verify` only after an inventory-confirmed effect.
4. Verify the coding model is still loaded if it was loaded before the transition.
5. Restore the configured warm set by recomputing `Planner.check()` from the observed post-schedule state, executing the same journaled path.
6. Accept the final snapshot and report both the scheduled model and restoration outcome.

Failure semantics:

- Plan/capacity/disk errors fail before any device command.
- A command or verification failure leaves the job uncertain; no further model commands are sent, and the device lease stays held for review/abandonment.
- A failure after verified temporary work but before/during restore attempts a bounded, journaled restore when the connection is still valid.
- Cancellation before mutation is terminal. Cancellation during an unverified command is an uncertain outcome; cancellation between verified operations attempts restoration with cancellation ignored only for the restore path.
- Restore failure is reported explicitly; the job does not claim the warm set was restored.

## Exposure

The model can append a reviewed `model_schedule` job through the existing `append_job` tool. The dock supplies the current device identity and defaults `restore` to true. The Jobs board title/details show role, model, and restore intent. No standalone queue or hidden retry is added.

## Slices

### Slice A — pure schedule planner

Add `Planner.schedule` and offline assertions for eviction order, coding protection, restore actions, already-loaded no-op, capacity rejection, disk rejection, incompatible role, unknown capacity, and no side effects on the input state.

### Slice B — queued execution and restoration

Add `model_schedule` validation, worker mapping, manager execution, journaling, failure/uncertainty handling, cancellation, and warm-set restoration.

### Slice C — exposure and UI

Extend `append_job` schema/arguments and the Jobs title/details. Keep acceptance-as-queued language.

### Slice D — verification/handoff

Run the pure planner/panel checks, the new Jobs schedule/capacity modes, the full Jobs suite, editor smoke, and transaction/resource regressions. Record measured behavior honestly; real device load timings remain hardware-gated.

## Gates

- Every mutation uses the shared FIFO, lease, and journal.
- The coding model is never scheduled for eviction; impossible combinations fail before mutation.
- A successful schedule restores the configured warm set.
- Unverified device work stops further commands and requires review.
- Progress and cancellation remain non-blocking and observable.
- Capacity/disk/disconnect failures are explicit and do not create duplicate jobs.

All gates are covered by the planner/panel and Jobs fixtures. See [acceptance evidence](../evidence/10-acceptance.md).

## Handoff

Accepted for the implemented path. See [acceptance evidence](../evidence/10-acceptance.md). Boundaries: no live Tiiny load/unload timing; `model_schedule` does not auto-schedule image generation inside the HTTP tool; unverified commands stop for reconciliation.
