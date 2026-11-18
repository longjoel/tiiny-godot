@tool
extends EditorPlugin

## Deterministic tool-selection corpus. Each case is a fixed user request paired
## with the tool call a correct planner should choose. The real registry executes
## the call and the fixture checks the result and editor state.

var dock: Node
var registry: Object
var root: Node
var failures := 0
var case_index := 0

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	failures += 1

func _save() -> void:
	await get_tree().process_frame
	var error := EditorInterface.save_scene()
	if error != OK:
		_fail("Could not save the fixture scene (error %d)" % error)

func _case(request: String, mode: String, tool: String, arguments: Dictionary, verify := Callable()) -> void:
	case_index += 1
	EditorInterface.get_editor_settings().set_setting("tiiny_ai/advanced/tool_mode", mode)
	registry.set_tool_mode(mode)
	dock.call("_refresh_registry_availability")
	var names: Array = Array(registry.tools_payload()).map(func(definition): return str(definition.function.name))
	if not tool in names:
		_fail("Selected tool is not in the %s payload: %s" % [mode, tool])
		return
	var result: Dictionary = await registry.execute(tool, arguments, {"call_id": "selection-%d" % case_index})
	if not bool(result.get("ok", false)) or str(result.get("tool", "")) != tool or str(result.get("call_id", "")) != "selection-%d" % case_index:
		_fail("Tool selection case failed: " + request + " -> " + tool + " " + str(result))
		return
	if verify.is_valid() and not bool(verify.call(result)):
		_fail("Tool selection state check failed: " + request + " -> " + tool + " " + str(result))
		return
	print("Tool selection: %s -> %s (case %d)" % [request, tool, case_index])

