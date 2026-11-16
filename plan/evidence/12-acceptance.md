# Story 12 — acceptance evidence

Story 12 is accepted for the implemented debugger path. A C++ bridge exposes the editor debugger session/stack/locals/runtime-tree state and validated breakpoint/execution controls; a GDScript provider exposes them as registry tools with structured results. A real paused-scene fixture verifies the end-to-end path.

Executable: `bin/godot.linuxbsd.editor.x86_64`, built from the story 12 working tree. No build or test remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| At a real breakpoint, inspect the correct session, stack frame, locals, and available live-node state | `check_debugger.py` starts `debug_scene.tscn`, sets a breakpoint in `debuggee.gd`, and waits for the real debugger to pause. `get_debugger_state` reports session 0, `breaked`, `debuggable`, and the fixture script. `get_stack_frames` returns the `debuggee.gd` frame; `get_stack_variables` returns `Members/counter = 7` and the not-yet-assigned `Locals/doubled`; `get_runtime_tree` returns the live node identity/type. Frame selection requests frame 0 variables. |
| Distinguish edited-scene data from runtime data and stale snapshots | Every debugger result carries `source: "runtime"`. Runtime tree results explicitly omit property values. After `debug_continue`, `get_stack_frames` returns `not_paused`; after the session ends, `get_runtime_tree` returns `no_session` and `debug_pause` returns `debug_unavailable`. No edited-scene value is substituted for runtime data. |
| Set/remove breakpoint tools validate paths and lines and keep editor UI synchronized | The fixture rejects `res://missing.gd` and line 0 with `invalid_breakpoint`. A valid set reports one enabled breakpoint through `tiiny_debugger_state`; removal reports zero. The bridge calls `EditorDebuggerNode::set_breakpoint`, which updates all debugger sessions and emits the editor `breakpoint_toggled` signal. |
| Resume/step controls and state-changing operations are visible in action history | Debugger tools return structured results (`ok`, summary, `data`, affected debugger/breakpoint entries), so chat renders them through the story 08 action cards. Implemented controls: continue, step into, step over, pause. The fixture exercises continue and verifies the stale-data transition; step/pause are implemented but the fixture only checks pause rejection after session end. |
| Disconnects, continued execution, unsupported languages, and stale IDs are handled safely | Continued execution and session end invalidate frames/runtime state. No-session and not-paused errors are explicit. Runtime identities are reported as read-only snapshots and are not dereferenced as live object IDs, so stale IDs cannot mutate the scene. GDScript is the tested language; other script languages inherit the same editor debugger bridge but were not exercised. |
| End-to-end diagnosis grounded in observed values | The fixture asserts the paused member `counter == 7` and that `doubled` is still null at the breakpoint, then records the runtime tree. Values come from the actual editor debugger inspector, not model prose or the edited scene. Missing capability (property-value inspection without a selected remote node) is reported explicitly. |

## Implementation

- C++ bridge in `editor/debugger/editor_debugger_node.cpp` (bound methods): state, stack frames, stack variables, runtime tree, frame selection, breakpoint validation/set, and continue/step/next/pause. `EditorDebuggerInspector::get_stack_variables()` returns grouped values; the runtime tree stores type/scene metadata.
- `editor/tiiny/tools/debugger.gd`: schemas and structured results for 12 debugger tools.
- `editor/tiiny/tools/registry.gd`, `editor/tiiny_ai_dock_source.h`, `editor/editor_node.cpp`, and `editor/SCsub`: provider injection, availability gating, and embedded-script generation.
- `EditorDebuggerNode` joins the `tiiny_debugger_bridge` group so the dock can resolve it lazily after editor startup.

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Real paused debugger fixture | Passed breakpoint validation, pause, frames, `counter=7`, runtime tree ≥1 node, continue/stale rejection, session-end errors, and removal | `/tmp/debugger-12i.log` |
| Transaction/registry/chat/action-card fixture | Passed | `/tmp/transactions-12b.log` |
| Editor smoke + restart stages | Passed 11/11 stages | `/tmp/tiiny-story12-smoke.json` |
| Jobs suite | Passed all 31 modes | `/tmp/jobs-12.log` |
| Loopback resource HTTP fixture | Passed | `/tmp/resource-http-12.log` |
| Build | Exit 0, `00:00:19.08` final incremental, same binary | `/tmp/tiiny-story12-build6.log` |

## Remaining boundaries

- Runtime tree entries expose identity, path, type, and scene file. Runtime property values require selecting a remote node in the editor; the tools explicitly report that limitation instead of inventing values.
- Only GDScript debugging was exercised. Other script languages use the same editor bridge but were not tested.
- Step/pause are implemented and availability-gated; the fixture exercises continue and post-session pause rejection, not a displayed step animation.
- Breakpoint line validation checks that the path is an existing script and the line is positive; it does not verify that the line contains executable code.
