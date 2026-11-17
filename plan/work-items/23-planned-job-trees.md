# 23 — Planned job trees with leaf-level health and failure intervention

Status: Complete. Deterministic/editor fixtures cover plans, deferred joins, dependency injection, contained failures, retry/skip/cancel, planner proposals, invalid plans, and overclaim downgrade. A live Qwen3.6 trace submitted a two-task dependent plan, ran both child jobs, injected the dependency result, joined once, and produced a final answer; one child returned prose instead of `submit_result`, so the rollup was `partial` and the fallback was recorded as `unverified`. That is the intended labeled fallback, not a completed structured record. See [implementation plan](../implementation/23-planned-job-trees.md).

Feature: Let the coding model submit a bounded execution plan whose tasks run as queued child jobs, with per-leaf health and a user-confirmed, planner-assisted retry when a leaf fails

Sequence: 23

Stream: `integration`

Dependencies: 02, 07, 20, 21, 22. Requires the atomic tool-result handoff from 21 and single direct dispatch from 22. Extends story 02's tail-append queue; it does not add a parallel lane.

Implementation: [plan](../implementation/23-planned-job-trees.md).

## Why

The target runtime is small local coding models. They handle short, focused instructions better than long multi-goal turns, and a large request ("build a two-player pong game with menus and sound") can exceed both their attention span and a single job's budget. The coding model should be able to submit an execution plan, have the queue run its tasks, and assemble recorded outcomes.

The classifier in item 22 was doing a weak, single-label version of this before the model saw the request. Removing it only makes sense if the model can plan deliberately and see real results.

The useful mental model is a query plan: declare tasks and dependencies, validate and order them, run them one at a time, and return outcomes. There is no cost-based optimizer and no parallel plan because the device runs one inference at a time. The unit of health is the leaf task, not a single verdict for the whole tree.

When a leaf fails, the useful response is not to fail the tree or silently re-plan. The user should see what was attempted, why it failed, and what already succeeded, then adjust the instruction and retry with that work reused. Equally, a failed branch should not stall unrelated work: if one jungle texture fails, the other assets can keep generating while the user fixes that one task. That is how a local assistant communicates a problem without discarding the rest of the plan.

## Scope

Add a tool (`submit_plan`) that lets a `chat_turn` step submit a bounded plan:

```json
{
  "goal": "short statement of the overall request",
  "tasks": [
    {"id": "scene", "title": "Add the court", "brief": "Objective, constraints, expected result, and relevant excerpts.", "depends_on": []},
    {"id": "input", "title": "Add paddle controls", "brief": "...", "depends_on": ["scene"]}
  ]
}
```

Validation happens before anything is appended: 1–3 tasks per plan, unique short IDs, dependencies reference declared tasks, no cycles, depth and queue caps, and enough parent budget to receive the result and answer. A rejected plan returns a tool error and leaves the queue unchanged; the model may submit a corrected plan within its normal budget.

Accepted tasks are appended as child `chat_turn` jobs in stable topological order in one atomic commit. Stable means the declared order breaks ties, so the same plan always produces the same sequence. One worker slot executes them.

A child job carries a fresh bounded brief and:

- the same configured coding model, connection hash, tool mode, approval policy, and user preferences as its parent;
- the same captured `AGENTS.md` project-instructions section and hash, from item 22;
- persisted plan fields: `plan_root`, `task_id`, `attempt`, `parent_job`, `depends_on`, `depth`, `task_title`.

Dependent tasks receive the bounded structured results of their dependencies in their effective brief at dispatch time, not at plan time. A task whose dependency failed is auto-cancelled with `dependency_failed` and never runs with missing inputs.

A child may itself submit a plan while below the depth limit, becoming an internal node. The tree is persisted through job parameters and links, not held in memory, and is reconstructed from queue records after a restart.

### Deferred join

The parent's continuation is not appended when the plan is submitted. The parent step completes as an awaiting-plan coordinator, recording its saved turn state and child IDs. The join is appended only when every task's latest attempt is resolved: completed, skipped, or cancelled.

