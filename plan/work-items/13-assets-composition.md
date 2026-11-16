# 13 — Multi-model 3D and audio recipes

Status: Accepted. Queued `asset_generate` jobs call the live Tiiny speech/image-to-3D endpoints, import real WAV/GLB artifacts, protect the coding model during queued model swaps, and pass on-device success, failure/retry, and cancellation tests. Shape-only 3D and speech structural checks remain bounded as documented. See [acceptance evidence](../evidence/13-acceptance.md).

Feature: Multi-model 3D and audio recipes

Sequence: 13

Stream: `assets`

Dependencies: 02, 09, 10

Implementation: [plan](../implementation/13-assets-composition.md).

## Scope

Compose specialized models into useful Godot asset workflows after their APIs and outputs are verified. Use the shared job manager for dependencies, worker limits, artifacts, logs, and recovery.

## Acceptance criteria

- [x] A reference-image-to-3D job imports a real generated asset and exposes its mesh/material results in Godot.
- [x] An image-generation-to-3D graph passes validated artifacts between stages and preserves usable intermediates.
- [x] At least one supported speech or music recipe produces and imports a playable Godot audio asset.
- [x] PBR maps, tileability, topology, and audio loopability are validated or explicitly marked unverified, never inferred from model names.
- [x] Sound effects remain unavailable until a suitable model/API and tested recipe exist.
- [x] Device tests cover success, downstream failure, cancellation, model swapping, and retry without duplicate output; model comparisons record evidence. Live `check_asset_generation.py` passed TTS and 3D success, queued model swaps with the coding model retained, confirmed missing-reference failure with lease release, a successful retry, and interrupted cancellation requiring acknowledgement.

## Concrete scenarios

Use WS-08, WS-09, WS-10, JOB-01, and JOB-04 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md).

## Evidence and handoff

Accepted. Added the queued `asset_generate` job (`image_to_3d`, `speech`) with live `/v1/3d/tasks` multipart submission/task polling and `/v1/audio/speech` WAV retrieval, GLB/WAV save/import, device lease/journaling, confirmed failure cleanup, and cancellation acknowledgement. `check_asset_generation.py` passed on-device with TTS, reference-image-to-3D, model swaps through `model_schedule` while retaining the coding model, missing-reference failure/retry, and interrupted cancellation. Deterministic GLB/WAV import, intermediate preservation, unverified quality flags, no sound-effects recipe, editor smoke, all 31 Jobs modes, and debugger regressions pass. Boundaries: shape-only 3D, structural audio validation, no installed music model. See [acceptance evidence](../evidence/13-acceptance.md).
