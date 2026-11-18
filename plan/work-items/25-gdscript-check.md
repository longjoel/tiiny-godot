# 25 — Safe GDScript compile check

Status: Complete. The in-memory check, error line, target compatibility, and editor-process `@tool` safety path pass in the pure and editor workspace suites. See [implementation plan](../implementation/25-gdscript-check.md).

Feature: Let the assistant compile a GDScript snippet in memory, report the first parse or compile error with its line and message, and check attachment compatibility without writing a file, starting a process, or running the snippet

Sequence: 25

Stream: `integration`

Dependencies: 15 and 18. Uses the existing workspace provider and script-creation flow. It does not execute project code and introduces no approval path.

Implementation: [plan](../implementation/25-gdscript-check.md).

## Why

The model writes GDScript for gameplay and then has to find out whether it is valid. The existing create-and-attach path validates during the write, but it needs approval, creates a file, and reports only "failed validation". That is too late and too opaque for iteration: a small model can spend several approved attempts guessing at a missing parenthesis.

A safe check should be cheap enough to call repeatedly. Compilation is the useful boundary here. It catches syntax, analyzer, and compiler errors, and it reports the base class and method surface, without instantiating the script or running any of its code. It cannot prove behavior; `verify_scene_runtime` covers measured gameplay separately.

Execution was considered and rejected for this item. Godot has no permission model, and mocking `OS.execute` is not a boundary:

- Attaching a script to the `OS` singleton succeeds, but `OS.execute` still calls the native method and the mock is never invoked.
- `OS.create_process` runs independently, and `FileAccess`, `DirAccess`, networking, and resource loading remain available.

A real execution boundary would require an external OS sandbox. Until that exists, the safe test is compilation, not evaluation.

## Scope

Add one shared tool, `check_gdscript`, available in editor and hybrid/workspace mode:

```json
{
  "source": "extends CharacterBody2D\n\nfunc _ready() -> void:\n\tpass\n",
  "target_class": "CharacterBody2D"
}
```

- `source` is bounded to 100,000 characters and must not be empty after trimming.
- Compilation uses `GDScript.new()` with `source_code` and `reload()` in the editor process. No file is written, no process is started, no node is created, and nothing is attached.
- A leading `@tool` annotation is removed before compiling. In the editor process `ScriptServer::is_scripting_enabled()` is false, so static initializers do not run; removing `@tool` prevents the annotation from enabling them.
- A successful check reports the base class, methods, signals, and an optional `target_class` compatibility verdict using `ClassDB.is_parent_class`.
- An incompatible target is a check failure (`incompatible_target`), not a tool error, because the snippet compiled.
- Unknown target classes, empty source, and oversized source are rejected before compiling.

Compilation may resolve asset `preload("res://...")` resources; a preload of another `.gd` is refused with `unsafe_source` because resolving it can run that script's static initializer. The result carries `preloaded: true` for asset preloads, and the snippet itself is never instantiated or called.

### Diagnostics

The engine did not expose parse errors to GDScript. `GDScript::reload()` printed them and returned only an error code. Add per-instance diagnostics to the GDScript module:

- `last_error`, `last_error_kind`, `last_error_line`, cleared at the start of every reload;
- populated on parser, analyzer, and compiler failure;
- exposed as `get_last_error()`, `get_last_error_kind()`, and `get_last_error_line()`.

The change is additive. It does not alter parsing, compilation, or reload behavior, and it gives the tool the real message and line instead of a generic failure.

## Acceptance criteria

- [x] `check_gdscript` is advertised in editor, workspace, and hybrid payloads without an approval or shell setting.
- [x] A valid controller compiles and reports `CharacterBody2D`, its methods, and target compatibility.
- [x] A type error returns the failing line and message, not a generic failure.
- [x] A valid script with an incompatible target fails with `incompatible_target`; an unknown target fails with `invalid_arguments`.
- [x] Empty and oversized sources fail without writing or compiling.
- [x] A `@tool` snippet with a side-effecting `_static_init` compile-checks with no file created in the editor process.
- [x] A preload of another `.gd` is refused before compilation; asset preloads remain allowed and are flagged.
- [x] No file, scene, node, process, or project setting is created or changed by the tool.
- [x] The base policy directs the model to check GDScript before creating or attaching it.
- [x] Pure and editor workspace suites, the wider Jobs suite, and smoke checks are rerun for regressions.

## Evidence

- `test_workspace_tools.gd`: valid compile with base/method/target, error line 4 with message, incompatible and unknown targets, `@tool` strip, GDScript-preload refusal, empty source, and oversized source passed; full pure suite passed.
- `editor_workspace_tools.gd` (through `check_workspace_tools.py`): valid compile, error line, and a side-effecting `@tool` static initializer that created no file in the editor process passed; editor integration passed.
- Regressions: full Jobs suite passed 66 modes; the transaction fixture, 18-case selection corpus, runtime fixture, and editor smoke passed. The new tool initially pushed the transaction fixture's 32k conservative chat budget over by about 400 bytes; shortened descriptions and policy sentence restored it without weakening the budget assertion.
- Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:36.82`, `bin/godot.linuxbsd.editor.x86_64`. No build remains running.