This is what makes intervention possible. While the plan is unresolved, a retry attempt is appended at the queue tail and therefore runs before the join. There is no insertion, reordering, or blocked queued job.

The join is appended exactly once under the idempotency key `plan-join:<parent_job_id>`. A recovery scan at startup and after each terminal transition finds awaiting plans whose tasks are all resolved, appends the join, and records the linkage. A crash between the last task resolving and the join append is repaired by that scan; a restart cannot duplicate the join.

### Eligible dispatch

A failed or unresolved branch must not stall the rest of the plan. The queue dispatches the lowest-sequence **eligible** job rather than simply the lowest-sequence queued job:

- A task is eligible when every dependency's latest attempt is `completed`.
- A task whose dependency is still `queued`, `running`, or awaiting intervention is blocked and is passed over, not moved or reordered.
- A task whose dependency failed and was skipped or cancelled is itself cancelled with `dependency_failed`; it is never dispatched.
- Jobs outside the plan, and plan tasks with no unresolved dependencies, remain eligible. They run while the failed task waits for the user.

This is FIFO among eligible work, not submission-order completion. Blocked jobs keep their sequence; nothing jumps ahead of them, and no priority, preemption, or parallel lane is added. A retry is appended at the tail like any new attempt, so it runs before its dependents and before the join but after work that was already eligible. The trade-off is explicit: a later independent job may finish before an earlier blocked one becomes eligible.

Eligibility is derived from persisted attempt records, never from in-memory scheduler state, so the same selection is reproducible after restart.

### Leaf health and rollups

A leaf task's own recorded state is authoritative: `queued`, `running`, `completed`, `failed`, `cancelled`, or `interrupted`, plus its structured result. An internal node's health is a rollup of its direct children's resolved outcomes:

| Rollup | Meaning |
| --- | --- |
| `completed` | Every direct child completed and the node's own coordination succeeded. |
| `partial` | Some children completed and some failed, were skipped, or were dependency-cancelled. |
| `failed` | Every child failed, or the node failed before its children could be dispatched. |
| `blocked` | Any child is `interrupted` or awaiting device acknowledgement. |
| `running` / `queued` | Work is still in progress. |

`needs_intervention` is an attention flag that can coexist with `running` or `queued`; it is not a terminal rollup. The final rollup is computed when the plan resolves.

A failed leaf does not mark its coordinating parent `failed`. The parent reports `partial` with per-task outcomes once the plan resolves, so the user sees "2 of 3 tasks completed, 1 skipped" rather than an undifferentiated failure.

While work continues, a plan can be both running and awaiting attention. Treat `needs_intervention` as an attention flag on the plan, not a terminal state: the details show per-task states (for example "1 failed, 1 skipped, 2 running, 1 queued") and the rollup is computed only when the plan resolves.

### Failure intervention

When a task fails normally (validation, execution, or protocol — not an unknown device outcome), the task enters `needs_intervention` and its dependents become blocked. Independent siblings and unrelated jobs keep running; the failed branch does not pause the queue. The user can resolve the failure at any time, and work completed by other branches is already recorded when they do.

The plan appears in the existing Needs attention column with **Fix task** while its other tasks may still be running. The intervention dialog shows:

- the overall goal and the task title;
- the exact brief that was attempted;
- the recorded error code, message, and field if present;
- what already succeeded, bounded: tool, summary, affected target, artifact IDs and hashes, undo group;
- the attempt number and remaining attempts;
- an editable instruction box labeled "What should we do instead?", prefilled with the original brief.

Actions: **Retry**, **Ask planner**, **Skip task**, **Cancel plan**. Dismissing the dialog leaves the task in `needs_intervention`; it does not auto-retry or auto-skip, and other branches continue meanwhile.

Retry appends a new attempt job for the same task at the queue tail. Its effective brief is the user's revised instruction plus a bounded prior-attempt block containing the original brief, the error, the successful calls with targets and artifacts, and unresolved items. The retry starts a fresh turn with a fresh normal budget; nothing already completed is replayed automatically, and tool validation still rejects duplicate files, stale scene revisions, and denied paths. The model is told what exists so it can continue rather than repeat. Because siblings may have changed the workspace while the dialog was open, the prior-attempt block labels recorded scene state as needing revalidation rather than as current fact.

