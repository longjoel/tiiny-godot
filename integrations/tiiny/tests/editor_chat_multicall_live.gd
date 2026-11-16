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

func _run() -> void:
	await _frames(30)
	var dock: Node = get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	var jobs: Node = get_tree().get_first_node_in_group("tiiny_job_manager")
	var manager: Node = get_tree().get_first_node_in_group("tiiny_setup_manager")
	if dock == null or jobs == null or manager == null: _fail("Tiiny dock/Jobs/manager is missing"); return
	if not manager.is_ready():
		if not manager.busy: manager.refresh_device(true)
		if not await _wait_for(func(): return manager.is_ready(), 30000): _fail("Tiiny is not ready"); return
	EditorInterface.open_scene_from_path("res://game.tscn")
	if not await _wait_for(func(): return EditorInterface.get_edited_scene_root() != null, 15000): _fail("Game scene did not open"); return
	var root := EditorInterface.get_edited_scene_root()
	var icon := root.get_node_or_null("Icon")
	if icon == null: _fail("Icon fixture is missing"); return
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(icon)
	dock.prompt.text = FileAccess.get_file_as_string("res://prompt.txt").strip_edges()
	await dock._generate()
	var latest: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 300000
	while Time.get_ticks_msec() < deadline:
		for job in jobs.queue.snapshot().jobs:
			if job.operation == "chat_turn": latest = job
		if not latest.is_empty() and latest.get("state") in ["completed", "failed", "cancelled", "interrupted"]: break
		await get_tree().create_timer(0.2).timeout
	if latest.is_empty() or latest.get("state") not in ["completed", "failed", "cancelled", "interrupted"]:
		_fail("Live chat did not finish: " + str(latest)); return
	print("Live chat job state: ", latest.get("state", ""), " result=", JSON.stringify(latest.get("result", {})))
	print("Live chat ledger: ", JSON.stringify(dock.get("turn_ledger")))
	print("Live chat history: ", dock.history_text().replace("\n", " | "))
	print("Live chat messages: ", JSON.stringify(dock.get("turn_messages")))
	print("Live chat rounds: ", dock.get("tool_rounds"), " calls=", dock.get("tool_call_count"))
	if latest.get("state") != "completed": _fail("Live multi-call chat failed: " + str(latest)); return
	if str(latest.get("result", {}).get("error", "")).contains("more than one tool call"):
		_fail("Multi-call rejection still occurred"); return
	var result_text := str(latest.get("result", {}).get("response", ""))
	if result_text.strip_edges().is_empty(): _fail("Live chat completed without a response"); return
	var edited := FileAccess.get_file_as_string("res://bounce_script.gd")
	var capture := FileAccess.open("/tmp/tiiny-live-edited.gd", FileAccess.WRITE)
	if capture != null:
		capture.store_string(edited)
		capture.close()
	var requested := FileAccess.get_file_as_string("res://prompt.txt").strip_edges().to_lower()
	if requested.contains("spin") and not edited.contains("rotation +="):
		_fail("Live spin edit did not update the script: " + edited); return
	if requested.contains("velocity") and not edited.contains("velocity"):
		_fail("Live velocity edit did not preserve velocity logic: " + edited); return
	if requested.contains("sprite") or requested.contains("soccer"):
		var found_sprite := false
		var scene_lines: Array[String] = []
		for child in root.get_children():
			var texture_path := ""
			if child is Sprite2D and child.texture != null: texture_path = child.texture.resource_path
			scene_lines.append("%s [%s] texture=%s" % [child.name, child.get_class(), texture_path])
			if child is Sprite2D and child.name != "Icon" and texture_path.begins_with("res://tiiny_generated/"): found_sprite = true
		var scene_capture := FileAccess.open("/tmp/tiiny-live-sprite.txt", FileAccess.WRITE)
		if scene_capture != null:
			scene_capture.store_string("\n".join(scene_lines))
			scene_capture.close()
		if not found_sprite: _fail("Live generated-sprite scene is wrong: " + " | ".join(scene_lines)); return
		for child in root.get_children():
			if child is Sprite2D and child.name != "Icon" and child.texture != null and child.texture.resource_path.begins_with("res://tiiny_generated/"):
				var sprite_image: Image = child.texture.get_image()
				if sprite_image != null: sprite_image.save_png("/tmp/tiiny-live-sprite.png")
				break
	print("Live edited script saved to /tmp/tiiny-live-edited.gd")
	print("Live multi-call chat passed.")
	get_tree().quit(0)
