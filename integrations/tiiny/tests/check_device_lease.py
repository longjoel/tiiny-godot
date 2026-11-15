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
    # A model command may keep running remotely after its editor crashes. The
    # OS lock disappears, but the durable shared marker must block another
    # project until the original project's user acknowledges the outcome.
    model_ready = base / "model-ready"
    model_env = dict(env, TIINY_LOCK_TEST_READY=str(model_ready))
    owner = subprocess.Popen(command(projects[0]), env=dict(model_env, TIINY_LOCK_TEST_MODE="model_owner"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 20
        while not model_ready.exists():
            if owner.poll() is not None:
                raise RuntimeError("model owner exited early: " + owner.stdout.read().decode(errors="replace"))
            if time.monotonic() >= deadline:
                raise TimeoutError("model owner did not record its operation")
            time.sleep(0.05)
        owner.kill()
        owner.wait(timeout=10)
        for project, mode in ((projects[1], "model_blocked"), (projects[0], "model_recover"), (projects[1], "free")):
            result = subprocess.run(command(project), env=dict(model_env, TIINY_LOCK_TEST_MODE=mode), capture_output=True, text=True, timeout=30)
            if result.returncode or f"Device lock {mode} passed" not in result.stdout or "SCRIPT ERROR" in result.stdout + result.stderr:
                raise RuntimeError(result.stdout + result.stderr)
    finally:
        if owner.poll() is None:
            owner.kill()
            owner.wait(timeout=10)
    inference_ready = base / "inference-ready"
    inference_env = dict(env, TIINY_LOCK_TEST_READY=str(inference_ready))
    owner = subprocess.Popen(command(projects[0]), env=dict(inference_env, TIINY_LOCK_TEST_MODE="inference_owner"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 20
        while not inference_ready.exists():
            if owner.poll() is not None:
                raise RuntimeError("inference owner exited early: " + owner.stdout.read().decode(errors="replace"))
            if time.monotonic() >= deadline:
                raise TimeoutError("inference owner did not record its request")
            time.sleep(0.05)
        owner.kill()
        owner.wait(timeout=10)
        for project, mode in ((projects[1], "model_blocked"), (projects[0], "model_recover"), (projects[1], "free")):
            result = subprocess.run(command(project), env=dict(inference_env, TIINY_LOCK_TEST_MODE=mode), capture_output=True, text=True, timeout=30)
            if result.returncode or f"Device lock {mode} passed" not in result.stdout or "SCRIPT ERROR" in result.stdout + result.stderr:
                raise RuntimeError(result.stdout + result.stderr)
    finally:
        if owner.poll() is None:
            owner.kill()
            owner.wait(timeout=10)
    corrupt_ready = base / "corrupt-ready"
    corrupt_env = dict(env, TIINY_LOCK_TEST_READY=str(corrupt_ready))
    owner = subprocess.Popen(command(projects[0]), env=dict(corrupt_env, TIINY_LOCK_TEST_MODE="corrupt_owner"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 20
        while not corrupt_ready.exists():
            if owner.poll() is not None:
                raise RuntimeError("corrupt fixture exited early: " + owner.stdout.read().decode(errors="replace"))
            if time.monotonic() >= deadline:
                raise TimeoutError("corrupt fixture did not write its marker")
            time.sleep(0.05)
        owner.kill()
        owner.wait(timeout=10)
        result = subprocess.run(command(projects[1]), env=dict(corrupt_env, TIINY_LOCK_TEST_MODE="model_blocked"), capture_output=True, text=True, timeout=30)
        if result.returncode or "Device lock model_blocked passed" not in result.stdout or "SCRIPT ERROR" in result.stdout + result.stderr:
            raise RuntimeError(result.stdout + result.stderr)
    finally:
        if owner.poll() is None:
            owner.kill()
            owner.wait(timeout=10)
print("Cross-process device lease passed")
