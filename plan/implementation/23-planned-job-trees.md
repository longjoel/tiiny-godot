# Story 23 implementation plan — planned job trees with leaf health

Status: Proposed. No source changes yet. Depends on stories 20, 21, and 22.

Parent: [23 — Planned job trees with leaf-level health](../work-items/23-planned-job-trees.md).

## Execution contract

- The FIFO queue remains the only executor. One worker slot, no parallel lanes, no priorities, no preemption.
- A plan is data: task IDs, dependencies, briefs, and budgets. The model declares it; the editor validates and orders it.
- The join is deferred. It is not queued at submission; it is appended when every task's latest attempt is resolved.
- A leaf's own state is authoritative. A coordinator's health is a rollup, not a pass/fail verdict.
- Normal failures inside a declared plan are contained. Failures outside a plan and unknown device/process outcomes still stop dispatch.
- The conversation must never contain an unanswered tool call. Cancellation appends a terminal cancellation step, not nothing.
- The user confirms every retry and planner proposal. No autonomous self-retry loop.

## Baseline

Relevant existing behavior:

- `queue.start_next()` refuses to start anything while any job is `running`, `failed`, or `interrupted`, then picks the first `queued` job. It has no notion of blocked or contained jobs.
- `queue.finish_with_successor()` atomically appends one successor and completes the parent. `queue.skip_with_successor()` does the same for a failed/cancelled/interrupted job.
- `_finish_locked()` sets `stop_reason` for any non-completed terminal state, which stops dispatch.
- `open()` marks every `running` job `interrupted` and sets `stop_reason`.
- `executor` owns exactly one worker and calls `finish`/`finish_with_successor`; continuation state is supplied by the worker.
- `panel.gd` owns job validation, workers, the scheduler board, details, retry/skip/clear, and the Needs attention column.
- the chat dock owns turn state, tool dispatch, continuation preparation, image/shell handoffs, and the turn ledger.
- `chat_turn` parameters are validated with an exact key set; `turn` state carries messages, counters, calls, failed calls, ledger, scene, and truncations.

## Data model

### `submit_plan` arguments

```json
{
  "goal": "short overall statement",
  "tasks": [
    {"id": "scene", "title": "Add the court", "brief": "Objective and expected result.", "depends_on": []},
    {"id": "input", "title": "Add controls", "brief": "...", "depends_on": ["scene"]}
  ]
}
```

Limits: 1–3 tasks per plan, unique IDs (`[A-Za-z0-9_-]{1,32}`), dependencies reference declared IDs, no cycles, depth ≤ 2, ≤ 8 tasks per root, queue cap 64, parent budget retained.

### Child `chat_turn` parameters

Existing chat parameters plus:

```json
{
  "role": "task",
  "plan_root": "<root coordinator job id>",
  "parent_job": "<immediate coordinator job id>",
  "task_id": "scene",
  "attempt": 1,
  "depth": 1,
  "task_title": "Add the court",
  "depends_on": [],
  "prior_attempt": {"error": {}, "summary": "", "successful": [], "artifacts": []}
}
```

`attempt` is 1-based. `prior_attempt` exists only on retries and is bounded.

### Parent completion result

The coordinator step completes without `next_job`:

```json
{
  "plan_pending": true,
  "plan": {"goal": "...", "tasks": [{"id": "...", "depends_on": [...], "title": "..."}]},
  "children": ["<job id>", "..."],
  "plan_call": {"id": "call_1", "name": "submit_plan", "arguments": {...}},
  "join_turn": {"id": "...", "step": 3, "system": "...", "messages": [...], "rounds": 1, "count": 2, "calls": ["call_1"], "failed": {}, "ledger": [], "scene": {}, "truncations": 0}
}
```

`join_turn` is the same JSON-safe state produced by `_prepare_chat_continuation`, captured with the plan call ID recorded in `calls` so the join can answer it with a matching tool result. It is bounded by the existing turn-state limits.

### Latest attempt

