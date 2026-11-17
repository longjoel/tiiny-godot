# 20 — Decompose long assistant turns into queued steps

Status: Complete. The per-round continuation mechanism is implemented and verified by the Jobs suite. Job-backed long tools remain a follow-up slice, as scoped.

Feature: Split a multi-round assistant turn into a chain of bounded FIFO jobs

Sequence: 20

Stream: `integration`

Dependencies: 02, 07, 18

## Scope

A single `chat_turn` job currently owns the whole agent loop: classification, up to ten model rounds, and every tool call, all under one `timeout_ms`. A large request such as “build a two-player pong game” can exceed that budget and fail as one job, losing the visible progress and forcing a full retry. The example job `d5bb215da685-00000023` timed out after loading and unloading the image model twice inside one `chat_turn`.

Split the turn at model-round boundaries. Each `chat_turn` job performs one model request and the tool calls in that response. If the model asks for another round, the job appends a continuation `chat_turn` at the queue tail and completes. The continuation carries the turn state in its parameters, so it can resume after other queued work or an editor restart. Each job has its own time budget. Strict FIFO, one current job, and failure-stops-dispatch are unchanged; there is no graph scheduler, priority, or parallel lane.

Long tool calls that deserve their own job (image generation, headless execution) are a follow-up slice. This item establishes the continuation mechanism and the per-round split first.

## Acceptance criteria

- [x] A multi-round turn produces multiple `chat_turn` jobs in accepted order, each with its own `timeout_ms`.
- [x] A continuation job restores the turn's messages, round counts, call IDs, failed-call set, ledger, scene context, and turn ID from its parameters.
- [x] The final assistant response is recorded on the final step; intermediate steps record a `continued` result with the next job ID.
- [x] A failure or cancellation in any step stops dispatch; later steps do not run and no duplicate continuation is appended.
- [x] Turn state survives an editor restart between steps; a continuation with missing or invalid state fails closed.
- [x] The Jobs panel shows each step with its prompt and step number.
- [x] Deterministic tests cover two-round and three-round turns, failure stop, restart, and duplicate-continuation rejection.
- [x] The integration README and STATUS distinguish the per-round split from the still-inline long tools.

## Verification and handoff

Use the existing fake queued-chat fixtures and the Jobs suite. Do not require a live device for the split itself. Record the exact job chain and results. Follow [TESTING.md](../TESTING.md).

## Evidence

- `check_builtin_jobs.py` passed all modes, including `chat`, `chat_protocol`, `chat_chain`, `chat_chain_prepare`, `chat_chain_restore`, `chat_empty`, and `chat_abandon`.
- `chat_chain` drives a three-step turn: classification, two tool rounds, and a final answer. It asserts three `chat_turn` jobs, `continued` results with `next_job`, restored step/round counters, and that a repeated response does not append a second continuation.
- `chat_chain_prepare`/`chat_chain_restore` persist a continuation with its turn state, restart the editor, and verify the state survives.
- `chat` verifies that a continuation is appended behind other queued work and that a later timeout still stops dispatch.
- `check_workspace_tools.py` and `check_model_configuration.py --editor-smoke` passed on the final binary.
- Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, 31.23 s. No build remains running.
- Not covered: a live-model multi-round turn, and moving long tools such as image generation into their own jobs.
