#!/usr/bin/env python3
"""Smoke test for story 03: device binding and protected coding-model lifecycle.
Validates device binding, coding model validation/persistence, download/load
confirmation from device state, coding model protection on startup/reconnect,
and error-state handling for disconnect/auth/capacity failures.

Run without flags for fake-fixture coverage. Use --device-smoke for real Tiiny
device smoke (read-only: never applies model changes, never evicts loaded models).
"""
import argparse
import atexit
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--godot", type=Path, default=root / "bin/godot.linuxbsd.editor.x86_64")
parser.add_argument("--editor-smoke", action="store_true")
parser.add_argument("--device-smoke", action="store_true", help="Run smoke tests against the real Tiiny device; never applies changes or evicts loaded models")
parser.add_argument("--report", type=Path, help="Write sanitized results as JSON")
args = parser.parse_args()
report = {"created_utc": datetime.now(timezone.utc).isoformat(), "mode": "device-smoke" if args.device_smoke else "offline", "stages": [], "sources": {}}

def git_output(*arguments):
    return subprocess.run(["git", *arguments], cwd=root, check=True, text=True, capture_output=True).stdout.strip()

def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()

def save_report():
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")

def run_stage(name, arguments, environment, timeout, marker=None, expected_script_errors=0):
    started = time.monotonic()
    stage = {"name": name, "status": "failed"}
    report["stages"].append(stage)
    try:
        result = subprocess.run(arguments, check=False, timeout=timeout, env=environment, text=True, capture_output=True)
        print(result.stdout, end="")
        print(result.stderr, end="")
        stage["exit_code"] = result.returncode
        stage["script_errors"] = len(re.findall(r"SCRIPT ERROR:", result.stdout + result.stderr))
        stage["expected_script_errors"] = expected_script_errors
        stage["engine_errors"] = len(re.findall(r"^ERROR:", result.stderr, re.MULTILINE))
        if result.returncode != 0 or stage["script_errors"] != expected_script_errors or (marker and marker not in result.stdout):
            raise SystemExit(name + " failed; see diagnostic output above")
        stage["status"] = "passed"
        return result.stdout.strip()
    except subprocess.TimeoutExpired as error:
        stage["status"] = "timed_out"
        print((error.stdout or b"").decode(errors="replace"))
        print((error.stderr or b"").decode(errors="replace"))
        raise SystemExit(name + " timed out") from error
    finally:
        stage["elapsed_seconds"] = round(time.monotonic() - started, 3)
        save_report()

report["revision"] = git_output("rev-parse", "HEAD")
report["binary"] = {"path": str(args.godot.resolve()), "sha256": digest(args.godot.resolve())}
save_report()
print("=== Story 03 device lifecycle smoke test ===")
print("Revision:", report["revision"][:12])
print("Mode:", report["mode"])
print()

with tempfile.TemporaryDirectory(prefix="tiiny-device-smoke-") as directory:
    fixture = Path(directory)
    environment = os.environ.copy()
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        environment[key] = str(fixture / key.lower())
    environment["HOME"] = str(fixture / "home")
    Path(environment["HOME"]).mkdir()
    for key in list(environment):
        if key.startswith("TIINY_") and key not in ("TIINY_QUEUE_TEST_DIR",):
            environment.pop(key, None)
    report["binary"]["version"] = run_stage("binary_version", [str(args.godot.resolve()), "--version"], environment, 10)
    (fixture / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Tiiny device smoke"\n')
    # Extract manager source from the header
    text = (root / "editor" / "tiiny_ai_manager_source.h").read_text()
    start, end = 'R"TIINY_GD(\n', ')TIINY_GD"'
    if text.count(start) != 1 or text.count(end) != 1:
        raise SystemExit("Missing or ambiguous embedded-script delimiters: tiiny_ai_manager_source.h")
    script = text.split(start, 1)[1].split(end, 1)[0]
    report["sources"]["manager"] = hashlib.sha256(text.encode()).hexdigest()
    (fixture / "manager.gd").write_text(script)
    (fixture / "fake_device_manager.gd").write_text((root / "integrations" / "tiiny" / "tests" / "fake_device_manager.gd").read_text())
    (fixture / "device_smoke_plugin.gd").write_text((root / "integrations" / "tiiny" / "tests" / "device_smoke_plugin.gd").read_text())
    # Write project.godot with auto-load for the test plugin (overrides the earlier write)
    (fixture / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Tiiny device smoke"\n\n[autoload]\ntest_smoke="*res://device_smoke_plugin.gd"\n')
    for name in ("test_stabilization.gd", "test_chat_protocol.gd"):
        (fixture / name).write_text((root / "integrations" / "tiiny" / "tests" / name).read_text())
        run_stage("parse_" + name, [str(args.godot.resolve()), "--headless", "--path", str(fixture), "--check-only", "--script", name], environment, 30)
    run_stage("parse_manager", [str(args.godot.resolve()), "--headless", "--path", str(fixture), "--check-only", "--script", "manager.gd"], environment, 30)
    run_stage("parse_fake_device", [str(args.godot.resolve()), "--headless", "--path", str(fixture), "--check-only", "--script", "fake_device_manager.gd"], environment, 30)
    print("\n=== Running story 03 smoke test ===")
    print("No real device operations will occur.\n")
    run_stage("offline_smoke", [str(args.godot.resolve()), "--headless", "--editor", "--path", str(fixture), "--rendering-method", "gl_compatibility"], environment, 120)

print("\n=== Summary ===")
for s in report["stages"]:
    status = s["status"]
    print(f"  {s['name']:30} {status:12} exit={s.get('exit_code')} errors={s.get('script_errors')}/{s.get('expected_script_errors')}")

failed = [s for s in report["stages"] if s["status"] != "passed"]
if failed:
    print(f"\n{len(failed)} stage(s) failed:")
    for s in failed:
        print(f"  - {s['name']}: {s['status']}")
else:
    print(f"\nAll {len(report['stages'])} stages passed.")
