# 30 — Device hygiene and request discipline

Status: Complete. Thinking is off by default, older chat turns are trimmed, SSD capacity is cached, and the manager unloads idle non-coding models while protecting the coding model. See the evidence below.

Feature: Keep the Tiiny device in a low-overhead state between requests: unload idle non-coding models, keep thinking off unless requested, bound chat history, avoid redundant capacity polls, and document the measured MoE, context, transport, and thermal limits

Sequence: 30

Stream: `device`

Dependencies: 02, 03, 04, 22. Extends the model manager, chat turn pipeline, and device guidance. It does not add a parallel queue or change the model-selection contract.

Implementation: [plan](../implementation/30-device-hygiene.md).

## Why

A device profile showed Z-Image holding 23 NPU units and about 11 GB while the editor was idle, thinking enabled by default, a 262K client context, and 30-second capacity refreshes that included a 626 ms `/api/v1/sys/storage` call. None of that helps the coding turn, and all of it competes with the one loaded chat model.

The community measurements also confirm the shape of the workload: Qwen3.6-35B-A3B (MoE) is roughly twice the throughput of a dense 27B, generation slows sharply with context, and the device has no active cooling. The integration should make the cheap default the safe default and leave the exceptions explicit.

## Scope

### Idle model unloading

- Add **Advanced > Unload idle models**, default on.
- When the FIFO queue has no queued/running/interrupted device work and the manager is not applying or running a model job, the manager:
  1. refreshes the catalog/loaded state;
  2. keeps the configured (or adopted) coding model loaded;
  3. unloads every other loaded model through the pinned SDK CLI `unload` command;
  4. verifies each unload against a fresh snapshot;
  5. reports exactly what was unloaded and what remains warm.
- The cleanup never unloads the coding model. If no coding model is loaded, it does nothing.
- Cleanup runs only after a valid applied model configuration exists.
- A failure stops the cleanup, reports the model, and leaves the device for review.
- The cleanup is not a queue job; it runs only when the queue is idle and holds the device lease so a new chat/asset job waits.
- The next specialized job reloads its model on demand through the existing scheduling path.

### Thinking default

- **Advanced > Model thinking** now defaults off.
- A one-time migration sets the old default-on value to off; a user can re-enable it.
- Chat requests use `chat_template_kwargs: {"enable_thinking": <setting>}`.
- Classification, visual, and shape-generation requests already force thinking off.

### Chat history bound

- At the start of a new turn, older conversation turns are trimmed to a byte budget derived from the selected context: `clamp(context_tokens / 3, 4096, 512 KiB)`.
- Trimming starts at a **user** message boundary so assistant tool calls are not separated from their tool results.
- The trimmed history begins with a short `[Earlier conversation was trimmed…]` user note.
- A single message that exceeds the context budget is still rejected rather than silently cut.
- The dock's visible history is retained; only the model context is bounded.

### Capacity polling

- Cache `/api/v1/sys/storage` for 60 seconds, keyed by connection identity.
- Catalog and loaded-model state continue to refresh on the 30-second idle check and on demand.
- This removes the 626 ms storage call from every refresh while preserving a bounded staleness.

### Guidance

Document, without pretending they are enforced in code:

- prefer MoE coding models and benchmark candidates (Qwen3.6-35B-A3B ≈27 tok/s vs dense 27B ≈12.6 tok/s);
- keep contexts short; 1K ≈27 tok/s, 128K ≈15.5 tok/s, first token at 128K can take minutes;
- one client, one loaded chat model; the FIFO/lease is serial but external connectors still queue;
- use Wi-Fi/LAN or wired Ethernet for model ports; USB exposes the management port;
- avoid keeping the desktop dashboard open if it generates 404/storage polling noise;
- provide airflow; 73–76 °C is normal for sustained 35B inference without active cooling.

## Acceptance criteria

- [x] Thinking defaults off for new and migrated configurations; classification/visual/shape payloads force it off.
- [x] A long conversation is trimmed to a user-led bounded history; the plain-text path is unchanged when no trimming is needed.
- [x] SSD capacity is cached for 60 seconds per connection.
- [x] Idle cleanup preserves the coding model, requires an idle queue and an applied configuration, and verifies unloads.
- [x] The unload setting is registered with basic editor visibility and defaults on.
- [x] The README documents MoE, thinking, context, serialization, transport, dashboard overhead, and thermals.
- [x] Workspace/editor fixtures, transaction, selection, runtime, smoke, and Jobs suites are rerun.
- [ ] A live idle-unload run is recorded only after the user chooses to exercise it on the device.

## Evidence

- `editor_workspace_tools.gd`: thinking defaults off, idle-unload setting defaults on, and a 160-message conversation trims to a bounded user-led history.
- `check_workspace_tools.py`, `check_workspace_transactions.py`, the 20-case selection corpus, runtime verification, and editor smoke passed.
- Full Jobs suite passed 66 modes; editor smoke passed 13.
- Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:32.71`, `bin/godot.linuxbsd.editor.x86_64`. No build remains running.

## Notes

- The idle cleanup intentionally overrides the model table's **Keep loaded** choice for non-coding models when the setting is on. Disable the setting to keep specialized models resident.
- No live unload was run during this item; the device profile and CLI path are documented, and the cleanup is guarded so it cannot remove the coding model.
