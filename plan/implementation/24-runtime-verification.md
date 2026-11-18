# Story 24 implementation plan — runtime verification

Status: Implemented and verified by the deterministic fixture and pure contract suite.

Parent: [24 — Runtime verification of scene gameplay](../work-items/24-runtime-verification.md).

## Execution contract

- Verification runs only on a saved scene. The editor scene is the default; a dirty scene is rejected because the child loads the file, not the unsaved buffer.
- The run is host code execution. It uses the existing `tiiny_ai/advanced/allow_shell_commands` gate and the existing per-run headless approval dialog. There is no second permission system.
- The tool is read-only with respect to the project. The probe and its JSON specification live in `user://tiiny_runtime`, outside `res://`, and are removed after the run.
- The editor computes checks from recorded measurements. The probe does not decide pass/fail and cannot be talked into a verdict by the model.
- A failed check returns `ok: true`, `passed: false`, and `failed: [...]`. The tool executed correctly; the scene did not pass. This keeps the model from retrying the tool instead of fixing the scene.
- Output is bounded: 600 physics frames, four actions, 24 samples per body, and a 3,000-character stderr tail.

## Probe

`workspace.gd` embeds `RUNTIME_PROBE_SOURCE`, executed with:

```
<editor binary> --headless --path <project> --script <user dir>/probe_<token>.gd -- <spec.json>
```

The probe is a `SceneTree` script. It:

1. reads the specification path from `OS.get_cmdline_user_args()`;
2. loads and instantiates the scene, then adds it under the root;
3. collects every `CharacterBody2D` and `RigidBody2D` breadth-first with scene-relative paths;
4. on each `physics_frame`, presses and releases scheduled actions and records the state produced by the previous physics step;
5. writes JSON to the output path and quits.

`physics_frame` fires before `_physics_process`, so samples trail by one physics step. Landing and jump checks tolerate that; the final frame is still after 180 steps. No engine-internal hooks or autoloads are added.

Actions use `Input.action_press`/`action_release`. The editor validates each name against built-in `InputMap` actions and project `input/<name>` settings before the run, so a jump test cannot silently do nothing because the action was misspelled. Project-defined actions are not loaded into the editor's `InputMap`, so both sources are checked.

## Checks

- `scene_loads`: probe reached the final frame and wrote a result.
- `no_errors`: no `SCRIPT ERROR`, `Parse Error`, `Invalid call`, `Failed loading resource`, or `Can't load script` line, and the child exited zero.
- `gravity`: `max_y - start_y >= 2` for some body.
- `lands`: some `CharacterBody2D` has `is_on_floor()` at the final sampled frame.
- `jump`: some body's y velocity became `<= -1` after an action press.

These are deliberately mechanical. They cannot prove feel, level design, or visual quality, and the tool says so by reporting only what it measured.

## Failure handling

- Probe error before simulation (`scene_load_failed`, `instantiate_failed`, `invalid_spec`) is a tool error with stderr and a fix hint.
- Timeout or non-zero exit is a tool error; the existing process-group cleanup applies.
- A missing result file is reported as `probe_failed` with the child output, not as a passing run.
- Files are removed on every path after they are written, including denied approval.

## Tests

- `integrations/tiiny/tests/editor_runtime_verification.gd` runs the real provider in a disposable project with a platformer, a static body, and a broken controller. It asserts:
  - all five checks pass for the platformer and the result carries a call ID;
  - gravity, landing, and jump fail on a scene with no gameplay;
  - `no_errors` fails and surfaces `SCRIPT ERROR` for a broken controller;
  - denied approval, disabled shell execution, undefined actions, unknown checks, and missing scenes fail with their own codes;
  - no probe files remain.
- `check_runtime_verification.py` isolates HOME and XDG directories and requires `Runtime verification cases passed: 3`.
- `test_workspace_tools.gd` asserts the definition is shared and long-running, a saved empty scene loads for 30 frames, and the invalid inputs and shell gate fail closed.
