@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _error_code(result: Dictionary) -> String:
	return str(result.get("error", {}).get("code", ""))

func _wait_for_scene(path: String) -> bool:
	for index in range(300):
		var root := EditorInterface.get_edited_scene_root()
		if root != null and root.scene_file_path == path:
			return true
		await get_tree().process_frame
	return false

func _history(root: Node) -> Array:
	var manager := EditorInterface.get_editor_undo_redo()
	var history_id: int = manager.get_object_history_id(root)
	return [manager, history_id, manager.get_history_undo_redo(history_id)]

func _version(root: Node) -> int:
	var pair: Array = _history(root)
	var history = pair[2]
	return int(history.get_version()) if history != null else -1

func _run() -> void:
	for index in range(20): await get_tree().process_frame
	var dock := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if dock == null:
		_fail("Tiiny dock is missing")
		return
	var script = dock.get("workspace_inspector_script")
	if script == null or not script is Script:
		_fail("Workspace inspector script was not injected into the dock")
		return
	var inspector = script.new()
	if inspector == null or not inspector.has_method("execute"):
		_fail("Workspace inspector script could not be instantiated")
		return
	if not inspector.definitions() is Array or inspector.definitions().size() != 7:
		_fail("Workspace inspector definitions are incomplete")
		return

	EditorInterface.open_scene_from_path("res://main.tscn")
	if not await _wait_for_scene("res://main.tscn"):
		_fail("Main fixture scene did not open")
		return
	var root := EditorInterface.get_edited_scene_root()
	var player := root.get_node_or_null("Player")
	if player == null:
		_fail("Fixture player is missing")
		return
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(player)

	var context: Dictionary = inspector.execute("get_workspace_context", {})
	if not context.get("ok", false) or context.data.scene.path != "res://main.tscn" or context.data.selected_count != 1:
		_fail("Workspace context failed: " + str(context))
		return
	var old_context: Dictionary = context.data.scene.duplicate(true)
	var tree: Dictionary = inspector.execute("get_scene_tree", {"max_depth": 4, "max_nodes": 100})
	if not tree.get("ok", false):
		_fail("Scene tree failed: " + str(tree))
		return
	var enemy: Dictionary = {}
	for entry in tree.data.nodes:
		if entry.path == "Enemy": enemy = entry
		if entry.path == "Player" and entry.owner != ".":
			_fail("Player ownership is wrong: " + str(entry))
			return
	if enemy.is_empty() or enemy.scene_file_path != "res://instance.tscn":
		_fail("Instanced scene metadata is wrong: " + str(enemy))
		return
	if not Array(tree.data.nodes).any(func(entry): return entry.path == "Enemy/Turret"):
		_fail("Instanced child was not traversed")
		return

	var node: Dictionary = inspector.execute("inspect_node", {"path": "Player", "max_properties": 200})
	if not node.get("ok", false) or node.data.node.owner != ".":
		_fail("Node inspection failed: " + str(node))
		return
	if not Array(node.data.properties).any(func(entry): return entry.name == "position" and entry.type == "Vector2"):
		_fail("Node properties are missing position")
		return
	var embedded: Dictionary = inspector.execute("inspect_resource", {"node_path": "Player/Shape", "property": "shape"})
	if not embedded.get("ok", false) or embedded.data.resource.class != "RectangleShape2D" or not embedded.data.resource.embedded:
		_fail("Embedded resource inspection failed: " + str(embedded))
		return
	var saved: Dictionary = inspector.execute("inspect_resource", {"path": "res://rectangle.tres"})
	if not saved.get("ok", false) or saved.data.resource.path != "res://rectangle.tres":
		_fail("Saved resource inspection failed: " + str(saved))
		return
	if not inspector.execute("list_signals", {"path": "Player"}).get("ok", false):
		_fail("Signal inspection failed")
		return

	var hash_before := FileAccess.get_sha256("res://main.tscn")
	var version_before := _version(root)
	var count_before := root.get_child_count()
	for definition in inspector.definitions():
		var name := str(definition.name)
		var arguments := {}
		if name == "inspect_node" or name == "list_signals": arguments = {"path": "Player"}
		elif name == "inspect_resource": arguments = {"path": "res://rectangle.tres"}
		if not inspector.execute(name, arguments).get("ok", false):
			_fail("Read-only tool failed: " + name)
			return
	if FileAccess.get_sha256("res://main.tscn") != hash_before or _version(root) != version_before or root.get_child_count() != count_before:
		_fail("Inspection changed the scene or undo state")
		return

	var pair: Array = _history(root)
	var manager = pair[0]
	var history = pair[2]
	manager.create_action("workspace-inspector-fixture", UndoRedo.MERGE_DISABLE, root)
	manager.add_do_method(player, "set_position", Vector2(90, 90))
	manager.add_undo_method(player, "set_position", player.position)
	manager.commit_action()
	var dirty: Dictionary = inspector.execute("get_workspace_context", {})
	if not dirty.get("ok", false) or not dirty.data.scene.dirty or dirty.data.scene.session_revision == old_context.session_revision:
		_fail("Dirty scene did not expose a changed session revision: " + str(dirty))
		return
	if _error_code(inspector.execute("get_scene_revision", {})) != "scene_dirty":
		_fail("Attachment revision did not reject a dirty scene")
		return
	if _error_code(inspector.execute("get_workspace_context", {}, old_context)) != "stale_scene":
		_fail("Changed session revision was not stale")
		return
	history.undo()
	if inspector.execute("get_workspace_context", {}).data.scene.dirty:
		_fail("Undo did not restore a clean scene")
		return

	EditorInterface.open_scene_from_path("res://base.tscn")
	if not await _wait_for_scene("res://base.tscn"):
		_fail("Base fixture scene did not open")
		return
	if _error_code(inspector.execute("get_workspace_context", {}, old_context)) != "stale_scene":
		_fail("Scene switch was not stale")
		return

	EditorInterface.open_scene_from_path("res://inherited.tscn")
	if not await _wait_for_scene("res://inherited.tscn"):
		_fail("Inherited fixture scene did not open")
		return
	var inherited_root := EditorInterface.get_edited_scene_root()
	if inherited_root.scene_file_path != "res://inherited.tscn":
		_fail("Inherited scene path is wrong")
		return
	var inherited_tree: Dictionary = inspector.execute("get_scene_tree", {"max_depth": 3})
	if not inherited_tree.get("ok", false) or not Array(inherited_tree.data.nodes).any(func(entry): return entry.path == "Extra"):
		_fail("Inherited scene tree failed: " + str(inherited_tree))
		return

	EditorInterface.open_scene_from_path("res://main.tscn")
	if not await _wait_for_scene("res://main.tscn"):
		_fail("Main scene did not reopen")
		return
	EditorInterface.play_custom_scene("res://running.tscn")
	var playing := false
	for index in range(200):
		if EditorInterface.is_playing_scene():
			playing = true
			break
		await get_tree().create_timer(0.05).timeout
	if playing:
		var running: Dictionary = inspector.execute("get_workspace_context", {})
		if not running.get("ok", false) or not running.data.scene.playing or running.data.scene.path != "res://main.tscn":
			_fail("Running scene confused edited-scene inspection: " + str(running))
			return
		EditorInterface.stop_playing_scene()
		for index in range(100):
			if not EditorInterface.is_playing_scene(): break
			await get_tree().create_timer(0.05).timeout
	else:
		print("Running-scene inspection skipped: play did not start in this headless run.")

	print("Workspace inspector editor integration passed.")
	get_tree().quit()
