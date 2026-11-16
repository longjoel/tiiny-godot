#!/usr/bin/env python3
"""Live batch for native authoring recipes."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"

def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/authoring_batch"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Tiiny Authoring Batch"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/authoring_batch/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text('[plugin]\nname="Authoring Batch"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n')
    shutil.copyfile(root / "integrations/tiiny/tests/editor_authoring_batch_live.gd", addon / "plugin.gd")
    (project / "main.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n\n'
        '[node name="Player" type="CharacterBody2D" parent="."]\n\n'
        '[node name="Torch" type="Node2D" parent="."]\n\n'
        '[node name="Light2D" type="Light2D" parent="Torch"]\n\n'
        '[node name="Platform" type="StaticBody2D" parent="."]\n'
    )

with tempfile.TemporaryDirectory(prefix="tiiny-authoring-batch-") as directory:
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
        timeout=720,
    )
    output = result.stdout + result.stderr
    Path("/tmp/tiiny-authoring-batch-full.log").write_text(output)
    print(output[-14000:])
    if result.returncode or "Live authoring batch passed." not in output or "SCRIPT ERROR" in output:
        raise SystemExit(result.returncode or 1)
    print("Live authoring batch passed.")
