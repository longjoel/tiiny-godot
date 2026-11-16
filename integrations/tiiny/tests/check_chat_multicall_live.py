#!/usr/bin/env python3
"""Live chat reproduction for the multi-tool-call Ornith turn."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"

def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/multicall_live"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Tiiny Multicall Live"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/multicall_live/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text('[plugin]\nname="Multicall Live"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n')
    shutil.copyfile(root / "integrations/tiiny/tests/editor_chat_multicall_live.gd", addon / "plugin.gd")
    source = Path("/home/longjoel/new-game-project/bounce_script.gd")
    script = source.read_text() if source.exists() else 'extends Sprite2D\n\nvar velocity := Vector2(80, 110)\n'
    (project / "bounce_script.gd").write_text(script)
    prompt = sys.argv[1] if len(sys.argv) > 1 else "right now this thing just kind of ping pongs around randomly. every time it hits the bottom of the window, I want it to pick up some velocity."
    (project / "prompt.txt").write_text(prompt)
    (project / "game.tscn").write_text(
        '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://bounce_script.gd" id="1"]\n\n'
        '[node name="Root" type="Node2D"]\n\n'
        '[node name="Icon" type="Sprite2D" parent="."]\nposition = Vector2(114, 301)\nscript = ExtResource("1")\n'
    )

with tempfile.TemporaryDirectory(prefix="tiiny-multicall-live-") as directory:
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
        timeout=420,
    )
    output = result.stdout + result.stderr
    Path("/tmp/tiiny-chat-live-full.log").write_text(output)
    print(output[-12000:])
    if result.returncode or "Live multi-call chat passed." not in output or "SCRIPT ERROR" in output:
        raise SystemExit(result.returncode or 1)
    print("Live multi-call chat passed.")
