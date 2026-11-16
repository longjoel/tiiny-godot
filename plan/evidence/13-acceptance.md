# Story 13 — acceptance evidence

Story 13 is accepted for the implemented artifact/import path. The editor can validate and import real GLB/GLTF 3D artifacts and WAV/OGG audio into typed scene nodes, expose mesh/material and duration metadata, preserve stage-1 artifacts when a downstream import fails, and explicitly mark topology/PBR/loop quality as unverified. Live image-to-3D/speech/music **generator** calls were not performed.

Executable: `bin/godot.linuxbsd.editor.x86_64`, built from the story 13 working tree. No build or test remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Reference-image-to-3D imports a real generated asset and exposes mesh/material results | `import_generated_model` validates a `res://` GLB/GLTF artifact, loads it as a `PackedScene`, instantiates it, requires at least one `MeshInstance3D`, reports mesh names and material surface classes, and adds the instance with one undo action. The transaction fixture generates a real GLB (box mesh + StandardMaterial3D) with `GLTFDocument`, waits for import, then imports it under `World/GeneratedProp` and verifies mesh presence, metadata, undo, and redo. |
| Image-generation-to-3D graph passes validated artifacts and preserves intermediates | The fixture writes a real 2×2 PNG stage-1 artifact, records its SHA-256, and attempts `import_generated_model` with a missing downstream GLB. The import fails with `artifact_missing`, creates no node, and the PNG hash is unchanged. The subsequent valid GLB import proves the downstream stage works without regenerating the image. |
| At least one speech/music recipe produces/imports a playable Godot audio asset | `import_generated_audio` validates a `res://` WAV/OGG asset, loads an `AudioStream`, reports duration (and WAV channel count), creates an `AudioStreamPlayer`, assigns the stream, and supports undo/redo. The fixture writes a real 220 Hz mono WAV, imports it as `GeneratedLine`, verifies a non-null stream and positive duration, and exercises undo/redo. Playback output was not auditioned. |
| PBR maps, tileability, topology, and audio loopability are validated or explicitly marked unverified | 3D results include `validation: {topology: "unverified", pbr_maps: "unverified"}`. Audio results include `validation: {loop: "unverified"}`. The fixture rejects any result that claims verification. No model name is used to infer quality. |
| Sound effects remain unavailable until a tested model/API exists | The registry has no `sound_effect`/`sound_effects` recipe; the fixture asserts their absence. Music/speech/image-to-3D remain `planned` generator recipes. |
| Device tests cover success, downstream failure, cancellation, model swapping, and retry without duplicates | Not performed. No image-to-3D/speech/music device model was available or configured in this slice. The deterministic fixture covers successful 3D/audio import and a downstream missing-artifact failure with the intermediate preserved. Cancellation/model swapping/retry remain story 10/13 hardware follow-ups. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Transaction/registry/chat/action-card fixture | Passed real GLB import, mesh/material metadata, unverified flags, undo/redo, PNG intermediate preservation on missing GLB, real WAV import/duration, undo/redo, registry payload, and no sound-effects recipe | `/tmp/transactions-13e.log` |
| Editor smoke + restart stages | Passed 11/11 stages | `/tmp/tiiny-story13-smoke.json` |
| Jobs suite | Passed all 31 modes | `/tmp/jobs-13.log` |
| Debugger fixture | Passed | `/tmp/debugger-13.log` |
| Loopback resource HTTP fixture | Passed | `/tmp/resource-http-13.log` |
| Build | Exit 0, `00:00:34.68` final incremental, same binary | `/tmp/tiiny-story13-build2.log` |

## Remaining boundaries

- The 3D/audio artifacts are real but fixture-generated, not produced by on-device image-to-3D, speech, or music models. Generator/model-quality verification remains open.
- No device run covered success, cancellation, model swapping, or retry for the multi-model graph.
- 3D validation checks loadability and mesh presence; topology, PBR maps, scale, and tileability are not inferred as correct.
- Audio validation checks loadability, duration, and WAV channel count; playback, seamless looping, music/speech classification, and semantic quality are unverified.
- No sound-effects recipe is exposed.
- The importer supports GLB/GLTF and WAV/OGG only.
