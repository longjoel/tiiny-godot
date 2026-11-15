# Story 02 implementation plan — persistent FIFO queue

Status: In progress; story 01 accepted. 9 of 10 story 02 acceptance criteria verified; remaining: displayed editor and Tiiny device coordination.

Parent: [story 02](../work-items/02-integration-job-manager.md). Visuals: [Jobs mockup](../mockups/02-jobs-panel.html), [diagrams](../mockups/02-job-manager-diagrams.md).

## Execution contract

The only submission operation is append. The manager durably assigns an ID and queue sequence before acknowledgment. It runs one job at a time in accepted order. A job includes a supported operation or generator, validated parameters, explicit input artifacts, intended outputs/targets, budgets, and execution history.

Append `create_tree`, then append `attach_tree_to_scene` using the first job's artifact ID. Tree generation includes validating and importing its output before completing. Attachment revalidates the target scene and referenced result. A failed tree stops the queue before attachment.

Users, the assistant, and supported scripts use the same append interface. Appends made during execution go to the tail, after all accepted work. Scripts cannot insert ahead, reorder, execute children immediately, or wait for appended work to complete. Bind target scenes and artifacts explicitly; do not interpret “the current scene” or “the last generated asset” again later.

No graph scheduler, priorities, independent worker lanes, or concurrent execution belongs in this story. Pause and stop are queue-wide controls; they are not alternative submission operations.

## Slice A — durable queue and attempts

Create native editor-owned queue/store components under `editor/tiiny/jobs/`, confirming actual integration APIs during implementation. Persist schema version, project identity, stable IDs, accepted sequence, submission key, operation/version, parameters, input/output references, budgets, state, timestamps, attempts, logs and artifacts. Serialize appends and state writes. Deduplicate identical submission keys, not merely similar requests.

Validate submission before acceptance; reject unsupported operations and invalid paths/parameters. Persist transitions using atomic replacement and a promotion journal. Corrupt records must be visible and must prevent automatic dispatch. Keep durable records separate from disposable working cache; verify import/ignore behavior before choosing `.tiiny/jobs/` and `.godot/tiiny/asset_jobs/` respectively.

Gate: store round-trip, concurrent append ordering, duplicate submission, invalid request, corrupt-record and interrupted-write tests.

## Slice B — serial executor with fake workers

Use one global execution slot and a supported worker interface (start/poll/cancel/reconcile), backed first by deterministic fake workers. Job states: queued, running, completed, failed, cancelled, interrupted. Queue states distinguish running, paused and stopped-with-reason.

Dispatch the head only. A completed job includes validated output/import/application, not just process exit. Failure or cancellation of the head stops dispatch. Pause lets the current job finish but prevents starting the next. Retry creates another attempt at the stopped position; skip records an explicit decision before moving on. Later jobs must still validate inputs, so skipping a tree cannot make its missing artifact valid.

Gate: strict FIFO, append-during-run, no overlap, failure stop, pause, retry, skip and cancellation tests with an injectable clock.

## Slice C — real generator and safe completion

Run a reviewed fixture generator with a compatible headless Godot executable in a disposable worker project. Capture asynchronous logs, process/attempt identity, time/output budgets and declared results. A separate process is crash isolation, not a filesystem sandbox. Arbitrary AI-authored scripts remain unavailable until an explicit filesystem/execution policy is implemented.

Validate staging paths including symlinks, sizes, formats and Godot loadability. Use explicit artifact IDs and hashes. Reserve output destinations, recheck target scene revisions, and record publication/import progress. Do not overwrite unrelated content. Handle multi-file promotion through a recovery journal rather than claiming it is atomic. Editor scene operations later use undo/redo where supported; cancellation does not undo published assets.

All device operations share the same Tiiny interface/lease as existing chat/setup; the queue cannot race external-to-queue editor device work. Reject unsupported transitions; full model swapping remains story 10.

Gate: real headless fixture generation/import plus timeout, crash, malformed output, missing input, stale target and destination-conflict checks.

## Slice D — UI and append tools

Add Jobs to the editor bottom panel; keep settings in Tiiny AI and chat in its side dock. Show ordered jobs, running stage, elapsed time, attempts, artifacts, logs, and stop reason. Provide append, pause/resume, cancel current, retry stopped and explicit skip controls. Enable controls only when their semantics apply. No priorities, drag reordering, graph view, or parallel-lane displays.

Expose `append_job` and `get_job_status` tools. Return IDs/positions immediately so chat remains usable. A reviewed generator accesses the same append service through a bounded worker bridge or recorded append-request protocol; validate every request and acknowledge persistence before considering it submitted. Bound total submissions to prevent accidental infinite append loops.

Gate: user, fake assistant, and reviewed worker append through the same validator; UI remains responsive and displays accepted order faithfully.

## Slice E — restart, retry and retention

Restore queue and paused/stopped state on startup. A recorded running job becomes interrupted until its real worker/device/output state is reconciled. Never blindly repeat inference, scene edits or file publication. Unsupported task reconciliation leaves the queue stopped for an explicit decision. Protect against two editor instances owning the same project queue.

Retain useful failed outputs and logs; retries revalidate reused artifacts against recipe/version/hash. Cleanup removes only manager-owned working files and follows explicit retention rules. Missing cache does not erase queue history or imply success. Check final device warm state when hardware tests change it.

Gate: JOB-01 through JOB-06 pass, including controlled restarts around publication/import boundaries and retry without duplicate final assets.

## Handoff

Record checks against every parent acceptance criterion, exact binary/configuration, storage decisions, supported operations, restrictions, and remaining blockers. Story 01 is accepted; story 02 acceptance remains pending.
