#!/usr/bin/env python3
"""Exercise the embedded typed scene transaction provider in a disposable editor."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"

def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/transaction_test"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Workspace Transaction Test"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/transaction_test/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Workspace Transaction Test"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(root / "integrations/tiiny/tests/editor_workspace_transactions.gd", addon / "plugin.gd")
    chat_source = (root / "editor/tiiny_ai_dock_source.h").read_text().split('R"TIINY_GD(\n', 1)[1].split(')TIINY_GD"', 1)[0]
    (project / "chat.gd").write_text(chat_source)
    shutil.copyfile(root / "integrations/tiiny/tests/fake_chat.gd", project / "fake_chat.gd")
    (project / "main.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n\n'
        '[node name="Player" type="CharacterBody2D" parent="."]\n\n'
        '[node name="Enemy" type="CharacterBody2D" parent="."]\n\n'
        '[node name="Tree" type="Node2D" parent="."]\n\n'
        '[node name="Torch" type="Node2D" parent="."]\n\n'
        '[node name="Light2D" type="Light2D" parent="Torch"]\n\n'
        '[node name="Platform" type="StaticBody2D" parent="."]\n'
    )
    (project / "base.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Base" type="Node2D"]\n'
    )
    (project / "running.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Running" type="Node2D"]\n'
    )

with tempfile.TemporaryDirectory(prefix="tiiny-workspace-transactions-") as directory:
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
    try:
        result = subprocess.run(
            [str(binary), "--headless", "--editor", "--path", str(project), "--rendering-method", "gl_compatibility"],
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
        )
    except subprocess.TimeoutExpired as error:
        print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
        print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
        raise
    output = result.stdout + result.stderr
    if result.returncode or "Workspace transaction editor integration passed." not in output or "SCRIPT ERROR" in output:
        print(output)
        raise SystemExit(result.returncode or 1)
    print("Workspace transaction editor integration passed.")
