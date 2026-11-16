@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = [node]
	for child in node.get_children(true): result.append_array(_descendants(child))
	return result

func _find_section(item: TreeItem, section := "tiiny_ai/models") -> TreeItem:
	if item == null: return null
	if item.get_metadata(0) == section: return item
	var child := item.get_first_child()
	while child:
		var found := _find_section(child, section)
		if found: return found
		child = child.get_next()
	return null

func _fail(reason: String) -> void:
	push_error(reason)
	get_tree().quit(1)

func _test_inventory_failures() -> bool:
	var fake = load("res://fake_inventory_manager.gd").new()
	get_tree().root.add_child(fake)
	await fake.refresh_device()
	if fake.busy or fake.connected or fake.is_ready() or not fake.plan.is_empty() or fake.requests.size() != 1: return false
	await fake.check_config()
	if fake.busy or fake.connected or not fake.plan.is_empty() or fake.requests.size() != 2: return false
	# A valid empty catalog is available but cannot satisfy the required coding model.
	fake.responses = {
		"/api/v1/models/online_models": {"data": []},
		"/api/v1/models/npu/status": {"data": {"npu_total": 100, "npu_used": 0, "models": []}},
		"/api/v1/sys/storage": {"data": {"total_bytes": 100 * 1073741824, "remaining_bytes": 80 * 1073741824}}
	}
	await fake.refresh_device()
	if not fake.connected or fake.is_ready() or fake.busy: return false
	await fake.check_config()
	if fake.plan.get("ok", true) or fake.busy: return false
	# Invalid catalog envelopes and later capacity errors terminate; no fallback loop.
	fake.responses["/api/v1/models/online_models"] = {"data": {}}
	await fake.refresh_device()
	if fake.connected or fake.busy or not fake.plan.is_empty(): return false
	fake.responses["/api/v1/models/online_models"] = {"data": []}
	fake.responses["/api/v1/models/npu/status"] = {"error": "Fixture capacity unavailable."}
	var before: int = fake.requests.size()
	await fake.check_config()
	if fake.connected or fake.busy or fake.requests.size() - before != 2: return false
	if not fake.message.contains("Fixture capacity unavailable"): return false
	fake.responses["/api/v1/models/npu/status"] = {"data": {"npu_total": 100, "npu_used": 0, "models": "malformed"}}
	await fake.refresh_device()
	if fake.connected or fake.busy: return false
	fake.responses["/api/v1/models/online_models"] = {"data": [null]}
	await fake.refresh_device()
	if fake.connected or fake.busy: return false
	# Verify distinct failure states and a later read-only recovery through the
	# real manager path; the fake refuses any SDK mutation.
	for failure in ["Device request failed (connection 0, HTTP 401).", "Device request failed (connection 1, HTTP 0)."]:
		fake.responses["/api/v1/models/online_models"] = {"error": failure}
		await fake.refresh_device()
		if fake.connected or fake.is_ready() or not fake.snapshot.is_empty() or not fake.plan.is_empty(): return false
		if fake.last_error_type != ("auth" if "401" in failure else "disconnect"): return false
		if "401" in failure and not fake.message.contains("authentication failed"): return false
	fake.responses["/api/v1/models/online_models"] = {"data": []}
	fake.responses["/api/v1/models/npu/status"] = {"data": {"npu_total": 0, "npu_used": 0, "models": []}}
	await fake.refresh_device()
	if fake.connected or fake.is_ready() or fake.last_error_type != "capacity" or not fake.snapshot.is_empty(): return false
	fake.responses["/api/v1/models/npu/status"] = {"data": {"npu_total": 100, "npu_used": 0, "models": []}}
	await fake.refresh_device()
	if not fake.connected or fake.busy or fake.is_ready() or fake.last_error_type != "": return false
	fake.queue_free()
	await get_tree().process_frame
	print("Offline inventory failures terminate without readiness or SDK execution.")
	return true

