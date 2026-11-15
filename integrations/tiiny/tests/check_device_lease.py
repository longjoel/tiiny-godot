#!/usr/bin/env python3
"""Check device exclusion between disposable editor projects."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"
with tempfile.TemporaryDirectory(prefix="tiiny-device-lease-") as directory:
    base = Path(directory)
    projects = []
    for name in ("first", "second"):
        project = base / name
        addon = project / "addons/device_test"
        addon.mkdir(parents=True)
        shutil.copyfile(root / "integrations/tiiny/tests/editor_device_lock.gd", addon / "plugin.gd")
        (addon / "plugin.cfg").write_text('[plugin]\nname="Device Test"\ndescription="Fixture"\nauthor="Tiiny"\nversion="1"\nscript="plugin.gd"\n')
        (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Device Test"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/device_test/plugin.cfg")\n')
        projects.append(project)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("TIINY_"):
            del env[key]
    env.update(HOME=str(base / "home"), XDG_CONFIG_HOME=str(base / "config"), XDG_DATA_HOME=str(base / "data"), XDG_CACHE_HOME=str(base / "cache"), TIINY_LOCK_TEST_READY=str(base / "ready"))
    def command(project):
        return [str(binary), "--headless", "--editor", "--path", str(project)]
    owner = subprocess.Popen(command(projects[0]), env=dict(env, TIINY_LOCK_TEST_MODE="owner"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 20
        while not (base / "ready").exists():
            if owner.poll() is not None:
                raise RuntimeError("owner exited early: " + owner.stdout.read().decode(errors="replace"))
            if time.monotonic() >= deadline:
                raise TimeoutError("owner did not acquire device lease")
            time.sleep(0.05)
        blocked = subprocess.run(command(projects[1]), env=dict(env, TIINY_LOCK_TEST_MODE="blocked"), capture_output=True, text=True, timeout=30)
        if blocked.returncode or "Device lock blocked passed" not in blocked.stdout or "SCRIPT ERROR" in blocked.stdout + blocked.stderr:
            raise RuntimeError(blocked.stdout + blocked.stderr)
        owner.kill()
        owner.wait(timeout=10)
        free = subprocess.run(command(projects[1]), env=dict(env, TIINY_LOCK_TEST_MODE="free"), capture_output=True, text=True, timeout=30)
        if free.returncode or "Device lock free passed" not in free.stdout or "SCRIPT ERROR" in free.stdout + free.stderr:
            raise RuntimeError(free.stdout + free.stderr)
    finally:
        if owner.poll() is None:
            owner.kill()
            owner.wait(timeout=10)
print("Cross-process device lease passed")
