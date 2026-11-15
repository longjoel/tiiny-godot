# 03 — Device binding and protected coding-model lifecycle

Status: Planning — [implementation plan](../implementation/03-device-lifecycle.md) drafted. Story 01 accepted; story 02 9 of 10 criteria verified.

Feature: Device binding and protected coding-model lifecycle

Sequence: 03

Stream: `device`

Dependencies: 01, 02

## Scope

Use the shared job manager from item 02 for long-running work, dependencies, state, and logs. Extend its worker interfaces rather than introducing another queue.

Bind management and inference to the same device. Restore the coding model first and expose disconnects and partial setup failures.

## Acceptance criteria

- [ ] Test discovery or explicit address binding and verify that management and inference reach the intended device.
- [ ] Validate and persist the selected coding model; reject incompatible capabilities before changing device state.
- [ ] Confirm downloads and load completion from device state rather than process exit alone.
- [ ] When a connection is available, restore the coding model on startup/reconnect; never deliberately evict it for another job.
- [ ] Disconnect, authentication failure, and capacity failure leave a clear recoverable state without reporting readiness.

## Concrete scenarios

Use DEV-01, DEV-02 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Pending. Record changed files, validation commands and results, editor/device observations, remaining limitations, and the next action. Update [STATUS.md](../STATUS.md) when handing off.
