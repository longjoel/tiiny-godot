#!/usr/bin/env python3
"""Exercise the embedded Jobs panel in a disposable editor project."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"
with tempfile.TemporaryDirectory(prefix="tiiny-builtin-jobs-") as directory:
    project = Path(directory)
    (project / "assets").mkdir()
    (project / "target.tscn").write_text('[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n')
    addon = project / "addons/jobs_test"
    addon.mkdir(parents=True)
    shutil.copyfile(root / "integrations/tiiny/tests/editor_builtin_jobs.gd", addon / "plugin.gd")
    (addon / "plugin.cfg").write_text('[plugin]\nname="Jobs Test"\ndescription="Fixture"\nauthor="Tiiny"\nversion="1"\nscript="plugin.gd"\n')
    (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Jobs Test"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/jobs_test/plugin.cfg")\n')
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("TIINY_"):
            del env[key]
    env.update(HOME=str(project / "home"), XDG_CONFIG_HOME=str(project / "config"), XDG_DATA_HOME=str(project / "data"), XDG_CACHE_HOME=str(project / "cache"))
    for mode in ("create", "restore"):
        env["TIINY_JOBS_TEST_MODE"] = mode
        result = subprocess.run([str(binary), "--headless", "--editor", "--path", str(project)], env=env, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        if result.returncode or f"Built-in Jobs {mode} passed" not in output or "SCRIPT ERROR" in output:
            print(output)
            raise SystemExit(result.returncode or 1)
        print(f"Built-in Jobs {mode} passed")
