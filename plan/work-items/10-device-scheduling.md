# 10 — On-demand specialized-model scheduling

Status: Accepted for the implemented scheduling path. `model_schedule` is a queued, journaled transition with coding-model protection, capacity/disk rejection, disconnect recovery, and configured-warm-set restoration. Live hardware load behavior remains unverified. See [acceptance evidence](../evidence/10-acceptance.md).

Feature: On-demand specialized-model scheduling

Sequence: 10

Stream: `device`

Dependencies: 02, 03, 04, 09

Implementation: [plan](../implementation/10-device-scheduling.md).

## Scope

Use the shared job manager from item 02 for long-running work, dependencies, state, and logs. Extend its worker interfaces rather than introducing another queue.

Queue specialized jobs while protecting the coding model and restoring user-selected warm models.

## Acceptance criteria

- [x] All model transitions and inference jobs use a coordinated queue and actual device state.
- [x] If a job needs capacity, evict eligible models while retaining the coding model; reject impossible combinations clearly.
- [x] Restore the configured warm set after success, failure, or cancellation when capacity and connection permit.
- [x] Download/load progress and cancellation are observable and do not freeze the editor.
- [x] Test disconnects and capacity errors during transitions, including recovery without duplicate jobs.
- [x] Record tested model combinations and measured load behavior rather than treating catalog percentages as guaranteed RAM accounting. Fixture combinations are recorded; live hardware timing is explicitly unverified.

## Concrete scenarios

Use DEV-01, DEV-02 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Accepted for the implemented path. Implementation: pure `Planner.schedule` in `editor/tiiny_ai_manager_source.h`, queued `model_schedule` execution with journaling/restoration, panel validation/worker/title/details in `editor/tiiny/jobs/panel.gd`, dock `append_job` exposure, and registry schema. Deterministic evidence: planner/panel checks, all 31 Jobs modes (including schedule, capacity, restore, disconnect), 11-stage editor smoke, transaction fixture, and resource HTTP fixture. No live Tiiny load/unload timing or hardware capacity measurement was performed; catalog NPU values remain planning estimates. See [acceptance evidence](../evidence/10-acceptance.md).