func _run() -> void:
	for index in range(30): await get_tree().process_frame
	dock = get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if dock == null or not dock.has_method("_ensure_workspace_registry"):
		_fail("Tiiny dock is unavailable")
		get_tree().quit(1)
		return
	dock.call("_ensure_workspace_registry")
	registry = dock.workspace_registry
	if registry == null:
		_fail("Workspace registry is unavailable")
		get_tree().quit(1)
		return
	EditorInterface.open_scene_from_path("res://main.tscn")
	for index in range(120):
		root = EditorInterface.get_edited_scene_root()
		if root != null and root.scene_file_path == "res://main.tscn": break
		await get_tree().process_frame
	if root == null:
		_fail("Could not open the fixture scene")
		get_tree().quit(1)
		return
	for index in range(120):
		if ResourceLoader.exists("res://generated/source.png"): break
		EditorInterface.get_resource_filesystem().scan()
		await get_tree().process_frame
	if not ResourceLoader.exists("res://generated/source.png"):
		_fail("Generated source image was not imported")
		get_tree().quit(1)
		return

	await _case("Inspect the open scene", "editor", "get_scene_tree", {}, func(result): return Array(result.data.nodes).size() >= 1)
	await _case("Inspect the player node", "editor", "inspect_node", {"path": "Player"}, func(result): return str(result.data.node.path) == "Player")
	await _case("Describe the workspace context", "editor", "get_workspace_context", {}, func(result): return not str(result.data.scene.path).is_empty())
	await _case("Read project display settings", "editor", "get_project_settings", {}, func(result): return result.data.settings.has("display/window/size/viewport_width"))

	await _case("Add a label showing the score", "editor", "apply_editor_transaction", {"operations": [
		{"op": "create_node", "class": "Label", "name": "SelectionLabel", "parent": ".", "properties": {"text": "Score: 0", "position": [10, 20]}},
	]}, func(_result): return root.get_node_or_null("SelectionLabel") is Label and root.get_node("SelectionLabel").text == "Score: 0")
	await _save()

	await _case("Create a sprite from the generated player image", "editor", "add_sprite_from_image", {"path": "res://generated/source.png", "parent_path": ".", "node_name": "SelectedSprite"}, func(_result): return root.get_node_or_null("SelectedSprite") is Sprite2D and root.get_node("SelectedSprite").texture != null)
	await _save()

	await _case("Create a blue player body from colored rectangles", "editor", "add_rectangle_body", {"node_name": "SelectedPlayerBody", "body_class": "CharacterBody2D", "width": 32, "height": 48, "position_x": 100, "position_y": 300, "color": "#3366ff"}, func(_result): return root.get_node_or_null("SelectedPlayerBody") is CharacterBody2D and root.get_node_or_null("SelectedPlayerBody/Visual") is Polygon2D and root.get_node_or_null("SelectedPlayerBody/CollisionShape2D") is CollisionShape2D)
	await _save()
	await _case("Create a green static platform from colored rectangles", "editor", "add_rectangle_body", {"node_name": "SelectedPlatformBody", "body_class": "StaticBody2D", "width": 200, "height": 24, "position_x": 320, "position_y": 430, "color": "#33aa55"}, func(_result): return root.get_node_or_null("SelectedPlatformBody") is StaticBody2D and root.get_node_or_null("SelectedPlatformBody/Visual") is Polygon2D and root.get_node_or_null("SelectedPlatformBody/CollisionShape2D") is CollisionShape2D)
	await _save()

	await _case("Add a rectangular collision shape to the player", "editor", "add_rectangular_collision_shape", {"parent_path": "Player", "width": 32, "height": 48, "node_name": "SelectedCollision"}, func(_result): return root.get_node_or_null("Player/SelectedCollision") is CollisionShape2D and root.get_node("Player/SelectedCollision").shape is RectangleShape2D)
	await _save()

	await _case("Add smoke particles", "editor", "add_particles_2d", {"parent_path": ".", "node_name": "SelectedParticles"}, func(_result): return root.get_node_or_null("SelectedParticles") is GPUParticles2D)
	await _save()

	await _case("Add torch flicker to the light", "editor", "add_torch_flicker", {"parent_path": "Torch", "light_path": "Torch/Light2D", "player_name": "TorchPlayer"}, func(_result): return root.get_node_or_null("Torch/TorchPlayer") is AnimationPlayer)
	await _save()

	await _case("Create a music audio bus at low volume", "editor", "configure_audio_bus", {"name": "SelectionBus", "volume_db": -6.0}, func(_result): return AudioServer.get_bus_index("SelectionBus") >= 0)
	await _case("Remove the temporary audio bus", "editor", "configure_audio_bus", {"name": "SelectionBus", "remove": true}, func(_result): return AudioServer.get_bus_index("SelectionBus") < 0)

	await _case("Change the window width to 1280", "editor", "set_project_setting", {"name": "display/window/size/viewport_width", "value": 1280}, func(_result): return int(ProjectSettings.get_setting("display/window/size/viewport_width")) == 1280)
	await _case("Restore the original window width", "editor", "set_project_setting", {"name": "display/window/size/viewport_width", "value": 1152}, func(_result): return int(ProjectSettings.get_setting("display/window/size/viewport_width")) == 1152)
	await _save()

	await _case("Look up CharacterBody2D movement docs", "editor", "lookup_docs", {"class_name": "CharacterBody2D", "member": "move_and_slide"}, func(result): return "CharacterBody2D.move_and_slide" in str(result.data.detail) and not str(result.data.documentation).is_empty())
	await _case("Find the existing generated image asset", "editor", "find_assets", {"kind": "image", "query": "source"}, func(result): return Array(result.data.assets).any(func(asset): return str(asset.path).ends_with("source.png")))
	await _case("List workspace files", "workspace", "list_files", {"path": "res://"}, func(result): return Array(result.data.entries).size() >= 1)
	await _case("Read the player script", "workspace", "read_file", {"path": "res://player.gd"}, func(result): return "SPEED" in str(result.data.content))
	await _case("Find the speed constant", "workspace", "search_text", {"query": "SPEED"}, func(result): return Array(result.data.matches).size() >= 1)

	registry.set_tool_mode("editor")
	EditorInterface.get_editor_settings().set_setting("tiiny_ai/advanced/tool_mode", "editor")
	if failures == 0:
		print("Tool selection cases passed: ", case_index)
		get_tree().quit(0)
	else:
		print("Tool selection cases failed: ", failures)
		get_tree().quit(1)