For a plan task, the latest attempt is the child job with the highest `attempt` for that `task_id` under the same `parent_job`. Older attempts are history. Dependents and join readiness consult the latest attempt only.

### Resolved attempts

- `completed`, `skipped`, `cancelled` are resolved.
- `queued`, `running` are unresolved.
- `failed` is unresolved while it awaits intervention.
- `interrupted` is unresolved and blocks the whole queue until acknowledged or skipped.

## Design

### 1. Submit and append

`submit_plan` is a dock-handled tool. Validation happens before append:

- task count, IDs, dependency references, acyclicity, depth, root task count, queue cap, attempt cap, and parent rounds/calls (≥ 2 each after the call).
- Parent retains a scene/turn snapshot for the join.

Accepted tasks append as child `chat_turn` jobs in stable topological order in one atomic queue transaction. No join is appended. The parent job completes with the result above. Submission keys are `task:<plan_root>:<task_id>:<attempt>`, so a retry is a new attempt, not a duplicate.

A child may submit its own plan while `depth < 2`. It becomes a coordinator; its join is its continuation. `plan_root` stays the topmost coordinator so root caps can be enforced.

### 2. Deferred join

Add to the queue:

```gdscript
func commit_ready_joins(validator: Callable) -> int
func cancel_plan(parent_id: String, validator: Callable) -> bool
```

`commit_ready_joins` scans parent jobs whose result has `plan_pending` and no `join_job`:

- If `plan_cancelled` is true, append a terminal cancellation step instead of a normal join.
- Otherwise, for every declared task, find its latest attempt. Ready when all latest attempts are resolved and none is `failed` or `interrupted`.
- Build a normal join `chat_turn` from `join_turn`, the saved `plan_call`, and the per-task outcomes. Append with submission key `plan-join:<parent_id>` under the queue lock in a single store write, and record the join ID on the parent result.
- If not ready, leave the plan awaiting.

Call it from the panel after every executor tick that changed a job state, after open/recovery, and after retry/skip/cancel. On restart it reconstructs everything from job records. A crash between the last resolution and the join append is repaired by the scan; the submission key prevents duplicates.

**Cancellation must close the conversation.** `Cancel plan` cancels queued tasks, cancels the current task if it belongs to the plan, marks the parent result `plan_cancelled`, and appends a terminal step that answers the `submit_plan` call with a `plan_cancelled` tool result. This is not a normal plan-result join; it exists so the turn has no orphan call. The join scan must honor the marker and never append a normal join afterward.

### 3. Eligible dispatch

Change `start_next()` from "first queued" to "first queued that is eligible":

- Ignore `failed` jobs whose result/attempt is marked `contained`. Keep `interrupted` as a hard stop.
- For a task, eligible when every dependency's latest attempt is `completed`.
- A task whose dependency is unresolved is blocked and passed over.
- A task whose dependency is skipped/cancelled is cancelled with `dependency_failed` before dispatch (or at skip time).
- Jobs outside a plan stay eligible.

Eligibility is computed from persisted records only. Blocked jobs keep their sequence; nothing is moved, reprioritized, or preempted. If every queued job is blocked, return empty.

Update the queue's own "cannot start while failed/interrupted" scan accordingly and add tests for contained failures.

### 4. Contained failure

A plan-child failure must not set the global `stop_reason`. Add a `contained: true` marker to the attempt/result and teach `_finish_locked()` to record the terminal state without stopping dispatch when it is set. The child still appears in Failed/Needs attention; its dependents stay blocked; independent siblings and unrelated jobs continue.

Only normal failures inside a declared plan are contained. `interrupted` is never contained. A failure outside a plan keeps the existing stop behavior.

### 5. Child role, structured result, budgets

- `_restore_turn_state`/`_start_queued_request` set `turn_role` from the job parameters.
- Tool payload is role-aware, not category-aware:
  - coordinator: normal tools plus `submit_plan` (`submit_result` never)
  - task: normal tools plus `submit_result`
  - intervention: only `revise_task` and `skip_task`
