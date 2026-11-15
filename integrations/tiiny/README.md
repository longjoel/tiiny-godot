# Tiiny Godot workspace assistant

This fork is exploring a Godot-native assistant powered by a Tiiny device. The goal is to turn a request into workspace operations: inspect scenes and resources, use Godot's built-in features, generate and import assets when needed, and report what changed. Think of it as a powerful, context-aware editor macro. Gameplay GDScript is a fallback when built-in tools cannot reasonably provide the requested behavior. Internal asset-building jobs may use disposable Godot generator scripts outside the editor process.

The integration is an **early prototype**. The workspace operations and undoable scene-editing workflow are a design direction, not finished features. See [WORKSPACE_ASSISTANT.md](WORKSPACE_ASSISTANT.md) for the design and first milestone. The sequenced implementation backlog and current work are in [plan/README.md](../../plan/README.md).

## What exists today

- **Tiiny Chat:** a side dock that sends requests and optional editor context to the configured text model. Conversation history lasts for the current editor session.
- **Prototype tools:** the model can request creation of a new GDScript file or experimental image generation. The image adapter passes loopback PNG/import checks; real Tiiny image generation remains unverified. It requires a configured, already-loaded image model and a base64 PNG response. Generated images are saved in `res://tiiny_generated/`. The script tool validates GDScript and refuses to overwrite existing files. Tool results are returned to the model for up to four sequential calls per turn.
- **Resource experiment:** the Create New Resource dialog accepts an AI description for `ConvexPolygonShape2D`; leaving it blank performs normal creation. The returned points are converted to a convex hull. Other resource types are not yet supported by this dialog.
- **Device settings:** editor settings include the connection, SDK path, device address, model roles, and warm-model choices. The Models screen reads the live catalog, loaded state, allocation budget, and SSD capacity. Changes are staged in a draft, checked against refreshed data, and executed only with Apply. Opening the editor/settings does not trigger downloads or model transitions.
- **Output:** request and model-management status is written to Godot's Output panel. Project context and screenshots are sent only when selected in the chat interface.

Story 01 establishes a verified prototype baseline: real Tiiny chat and polygon generation/save/reopen, native resource/node dialog regressions, process cleanup, HTTP failure recovery, and displayed editor checks. This does not complete the planned workspace tools or validate real model downloads/loads. See [the acceptance evidence](../../plan/evidence/01-completion.md).

## Setup

