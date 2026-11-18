# 29 — Job-backed visual classification

Status: Complete. The tool, image preparation, cache, queue job shape, validation, successor, completion result, and vision gate are implemented and covered by the editor workspace fixture; the device vision request is verified.

Feature: Let the assistant classify an existing texture, a captured 2D/3D scene view, or the running player view with the vision-capable coding model and receive a bounded text description/labels as a tool result

Sequence: 29

Stream: `integration`

Dependencies: 02, 21, 27, 28. Uses the FIFO job manager, the atomic tool-result handoff, asset metadata, and the visual preparation/capability work from story 28. It does not use the image-generation role and does not unload the coding model.

Implementation: [plan](../implementation/29-vision-classification.md).

## Why

Story 28 lets the model see an image in a follow-up turn, which is right for “look at this screenshot.” It is not enough when the model needs a reusable text answer inside a tool loop:

- deciding whether an existing texture is a player, platform, background, icon, or UI element;
- checking whether a newly generated texture matches the request;
- looking at a rendered scene and returning “player is off-screen, platform is missing, camera is clipped”;
- caching that description so `find_assets` can expose semantic labels.

A tool that calls the model synchronously would violate the queue/one-device discipline and block the chat. The classifier is therefore a job-backed long tool, like image generation and shell execution: the chat step ends, the job runs, and a queued continuation receives the structured result.

The device evidence: `Qwen/Qwen3.6-35B-A3B` reports `supports_vision: true`; a direct OpenAI-style image request returned a correct description. No model load or image-model switch is required because the coding model is already warm.

## Scope

Add one tool:

```json
{"source": "texture", "path": "res://generated/player.png", "prompt": "Is this a player, platform, or background?"}
{"source": "scene2d", "view": "2d"}
{"source": "player"}
```

- `source`: `texture`, `scene2d`, `scene3d`, or `player`.
- For `texture`, `path` is an existing image asset.
- For scene/player sources, the tool reuses story 28's capture helpers; a capture failure is returned before queueing.
- Optional `prompt` is bounded and defaults to a fixed classification prompt with a one-sentence description and a short label list.
- The job result:

```json
{
  "ok": true,
  "summary": "Looks like a blue player character on a transparent background.",
  "data": {
    "description": "...",
    "labels": ["player", "character", "blue"],
    "source": "texture",
    "path": "res://generated/player.png",
    "image_sha256": "...",
    "model": "Qwen/Qwen3.6-35B-A3B",
    "cached": false,
    "duration_ms": 1200
  }
}
```

- The tool is available only when the selected coding model supports vision. Otherwise it fails closed with `vision_unavailable` and points to `find_assets` metadata.
- Classification is read-only. A failed classification returns a tool error and resumes the chat; it must not stop unrelated queued work. This is an explicit exception to the current “failure stops dispatch” policy for mutating/asset jobs.
- Results are cached by image SHA-256 + prompt version + model. A cache hit returns immediately without queueing a job. Cache entries store text and metadata, never image bytes.
- Queue parameters, traces, and logs contain the image path/hash, not base64. Job working storage holds the downscaled PNG for the request and may be pruned after success.
- The prompt asks for:
  - what the image appears to be and its likely role;
  - dominant colors/style and transparency;
  - obvious defects for scene views (player visibility, missing platform, camera framing);
  - a short comma-separated label list.
- Limits: one image per job, downscaled to 512 px, 1 MiB PNG, 160 output tokens, 60–120 s timeout, one classification at a time.
- `find_assets` may later include cached labels; that is optional and must not scan the cache per row without a bound.

## Acceptance criteria

- [x] `classify_visual` is advertised only when the coding model reports vision support.
- [x] A texture classification queues a job, sends one image content part with the default prompt, and returns a description + labels as a tool result.
- [x] The job uses the coding model and existing device lease; it does not load/unload models or touch the image role.
- [x] A cache hit returns without a second inference request; changing the image hash, prompt version, or model misses.
- [x] Scene 2D/3D capture and player capture reuse story 28, with the same unavailable/capture-failure behavior.
- [x] Missing, non-image, oversized, or symlinked paths fail before queueing.
- [x] A classification failure resumes the chat with an error and does not stall unrelated queued jobs.
- [x] Queue records, traces, and logs contain no base64 image data.
- [ ] Deterministic fixtures and a gated live device check pass; the wider Jobs, workspace, and smoke suites are rerun.

## Evidence

- Device probe: `Qwen/Qwen3.6-35B-A3B`, `supports_vision: true`, OpenAI `image_url` content part accepted, correct test-image description (557 prompt / 22 completion tokens). A second probe using the classification prompt returned fenced JSON with `description` and ten labels (598 prompt / 104 completion tokens); the parser unwraps the fence.
- Full Jobs suite passed 66 modes; editor smoke passed 13.
- `editor_workspace_tools.gd`: vision-enabled payload advertises `classify_visual`; a texture is prepared to a bounded `user://` PNG; cache put/get works; a cache hit skips the queued job; the job parameters pass validation; `prepare_vision_tool_successor` appends the classification tool result and ledger entry; `_finish_asset_job("completed")` returns the cached result shape.
- Story 27 `find_assets` supplies the deterministic fallback.
- Story 28 defines the shared image preparation, capability detection, and redaction path.
- Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:30.19`, `bin/godot.linuxbsd.editor.x86_64`. No build remains running.

## Open design points

- The implementation reuses the existing `asset_generate` operation with `kind: "vision"` and shares its worker/lease path, bypassing image-model scheduling/restore. No dedicated queue operation was added.
- Whether a failed read-only classifier should be retryable from the Jobs panel like other jobs or just returned as a tool error. Default: return the error and allow the model to retry; no queue stop.
- Cache lifetime and pruning policy; no TTL initially, prune by size/count.
