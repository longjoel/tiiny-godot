@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _run() -> void:
	for index in range(30): await get_tree().process_frame
	var jobs := get_tree().get_first_node_in_group("tiiny_job_manager")
	var real_dock := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	var real_manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
	if jobs == null or real_dock == null or real_manager == null or not jobs.available:
		_fail("Editor services are unavailable"); return
	jobs.queue.set_paused(true)
	real_manager.remove_from_group("tiiny_setup_manager")
	var manager = load("res://fake_model_manager.gd").new()
	get_tree().root.add_child(manager)
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("tiiny_ai/models/coding_model", "code")
	settings.set_setting("tiiny_ai/models/image_model", "requested")
	manager.fixture_state = {
		"models": {
			"code": {"name": "Code", "type": "Text Generation", "supported": ["Tool Use"], "npu": 47, "bytes": 100, "installed": true, "max_context": 32768},
			"warm": {"name": "Warm", "type": "Text-to-Image", "supported": [], "npu": 23, "bytes": 100, "installed": true, "max_context": 0},
			"requested": {"name": "Requested", "type": "Text-to-Image", "supported": [], "npu": 40, "bytes": 100, "installed": true, "max_context": 0},
		},
		"loaded": {"code": 47.0, "warm": 23.0}, "npu_total": 100, "npu_used": 70,
		"disk_free": 100 * 1073741824, "disk_total": 200 * 1073741824, "connection": "b".repeat(64),
	}
	var saved := {"roles": {}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
	for role in manager.ROLES:
		saved.roles[role] = {"model": "code" if role == "coding_model" else ("warm" if role == "image_model" else ""), "context": 8192 if role == "coding_model" else 0, "warm": role in ["coding_model", "image_model"]}
	settings.set_setting("_tiiny_ai/applied_configuration", saved)
	manager.draft = saved.duplicate(true)
	manager.draft_initialized = true
	manager.snapshot = manager.fixture_state.duplicate(true)
	manager.snapshot["time"] = Time.get_ticks_msec()
	manager.connected = true
	manager.connection_identity = "b".repeat(64)
	manager.next_restore_check_msec = Time.get_ticks_msec() + 60000
	var fake = load("res://fake_asset_pipeline_chat.gd").new()
	get_tree().root.add_child(fake)
	fake.jobs_service = jobs
	jobs.chat_service = fake
	var image := Image.create(2, 3, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	fake.reference_png = image.save_png_to_buffer()
	var accepted: Variant = JSON.parse_string(fake._append_job_tool({"operation": "asset_generate", "kind": "image", "text": "planner fixture"}))
	if not accepted is Dictionary or not accepted.get("accepted", false):
		_fail("Managed image was not accepted: " + str(accepted)); return
	jobs.queue.set_paused(false)
	var deadline := Time.get_ticks_msec() + 30000
	var record: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		record = jobs.get_job_status(accepted.id)
		if record.get("state") in ["completed", "failed", "cancelled", "interrupted"]: break
		await get_tree().create_timer(0.05).timeout
	var expected := [["unload", "warm"], ["load", "requested"], ["unload", "requested"], ["load", "warm"]]
	if record.get("state") != "completed" or manager.calls != expected or manager.fixture_state.loaded != {"code": 47.0, "warm": 23.0}:
		_fail("Managed image did not execute and restore the planned warm set: " + str(record) + " calls=" + str(manager.calls)); return
	if not FileAccess.file_exists(str(record.get("result", {}).get("artifact", ""))) or fake.image_responses != 1 or jobs.device_recovery_pending():
		_fail("Managed image artifact or device journal is invalid: " + str(record)); return
	print("Managed image planner fixture passed.")
	get_tree().quit(0)
