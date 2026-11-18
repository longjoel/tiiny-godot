#!/usr/bin/env python3
"""Run the pure and editor fixtures for the story 18 workspace coding tools."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"


def pure_fixture() -> None:
    result = subprocess.run(
        [str(binary), "--headless", "--path", str(root), "--script", "integrations/tiiny/tests/test_workspace_tools.gd"],
        cwd=root,
        capture_output=True,
        text=True,
        timeout=300,
    )
    output = result.stdout + result.stderr
    if result.returncode or "Workspace tools pure fixture passed." not in output:
        print(output)
        raise SystemExit(result.returncode or 1)
    print("Workspace tools pure fixture passed.")


def make_project(project: Path) -> None:
    project.mkdir(parents=True)
    addon = project / "addons/workspace_tools_test"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Workspace Tools Editor Test"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/workspace_tools_test/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text(
        '[plugin]\nname="Workspace Tools Editor Test"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n'
    )
    shutil.copyfile(root / "integrations/tiiny/tests/editor_workspace_tools.gd", addon / "plugin.gd")
    chat_source = (root / "editor/tiiny_ai_dock_source.h").read_text().split('R"TIINY_GD(\n', 1)[1].split(')TIINY_GD"', 1)[0]
    (project / "chat.gd").write_text(chat_source)
    shutil.copyfile(root / "integrations/tiiny/tests/fake_chat.gd", project / "fake_chat.gd")
    (project / "dirty.tscn").write_text(
        '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="PackedScene" path="res://instance.tscn" id="1"]\n\n[node name="DirtyRoot" type="Node2D"]\n\n'
        '[node name="Label" type="Label" parent="."]\n'
        'text = "saved text"\n\n[node name="Instance" parent="." instance=ExtResource("1")]\n'
    )
    (project / "instance.tscn").write_text('[gd_scene format=3]\n\n[node name="InstanceRoot" type="Node2D"]\n\n[node name="Inner" type="Node2D" parent="."]\n')
    (project / "other.tscn").write_text('[gd_scene format=3]\n\n[node name="OtherRoot" type="Node2D"]\n')


def editor_fixture() -> None:
    with tempfile.TemporaryDirectory(prefix="tiiny-workspace-tools-editor-") as directory:
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
                [str(binary), "--headless", "--editor", "--path", str(project), "--rendering-method", "gl_compatibility"],
                env=env,
                capture_output=True,
                text=True,
                timeout=180,
            )
        except subprocess.TimeoutExpired as error:
            print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
            print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
            raise
        output = result.stdout + result.stderr
        expected_parse = output.count("SCRIPT ERROR: Parse Error: Expected parameter name.")
        # The replace_in_gdscript fixture deliberately submits an unknown method
        # and asserts the tool result, not the engine diagnostic.
        expected_replace = output.count('SCRIPT ERROR: Parse Error: Function "move_and_slide()" not found in base self.')
        errors = output.count("SCRIPT ERROR") - expected_parse - expected_replace
        progress_error = "Do not use progress dialog" in output or "!tasks.has(p_task)" in output
        if result.returncode or "Workspace coding editor integration passed." not in output or errors or expected_parse != 1 or expected_replace != 1 or progress_error:
            print(output)
            raise SystemExit(result.returncode or 1)
        print("Workspace coding editor integration passed.")


if __name__ == "__main__":
    pure_fixture()
    editor_fixture()
