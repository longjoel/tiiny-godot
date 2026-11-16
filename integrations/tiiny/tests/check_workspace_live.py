#!/usr/bin/env python3
"""Gated live-model check: real coding model must use the workspace recipe."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"

with tempfile.TemporaryDirectory(prefix="tiiny-workspace-live-") as directory:
    project = Path(directory) / "project"
    addon = project / "addons/workspace_live"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Workspace Live Test"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/workspace_live/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Workspace Live Test"\ndescription="Live fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(root / "integrations/tiiny/tests/editor_workspace_live.gd", addon / "plugin.gd")
    (project / "main.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n\n'
        '[node name="Player" type="CharacterBody2D" parent="."]\n'
    )
    env = os.environ.copy()
    env.update(
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
            timeout=300,
        )
    except subprocess.TimeoutExpired as error:
        print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
        print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
        raise
    output = result.stdout + result.stderr
    print(output[-12000:])
    if result.returncode or "Live workspace recipe passed" not in output or "SCRIPT ERROR" in output:
        raise SystemExit(result.returncode or 1)
    print("Live workspace recipe passed.")
