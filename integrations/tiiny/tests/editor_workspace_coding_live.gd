@tool
extends EditorPlugin

## Gated live sample: the warm coding model uses workspace file tools in
## workspace mode, then typed editor tools in hybrid mode. This is a tool-choice
## trace, not a success-rate evaluation.

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _wait_for_scene(path: String) -> bool:
	for index in range(300):
		var root := EditorInterface.get_edited_scene_root()
		if root != null and root.scene_file_path == path:
			return true
		await get_tree().process_frame
	return false

func _run() -> void:
	for index in range(25):
		await get_tree().process_frame
	var dock := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
	var jobs := get_tree().get_first_node_in_group("tiiny_job_manager")
	var waiter = load("res://live_turn_wait.gd").new()
	if dock == null or manager == null or jobs == null or not jobs.available:
		_fail("Tiiny dock or manager unavailable")
		return
	await manager.refresh_device()
	if not manager.connected:
		_fail("Live device not connected: " + manager.message)
		return
	var models: Dictionary = manager.snapshot.get("models", {})
	var loaded: Array = manager.snapshot.get("loaded", {}).keys()
	var coding := ""
	for id in loaded:
		if manager.Planner.suitable("coding_model", models.get(id, {})):
			coding = str(id)
			break
	if coding.is_empty():
		_fail("No warm compatible coding model")
		return
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("tiiny_ai/models/coding_model", coding)
	var max_context := int(models.get(coding, {}).get("max_context", 0))
	settings.set_setting("tiiny_ai/models/context_tokens", max_context if max_context > 0 else 32768)
	settings.set_setting("tiiny_ai/advanced/request_timeout_seconds", 180)
	await manager.refresh_device()
	var warm_before: Array = manager.snapshot.get("loaded", {}).keys()
	warm_before.sort()

	settings.set_setting("tiiny_ai/advanced/tool_mode", "workspace")
	dock.call("_ensure_workspace_registry")
	dock.call("_refresh_registry_availability")
	var workspace_tools: Array = Array(dock.workspace_registry.tools_payload()).map(func(tool): return str(tool.function.name))
	if "list_files" not in workspace_tools or "apply_editor_transaction" in workspace_tools:
		_fail("Live workspace payload is wrong: " + str(workspace_tools))
		return
	print("Live workspace tool names: ", workspace_tools)
	dock.prompt.text = "Workspace coding mode is active. Use read_file on res://player.gd, then use apply_patch or write_file with the returned SHA-256 to change `const SPEED := 200.0` to `const SPEED := 300.0`. Do not create a scene node and do not use create_gdscript."
	var before_submit: int = jobs.queue.snapshot().jobs.size()
	dock.call("_generate")
	var queued: Array = jobs.queue.snapshot().jobs
	if queued.size() != before_submit + 1:
		_fail("Workspace coding turn was not submitted: " + dock.status.text)
		return
	if not await waiter.wait_for_turn(get_tree(), jobs, str(queued.back().id), 600000):
		_fail("Workspace coding turn did not complete: " + waiter.reason)
		return
	var source := FileAccess.get_file_as_string("res://player.gd")
	if not source.contains("const SPEED := 300.0"):
		_fail("Live workspace turn did not edit the script. Ledger: " + str(dock.turn_ledger) + " status: " + dock.status.text)
		return
	var file_tools := ["read_file", "read_project_file"]
	var edit_tools := ["apply_patch", "write_file", "replace_in_gdscript"]
	if not Array(dock.turn_ledger).any(func(entry): return entry.tool in file_tools and entry.ok):
		_fail("The live turn did not read the file first: " + str(dock.turn_ledger))
		return
	if not Array(dock.turn_ledger).any(func(entry): return entry.tool in edit_tools and entry.ok):
		_fail("The live turn did not use a workspace edit tool: " + str(dock.turn_ledger))
		return
	var workspace_ledger: Array = dock.turn_ledger.duplicate(true)

	settings.set_setting("tiiny_ai/advanced/tool_mode", "hybrid")
	EditorInterface.open_scene_from_path("res://main.tscn")
	if not await _wait_for_scene("res://main.tscn"):
		_fail("Live scene did not open")
		return
	dock.call("_refresh_registry_availability")
	var root := EditorInterface.get_edited_scene_root()
	dock.prompt.text = "Use apply_editor_transaction with exactly one create_node operation to create a Label named ScoreLabel under the scene root with text \"Score: 0\". Use exactly that tool and do not write a script."
	before_submit = jobs.queue.snapshot().jobs.size()
	dock.call("_generate")
	queued = jobs.queue.snapshot().jobs
	if queued.size() != before_submit + 1:
		_fail("Hybrid editor turn was not submitted: " + dock.status.text)
		return
	if not await waiter.wait_for_turn(get_tree(), jobs, str(queued.back().id), 600000):
		_fail("Hybrid editor turn did not complete: " + waiter.reason)
		return
	var label := root.get_node_or_null("ScoreLabel") as Label
	if label == null or label.text != "Score: 0":
		_fail("Live hybrid turn did not create the Label. Ledger: " + str(dock.turn_ledger))
		return
	if not Array(dock.turn_ledger).any(func(entry): return entry.tool == "apply_editor_transaction" and entry.ok):
		_fail("Hybrid turn did not use the typed transaction: " + str(dock.turn_ledger))
		return
	await manager.refresh_device()
	var warm_after: Array = manager.snapshot.get("loaded", {}).keys()
	warm_after.sort()
	if warm_after != warm_before:
		_fail("Live coding turns changed model residency")
		return
	print("Live workspace coding trace passed with ", coding, "; workspace ledger: ", workspace_ledger, "; hybrid ledger: ", dock.turn_ledger)
	settings.set_setting("tiiny_ai/advanced/tool_mode", "editor")
	get_tree().quit(0)
