#!/usr/bin/env python3
"""Validate exact embedded scripts and the pure planner without device access."""
import argparse
import atexit
import hashlib
import json
import os
import re
import shlex
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--godot", type=Path, default=root / "bin/godot.linuxbsd.editor.x86_64")
parser.add_argument("--editor-smoke", action="store_true", help="Open the real Models settings section with fixture device data")
parser.add_argument("--live-readonly", action="store_true", help="Read real Tiiny inventory and run Check Config; never Apply")
parser.add_argument("--http-smoke", action="store_true", help="Exercise real HTTP against a loopback fixture")
parser.add_argument("--display-driver", choices=("x11", "wayland"), default="x11", help="Native display backend for displayed checks")
parser.add_argument("--displayed", action="store_true", help="Run editor checks on the attached display and capture windows")
parser.add_argument("--live-inference", action="store_true", help="Run real chat and polygon inference without changing model residency")
parser.add_argument("--report", type=Path, help="Write sanitized baseline identity and per-stage results as JSON")
args = parser.parse_args()
report = {"created_utc": datetime.now(timezone.utc).isoformat(), "mode": "live-inference" if args.live_inference else "live-readonly" if args.live_readonly else "offline", "stages": [], "sources": {}}

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
report["worktree"] = git_output("status", "--porcelain=v1").splitlines()
report["binary"] = {"path": str(args.godot.resolve()), "sha256": digest(args.godot.resolve())}
save_report()
with tempfile.TemporaryDirectory(prefix="tiiny-model-config-") as directory:
    fixture = Path(directory)
    environment = os.environ.copy()
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        environment[key] = str(fixture / key.lower())
    # Offline runs must not inherit SDK credentials or a caller-selected live mode.
    environment.pop("TIINY_TEST_LIVE_READONLY", None)
    offline_environment = environment.copy()
    offline_environment["HOME"] = str(fixture / "home")
    Path(offline_environment["HOME"]).mkdir()
    for key in list(offline_environment):
        if key.startswith("TIINY_"): offline_environment.pop(key)
    report["binary"]["version"] = run_stage("binary_version", [str(args.godot.resolve()), "--version"], offline_environment, 10)
    (fixture / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Tiiny planner checks"\n')
    for source, target in [("tiiny_ai_manager_source.h", "manager.gd"), ("tiiny_ai_dock_source.h", "chat.gd")]:
        text = (root / "editor" / source).read_text()
        start, end = 'R"TIINY_GD(\n', ')TIINY_GD"'
        if text.count(start) != 1 or text.count(end) != 1:
            raise SystemExit("Missing or ambiguous embedded-script delimiters: " + source)
        script = text.split(start, 1)[1].split(end, 1)[0]
        report["sources"][source] = hashlib.sha256(text.encode()).hexdigest()
        (fixture / target).write_text(script)
        run_stage("parse_" + target, [str(args.godot.resolve()), "--headless", "--path", directory, "--check-only", "--script", target], offline_environment, 30)
    (fixture / "checks.gd").write_text((Path(__file__).parent / "test_model_configuration.gd").read_text())
    run_stage("planner_panel", [str(args.godot.resolve()), "--headless", "--path", directory, "--script", "checks.gd"], offline_environment, 30, "all checks passed (no device access)")
    (fixture / "invalid_script.gd").write_text((Path(__file__).parent / "test_invalid_script.gd").read_text())
    run_stage("invalid_generated_script", [str(args.godot.resolve()), "--headless", "--path", directory, "--script", "invalid_script.gd"], offline_environment, 30, "Invalid generated script rejected before file creation (expected parse diagnostic).", expected_script_errors=1)

    if args.editor_smoke or args.live_readonly or args.http_smoke or args.live_inference or args.displayed:
        if args.live_readonly or args.live_inference:
            environment["TIINY_TEST_LIVE_READONLY"] = "1"
            if args.live_inference: environment["TIINY_TEST_LIVE_INFERENCE"] = "1"
        (fixture / "fixture.gd").write_text('extends Node2D\nfunc _ready():\n\tprint("Tiiny fixture scene running")\n')
        (fixture / "fixture.tscn").write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://fixture.gd" id="1"]\n[node name="Fixture" type="Node2D"]\nscript = ExtResource("1")\n')
        addon = fixture / "addons" / "models_smoke"
        addon.mkdir(parents=True)
        (addon / "plugin.cfg").write_text('[plugin]\nname="Models smoke"\ndescription="Offline UI check"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n')
        stub = fixture / "fake-tiiny"
        stub.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shlex.quote(str(fixture / "cli-arguments")) + "\nprintf '\\033[32m25%%\\033[0m\\r100%%\\n'\nexit 0\n")
        stub.chmod(0o755)
        (fixture / "fake_inventory_manager.gd").write_text((Path(__file__).parent / "fake_inventory_manager.gd").read_text())
        (fixture / "fake_manager.gd").write_text((Path(__file__).parent / "fake_model_manager.gd").read_text())
        for name in ("fake_chat.gd", "test_chat_protocol.gd", "test_stabilization.gd", "fake_resource_responder.gd"):
            (fixture / name).write_text((Path(__file__).parent / name).read_text())
        for name in ("test_stabilization.gd", "test_chat_protocol.gd"):
            run_stage("parse_" + name, [str(args.godot.resolve()), "--headless", "--path", directory, "--check-only", "--script", name], offline_environment, 30)
        (addon / "plugin.gd").write_text((Path(__file__).parent / "editor_model_settings_smoke.gd").read_text())
        with (fixture / "project.godot").open("a") as project:
            project.write('\n[editor_plugins]\nenabled=PackedStringArray("res://addons/models_smoke/plugin.cfg")\n')
        editor_environment = environment if args.live_readonly or args.live_inference else offline_environment
        if args.http_smoke:
            from http_fixture import start
            server = start()
            other_server = start()
            atexit.register(server.server_close)
            atexit.register(other_server.server_close)
            editor_environment["TIINY_TEST_HTTP_URL"] = "http://127.0.0.1:" + str(server.server_port)
            editor_environment["TIINY_TEST_OTHER_HTTP_URL"] = "http://127.0.0.1:" + str(other_server.server_port)
        if args.displayed:
            capture = (args.report.parent if args.report else Path("/tmp")) / "tiiny-story01-captures"
            capture.mkdir(parents=True, exist_ok=True)
            editor_environment["TIINY_TEST_CAPTURE_DIR"] = str(capture.resolve())
        options = ["--display-driver", args.display_driver] if args.displayed else ["--headless"]
        run_stage("editor_smoke", [str(args.godot.resolve()), *options, "--editor", "--path", directory, "--rendering-method", "gl_compatibility"], editor_environment, 480 if args.live_inference else 90, "Editor Models section smoke check passed")
        if args.http_smoke and (server.request_count == 0 or other_server.request_count != 0):
            raise SystemExit("Two-device binding fixture contacted an unexpected endpoint")
