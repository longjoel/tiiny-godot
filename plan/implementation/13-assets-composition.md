# Story 13 implementation plan — multi-model 3D and audio recipes

Status: Accepted for the implemented artifact/import path. Generator/device verification remains open.

Parent: [13 — Multi-model 3D and audio recipes](../work-items/13-assets-composition.md).

## Execution contract

Generator calls are not invented. The editor owns validation and import of artifacts produced by specialized models, so a future image-to-3D/speech/music adapter can hand off a file without adding a second queue or ad-hoc scene code. Import recipes use the story 06 typed executor, one undo action, and explicit unverified-quality flags.

## Recipes

### `import_generated_model(path, parent_path?, node_name?)`

- Require a `res://` `.glb`/`.gltf` path with no traversal.
- Missing file → `artifact_missing`; unloadable scene or no `MeshInstance3D` → `artifact_invalid`.
- Instantiate the `PackedScene`, collect mesh names and material surface classes, choose a unique owned node name, and add it under an owned parent.
- One undo action; undo removes the instance, redo restores it.
- Result data: artifact path, meshes, materials, and `validation: {topology: unverified, pbr_maps: unverified}`.

### `import_generated_audio(path, parent_path?, player_name?)`

- Require a `res://` `.wav`/`.ogg` path with no traversal.
- Missing/unloadable/non-AudioStream → typed error.
- Create an owned `AudioStreamPlayer`, assign the stream, and record duration plus WAV channel count when available.
- Result data: artifact, duration, channels, `validation: {loop: unverified}`.
- No autoplay; auditioning and seamless looping are separate checks.

### Executor support

`create_node_value` accepts a recipe-owned unparented Node, keeps it alive with `add_do_reference`, and participates in the same undo/redo and clean-after-undo checks. Build results can add recipe-specific `data` fields to the structured transaction result.

## Pipeline/intermediate behavior

The deterministic fixture represents the two-stage graph:

1. A real 2×2 PNG stage-1 artifact is created and hashed.
2. A downstream GLB import is requested with a missing artifact; it fails with `artifact_missing`, creates no node, and leaves the PNG hash unchanged.
3. A real generated GLB is imported successfully, proving the downstream stage without regenerating the image.

A production image-to-3D adapter must use the same artifact path and preserve failed-stage intermediates.

## Registry policy

- `image_to_3d`, `music_generation`, and `speech_generation` remain `planned` generator recipes until a device/API and tested adapter exist.
- Import recipes are executable transaction tools.
- No sound-effects recipe is listed.
- Never infer topology, PBR, tileability, or loopability from a model name; report unverified unless a validator measured it.

## Verification

Transaction fixture:

- Generate a GLB with a box mesh and material; import under `World/GeneratedProp`; verify mesh/material metadata and unverified flags; undo/redo.
- Preserve a stage-1 PNG hash across a missing downstream GLB.
- Import a generated WAV as `GeneratedLine`; verify positive duration and unverified loop flag; undo/redo.
- Registry payload advertises both import recipes and omits sound effects.

Regression: editor smoke, all Jobs modes, debugger fixture, and loopback resource HTTP.

## Gates

- Real artifacts load and expose typed metadata.
- Failed downstream imports preserve the prior stage artifact.
- Quality is marked unverified rather than inferred.
- Sound effects remain unavailable.
- Device success/cancellation/model-swapping/retry must be recorded separately when hardware is available.
