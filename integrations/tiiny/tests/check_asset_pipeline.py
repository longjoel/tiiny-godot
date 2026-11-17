#!/usr/bin/env python3
"""Exercise queued image -> 3D failure/retry with a fake Tiiny endpoint."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
BINARY = ROOT / "bin/godot.linuxbsd.editor.x86_64"

with tempfile.TemporaryDirectory(prefix="tiiny-asset-pipeline-") as directory:
    project = Path(directory) / "project"
    addon = project / "addons/pipeline"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Tiiny pipeline test"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/pipeline/plugin.cfg")\n'
    )
    (addon / "plugin.cfg").write_text('[plugin]\nname="Pipeline"\ndescription="Fixture"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n')
    shutil.copyfile(ROOT / "integrations/tiiny/tests/editor_asset_pipeline.gd", addon / "plugin.gd")
    shutil.copyfile(ROOT / "integrations/tiiny/tests/fake_asset_pipeline_chat.gd", project / "fake_asset_pipeline_chat.gd")
    source = (ROOT / "editor/tiiny_ai_dock_source.h").read_text().split('R"TIINY_GD(\n', 1)[1].split(')TIINY_GD"', 1)[0]
    (project / "chat.gd").write_text(source)
    env = {key: value for key, value in os.environ.items() if not key.startswith("TIINY_")}
    env.update(HOME=str(project / "home"), XDG_CONFIG_HOME=str(project / "config"), XDG_DATA_HOME=str(project / "data"), XDG_CACHE_HOME=str(project / "cache"))
    result = subprocess.run([str(BINARY), "--headless", "--editor", "--path", str(project), "--rendering-method", "gl_compatibility"], env=env, capture_output=True, text=True, timeout=100)
    output = result.stdout + result.stderr
    if result.returncode or "Queued image-to-3D pipeline fixture passed." not in output or "SCRIPT ERROR" in output:
        print(output)
        raise SystemExit(result.returncode or 1)
    print("Queued image-to-3D pipeline fixture passed.")
