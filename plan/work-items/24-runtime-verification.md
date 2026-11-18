# 24 — Runtime verification of scene gameplay

Status: Complete. The deterministic fixture proves a falling-and-jumping scene passes gravity, landing, and jump checks, a static scene fails them, a script error fails the error check, and approval, shell gating, invalid input, and cleanup behave. The pure contract test covers the definition, schema rejection, and the shell gate. See [implementation plan](../implementation/24-runtime-verification.md).

Feature: Let the assistant instantiate a saved scene headlessly, step physics, simulate input actions, and report measured body motion plus objective scene-load, error, gravity, landing, and jump checks

Sequence: 24

Stream: `integration`

Dependencies: 18 and 21. Reuses item 18's root-confined workspace provider and gated headless execution, and item 21's rule that tool results carry real evidence. It does not add a parallel execution lane or a new job type.

Implementation: [plan](../implementation/24-runtime-verification.md).

## Why

The workspace tools can prove that nodes exist, properties were set, scripts parse, and transactions undo. They cannot prove that the result plays. A platformer can pass every scene assertion and still have a player that never falls because the controller was attached to the wrong node, a platform whose collision shape is missing, or a jump bound to an action the project does not define.

The comparison with a one-shot external agent made this concrete: that output was credible because the game ran, not because its scene file was tidy. Helping the model reach a working result means giving it a way to observe frames, not only the scene tree.

Local coding models also overclaim. A measured report with a failed check is more useful than another schema retry, and it gives the user an honest completion statement instead of "the game is ready".

## Scope

Add one shared tool, `verify_scene_runtime`, available in editor and hybrid/workspace mode:

```json
{
  "scene_path": "res://main.tscn",
  "frames": 180,
  "actions": [{"action": "ui_accept", "frame": 90, "hold": 2}],
  "checks": ["scene_loads", "no_errors", "gravity", "lands", "jump"]
}
```

- `scene_path` defaults to the edited scene. A dirty editor scene is rejected because the run loads the saved file. A missing bridge requires an explicit path.
- `frames` is bounded to 10–600; `actions` to four entries with an action name, start frame, and hold; every action must be a built-in `ui_*` action or a project-defined `input/<name>` action, so an invented action is rejected before a run.
- `checks` defaults to `scene_loads` and `no_errors` and may add `gravity`, `lands`, and `jump`.
- The run uses the existing `allow_shell_commands` setting and per-run headless approval. No new permission path is introduced.
- The probe and its specification are written to `user://tiiny_runtime`, outside the project, with a per-run token. All three files are removed after the run.

The probe instantiates the scene, waits on `physics_frame`, presses and releases the requested actions, and records each `CharacterBody2D`/`RigidBody2D` path, class, start/end position, maximum y, final y velocity, minimum y velocity after an action, final `is_on_floor`, and up to 24 sampled positions. It writes JSON and does not modify the scene or project.

Checks are computed by the editor from the measurements:

| Check | Passes when |
| --- | --- |
| `scene_loads` | The scene instantiates and the simulation completes. |
| `no_errors` | The child process reports no `SCRIPT ERROR`, parse error, invalid call, or load failure. |
| `gravity` | A body moved downward at least 2 px during the run. |
| `lands` | A `CharacterBody2D` reports `is_on_floor` at the final frame. |
| `jump` | A body's y velocity became negative after a simulated action. |

A failed check is evidence, not a tool failure: the result is `ok` with `passed: false` and a named failed list, so the model can fix the cause instead of retrying the verification.

## Acceptance criteria

- [x] `verify_scene_runtime` is advertised in editor and workspace/hybrid payloads, gated by the shell setting, and requires approval.
- [x] A saved platformer scene with gravity and `ui_accept` jump passes all five checks, and the result names the player body and frame count.
- [x] A scene with no gameplay script fails `gravity`, `lands`, and `jump` while still reporting a successful run.
- [x] A scene whose controller raises a runtime error fails `no_errors` and includes the error text.
- [x] Undefined actions, unknown checks, missing scenes, disabled shell execution, and denied approval fail closed with distinct codes.
- [x] Probe files are cleaned up after success and after rejection.
- [x] The base policy directs gameplay verification to this tool and forbids claiming the game plays without it.
- [x] Deterministic fixtures and the pure contract suite pass; the wider Jobs and smoke suites are rerun for regressions.

## Evidence

- `integrations/tiiny/tests/check_runtime_verification.py` and `editor_runtime_verification.gd`: 3 evidence cases passed (platformer with a project-defined `jump` action, no-gameplay, script-error) plus approval, shell-gate, action, check, missing-scene, call-ID, and cleanup assertions.
- `test_workspace_tools.gd`: runtime definition, successful scene load with 30 frames, undefined action, unknown check, missing scene, and shell gate passed; full pure suite passed.
- Regressions: full Jobs suite passed 66 modes; the 18-case tool-selection corpus, transaction fixture, and pure/editor workspace suites passed; editor smoke passed 13 after a rerun (the first run hit the known resource-dialog crash).
- Follow-up: `verify_scene_runtime` returns `data.scene` as a path string. `_auto_save_after_edit` now reads `dirty` only when `data.scene` is a dictionary (and falls back to the string as a path for action cards). The editor workspace fixture calls auto-save with this shape to guard it.
- Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:35.50`, `bin/godot.linuxbsd.editor.x86_64`. No build remains running.