### Planner guidance

The user may not know how to repair a task. **Ask planner** sends the failure back to the coordinating node — the model that wrote the plan — so it can diagnose the problem and propose a fix.

It appends one intervention planning step for the plan's coordinator, carrying a synthetic failure event: the task, original brief, every prior attempt (including user and planner revisions), the recorded error, and what already succeeded. The coordinator sees this within its own plan conversation. Its tool array is limited to two intervention tools:

```json
{"tool": "revise_task", "arguments": {"task_id": "texture", "instruction": "New brief for the retry.", "diagnosis": "Why this should work differently, in plain sentences."}}
```

```json
{"tool": "skip_task", "arguments": {"task_id": "texture", "reason": "Plain-sentence explanation."}}
```

`revise_task` returns the proposed instruction and a short rationale, which appear in the intervention dialog in the same editable box, prefilled and clearly attributed to the planner. The user can edit it and choose Retry, or reject it and go back to the original brief. The planner does not retry on its own: guidance is a proposal, not an autonomous loop, and it cannot skip a task without the user confirming Skip. If the planner call fails, returns an invalid record, or proposes an instruction over the bound, the dialog keeps the original brief and shows the planner's error.

Planner reviews are capped at 2 per task and are budgeted separately from the parent's post-join allowance, so reviewing a failure cannot starve the final answer. Each review is one bounded model round; the coordinator's intervention step is persisted like any other job and survives restart. It is marked `purpose: intervention` so it is never confused with, or allowed to consume, the deferred join.

Skip resolves the task as cancelled with the user's reason and lets the plan continue with the remaining tasks. Cancel abandons the unresolved tasks, cancels queued or running tasks in the plan, and appends a terminal cancellation step that answers the `submit_plan` call so the conversation has no orphan call. It does not append a normal plan-result join, and it keeps completed leaves and their records. Attempts are capped at 3 per task (initial plus two retries); the cap is a testable constant. A failed task that is `interrupted` is not retryable from this dialog until the device outcome is acknowledged or skipped; that is the existing safety path, not an edit-and-retry path.

The user's edited instruction is user authority, but it cannot grant tools, bypass approvals, weaken validation, or override the base policy.

### Child result contract

Children are workers, not chat participants, so a leaf's final output is structured data rather than conversational prose. The plain-text reply contract from item 22 applies to the user-facing parent answer.

```json
{
  "schema": 1,
  "task": "short task label",
  "status": "completed | blocked | failed | unverified",
  "summary": "1-3 plain sentences, no Markdown",
  "changes": [{"kind": "node|file|resource", "target": "...", "detail": "..."}],
  "verification": [{"check": "...", "result": "passed|failed|skipped", "detail": "..."}],
  "blockers": ["..."],
  "next_steps": ["..."],
  "job_ids": ["..."]
}
```

Prefer a terminal `submit_result` tool whose handler validates the record before the leaf completes. A child that instead ends with plain text is wrapped as a labeled fallback (`status: "unverified"`, `format: "text"`) rather than failing the turn over formatting. An empty final message with no successful tool follows the existing empty-response failure rule.

The harness never upgrades a claim. A claimed `completed` with a non-empty `changes` list but zero successful tool calls is downgraded to `unverified`. Oversized fields and arrays are rejected rather than truncated into a misleading partial record; the full record remains in job details.

### Budgets and reservations

The current turn limits are 10 tool rounds and 16 tool calls, counted across continuation steps. A leaf must never spend its whole allowance on work and then be unable to report, so reporting is reserved rather than shared:

