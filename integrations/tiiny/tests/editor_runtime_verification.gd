@tool
extends EditorPlugin

## Deterministic runtime-verification fixture. Builds nothing itself; it runs
## the real verify_scene_runtime tool against scenes in this disposable project
## and asserts both passing and failing evidence.

var dock: Node
var workspace: Object
var checks := 0
var failures := 0

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	failures += 1

func _approve(_args: Array, _root: String) -> bool:
	return true

func _deny(_args: Array, _root: String) -> bool:
	return false

func _expect(name: String, result: Dictionary, ok: bool, passed := true) -> void:
	checks += 1
	if bool(result.get("ok", false)) != ok:
		_fail("%s: expected ok=%s, got %s" % [name, ok, str(result)])
		return
	if ok and bool(result.get("data", {}).get("passed", true)) != passed:
		_fail("%s: expected passed=%s, got %s" % [name, passed, str(result)])
		return
	print("Runtime verification: %s %s" % [name, "passed" if ok else "rejected"])

func _run() -> void:
	for index in range(30):
		await get_tree().process_frame
	dock = get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if dock == null or not dock.has_method("_ensure_workspace_registry"):
		_fail("Tiiny dock is unavailable")
		get_tree().quit(1)
		return
	EditorInterface.get_editor_settings().set_setting("tiiny_ai/advanced/allow_shell_commands", true)
	EditorInterface.get_editor_settings().set_setting("tiiny_ai/advanced/tool_mode", "editor")
	dock.call("_ensure_workspace_registry")
	dock.call("_refresh_registry_availability")
	workspace = dock.workspace_coding
	if workspace == null:
		_fail("Workspace provider is unavailable")
		get_tree().quit(1)
		return
	workspace.allow_shell_commands = true
	workspace.approve_headless = Callable(self, "_approve")
	var names: Array = Array(dock.workspace_registry.tools_payload()).map(func(definition): return str(definition.function.name))
	if not "verify_scene_runtime" in names:
		_fail("verify_scene_runtime is not in the editor payload")
		get_tree().quit(1)
		return

	var passed: Dictionary = await dock.workspace_registry.execute("verify_scene_runtime", {
		"scene_path": "res://main.tscn",
		"frames": 180,
		"actions": [{"action": "jump", "frame": 90, "hold": 2}],
		"checks": ["scene_loads", "no_errors", "gravity", "lands", "jump"],
	}, {"call_id": "runtime-1"})
	_expect("platformer", passed, true, true)
	if bool(passed.get("ok", false)) and str(passed.get("call_id", "")) != "runtime-1":
		_fail("Tool result did not carry the call ID: " + str(passed))
	if bool(passed.get("ok", false)):
		var data: Dictionary = passed.get("data", {})
		var bodies: Array = data.get("bodies", [])
		var player: Dictionary = bodies[0] if not bodies.is_empty() else {}
		if bodies.is_empty() or str(player.get("path", "")) != "Player":
			_fail("Platformer evidence is missing the Player body: " + str(passed))
		elif not bool(data.get("checks", {}).get("gravity", {}).get("passed", false)):
			_fail("Gravity evidence is missing: " + str(passed))
		elif not bool(data.get("checks", {}).get("jump", {}).get("passed", false)):
			_fail("Jump evidence is missing: " + str(passed))

	var still: Dictionary = await workspace.execute("verify_scene_runtime", {
		"scene_path": "res://still.tscn",
		"frames": 60,
		"checks": ["scene_loads", "gravity", "lands", "jump"],
	})
	_expect("no gameplay fails checks", still, true, false)
	if bool(still.get("ok", false)):
		var failed: Array = still.get("data", {}).get("failed", [])
		for name in ["gravity", "lands", "jump"]:
			if not name in failed:
				_fail("Expected %s to fail on still.tscn, got %s" % [name, str(failed)])

	var broken: Dictionary = await workspace.execute("verify_scene_runtime", {
		"scene_path": "res://broken.tscn",
		"frames": 30,
		"checks": ["scene_loads", "no_errors"],
	})
	_expect("script errors fail checks", broken, true, false)
	if bool(broken.get("ok", false)) and not str(broken.get("data", {}).get("stderr", "")).contains("SCRIPT ERROR"):
		_fail("Script error output was not reported: " + str(broken))

	workspace.approve_headless = Callable(self, "_deny")
	var refused: Dictionary = await workspace.execute("verify_scene_runtime", {
		"scene_path": "res://main.tscn",
		"frames": 30,
		"checks": ["scene_loads"],
	})
	workspace.approve_headless = Callable(self, "_approve")
	if bool(refused.get("ok", true)) or str(refused.get("error", {}).get("code", "")) != "approval_required":
		_fail("Denied approval was not reported: " + str(refused))

	workspace.allow_shell_commands = false
	var gated: Dictionary = await workspace.execute("verify_scene_runtime", {
		"scene_path": "res://main.tscn",
		"frames": 30,
		"checks": ["scene_loads"],
	})
	workspace.allow_shell_commands = true
	if bool(gated.get("ok", true)) or str(gated.get("error", {}).get("code", "")) != "command_disabled":
		_fail("Disabled shell setting was not reported: " + str(gated))

	var bad_action: Dictionary = await workspace.execute("verify_scene_runtime", {
		"scene_path": "res://main.tscn",
		"actions": [{"action": "not_a_real_action", "frame": 30}],
	})
	if bool(bad_action.get("ok", true)) or str(bad_action.get("error", {}).get("code", "")) != "invalid_arguments":
		_fail("Unknown input action was not rejected: " + str(bad_action))

	var bad_check: Dictionary = await workspace.execute("verify_scene_runtime", {
		"scene_path": "res://main.tscn",
		"checks": ["definitely_not_a_check"],
	})
	if bool(bad_check.get("ok", true)) or str(bad_check.get("error", {}).get("code", "")) != "invalid_arguments":
		_fail("Unknown check was not rejected: " + str(bad_check))

	var missing: Dictionary = await workspace.execute("verify_scene_runtime", {"scene_path": "res://missing.tscn"})
	if bool(missing.get("ok", true)) or str(missing.get("error", {}).get("code", "")) != "not_found":
		_fail("Missing scene was not rejected: " + str(missing))

	var residue := 0
	var directory := DirAccess.open(ProjectSettings.globalize_path("user://tiiny_runtime"))
	if directory != null:
		for file in directory.get_files():
			residue += 1
	if residue != 0:
		_fail("Runtime probe files were not cleaned up: %d remain" % residue)

	if failures == 0:
		print("Runtime verification cases passed: ", checks)
		get_tree().quit(0)
	else:
		print("Runtime verification cases failed: ", failures)
		get_tree().quit(1)
