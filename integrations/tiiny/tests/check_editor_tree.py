#!/usr/bin/env python3
"""Run the tree worker and publisher inside a disposable headless editor."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"
with tempfile.TemporaryDirectory(prefix="tiiny-editor-tree-") as directory:
    project = Path(directory)
    (project / "assets").mkdir()
    scripts = project / "job_scripts"
    scripts.mkdir()
    for name in ("queue.gd", "executor.gd", "tree_worker.gd", "tree_publisher.gd"):
        shutil.copyfile(root / "editor/tiiny/jobs" / name, scripts / name)
    addon = project / "addons/tree_test"
    addon.mkdir(parents=True)
    shutil.copyfile(root / "integrations/tiiny/tests/editor_tree_smoke.gd", addon / "plugin.gd")
    (addon / "plugin.cfg").write_text('[plugin]\nname="Tree Test"\ndescription="Fixture"\nauthor="Tiiny"\nversion="1"\nscript="plugin.gd"\n')
    (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Tree Test"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/tree_test/plugin.cfg")\n')
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("TIINY_"):
            del env[key]
    env["HOME"] = str(project / "home")
    env["XDG_CONFIG_HOME"] = str(project / "config")
    env["XDG_DATA_HOME"] = str(project / "data")
    env["XDG_CACHE_HOME"] = str(project / "cache")
    result = subprocess.run([str(binary), "--headless", "--editor", "--path", str(project)], env=env, capture_output=True, text=True, timeout=60)
    if result.returncode or "Editor tree publication and import passed" not in result.stdout or "SCRIPT ERROR" in result.stdout + result.stderr:
        print(result.stdout + result.stderr)
        raise SystemExit(result.returncode or 1)
print("Editor tree publication and import passed")