| Budget | Per leaf attempt |
| --- | --- |
| Work model rounds | 10 |
| Work tool calls | 14 (two calls held back for reporting) |
| Wrap-up rounds | 2, advertising only `submit_result` |
| `submit_result` attempts | 2, excluded from work counters |
| Absolute cap | 12 rounds, 16 executed calls |
| Per-step timeout | Parent's per-step timeout, or shorter if set |
| Structured record | ~4 KiB, 20 changes, 10 verification entries |
| User retries | 2 (3 attempts total), each with a fresh budget |
| Planner reviews | 2 per task, budgeted separately from the parent's post-join allowance |

Rules:

- When work rounds reach 10 or work calls reach 14, the next dispatched step is a wrap-up step whose prompt says the work budget is spent and whose tool array contains only `submit_result`. This is terminal-format enforcement for a worker, not the request classification removed in 22.
- `submit_result` is available to child jobs throughout, so a leaf can report as soon as its work is done; only the wrap-up step narrows the array to it. It is never advertised to the user-facing parent turn.
- A schema-invalid or oversized record returns `invalid_arguments`; the second attempted record is the last. A leaf that exhausts wrap-up without a valid record completes as `unverified` with `result_invalid`.
- A plan is refused unless the parent still has at least 2 rounds and 2 calls remaining after the submitting call, so it can receive results and answer. The check happens before the atomic append.
- Leaf counters start fresh per attempt. Retries consume the per-task attempt cap and the queue's total-job cap, so a loop cannot flood the queue.
- Recursion is bounded by depth and job caps, not by shrinking per-attempt budgets.

Recommended defaults, recorded as testable constants: plan depth 2, 3 tasks per plan, 8 tasks per root turn, 3 attempts per task, 64 queued jobs total.

## Acceptance criteria

