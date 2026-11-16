#!/usr/bin/env python3
"""Exercise the embedded read-only workspace inspector in a disposable editor."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"

def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    (project / "addons/workspace_test").mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Workspace Inspector Test"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/workspace_test/plugin.cfg")\n'
    )
    (project / "addons/workspace_test/plugin.cfg").write_text(
        '[plugin]\nname="Workspace Inspector Test"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(root / "integrations/tiiny/tests/editor_workspace_inspector.gd", project / "addons/workspace_test/plugin.gd")
    (project / "instance.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Enemy" type="Node2D"]\n\n'
        '[node name="Turret" type="Node2D" parent="."]\n'
    )
    (project / "main.tscn").write_text(
        '[gd_scene load_steps=3 format=3]\n\n'
        '[ext_resource type="PackedScene" path="res://instance.tscn" id="1"]\n'
        '[sub_resource type="RectangleShape2D" id="RectangleShape2D_1"]\n'
        'size = Vector2(32, 16)\n\n'
        '[node name="Root" type="Node2D"]\n\n'
        '[node name="Player" type="Node2D" parent="."]\n'
        'position = Vector2(10, 20)\n\n'
        '[node name="Shape" type="CollisionShape2D" parent="Player"]\n'
        'shape = SubResource("RectangleShape2D_1")\n\n'
        '[node name="Enemy" parent="." instance=ExtResource("1")]\n'
    )
    (project / "base.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Base" type="Node2D"]\n\n'
        '[node name="BaseChild" type="Node2D" parent="."]\n'
    )
    (project / "inherited.tscn").write_text(
        '[gd_scene load_steps=2 format=3]\n\n'
        '[ext_resource type="PackedScene" path="res://base.tscn" id="1"]\n\n'
        '[node name="Inherited" instance=ExtResource("1")]\n\n'
        '[node name="Extra" type="Node2D" parent="."]\n'
    )
    (project / "running.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Running" type="Node2D"]\n'
    )
    (project / "rectangle.tres").write_text(
        '[gd_resource type="RectangleShape2D" format=3]\n\n[resource]\nsize = Vector2(32, 16)\n'
    )

with tempfile.TemporaryDirectory(prefix="tiiny-workspace-inspector-") as directory:
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
    )
    result = subprocess.run(
        [str(binary), "--headless", "--editor", "--path", str(project), "--rendering-method", "gl_compatibility"],
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )
    output = result.stdout + result.stderr
    if result.returncode or "Workspace inspector editor integration passed." not in output or "SCRIPT ERROR" in output:
        print(output)
        raise SystemExit(result.returncode or 1)
    print("Workspace inspector editor integration passed.")
