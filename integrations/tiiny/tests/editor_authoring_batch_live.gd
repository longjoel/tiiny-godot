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
	var deadline := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < deadline:
		for job in jobs.queue.snapshot().jobs:
			if job.operation == "chat_turn": latest = job
		if not latest.is_empty() and latest.get("state") in ["completed", "failed", "cancelled", "interrupted"]: break
		await get_tree().create_timer(0.2).timeout
	print("Prompt: ", prompt)
	print("  state=", latest.get("state", ""), " result=", JSON.stringify(latest.get("result", {})))
	print("  ledger=", JSON.stringify(dock.get("turn_ledger")))
	return latest

func _save_clean() -> bool:
	EditorInterface.save_scene()
	return await _wait_for(func(): return not (EditorInterface.get_edited_scene_root().scene_file_path in EditorInterface.get_unsaved_scenes()), 15000)

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
	var first: Dictionary = await _run_prompt(dock, jobs, "Make the Torch light flicker.")
	if first.get("state") != "completed": _fail("Torch prompt failed: " + str(first)); return
	var torch: Node = root.get_node_or_null("Torch")
	var players: Array = torch.find_children("*", "AnimationPlayer", true, false) if torch != null else []
	if players.is_empty(): _fail("Torch flicker did not create an AnimationPlayer"); return
	if not await _save_clean(): _fail("Could not save after torch"); return
	root = EditorInterface.get_edited_scene_root()
	var second: Dictionary = await _run_prompt(dock, jobs, "Make the Platform slippery.")
	if second.get("state") != "completed": _fail("Slippery prompt failed: " + str(second)); return
	var platform: StaticBody2D = root.get_node_or_null("Platform")
	if platform == null or not platform.physics_material_override is PhysicsMaterial or platform.physics_material_override.friction > 0.1:
		_fail("Slippery material missing: " + str(platform.physics_material_override if platform != null else null)); return
	if not await _save_clean(): _fail("Could not save after slippery"); return
	root = EditorInterface.get_edited_scene_root()
	var third: Dictionary = await _run_prompt(dock, jobs, "Add a 32 by 48 rectangular collision shape to Player.")
	if third.get("state") != "completed": _fail("Collision prompt failed: " + str(third)); return
	var shape: CollisionShape2D = root.get_node_or_null("Player/CollisionShape2D")
	if shape == null or not shape.shape is RectangleShape2D or shape.shape.size != Vector2(32, 48):
		_fail("Collision shape missing or wrong: " + str(shape)); return
	if not await _save_clean(): _fail("Could not save after collision"); return
	var lines: Array[String] = []
	lines.append("Torch AnimationPlayers=%d" % players.size())
	lines.append("Platform friction=%.2f" % platform.physics_material_override.friction)
	lines.append("Player collision=%s %s" % [shape.shape.get_class(), str(shape.shape.size)])
	var capture := FileAccess.open("/tmp/tiiny-live-authoring-batch.txt", FileAccess.WRITE)
	if capture != null:
		capture.store_string("\n".join(lines))
		capture.close()
	print("Live authoring batch: ", " | ".join(lines))
	print("Live authoring batch passed.")
	get_tree().quit(0)
