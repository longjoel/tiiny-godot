#!/usr/bin/env python3
"""Deterministic tool-selection corpus: fixed request -> expected tool call."""
from pathlib import Path
import os
import shutil
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / "bin/godot.linuxbsd.editor.x86_64"

SCENE = '''[gd_scene format=3]

[node name="Root" type="Node2D"]

[node name="Player" type="CharacterBody2D" parent="."]

[node name="Label" type="Label" parent="."]
offset_left = 8.0
offset_top = 8.0
text = "HUD"

[node name="Torch" type="Node2D" parent="."]

[node name="Light2D" type="Light2D" parent="Torch"]

[node name="World" type="Node3D" parent="."]
'''

SCRIPT = '''extends CharacterBody2D

const SPEED := 200.0
const GRAVITY := 900.0

func _physics_process(delta: float) -> void:
\tvelocity.x = Input.get_axis("move_left", "move_right") * SPEED
\tvelocity.y += GRAVITY * delta
\tmove_and_slide()
'''


def png_bytes() -> bytes:
    raw = (b"\x00" + b"\xff\x00\x00\xff" * 2) * 2
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    (project / "generated").mkdir()
    addon = project / "addons/tool_selection"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Tool Selection"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/tool_selection/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Tool Selection"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(ROOT / "integrations/tiiny/tests/editor_tool_selection.gd", addon / "plugin.gd")
    (project / "main.tscn").write_text(SCENE)
    (project / "player.gd").write_text(SCRIPT)
    (project / "generated/source.png").write_bytes(png_bytes())


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tiiny-tool-selection-") as directory:
        project = Path(directory) / "project"
        make_project(project)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("TIINY_"):
                del env[key]
        env.update(
            HOME=str(project / "home"),
            XDG_CONFIG_HOME=str(project / "config"),
            XDG_DATA_HOME=str(project / "data"),
            XDG_CACHE_HOME=str(project / "cache"),
        )
        try:
            result = subprocess.run(
                [str(BINARY), "--headless", "--editor", "--path", str(project), "--rendering-method", "gl_compatibility"],
                env=env,
                capture_output=True,
                text=True,
                timeout=240,
            )
        except subprocess.TimeoutExpired as error:
            print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
            print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
            raise
        output = result.stdout + result.stderr
        print(output[-14000:])
        if result.returncode or "Tool selection cases passed" not in output or "SCRIPT ERROR" in output:
            raise SystemExit(result.returncode or 1)
    print("Tool selection corpus passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
