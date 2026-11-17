@tool
extends EditorPlugin

## Story 18 bake-off: ten fixed tasks solved once with workspace coding tools
## and once with typed editor tools, in one disposable editor. This is a
## deterministic solution-path comparison, not a model success rate.

const REPORT_PATH_ENV := "TIINY_BAKEOFF_REPORT"
const SCENE := "res://bake.tscn"
const SCRIPT := "res://player.gd"
const MATERIAL := "res://crate_material.tres"
const TASK_IDS := ["script_speed", "script_jump", "collision", "marker", "label", "camera", "light", "material", "slippery", "reparent"]

var dock: Node
var provider: Object
var inspector: Object
var transactions: Object
var failures := 0

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	failures += 1
	get_tree().quit(1)

func _wait_for_scene(path: String) -> bool:
	for index in range(300):
		var root := EditorInterface.get_edited_scene_root()
		if root != null and root.scene_file_path == path:
			return true
		await get_tree().process_frame
	return false

func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _restore() -> void:
	if EditorInterface.get_edited_scene_root() != null:
		EditorInterface.close_scene()
		for index in range(30):
			await get_tree().process_frame
	_write(SCENE, FileAccess.get_file_as_string("res://pristine.tscn"))
	_write(SCRIPT, FileAccess.get_file_as_string("res://pristine_player.gd"))
	if FileAccess.file_exists(MATERIAL):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(MATERIAL))
	EditorInterface.get_resource_filesystem().scan()

func _context() -> Dictionary:
	var context: Dictionary = inspector.scene_context({})
	context["call_id"] = "bakeoff-" + Crypto.new().generate_random_bytes(4).hex_encode()
	context["undo_group"] = "tiiny:bakeoff:" + str(context.get("call_id", ""))
	return context

func _scene_text() -> String:
	return FileAccess.get_file_as_string(SCENE)

func _write_scene(text: String) -> Dictionary:
	return await provider.execute("write_file", {"path": SCENE, "content": text, "expected_sha256": FileAccess.get_sha256(SCENE)})

func _write_script(text: String) -> Dictionary:
	return await provider.execute("write_file", {"path": SCRIPT, "content": text, "expected_sha256": FileAccess.get_sha256(SCRIPT)})

func _workspace_solution(id: String) -> Dictionary:
	match id:
		"script_speed":
			var read: Dictionary = await provider.execute("read_file", {"path": SCRIPT})
			var old := "const SPEED := 200.0"
			var patch := "<<<<<<<\n" + old + "\n=======\nconst SPEED := 300.0\n>>>>>>>"
			return await provider.execute("apply_patch", {"path": SCRIPT, "expected_sha256": str(read.get("data", {}).get("sha256", "")), "patch": patch})
		"script_jump":
			var source := FileAccess.get_file_as_string(SCRIPT)
			return await _write_script(source.replace("\tvelocity.y += GRAVITY * delta\n", "\tvelocity.y += GRAVITY * delta\n\tif Input.is_action_just_pressed(\"jump\") and is_on_floor():\n\t\tvelocity.y = -420.0\n"))
		"collision":
			var text := _scene_text()
			text = text.replace("[gd_scene load_steps=1 format=3]\n", "[gd_scene load_steps=2 format=3]\n\n[sub_resource type=\"RectangleShape2D\" id=\"RectangleShape2D_1\"]\nsize = Vector2(32, 48)\n")
			text = text.replace("[node name=\"Player\" type=\"CharacterBody2D\" parent=\".\"]\n", "[node name=\"Player\" type=\"CharacterBody2D\" parent=\".\"]\n\n[node name=\"CollisionShape2D\" type=\"CollisionShape2D\" parent=\"Player\"]\nshape = SubResource(\"RectangleShape2D_1\")\n")
			return await _write_scene(text)
		"marker":
			var text := _scene_text()
			return await _write_scene(text + "\n[node name=\"Spawn\" type=\"Marker2D\" parent=\".\"]\nposition = Vector2(32, 64)\n")
		"label":
			return await _write_scene(_scene_text().replace("text = \"HUD\"", "text = \"Score: 0\""))
		"camera":
			return await _write_scene(_scene_text() + "\n[node name=\"MainCamera\" type=\"Camera2D\" parent=\".\"]\nposition = Vector2(0, -20)\nzoom = Vector2(1.5, 1.5)\n")
		"light":
			return await _write_scene(_scene_text() + "\n[node name=\"OmniLight3D\" type=\"OmniLight3D\" parent=\"World\"]\nlight_energy = 2.0\n")
		"material":
			_write(MATERIAL, "[gd_resource type=\"StandardMaterial3D\" format=3]\n\n[resource]\nmetallic = 0.8\nroughness = 0.2\n")
			var text := _scene_text()
			text = text.replace("[gd_scene load_steps=1 format=3]\n", "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"StandardMaterial3D\" path=\"res://crate_material.tres\" id=\"1_material\"]\n")
			text = text.replace("[node name=\"Crate\" type=\"MeshInstance3D\" parent=\"World\"]", "[node name=\"Crate\" type=\"MeshInstance3D\" parent=\"World\"]\nmaterial_override = ExtResource(\"1_material\")")
			return await _write_scene(text)
		"slippery":
			var text := _scene_text()
			text = text.replace("[gd_scene load_steps=1 format=3]\n", "[gd_scene load_steps=2 format=3]\n\n[sub_resource type=\"PhysicsMaterial\" id=\"PhysicsMaterial_1\"]\nfriction = 0.0\n")
			text = text.replace("[node name=\"Platform\" type=\"StaticBody2D\" parent=\".\"]\n", "[node name=\"Platform\" type=\"StaticBody2D\" parent=\".\"]\nphysics_material_override = SubResource(\"PhysicsMaterial_1\")\n")
			return await _write_scene(text)
		"reparent":
			return await _write_scene(_scene_text().replace("[node name=\"Crate\" type=\"MeshInstance3D\" parent=\"World\"]", "[node name=\"Crate\" type=\"MeshInstance3D\" parent=\".\"]"))
	return {"ok": false, "error": {"code": "unknown_task", "message": id}}

