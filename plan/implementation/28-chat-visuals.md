# Story 28 implementation plan — chat images and rendered views

Status: Proposed. Design only; no source changes yet.

Parent: [28 — Chat image attachments and rendered-view inspection](../work-items/28-chat-visuals.md).

## Current baseline

- `editor/tiiny_ai_dock_source.h` owns the chat: `prompt` (`TextEdit`), `send_button`, `conversation`, `turn_messages`, `_send_chat`, `_continue_agent`, `_check_context_budget`, `_trace_payload`, and `_append_chat_log`.
- `_generate()` queues a `chat_turn` job with `prompt`, `context`, `conversation`, model, and timeout. `_start_answer` builds the system prompt and sends a text-only user message.
- `_send_chat` and `_continue_agent` build `messages` with string `content`.
- Tool results are text; there is no way to attach an image to the next request.
- The coding model is `Image-Text-to-Text`; the endpoint accepts OpenAI `image_url` data URIs (verified).

## 1. Attachment model

Add a small helper in the dock (or a shared `visual_attachment.gd` if it grows):

```json
{
  "id": "sha256:<hex>",
  "path": "user://tiiny_chat/attachments/<hex>.png",
  "source": "clipboard|project|scene|player",
  "name": "pasted.png",
  "width": 512,
  "height": 512,
  "bytes": 48211
}
```

Rules:

- Store only under `user://tiiny_chat/attachments/`. Never write a pasted screenshot into `res://` unless the user explicitly saves it as an asset.
- Downscale the long edge to `min(original, 1024)` with `Image.resize`.
- Re-encode PNG; reject over 2 MiB after re-encode.
- Deduplicate by SHA-256 of the encoded bytes.
- Keep at most 50 files / 50 MiB; prune oldest unused first. Add a small index or scan the directory.
- Max four per message; max 6 MiB total.

Sources:

- **Clipboard:** `DisplayServer.clipboard_get_image()`; check in `_prompt_input` before the normal Ctrl+V text paste.
- **Project file:** a file dialog for `res://` images, using the canonical path checks.
- **Scene view:** returned by `capture_scene_view`.
- **Player view:** returned by `capture_player_view`.

Attachment UI:

- `attachment_strip: HBoxContainer` above `prompt`.
- Each chip is a `PanelContainer` with a 48×48 `TextureRect`, a filename/size label, and a remove button.
- `_append_message("user", text, attachments)` or a dedicated user-message renderer shows thumbnails in history.
- Clear on send/new chat; keep on validation failure.

## 2. Content representation

Two representations:

**Conversation/trace-safe reference**

```json
{"type": "tiiny_image", "attachment_id": "sha256:...", "path": "user://...", "width": 512, "height": 512}
```

**Wire content part**

```json
{"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
```

- `_attachment_content(text, attachments)` returns an Array only when attachments exist; otherwise a plain String.
- `turn_messages` stores the reference form. `_materialize_messages(messages)` walks content arrays, replaces `tiiny_image` with `image_url` data URIs, and leaves text parts alone.
- `conversation` stores the reference form so job parameters and continuations stay small.
- `_send_chat` and `_continue_agent` accept a `user_content: Variant` (String or Array) and materialize only for the HTTP payload.
- `_check_context_budget` iterates text parts and adds a fixed image estimate (start at 1024 tokens per image). Also add a 4 KiB per-image byte allowance to be safe. Measure on the device and revise once.

## 3. Capability gate

- Read `tiiny_ai/models/coding_model_type` (already set on Apply) or, preferably, persist `supports_vision` from `/v1/models` into a new `tiiny_ai/models/coding_model_vision` setting on Apply/refresh.
- Enable attachments only when the type is `Image-Text-to-Text` and vision is not explicitly false.
- When unavailable, `_set_status` says the selected model does not accept images and leaves the composer intact.
- Tool availability: `capture_scene_view` / `capture_player_view` can be advertised only when vision is available; if they are called without it, return `vision_unavailable`.

## 4. Request flow