func _test_apply_contract() -> bool:
	var fake = load("res://fake_manager.gd").new()
	get_tree().root.add_child(fake)
	await fake._poll_download_progress({}, ["download", "fixture-model"])
	if not fake.message.contains("42.5% (device)"): return false
	var progress_count: int = fake.operation_log.size()
	await fake._poll_download_progress({}, ["download", "fixture-model"])
	if fake.operation_log.size() != progress_count: return false
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("tiiny_ai/models/coding_model", "code")
	var fixture := {"models": {"code": {"name": "Code", "type": "Text Generation", "supported": ["Tool Use"], "npu": 47, "bytes": 100, "installed": true, "max_context": 32768}, "image": {"name": "Image", "type": "Text-to-Image", "npu": 23, "bytes": 100, "installed": true, "max_context": 0}}, "loaded": {"code": 47, "image": 23}, "npu_total": 100, "npu_used": 70, "disk_free": 100 * 1073741824, "disk_total": 200 * 1073741824, "connection": "f".repeat(64)}
	fake.fixture_state = fixture.duplicate(true)
	fake.draft_initialized = true
	fake.draft = {"roles": {}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
	for role in fake.ROLES:
		fake.draft.roles[role] = {"model": "code" if role == "coding_model" else "image" if role == "image_model" else "", "context": 8192 if role == "coding_model" else 0, "warm": role == "coding_model"}
	await fake.check_config()
	if not fake.plan.get("ok", false) or not fake.calls.is_empty(): return false
	await fake.fixture_apply_config()
	if fake.calls != [["unload", "image"]] or not fake.fixture_state.loaded.has("code"): return false
	# A stale device state invalidates the checked operations before any mutation.
	fake.fixture_state = fixture.duplicate(true)
	fake.calls.clear()
	await fake.check_config()
	fake.fixture_state.loaded.erase("image")
	await fake.fixture_apply_config()
	if not fake.calls.is_empty() or not fake.plan.is_empty(): return false
	# A false-positive CLI success cannot pass post-operation verification.
	fake.fixture_state = fixture.duplicate(true)
	fake.calls.clear()
	fake.omit_effect = true
	await fake.check_config()
	await fake.fixture_apply_config()
	if not fake.plan.is_empty() or fake.applying or fake.busy: return false
	if not fake.message.contains("did not confirm"): return false
	# Expired checks never invoke the mutating adapter.
	fake.calls.clear()
	await fake.check_config()
	fake.plan.checked_at = Time.get_ticks_msec() - 61000
	await fake.fixture_apply_config()
	if not fake.calls.is_empty() or not fake.plan.is_empty(): return false
	fake.fail_command = true
	fake.omit_effect = false
	fake.fixture_state = fixture.duplicate(true)
	fake.draft.roles.coding_model.context = 16384
	await fake.check_config()
	await fake.fixture_apply_config()
	if not fake.message.contains("Operation failed") or int(settings.get_setting("tiiny_ai/models/context_tokens")) != 8192: return false
	# Invalid coding capability and insufficient capacity are rejected before any SDK action.
	fake.fail_command = false
	fake.fixture_state = fixture.duplicate(true)
	fake.calls.clear()
	fake.fixture_state.models.code.supported = []
	await fake.check_config()
	if fake.plan.get("ok", true): return false
	await fake.fixture_apply_config()
	if not fake.calls.is_empty(): return false
	fake.fixture_state = fixture.duplicate(true)
	fake.fixture_state.npu_total = 40
	await fake.check_config()
	if fake.plan.get("ok", true) or not fake.calls.is_empty(): return false
	# Zero exit status is insufficient for either download or load, including a partial load.
	for mode in ["download", "load", "partial"]:
		fake.fixture_state = fixture.duplicate(true)
		fake.fixture_state.loaded.erase("image")
		fake.fixture_state.models.image.installed = mode != "download"
		fake.calls.clear()
		fake.omit_effect = mode != "partial"
		fake.partial_load = mode == "partial"
		fake.draft.roles.image_model.warm = true
		await fake.check_config()
		if not fake.plan.get("ok", false): return false
		await fake.fixture_apply_config()
		if fake.calls.is_empty() or not fake.plan.is_empty() or fake.applying or fake.busy: return false
		if mode == "partial" and not fake.message.contains("NPU allocation"): return false
		if mode != "partial" and not fake.message.contains("did not confirm"): return false
		if not fake.fixture_state.loaded.has("code"): return false
	fake.omit_effect = false
	fake.partial_load = false
	fake.draft.roles.image_model.warm = false
	# A post-operation authentication or disconnect failure cannot report readiness.
	for failure in ["Device request failed (connection 0, HTTP 401).", "Device request failed (connection 1, HTTP 0)."]:
		fake.fixture_state = fixture.duplicate(true)
		fake.snapshot_error = ""
		fake.error_after_command = failure
		fake.calls.clear()
		await fake.check_config()
		if not fake.plan.get("ok", false): return false
		await fake.fixture_apply_config()
		if fake.connected or fake.is_ready() or fake.calls.is_empty() or not fake.plan.is_empty(): return false
		if fake.last_error_type != ("auth" if "401" in failure else "disconnect"): return false
		if not fake.snapshot.is_empty(): return false
		if "401" in failure and not fake.message.contains("authentication failed"): return false
	fake.snapshot_error = ""
	fake.error_after_command = ""
	fake.queue_free()
	await get_tree().process_frame
	print("Staged Apply contract passed with fake transport; no device mutation.")
	return true

func _fixture_config(manager: Node) -> Dictionary:
	var config := {"roles": {}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
	for role in manager.ROLES:
		config.roles[role] = {"model": "", "context": 0, "warm": false}
	config.roles.coding_model = {"model": "code", "context": 8192, "warm": true}
	config.roles.image_model = {"model": "image", "context": 0, "warm": true}
	return config

func _run_settings_stage(manager: Node, stage: String) -> void:
	var settings := EditorInterface.get_editor_settings()
	var applied: Variant = settings.get_setting("_tiiny_ai/applied_configuration")
	if stage == "save":
		var saved := _fixture_config(manager)
		settings.set_setting("_tiiny_ai/applied_configuration", saved)
		settings.set_setting("tiiny_ai/models/coding_model", "code")
		manager.draft = saved.duplicate(true)
		manager.draft_initialized = true
		var unsaved: Dictionary = saved.duplicate(true)
		unsaved.roles.image_model.warm = false
		manager.update_draft(unsaved)
		if not manager.has_unapplied_changes(): _fail("Unsaved draft was not marked.")
		if settings.get_setting("_tiiny_ai/applied_configuration") != saved: _fail("Unsaved draft overwrote applied settings.")
		print("Settings restart save passed")
		get_tree().quit()
		return
	if stage == "unsaved":
		if not applied is Dictionary or not applied.roles.image_model.warm: _fail("Applied warm selection did not survive restart.")
		if manager.draft != applied: _fail("Restart did not restore the applied draft.")
		if manager.has_unapplied_changes(): _fail("Applied configuration was reported as unsaved after restart.")
		var edited: Dictionary = manager.draft.duplicate(true)
		edited.roles.image_model.warm = false
		manager.update_draft(edited)
		if not manager.has_unapplied_changes(): _fail("New unsaved edit was not marked.")
		if settings.get_setting("_tiiny_ai/applied_configuration") != applied: _fail("Unsaved edit overwrote applied settings.")
		print("Settings restart unsaved passed")
		get_tree().quit()
		return
	if stage == "final":
		var expected := _fixture_config(manager)
		if applied != expected: _fail("Applied warm selection changed across restart.")
		if manager.draft != expected: _fail("Session-only draft leaked into the next restart.")
		if manager.has_unapplied_changes(): _fail("Restored applied configuration was reported as unsaved.")
		print("Settings restart final passed")
		get_tree().quit()
		return
	_fail("Unknown settings restart stage: " + stage)

func _run_live_apply(manager: Node) -> void:
	var settings := EditorInterface.get_editor_settings()
	await manager.refresh_device()
	if not manager.connected: _fail("Live Apply refresh failed: " + manager.message)
	var models: Dictionary = manager.snapshot.get("models", {})
	var original_warm: Array = manager.snapshot.get("loaded", {}).keys()
	original_warm.sort()
	var coding := ""
	for id in original_warm:
		if manager.Planner.suitable("coding_model", models.get(id, {})):
			coding = str(id)
			break
	if coding.is_empty(): _fail("Live Apply needs an already-warm compatible coding model.")
	var target := OS.get_environment("TIINY_TEST_LIVE_APPLY_MODEL").strip_edges()
	if not target.is_empty():
		if not models.has(target): _fail("Requested live Apply model is not in the catalog: " + target)
	else:
		for id in models:
			var model: Dictionary = models[id]
			if str(model.get("type", "")) != "Text-to-Speech" or bool(model.get("installed", false)): continue
			if float(model.get("npu", -1)) < 0 or float(model.get("bytes", -1)) <= 0: continue
			if target.is_empty() or float(model.bytes) < float(models[target].bytes): target = str(id)
	if target.is_empty(): _fail("Live Apply found no downloadable Text-to-Speech model.")
	settings.set_setting("tiiny_ai/models/coding_model", coding)
	settings.set_setting("tiiny_ai/models/context_tokens", 8192)
	if bool(models[target].get("installed", false)):
		if not manager.is_ready(): _fail("Coding model was not ready before live Apply verification.")
		print("Live Apply download passed: ", target, "; already installed; warm set unchanged: ", original_warm)
		get_tree().quit()
		return
	var config := {"roles": {}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
	for role in manager.ROLES:
		config.roles[role] = {"model": "", "context": 0, "warm": false}
	config.roles.coding_model = {"model": coding, "context": 8192, "warm": true}
	config.roles.speech_model = {"model": target, "context": 0, "warm": false}
	manager.draft_initialized = true
	manager.update_draft(config)
	await manager.check_config()
	if not manager.plan.get("ok", false):
		_fail("Live Apply Check Config failed: " + str(manager.plan.get("errors", [])))
		return
	var expected := [{"verb": "download", "id": target}]
	if manager.plan.get("actions", []) != expected:
		_fail("Live Apply plan was not a single download: " + str(manager.plan.get("actions", [])))
		return
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	if service == null: _fail("Live Apply Jobs service is unavailable.")
	print("Live Apply baseline warm set: ", original_warm, "; coding: ", coding, "; download: ", target, " (", int(models[target].bytes), " bytes)")
	manager.apply_config()
	if not manager.plan.is_empty(): _fail("Live Apply did not queue: " + manager.message)
	var job_id := ""
	var deadline := Time.get_ticks_msec() + 900000
	while Time.get_ticks_msec() < deadline:
		if job_id.is_empty():
			for job in service.queue.snapshot().jobs:
				if job.operation == "model_apply" and job.state in ["queued", "running", "completed", "failed", "cancelled", "interrupted"]:
					job_id = str(job.id)
		if not job_id.is_empty():
			var status: Dictionary = service.get_job_status(job_id)
			if status.get("state") == "completed": break
			if status.get("state") in ["failed", "cancelled", "interrupted", "skipped"]:
				_fail("Live Apply job stopped: " + str(status.get("state")) + " " + str(status.get("error", "")))
		await get_tree().create_timer(1.0).timeout
	if job_id.is_empty(): _fail("Live Apply job was never queued.")
	var final_status: Dictionary = service.get_job_status(job_id)
	if final_status.get("state") != "completed": _fail("Live Apply timed out: " + str(final_status.get("state")))
	await manager.refresh_device()
	if not manager.connected: _fail("Live Apply final refresh failed: " + manager.message)
	var final_models: Dictionary = manager.snapshot.get("models", {})
	if not final_models.has(target) or not final_models[target].get("installed", false):
		_fail("Device did not report the download as installed: " + target)
	var final_warm: Array = manager.snapshot.get("loaded", {}).keys()
	final_warm.sort()
	if final_warm != original_warm: _fail("Live Apply changed the warm set: " + str(final_warm))
	if not manager.is_ready(): _fail("Coding model was not ready after the download.")
	var progress: Array = Array(manager.operation_log).filter(func(line): return "download" in str(line).to_lower() and "%" in str(line))
	print("Live Apply download passed: ", target, "; installed; warm set unchanged: ", final_warm, "; progress lines: ", progress.size())
	if not progress.is_empty(): print("Live Apply progress sample: ", progress.back())
	get_tree().quit()

func _fixture_snapshot(manager: Node, age_ms := 0) -> Dictionary:
	var models := {
		"code": {"id": "code", "name": "Code", "type": "Text Generation", "description": "Scripting coordinator", "supported": ["Tool Use"], "npu": 47.0, "bytes": 16 * 1073741824, "max_context": 32768, "installed": true, "loaded": true, "state": "running"},
		"image": {"id": "image", "name": "Image", "type": "Text-to-Image", "description": "Image generation", "supported": [], "npu": 23.0, "bytes": 10 * 1073741824, "max_context": 0, "installed": true, "loaded": true, "state": "running"},
		"new_image": {"id": "new_image", "name": "New Image", "type": "Text-to-Image", "description": "Not downloaded yet", "supported": [], "npu": 20.0, "bytes": 8 * 1073741824, "max_context": 0, "installed": false, "loaded": false, "state": "not_downloaded"}
	}
	return {"models": models, "loaded": {"code": 47.0, "image": 23.0}, "npu_total": 100.0, "npu_used": 70.0, "disk_total": 200 * 1073741824, "disk_free": 100 * 1073741824, "connection": "f".repeat(64), "time": Time.get_ticks_msec() - age_ms}

func _fixture_plan() -> Dictionary:
	return {"ok": true, "errors": [], "warnings": ["Context is a client-side request budget.", "SSD includes one staging allowance."], "actions": [{"verb": "download", "id": "new_image"}, {"verb": "load", "id": "new_image"}], "npu_projected": 93.0, "npu_remaining": 7.0, "npu_reserve": 5.0, "download_bytes": 8 * 1073741824, "disk_projected_free": 90 * 1073741824, "disk_peak_free": 82 * 1073741824, "disk_reserve": 2 * 1073741824, "checked_at": Time.get_ticks_msec()}

func _capture_window(window: Window, path: String) -> bool:
	for count in range(3): await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := window.get_texture().get_image()
	return image != null and image.save_png(path) == OK

func _capture_panel_states(capture: String) -> void:
	var fake = load("res://fake_manager.gd").new()
	get_tree().root.add_child(fake)
	var settings := EditorInterface.get_editor_settings()
	var previous_applied: Variant = settings.get_setting("_tiiny_ai/applied_configuration")
	settings.set_setting("_tiiny_ai/applied_configuration", _fixture_config(fake))
	fake.connected = true
	fake.draft = _fixture_config(fake)
	fake.draft_initialized = true
	fake.snapshot = _fixture_snapshot(fake)
	fake.plan = _fixture_plan()
	var panel: Control = fake.create_configuration_panel()
	var window := Window.new()
	window.title = "Models state capture"
	window.size = Vector2i(1400, 900)
	get_tree().root.add_child(window)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	window.add_child(panel)
	window.popup_centered()
	var states := ["fresh", "stale", "incompatible", "applying", "failed"]
	for width in [1400, 600]:
		window.size = Vector2i(width, 900)
		for state in states:
			fake.connected = true
			fake.applying = false
			fake.busy = false
			fake.last_operation_failed = false
			fake.snapshot = _fixture_snapshot(fake)
			fake.draft = _fixture_config(fake)
			fake.plan = _fixture_plan()
			fake.message = "Review the plan, then Apply."
			match state:
				"stale": fake.snapshot = _fixture_snapshot(fake, 78000)
				"incompatible":
					fake.draft.roles.coding_model.model = "image"
					var incompatible: Dictionary = _fixture_plan()
					incompatible.ok = false
					incompatible.errors = ["image is not compatible with Scripting."]
					incompatible.actions = []
					fake.plan = incompatible
				"applying":
					fake.applying = true
					fake.busy = true
					fake.current_operation = {"verb": "download", "id": "new_image"}
					fake.current_progress = 42.5
					fake.operation_started = Time.get_ticks_msec() - 12000
				"failed":
					fake.last_operation_failed = true
					fake.operation_log = PackedStringArray(["unload image", "load code", "download new_image"])
					fake.message = "Tiiny did not confirm the requested download. Stopped before the next operation."
			panel._render()
			if not await _capture_window(window, capture.path_join("models-%s-%d.png" % [state, width])):
				_fail("Displayed Models state capture failed: " + state)
	# Plan details uses the same dialog pattern as model Info.
	fake.last_operation_failed = false
	fake.plan = _fixture_plan()
	panel._render()
	panel._show_plan_details()
	await get_tree().process_frame
	var details: AcceptDialog = panel.find_child("ModelInformation", true, false)
	if details == null or not await _capture_window(details, capture.path_join("models-plan-details.png")):
		_fail("Displayed plan-details capture failed.")
	details.hide()
	window.hide()
	window.queue_free()
	fake.queue_free()
	if previous_applied != null: settings.set_setting("_tiiny_ai/applied_configuration", previous_applied)
	await get_tree().process_frame
	print("Displayed Models state captures saved.")

func _test_coding_adoption() -> bool:
	var fake = load("res://fake_manager.gd").new()
	get_tree().root.add_child(fake)
	var settings := EditorInterface.get_editor_settings()
	var previous_coding: Variant = settings.get_setting("tiiny_ai/models/coding_model")
	var previous_applied: Variant = settings.get_setting("_tiiny_ai/applied_configuration") if settings.has_setting("_tiiny_ai/applied_configuration") else null
	var config := {"roles": {}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
	for role in fake.ROLES:
		config.roles[role] = {"model": "", "context": 0, "warm": false}
	config.roles.coding_model = {"model": "Qwen/Qwen3.6-35B-A3B", "context": 8192, "warm": true}
	settings.set_setting("tiiny_ai/models/coding_model", "Qwen/Qwen3.6-35B-A3B")
	settings.set_setting("_tiiny_ai/applied_configuration", config)
	fake.snapshot = {"models": {"Qwen/Qwen3.6-35B-A3B": {"id": "Qwen/Qwen3.6-35B-A3B", "name": "Qwen3.6", "type": "Image-Text-to-Text", "supported": ["Tool Use"], "npu": 47.0, "bytes": 100, "max_context": 262144, "installed": true, "loaded": false}, "ornith-ai/Ornith-1.5-35B-A3B-Turbo": {"id": "ornith-ai/Ornith-1.5-35B-A3B-Turbo", "name": "Ornith", "type": "Image-Text-to-Text", "supported": ["Tool Use"], "npu": 54.0, "bytes": 100, "max_context": 262144, "installed": true, "loaded": true}}, "loaded": {"ornith-ai/Ornith-1.5-35B-A3B-Turbo": 54.0}, "npu_total": 100.0, "npu_used": 54.0, "disk_free": 100 * 1073741824, "disk_total": 200 * 1073741824, "time": Time.get_ticks_msec()}
	fake.draft = config.duplicate(true)
	fake.draft_initialized = true
	fake.connected = true
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	var stale_id := ""
	if service != null:
		var stale: Dictionary = service.append_job("adopt-stale-restore", "model_restore", {"model": "Qwen/Qwen3.6-35B-A3B", "connection": "b".repeat(64), "timeout_ms": 7200000})
		stale_id = str(stale.get("id", ""))
	fake._adopt_loaded_coding_model("ornith-ai/Ornith-1.5-35B-A3B-Turbo")
	var adopted: bool = str(settings.get_setting("tiiny_ai/models/coding_model")) == "ornith-ai/Ornith-1.5-35B-A3B-Turbo"
	var saved: Variant = settings.get_setting("_tiiny_ai/applied_configuration")
	var persisted: bool = saved is Dictionary and saved.roles.coding_model.model == "ornith-ai/Ornith-1.5-35B-A3B-Turbo"
	var drafted: bool = fake.draft.roles.coding_model.model == "ornith-ai/Ornith-1.5-35B-A3B-Turbo"
	var stale_cancelled: bool = stale_id.is_empty() or (service != null and service.get_job_status(stale_id).get("state") == "cancelled")
	var before: int = service.queue.snapshot().jobs.size() if service != null else 0
	fake._schedule_coding_restore()
	var queued: bool = service != null and service.queue.snapshot().jobs.size() != before
	var reported: bool = fake.message.contains("Adopted already-loaded coding model")
	if previous_coding != null: settings.set_setting("tiiny_ai/models/coding_model", previous_coding)
	if previous_applied != null: settings.set_setting("_tiiny_ai/applied_configuration", previous_applied)
	fake.queue_free()
	await get_tree().process_frame
	if not adopted or not persisted or not drafted or queued or not reported or not stale_cancelled:
		return false
	print("Already-loaded coding-model adoption passed; no restore was queued.")
	return true

func _run() -> void:
	for count in range(10): await get_tree().process_frame
	var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
	if manager == null:
		_fail("Tiiny settings manager did not initialize.")
		return
	var settings_stage := OS.get_environment("TIINY_TEST_SETTINGS_STAGE")
	if not settings_stage.is_empty():
		await _run_settings_stage(manager, settings_stage)
		return
	if OS.get_environment("TIINY_TEST_LIVE_APPLY") == "1":
		await _run_live_apply(manager)
		return
	if OS.get_environment("TIINY_TEST_LIVE_READONLY") == "1":
		await manager.refresh_device()
		if not manager.connected:
			_fail("Live read-only refresh failed: " + manager.message)
			return
		print("Live coding model after refresh: ", EditorInterface.get_editor_settings().get_setting("tiiny_ai/models/coding_model"), "; loaded: ", manager.snapshot.get("loaded", {}).keys())
		var find_model := OS.get_environment("TIINY_TEST_FIND_MODEL").strip_edges().to_lower()
		if not find_model.is_empty():
			for id in manager.snapshot.models:
				var model: Dictionary = manager.snapshot.models[id]
				if find_model in str(id).to_lower() or find_model in str(model.get("name", "")).to_lower():
					print("Matching device model: ", {"id": id, "type": model.get("type"), "supported": model.get("supported"), "installed": model.get("installed"), "loaded": manager.snapshot.loaded.has(id), "npu": model.get("npu"), "max_context": model.get("max_context")})
		if OS.get_environment("TIINY_TEST_LIVE_INFERENCE") == "1":
			var checks = load("res://test_stabilization.gd").new()
			var original_warm: Array = manager.snapshot.loaded.keys()
			original_warm.sort()
			var live_error: String = await checks.run_live(self, manager, get_tree().get_first_node_in_group("tiiny_ai_editor_dock"))
			await manager.refresh_device()
			var final_warm: Array = manager.snapshot.get("loaded", {}).keys()
			final_warm.sort()
			print("Live final warm set: ", final_warm, "; unchanged: ", manager.connected and original_warm == final_warm)
			if not manager.connected or original_warm != final_warm:
				_fail("Could not verify the original Tiiny warm set after inference.")
				return
			if not live_error.is_empty():
				_fail(live_error)
				return
		else:
			await manager.check_config()
			if not manager.plan.get("ok", false):
				var errors: Array = Array(manager.plan.get("errors", []))
				var capacity_only := not errors.is_empty()
				for error in errors:
					if not ("NPU" in str(error) or "SSD" in str(error)):
						capacity_only = false
				if not capacity_only or manager.is_ready():
					_fail("Live read-only Check Config did not pass: " + str(errors))
					return
				print("Live read-only inventory passed; Check Config correctly rejected insufficient capacity: ", errors, "; no Apply was invoked.")
			else:
				print("Live read-only inventory and Check Config passed; no Apply was invoked.")
	else:
		if get_tree().get_nodes_in_group("tiiny_ai_editor_dock").size() != 1 or get_tree().get_nodes_in_group("tiiny_setup_manager").size() != 1:
			_fail("Expected one built-in chat dock and one manager at startup.")
			return
		for property in EditorInterface.get_editor_settings().get_property_list():
			if str(property.name).begins_with("tiiny_ai/advanced/") and not (int(property.usage) & PROPERTY_USAGE_EDITOR_BASIC_SETTING):
				_fail("Tiiny configuration is hidden behind the global Advanced Settings switch.")
				return
			if str(property.name).begins_with("tiiny_ai/connection/") or str(property.name).begins_with("tiiny_ai/device/"):
				_fail("Obsolete connection/device settings sections were reintroduced.")
				return
		if manager.busy or manager.connected or manager.is_ready() or not manager._connection().has("error"):
			_fail("Fresh offline startup inherited a configured device or active operation.")
			return
		await manager.refresh_device()
		if manager.busy or manager.connected or manager.is_ready() or not manager.plan.is_empty():
			_fail("Unconfigured offline refresh did not terminate safely.")
			return
		if not await _test_inventory_failures():
			_fail("Inventory failure contract failed.")
			return
		var protocol = load("res://test_chat_protocol.gd").new()
		var protocol_error: String = await protocol.run(self)
		if not protocol_error.is_empty():
			_fail(protocol_error)
			return
		if not await _test_apply_contract():
			_fail("Staged Apply contract failed.")
			return
		if not await _test_coding_adoption():
			_fail("Loaded coding-model adoption failed.")
			return
		var assistant := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
		# Check the script embedded in the binary as well as the extracted fixture.
		assistant.request_stage = "answer"
		assistant.pending_url = ""
		assistant.send_button.disabled = true
		var invalid_call := {"id": "", "type": "function", "function": {"name": "create_gdscript", "arguments": JSON.stringify({"path": "res://binary_invalid.gd", "source": "extends Node\n"})}}
		await assistant._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"choices": [{"message": {"role": "assistant", "tool_calls": [invalid_call]}}]}).to_utf8_buffer())
		if FileAccess.file_exists("res://binary_invalid.gd") or assistant.send_button.disabled:
			_fail("Built-in chat script did not reject the invalid tool call before mutation.")
			return
		var short_request := {"messages": [{"role": "user", "content": "hello"}]}
		if not assistant._check_context_budget(short_request) or short_request.get("max_tokens") != 1024:
			_fail("Context budget did not configure the response allowance.")
			return
		if assistant._check_context_budget({"messages": [{"role": "user", "content": "x".repeat(10000)}]}):
			_fail("Context budget did not reject an oversized request.")
			return
		var settings := EditorInterface.get_editor_settings()
		settings.set_setting("tiiny_ai/advanced/cli_path", ProjectSettings.globalize_path("res://fake-tiiny"))
		settings.set_setting("tiiny_ai/advanced/device_address", "127.0.0.1")
		settings.set_setting("tiiny_ai/advanced/api_key", "fixture-key")
		if await manager._run_cli(["load", "fixture-model"]) != 0:
			_fail("Nonblocking CLI runner failed with the local stub.")
			return
		var cli_arguments := FileAccess.get_file_as_string("res://cli-arguments").strip_edges().split("\n")
		if cli_arguments.size() != 5 or cli_arguments[0] != "--device-address" or cli_arguments[1] != "127.0.0.1" or cli_arguments[2] != "-y" or cli_arguments[3] != "load" or cli_arguments[4] != "fixture-model":
			_fail("CLI management did not use the configured device address.")
			return
		if not Array(manager.operation_log).any(func(line): return "25.0% (SDK)" in line) or not Array(manager.operation_log).any(func(line): return "100.0% (SDK)" in line):
			_fail("CLI progress percentages did not reach the operation log.")
			return
		print("Nonblocking CLI runner passed with local stub, no real SDK invocation.")
		var stabilization = load("res://test_stabilization.gd").new()
		var stabilization_error: String = await stabilization.run(self, manager, assistant)
		if not stabilization_error.is_empty():
			_fail(stabilization_error)
			return
		# Opening the fixture panel must not touch the real device.
		if OS.get_environment("TIINY_TEST_HTTP_URL").is_empty():
			manager.snapshot = {"models": {}, "loaded": {}, "npu_total": 100, "npu_used": 0, "disk_total": 100 * 1073741824, "disk_free": 80 * 1073741824, "time": Time.get_ticks_msec()}
		manager.connected = true
	var opened := false
	for node in _descendants(get_tree().root):
		if node is PopupMenu:
			for index in range(node.item_count):
				if node.get_item_text(index) == "Editor Settings...":
					node.id_pressed.emit(node.get_item_id(index))
					opened = true
					break
		if opened: break
	if not opened:
		_fail("Could not open the editor settings menu.")
		return
	for count in range(5): await get_tree().process_frame
	var dialog: Window
	for node in _descendants(get_tree().root):
		if node is Window and node.title == "Editor Settings": dialog = node
	if dialog == null:
		_fail("Editor Settings dialog not found.")
		return
	var selected := false
	for node in _descendants(dialog):
		if node is Tree:
			var item := _find_section(node.get_root())
			if item:
				if _find_section(node.get_root(), "tiiny_ai/advanced") == null:
					_fail("Advanced configuration section missing from normal settings view.")
					return
				item.select(0)
				node.scroll_to_item(item)
				node.item_selected.emit()
				selected = true
				break
	if not selected:
		_fail("Models section is missing from the settings tree.")
		return
	for count in range(5): await get_tree().process_frame
	var panels := 0
	for node in _descendants(dialog):
		if node.name == "Tiiny Model Management": panels += 1
	if panels != 1:
		_fail("Expected exactly one custom model configuration panel, found %d." % panels)
		return
	var capture := OS.get_environment("TIINY_TEST_CAPTURE_DIR")
	if not capture.is_empty():
		dialog.size = Vector2i(1500, 900)
		for count in range(5): await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := dialog.get_texture().get_image()
		if image == null or image.save_png(capture.path_join("settings-models.png")) != OK:
			_fail("Displayed settings capture failed.")
			return
		dialog.hide()
		get_tree().get_first_node_in_group("tiiny_ai_editor_dock").get_parent().make_visible()
		for count in range(5): await get_tree().process_frame
		await RenderingServer.frame_post_draw
		image = get_tree().root.get_texture().get_image()
		if image == null or image.save_png(capture.path_join("editor-chat.png")) != OK:
			_fail("Displayed editor capture failed.")
			return
		print("Displayed editor/settings captures saved.")
		await _capture_panel_states(capture)
	print("Editor Models section smoke check passed (device mutations disabled).")
	dialog.hide()
	get_tree().quit()
