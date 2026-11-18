#!/usr/bin/env python3
"""Run the deterministic runtime-verification fixture in a disposable editor."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / "bin/godot.linuxbsd.editor.x86_64"

PLAYER = '''extends CharacterBody2D

const GRAVITY := 1000.0
const JUMP := -380.0

func _physics_process(delta: float) -> void:
\tvelocity.y += GRAVITY * delta
\tif Input.is_action_just_pressed("jump") and is_on_floor():
\t\tvelocity.y = JUMP
\tmove_and_slide()
'''

BROKEN = '''extends CharacterBody2D

func _ready() -> void:
\tvar broken = null
\tbroken.nope()
'''


def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/runtime_verification"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Runtime Verification"\nrun/main_scene="res://main.tscn"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/runtime_verification/plugin.cfg")\n'
        '[input]\njump={\n"deadzone": 0.5,\n"events": []\n}\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Runtime Verification"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(ROOT / "integrations/tiiny/tests/editor_runtime_verification.gd", addon / "plugin.gd")
    (project / "player.gd").write_text(PLAYER)
    (project / "broken.gd").write_text(BROKEN)
    (project / "main.tscn").write_text(
        '[gd_scene load_steps=4 format=3]\n\n'
        '[ext_resource type="Script" path="res://player.gd" id="1"]\n\n'
        '[sub_resource type="RectangleShape2D" id="player_shape"]\nsize = Vector2(24, 24)\n\n'
        '[sub_resource type="RectangleShape2D" id="platform_shape"]\nsize = Vector2(240, 24)\n\n'
        '[node name="Root" type="Node2D"]\n\n'
        '[node name="Player" type="CharacterBody2D" parent="."]\nposition = Vector2(320, 80)\nscript = ExtResource("1")\n\n'
        '[node name="CollisionShape2D" type="CollisionShape2D" parent="Player"]\nshape = SubResource("player_shape")\n\n'
        '[node name="Platform" type="StaticBody2D" parent="."]\nposition = Vector2(320, 320)\n\n'
        '[node name="CollisionShape2D" type="CollisionShape2D" parent="Platform"]\nshape = SubResource("platform_shape")\n'
    )
    (project / "still.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n\n'
        '[node name="Prop" type="CharacterBody2D" parent="."]\nposition = Vector2(64, 64)\n'
    )
    (project / "broken.tscn").write_text(
        '[gd_scene load_steps=2 format=3]\n\n'
        '[ext_resource type="Script" path="res://broken.gd" id="1"]\n\n'
        '[node name="Root" type="Node2D"]\n\n'
        '[node name="Broken" type="CharacterBody2D" parent="."]\nscript = ExtResource("1")\n'
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tiiny-runtime-verification-") as directory:
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
                timeout=300,
            )
        except subprocess.TimeoutExpired as error:
            print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
            print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
            raise
        output = result.stdout + result.stderr
        print(output[-16000:])
        if result.returncode or "Runtime verification cases passed" not in output:
            raise SystemExit(result.returncode or 1)
    print("Runtime verification fixture passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
