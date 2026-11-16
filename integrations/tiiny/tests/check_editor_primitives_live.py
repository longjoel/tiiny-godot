#!/usr/bin/env python3
"""Live composed-authoring sample for story 14."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"

def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/primitives_live"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Tiiny Primitives Live"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/primitives_live/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text('[plugin]\nname="Primitives Live"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n')
    shutil.copyfile(root / "integrations/tiiny/tests/editor_primitives_live.gd", addon / "plugin.gd")
    (project / "main.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n\n'
        '[node name="Player" type="Node2D" parent="."]\n\n'
        '[node name="World" type="Node3D" parent="."]\n\n'
        '[node name="Crate" type="MeshInstance3D" parent="World"]\n'
    )

with tempfile.TemporaryDirectory(prefix="tiiny-primitives-live-") as directory:
    project = Path(directory) / "project"
    make_project(project)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("TIINY_"):
            del env[key]
    result = subprocess.run(
        [str(binary), "--headless", "--editor", "--path", str(project)],
        env=env,
        capture_output=True,
        text=True,
        timeout=360,
    )
    output = result.stdout + result.stderr
    Path("/tmp/tiiny-primitives-live-full.log").write_text(output)
    print(output[-12000:])
    if result.returncode or "Live composed editor primitives passed." not in output or "SCRIPT ERROR" in output:
        raise SystemExit(result.returncode or 1)
    print("Live composed editor primitives passed.")
