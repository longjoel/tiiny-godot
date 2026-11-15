#!/usr/bin/env python3
"""Exercise the queue lease and interrupted-job recovery in real processes."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / "bin/godot.linuxbsd.editor.x86_64"
SCRIPT = "integrations/tiiny/tests/job_process.gd"

with tempfile.TemporaryDirectory(prefix="tiiny-queue-process-") as directory:
    base_env = os.environ.copy()
    base_env["TIINY_QUEUE_TEST_DIR"] = directory
    command = [str(BINARY), "--headless", "--path", str(ROOT), "--script", SCRIPT]

    def env(mode):
        return dict(base_env, TIINY_QUEUE_TEST_MODE=mode)

    owner = subprocess.Popen(command, env=env("owner"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 15
        while not (Path(directory) / "ready").exists():
            if owner.poll() is not None:
                raise RuntimeError("owner exited early: " + owner.stdout.read().decode(errors="replace"))
            if time.monotonic() >= deadline:
                raise TimeoutError("owner did not become ready")
            time.sleep(0.05)
        subprocess.run(command, env=env("contend"), check=True, timeout=15, capture_output=True)
        owner.kill()
        owner.wait(timeout=15)
        # A partial, unacknowledged write must not replace the committed record.
        (Path(directory) / "process.json.tmp").write_text('{"partial":', encoding="utf-8")
        subprocess.run(command, env=env("recover"), check=True, timeout=15, capture_output=True)
    finally:
        if owner.poll() is None:
            owner.kill()
            owner.wait(timeout=15)
    publication_dir = Path(directory) / "publication"
    publication_dir.mkdir()
    base_env["TIINY_QUEUE_TEST_DIR"] = str(publication_dir)
    owner = subprocess.Popen(command, env=env("publication_owner"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 15
        while not (publication_dir / "ready").exists():
            if owner.poll() is not None:
                raise RuntimeError("publication owner exited early: " + owner.stdout.read().decode(errors="replace"))
            if time.monotonic() >= deadline:
                raise TimeoutError("publication owner did not become ready")
            time.sleep(0.05)
        owner.kill()
        owner.wait(timeout=15)
        subprocess.run(command, env=env("publication_recover"), check=True, timeout=15, capture_output=True)
    finally:
        if owner.poll() is None:
            owner.kill()
            owner.wait(timeout=15)
print("process lock and interrupted recovery passed")
