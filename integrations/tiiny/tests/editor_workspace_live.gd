@tool
extends EditorPlugin

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
	for index in range(20): await get_tree().process_frame
	var dock := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
	if dock == null or manager == null: _fail("Tiiny dock or manager unavailable"); return
	await manager.refresh_device()
	if not manager.connected: _fail("Live device not connected: " + manager.message); return
	var models: Dictionary = manager.snapshot.get("models", {})
	var loaded: Array = manager.snapshot.get("loaded", {}).keys()
	var coding := ""
	for id in loaded:
		if manager.Planner.suitable("coding_model", models.get(id, {})):
			coding = str(id)
			break
	if coding.is_empty(): _fail("No warm compatible coding model"); return
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("tiiny_ai/models/coding_model", coding)
	settings.set_setting("tiiny_ai/models/context_tokens", 32768)
	settings.set_setting("tiiny_ai/advanced/request_timeout_seconds", 180)
	await manager.refresh_device()

	EditorInterface.open_scene_from_path("res://main.tscn")
	if not await _wait_for_scene("res://main.tscn"): _fail("Live scene did not open"); return
	var root := EditorInterface.get_edited_scene_root()
	if root.get_node_or_null("Player") == null: _fail("Live fixture player missing"); return
	var before_warm: Array = manager.snapshot.get("loaded", {}).keys()
	before_warm.sort()

	dock._ensure_workspace_registry()
	dock._refresh_registry_availability()
	print("Live tool names: ", Array(dock.workspace_registry.tools_payload()).map(func(tool): return str(tool.function.name)))
	dock.prompt.text = "Call add_rectangular_collision_shape with parent_path Player, width 32, height 48. Use exactly that tool. Do not call append_job and do not write a script."
	dock._generate()
	var deadline := Time.get_ticks_msec() + 240000
	while Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.5).timeout
		var shape := root.get_node_or_null("Player/CollisionShape2D")
		if not dock.send_button.disabled and not shape == null:
			break
	var shape := root.get_node_or_null("Player/CollisionShape2D")
	if shape == null or not shape.shape is RectangleShape2D or shape.shape.size != Vector2(32, 48):
		print("Live turn messages: ", dock.turn_messages)
		_fail("Live model did not produce the recipe. Ledger: " + str(dock.turn_ledger) + " status: " + dock.status.text)
		return
	if not Array(dock.turn_ledger).any(func(entry): return entry.tool == "add_rectangular_collision_shape" and entry.ok):
		_fail("Live recipe was not recorded in the ledger: " + str(dock.turn_ledger)); return
	var manager_undo := EditorInterface.get_editor_undo_redo()
	var history_id: int = manager_undo.get_object_history_id(root)
	var history = manager_undo.get_history_undo_redo(history_id)
	if not history.undo() or root.get_node_or_null("Player/CollisionShape2D") != null:
		_fail("Live recipe undo failed"); return
	await manager.refresh_device()
	var after_warm: Array = manager.snapshot.get("loaded", {}).keys()
	after_warm.sort()
	if after_warm != before_warm: _fail("Live recipe changed model residency"); return
	print("Live workspace recipe passed with ", coding, "; tool ledger: ", dock.turn_ledger, "; warm set unchanged.")
	get_tree().quit()
