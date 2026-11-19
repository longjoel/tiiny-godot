# Story 33 implementation plan — plan document, execution, and writeback

Status: Design under review. No code has been written.

Parent: [33 — Reviewable game plan document and job execution](../work-items/33-plan-document.md).

## Decision

Use a strict YAML subset implemented in GDScript, not a general YAML API in the engine core. Plan documents are small, editor-owned artifacts. The parser can fail closed on the YAML features we do not need, and the writer can emit deterministic, valid YAML for review and external tooling.

If the document needs JSON import/export later, the parsed value is an ordinary Godot `Dictionary`, so that is a serializer addition rather than a format rewrite.

## Modules

- `editor/tiiny/plan/plan_yaml.gd` — parser and canonical writer for the subset.
- `editor/tiiny/plan/plan_document.gd` — schema, defaults, validation, task graph, status/evidence helpers.
- `editor/tiiny/plan/plan_store.gd` — load/save, SHA-256 conflict checks, atomic writes, run reconciliation.
- Plan tool handlers in the dock, or a small provider invoked by the dock, for create/read/update/validate/run.
- `integrations/tiiny/tests/test_plan_document.gd` — pure parser/validator/store tests.
- Editor/Jobs fixture coverage for compile → child jobs → join → evidence writeback.

## YAML subset

Supported:

- block mappings and sequences with spaces;
- quoted and plain scalars;
- `|` literal and `>` folded block text;
- comments and blank lines;
- UTF-8, with bounded string and document sizes.

Rejected with line-specific errors:

- tabs for indentation;
- duplicate mapping keys;
- anchors (`&`), aliases (`*`), tags (`!`), directives (`%`), merge keys (`<<`);
- multiple `---` documents;
- flow collections unless needed later;
- unquoted values that are ambiguous booleans, numbers, or nulls beyond the schema’s expectations when they could change meaning;
- unknown fields when validating the plan schema.

Writer:

- emits block style, two-space indentation, stable field order, and minimal quoting;
- does not preserve comments;
- writes a trailing newline;
- round-trips the parsed value and produces identical bytes for the same data.

Comments are for transient review. Durable annotations belong in `notes`.

## Schema v1

Top level:

```text
schema: int (must be 1)
id: string (1-64, [A-Za-z0-9_-])
title: string (1-120)
status: draft | ready | running | done | blocked
scene: optional res:// path
notes: optional bounded string
game: optional bounded mapping (summary, viewport, controls, win, lose)
questions: list (max 20)
tasks: list (max 8)
```

Question:

```text
id: 1-32, unique
prompt: 1-2000
answer: optional 0-4000
blocking: bool (default true)
```

Task:

```text
id: 1-32, unique
title: 1-120
status: todo | done | blocked | skipped
depends_on: list of task IDs (max 8)
brief: 1-4000
files: optional list of res:// paths (max 20)
done_when: list of checks (max 10)
evidence: list (max 50)
notes: optional
```

Check:

```text
id: 1-64, unique within the task
check: runtime | tool | user
detail: 1-512
```

Evidence:

```text
check: matching check ID
result: passed | failed | skipped
source: runtime | tool | user | task
detail: optional 1-512
at: ISO-8601 timestamp
job_id: optional
```

Status rules:

- `done` requires a passed evidence entry for every `done_when` check from `runtime`, `tool`, or `user`; `task` claims are recorded but do not complete a task.
- A task with no `done_when` checks requires one explicit `user` evidence entry to become `done`.
- A task with failed evidence stays `todo` or becomes `blocked` with a recorded reason.
- A dependency is satisfied only by a `done` dependency. `skipped` or `blocked` dependents are blocked or skipped; they never run with missing inputs.
- Independent tasks remain eligible and are not affected by another task’s failure.

## Validation

Before any run:

- schema version and known fields;
- bounded sizes and list lengths;
- unique document/task/check IDs;
- dependency references exist, no self-dependency, no cycles;
- task count at most 8;
- `res://` path shape for `scene` and `files`;
- status and evidence consistency;
- all `blocking: true` questions answered;
- no active run for the same document.

Validation returns a report with:

- `valid`;
- `errors[]` with field paths and lines;
- `eligible[]` and `blocked[]` task IDs;
- `unverified[]` checks that lack non-claimed evidence.

## Tools

- `plan_read` — read a plan document; returns the canonical text and parsed summary.
- `plan_create` — create a new `res://plans/<id>.plan.yaml`; approval-gated.
- `plan_update` — bounded field/task patch with the current SHA-256; approval-gated. Reject stale hashes.
- `plan_validate` — read-only validation and eligibility report.
- `plan_run` — validate, refuse unanswered blocking questions, require run approval, and compile tasks into jobs.

