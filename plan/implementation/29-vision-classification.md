# Story 29 implementation plan — job-backed visual classification

Status: Proposed. Design only; depends on stories 27 and 28.

Parent: [29 — Job-backed visual classification](../work-items/29-vision-classification.md).

## 1. Job operation

Add `vision_classify` as an internal job operation alongside `asset_generate` and `shell_exec`:

```json
{
  "kind": "vision_classify",
  "image_path": "user://tiiny_chat/attachments/<hash>.png",
  "image_sha256": "...",
  "source": "texture|scene2d|scene3d|player",
  "prompt": "...",
  "prompt_version": "classify-v1",
  "model": "Qwen/Qwen3.6-35B-A3B",
  "connection_hash": "...",
  "timeout_ms": 120000,
  "chat_handoff": {"chat": {...}, "call": {...}, "remaining": [...]}
}
```

The job is read-only. It does not participate in `asset_generate` model schedule/restore, does not use the image role, and does not unload or reload the coding model.

## 2. Tool and preparation

Register `classify_visual` as a legacy/dock tool (it needs `jobs_service`, device lease, and the chat handoff, so a workspace-provider handler is the wrong layer). Add the definition in `registry.gd` or the dock tool definitions and bind:

```gdscript
workspace_registry.set_handler("classify_visual", Callable(self, "_registry_classify_visual"))
```

Validation before queueing:

- capability: selected coding model is `Image-Text-to-Text` / `supports_vision`;
- source/path: a texture path must be an existing image under the project; symlinks and denied paths fail;
- scene/player sources call story 28's capture helper and fail before queueing if capture is unavailable;
- decode and downscale to 512 px; re-encode PNG; reject empty/over 1 MiB;
- compute SHA-256 of the prepared PNG;
- cache lookup: `user://tiiny_classifications/<image_sha256>_<prompt_hash>_<model_hash>.json`;
- on a hit, return the cached tool result immediately and let the chat continue;
- on a miss, queue the job and hand off the chat, like `generate_image`/`run_godot_headless`.

The tool result on a cache hit and after a job has the same shape.

## 3. Worker and device lease

Reuse the asset job's polling shape, but with a dedicated loop:

- `_prepare_vision_tool_job` queues the job and sets `queued_chat_next_operation = "vision_classify"`.
- The dock polls the job with `_poll_vision_job`; on dispatch it:
  1. verifies the connection hash and that the coding model is loaded;
  2. acquires/reuses the device lease (`_acquire_device("visual classification")`);
  3. records the device request with the job ID;
  4. sends a `/v1/chat/completions` request with one text part and one image data URI (base64 generated at request time, not stored);
  5. confirms success/uncertainty;
  6. parses `choices[0].message.content` into a description and optional labels;
  7. writes the cache entry;
  8. finishes the job with a structured result and resumes the chat via a successor.
- No model load is scheduled. If the coding model is not loaded, fail with “Load the coding model in Tiiny AI > Models.”
- Timeout 60–120 s; output max 160 tokens; temperature 0; thinking disabled.

## 4. Result and cache

Result data:

```json
{
  "description": "A blue player character on a transparent background.",
  "labels": ["player", "character", "blue"],
  "source": "texture",
  "path": "res://generated/player.png",
  "image_sha256": "...",
  "model": "Qwen/Qwen3.6-35B-A3B",
  "cached": false,
  "duration_ms": 1200
}
```

Cache file stores only text and metadata. Key includes the prepared-image hash, the prompt version/hash, and the model. No TTL initially; prune by count/size (e.g., 200 entries or 2 MiB). A cache hit is a normal tool result with `cached: true`.

The prepared PNG lives under `user://tiiny_chat/attachments/` or a job working path and can be pruned after success; the cache key remains valid.

## 5. Chat handoff and failure policy

- On success, a successor appends the tool result to the chat and continues, analogous to `prepare_shell_tool_successor`.
- On a read-only classification failure (HTTP error, malformed response, capture failure):
  - return a tool error with the reason;
  - resume the chat;
  - do not stop unrelated queued jobs.
- This needs a queue-level exception: `vision_classify` is a contained read-only operation, unlike image/asset jobs whose failures may require review. Add an explicit `failure_policy` or operation check; do not silently change `shell_exec`/asset behavior.
- A classification job has no mutation, publication, or device-outcome uncertainty beyond the HTTP request; if the request outcome is unknown, report `outcome_unknown` and do not retry automatically.

## 6. Panel and diagnostics

- Jobs panel shows the source/path/hash, model, cache state, and description; no base64.
- The job detail can show a thumbnail from the local path if it still exists; otherwise a placeholder.
- Traces/logs contain no image bytes. The tool result can include the image path/hash only.
- `find_assets` may later read cached labels for matching image hashes; do not scan unbounded cache files per row.

## 7. Tests

Deterministic:

- Fake HTTP fixture returns a classification; assert the request has a text part + `image_url` data URI, the job result is a tool message, and the chat continues.
- Cache hit: second call with the same image/prompt/model makes no HTTP request and returns `cached: true`.
- Cache miss: different image hash/model/prompt version.
- Capability off: tool unavailable; no job.
- Invalid inputs: missing path, non-image, symlink, oversized, empty capture.
- Failure containment: fake HTTP 500/timeout; chat resumes with a tool error; an unrelated queued job still runs.
- Redaction: trace, queue parameters, and logs contain no `data:image` or base64.
- Model not loaded: job fails with a clear reason; no model schedule/restore.

Editor:

- Capture a 2D scene with a `ColorRect` and classify the view; assert the prepared PNG dimensions and a fake result.
- Player capture unavailable path returns a precise error.

Live (gated):

- Classify a real generated texture; record the description and labels.
- Capture and classify a 3D scene; record visible-issue text.
- Measure prompt/completion tokens and duration; verify cache hits.

## 8. Risks

- Queue failure semantics: containment is a deliberate exception; it must be tested so a read-only classifier cannot hide a real mutation failure.
- Cache correctness: include the model and prompt version; otherwise a prompt/model change silently reuses stale labels.
- Image size and token cost: one 512 px image is a real context cost; cap and measure.
- The coding model may be unloaded or swapped; do not schedule/restore for a read-only classifier, fail clearly instead.
- Base64 must never enter persisted state; the request body is the only place it exists.