- [x] A submitted plan is validated before append: task count, unique IDs, dependency references, acyclicity, depth, queue size, parent budget, and attempt cap. Invalid plans change nothing and return a tool error with the reason.
- [x] Accepted tasks commit atomically in stable topological order. The parent step completes as an awaiting-plan coordinator with saved join state and child IDs; no continuation is queued yet.
- [x] The join is appended only when every task's latest attempt is resolved, exactly once under `plan-join:<parent_job_id>`. A startup/terminal-transition scan repairs a crash between resolution and append. Restart cannot lose or duplicate the join.
- [x] The tree is fully reconstructable from persisted job records (`plan_root`, `task_id`, `attempt`, `parent_job`, `depends_on`, and the parent's recorded child IDs). No in-memory scheduler state is required.
- [x] Tasks execute one at a time on the existing FIFO queue in plan order. No parallel lane, priority, preemption, insertion, or reordering of already queued work is introduced.
- [x] A dependent task's effective brief is composed at dispatch from its own brief plus the bounded structured results of its dependencies.
- [x] The queue dispatches the lowest-sequence eligible job. A task with an unresolved or failed dependency is blocked and passed over, never moved or reordered; a task whose dependency was skipped or cancelled is itself cancelled with `dependency_failed`. Independent siblings and unrelated jobs stay eligible and keep running.
- [x] A normal task failure sets `needs_intervention` and blocks only that task's dependents; it does not pause dispatch, auto-retry, or mark the parent `failed`. Failures outside a declared plan keep the existing failure-stops-dispatch rule. An `interrupted` task blocks the plan until it is acknowledged or skipped.
- [x] The intervention surface shows the goal, task, attempted brief, error, successful actions and artifacts, attempt count, and an editable instruction field. Retry, Ask planner, Skip task, and Cancel plan are the actions; dismissal leaves that task awaiting a decision while other branches continue.
- [x] Ask planner appends one persisted intervention step for the plan coordinator with the failure event and prior attempts, advertising only `revise_task` and `skip_task`. A `revise_task` proposal appears in the editable field with its rationale and is not retried without the user confirming. `skip_task` does not take effect until the user confirms Skip. A failed or invalid planner response leaves the original brief and shows the error.
- [x] Planner reviews are capped at 2 per task, use their own budget so the parent's post-join allowance is preserved, and never bypass attempts, approvals, validation, or tool mode.
- [x] Retry appends one new attempt at the tail with the revised instruction plus a bounded prior-attempt block (original brief, error, successful calls with targets and artifacts, unresolved items). Nothing completed is replayed automatically, and duplicate or stale operations are still rejected by normal validation.
- [x] Skip resolves the task as cancelled and cancels its dependents with `dependency_failed` while independent branches continue; Cancel cancels the plan's queued/running tasks and appends a terminal cancellation step that answers the plan call, never a normal join; both preserve completed leaves, attempts, and records. No unresolved plan submission is left without a tool result. Attempts are capped at 3 per task.
- [x] The continuation/join appends exactly one matching tool result for the plan call, carrying per-task claimed status, recorded state, attempt count, call counts, and bounded changes/verification. A restart cannot duplicate that result.
- [x] Leaf health is stored per task and rolled up per node (`completed`, `partial`, `failed`, `blocked`, `running`, `queued`), with `needs_intervention` tracked as an attention flag rather than a rollup. A parent with one skipped child reports `partial`.
- [x] Each leaf completes with a schema-validated structured record from `submit_result`, or a labeled fallback; overclaims are downgraded to `unverified`; oversized records are rejected and retried within the reserved attempts.
- [x] Budgets are enforced and reporting is reserved: 10 work rounds, 14 work calls, 2 wrap-up rounds, 2 record attempts, absolute ceiling 12 rounds and 16 calls. A plan is refused unless the parent retains 2 rounds and 2 calls.
- [x] `submit_plan` and `submit_result` are advertised only to jobs where they apply, never as request-category routing. Children keep the same tool registry and mode as their parent.
- [x] The Jobs panel keeps its column board. Plan lineage (`plan`, `task id`, attempt, depth) appears on cards, the Needs attention column hosts unresolved plans, and the details dialog shows the per-task list, attempts, edited instructions, and rollup. No hierarchy graph or new scheduling view is added. `plan_success` asserts the plan and task card titles, plan/task details content, and that both cards can be constructed.
- [x] Deterministic fixtures cover: two successful tasks; a failed task whose independent sibling continues to completion while its dependent stays blocked; a `partial` rollup; restart before and after the append boundary, between resolution and join, and with a blocked dependent; selection of the next eligible job past a blocked one; each validation refusal; a blocked plan on an interrupted task; the full work-budget wrap-up; a valid record, prose fallback, malformed record, overclaim, and oversized record; dependency-result injection; retry success after an edit; retry failure then skip with dependent cancellation; the attempt cap; cancel; dialog dismissal across restart; prior-attempt contents; a planner proposal accepted and retried; a planner proposal replaced by the user; a planner that chooses skip; a planner that fails or returns an invalid record; and the planner review cap.
- [x] A live coding-model trace submits a dependent two-task plan, runs both tasks, injects the first result into the second, records per-task outcomes and the final rollup, and produces a final answer. A live failure/retry was not forced; retry, skip, cancel, and planner guidance are covered by the deterministic `plan_failure_retry`, `plan_planner_retry`, `plan_skip`, and `plan_cancel` fixtures. Do not present the trace as a success rate.
- [x] `integrations/tiiny/README.md`, `integrations/tiiny/tests/README.md`, `integrations/tiiny/WORKSPACE_ASSISTANT.md`, the plan table, and `STATUS.md` describe plans as serial, bounded, dependency-aware trees with leaf health and editable retry, and note that approvals can pause a task.

## Design constraints and decisions

- **One queue, one lane.** Plans are ordered work, not concurrent work. This deliberately extends story 02's "no dependency graphs" constraint by persisting plan edges, eligibility, and ordering; it does not add a scheduler that can preempt, prioritize, or run lanes in parallel. The only ordering change is that blocked jobs are passed over until eligible.
- **Blocked branch, not global pause.** A failed leaf stops only its dependents. Independent siblings and unrelated jobs continue, which is the point of leaf health. Cached results are context, not isolation: another branch may change the workspace, so retries mark recorded scene state for revalidation.
- **Deferral is not reordering.** An ineligible job keeps its position; the executor selects the next eligible job in sequence order. Nothing jumps ahead of a queued job, and no job is moved or reprioritized.
- **No cost-based planning.** The model declares tasks; the executor validates and orders them. Do not estimate token cost, score candidate plans, or reorder for throughput.
- **Deferred join, not blocked jobs.** No queued job waits for another while holding the slot. The join simply does not exist until the plan resolves. Cancelling a plan must persist a plan-cancelled marker that the join scan honors, cancel the plan's queued/running tasks, and append a terminal cancellation step answering the plan call. A later scan must not resurrect a normal join, and the conversation must not be left with an orphan call.
- **Plan edges, not container jobs.** A node that submits a plan is a normal `chat_turn`. Do not add a second job type.
- **Leaf health is authoritative.** A coordinator's job state describes coordination, not the work of its children. Surface per-leaf outcomes; never collapse them into one success claim.
- **Planner guidance is proposed, not autonomous.** The coordinator may draft the repair, but the user confirms Retry or Skip. Do not build a self-retry loop on failure; a small model repeating a bad plan is the failure mode to avoid.
- **Guidance cannot escalate.** The planner's revised instruction is still user-level content: it cannot grant tools, bypass approvals, weaken validation, or change tool mode. Its intervention tools are limited to `revise_task` and `skip_task`.
- **Reuse means recorded context, not replay.** The prior-attempt block is data for the model. Do not re-execute completed calls, re-import existing artifacts, or synthesize idempotency the tools do not have.
- **Interrupted is not retryable.** Unknown device outcomes require acknowledgement or skip through the existing safety path. Do not turn an uncertain remote effect into an edit-and-retry dialog.
- **No authority escalation.** Children inherit approval rules; user-edited retry instructions cannot grant tools, bypass approvals, or weaken validation.
- **Same model, revalidated.** Children use the configured coding model at dispatch. Specialized models remain reachable through `generate_image`, `asset_generate`, `model_schedule`, and their leases.
- **Context is chosen, not inherited.** The parent supplies briefs and excerpts. Do not copy the parent transcript into a child.
- **No tool filtering per child.** Children get the same registry and mode; only the two terminal tools are scoped by role.

## Open questions

1. **Revise vs replace.** The coordinator can currently revise or skip one task. A deeper failure might call for splitting the task or changing dependencies, which would mean replacing part of the plan. Recommendation: ship single-task revision first and add plan replacement only if traces show failures that one instruction cannot fix.
2. **Task count for small models.** Three tasks per plan is conservative. Raise or lower only with live evidence.
3. **Declared independence.** The model asserts independence by omitting dependency edges. If independent siblings touch the same node or file, one can invalidate the other; tool validation will report a conflict and that becomes another intervention. Recommendation: trust declared edges in v1, record conflicts, and consider planner guidance about overlapping targets later.
4. **Dependency-result size.** Injecting a dependency's full record may crowd a small context. Recommendation: inject summary, changes, and verification only, with job IDs for detail.
5. **Attempt cap.** Three attempts is a guess. It should be a constant with a test; revisit after real failures.
6. **Root wall-clock budget.** Caps bound the tree, but 8 tasks at up to 12 requests each is still a long unattended run, and intervention can pause it indefinitely. Recommendation: omit a root deadline for v1; revisit with traces.
7. **Manual edits during intervention.** The user may edit the scene while the dialog is open. The retry will revalidate and may report a stale or conflicting target. Recommendation: accept and report it; do not lock the editor.

## Verification and handoff

Follow [TESTING.md](../TESTING.md). Extend `check_builtin_jobs.py` with `plan_*` modes for validation, ordering, deferred join, dependency skip, rollup, contained failure, intervention, retry reuse, attempt cap, cancel, and restart. Reuse the restart fixtures for both boundaries: append and join. Run `check_workspace_tools.py`, `check_workspace_transactions.py`, `check_debugger.py`, and `check_model_configuration.py --editor-smoke`. Announce and run an incremental `scons platform=linuxbsd target=editor use_static_cpp=no -j8` build before editor fixtures. The live trace requires the real Tiiny and the configured coding model; record the exact plan, attempts, edited instructions, per-task timings and outcomes, and the final rollup.