func _editor_solution(id: String, context: Dictionary) -> Dictionary:
	match id:
		"script_speed":
			var hash := FileAccess.get_sha256(SCRIPT)
			return dock.call("_registry_replace_script", {"path": SCRIPT, "expected_sha256": hash, "old_text": "const SPEED := 200.0", "new_text": "const SPEED := 300.0", "reason": "bake-off"}, {})
		"script_jump":
			var source := FileAccess.get_file_as_string(SCRIPT)
			var updated := source.replace("\tvelocity.y += GRAVITY * delta\n", "\tvelocity.y += GRAVITY * delta\n\tif Input.is_action_just_pressed(\"jump\") and is_on_floor():\n\t\tvelocity.y = -420.0\n")
			return dock.call("_registry_replace_script", {"path": SCRIPT, "expected_sha256": FileAccess.get_sha256(SCRIPT), "old_text": source, "new_text": updated, "reason": "bake-off"}, {})
		"collision":
			return transactions.execute("add_rectangular_collision_shape", {"parent_path": "Player", "width": 32, "height": 48}, context)
		"marker":
			return transactions.execute("apply_editor_transaction", {"operations": [
				{"op": "create_node", "id": "spawn", "class": "Marker2D", "parent": ".", "name": "Spawn", "properties": {"position": Vector2(32, 64)}},
			]}, context)
		"label":
			return transactions.execute("apply_editor_transaction", {"operations": [
				{"op": "set_property", "target": "Label", "property": "text", "value": "Score: 0"},
			]}, context)
		"camera":
			return transactions.execute("apply_editor_transaction", {"operations": [
				{"op": "create_node", "id": "camera", "class": "Camera2D", "parent": ".", "name": "MainCamera", "properties": {"position": Vector2(0, -20), "zoom": Vector2(1.5, 1.5)}},
			]}, context)
		"light":
			return transactions.execute("apply_editor_transaction", {"operations": [
				{"op": "create_node", "id": "light", "class": "OmniLight3D", "parent": "World", "name": "OmniLight3D", "properties": {"light_energy": 2.0}},
			]}, context)
		"material":
			return transactions.execute("apply_editor_transaction", {"operations": [
				{"op": "create_resource", "id": "metal", "class": "StandardMaterial3D", "properties": {"metallic": 0.8, "roughness": 0.2}},
				{"op": "assign_resource", "target": "World/Crate", "property": "material_override", "resource": "metal"},
			]}, context)
		"slippery":
			return transactions.execute("assign_slippery_surface", {"target_path": "Platform", "friction": 0.0}, context)
		"reparent":
			return transactions.execute("apply_editor_transaction", {"operations": [
				{"op": "reparent_node", "target": "World/Crate", "parent": "."},
			]}, context)
	return {"ok": false, "error": {"code": "unknown_task", "message": id}}

