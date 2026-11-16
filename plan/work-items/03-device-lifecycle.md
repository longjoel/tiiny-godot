# 03 — Device binding and protected coding-model lifecycle

Status: Accepted (deterministic/fake-device, live inference, and a download-only real Apply). Real warm-set-changing load/unload and restoration were not run because the device’s kept set needs 101 NPU units plus the 5-unit reserve; no model was evicted. Those hardware checks are carried into story 04’s gated Apply (download-only) and later story 10 scheduling. See [acceptance evidence](../evidence/03-acceptance.md). The prior source-text smoke test is not acceptance evidence.

Feature: Device binding and protected coding-model lifecycle

Sequence: 03

Stream: `device`

Dependencies: 01, 02

## Scope

Use the shared job manager from item 02 for long-running work, dependencies, state, and logs. Extend its worker interfaces rather than introducing another queue.

Bind management and inference to the same device. Restore the coding model first and expose disconnects and partial setup failures.

## Acceptance criteria

- [x] Test discovery or explicit address binding and verify that management and inference reach the intended device.
- [x] Validate and persist the selected coding model; reject incompatible capabilities before changing device state.
- [x] Confirm downloads and load completion from device state rather than process exit alone.
- [x] When a connection is available, restore the coding model on startup/reconnect; never deliberately evict it for another job.
- [x] Disconnect, authentication failure, and capacity failure leave a clear recoverable state without reporting readiness.

## Concrete scenarios

Use DEV-01, DEV-02 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

See [acceptance evidence](../evidence/03-acceptance.md) and [STATUS.md](../STATUS.md). Story 03 gates story 04; story 04 implements the Models UI and carries the gated real-device Apply.
