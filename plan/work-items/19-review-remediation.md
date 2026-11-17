# 19 — Review findings and acceptance reconciliation

Status: Accepted

Feature: Resolve the review findings for stories 13, 15, 16, and 18

Sequence: 19

Stream: `integration`

Dependencies: 13, 15, 16, 18

## Scope

Verify and resolve the findings from the review of story 10 onward. Reproduce each finding against the then-current code before changing it: story 18 has since been accepted and some findings may already have been resolved by its implementation. Record the reproduction, fix or contrary evidence, and focused verification for each finding.

### Workspace execution and file safety

- Close the headless-execution approval bypass: project scripts and other Godot arguments capable of executing host code must be subject to an explicit, accurately described authorization policy. A flag allowlist alone does not confine project code. Preserve useful headless checks while making the distinction and its limitations clear.
- Check dirty state for the actual target across all open scene tabs before file edits and reloads. Never silently discard unsaved scene state; an explicit discard must be an informed user decision, not merely a model-supplied flag.
- Make hash-guarded writes, patches, moves, and deletes reject conflicting changes through commit, including changes while an approval dialog is open. Ensure create and move destinations cannot overwrite a file that appears concurrently. Document any platform or filesystem limitations instead of claiming stronger guarantees than the implementation provides.
- Apply the same explicit creation approval policy to every file-creation route, including `write_file(create: true)`.
- Prevent git inspection from exposing denied credential paths or credential content, including unfiltered and staged diffs. Define and test the policy for other git output and redaction limits.

### Reconcile accepted-story evidence

- Story 13: implement and test the image-generation-to-3D composition using a validated producer artifact, preserving usable intermediate output on downstream failure; or, if the original criterion cannot be met, explicitly revise the scope and acceptance state rather than treating a pre-existing image as proof of the composed workflow.
- Story 15: provide and test a create-and-attach workflow that meets the no-partial-state-on-validation-failure criterion and reports file and scene effects honestly, including the specified invalid and undo/save boundaries; or explicitly revise the scope and acceptance state if the criterion cannot be met.
- Story 16: establish task-specific passing evidence for every task marked supported, with a traceable mapping from task to executed test and result. The catalog validator's existence check alone is not proof that a test covers a task or passes. Correct classifications and coverage claims where evidence is absent.

## Acceptance criteria

- [x] Every review finding has a recorded disposition, current-code evidence, and a focused verification result; any unresolved issue remains explicitly open.
- [x] Headless script execution cannot bypass the chosen host-code authorization policy. Tests cover approved and denied script execution, as well as disabled and denied invocations using `--quit`, `--import`, and `--check-only`; all validated argument combinations pass through the same setting and approval gate.
- [x] Tests cover dirty current and non-current scene tabs for writes, moves, deletes, and reloads, including explicit save/discard decisions and preservation of unsaved state. The real-editor workspace fixture exercises both tabs, denied discard, save, and approved discard followed by reload of saved contents.
- [x] Deterministic concurrent-edit tests cover write, patch, create, move, and delete, including changes during approval and a destination appearing before commit. Conflicts leave the intervening change intact.
- [x] All creation entry points enforce the same explicit approval policy, with tests for denial and approval.
- [x] Git status, diff, and log comply with a documented credential and denied-path policy; tests include staged and unstaged changes and unfiltered output. Any residual redaction limits are stated accurately.
- [x] Story 13's composed producer-to-consumer workflow and failure/intermediate preservation have passing evidence: the FIFO fixture uses controlled Tiiny responses to generate/import an image, fail downstream, retry, and import a GLB without regenerating the image. The composed path has not been device-tested.
- [x] Story 15's create-and-attach validation, failure effects, ownership/instance boundaries, undo, and save/reload have passing editor-fixture evidence. File creation remains outside scene undo; a failure after creation reports the remaining file.
- [x] Every supported catalog task maps to a specific passing test and recorded run; classifications and reports do not equate a test-file reference with a passing task test.
- [x] Update the relevant work items, acceptance evidence, catalog, integration README where user-visible behavior changes, and STATUS. Distinguish deterministic, editor, live-model, and device evidence; do not claim unrun checks.

## Verification and handoff

Use focused deterministic and editor fixtures first, with reproducible interleavings for concurrency. Run device or live-model checks only where necessary to substantiate the specific claim, and record their boundaries. Follow [TESTING.md](../TESTING.md).
