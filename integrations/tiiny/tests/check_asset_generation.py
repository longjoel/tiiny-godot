#!/usr/bin/env python3
"""Live-device fixture for generator-backed 3D/audio asset jobs."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"

def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/asset_test"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Tiiny Asset Test"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/asset_test/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Tiiny Asset Test"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    (project / "speech_scene.tscn").write_text('[gd_scene format=3]\n\n[node name="SpeechScene" type="Node"]\n')
    shutil.copyfile(root / "integrations/tiiny/tests/editor_asset_generation.gd", addon / "plugin.gd")
    image = Image.new("RGB", (512, 512), (235, 235, 235))
    draw = ImageDraw.Draw(image)
    draw.ellipse((96, 96, 416, 416), fill=(220, 120, 50), outline=(70, 35, 20), width=8)
    draw.rectangle((200, 200, 312, 312), fill=(245, 185, 95))
    image.save(project / "reference.png")

with tempfile.TemporaryDirectory(prefix="tiiny-asset-live-") as directory:
    project = Path(directory) / "project"
    make_project(project)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("TIINY_"):
            del env[key]
    try:
        result = subprocess.run(
            [str(binary), "--headless", "--editor", "--path", str(project)],
            env=env,
            capture_output=True,
            text=True,
            timeout=1200,
        )
    except subprocess.TimeoutExpired as error:
        print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
        print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
        raise
    output = result.stdout + result.stderr
    if result.returncode or "Tiiny live asset generation passed." not in output or "SCRIPT ERROR" in output:
        print(output)
        raise SystemExit(result.returncode or 1)
    for line in output.splitlines():
        if "Live " in line:
            print(line)
    print("Tiiny live asset generation passed.")
