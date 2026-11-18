# Story 30 implementation plan — device hygiene and request discipline

Status: Implemented and covered by the editor/workspace fixtures and the full Jobs suite. Live idle unload is not run by the test suite.

Parent: [30 — Device hygiene and request discipline](../work-items/30-device-hygiene.md).

## 1. Thinking

- `tiiny_ai/advanced/model_thinking` defaults to `false`.
- A one-time `_tiiny_ai/model_thinking_defaulted` marker sets the old default-on value to off for existing installs; the user can re-enable it.
- Chat payloads keep using `_thinking_enabled()`.
- Vision classification and shape generation already hard-code `"enable_thinking": false`.

## 2. Conversation bound

`_history_budget_bytes()` returns `clamp(context_tokens / 3, 4096, 512 KiB)`.

`_trim_conversation(messages)`:

1. serializes the history and returns a copy when under budget;
2. drops the oldest messages until under the byte budget;
3. advances to the next `user` message so tool-call/tool-result pairs are not orphaned;
4. inserts `[Earlier conversation was trimmed to keep the request short.]` as the first user message;
5. returns an empty history if no user remains; the current prompt is appended afterward.

Applied when queueing a new chat turn and when `_send_chat` seeds the first turn. The dock's visible history is not cleared; only the model context is bounded. A single oversized message is still rejected by `_check_context_budget`.

## 3. Idle unload

Setting: `tiiny_ai/advanced/unload_idle_models`, default `true`, registered with `PROPERTY_USAGE_EDITOR_BASIC_SETTING`.

Manager `_process` (30-second idle check) now awaits the snapshot refresh, then calls `_unload_idle_models()`.

`_unload_idle_models()` guards:

- not busy, not applying, no model job;
- an applied, valid model configuration exists;
- the Jobs service is available and `_queue_has_pending` is false;
- a device connection exists;
- a suitable coding model is loaded (configured, or the adopted loaded coding model).

It then:

1. collects every loaded model ID other than the coding model;
2. acquires the device lease and sets `busy`;
3. for each ID, rechecks the queue and runs the pinned CLI `unload <id>`;
4. stops on the first non-zero exit with a report;
5. refreshes the snapshot and verifies none of the unloaded IDs are still loaded;
6. updates `snapshot` and reports what remains warm;
7. always releases `busy` and the lease.

The cleanup intentionally ignores “Keep loaded” for non-coding models while enabled. The next specialized job reloads its model through the existing scheduling path.

## 4. Capacity polling

Add `storage_cache = {at, data, identity}`. `_fetch_snapshot` uses the cached `sys/storage` response when it is under 60 seconds old and the connection identity matches; otherwise it fetches and stores. Catalog and NPU state still refresh normally. This removes a ~626 ms storage call from every 30-second poll.

## 5. Serialization and guidance

No new lane is added. Chat, resource inference, specialized asset jobs, shell jobs, and classification share the existing FIFO queue and device lease. The README documents that external connectors and a second client still queue behind the editor, and the measured MoE/context/transport/thermal limits.

## 6. Tests

- `editor_workspace_tools.gd`: thinking default off, idle-unload setting default on, long-history trim begins with a user marker and is smaller.
- Existing pure/editor workspace, transaction, selection, runtime, smoke, and Jobs suites.
- A live idle-unload run is intentionally manual: it changes device state, so it is not part of deterministic CI. The device profile and CLI path are documented.
