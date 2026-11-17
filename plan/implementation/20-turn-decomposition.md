# Story 20 implementation plan — turn decomposition

Status: In progress

Parent: [story 20](../work-items/20-turn-decomposition.md).

## Problem

`chat_turn` runs classification, up to ten model rounds, and every tool call inside one executor deadline. The deadline is `tiiny_ai/advanced/request_timeout_seconds` (default 300 s). A multi-step request can exceed it even when every individual request is healthy. The job then stops as one unit, and the user must retry the whole turn.

## Design

Split at the model-round boundary. A job is one model request plus the tool calls in that response.

1. The first job classifies the request and runs the first answer round.
2. When the model returns tool calls, the job executes them, then appends a continuation `chat_turn` at the queue tail and completes with `{"continued": true, "next_job": "<id>"}`.
3. The continuation restores the turn state from its `turn` parameter and sends the next model request. It does not re-classify and does not append the user message again.
4. When the model returns final text, the job records the response and completes normally.
5. If a step fails or is cancelled, the queue stops dispatch. The continuation is already at the tail but does not run until the user resolves the stopped step.

The continuation is an ordinary append at the tail. It does not jump ahead, does not run as a child, and does not wait while the current job holds the slot. This preserves the story 02 contract.

## Turn state

The continuation job carries a `turn` dictionary:

| Key | Meaning |
| --- | --- |
| `id` | Stable turn ID, reused for undo groups and ledger entries |
| `step` | 1-based step number for display |
| `system` | The system prompt used for the turn |
| `messages` | `turn_messages` including the user message, assistant tool calls, and tool results |
| `rounds` | `tool_rounds` |
| `calls` | `tool_call_ids` |
| `count` | `tool_call_count` |
| `failed` | `turn_failed_calls` signatures |
| `ledger` | `turn_ledger` entries |
| `scene` | `turn_scene_context` |

The state is JSON round-tripped before append so the queue's `_json_safe` check cannot reject it. The existing 24 MiB chat-context bound still applies.

## Slices

### Slice A — continuation state and dispatch

- Extend `_validate_chat` to accept an optional `turn` dictionary with the keys above and bounded sizes.
- In `poll_queued_chat`, when `turn` is present, restore the state and call `_continue_agent()` instead of `_start_queued_request()`.
- In `_request_completed`, after tool execution, append a continuation when `queued_chat_started` is true; otherwise keep the current inline `_continue_agent.call_deferred()` path for direct (non-queued) turns.
- Add `_append_chat_continuation()` that builds the parameters and appends through `jobs_service`.
- Include `continued` and `next_job` in the completed result.
- Reject a continuation whose `turn` state is missing, malformed, or belongs to a different model/connection.

### Slice B — tests

- Extend the `chat_protocol` Jobs mode to expect a continuation job after the tool round, drive the next request, and assert the final response is on the continuation.
- Add a three-round mode that proves the chain grows one job per round and the round counters persist.
- Add a failure mode: a failed tool or a stopped step leaves the continuation queued and dispatch stopped.
- Add a restart mode: a continuation restored from disk resumes with the same messages and counters.
- Add a duplicate-continuation check: a step cannot append two continuations for the same round.

### Slice C — UI

- Job title shows `step N` when `turn.step` is present.
- The completed card shows `continued` rather than an empty response.
- The chat dock does not append an empty assistant message for an intermediate step.

### Slice D — follow-up: job-backed long tools

Defer `generate_image`, `run_godot_headless`, and `run_command` to their own jobs with a continuation that supplies the tool result. This is the slice that moves the image-model load/unload out of `chat_turn` and into an `asset_generate` job. It is not part of the first implementation.

## Boundaries

- The per-round split bounds each model request, not a single long tool call. A tool that exceeds the round budget still stops the step.
- The continuation chain is linear. There is no fan-out, join, or dependency graph.
- Conversation isolation between interleaved user turns is unchanged from the current queue behavior.
- Live-model behavior is not required for the split; the fake queued-chat fixtures cover the mechanism.