The model edits structured plan fields; it does not have to emit raw YAML. The user may edit the file directly in the editor.

## Execution

`plan_run` constructs the same plan record that `submit_plan` produces today and hands it to the existing `finish_with_plan` path. No new scheduler.

The coordinator and child job parameters carry:

```text
plan_doc_path
plan_doc_hash
plan_run_id
plan_task_id (children)
plan_doc_version (schema)
```

Child tasks keep `plan_root`, `parent_job`, `depends_on`, `attempt`, `depth`, and the task brief compiled from the document. The brief includes the task’s requirements, files, and `done_when` checks. Dependency results are injected at dispatch as they are today.

The join is appended by `commit_ready_joins` exactly as it is today. Its parameters carry the plan document metadata so writeback can find the document and run.

## Evidence provenance

A task’s `submit_result.verification` is a claim, not proof. At join time:

- Extend join outcomes with tool evidence extracted from each child job’s ledger/result.
- A `verify_scene_runtime` result with a named check and `passed: true` becomes `source: runtime`.
- A successful file/tool operation that directly proves a check becomes `source: tool`.
- `submit_result.verification` entries become `source: task` and never mark a task `done` by themselves.
- A user may explicitly record `source: user` evidence in the document.

This keeps “done” aligned with the repository’s existing evidence rule.

## Writeback

At join completion:

1. Load the document.
2. Compare its SHA-256 with `plan_doc_hash`.
3. If it changed, do not write. Return a `plan_conflict` result with the current hash and a bounded patch/diff suggestion. The run’s outcomes remain in the job record.
4. If it matches, append evidence, update task statuses, roll up the document status, and write atomically.
5. Record `plan_run_id` and the join job ID in the document run history or as a bounded note.

Recovery: mark the join result with `plan_writeback: pending` before writing. On startup, reconcile completed joins whose writeback is pending. Reapplication is idempotent by `plan_run_id` + check + job ID. A changed document becomes a conflict, not an overwrite.

One run per document: `plan_run` rejects a document that already has an active run, using persisted queue records rather than in-memory state.

## Questions

Questions live in the document. The model can create or update them with `plan_update`; the user answers in the file or in chat. A blocking unanswered question prevents `plan_run`. The card UI and an `ask_user` tool are story 34; the document contract is ready for them.

## Limits and non-goals

- No general YAML class, anchors, aliases, tags, or merge keys.
- No arbitrary operations, scripts, or scene serialization in the document.
- No parallel tasks or new queue.
- No mid-task questions in this story.
- No more than 8 tasks in version 1; phases are a later extension.
- The document is not scene-undoable; edits are project files with hash checks and approval.

## Test plan

Pure:

- Round-trip a full sample document.
- Deterministic writer output.
- Block scalars, quoting, Unicode, comments.
- Reject tabs, duplicate keys, anchors, aliases, tags, multi-document input, unknown fields, oversized documents, invalid UTF-8.
- Validator: unknown fields, duplicate IDs, missing/self/cyclic dependencies, task cap, invalid statuses/evidence, `res://` paths, unanswered blocking questions.
- Eligibility: independent tasks remain eligible while a dependency blocks another.
- Status: `task` evidence does not complete a check; `runtime`/`tool`/`user` can.

Editor/Jobs:

- Create a document, validate, run; verify no jobs before Run.
- Two or three tasks with a dependency; child jobs run, dependency result injected, join once.
- Independent task completes while a dependent task waits.
- Overclaim: `submit_result` claims a check with no tool evidence; task ends `unverified`.
- A real `verify_scene_runtime` pass becomes `runtime` evidence and completes the check.
- User edits during the run produce `plan_conflict`; no overwrite.
- Crash between join and writeback recovers once, without duplicate evidence.
- A second run of the same document is rejected while one is active.

## Risks

- A YAML subset can surprise users; the wizard must validate on edit and explain rejected syntax.
- Comments may be lost on write; use `notes`.
- Model-generated raw YAML is unreliable; keep the model on structured plan tools and reserve raw text for the user.
- Writeback conflicts are likely if the user edits during a run; the conflict path must be visible and non-destructive.
- Evidence provenance is the main trust boundary; do not let `task` claims mark work done.
- Eight tasks may be too small for a full game; keep the document useful for a vertical slice and add phases deliberately.
