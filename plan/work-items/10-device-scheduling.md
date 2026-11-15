# 10 — On-demand specialized-model scheduling

Status: Queued

Feature: On-demand specialized-model scheduling

Sequence: 10

Stream: `device`

Dependencies: 02, 03, 04, 09

## Scope

Use the shared job manager from item 02 for long-running work, dependencies, state, and logs. Extend its worker interfaces rather than introducing another queue.

Queue specialized jobs while protecting the coding model and restoring user-selected warm models.

## Acceptance criteria

- [ ] All model transitions and inference jobs use a coordinated queue and actual device state.
- [ ] If a job needs capacity, evict eligible models while retaining the coding model; reject impossible combinations clearly.
- [ ] Restore the configured warm set after success, failure, or cancellation when capacity and connection permit.
- [ ] Download/load progress and cancellation are observable and do not freeze the editor.
- [ ] Test disconnects and capacity errors during transitions, including recovery without duplicate jobs.
- [ ] Record tested model combinations and measured load behavior rather than treating catalog percentages as guaranteed RAM accounting.

## Concrete scenarios

Use DEV-01, DEV-02 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Pending. Record changed files, validation commands and results, editor/device observations, remaining limitations, and the next action. Update [STATUS.md](../STATUS.md) when handing off.
