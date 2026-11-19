# 33 — Reviewable game plan document and job execution

Status: Design under review. Format, validation, execution, and writeback are scoped; implementation has not started.

Feature: A versioned plan document that describes a game and its reviewable tasks, validates before dispatch, compiles those tasks into the existing job sequence, and records evidence and status back into the document.

Sequence: 33

Stream: `integration`

Dependencies: 02, 20, 23, 31, 32. Reuses the FIFO queue, the plan coordinator/child/join sequence, and the task protocol. It adds no parallel lane, priority, or second scheduler.

Implementation: [plan](../implementation/33-plan-document.md).

## Why

`submit_plan` is a one-shot tool call: the model decides the whole 1–3 task breakdown before the user sees it, and the tasks queue immediately. There is no draft, no way to review the plan as a document, no place to record questions and answers, and no durable statement of what “done” means for each task. Failed tasks can be fixed afterward, but the plan itself cannot be reviewed or edited before work starts.

A plan document fixes that. It is the reviewable artifact: the user can open it, see what is done and not done, see which tasks block which, answer open questions, and choose when to run it. The queue remains the execution engine; the document is the contract.

## Format

The document is a project file, `res://plans/<id>.plan.yaml`, using a strict YAML subset implemented in GDScript. The parser accepts mappings, sequences, quoted/unquoted scalars, literal/folded block text, and comments. It rejects tabs, duplicate keys, anchors, aliases, tags, directives, merge keys, multiple documents, unknown fields, oversized content, and invalid UTF-8. The writer emits deterministic, valid YAML.

Comments are accepted for review but are not preserved by the canonical writer. Durable notes belong in `notes` fields.

```yaml
schema: 1
id: infinite-joust
title: Infinite Joust
status: draft
scene: res://infinite_joust.tscn
notes: Vertical slice first; combat after the movement loop is verified.

game:
  summary: A side-scrolling joust with moving platforms.
  viewport: [1152, 648]
  controls:
    left: ui_left
    right: ui_right
    flap: ui_accept
    dive: ui_down

questions:
  - id: lose_condition
    prompt: Should falling off the screen end the run or respawn the player?
    answer: end the run
    blocking: true

tasks:
  - id: player
    title: Player flight
    status: todo
    depends_on: []
    brief: |
      Add a CharacterBody2D controller with gravity, left/right movement,
      and an upward flap on ui_accept.
    files: [res://player.gd]
    done_when:
      - id: moves_right
        check: runtime
        detail: x increases after ui_right
      - id: flaps
        check: runtime
        detail: y decreases after ui_accept while airborne
    evidence: []

  - id: platforms
    title: Moving platforms
    status: todo
    depends_on: [player]
    brief: |
      Add three platforms and a controller that reverses direction at the
      viewport edges.
    done_when:
      - id: platforms_move
        check: runtime
        detail: platform positions change over time
    evidence: []

  - id: enemies
    title: Enemy spawning
    status: todo
    depends_on: []
    brief: |
      Spawn enemies on a timer and remove them when defeated.
    done_when:
      - id: enemies_spawn
        check: runtime
        detail: enemy count increases within five seconds
    evidence: []
```

### Status and evidence

- Task `status` is `todo`, `done`, `blocked`, or `skipped`.
- `done` requires passing evidence for every `done_when` check. A model’s “completed” result without evidence is recorded as `unverified`, not done.
- An evidence entry records `check`, `result` (`passed`, `failed`, `skipped`), `source` (`runtime`, `tool`, `user`), `detail`, and time.
- `depends_on` is the only execution relationship. A task is eligible only when every dependency is `done`; dependent tasks are blocked, while independent tasks remain eligible.
- The review view can render `[x]` for done, `[ ]` for todo, and “blocked by …” for dependencies, while the YAML remains the source of truth.

## Scope

- **Schema v1:** `schema`, `id`, `title`, `status`, `scene`, `notes`, `game`, `questions`, `tasks`; bounded strings and lists.
- **Parser/writer:** `editor/tiiny/plan/plan_yaml.gd` (or equivalent), pure GDScript, no engine-core YAML API.
- **Validator:** unique task IDs, dependency references and cycles, task caps, status/evidence shapes, `res://` paths, known fields, unanswered blocking questions before a run.
- **Plan store:** load/save with SHA-256 conflict checks and atomic writes, using the workspace file provider where possible. Model edits require the existing approval path; the user may edit the file directly.
- **Plan tools:** create, read, update, validate, and run the document. The model edits through bounded plan fields, not by emitting raw YAML.
- **Execution:** `run_plan` validates, requires approval to queue work, and compiles the tasks into the existing coordinator → child jobs → deferred join sequence. Each child carries `plan_doc_path`, `plan_doc_hash`, and `plan_run_id`; dependencies use the existing eligibility rules.
- **Writeback:** at join completion, map structured `verification` entries to `done_when` checks, append evidence with the source, update task statuses, and update the document status. A hash mismatch during the run is a conflict: do not overwrite user edits; return the stale hash and a diff/patch suggestion. A completed run with no evidence stays `unverified`.
- **Questions:** stored in the document. A run refuses while any `blocking: true` question is unanswered. The model may add questions and stop; the user answers in chat or in the file. The wizard card UI is story 35.

## Out of scope

- The visual plan wizard, question cards, and edit/review UI (story 35).
- Mid-task questions; a blocked task plus **Fix task** remains the first mechanism.
- A general YAML class in `core/io` or a vendored YAML library.
- Executing arbitrary operations or scripts from the document. The model still uses typed Godot tools; the YAML describes intent, acceptance, and task order.
- More than one run of the same document at a time.
- Parallel tasks, priorities, or a new queue.

## Limits

- Version 1 allows at most **8 tasks per document/run**, matching the existing plan-tree cap and the small-model/focused-task design.
- Larger game plans are split into phases later; the document can grow only after phase selection exists.
- Depth stays 2; the device remains serial.

## Acceptance criteria

- [ ] A safe YAML subset parser/writer round-trips a valid plan document, emits deterministic valid YAML, and rejects tabs, duplicate keys, anchors, aliases, tags, multi-document input, unknown fields, and oversized input with line-specific errors.
- [ ] The validator rejects duplicate IDs, missing dependencies, self-dependencies, cycles, invalid statuses/evidence, invalid paths, unanswered blocking questions, and more than eight tasks.
- [ ] The validator reports eligible and blocked tasks from `depends_on`; independent tasks are not blocked by another task’s status.
- [ ] `run_plan` refuses an invalid document or unanswered blocking question and queues nothing.
- [ ] A valid run creates the coordinator, child task jobs, and deferred join through the existing plan mechanism; no job is queued before Run.
- [ ] Join results append evidence, set task statuses, and roll up the document status. A task claiming completion without evidence is marked `unverified`.
- [ ] User edits made during a run produce a conflict result, not an overwrite; the stale hash and a suggested patch are returned.
- [ ] A crash between join and writeback is recoverable without duplicating evidence.
- [ ] Pure parser/validator fixtures and an editor/Jobs execution fixture pass.
- [ ] Focused workspace, transaction, selection, runtime, smoke, and Jobs suites rerun; build recorded with no build left running.
- [ ] User-visible behavior and test-layer documentation are updated.

## Evidence

Pending implementation. Planned fixtures:

- `integrations/tiiny/tests/test_plan_document.gd` for parser, writer, validator, dependencies, statuses, evidence, and conflicts.
- Editor/Jobs fixture for draft → run → child jobs → join → writeback, including a dependent task and an independent task, an overclaim, a stale-hash conflict, and restart recovery.
