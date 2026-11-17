#!/usr/bin/env python3
"""Gated live-model trace: workspace file tools, then hybrid typed editor tools."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / "bin/godot.linuxbsd.editor.x86_64"


def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/workspace_coding_live"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Workspace Coding Live"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/workspace_coding_live/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Workspace Coding Live"\ndescription="Live fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(ROOT / "integrations/tiiny/tests/editor_workspace_coding_live.gd", addon / "plugin.gd")
    shutil.copyfile(ROOT / "integrations/tiiny/tests/live_turn_wait.gd", project / "live_turn_wait.gd")
    (project / "main.tscn").write_text('[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n')
    (project / "player.gd").write_text("extends Node\n\nconst SPEED := 200.0\n")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tiiny-workspace-coding-live-") as directory:
        project = Path(directory) / "project"
        make_project(project)
        env = os.environ.copy()
        env.update(
            XDG_CONFIG_HOME=str(project / "config"),
            XDG_DATA_HOME=str(project / "data"),
            XDG_CACHE_HOME=str(project / "cache"),
        )
        try:
            result = subprocess.run(
                [str(BINARY), "--headless", "--editor", "--path", str(project), "--rendering-method", "gl_compatibility"],
                env=env,
                capture_output=True,
                text=True,
                timeout=1500,
            )
        except subprocess.TimeoutExpired as error:
            print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
            print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
            raise
        output = result.stdout + result.stderr
        print(output[-14000:])
        if result.returncode or "Live workspace coding trace passed" not in output or "SCRIPT ERROR" in output:
            raise SystemExit(result.returncode or 1)
    print("Live workspace coding trace passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
