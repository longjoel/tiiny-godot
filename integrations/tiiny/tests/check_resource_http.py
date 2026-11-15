#!/usr/bin/env python3
"""Exercise queued resource inference against the local HTTP fixture."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
from http_fixture import start

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"
server = start()
try:
    with tempfile.TemporaryDirectory(prefix="tiiny-resource-http-") as directory:
        project = Path(directory)
        addon = project / "addons/resource_test"
        addon.mkdir(parents=True)
        shutil.copyfile(root / "integrations/tiiny/tests/editor_resource_http.gd", addon / "plugin.gd")
        (addon / "plugin.cfg").write_text('[plugin]\nname="Resource Test"\ndescription="Fixture"\nauthor="Tiiny"\nversion="1"\nscript="plugin.gd"\n')
        (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Resource Test"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/resource_test/plugin.cfg")\n')
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("TIINY_"):
                del env[key]
        env.update(HOME=str(project / "home"), XDG_CONFIG_HOME=str(project / "config"), XDG_DATA_HOME=str(project / "data"), XDG_CACHE_HOME=str(project / "cache"), TIINY_TEST_HTTP_URL=f"http://127.0.0.1:{server.server_port}")
        result = subprocess.run([str(binary), "--headless", "--editor", "--path", str(project)], env=env, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        if result.returncode or "Queued resource loopback passed" not in output or "SCRIPT ERROR" in output:
            print(output)
            raise SystemExit(result.returncode or 1)
        print("Queued resource loopback passed")
finally:
    server.shutdown()
    server.server_close()
