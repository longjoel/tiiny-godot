#!/usr/bin/env python3
"""Displayed editor captures for the story 18 tool-mode switch."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / "bin/godot.linuxbsd.editor.x86_64"
CAPTURES = [Path("/tmp/tiiny-story18-mode-workspace.png"), Path("/tmp/tiiny-story18-mode-hybrid.png")]


def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/workspace_display"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Workspace Display"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/workspace_display/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Workspace Display"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(ROOT / "integrations/tiiny/tests/editor_workspace_displayed.gd", addon / "plugin.gd")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tiiny-workspace-display-") as directory:
        project = Path(directory) / "project"
        make_project(project)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("TIINY_"):
                del env[key]
        env["DISPLAY"] = ":0"
        try:
            result = subprocess.run(
                [str(BINARY), "--editor", "--path", str(project), "--display-driver", "x11", "--rendering-method", "gl_compatibility"],
                env=env,
                capture_output=True,
                text=True,
                timeout=150,
            )
        except subprocess.TimeoutExpired as error:
            print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
            print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
            raise
        output = result.stdout + result.stderr
        if result.returncode or "Displayed workspace mode capture passed" not in output or "SCRIPT ERROR" in output:
            print(output)
            raise SystemExit(result.returncode or 1)
    missing = [path for path in CAPTURES if not path.exists() or path.stat().st_size < 1000]
    if missing:
        raise SystemExit("Missing displayed captures: " + ", ".join(map(str, missing)))
    print("Displayed workspace mode captures passed:", ", ".join(f"{path} ({path.stat().st_size} bytes)" for path in CAPTURES))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
