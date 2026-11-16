# Story 13 — acceptance evidence

Story 13 is accepted with both the artifact/import path and the real generator-backed job path. A queued `asset_generate` job now calls the live Tiiny `/v1/audio/speech` and `/v1/3d/tasks` endpoints, saves and imports the resulting WAV/GLB, and is exercised on-device for success, model swapping, downstream failure/retry, and cancellation.

Executable: `bin/godot.linuxbsd.editor.x86_64`, built from the story 13 working tree. No build or test remains running.

## Live device combination

- Device reachable at the configured address; coding model `ornith-ai/Ornith-1.5-35B-A3B-Turbo` (54 NPU units) was kept loaded throughout.
- Speech model `Supertone/supertonic-3` (Text-to-Speech, 0 NPU).
- Image-to-3D model `Tencent/Hunyuan3d-2.1` (Image-to-3D, 22 NPU).
- TTS and 3D coexisted with the coding model at 76 NPU units. The fixture unloaded each specialized model and reloaded it through the queued `model_schedule` job (`restore=false`) before generating, verifying the coding model stayed resident.
- The 3D run used `stage=shape`; PBR/texture and topology quality were not claimed.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| A reference-image-to-3D job imports a real generated asset and exposes mesh/material results | The live fixture submits `asset_generate` with `kind=image_to_3d`, a real 512×512 reference PNG, and `stage=shape`. The queued worker POSTs multipart to `/v1/3d/tasks`, polls `/v1/3d/tasks/{id}`, decodes the returned base64 GLB, saves it under `res://tiiny_generated/`, waits for import, and reports the artifact. The fixture loads the GLB as a `PackedScene` and verifies a `MeshInstance3D`. |
| An image-generation-to-3D graph passes validated artifacts between stages and preserves usable intermediates | The live run preserved the reference PNG while the 3D stage executed. The deterministic transaction fixture additionally records the stage-1 PNG SHA-256 and verifies it is unchanged when a downstream GLB import fails, then imports a valid GLB without regenerating the image. The generator job itself writes only new timestamped artifacts and never overwrites existing files. |
| At least one supported speech/music recipe produces and imports a playable Godot audio asset | The live fixture submits `asset_generate` with `kind=speech`; the worker POSTs to `/v1/audio/speech`, saves the returned WAV under `res://tiiny_generated/`, waits for import, and reports the artifact. The fixture verifies `ResourceLoader.load(...) is AudioStream` with a positive duration. Music generation remains unavailable because no Music Generation model is installed; speech is the supported audio recipe. |
| PBR maps, tileability, topology, and audio loopability are validated or explicitly marked unverified | `import_generated_model` results carry `validation: {topology: "unverified", pbr_maps: "unverified"}`; `import_generated_audio` carries `validation: {loop: "unverified"}`. The 3D device run used the shape-only stage and made no PBR claim. The audio run did not claim seamless looping. No quality was inferred from model names. |
| Sound effects remain unavailable until a suitable model/API exists | No sound-effects recipe is registered; the transaction fixture asserts `sound_effect`/`sound_effects` are absent. Speech/music/image-to-3D generator roles remain distinct in `RESOURCE_RECIPES`. |
| Device tests cover success, downstream failure, cancellation, model swapping, and retry without duplicate output | `check_asset_generation.py` passed on-device: TTS and 3D success with imported artifacts; specialized models unloaded and reloaded through `model_schedule` while the coding model stayed loaded; a missing reference image failed with a confirmed error and released the device lease; a following valid 3D job succeeded (retry); a running 3D job was cancelled, became `interrupted`, and required explicit acknowledgement/abandon before dispatch resumed. Submission keys and the persistent queue prevented duplicate jobs. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Live generator-backed asset fixture | Passed TTS, 3D, model swaps, confirmed failure/retry, and cancellation acknowledgement | `/tmp/asset-live3.log` |
| Deterministic transaction/import fixture | Passed real fixture GLB/WAV import, metadata, undo/redo, unverified flags, intermediate preservation, and registry policy | `/tmp/transactions-13f.log` |
| Jobs suite | Passed all 31 modes | `/tmp/jobs-13b.log` |
| Editor smoke + restart stages | Passed 11/11 stages | `/tmp/tiiny-story13b-smoke.json` |
| Debugger fixture | Passed | `/tmp/debugger-13b.log` |
| Build | Exit 0, `00:00:29.89` final incremental, same binary | `/tmp/tiiny-asset-job-build2.log` |

## Implementation

- Queued operation `asset_generate` in `editor/tiiny/jobs/panel.gd`, with `AssetWorker` mapping and validation.
- `poll_asset_job`/cancellation/finalization in `editor/tiiny_ai_dock_source.h`: device lease + `begin_device_request`, multipart 3D submission, task polling, speech POST, GLB/WAV save, import wait, confirmed failure cleanup, and cancellation uncertainty.
- `append_job` schema and dock arguments expose image-to-3D and speech generation; model roles come from Editor Settings.
- Existing `import_generated_model`/`import_generated_audio` recipes remain available for artifacts imported later.

## Remaining boundaries

- 3D device evidence used `stage=shape`. PBR texture generation, topology quality, scale, and tileability were not evaluated.
- Speech playback was validated structurally (AudioStream + duration); semantic quality, voice cloning, and seamless looping were not auditioned.
- Music generation has no installed/tested model, so it remains unavailable rather than being simulated.
- The live fixture requires the real device and leaves the original model set restored (specialized models unloaded at the end).