- `submit_result` validates the record (schema, bounds, plain free text) and ends the step with `structured_result`. It is excluded from work counters.
- The record contains: schema, task, status (`completed|blocked|failed|unverified`), summary, changes, verification, blockers, next_steps, job_ids.
- On `completed` with non-empty changes and zero successful calls, downgrade to `unverified`.
- Oversized records return `invalid_arguments`; two attempts maximum.
- Budgets: 10 work rounds, 14 work calls, 2 wrap-up rounds, 2 record attempts, absolute 12 rounds/16 calls. When a cap is reached, the next step advertises only `submit_result` and a wrap-up prompt. Attempts start with fresh budgets; retries are capped at 3 per task.

### 6. Rollup and UI

At join time, compute each task's resolved state and the plan rollup:

- `completed`: every task completed
- `partial`: some completed and some failed/skipped/cancelled
- `failed`: every task failed or the coordinator failed before dispatch
- `blocked`: any interrupted task

Store the per-task list in the join result. The root answer is composed by the coordinator from the recorded outcomes, not child prose.

UI: keep the column board. Cards show `plan` / task ID / attempt / depth. The details dialog shows the task list with states, attempts, edited instructions, rollup, and child job IDs. Needs attention hosts failed tasks and unresolved plans. No graph view.

### 7. Intervention dialog and retry

When a task's latest attempt is `failed`, the plan is `needs_intervention`. Independent branches continue.

The dialog shows goal, task, attempted brief, error, successful actions/artifacts (from the attempt ledger), attempt count, and an editable instruction prefilled with the brief.

- **Retry:** dock prepares a new attempt with the revised instruction and a bounded prior-attempt block; panel appends it with key `task:<plan_root>:<task_id>:<attempt+1>`. Attempt cap 3. Nothing completed is replayed.
- **Skip:** queue resolves the failed attempt `skipped`, cancels dependents with `dependency_failed`, and continues.
- **Cancel:** as above.
- **Ask planner:** see next section.

Dismissal leaves the task waiting; no auto-retry or auto-skip.

### 8. Planner guidance

Panel asks the dock to prepare an intervention step for the coordinator:

- new `chat_turn`, `role: "intervention"`, `purpose: "intervention"`, `failed_job`, `task_id`, `plan_call`, and the failure event;
- the coordinator's saved turn state, plus prior attempts/revisions;
- tool payload limited to `revise_task` and `skip_task`;
- one round, separate from the parent's reserved post-join budget; max 2 reviews per task.

The dock's intervention handler accepts one of:

```json
{"task_id": "...", "instruction": "...", "diagnosis": "..."}
{"task_id": "...", "reason": "..."}
```

It stores the proposal on the failed job (`result.intervention_proposal`) and completes the intervention step. The dialog shows the proposal in the editable box with its rationale. The user confirms Retry or Skip. Invalid/failed proposals fall back to the original brief and show the error. No automatic retry.

### 9. Delegation precedence and authority

- Child jobs inherit the configured coding model, connection hash, tool mode, approvals, user preferences, and the captured `AGENTS.md` section/hash.
- Planner guidance and user edits cannot grant tools, bypass approvals, weaken validation, or change tool mode.
- Briefly state that delegation is decomposition, not parallelism; child cost is additive.

## Slices

### Slice A — plan data, validation, and child append

- Add `submit_plan` with schema/validation and stable topological order.
- Extend `chat_turn` validation for task parameters and prior attempts.
- Capture `join_turn`, `plan_call`, and children on the parent; complete without a successor.
- Add generic plan/task validation helpers that can run without a model.

Gate: pure fixture rejects each invalid plan with no append; a valid plan appends tasks and the parent awaiting result; no join exists yet.

### Slice B — deferred join and cancellation

- Add `commit_ready_joins`, readiness, idempotency, restart scan, and `cancel_plan`.
- Make cancellation append a terminal cancellation step; ensure no normal join afterward.
- Build the join tool result and continue the coordinator.

