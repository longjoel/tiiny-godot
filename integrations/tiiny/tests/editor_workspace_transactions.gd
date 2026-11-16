@tool
extends EditorPlugin

var inspector
var transactions

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

func _history_count(root: Node) -> int:
	var pair: Array = _history(root)
	var history = pair[2]
	return int(history.get_history_count()) if history != null else -1

func _register_test_recipes() -> void:
	transactions.register_recipe({
		"name": "add_marker_2d",
		"title": "Add Marker2D",
		"description": "Test-only recipe proving the executor is class-agnostic.",
		"parameters": {"type": "object", "properties": {"parent_path": {"type": "string"}}},
		"risk": "mutating",
		"validate": Callable(self, "_validate_marker"),
		"build": Callable(self, "_build_marker"),
	})
	transactions.register_recipe({
		"name": "add_capsule_collision_shape",
		"title": "Add capsule collision shape",
		"description": "Test-only second collision recipe through the same executor.",
		"parameters": {"type": "object", "properties": {"parent_path": {"type": "string"}, "radius": {"type": "number"}, "height": {"type": "number"}}},
		"risk": "mutating",
		"validate": Callable(self, "_validate_capsule"),
		"build": Callable(self, "_build_capsule"),
	})
	transactions.register_recipe({
		"name": "add_incompatible_shape",
		"title": "Add incompatible shape",
		"description": "Test-only recipe that must fail resource compatibility before mutation.",
		"parameters": {"type": "object", "properties": {"parent_path": {"type": "string"}}},
		"risk": "mutating",
		"validate": Callable(self, "_validate_incompatible"),
		"build": Callable(self, "_build_incompatible"),
	})

func _validate_marker(params: Dictionary, context: Dictionary) -> Dictionary:
	var path := str(params.get("parent_path", ""))
	var found: Dictionary = inspector.resolve_scene_node(context.root, path)
	if found.has("error"): return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	if not found.node is Node2D: return {"ok": false, "code": "invalid_parent", "message": "Marker parent must be Node2D."}
	if found.node != context.root and found.node.get_owner() != context.root: return {"ok": false, "code": "read_only_instance", "message": "Parent is not owned by the scene."}
	return {"ok": true, "request": {"parent_path": path}}

func _build_marker(request: Dictionary) -> Dictionary:
	return {"ok": true, "action_name": "Add Marker2D", "summary": "Added Marker2D under " + str(request.parent_path) + ".", "ops": [
		{"op": "create_node", "id": "marker", "class": "Marker2D", "name": "Marker2D"},
		{"op": "add_child", "parent": request.parent_path, "node": "marker"},
		{"op": "set_owner", "node": "marker", "owner": "."},
	]}

func _validate_capsule(params: Dictionary, context: Dictionary) -> Dictionary:
	var path := str(params.get("parent_path", ""))
	var radius: Variant = params.get("radius")
	var height: Variant = params.get("height")
	if not (radius is int or radius is float) or float(radius) <= 0 or not (height is int or height is float) or float(height) <= 0:
		return {"ok": false, "code": "invalid_dimensions", "message": "Capsule dimensions must be positive."}
	var found: Dictionary = inspector.resolve_scene_node(context.root, path)
	if found.has("error"): return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	if not found.node is CollisionObject2D: return {"ok": false, "code": "invalid_parent", "message": "Capsule parent must be a collision body."}
	if found.node != context.root and found.node.get_owner() != context.root: return {"ok": false, "code": "read_only_instance", "message": "Parent is not owned by the scene."}
	return {"ok": true, "request": {"parent_path": path, "radius": float(radius), "height": float(height)}}

func _build_capsule(request: Dictionary) -> Dictionary:
	return {"ok": true, "action_name": "Add capsule CollisionShape2D", "summary": "Added a capsule collision shape under " + str(request.parent_path) + ".", "ops": [
		{"op": "create_node", "id": "shape", "class": "CollisionShape2D", "name": "CapsuleShape"},
		{"op": "create_resource", "id": "capsule", "class": "CapsuleShape2D", "properties": {"radius": request.radius, "height": request.height}},
		{"op": "add_child", "parent": request.parent_path, "node": "shape"},
		{"op": "set_owner", "node": "shape", "owner": "."},
		{"op": "set_property", "target": "shape", "property": "shape", "value": {"ref": "capsule"}},
	]}

func _validate_incompatible(params: Dictionary, context: Dictionary) -> Dictionary:
	var path := str(params.get("parent_path", ""))
	var found: Dictionary = inspector.resolve_scene_node(context.root, path)
	if found.has("error"): return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	if not found.node is CollisionObject2D: return {"ok": false, "code": "invalid_parent", "message": "Parent must be a collision body."}
	return {"ok": true, "request": {"parent_path": path}}