1. `_generate()` collects `pending_prompt` and `pending_attachments`.
2. Queue parameters include `attachments` (records) and `conversation` with reference parts; no base64.
3. `_start_answer()` calls `_send_chat(instructions, _attachment_content(user_text, pending_attachments))`.
4. `_send_chat` builds the payload and calls `_materialize_messages` on the outgoing messages.
5. `_continue_agent()` does the same after tool calls.
6. On tool results that include `data.visual` (scene/player capture), `_execute_turn_calls` appends a **user** message with a text prompt and the image reference before the next request. This is how the model can inspect a tool-captured view without a nested model call.
7. The user message in history shows thumbnails; the model sees the image on the next request.

Safety:

- `_trace_payload` sanitizes any content array: replace `image_url` with an image reference, never include the data URI. Add a unit assertion that the serialized trace has no `data:image` and no base64 prefix.
- `_append_chat_log` logs prompts, reasoning, and tool summaries only; ensure it never logs materialized payloads.
- Queue parameters and continuation state contain references only.
- Do not base64 the same image into multiple persisted places.

## 5. Scene and player capture

### `capture_scene_view`

A read-only editor tool (mode `both`, but editor-only availability):

```json
{"view": "2d|3d", "max_px": 1024}
```

Implementation:

1. Get `EditorInterface.get_editor_viewport_2d()` or `get_editor_viewport_3d()`.
2. Wait for `RenderingServer.frame_post_draw` (the tool execute path can await).
3. `var image = viewport.get_texture().get_image()`.
4. If empty, return `capture_failed` with the reason (headless/no rendering).
5. Downscale to `max_px`, save to `user://tiiny_chat/attachments/<hash>.png`, return:

```json
{"ok": true, "data": {"visual": {"id": "...", "path": "...", "width": 512, "height": 288, "prompt": "This is the rendered 2D view of the edited scene."}}}
```

The dock attaches the visual to the next request.

### `capture_player_view`

The running-game view is harder. Research order:

1. Check whether `EditorInterface`/`GameView` exposes the embedded game texture to GDScript. The editor's Game tab uses `GameView`/`WindowWrapper`; if the embedded window's texture is reachable, capture it.
2. If not, add a small C++ accessor on `EditorInterface` (e.g., `get_game_view_texture()`) only if the embedded game is actually available. Return empty when the game is not running or embedding is disabled.
3. Never capture the entire editor window and label it the game. If the game window is external, return `unavailable` with guidance to enable embedded game mode or use `capture_scene_view`.

The plan should include a probe test before committing to a C++ change; player capture is a best-effort feature with a clear fallback, not a promised screenshot of an external window.

## 6. Trace and budget

- `_check_context_budget` must handle content arrays (it already counts `part.text`); add image estimates and reject over-budget attachments before sending.
- `_trace_payload` adds a sanitizer for `turn_messages`/`conversation`.
- Add a test that the trace JSON length stays bounded with a 512 px attachment and contains `"type":"image"` but no `"data:image"`.
- The chat log remains append-only and must not include image bytes.

## 7. Tests

Deterministic:

- Fake HTTP fixture: send a text+image message, assert the outgoing `content` array has `text` + `image_url` data URI; with no attachments, assert a plain string.
- Capability off: attachments rejected, no request queued.
- Budget: two large images rejected before submit with a clear status.
- Attachment storage: dedupe, downscale, 2 MiB cap, pruning.
- Trace/log: no `data:image`, no base64, bounded size.
- Continuation: queue a turn with an attachment, simulate a continuation, assert the reference survives and resolves again.
- Editor capture: create a 2D scene with a colored `ColorRect`, capture, assert PNG dimensions/non-empty; 3D view similarly; no `res://` file created.
- Player capture: unavailable path returns a precise error when the game is not running; embedded path tested only if the probe succeeds.

Live (gated):

- Attach a generated image and ask “what is this?”; record the model response and trace.
- Capture the 3D view and ask for visible issues; record the response.
- Do not claim success from a missing image; the trace must show the content part.

## 8. Risks

- Base64 in traces/job parameters is the main failure mode. References must be the persisted form.
- Image tokens and body size can exceed the device/context; start with one image, 512 px, and a conservative estimate.
- The Tiiny endpoint accepted the tested image format, but model/version changes may alter limits; capability detection must be data-driven.
- Player capture may be impossible without engine support; scope it as best-effort with an explicit fallback.
- Pasted images may contain sensitive content; store locally, never log bytes, and make deletion clear.
