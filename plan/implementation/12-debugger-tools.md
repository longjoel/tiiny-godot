# Story 12 implementation plan — paused execution, live inspection, and breakpoints

Status: Accepted for the implemented path.

Parent: [12 — Paused execution, live scene inspection, and breakpoints](../work-items/12-debugger-tools.md).

## Execution contract

The editor debugger remains authoritative. The Tiiny bridge is read-only for observations and uses the editor's own validated breakpoint/execution APIs for changes. Runtime data is labeled `source: "runtime"` and never substituted with edited-scene values.

## Bridge

`EditorDebuggerNode` gains script-bound methods:

- `tiiny_debugger_state()`: current session ID, session-active/breaked/debuggable flags, selected frame, script file/line, enabled breakpoint count.
- `tiiny_stack_frames()`: frame dictionaries from the paused stack tree.
- `tiiny_stack_variables()`: grouped `Locals`/`Members`/`Globals`/`Evaluated` values from `EditorDebuggerInspector`.
- `tiiny_runtime_tree()`: bounded runtime tree identities, paths, types, and scene files (no property values).
- `tiiny_select_stack_frame(frame)`: selects the frame and requests its variables.
- `tiiny_set_breakpoint(path,line,enabled)`: validates `res://` existence and script type, then uses `EditorDebuggerNode::set_breakpoint` so all sessions/UI stay synchronized.
- `tiiny_debug_command(command)`: pause/continue/step/next with session/pause guards.
- `request_remote_tree()` is bound so the provider can refresh the runtime tree.

`EditorDebuggerInspector` gains `get_stack_variables()`. Runtime tree items store node type and scene-file metadata. The debugger node joins `tiiny_debugger_bridge` so the dock resolves it lazily after editor startup.

## Provider

`editor/tiiny/tools/debugger.gd` exposes 12 tools: state, frames, variables, frame selection, runtime tree, runtime-node identity, set/remove breakpoint, continue, step, next, and pause. Results are structured (`ok`, summary, data, affected) for the story 08 action cards.

- Unpaused frame/variable calls return `not_paused`.
- No session returns `no_session`/`debug_unavailable`.
- Runtime node inspection reports `properties_available: false` rather than inventing property values.
- Frame/variable reads retry once after selecting a frame, because the debuggee's variable messages are asynchronous.

## Availability

Dock availability enables state/breakpoints when the bridge exists, frame/variables/step/continue only while paused, runtime tree only with an active session, and pause only while running.

## Verification

`check_debugger.py` creates a fixture scene that waits one second, then pauses on line 8. The editor plugin sets a breakpoint after the session starts, waits for the real pause, and checks:

- invalid path/line rejection and enabled-breakpoint state;
- session 0, debuggable, fixture script;
- stack frame and `Members/counter = 7`, `Locals/doubled = null`;
- frame selection and runtime tree with at least one node;
- continue, stale-frame rejection, session end, `no_session` runtime tree, and pause rejection;
- breakpoint removal.

## Gates

- Runtime evidence comes from the real debugger, not model prose or edited-scene defaults.
- Breakpoints validate and synchronize the editor UI.
- Continued/ended sessions invalidate pause data.
- Missing runtime property data is explicit.