func _verify(id: String, root: Node) -> bool:
	match id:
		"script_speed":
			return FileAccess.get_file_as_string(SCRIPT).contains("const SPEED := 300.0")
		"script_jump":
			return FileAccess.get_file_as_string(SCRIPT).contains("is_action_just_pressed(\"jump\")")
		"collision":
			var shape := root.get_node_or_null("Player/CollisionShape2D") as CollisionShape2D
			return shape != null and shape.shape is RectangleShape2D and is_equal_approx(shape.shape.size.x, 32.0) and is_equal_approx(shape.shape.size.y, 48.0)
		"marker":
			var marker := root.get_node_or_null("Spawn") as Marker2D
			return marker != null and marker.position.is_equal_approx(Vector2(32, 64))
		"label":
			var label := root.get_node_or_null("Label") as Label
			return label != null and label.text == "Score: 0"
		"camera":
			var camera := root.get_node_or_null("MainCamera") as Camera2D
			return camera != null and camera.position.is_equal_approx(Vector2(0, -20)) and camera.zoom.is_equal_approx(Vector2(1.5, 1.5))
		"light":
			var light := root.get_node_or_null("World/OmniLight3D") as OmniLight3D
			return light != null and is_equal_approx(light.light_energy, 2.0)
		"material":
			var crate := root.get_node_or_null("World/Crate") as MeshInstance3D
			return crate != null and crate.material_override is StandardMaterial3D and is_equal_approx(crate.material_override.metallic, 0.8) and is_equal_approx(crate.material_override.roughness, 0.2)
		"slippery":
			var platform := root.get_node_or_null("Platform") as StaticBody2D
			return platform != null and platform.physics_material_override is PhysicsMaterial and is_equal_approx(platform.physics_material_override.friction, 0.0)
		"reparent":
			var crate := root.get_node_or_null("Crate")
			return crate != null and crate.get_parent() == root
	return false

func _verify_scene_from_disk(id: String) -> bool:
	var packed: Variant = ResourceLoader.load(SCENE, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE)
	if not packed is PackedScene:
		return false
	var instance: Node = packed.instantiate()
	var ok := _verify(id, instance)
	instance.free()
	return ok

func _diff_lines(result: Dictionary) -> int:
	var diff := str(result.get("data", {}).get("diff", ""))
	if diff.is_empty(): return 0
	return Array(diff.split("\n")).filter(func(line): return line.begins_with("+") or line.begins_with("-")).size()

func _record_workspace(id: String, result: Dictionary, ms: float, verify_ok: bool) -> Dictionary:
	return {
		"ms": ms,
		"ok": bool(result.get("ok", false)) and verify_ok,
		"error": str(result.get("error", {}).get("code", "")),
		"file_writes": 1,
		"undo_actions": 0,
		"diff_lines": _diff_lines(result),
	}

func _record_editor(result: Dictionary, ms: float, verify_ok: bool, undo_actions: int) -> Dictionary:
	return {
		"ms": ms,
		"ok": bool(result.get("ok", false)) and verify_ok,
		"error": str(result.get("error", {}).get("code", "")),
		"file_writes": 1 if bool(result.get("ok", false)) else 0,
		"undo_actions": undo_actions,
		"diff_lines": 0,
	}

