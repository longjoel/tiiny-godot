@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _frames(count: int) -> void:
	for index in range(count):
		await get_tree().process_frame

func _run() -> void:
	await _frames(40)
	var jobs: Node = get_tree().get_first_node_in_group("tiiny_job_manager")
	if jobs == null:
		push_error("Jobs panel is missing")
		get_tree().quit(1)
		return
	var dock: Node = jobs.get_parent()
	if dock != null and dock.has_method("open"): dock.call("open")
	if dock != null and dock.has_method("make_visible"): dock.call("make_visible")
	await _frames(10)
	var accepted: Dictionary = jobs.append_job("display-fixture", "create_tree", {"destination": "res://assets/display.png", "timeout_ms": 30000})
	if accepted.has("error"):
		push_error("Displayed fixture job was not queued: " + str(accepted))
		get_tree().quit(1)
		return
	var deadline := Time.get_ticks_msec() + 30000
	while jobs.get_job_status(accepted.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.1).timeout
	var state: Dictionary = jobs.get_job_status(accepted.id)
	if state.get("state") != "completed":
		push_error("Displayed fixture job did not complete: " + str(state))
		get_tree().quit(1)
		return
	await _frames(20)
	if not jobs.is_visible_in_tree():
		push_error("Jobs panel is not visible")
		get_tree().quit(1)
		return
	var image := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		push_error("Could not capture the editor viewport")
		get_tree().quit(1)
		return
	var error := image.save_png("/tmp/tiiny-jobs-displayed.png")
	if error != OK:
		push_error("Could not save the Jobs capture: " + str(error))
		get_tree().quit(1)
		return
	print("Displayed Jobs capture passed size=", image.get_size(), " job=", state.get("id", ""), " state=", state.get("state", ""))
	get_tree().quit(0)
