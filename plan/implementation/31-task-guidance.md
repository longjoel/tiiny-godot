# Story 31 implementation plan — bounded task guidance and read-only guard

Status: Implemented and covered by the editor fixture.

Parent: [31 — Bounded task guidance and read-only loop guard](../work-items/31-task-guidance.md).

## Trace

Task job, workspace mode, scene `run-and-jump.tscn` containing only a `Node2D`:

1. `list_files res://`
2. `read_project_file res://run-and-jump.tscn`
3. `list_files res://`
4. truncated-response retry
5. no edit, no `submit_result`

The scene had nothing to add logic to. The task should have returned `blocked`.

## Changes

### Editor context

In `_editor_context`:

```text
Scene: res://run-and-jump.tscn (Node2D)
Scene nodes: 0
Scene tree: empty
```

The node count is informational; the model can use `get_scene_tree` for details.

### Task protocol

In `_send_chat`, when `turn_role == "task"`:

```text
--- Task protocol ---
This is a bounded task. Inspect the minimum relevant files, then make one
concrete edit or call submit_result. Do not repeat a read-only call. If the
scene, node, or script the task needs does not exist, call submit_result with
status blocked and name the missing item; do not keep listing files. Claim only
what a tool result proved.
```

`turn_system` stores the effective system, so continuation steps inherit it.

### Duplicate read-only guard

`_is_read_only_tool` covers:

`list_files`, `read_file`, `read_project_file`, `file_info`, `search_text`, `get_scene_tree`, `get_workspace_context`, `get_selection`, `inspect_node`, `inspect_resource`, `list_signals`, `get_project_settings`, `lookup_docs`, `find_assets`, `check_gdscript`.

`_turn_has_edits` checks the turn ledger for any `affected` entry or undo group.

In `_execute_turn_calls`, a task read-only call is treated as repeated when:

- its signature count reaches 2;
- no edit has occurred in the turn.

The existing repeat branch returns `repeated_call` with:

```text
This read-only call already ran. Stop inspecting and call submit_result with
completed or blocked.
```

and calls `_request_wrapup`, so the next task request is limited to `submit_result`.

A successful edit clears `turn_signature_counts` (existing behavior), so the guard does not block a legitimate re-read after a change.

## Tests

- Editor workspace fixture creates a workspace-mode task fake chat, calls `list_files` twice against `res://` with no edit, and asserts:
  - the second result is `repeated_call`;
  - the summary tells the model to call `submit_result`.
- The same fixture creates a second task chat whose ledger already records an `affected` file, calls `list_files` twice, and asserts both calls succeed (no `repeated_call`).
- Existing Jobs plan/task modes exercise the normal task path; the full suite is rerun.