1. Install and authenticate the [Tiiny SDK](https://dev.tiiny.ai/) and connect the device. Build and launch this fork's editor, then open a project.
2. In **Editor > Editor Settings > Tiiny AI > Advanced**, set the API URL and API key. If the key is empty, the editor uses `TIINY_API_KEY`, then the authenticated SDK configuration. The password field masks the value but Editor Settings stores it on disk.
3. In the same **Advanced** section, set the SDK CLI path and, optionally, a device address. A blank address uses the SDK's currently selected device. The default `http://openai.api.tiiny/v1` URL is routed through that same bound device with the required Host header. A custom API URL must use the bound device address. Both Models and Advanced appear in the normal settings view without enabling Godot’s global Advanced Settings toggle. Existing Connection and Device values migrate automatically; any already configured Advanced value takes precedence.
4. Open **Tiiny AI > Models** and select **Refresh**. Capacity bars appear above one model table. Each row shows context, throughput ("Not measured" until a benchmark exists), catalog download size, NPU allocation, desired **Keep loaded**, and actual installed/loaded state. Each row's **Info** button opens its description and capabilities. Unassigned installed models appear as additional rows in this same table.
5. Choose task models and the scripting context budget. Scripting requires a text model with declared tool-use support and is always kept loaded. Optional model choices are filtered by catalog type; descriptions help distinguish specialized variants. Role selection alone does not establish generation quality.
6. Select **Check Config**. Review projected capacity and the ordered download/unload/load plan; **Details** shows staging forecasts and warnings. **Advanced headroom** contains optional minimum free-capacity settings. Changing them invalidates the check; they affect plan validation rather than reserving device storage or allocation directly. Check Config does not mutate the device. Apply stays disabled on incompatible selections, unknown required capacity, insufficient headroom, or a protected coding-model switch that cannot fit both old and new models.
7. Select **Apply** to revalidate and execute the checked plan. Draft edits invalidate the check; checks expire after 60 seconds. Inventory changes require a fresh review. Preferences are saved only after the result is verified. No restart is required.

Output records download percentages reported by the device and elapsed time, polling approximately every three seconds while the command runs. Repeated percentages are limited to one update per ten seconds. Other model operations forward SDK percentages when present. Terminal escape codes and arbitrary SDK output are filtered. A percentage is progress only; operation completion still requires device verification.

This fork assumes exclusive use of the configured Tiiny. Applying the warm configuration can unload models used by other applications. A failed download or load may leave a partial configuration; check Output and retry. Readiness expires after 60 seconds; Refresh obtains current device state before further inference. The manager does not continuously monitor residency, restore models on reconnect, or swap models for individual jobs. Shutdown stops the owned SDK process tree; completed remote effects are not rolled back and must be rechecked. The current SDK adapter requires Linux `script` and `timeout` commands for model operations. A failure stops further operations and refreshes the observed state; it is not an atomic rollback. The planner never deletes installed models to free storage.

## Capacity and context

Tiiny's 100-unit model allocation budget is distinct from physical NPU RAM and compute utilization. The planner uses `/api/v1/models/npu/status`, the catalog's per-model units, and `/api/v1/sys/storage`. It counts each selected model once, retains unattributed allocation, and reserves configurable NPU units (default 5). SSD preflight includes missing downloads, a conservative largest-download staging allowance, and a reserve (default 2 GiB). These are admission checks with explicit allowances, not guarantees about unknown runtime allocations or archive expansion. Every operation is verified against the device.

**Context** is currently a client-side chat request budget. The SDK exposes no load-time context-allocation flag, so a smaller choice does not reduce the NPU footprint shown. Chat conservatively budgets text using UTF-8 bytes plus framing/output allowance; image token cost is estimated. Oversized requests are rejected rather than silently truncating context. **New conversation** clears the request history while preserving displayed results, so a full context does not trap the user. Actual tokenizer-based budgeting and runtime context reconfiguration remain future work. The table does not invent token/s measurements.

Tiiny AI has two settings sections: **Models** for model configuration and **Advanced** for connection, device, prompt, and request limits. There are no separate Tiiny Assistant or Tiiny Models settings tabs.

## Context and instructions

The chat can include the edited scene, selected node paths and types, and—when applicable—the current script, including unsaved text, up to the configured limit. It can attach an existing screenshot and optional user-supplied JSON describing visual elements. Screenshot input requires a vision-capable text model. These inputs are sent to the configured Tiiny endpoint; the assistant does not currently inspect the paused debugger or live scene.

The built-in Godot-oriented system prompt and `ResourceToolLibrary` are in `editor/tiiny_ai_dock_source.h`. Optional additional instructions can be set under **Tiiny AI > Advanced > System Prompt Extra**. Request timeout and script-context size are also configurable there.

## Next work

The first foundational feature after stabilization is a persistent job manager: append user-, assistant-, or script-submitted jobs to a strict serial FIFO queue, show progress/artifacts, stop on failure, and recover order and execution state after restart. This manager is planned, not implemented; see [plan item 02](../../plan/work-items/02-integration-job-manager.md).

The subsequent workspace milestone is a typed, validated scene operation: inspect a selected node, add a node, create and assign a compatible resource, and group the change into Godot's undo/redo system. Subsequent work can add animation, physics, materials, generated 3D assets, audio, and live debugging. The assistant should prefer those native operations before reaching for GDScript.

Model-role selection does not itself implement a generation workflow. Image-to-3D, material, music, speech, sound-effects, and debugger tools still need adapters, validation, and testing. Likewise, a generated image is not automatically a seamless texture or a complete PBR material.

## Verification

Run from this checkout after building:

```sh
python3 integrations/tiiny/tests/check_model_configuration.py --editor-smoke
python3 integrations/tiiny/tests/check_model_configuration.py --http-smoke --displayed --report /tmp/tiiny-story01-displayed.json
python3 integrations/tiiny/tests/check_model_configuration.py --live-inference --report /tmp/tiiny-story01-live.json
```

The first command uses isolated settings/HOME and fake inference/SDK boundaries. It covers parsing, model planning, startup failures, malformed tools, script validation, no overwrites, context recovery, native dialog cancellation/late responses, ordinary resource/node creation, and owned SDK child cleanup. The second runs a loopback HTTP service, exercises actual request timeouts, PNG decoding/import and polygon requests, runs a fixture scene, checks Output, and captures displayed settings/chat windows. See [test instructions](tests/README.md) for backend selection and diagnostics.

`--live-inference` explicitly uses the connected Tiiny, picks an already-warm compatible coding model in temporary editor settings, sends chat and polygon requests, validates the saved polygon, and checks that model residency is unchanged. It tests image generation only when an image model is already warm; otherwise that adapter remains experimental. It never invokes model-management Apply. `--live-readonly` instead checks live inventory and Check Config without inference. Real mutating Apply and generator quality remain separate acceptance work under stories 03–04 and 09.

Chat accepts one function call per response, up to four tool rounds per turn. Invalid envelopes, empty/repeated IDs, and malformed arguments are rejected before dispatch; unknown tools return matched errors. Completed tool results appear immediately and remain in context after a failed continuation. Nothing automatically retries or rolls back completed files. Error handling avoids copying HTTP response bodies into Output.

Known baseline limitations include unrelated MultiplayerPeerExtension/WebRTCDataChannelExtension initialization diagnostics, and dummy-display popup warnings under headless testing. The separate invalid-script test deliberately expects one parse diagnostic. Passing Tiiny checks do not imply an otherwise diagnostic-free upstream Godot build. Earlier reports remain in [baseline evidence](../../plan/evidence/01-baseline.md) and [protocol evidence](../../plan/evidence/01-chat-protocol.md).
