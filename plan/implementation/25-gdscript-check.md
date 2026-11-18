# Story 25 implementation plan — safe GDScript compile check

Status: Implemented and verified by the pure and editor workspace suites.

Parent: [25 — Safe GDScript compile check](../work-items/25-gdscript-check.md).

## Execution contract

- The check compiles only. It never instantiates the script, calls a function, writes a file, starts a process, attaches to a node, or changes the scene.
- The check runs in the editor process. `ScriptServer::is_scripting_enabled()` is false there, so `reload()` does not run static initializers.
- A leading `@tool` annotation is removed before compiling, because `is_tool()` is the other path that enables `can_run`.
- The snippet is bounded to 100,000 characters. Results are bounded to 80 method names and 40 signal names.
- An incompatible `target_class` is a failed check, not a tool error. The script compiled; it simply cannot attach to that node class.
- The tool is advertised in every mode and has no approval, shell, scene, or device gate.

## Engine diagnostics

`GDScript` previously exposed only the `Error` from `reload()`. Add per-instance diagnostics:

```cpp
String last_error;
String last_error_kind; // "parse" or "compile"
int last_error_line = 0;
```

In `GDScript::reload()`:

- clear all three immediately after setting `reloading = true`;
- on parser failure, copy the first `ParserError` line and message;
- on analyzer failure, copy the first error from the parser error list;
- on compiler failure, copy `compiler.get_error_line()` and `compiler.get_error()`.

Bind `get_last_error()`, `get_last_error_kind()`, and `get_last_error_line()` in `_bind_methods`. The fields are per-script and additive; no existing behavior changes.

## Tool

Definition in `editor/tiiny/tools/workspace.gd`:

```json
{
  "name": "check_gdscript",
  "source": "extends CharacterBody2D\n...",
  "target_class": "CharacterBody2D"
}
```

Handler:

1. Reject empty or oversized source and unknown target classes.
2. Remove the first line-leading `@tool` annotation with a multiline regex; the replacement keeps the newline so reported line numbers match the input.
3. Compile with `GDScript.new()` + `source_code` + `reload()`.
4. On failure, return `ok: false`, `error.code` of `parse_error` or `compile_error`, the message, line, kind, and engine error code.
5. On success, return the base class, method names, signal names, `tool_annotation_removed`, and `preloaded`.
6. When `target_class` is supplied, fail with `incompatible_target` if `ClassDB.is_parent_class(target_class, base_class)` is false.

If `get_instance_base_type()` returns empty for a valid script, report `RefCounted` because that is GDScript's default base.

## Safety boundary

- `@tool` stripping is required because a tool script can run `_static_init()` during reload.
- A `preload("res://other.gd")` is refused with `unsafe_source`; resolving it can run the dependency's static initializer even in the editor process. Asset preloads such as textures or scenes are still allowed and marked `preloaded: true`.
- Static variable initializers and `_static_init` did not run in the editor process in testing. They do run in a `--script` process where scripting is enabled, so the safety guarantee is tied to the editor host and is asserted in the editor fixture.
- Mocking `OS.execute` was tested and rejected: a script attached to the `OS` singleton does not intercept the native MethodBind call, and `OS.create_process` still spawns processes. Execution remains out of scope until an external sandbox exists.

## Tests

- `test_workspace_tools.gd`:
  - valid controller compiles, reports `CharacterBody2D`, `_physics_process`, and target compatibility;
  - a `String` assigned to `int` returns line 4 and a non-empty message;
  - `CharacterBody2D` against `Label` returns `incompatible_target`;
  - an unknown target returns `invalid_arguments`;
  - `@tool` is stripped;
  - a `preload("res://other.gd")` is refused as `unsafe_source`;
  - whitespace-only and 100,001-character sources are rejected.
- `editor_workspace_tools.gd` (editor process):
  - valid compile and error line through the registry;
  - a `@tool` snippet whose `_static_init` writes a file creates no file, proving the editor-process boundary.
- The existing definition loop asserts the new tool has a name, description, parameters, risk, and timeout.
