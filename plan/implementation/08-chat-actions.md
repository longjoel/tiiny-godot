# Story 08 implementation plan — chat action history, previews, and recovery

Status: Accepted. Action cards, navigation, guarded undo, retry, file-change labeling, 320px layout, and running-scene checks are implemented. See [acceptance evidence](../evidence/08-acceptance.md).

Parent: [08 — Chat action history, previews, and recovery](../work-items/08-ui-chat-actions.md).

## Execution contract

The chat dock is the presenter. The story 07 turn ledger and structured tool results are the source of truth for what happened. The dock must not infer success from model prose or parse arbitrary status strings.

Every tool result in an active turn becomes one compact action card in the chat transcript. Cards expose status, summary, affected targets, undo availability, and recovery actions. Long-running jobs remain represented by the shared Jobs service; chat only links to the accepted job record.

## Action card

A card is built from the structured result plus the original tool arguments:

```json
{
  "call_id": "call_1",
  "tool": "add_rectangular_collision_shape",
  "ok": true,
  "summary": "Added CollisionShape2D under Player with an owned 32×48 RectangleShape2D.",
  "affected": [{"kind": "node", "scene_path": "res://player.tscn", "path": "Player/CollisionShape2D"}],
  "undo_group": "tiiny:turn-7:call-1",
  "data": {"action_name": "Add CollisionShape2D (32×48)", "scene": {"path": "res://player.tscn"}},
  "error": null
}
```

Card fields:

- Status chip: `Queued`, `Running`, `Completed`, `Failed`, `Cancelled`, `Interrupted`, or `Unknown outcome`.
- Summary/error text.
- Affected lines with scene-relative node paths or resource references.
- `Select` for scene nodes, `Open` for saved resources, `Show job` for accepted job IDs.
- `Undo` only when the result has an undo group and the editor history's current action matches the recorded action name.
- `Retry` only for a failed synchronous tool result; it revalidates against the current scene. It is not offered for uncertain/device-interrupted work.
- File creation and other filesystem actions are labeled `File change` with no scene `Undo` button.

Cards are bounded; the transcript keeps the newest 100 action cards. Full result JSON remains available in the turn ledger and copied tool content.

## Navigation

- Node target: open the recorded scene if it is not current, resolve the scene-relative path, select it, and call `EditorInterface.edit_node(node)`. A missing node reports that the target no longer exists; no substitution.
- Saved resource target: load and call `EditorInterface.edit_resource(resource)`.
- Embedded resource target: select its owning scene node when known; otherwise show the resource class/path text.
- Job target: open the job details dialog through a public Jobs-service method.

Navigation is read-only and never changes the scene or saves files.

## Undo semantics

- Transactions add `action_name` to their result data.
- The `Undo` button resolves the edited scene's undo history and checks `get_current_action_name()` against the recorded name.
- If another action is newer, the button reports that Godot's history is not at the recorded action and directs the user to the editor history; it does not undo an unrelated action.
- `create_gdscript`, `generate_image`, and job acceptance have no scene undo group and never show a scene `Undo` button.

## Long operations and failure

- `append_job`/`get_job_status` results carry job IDs and state in structured data; the card links to the Jobs details dialog.
- Queue acceptance is shown as `Queued`, never as completion.
- A failed synchronous tool shows its error and a bounded `Retry` path.
- An interrupted/uncertain job shows that the remote outcome requires review and links to Jobs; it does not offer blind retry.
- Cancellation keeps completed cards and marks the stopped action/status; partial work remains visible.

## Slices

### Slice A — card model and rendering

Add `_append_action_card(result, arguments)` and bounded card storage. Render status, summary, affected lines, and the existing summary in `history_text()`. Add a deterministic accessor for tests (`action_cards_state()`), with no model/device dependency.

### Slice B — navigation and undo

Add scene-node selection, saved/embedded resource handling, job details navigation, transaction `action_name`, and guarded undo. Verify file operations never show scene undo.

### Slice C — retry, cancellation, and layout

Add retry for failed synchronous tools; preserve completed cards after cancellation; show queued/running job state; test small dock width and a running scene. Verify cards remain readable and controls reachable.

### Slice D — verification/handoff

Run the fake-chat/registry fixture, the transaction fixture, the Jobs suite, editor smoke, and a displayed dock capture at a small width while a scene runs. Record unsupported recovery paths honestly.

## Gates

- No card claims completion from queue acceptance or model prose.
- Node/resource/job navigation targets the recorded object and reports missing/stale targets.
- Undo is shown only when the editor history can actually undo that action.
- File creation is visibly non-scene-undoable.
- Failed steps show partial work plus a usable retry/recovery path.
- Small-window and running-scene checks pass.

## Handoff

Accepted. See [acceptance evidence](../evidence/08-acceptance.md). Remaining limitations: retry only for failed synchronous tools; guarded undo does not search backwards through history; job progress remains in Jobs.
