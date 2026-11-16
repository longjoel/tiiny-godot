#!/usr/bin/env python3
"""Exercise the built-in debugger bridge/provider with a real paused scene."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"

def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/debugger_test"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Tiiny Debugger Test"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/debugger_test/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Tiiny Debugger Test"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(root / "integrations/tiiny/tests/editor_debugger.gd", addon / "plugin.gd")
    (project / "debuggee.gd").write_text(
        'extends Node\n\nvar counter := 0\n\nfunc _ready() -> void:\n\tawait get_tree().create_timer(1.0).timeout\n\tcounter = 7\n\tvar doubled := counter * 2\n\tprint("debugger fixture ", doubled)\n\tget_tree().quit()\n'
    )
    (project / "debug_scene.tscn").write_text(
        '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://debuggee.gd" id="1"]\n\n'
        '[node name="DebugScene" type="Node"]\nscript = ExtResource("1")\n'
    )

with tempfile.TemporaryDirectory(prefix="tiiny-debugger-") as directory:
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
    if result.returncode or "Tiiny debugger integration passed." not in output or "SCRIPT ERROR" in output:
        print(output)
        raise SystemExit(result.returncode or 1)
    print("Tiiny debugger integration passed.")