Gate: success join, restart before/after the join append, duplicate rejection, and cancellation with no orphan call.

### Slice C — eligible dispatch and contained failure

- Add eligibility and blocked-task skipping.
- Add contained failure recording and `start_next` exemptions.
- Cancel dependents on skip.
- Update queue/executor fixtures that assume strict first-queued dispatch.

Gate: an independent sibling completes while a failed task waits; its dependent stays blocked; an unrelated job runs; an interrupted task still blocks everything.

### Slice D — child role, tools, structured result, budgets

- Role-aware payloads for coordinator/task/intervention.
- `submit_result` validation, downgrade rule, result storage.
- Wrap-up step and counters.
- Child tool mode/approval inheritance and AGENTS duplication.

Gate: valid record, prose fallback, malformed/oversized record, overclaim downgrade, wrap-up with full budget, and early finish.

### Slice E — rollup and Jobs UI

- Compute and store per-task outcomes and rollup.
- Add lineage, task list, attempt history, and rollup to card/details.
- No graph view.

Gate: displayed or headless fixture asserts `partial` with one skipped child and the details content.

### Slice F — intervention dialog, retry, skip, cancel

- Add dialog and actions.
- Add attempt append, prior-attempt block, cap, and dependents cancellation.
- Add dismissal and restart behavior.

Gate: retry success after an edit, retry failure then skip, cap, cancel, dismissal across restart, and prior contents.

### Slice G — planner guidance

- Add intervention step, tools, proposal storage, dialog proposal, fallback, and caps.
- Ensure the intervention step is not the join and cannot consume it.

Gate: proposal accepted/overridden, skip proposal, planner failure/invalid record, cap.

### Slice H — live evidence and docs

- Live plan with two tasks and a dependency; one failure; edit/retry; record per-task outcomes and rollup.
- Update README, tests README, WORKSPACE_ASSISTANT, STATUS, and the 23 work item.

Gate: exact job chain, attempts, timings, and outcomes recorded. A trace is not a success rate.

## File touch points

- `editor/tiiny_ai_dock_source.h` — `submit_plan`, task/intervention turn roles, structured result, retry/intervention preparation, join result.
- `editor/tiiny/tools/registry.gd` — role-aware tools, plan/result schemas.
- `editor/tiiny/jobs/queue.gd` — plan records, eligibility, contained failure, join scan, cancellation, dependents.
- `editor/tiiny/jobs/executor.gd` — terminal hooks for join scanning; contained failure pass-through.
- `editor/tiiny/jobs/panel.gd` — validation, join commit trigger, intervention dialog/actions, lineage/details.
- `integrations/tiiny/tests/test_job_queue.gd`, `test_job_executor.gd`, `editor_builtin_jobs.gd`, `check_builtin_jobs.py` — deterministic coverage.
- `integrations/tiiny/README.md`, `integrations/tiiny/tests/README.md`, `plan/STATUS.md` — docs.

## Risks

- **Queue semantics.** "First eligible" changes a core invariant. Keep the tests explicit about deferral versus reordering; never let a blocked job lose its sequence.
- **Orphan tool calls.** Every plan submission must eventually receive a tool result, including cancellation. Verify conversation integrity before any next model request.
- **Containment safety.** Only declared-plan normal failures are contained. Interrupted outcomes and failures outside plans still stop. This boundary needs focused tests.
- **Plan state size.** Parent results carry `join_turn`, tasks, and outcomes. Bound tasks and records; keep the existing 24 MiB store limit in mind.
- **Nested plans.** Each coordinator has its own deferred join. Ensure `plan_root`, depth, and readiness do not confuse a child coordinator's join with the root's.
- **Planner loops.** The user confirms every proposal; caps and separate budgets prevent a review loop from starving the final answer.
- **UI scope.** The board stays columns. No graph or new scheduling surface.

## Handoff

Story 23 can begin after 22's direct-dispatch slice. If 23 grows beyond these slices, split planner guidance into its own item rather than weakening the join or cancellation guarantees.
