# 13 — Multi-model 3D and audio recipes

Status: Queued

Feature: Multi-model 3D and audio recipes

Sequence: 13

Stream: `assets`

Dependencies: 02, 09, 10

## Scope

Compose specialized models into useful Godot asset workflows after their APIs and outputs are verified. Use the shared job manager for dependencies, worker limits, artifacts, logs, and recovery.

## Acceptance criteria

- [ ] A reference-image-to-3D job imports a real generated asset and exposes its mesh/material results in Godot.
- [ ] An image-generation-to-3D graph passes validated artifacts between stages and preserves usable intermediates.
- [ ] At least one supported speech or music recipe produces and imports a playable Godot audio asset.
- [ ] PBR maps, tileability, topology, and audio loopability are validated or explicitly marked unverified, never inferred from model names.
- [ ] Sound effects remain unavailable until a suitable model/API and tested recipe exist.
- [ ] Device tests cover success, downstream failure, cancellation, model swapping, and retry without duplicate output; model comparisons record evidence.

## Concrete scenarios

Use WS-08, WS-09, WS-10, JOB-01, and JOB-04 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md).

## Evidence and handoff

Pending. Record changed files, test/device results, limitations, and the next action in [STATUS.md](../STATUS.md).
