@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _frames(count: int) -> void:
	for index in range(count):
		await get_tree().process_frame

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _wait_for(predicate: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()): return true
		await get_tree().create_timer(0.1).timeout
	return false

func _run_prompt(dock: Node, jobs: Node, prompt: String) -> Dictionary:
	dock.prompt.text = prompt
	await dock._generate()
	var latest: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 300000
	while Time.get_ticks_msec() < deadline:
		for job in jobs.queue.snapshot().jobs:
			if job.operation == "chat_turn": latest = job
		if not latest.is_empty() and latest.get("state") in ["completed", "failed", "cancelled", "interrupted"]: break
		await get_tree().create_timer(0.2).timeout
	print("Prompt: ", prompt)
	print("  state=", latest.get("state", ""), " result=", JSON.stringify(latest.get("result", {})))
	print("  ledger=", JSON.stringify(dock.get("turn_ledger")))
	print("  messages=", JSON.stringify(dock.get("turn_messages")))
	return latest

func _run() -> void:
	await _frames(30)
	var dock: Node = get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	var jobs: Node = get_tree().get_first_node_in_group("tiiny_job_manager")
	var manager: Node = get_tree().get_first_node_in_group("tiiny_setup_manager")
	if dock == null or jobs == null or manager == null: _fail("Tiiny dock/Jobs/manager is missing"); return
	if not manager.is_ready():
		if not manager.busy: manager.refresh_device(true)
		if not await _wait_for(func(): return manager.is_ready(), 30000): _fail("Tiiny is not ready"); return
	EditorInterface.open_scene_from_path("res://main.tscn")
	if not await _wait_for(func(): return EditorInterface.get_edited_scene_root() != null, 15000): _fail("Scene did not open"); return
	var root := EditorInterface.get_edited_scene_root()
	var first: Dictionary = await _run_prompt(dock, jobs, "Add a Camera2D named MainCamera with position (100, 200) and position smoothing enabled. Add a Label named ScoreLabel showing 'Score: 0' at the top left.")
	if first.get("state") != "completed": _fail("First composed prompt failed: " + str(first)); return
	var camera: Camera2D = root.get_node_or_null("MainCamera")
	var label: Label = root.get_node_or_null("ScoreLabel")
	if camera == null or not camera.position_smoothing_enabled or camera.position != Vector2(100, 200):
		_fail("Live Camera2D composition is wrong: " + str(camera)); return
	if label == null or label.text != "Score: 0" or label.position.x < 0 or label.position.y < 0 or label.position.x > 20 or label.position.y > 20:
		_fail("Live Label composition is wrong: " + str(label) + " pos=" + str(label.position if label != null else "")); return
	EditorInterface.save_scene()
	if not await _wait_for(func(): return not (EditorInterface.get_edited_scene_root().scene_file_path in EditorInterface.get_unsaved_scenes()), 15000): _fail("Could not save after first prompt"); return
	root = EditorInterface.get_edited_scene_root()
	var second: Dictionary = await _run_prompt(dock, jobs, "Make the Crate metallic and rough using a StandardMaterial3D.")
	if second.get("state") != "completed": _fail("Second composed prompt failed: " + str(second)); return
	var crate: MeshInstance3D = root.get_node_or_null("World/Crate")
	if crate == null or not crate.material_override is StandardMaterial3D:
		_fail("Live PBR composition is missing material: " + str(crate)); return
	var material: StandardMaterial3D = crate.material_override
	if not is_equal_approx(material.metallic, 1.0) or material.roughness < 0.5:
		_fail("Live PBR material values are wrong: " + str(material)); return
	var lines: Array[String] = []
	for child in root.get_children():
		lines.append("%s [%s] pos=%s" % [child.name, child.get_class(), str(child.position) if child is Node2D else ""])
	lines.append("Crate material=%s metallic=%.2f roughness=%.2f" % [material.get_class(), material.metallic, material.roughness])
	var capture := FileAccess.open("/tmp/tiiny-live-primitives.txt", FileAccess.WRITE)
	if capture != null:
		capture.store_string("\n".join(lines))
		capture.close()
	print("Live composed scene: ", " | ".join(lines))
	print("Live composed editor primitives passed.")
	get_tree().quit(0)
