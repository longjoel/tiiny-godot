# 28 — Chat image attachments and rendered-view inspection

Status: Complete. Clipboard/project attachments, reference-safe payloads, image-budget accounting, trace redaction, editor scene capture, and the unavailable player-capture path are implemented and covered by the editor and workspace fixtures. See the evidence below.

Feature: Let users paste or attach images to a chat request and let the assistant inspect editor-rendered scenes and the running player view through the coding model's vision capability

Sequence: 28

Stream: `integration`

Dependencies: 08, 22, 27. Builds on the chat/action UI, direct model dispatch, and deterministic asset awareness. It uses the coding model's `Image-Text-to-Text` capability; it does not use the image-generation role.

Implementation: [plan](../implementation/28-chat-visuals.md).

## Why

The selected coding model supports vision. Direct device evidence (2026-11-18, `Qwen/Qwen3.6-35B-A3B`): `/v1/models` reports `type: Image-Text-to-Text` and `supports_vision: true`, and a `/v1/chat/completions` request with an OpenAI-style `image_url` data URI correctly described a test image (“a yellow circle centered on a red square, all set against a blue background”).

The dock still sends text-only content. That blocks two useful workflows:

- showing a screenshot or reference image in the chat instead of describing it in prose;
- asking the assistant to look at the rendered 2D/3D scene or the running game and judge what the player sees.

Pasting and scene capture are different sources but the same pipeline: prepare a bounded local PNG, attach it to the next model request, and keep the image out of logs, traces, and persisted queue parameters.

## Scope

### Attachments

- Paste an image from the clipboard into the chat, or use an **Attach image** button with a file picker for project images.
- Store chat images under `user://tiiny_chat/attachments/`, never in `res://`. Name by SHA-256, deduplicate, downscale to at most 1024 px on the long edge, re-encode as PNG, cap at 2 MiB each and 6 MiB per message.
- Allow up to four attachments per message. Show thumbnail chips with a remove action; clear them on send or new chat.
- Keep an attachment record: id/hash, path, width, height, bytes, source (clipboard, project, scene view, player view), and a display name.

### Request pipeline

- A message with attachments uses an OpenAI-compatible content array:

```json
{"role": "user", "content": [
  {"type": "text", "text": "Why is the player falling through here?"},
  {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
]}
```

- `conversation` and queued job parameters store attachment references, not base64. A resolver materializes the data URI only while building the HTTP request.
- The chat trace replaces image parts with `{type, attachment_id, sha256, width, height}`. Logs and queue parameters must never contain image bytes.
- The context budget counts each image with a fixed conservative token estimate plus the text. The transport body limit and timeout remain bounded.
- If the selected coding model is not `Image-Text-to-Text` / does not report `supports_vision`, attachments are rejected with a clear status. Do not silently drop them.

### Scene and player capture

- `capture_scene_view` captures the editor's 2D or 3D viewport through `EditorInterface.get_editor_viewport_2d()` / `get_editor_viewport_3d()`, waits for a rendered frame, downsamples, and returns an attachment reference.
- `capture_player_view` targets the running player output. The primary path is the embedded Game view when the editor exposes a capturable view; otherwise it returns a clear `unavailable` result with guidance to enable the embedded game or use a 2D/3D scene capture. It must not silently capture the entire editor UI and call it the game.
- Captures are local `user://` files and follow the same attachment limits and redaction rules.

### Chat UI

- An attachment strip above the prompt shows thumbnails, size, and remove buttons.
- The sent user message displays the attached images as thumbnails, not as base64 text.
- A failed capability or size check keeps the attachment chips and explains what to change.
- New chat and send reset attachment state.

## Acceptance criteria

- [x] Pasting a clipboard image creates a bounded `user://` PNG and a removable chip; oversized images are downscaled or rejected with a reason.
- [x] Sending an attachment produces an OpenAI-style content array with the text and image data URIs, without changing the plain-text path when no image is attached.
- [x] Conversation, job parameters, chat logs, and traces contain attachment references, never base64; trace JSON remains small.
- [x] The context budget accounts for images and refuses an oversized message before the request.
- [x] A model without vision rejects attachments with a clear status and keeps them in the composer.
- [x] `capture_scene_view` captures the editor viewport when rendering is available and reports `capture_failed` otherwise; `capture_player_view` reports a precise `unavailable` reason because this build cannot capture an external game window.
- [x] Attachments survive a queued continuation/job resume by reference and resolve at dispatch.
- [x] Deterministic fixtures pass and no image bytes appear in diagnostics. The device vision request was verified directly; a live UI paste check remains manual.
- [x] The wider job, workspace, and smoke suites are rerun.

## Evidence

- Device vision probe: `Qwen/Qwen3.6-35B-A3B`, `supports_vision: true`, OpenAI `image_url` content part accepted, correct description returned (557 prompt / 22 completion tokens).
- `editor_workspace_tools.gd`: a 4×4 image produced a `user://` attachment record; plain text stayed a string; image content built text + image parts; materialization produced a data URI; trace sanitization removed image bytes; the 8k budget rejected text + image; a fake chat submitted a payload with the image data URI; `capture_scene_view` reported a clear headless result; `capture_player_view` reported unavailable; vision-enabled payload advertised both capture tools.
- `test_workspace_tools.gd`, 20-case selection, transaction fixture, runtime fixture, and editor smoke passed. Full Jobs suite passed 66 modes.
- Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:31.61`, `bin/godot.linuxbsd.editor.x86_64`. No build remains running.
- Player capture remains manual: paste an OS screenshot of the running game. Automatic external-window capture is deferred until an embedded game texture is reachable.

## Open design points

- Whether the embedded Game view is readable from GDScript or needs a small C++ accessor. Research before implementation; do not promise the player capture until a probe succeeds.
- Whether a pasted image should be saved as a project asset or remain chat-only. Default: chat-only.
- Exact per-image token estimate; start conservative and measure on the device.
