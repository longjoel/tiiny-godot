#!/usr/bin/env python3
"""Run the story 18 workspace-vs-editor fixed-solution bake-off."""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / "bin/godot.linuxbsd.editor.x86_64"

PRISTINE_SCENE = '''[gd_scene load_steps=1 format=3]

[node name="Root" type="Node2D"]

[node name="Player" type="CharacterBody2D" parent="."]

[node name="Label" type="Label" parent="."]
offset_left = 8.0
offset_top = 8.0
text = "HUD"

[node name="World" type="Node3D" parent="."]

[node name="Crate" type="MeshInstance3D" parent="World"]
position = Vector3(0, 0, 0)

[node name="Platform" type="StaticBody2D" parent="."]
'''

PRISTINE_SCRIPT = '''extends CharacterBody2D

const SPEED := 200.0
const GRAVITY := 900.0

func _physics_process(delta: float) -> void:
\tvelocity.x = Input.get_axis("move_left", "move_right") * SPEED
\tvelocity.y += GRAVITY * delta
\tmove_and_slide()
'''


def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/workspace_bakeoff"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Workspace Bakeoff"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/workspace_bakeoff/plugin.cfg")\n'
        '[input]\nmove_left={\n"deadzone": 0.5,\n"events": []\n}\n'
        'move_right={\n"deadzone": 0.5,\n"events": []\n}\n'
        'jump={\n"deadzone": 0.5,\n"events": []\n}\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Workspace Bakeoff"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(ROOT / "integrations/tiiny/tests/editor_workspace_bakeoff.gd", addon / "plugin.gd")
    (project / "pristine.tscn").write_text(PRISTINE_SCENE)
    (project / "bake.tscn").write_text(PRISTINE_SCENE)
    (project / "pristine_player.gd").write_text(PRISTINE_SCRIPT)
    (project / "player.gd").write_text(PRISTINE_SCRIPT)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, default=Path("/tmp/tiiny-story18-bakeoff.json"))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="tiiny-workspace-bakeoff-") as directory:
        project = Path(directory) / "project"
        make_project(project)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("TIINY_"):
                del env[key]
        env.update(
            HOME=str(project / "home"),
            XDG_CONFIG_HOME=str(project / "config"),
            XDG_DATA_HOME=str(project / "data"),
            XDG_CACHE_HOME=str(project / "cache"),
            TIINY_BAKEOFF_REPORT=str(args.report),
        )
        try:
            result = subprocess.run(
                [str(BINARY), "--headless", "--editor", "--path", str(project), "--rendering-method", "gl_compatibility"],
                env=env,
                capture_output=True,
                text=True,
                timeout=300,
            )
        except subprocess.TimeoutExpired as error:
            print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
            print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
            raise
        output = result.stdout + result.stderr
        errors = output.count("SCRIPT ERROR")
        if result.returncode or "Workspace bake-off completed" not in output or errors:
            print(output)
            raise SystemExit(result.returncode or 1)

    data = json.loads(args.report.read_text())
    tasks = data.get("tasks", [])
    problems = []
    if len(tasks) != 10:
        problems.append(f"expected 10 tasks, found {len(tasks)}")
    for task in tasks:
        for mode in ("workspace", "editor"):
            if not task.get(mode, {}).get("ok", False):
                problems.append(f"{task.get('id')}: {mode} failed")
    recovery = data.get("recovery", {})
    for key in ("workspace_stale_rejected", "workspace_stale_external_edit_preserved", "workspace_no_temp_files", "editor_applied", "editor_undo_restored", "editor_redo_restored"):
        if not recovery.get(key, False):
            problems.append(f"recovery check failed: {key}")

    print(f"{'task':<14}{'workspace ms':>14}{'editor ms':>12}{'ws diff':>9}{'ed undo':>9}")
    for task in tasks:
        print(f"{task['id']:<14}{task['workspace']['ms']:>14.2f}{task['editor']['ms']:>12.2f}{task['workspace']['diff_lines']:>9}{task['editor']['undo_actions']:>9}")
    summary = data.get("summary", {})
    print(f"Correct: workspace {summary.get('workspace_ok')}/10, editor {summary.get('editor_ok')}/10")
    print(f"Median ms: workspace {summary.get('workspace_median_ms')}, editor {summary.get('editor_median_ms')}")
    print(f"Review effort: workspace diff lines {summary.get('workspace_diff_lines')}; editor undo actions {summary.get('editor_undo_actions')}")
    print("Recovery: " + json.dumps(recovery, sort_keys=True))
    if problems:
        print("\nProblems:")
        for problem in problems:
            print(" -", problem)
        return 1
    print(f"Bake-off validated; report: {args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