func _run() -> void:
	for index in range(30):
		await get_tree().process_frame
	dock = get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if dock == null:
		_fail("Tiiny dock is missing")
		return
	provider = dock.get("workspace_coding")
	var inspector_script: Script = dock.get("workspace_inspector_script")
	var transactions_script: Script = dock.get("workspace_transactions_script")
	if provider == null or inspector_script == null or transactions_script == null:
		_fail("Workspace providers were not injected")
		return
	inspector = inspector_script.new()
	transactions = transactions_script.new(inspector)

	var tasks: Array = []
	var workspace_total := 0.0
	var editor_total := 0.0
	for id in TASK_IDS:
		await _restore()
		var started := Time.get_ticks_usec()
		var workspace_result: Dictionary = await _workspace_solution(id)
		var workspace_ms := (Time.get_ticks_usec() - started) / 1000.0
		var workspace_ok := false
		if bool(workspace_result.get("ok", false)):
			if id.begins_with("script_"):
				workspace_ok = _verify(id, null)
			else:
				workspace_ok = _verify_scene_from_disk(id)
		var workspace_record := _record_workspace(id, workspace_result, workspace_ms, workspace_ok)
		if not bool(workspace_record.ok):
			_fail("Workspace solution failed for %s: %s" % [id, str(workspace_result)])

		await _restore()
		EditorInterface.open_scene_from_path(SCENE)
		if not await _wait_for_scene(SCENE):
			_fail("Bake-off scene did not open")
			return
		var root := EditorInterface.get_edited_scene_root()
		var context := _context()
		var history := EditorInterface.get_editor_undo_redo()
		var history_count := int(history.get_history_undo_redo(history.get_object_history_id(root)).get_history_count())
		started = Time.get_ticks_usec()
		var editor_result: Dictionary = _editor_solution(id, context)
		if bool(editor_result.get("ok", false)) and not id.begins_with("script_"):
			EditorInterface.save_scene()
		var editor_ms := (Time.get_ticks_usec() - started) / 1000.0
		var editor_ok := bool(editor_result.get("ok", false)) and _verify(id, EditorInterface.get_edited_scene_root())
		var undo_actions := 1 if bool(editor_result.get("ok", false)) and not id.begins_with("script_") else 0
		if undo_actions == 1 and int(history.get_history_undo_redo(history.get_object_history_id(root)).get_history_count()) <= history_count:
			_fail("Editor solution for %s did not create one undo action" % id)
		var editor_record := _record_editor(editor_result, editor_ms, editor_ok, undo_actions)
		if not bool(editor_record.ok):
			_fail("Editor solution failed for %s: %s" % [id, str(editor_result)])
		tasks.append({"id": id, "workspace": workspace_record, "editor": editor_record})
		workspace_total += workspace_ms
		editor_total += editor_ms
		await _restore()

	var recovery := await _recovery_checks()
	var report := {
		"fixture": "fixed scripted solutions in one disposable editor",
		"note": "Single-run wall-clock comparison of solution paths, not a model success rate. Times include only the solution tool calls, not verification or scene opening.",
		"tasks": tasks,
		"summary": {
			"task_count": tasks.size(),
			"workspace_ok": tasks.filter(func(task): return bool(task.workspace.ok)).size(),
			"editor_ok": tasks.filter(func(task): return bool(task.editor.ok)).size(),
			"workspace_total_ms": workspace_total,
			"editor_total_ms": editor_total,
			"workspace_median_ms": _median(tasks.map(func(task): return float(task.workspace.ms))),
			"editor_median_ms": _median(tasks.map(func(task): return float(task.editor.ms))),
			"workspace_undo_actions": tasks.reduce(func(total, task): return total + int(task.workspace.undo_actions), 0),
			"editor_undo_actions": tasks.reduce(func(total, task): return int(total) + int(task.editor.undo_actions), 0),
			"workspace_diff_lines": tasks.reduce(func(total, task): return int(total) + int(task.workspace.diff_lines), 0),
			"editor_diff_lines": tasks.reduce(func(total, task): return int(total) + int(task.editor.diff_lines), 0),
		},
		"recovery": recovery,
	}
	var report_path := OS.get_environment(REPORT_PATH_ENV)
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://bakeoff-report.json")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		_fail("Could not write the bake-off report")
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("Workspace bake-off completed: " + report_path)
	get_tree().quit(0)

func _median(values: Array) -> float:
	if values.is_empty(): return 0.0
	var copy := values.duplicate()
	copy.sort()
	var middle := copy.size() / 2
	if copy.size() % 2 == 1:
		return float(copy[middle])
	return (float(copy[middle - 1]) + float(copy[middle])) / 2.0

func _recovery_checks() -> Dictionary:
	await _restore()
	var original := FileAccess.get_file_as_string(SCENE)
	var hash := FileAccess.get_sha256(SCENE)
	_write(SCENE, original + "\n[node name=\"External\" type=\"Node2D\" parent=\".\"]\n")
	var stale: Dictionary = await provider.execute("write_file", {"path": SCENE, "content": original, "expected_sha256": hash})
	var preserved := FileAccess.get_file_as_string(SCENE).contains("[node name=\"External\"")
	var leftovers := Array(DirAccess.open("res://").get_files()).filter(func(name): return ".tiiny-tmp-" in name)
	await _restore()

	EditorInterface.open_scene_from_path(SCENE)
	await _wait_for_scene(SCENE)
	var root := EditorInterface.get_edited_scene_root()
	var context := _context()
	var history := EditorInterface.get_editor_undo_redo()
	var history_pair := history.get_history_undo_redo(history.get_object_history_id(root))
	var applied: Dictionary = transactions.execute("apply_editor_transaction", {"operations": [
		{"op": "create_node", "id": "recovery", "class": "Marker2D", "parent": ".", "name": "RecoveryMarker"},
	]}, context)
	var created := root.get_node_or_null("RecoveryMarker") != null
	var undone: bool = history_pair.undo() and root.get_node_or_null("RecoveryMarker") == null
	var redone: bool = history_pair.redo() and root.get_node_or_null("RecoveryMarker") != null
	await _restore()
	return {
		"workspace_stale_code": str(stale.get("error", {}).get("code", "")),
		"workspace_stale_rejected": str(stale.get("error", {}).get("code", "")) == "stale_hash",
		"workspace_stale_external_edit_preserved": preserved,
		"workspace_no_temp_files": leftovers.is_empty(),
		"editor_applied": bool(applied.get("ok", false)) and created,
		"editor_undo_restored": undone,
		"editor_redo_restored": redone,
	}
