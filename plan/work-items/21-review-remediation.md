# 21 — Address post-story-20 review

Status: Complete. The review findings are addressed with deterministic, editor, and live evidence; the remaining boundaries are recorded in the criteria and STATUS.

Dependencies: 02, 18, 20. The user explicitly redirected work to address the review findings.

## Acceptance criteria

- [x] File creation rejects a parent replaced with a symlink during approval; both creation routes have focused tests. Record the remaining final-syscall race honestly.
- [x] Workspace write, patch, move, and delete protect unsaved script-editor buffers, including changes made during approval. Verify using a real editor buffer and check disk and buffer preservation.
- [x] Continuation handoff survives a crash at every persistence boundary without duplicate continuations or unintended replay. Verify with a deterministic restart interleaving and failure/cancellation cases. The restart fixture models the queue state before and after its single atomic store commit; it does not simulate power failure within the native filesystem call.
- [x] Image generation, headless execution and shell execution invoked from chat have independent queued job lifecycles and budgets, return their actual results to the resumed turn, and preserve FIFO and recovery guarantees. Image jobs also load and restore their model under the job's device lease. Headless and shell jobs are pre-approved at the tool call, revalidate the setting and approval digest at dispatch, and record the owned process id for recovery.
- [x] Evaluate representative live model tool selection and composition and the composed image-to-3D and multi-round paths where device access permits; record exact results and distinguish untested cases rather than implying catalog support is a live success rate. Live Qwen3.6 traces passed for workspace file edit, hybrid typed scene edit, and a two-task planned turn; the image-to-3D device path was not rerun here and retains its story 13 evidence.
- [x] Reconcile current coverage, device scheduling and related product documentation; update integration README and STATUS with verification and remaining limitations.

## Remaining implementation constraints

The long-tool slice must preserve every call in a multi-call model response and its ordered tool results. Persist the remaining calls and turn state before leaving a chat step; use an atomic parent/successor handoff for each boundary. A long-tool job must carry its own timeout and report the actual structured result back into the matching tool-call message before any next model request. Revalidate tool mode, settings and approval at execution time. Do not replay host commands or device operations automatically after an interrupted outcome; recover or explicitly abandon them. Cancellation must stop owned processes or requests and prevent later steps from dispatching until the outcome is resolved.

Image generation now performs its model scheduling and configured-warm-set restoration under the image job's device lease and journal, including the uncertain-restoration path. Host shell jobs are pre-approved once, revalidate the approval digest and `allow_shell_commands` at dispatch, and record the owned process id on the attempt. A process that outlives an interrupted editor is never killed or retried automatically: the job becomes `interrupted`, the details show the recorded pid, and skipping resumes the turn with `outcome_unknown`. FIFO remains strict: no nested job may wait for another job while holding the worker slot.
