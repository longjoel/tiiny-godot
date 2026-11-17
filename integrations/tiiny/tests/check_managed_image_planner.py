#!/usr/bin/env python3
"""Exercise the real model planner and journal with fake device transport."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"
with tempfile.TemporaryDirectory(prefix="tiiny-managed-image-") as directory:
    project = Path(directory) / "project"
    addon = project / "addons/managed_image"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Managed Image Test"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/managed_image/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text('[plugin]\nname="Managed Image"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n')
    for source, target in [
        ("editor_managed_image_planner.gd", addon / "plugin.gd"),
        ("fake_model_manager.gd", project / "fake_model_manager.gd"),
        ("fake_asset_pipeline_chat.gd", project / "fake_asset_pipeline_chat.gd"),
    ]:
        shutil.copyfile(root / "integrations/tiiny/tests" / source, target)
    for source, target in [("editor/tiiny_ai_dock_source.h", "chat.gd"), ("editor/tiiny_ai_manager_source.h", "manager.gd")]:
        text = (root / source).read_text().split('R"TIINY_GD(\n', 1)[1].split(')TIINY_GD"', 1)[0]
        (project / target).write_text(text)
    env = {key: value for key, value in os.environ.items() if not key.startswith("TIINY_")}
    env.update(HOME=str(project / "home"), XDG_CONFIG_HOME=str(project / "config"), XDG_DATA_HOME=str(project / "data"), XDG_CACHE_HOME=str(project / "cache"))
    result = subprocess.run([str(binary), "--headless", "--editor", "--path", str(project), "--rendering-method", "gl_compatibility"], env=env, capture_output=True, text=True, timeout=100)
    output = result.stdout + result.stderr
    if result.returncode or "Managed image planner fixture passed." not in output or "SCRIPT ERROR" in output:
        print(output)
        raise SystemExit(result.returncode or 1)
    print("Managed image planner fixture passed.")
