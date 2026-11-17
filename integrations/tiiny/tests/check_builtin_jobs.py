#!/usr/bin/env python3
"""Exercise the embedded Jobs panel in a disposable editor project."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
binary = root / "bin/godot.linuxbsd.editor.x86_64"
def make_project(project):
    project.mkdir(parents=True)
    (project / "assets").mkdir()
    (project / "target.tscn").write_text('[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n')
    chat_source = (root / "editor/tiiny_ai_dock_source.h").read_text().split('R"TIINY_GD(\n', 1)[1].split(')TIINY_GD"', 1)[0]
    (project / "chat.gd").write_text(chat_source)
    manager_source = (root / "editor/tiiny_ai_manager_source.h").read_text().split('R"TIINY_GD(\n', 1)[1].split(')TIINY_GD"', 1)[0]
    (project / "manager.gd").write_text(manager_source)
    shutil.copyfile(root / "integrations/tiiny/tests/fake_model_manager.gd", project / "fake_model_manager.gd")
    shutil.copyfile(root / "integrations/tiiny/tests/fake_queued_chat.gd", project / "fake_queued_chat.gd")
    shutil.copyfile(root / "integrations/tiiny/tests/fake_restore_chat.gd", project / "fake_restore_chat.gd")
    addon = project / "addons/jobs_test"
    addon.mkdir(parents=True)
    shutil.copyfile(root / "integrations/tiiny/tests/editor_builtin_jobs.gd", addon / "plugin.gd")
    (addon / "plugin.cfg").write_text('[plugin]\nname="Jobs Test"\ndescription="Fixture"\nauthor="Tiiny"\nversion="1"\nscript="plugin.gd"\n')
    (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Jobs Test"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/jobs_test/plugin.cfg")\n')

def run_modes(project, modes):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("TIINY_"):
            del env[key]
    env.update(HOME=str(project / "home"), XDG_CONFIG_HOME=str(project / "config"), XDG_DATA_HOME=str(project / "data"), XDG_CACHE_HOME=str(project / "cache"))
    for mode in modes:
        env["TIINY_JOBS_TEST_MODE"] = mode
        try:
            result = subprocess.run([str(binary), "--headless", "--editor", "--path", str(project)], env=env, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired as error:
            print((error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or "")
            print((error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or "")
            raise
        output = result.stdout + result.stderr
        if result.returncode or f"Built-in Jobs {mode} passed" not in output or "SCRIPT ERROR" in output:
            print(output)
            raise SystemExit(result.returncode or 1)
        print(f"Built-in Jobs {mode} passed")

with tempfile.TemporaryDirectory(prefix="tiiny-builtin-jobs-") as directory:
    for name, modes in (("normal", ("create", "restore")), ("queued_cancel", ("queued_cancel",)), ("stale", ("stale",)), ("missing", ("missing",)), ("scene_recovery", ("scene_recovery",)), ("scene_restart", ("scene_prepare", "scene_restore")), ("chat", ("chat", "chat_restore")), ("chat_protocol", ("chat_protocol",)), ("chat_second_request_uncertain", ("chat_second_request_uncertain",)), ("chat_image_uncertain", ("chat_image_uncertain",)), ("chat_image_handoff", ("chat_image_handoff",)), ("chat_image_stale", ("chat_image_stale",)), ("chat_chain", ("chat_chain",)), ("chat_chain_restart", ("chat_chain_prepare", "chat_chain_restore")), ("device_acknowledge", ("device_acknowledge",)), ("queue_resume", ("queue_resume",)), ("chat_truncation", ("chat_truncation",)), ("chat_empty", ("chat_empty",)), ("chat_abandon", ("chat_abandon",)), ("resource_cancel", ("resource_cancel",)), ("worker_append", ("worker_append",)), ("model_apply", ("model_apply",)), ("model_apply_restore", ("model_apply_restore",)), ("model_wait_cancel", ("model_wait_cancel",)), ("model_failed", ("model_failed", "model_failed_restore")), ("model_restore", ("model_restore",)), ("model_restore_download", ("model_restore_download",)), ("model_restore_capacity", ("model_restore_capacity",)), ("model_preflight", ("model_preflight",)), ("model_preflight_stale", ("model_preflight_stale",)), ("model_resource_preflight", ("model_resource_preflight",)), ("model_resource_preflight_stale", ("model_resource_preflight_stale",)), ("model_preflight_cancel", ("model_preflight_cancel",)), ("model_restore_stale", ("model_restore_stale",)), ("model_schedule", ("model_schedule",)), ("model_schedule_capacity", ("model_schedule_capacity",)), ("model_schedule_restore", ("model_schedule_restore",)), ("model_schedule_disconnect", ("model_schedule_disconnect",))):
        if os.environ.get("TIINY_JOBS_ONLY_MODE") and name != os.environ["TIINY_JOBS_ONLY_MODE"]:
            continue
        project = Path(directory) / name
        make_project(project)
        run_modes(project, modes)
