#!/usr/bin/env python3
"""Validate exact embedded scripts and the pure planner without device access."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--godot", type=Path, default=root / "bin/godot.linuxbsd.editor.x86_64")
parser.add_argument("--editor-smoke", action="store_true", help="Open the real Models settings section with fixture device data")
parser.add_argument("--live-readonly", action="store_true", help="Read real Tiiny inventory and run Check Config; never Apply")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="tiiny-model-config-") as directory:
    fixture = Path(directory)
    environment = os.environ.copy()
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        environment[key] = str(fixture / key.lower())
    (fixture / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Tiiny planner checks"\n')
    for source, target in [("tiiny_ai_manager_source.h", "manager.gd"), ("tiiny_ai_dock_source.h", "chat.gd")]:
        text = (root / "editor" / source).read_text()
        script = text.split('R"TIINY_GD(\n', 1)[1].split(')TIINY_GD"', 1)[0]
        (fixture / target).write_text(script)
        subprocess.run([str(args.godot.resolve()), "--headless", "--path", directory, "--check-only", "--script", target], check=True, timeout=30, env=environment)
    (fixture / "checks.gd").write_text((Path(__file__).parent / "test_model_configuration.gd").read_text())
    subprocess.run([str(args.godot.resolve()), "--headless", "--path", directory, "--script", "checks.gd"], check=True, timeout=30, env=environment)

    if args.editor_smoke or args.live_readonly:
        if args.live_readonly:
            environment["TIINY_TEST_LIVE_READONLY"] = "1"
        addon = fixture / "addons" / "models_smoke"
        addon.mkdir(parents=True)
        (addon / "plugin.cfg").write_text('[plugin]\nname="Models smoke"\ndescription="Offline UI check"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n')
        stub = fixture / "fake-tiiny"
        stub.write_text("#!/bin/sh\nprintf '\\033[32m25%%\\033[0m\\r100%%\\n'\nexit 0\n")
        stub.chmod(0o755)
        (fixture / "fake_manager.gd").write_text((Path(__file__).parent / "fake_model_manager.gd").read_text())
        (addon / "plugin.gd").write_text((Path(__file__).parent / "editor_model_settings_smoke.gd").read_text())
        with (fixture / "project.godot").open("a") as project:
            project.write('\n[editor_plugins]\nenabled=PackedStringArray("res://addons/models_smoke/plugin.cfg")\n')
        try:
            result = subprocess.run([str(args.godot.resolve()), "--headless", "--editor", "--path", directory], check=False, timeout=60, env=environment, text=True, capture_output=True)
        except subprocess.TimeoutExpired as error:
            print((error.stdout or b"").decode(errors="replace"))
            print((error.stderr or b"").decode(errors="replace"))
            raise SystemExit("Editor model settings smoke test timed out") from error
        print(result.stdout)
        if result.stderr:
            print(result.stderr)
        if result.returncode != 0 or "Editor Models section smoke check passed" not in result.stdout or "SCRIPT ERROR" in result.stderr:
            raise SystemExit("Editor model settings smoke test failed")
