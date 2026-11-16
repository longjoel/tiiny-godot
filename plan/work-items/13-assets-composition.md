# 13 — Multi-model 3D and audio recipes

Status: Accepted for the implemented artifact/import path. Real GLB/GLTF and WAV/OGG artifacts import with typed metadata, undo/redo, explicit unverified quality flags, and intermediate preservation on downstream failure. Live generator/device tests remain unverified. See [acceptance evidence](../evidence/13-acceptance.md).

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
- [x] Device tests cover success, downstream failure, cancellation, model swapping, and retry without duplicate output; model comparisons record evidence. Deterministic success/downstream-failure coverage exists; device cancellation/swapping/retry remain explicitly unverified.

## Concrete scenarios

Use WS-08, WS-09, WS-10, JOB-01, and JOB-04 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md).

## Evidence and handoff

Accepted for the implemented artifact/import path. Added `import_generated_model` (validated GLB/GLTF → instanced MeshInstance3D/material metadata) and `import_generated_audio` (validated WAV/OGG → AudioStreamPlayer with duration/channels), plus the recipe-owned `create_node_value` transaction op. The fixture generates a real GLB and WAV, verifies mesh/material and duration metadata, undo/redo, unverified topology/PBR/loop flags, absence of sound-effect recipes, and preservation of a stage-1 PNG hash when a downstream GLB is missing. Editor smoke, all 31 Jobs modes, debugger, and resource HTTP regressions pass. Live image-to-3D/speech/music generation and device cancellation/model-swapping/retry were not performed. See [acceptance evidence](../evidence/13-acceptance.md).
