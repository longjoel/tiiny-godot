# 31 — Bounded task guidance and read-only loop guard

Status: Complete. Empty-scene context, a task protocol, and a duplicate read-only guard are implemented and covered by the editor workspace/Jobs fixtures.

Feature: Keep a bounded plan task from looping file inspections when the requested scene or script does not exist; require a concrete edit or a structured `submit_result` instead

Sequence: 31

Stream: `integration`

Dependencies: 23, 29, 30. Extends plan-task dispatch and the chat tool loop. It does not change the plan-tree contract or add a new queue.

Implementation: [plan](../implementation/31-task-guidance.md).

## Why

A Gemma 4 26B plan task (“Game Logic and Win/Loss Condition”) inspected `res://`, read an empty `run-and-jump.tscn`, listed `res://` again, and then hit a truncated-response retry. The scene had no nodes or script to modify, the task brief did not say how to stop, and the model kept exploring instead of returning a blocked result.

The trace also showed the result tool missing from the model-facing capability list; the task brief mentioned `submit_result`, but the system prompt did not explain that a missing prerequisite is a valid blocked outcome.

## Scope

- **Empty scene context:** the editor context now reports `Scene nodes: N` and `Scene tree: empty` when the edited root has no children.
- **Task protocol:** every task-role request gets a short system section:
  - inspect only what is needed;
  - take one concrete edit or call `submit_result`;
  - do not repeat a read-only call;
  - if the required scene, node, or script is missing, submit `blocked` and name the missing item instead of listing files;
  - claim only what a tool result proved.
- **Duplicate read-only guard:** in a task, a repeated read-only call with no edits in the turn is treated as a repeated call at the second occurrence, not the third. The tool result says to stop inspecting and call `submit_result`; the turn is wrapped up so the task can finish.
- The guard covers listing, reading, searches, inspection, settings, docs, and asset inventory. A successful edit clears the signature counts, so post-edit re-reads are not blocked by this narrow rule.

## Acceptance criteria

- [x] An empty edited scene is visible in the editor context.
- [x] Task requests carry a bounded task protocol that names the blocked path and forbids repeated read-only calls.
- [x] A repeated read-only call in a task with no edits returns `repeated_call` and asks for `submit_result`.
- [x] A successful edit resets the existing signature counts; the guard does not apply after edits (verified by a post-edit re-read fixture).
- [x] Editor fixture, workspace/editor suites, transaction, selection, runtime, smoke, and Jobs are rerun.

## Evidence

- `editor_workspace_tools.gd`: a workspace-mode task chat executes `list_files` twice against a real project directory with no edit; the second call returns `repeated_call` with the “submit_result” guidance. A second task chat with a recorded edit in its ledger re-reads `list_files` twice and both calls succeed, proving the guard does not block inspection after a change.
- Editor smoke passed 13; workspace pure/editor, transaction, 20-case selection, and runtime verification passed.
- Full Jobs suite passed 66 modes on the final build; editor smoke passed 13.
- Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:31.21`, `bin/godot.linuxbsd.editor.x86_64`. No build remains running.