func _build_incompatible(request: Dictionary) -> Dictionary:
	return {"ok": true, "action_name": "Add incompatible shape", "summary": "This must fail.", "ops": [
		{"op": "create_node", "id": "shape", "class": "CollisionShape2D", "name": "BadShape"},
		{"op": "create_resource", "id": "bad", "class": "Gradient", "properties": {}},
		{"op": "add_child", "parent": request.parent_path, "node": "shape"},
		{"op": "set_owner", "node": "shape", "owner": "."},
		{"op": "set_property", "target": "shape", "property": "shape", "value": {"ref": "bad"}},
	]}

func _run() -> void:
	for index in range(20): await get_tree().process_frame
	var dock := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if dock == null: _fail("Tiiny dock is missing"); return
	var inspector_script = dock.get("workspace_inspector_script")
	var transactions_script = dock.get("workspace_transactions_script")
	if inspector_script == null or transactions_script == null:
		_fail("Workspace scripts were not injected"); return
	inspector = inspector_script.new()
	transactions = transactions_script.new(inspector)
	_register_test_recipes()

	EditorInterface.open_scene_from_path("res://main.tscn")
	if not await _wait_for_scene("res://main.tscn"): _fail("Main scene did not open"); return
	var root := EditorInterface.get_edited_scene_root()
	var player := root.get_node_or_null("Player")
	var enemy := root.get_node_or_null("Enemy")
	var tree := root.get_node_or_null("Tree")
	if player == null or enemy == null or tree == null: _fail("Fixture nodes are missing"); return

	var initial_nodes := root.get_child_count()
	var initial_history := _history_count(root)
	for invalid in [
		{"parent_path": "Tree", "width": 32, "height": 48},
		{"parent_path": "Missing", "width": 32, "height": 48},
		{"parent_path": "Player", "width": 0, "height": 48},
	]:
		var failed: Dictionary = transactions.execute("add_rectangular_collision_shape", invalid)
		if failed.get("ok", true) or root.get_child_count() != initial_nodes or _history_count(root) != initial_history:
			_fail("Invalid recipe created partial state: " + str(failed)); return

	var context_before: Dictionary = inspector.scene_context({})
	var applied: Dictionary = transactions.execute("add_rectangular_collision_shape", {"parent_path": "Player", "width": 32, "height": 48})
	if not applied.get("ok", false): _fail("Collision recipe failed: " + str(applied)); return
	var shape := root.get_node_or_null("Player/CollisionShape2D")
	if shape == null or not (shape is CollisionShape2D) or not (shape.shape is RectangleShape2D) or shape.shape.size != Vector2(32, 48):
		_fail("Collision recipe result is wrong: " + str(shape)); return
	if shape.owner != root: _fail("Created shape owner is wrong"); return
	var after_context: Dictionary = inspector.scene_context({})
	if after_context.has("error"): _fail("Post-recipe scene context failed: " + str(after_context)); return
	if _history_count(root) != initial_history + 1 or not bool(after_context.get("scene", {}).get("dirty", false)):
		_fail("Recipe did not create one dirty undo action"); return
	if _error_code(transactions.execute("add_rectangular_collision_shape", {"parent_path": "Player", "width": 32, "height": 48})) != "scene_dirty":
		_fail("Dirty scene was allowed to mutate again"); return

	var pair: Array = _history(root)
	var history = pair[2]
	if not history.undo(): _fail("Undo failed"); return
	if root.get_node_or_null("Player/CollisionShape2D") != null: _fail("Undo did not remove the shape"); return
	if not history.redo(): _fail("Redo failed"); return
	shape = root.get_node_or_null("Player/CollisionShape2D")
	if shape == null or shape.shape == null or shape.shape.size != Vector2(32, 48): _fail("Redo did not restore the shape"); return

	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Saved main scene lost"); return
	EditorInterface.reload_scene_from_path("res://main.tscn")
	if not await _wait_for_scene("res://main.tscn"): _fail("Reloaded main scene did not open"); return
	root = EditorInterface.get_edited_scene_root()
	shape = root.get_node_or_null("Player/CollisionShape2D")
	if shape == null or not (shape.shape is RectangleShape2D) or shape.shape.size != Vector2(32, 48):
		_fail("Saved/reopened shape is wrong: " + str(shape)); return
	if bool(inspector.scene_context({}).scene.dirty): _fail("Reloaded scene should be clean"); return
	var clean_context: Dictionary = inspector.scene_context({})
	var stale_context: Dictionary = clean_context.duplicate(true)
	stale_context.session_revision = "undo:999"
	if _error_code(transactions.execute("add_rectangular_collision_shape", {"parent_path": "Player", "width": 16, "height": 16}, stale_context)) != "stale_scene":
		_fail("Stale turn context was accepted"); return
	var conflict_history := _history_count(root)
	if _error_code(transactions.execute("add_rectangular_collision_shape", {"parent_path": "Player", "width": 16, "height": 16})) != "target_conflict":
		_fail("Existing collision shape conflict was not reported"); return
	var incompatible: Dictionary = transactions.execute("add_incompatible_shape", {"parent_path": "Enemy"})
	if _error_code(incompatible) != "type_mismatch" or root.get_node_or_null("Enemy/BadShape") != null or _history_count(root) != conflict_history:
		_fail("Incompatible resource created partial state: " + str(incompatible)); return

	var torch: Node = root.get_node_or_null("Torch")
	if torch == null: _fail("Torch fixture node is missing"); return
	var existing_player := AnimationPlayer.new()
	existing_player.name = "Existing"
	torch.add_child(existing_player)
	existing_player.owner = root
	var existing_library := AnimationLibrary.new()
	existing_library.add_animation("idle", Animation.new())
	existing_player.add_animation_library("user", existing_library)
	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Could not save the torch fixture"); return
	root = EditorInterface.get_edited_scene_root()
	var torch_history := _history_count(root)
	var flicker: Dictionary = transactions.execute("add_torch_flicker", {"parent_path": "Torch", "duration": 0.8, "min_energy": 0.3, "max_energy": 1.0, "steps": 4})
	if not flicker.get("ok", false) or _history_count(root) != torch_history + 1:
		_fail("Torch flicker recipe failed: " + str(flicker)); return
	var torch_player: AnimationPlayer = root.get_node_or_null("Torch/AnimationPlayer")
	if torch_player == null or torch_player.autoplay != &"tiiny/flicker":
		_fail("Torch flicker did not create an autoplay AnimationPlayer: " + str(torch_player)); return
	var library: AnimationLibrary = torch_player.get_animation_library("tiiny")
	if library == null or not library.has_animation("flicker"):
		_fail("Torch flicker library/animation is missing"); return
	var animation: Animation = library.get_animation("flicker")
	if animation == null or animation.get_track_count() != 1 or animation.track_get_key_count(0) != 4:
		_fail("Torch flicker track/key count is wrong: " + str(animation)); return
	if str(animation.track_get_path(0)) != "Light2D:energy":
		_fail("Torch flicker track path is wrong: " + str(animation.track_get_path(0))); return
	var preserved_player: AnimationPlayer = root.get_node_or_null("Torch/Existing")
	if preserved_player == null or not preserved_player.has_animation_library("user") or not preserved_player.get_animation_library("user").has_animation("idle"):
		_fail("Torch flicker did not preserve the existing animation library"); return
	var torch_undo := _history(root)
	if not torch_undo[2].undo() or root.get_node_or_null("Torch/AnimationPlayer") != null:
		_fail("Torch flicker undo did not remove the AnimationPlayer"); return
	if not torch_undo[2].redo() or root.get_node_or_null("Torch/AnimationPlayer") == null:
		_fail("Torch flicker redo did not restore the AnimationPlayer"); return
	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Could not save after torch redo"); return
	root = EditorInterface.get_edited_scene_root()
	var no_light: Dictionary = transactions.execute("add_torch_flicker", {"parent_path": "Player"})
	if _error_code(no_light) != "target_missing" or root.get_node_or_null("Player/AnimationPlayer") != null:
		_fail("Torch flicker did not reject a target without a light: " + str(no_light)); return

	var platform: StaticBody2D = root.get_node_or_null("Platform")
	if platform == null: _fail("Platform fixture node is missing"); return
	platform.physics_material_override = null
	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Could not save the physics fixture"); return
	root = EditorInterface.get_edited_scene_root()
	platform = root.get_node_or_null("Platform")
	var slippery_history := _history_count(root)
	var slippery: Dictionary = transactions.execute("assign_slippery_surface", {"target_path": "Platform", "friction": 0.02, "bounce": 0.1})
	if not slippery.get("ok", false) or _history_count(root) != slippery_history + 1:
		_fail("Slippery-surface recipe failed: " + str(slippery)); return
	var material: PhysicsMaterial = platform.physics_material_override
	if material == null or absf(material.friction - 0.02) > 0.0001 or absf(material.bounce - 0.1) > 0.0001 or material.rough or material.absorbent:
		_fail("Slippery PhysicsMaterial values are wrong: " + str(material)); return
	var slippery_undo := _history(root)
	if not slippery_undo[2].undo() or platform.physics_material_override != null:
		_fail("Slippery-surface undo did not restore the previous material"); return
	if not slippery_undo[2].redo() or not platform.physics_material_override is PhysicsMaterial:
		_fail("Slippery-surface redo did not restore the material"); return
	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Could not save before shared-material test"); return
	root = EditorInterface.get_edited_scene_root()
	platform = root.get_node_or_null("Platform")
	var shared := PhysicsMaterial.new()
	shared.friction = 0.9
	platform.physics_material_override = shared
	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Could not save the shared-material fixture"); return
	root = EditorInterface.get_edited_scene_root()
	platform = root.get_node_or_null("Platform")
	var shared_history := _history_count(root)
	var replaced: Dictionary = transactions.execute("assign_slippery_surface", {"target_path": "Platform", "friction": 0.03})
	if not replaced.get("ok", false) or not str(replaced.get("summary", "")).contains("previous PhysicsMaterial") or absf(shared.friction - 0.9) > 0.0001:
		_fail("Slippery-surface replacement did not preserve/report the previous resource: " + str(replaced)); return
	if platform.physics_material_override == shared or _history_count(root) != shared_history + 1:
		_fail("Slippery-surface replacement did not assign an owned material"); return
	var shared_undo := _history(root)
	if not shared_undo[2].undo() or platform.physics_material_override != shared:
		_fail("Slippery-surface undo did not restore the shared material reference"); return
	var unsupported: Dictionary = transactions.execute("assign_slippery_surface", {"target_path": "Torch"})
	if _error_code(unsupported) != "invalid_target":
		_fail("Slippery-surface did not reject a non-physics target: " + str(unsupported)); return

	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Could not save before asset import tests"); return
	root = EditorInterface.get_edited_scene_root()
	var world: Node3D = root.get_node_or_null("World")
	if world == null: _fail("World 3D fixture node is missing"); return
	var doc := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	var model_root := Node3D.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var box := BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	mesh_instance.mesh = box
	var model_material := StandardMaterial3D.new()
	model_material.albedo_color = Color(0.8, 0.3, 0.1)
	mesh_instance.material_override = model_material
	model_root.add_child(mesh_instance)
	mesh_instance.owner = model_root
	var append_error := doc.append_from_scene(model_root, gltf_state)
	model_root.free()
	if append_error != OK: _fail("Could not build the fixture GLB: " + str(append_error)); return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://generated"))
	if doc.write_to_filesystem(gltf_state, "res://generated/torch_prop.glb") != OK:
		_fail("Could not write the fixture GLB"); return
	EditorInterface.get_resource_filesystem().scan()
	var glb_deadline := Time.get_ticks_msec() + 15000
	while not ResourceLoader.exists("res://generated/torch_prop.glb") and Time.get_ticks_msec() < glb_deadline:
		await get_tree().create_timer(0.1).timeout
	if not ResourceLoader.exists("res://generated/torch_prop.glb"): _fail("Fixture GLB did not import"); return
	var source_hash := FileAccess.get_sha256("res://generated/source.png")
	var missing: Dictionary = transactions.execute("import_generated_model", {"path": "res://generated/missing.glb", "parent_path": "World"})
	if _error_code(missing) != "artifact_missing" or FileAccess.get_sha256("res://generated/source.png") != source_hash:
		_fail("Downstream 3D failure did not preserve the stage-1 image artifact: " + str(missing)); return
	var imported_model: Dictionary = transactions.execute("import_generated_model", {"path": "res://generated/torch_prop.glb", "parent_path": "World", "node_name": "GeneratedProp"})
	if not imported_model.get("ok", false) or Array(imported_model.get("data", {}).get("meshes", [])).is_empty():
		_fail("Generated 3D model import failed: " + str(imported_model)); return
	if str(imported_model.get("data", {}).get("validation", {}).get("topology", "")) != "unverified" or str(imported_model.get("data", {}).get("validation", {}).get("pbr_maps", "")) != "unverified":
		_fail("Generated 3D model claimed unverified quality"); return
	var instance: Node = root.get_node_or_null("World/GeneratedProp")
	if instance == null or instance.find_children("*", "MeshInstance3D", true, false).is_empty():
		_fail("Generated model instance has no mesh"); return
	var model_undo := _history(root)
	if not model_undo[2].undo() or root.get_node_or_null("World/GeneratedProp") != null:
		_fail("Generated model undo failed"); return
	if not model_undo[2].redo() or root.get_node_or_null("World/GeneratedProp") == null:
		_fail("Generated model redo failed"); return
	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Could not save after model import"); return
	root = EditorInterface.get_edited_scene_root()
	var audio_deadline := Time.get_ticks_msec() + 15000
	while not ResourceLoader.exists("res://generated/line.wav") and Time.get_ticks_msec() < audio_deadline:
		await get_tree().create_timer(0.1).timeout
	if not ResourceLoader.exists("res://generated/line.wav"): _fail("Fixture WAV did not import"); return
	var imported_audio: Dictionary = transactions.execute("import_generated_audio", {"path": "res://generated/line.wav", "player_name": "GeneratedLine"})
	if not imported_audio.get("ok", false) or float(imported_audio.get("data", {}).get("duration", 0.0)) <= 0.0:
		_fail("Generated audio import failed: " + str(imported_audio)); return
	if str(imported_audio.get("data", {}).get("validation", {}).get("loop", "")) != "unverified":
		_fail("Generated audio claimed loop verification"); return
	var audio_player: AudioStreamPlayer = root.get_node_or_null("GeneratedLine")
	if audio_player == null or audio_player.stream == null:
		_fail("Generated audio player/stream is missing"); return
	var audio_undo := _history(root)
	if not audio_undo[2].undo() or root.get_node_or_null("GeneratedLine") != null:
		_fail("Generated audio undo failed"); return
	if not audio_undo[2].redo() or root.get_node_or_null("GeneratedLine") == null:
		_fail("Generated audio redo failed"); return
	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Could not save after audio import"); return
	root = EditorInterface.get_edited_scene_root()

	var registry = dock.get("workspace_registry_script").new(inspector, transactions)
	registry.set_handler("read_project_file", Callable(dock, "_registry_read_file"))
	registry.set_handler("replace_in_gdscript", Callable(dock, "_registry_replace_script"))
	for definition in registry.definitions():
		registry.set_available(str(definition.name), true)
	if not Array(registry.tools_payload()).any(func(tool): return str(tool.function.name) == "add_rectangular_collision_shape"):
		_fail("Registry payload omitted the recipe"); return
	for recipe_name in ["add_torch_flicker", "assign_slippery_surface", "import_generated_model", "import_generated_audio", "read_project_file", "replace_in_gdscript"]:
		if not Array(registry.tools_payload()).any(func(tool): return str(tool.function.name) == recipe_name):
			_fail("Registry payload omitted the native workflow recipe: " + recipe_name); return
	var edit_path := "res://edit_fixture.gd"
	var edit_file := FileAccess.open(edit_path, FileAccess.WRITE)
	if edit_file == null: _fail("Could not create the script-edit fixture"); return
	edit_file.store_string("extends Node\n\nvar speed := 1\n")
	edit_file.close()
	EditorInterface.get_resource_filesystem().scan()
	var read_result: Dictionary = await registry.execute("read_project_file", {"path": edit_path})
	if not read_result.get("ok", false) or not str(read_result.get("data", {}).get("content", "")).contains("var speed := 1"):
		_fail("Project file read failed: " + str(read_result)); return
	var edit_hash := str(read_result.get("data", {}).get("sha256", ""))
	var stale_edit: Dictionary = await registry.execute("replace_in_gdscript", {"path": edit_path, "expected_sha256": "0".repeat(64), "old_text": "var speed := 1", "new_text": "var speed := 2", "reason": "fixture"})
	if str(stale_edit.get("error", {}).get("code", "")) != "execution_failed" or not FileAccess.get_file_as_string(edit_path).contains("var speed := 1"):
		_fail("Stale script edit was applied: " + str(stale_edit)); return
	var applied_edit: Dictionary = await registry.execute("replace_in_gdscript", {"path": edit_path, "expected_sha256": edit_hash, "old_text": "var speed := 1", "new_text": "var speed := 2", "reason": "fixture velocity"})
	if not applied_edit.get("ok", false) or not FileAccess.get_file_as_string(edit_path).contains("var speed := 2"):
		_fail("Valid script edit failed: " + str(applied_edit)); return
	if Array(applied_edit.get("affected", [])).is_empty() or str(applied_edit.affected[0].get("kind", "")) != "file":
		_fail("Script edit did not report a file target"); return
	var invalid_source := "extends Node\n"
	edit_file = FileAccess.open(edit_path, FileAccess.WRITE)
	edit_file.store_string(invalid_source)
	edit_file.close()
	var invalid_hash := FileAccess.get_sha256(edit_path)
	var invalid_edit: Dictionary = await registry.execute("replace_in_gdscript", {"path": edit_path, "expected_sha256": invalid_hash, "old_text": "extends Node", "new_text": "extends Node(", "reason": "fixture invalid"})
	if invalid_edit.get("ok", false) or FileAccess.get_file_as_string(edit_path) != invalid_source:
		_fail("Invalid script replacement changed the file: " + str(invalid_edit)); return
	var duplicate_source := "extends Node\n\nvar a := 1\nvar a := 1\n"
	edit_file = FileAccess.open(edit_path, FileAccess.WRITE)
	edit_file.store_string(duplicate_source)
	edit_file.close()
	var duplicate_edit: Dictionary = await registry.execute("replace_in_gdscript", {"path": edit_path, "expected_sha256": FileAccess.get_sha256(edit_path), "old_text": "var a := 1", "new_text": "var a := 2", "reason": "fixture duplicate"})
	if duplicate_edit.get("ok", false) or FileAccess.get_file_as_string(edit_path) != duplicate_source:
		_fail("Duplicate script snippet was edited: " + str(duplicate_edit)); return
	var bad_schema: Dictionary = await registry.execute("add_rectangular_collision_shape", {"parent_path": "Enemy", "width": "wide", "height": 1})
	if _error_code(bad_schema) != "invalid_arguments":
		_fail("Registry schema accepted a string width: " + str(bad_schema)); return
	var registry_context: Dictionary = inspector.scene_context({})
	var registry_call := {"scene_path": registry_context.scene_path, "revision": registry_context.revision, "session_revision": registry_context.session_revision, "root_instance_id": registry_context.root_instance_id, "call_id": "call-registry"}
	var through_registry: Dictionary = await registry.execute("add_rectangular_collision_shape", {"parent_path": "Enemy", "width": 12, "height": 20}, registry_call)
	if not through_registry.get("ok", false) or through_registry.get("call_id") != "call-registry" or str(through_registry.get("undo_group", "")).is_empty():
		_fail("Registry recipe execution failed: " + str(through_registry)); return
	if not root.get_node_or_null("Enemy/CollisionShape2D") is CollisionShape2D:
		_fail("Registry recipe did not create the node"); return
	var registry_undo := _history(root)
	if not registry_undo[2].undo() or root.get_node_or_null("Enemy/CollisionShape2D") != null:
		_fail("Registry recipe undo failed"); return
	if _error_code(await registry.execute("unknown_tool", {})) != "unknown_tool":
		_fail("Unknown registry tool was not rejected"); return
	registry.set_available("add_rectangular_collision_shape", false, "Save the scene before applying an edit.")
	if Array(registry.tools_payload()).any(func(tool): return str(tool.function.name) == "add_rectangular_collision_shape"):
		_fail("Unavailable tool remained in the payload"); return
	if _error_code(await registry.execute("add_rectangular_collision_shape", {"parent_path": "Enemy", "width": 1, "height": 1})) != "unavailable":
		_fail("Unavailable registry tool did not return unavailable"); return
	var prompt: String = registry.build_system_prompt("Prefer concise answers.", "Scene: res://main.tscn")
	if not ("Tool capabilities" in prompt and "User preferences" in prompt and "Editor context" in prompt and "workspace-first" in prompt.to_lower()):
		_fail("Prompt sections are incomplete"); return
	var ledger: Dictionary = registry.ledger_entry(through_registry, "turn-fixture")
	if ledger.turn != "turn-fixture" or not ledger.ok or ledger.call != "call-registry":
		_fail("Ledger entry is wrong: " + str(ledger)); return
	var recipes: Dictionary = registry.resource_recipes()
	if str(recipes.get("convex_polygon_shape", {}).get("status", "")) != "available" or str(recipes.get("convex_polygon_shape", {}).get("output", "")) != "ConvexPolygonShape2D":
		_fail("Convex polygon recipe metadata is wrong: " + str(recipes.get("convex_polygon_shape", {}))); return
	if str(recipes.get("image_generation", {}).get("status", "")) != "available" or str(recipes.get("image_generation", {}).get("output", "")) != "Texture2D":
		_fail("Image recipe metadata is wrong: " + str(recipes.get("image_generation", {}))); return
	for planned in ["image_to_3d", "music_generation", "speech_generation"]:
		if str(recipes.get(planned, {}).get("status", "")) != "planned":
			_fail("Planned recipe is not marked planned: " + planned); return
	if recipes.has("sound_effect") or recipes.has("sound_effects"):
		_fail("Sound effects were advertised without a tested recipe"); return
	if str(recipes.get("image_to_3d", {}).get("output", "")) != "Mesh" or str(recipes.get("music_generation", {}).get("output", "")) != "AudioStream":
		_fail("Planned recipe output types are wrong: " + str(recipes)); return
	if not registry.supports_resource_type("ConvexPolygonShape2D") or not registry.supports_resource_type("Texture2D"):
		_fail("Available recipe resource types are not supported"); return
	if registry.supports_resource_type("Image") or registry.supports_resource_type("Mesh") or registry.supports_resource_type("AudioStream") or registry.supports_resource_type("StandardMaterial3D"):
		_fail("Planned or untyped resource was reported supported"); return
	if Array(registry.tools_payload()).any(func(tool): return str(tool.function.name) in ["image_to_3d", "music_generation", "speech_generation"]):
		_fail("Planned recipe was exposed as an executable tool"); return
	if not dock.supports_ai_resource_type("ConvexPolygonShape2D") or dock.supports_ai_resource_type("Image"):
		_fail("Dock resource eligibility disagrees with the registry"); return

	var chat = load("res://fake_chat.gd").new()
	add_child(chat)
	for index in range(5): await get_tree().process_frame
	chat.jobs_service = get_tree().root.find_child("Tiiny Jobs", true, false)
	chat.workspace_inspector_script = dock.get("workspace_inspector_script")
	chat.workspace_transactions_script = dock.get("workspace_transactions_script")
	chat.workspace_registry_script = dock.get("workspace_registry_script")
	chat.pending_prompt = "Add a rectangular collision shape to Enemy, 32 wide and 48 tall."
	chat.pending_key = "fixture-key"
	chat.pending_model = "fixture-model"
	EditorInterface.get_editor_settings().set_setting("tiiny_ai/models/context_tokens", 16384)
	chat._start_answer("code")
	if chat.submissions.is_empty(): _fail("Registry chat did not submit a payload: " + chat.status.text); return
	var payload: Dictionary = chat.submissions.back()
	if not payload.get("tools") is Array or not Array(payload.tools).any(func(tool): return str(tool.function.name) == "add_rectangular_collision_shape"):
		_fail("Registry chat omitted the recipe tool"); return
	var call := {"id": "call-chat", "type": "function", "function": {"name": "add_rectangular_collision_shape", "arguments": JSON.stringify({"parent_path": "Enemy", "width": 32, "height": 48})}}
	var reply := {"choices": [{"message": {"role": "assistant", "tool_calls": [call]}}]}
	await chat._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify(reply).to_utf8_buffer())
	var envelope: Variant = JSON.parse_string(chat.turn_messages.back().content)
	if not envelope is Dictionary or not envelope.get("ok", false) or not envelope.get("undo_group") is String or str(envelope.undo_group).is_empty():
		_fail("Chat did not return a structured recipe result: " + str(envelope)); return
	if root.get_node_or_null("Enemy/CollisionShape2D") == null or chat.turn_ledger.size() != 1:
		_fail("Chat recipe or ledger result is missing"); return
	var cards: Array = chat.action_cards_state()
	if cards.size() != 1 or cards[0].status != "Completed" or str(cards[0].action_name).is_empty():
		_fail("Action card state is wrong: " + str(cards)); return
	var first_card: Control = cards[0].card
	if first_card == null: _fail("Action card UI is missing"); return
	var select_button: Button = first_card.find_child("ActionSelect", true, false)
	if select_button == null: _fail("Action card Select button is missing"); return
	select_button.pressed.emit()
	await get_tree().process_frame
	var selected: Array = EditorInterface.get_selection().get_selected_nodes()
	if not selected.any(func(node): return str(root.get_path_to(node)) == "Enemy/CollisionShape2D"):
		_fail("Action card did not select the recorded node"); return
	var undo_button: Button = first_card.find_child("ActionUndo", true, false)
	if undo_button == null: _fail("Action card Undo button is missing"); return
	undo_button.pressed.emit()
	await get_tree().process_frame
	if root.get_node_or_null("Enemy/CollisionShape2D") != null: _fail("Action card Undo did not remove the shape"); return
	chat._start_answer("code")
	var unknown_call := {"id": "call-unknown", "type": "function", "function": {"name": "unsupported_fixture_tool", "arguments": "{}"}}
	var unknown_reply := {"choices": [{"message": {"role": "assistant", "tool_calls": [unknown_call]}}]}
	await chat._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify(unknown_reply).to_utf8_buffer())
	var unknown_envelope: Variant = JSON.parse_string(chat.turn_messages.back().content)
	if not unknown_envelope is Dictionary or str(unknown_envelope.get("error", {}).get("code", "")) != "unknown_tool":
		_fail("Chat unknown tool was not structured: " + str(unknown_envelope)); return
	cards = chat.action_cards_state()
	if cards.is_empty() or cards.back().ok or str(cards.back().status) != "Failed":
		_fail("Failed action card state is wrong: " + str(cards)); return
	var failed_card: Control = cards.back().card
	if failed_card == null or failed_card.find_child("ActionRetry", true, false) == null:
		_fail("Failed action card has no retry path"); return
	chat._start_answer("code")
	var file_call := {"id": "call-file", "type": "function", "function": {"name": "create_gdscript", "arguments": JSON.stringify({"path": "res://action_card.gd", "source": "extends Node\n", "reason": "action card fixture"})}}
	var file_reply := {"choices": [{"message": {"role": "assistant", "tool_calls": [file_call]}}]}
	await chat._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify(file_reply).to_utf8_buffer())
	var file_card: Control = chat.action_cards_state().back().card
	if file_card == null or file_card.find_child("ActionFileNote", true, false) == null or file_card.find_child("ActionUndo", true, false) != null:
		_fail("File action card incorrectly offers scene undo"); return
	chat._append_action_card({"ok": true, "tool": "generate_image", "summary": "Generated and imported res://tiiny_generated/image.png.", "data": {"path": "res://tiiny_generated/image.png"}, "affected": [{"kind": "resource", "path": "res://tiiny_generated/image.png", "class": "Texture2D"}]}, {"prompt": "fixture"})
	var image_card: Control = chat.action_cards_state().back().card
	if image_card == null or image_card.find_child("ActionOpen", true, false) == null or image_card.find_child("ActionUndo", true, false) != null:
		_fail("Generated image card has no artifact link or falsely offers undo"); return
	chat._append_action_card({"ok": true, "tool": "replace_in_gdscript", "summary": "Edited res://edit_fixture.gd with one validated snippet replacement.", "affected": [{"kind": "file", "path": "res://edit_fixture.gd"}]}, {"path": "res://edit_fixture.gd"})
	var edit_card: Control = chat.action_cards_state().back().card
	if edit_card == null or edit_card.find_child("ActionFileNote", true, false) == null or edit_card.find_child("ActionUndo", true, false) != null:
		_fail("Script-edit card falsely offered scene undo"); return
	chat.size = Vector2(320, 600)
	await get_tree().process_frame
	await get_tree().process_frame
	if file_card.size.x <= 0 or file_card.size.x > 321:
		_fail("Action card did not fit the small chat width: " + str(file_card.size)); return
	EditorInterface.play_custom_scene("res://running.tscn")
	var playing := false
	for index in range(100):
		if EditorInterface.is_playing_scene(): playing = true; break
		await get_tree().create_timer(0.05).timeout
	if not playing: _fail("Running scene did not start for chat UI test"); return
	if chat.history_text().is_empty() or chat.action_cards_state().is_empty():
		_fail("Chat action history disappeared while a scene ran"); return
	EditorInterface.stop_playing_scene()
	for index in range(100):
		if not EditorInterface.is_playing_scene(): break
		await get_tree().create_timer(0.05).timeout
	chat.queue_free()
	await get_tree().process_frame

	var marker: Dictionary = transactions.execute("add_marker_2d", {"parent_path": "Tree"})
	if not marker.get("ok", false) or not root.get_node_or_null("Tree/Marker2D") is Marker2D:
		_fail("Marker test recipe failed: " + str(marker)); return
	pair = _history(root)
	history = pair[2]
	history.undo()
	if root.get_node_or_null("Tree/Marker2D") != null: _fail("Marker undo failed"); return
	history.redo()
	if root.get_node_or_null("Tree/Marker2D") == null: _fail("Marker redo failed"); return

	EditorInterface.save_scene()
	if not await _wait_for_scene("res://main.tscn"): _fail("Marker save failed"); return
	var capsule: Dictionary = transactions.execute("add_capsule_collision_shape", {"parent_path": "Enemy", "radius": 8, "height": 32})
	if not capsule.get("ok", false): _fail("Capsule test recipe failed: " + str(capsule)); return
	var capsule_node: Node = root.get_node_or_null("Enemy/CapsuleShape")
	if capsule_node == null or not (capsule_node.shape is CapsuleShape2D) or capsule_node.shape.radius != 8 or capsule_node.shape.height != 32:
		_fail("Capsule resource result is wrong"); return

	EditorInterface.open_scene_from_path("res://base.tscn")
	if not await _wait_for_scene("res://base.tscn"): _fail("Base scene did not open"); return
	var switched: Dictionary = transactions.execute("add_rectangular_collision_shape", {"parent_path": "Player", "width": 1, "height": 1}, clean_context)
	if _error_code(switched) != "stale_scene": _fail("Scene switch was not rejected"); return

	print("Workspace transaction editor integration passed.")
	get_tree().quit()
