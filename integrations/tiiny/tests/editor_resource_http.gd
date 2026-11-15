@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _run() -> void:
	var dock := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
	var jobs := get_tree().get_first_node_in_group("tiiny_job_manager")
	if dock == null or manager == null or jobs == null or not jobs.available:
		_fail("Built-in services unavailable")
		return
	var base := OS.get_environment("TIINY_TEST_HTTP_URL")
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("tiiny_ai/advanced/api_url", base + "/v1")
	settings.set_setting("tiiny_ai/advanced/device_address", base.trim_prefix("http://"))
	settings.set_setting("tiiny_ai/advanced/api_key", "fixture-secret-key")
	settings.set_setting("tiiny_ai/models/coding_model", "fixture-code")
	var deadline := Time.get_ticks_msec() + 30000
	while manager.busy and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	await manager.refresh_device()
	if not manager.is_ready():
		_fail("Fixture model inventory not ready")
		return
	if not jobs.queue.set_paused(true):
		_fail("Could not pause queue")
		return
	var result: Array = []
	dock.generate_shape_for_dialog("Fixture polygon", func(shape, error): result.assign([shape, error]))
	var state: Dictionary = jobs.queue.snapshot()
	if state.jobs.size() != 1 or state.jobs[0].operation != "resource_shape" or state.jobs[0].state != "queued":
		_fail("Resource request not queued")
		return
	await get_tree().create_timer(0.2).timeout
	if not result.is_empty():
		_fail("Paused resource dispatched")
		return
	jobs.queue.set_paused(false)
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if result.size() != 2 or not result[0] is ConvexPolygonShape2D or result[0].points.size() != 4:
		_fail("Queued loopback polygon failed: " + str(result))
		return
	if jobs.queue.snapshot().jobs[0].state != "completed":
		_fail("Resource callback preceded queue completion")
		return
	print("Queued resource loopback passed")
	get_tree().quit(0)
