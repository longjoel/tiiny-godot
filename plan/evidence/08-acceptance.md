# Story 08 — acceptance evidence

Story 08 is accepted. Chat now renders structured action cards from the story 07 ledger instead of model prose, with navigation, guarded scene undo, retry for failed synchronous tools, file-change labeling, queued-job links, and bounded card history.

Executable: `bin/godot.linuxbsd.editor.x86_64`, version `4.8.beta.custom_build.fe5ab2a84`. No build or test remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Meaningful queued/running/completed/failed actions with affected targets | `_append_action_card` renders status, tool, summary, and affected nodes/resources/jobs. `action_cards_state()` exposes deterministic state. The transaction fixture checks Completed + Failed cards and their affected nodes. |
| Inspect proposed changes and navigate to results | Node cards have **Select**, which opens the recorded scene if needed, resolves the scene-relative path, selects, and calls `EditorInterface.edit_node`. Resource cards use `edit_resource` when saved; embedded resources fall back to their owner node. Job cards open the Jobs details dialog. The fixture presses Select and verifies the created shape becomes the selection. |
| Undo matches Godot support | Transaction results carry `data.action_name`; cards show **Undo** only with an undo group. `_undo_action` checks the scene history’s current action name before undoing, so it never undoes an unrelated newer action. File tool cards show `File change · not scene-undoable` and no Undo button. The fixture presses Undo and verifies the shape is removed. |
| Long operations responsive; cancellation explains what stopped/completed | Job acceptance cards show Queued/Running and link to Jobs; acceptance is never displayed as completion. Failed synchronous cards show the error. Protocol/empty-response stops preserve completed ledger summaries and release the device lease (story 07 fix). |
| Failed step reports partial work and recovery path | Failed action cards show the error and a **Retry** button. Retry revalidates against current scene context and appends a new card. The fixture verifies the failed unknown-tool card has Retry. |
| Small editor window and running scene | The transaction fixture resizes the chat to 320×600 and verifies the card fits; it starts a separate running scene, confirms the chat history/cards remain visible, then stops it. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Transaction/registry/chat/action-card fixture | Passed, including Select, Undo, Retry, file note, 320px layout, running scene | `/tmp/transactions-08d.log` |
| Existing editor smoke + restart stages | Passed, 11/11 stages | `/tmp/tiiny-story08-regression.json` |
| Built-in Jobs suite | Passed, all 27 modes | `/tmp/jobs-08.log` |

## Remaining boundaries

- Retry is only for failed synchronous tool results; interrupted device work must be reviewed/abandoned in Jobs.
- Undo does not search backwards through history; if another action is newer, the card directs the user to Godot’s history instead of undoing an unrelated action.
- Job progress remains in the Jobs panel; chat shows accepted/current state and a link, not a duplicate progress engine.
- No displayed screenshot capture was added in this slice; layout is checked at 320×600 in the editor fixture.
