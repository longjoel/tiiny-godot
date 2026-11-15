# 02 — Persistent FIFO job queue

Status: In progress; story 01 baseline accepted. Acceptance remains pending.

Feature: Persistent FIFO jobs and execution visibility

Sequence: 02

Stream: `integration` (with Jobs UI)

Dependencies: 01

## Scope

Provide one persistent, append-only queue inside Godot. Users, the assistant, and supported worker scripts may append jobs. Run one job at a time in the order the manager accepts them. A job finishes only after its declared outputs and required import/application are validated. The next job then starts.

Example: append `create_tree`, then append `attach_tree_to_scene`, with an explicit artifact reference passed between them. There are no dependency graphs, priority reordering, parallel worker lanes, or parent/child scheduling in this version. Scripts may append jobs at the tail but must not wait for them while holding the current job. An appended job does not jump ahead of already queued work.

## Acceptance criteria

- [x] A user, assistant tool, or supported script can append a validated job; the manager assigns a stable ID and durable queue position before acknowledging it.
- [x] Exactly one job runs at a time, strictly in accepted order. Concurrent append requests are serialized; execution never relies on timing or hope.
- [x] `create_tree` finishes output validation/import before `attach_tree_to_scene` starts. The attachment uses an explicit artifact reference and revalidates its target scene.
- [x] Failure, interrupted execution, or cancellation of the current job stops dispatch. Later jobs remain queued until the user explicitly resolves the stopped job and resumes; no missing result is silently substituted.
- [x] Pause stops new dispatch without undoing completed work. Retry reruns the stopped queue position as a new attempt before later jobs. Explicitly skipping a job records that decision; subsequent jobs still validate their inputs.
- [x] Queue order, job parameters, attempts, results, and stop/pause state survive restart. Unknown worker outcomes are reconciled before anything else starts; completed effects are not blindly replayed.
- [x] Jobs have isolated working files, declared artifact outputs, time/output limits, and retained diagnostics. Validate output paths/formats and target revisions before import or application; do not overwrite unrelated content.
- [x] The Jobs bottom panel shows accepted order, current stage, elapsed time, stop reason, logs, and outputs. No fabricated percent or ETA; editor stays responsive.
- [x] Fake-worker tests verify FIFO order, append-during-run, failure stopping, pause/resume, retry, skipped missing inputs, restart recovery, and no duplicate promotion. A reviewed headless Godot fixture produces a usable asset.
- [ ] Tiiny execution uses the shared device interface without deliberately unloading the coding model. Advanced model scheduling and arbitrary untrusted generator execution remain later work.

## Implementation plan and visuals

Follow [the implementation plan](../implementation/02-job-manager.md), [FIFO diagrams](../mockups/02-job-manager-diagrams.md), and [Jobs mockup](../mockups/02-jobs-panel.html). The initial standalone queue core is under development; acceptance remains pending.

## Evidence and handoff

JOB-01 through JOB-06 are verified (see STATUS.md entries: `check_job_process.py` lock/recovery, `check_editor_tree.py` publication/import, `check_builtin_jobs.py` create/restore, and four headless fixtures at 0 failures). Criterion 10 (Tiiny device coordination) is deferred per the work item. See [STATUS.md](../STATUS.md) for the full verification log.
