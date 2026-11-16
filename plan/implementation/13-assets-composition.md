# Story 13 implementation plan — multi-model 3D and audio recipes

Status: Accepted. Queued generator jobs call the live Tiiny speech and image-to-3D endpoints; deterministic import and live device success/failure/retry/cancellation/model-swap checks pass.

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

## Live generator jobs

New queued `asset_generate` operation:

- `kind=image_to_3d`: validate a reference image and `stage` (`shape`/`both`); POST multipart to `/v1/3d/tasks`; poll `/v1/3d/tasks/{id}`; decode the completed base64 GLB; save a new timestamped file; wait for import.
- `kind=speech`: validate text; POST JSON to `/v1/audio/speech`; save the returned WAV; wait for import.
- Both use the shared device lease/journal, confirmed-failure cleanup, cancellation uncertainty, and `model_schedule`-driven specialized-model swaps that retain the coding model.
- `append_job` schema/dock arguments expose both kinds; model roles come from Editor Settings.

The on-device fixture unloads/reloads TTS and Hunyuan3D through `model_schedule` while Ornith stays loaded, runs TTS and a shape-only 3D task, verifies imported AudioStream/MeshInstance3D, injects a missing-reference failure and retry, and cancels a running 3D task before acknowledging the interrupted outcome.

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
