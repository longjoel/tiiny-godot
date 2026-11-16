#!/usr/bin/env python3
"""Displayed editor capture of the Jobs panel with a completed fixture job."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"
capture = Path("/tmp/tiiny-jobs-displayed.png")

def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    (project / "assets").mkdir()
    addon = project / "addons/jobs_display"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Tiiny Jobs Display"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/jobs_display/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text('[plugin]\nname="Jobs Display"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n')
    shutil.copyfile(root / "integrations/tiiny/tests/editor_jobs_displayed.gd", addon / "plugin.gd")

with tempfile.TemporaryDirectory(prefix="tiiny-jobs-display-") as directory:
    project = Path(directory) / "project"
    make_project(project)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("TIINY_"):
            del env[key]
    env["DISPLAY"] = ":0"
    result = subprocess.run(
        [str(binary), "--editor", "--path", str(project), "--display-driver", "x11", "--rendering-method", "gl_compatibility"],
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    output = result.stdout + result.stderr
    if result.returncode or "Displayed Jobs capture passed" not in output or "SCRIPT ERROR" in output:
        print(output)
        raise SystemExit(result.returncode or 1)
    if not capture.exists() or capture.stat().st_size < 1000:
        print(output)
        raise SystemExit("Jobs capture was not written")
    print("Displayed Jobs capture passed:", capture, capture.stat().st_size, "bytes")
