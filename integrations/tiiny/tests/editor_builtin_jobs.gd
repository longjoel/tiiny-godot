@tool
extends EditorPlugin

class WarmImageManager extends Node:
	var busy := false
	var applying := false
	func is_ready() -> bool:
		return true
	func is_model_loaded(_model: String) -> bool:
		return true

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _unused_publish(_job: Dictionary, _artifact: Dictionary) -> Dictionary:
	return {"error": "Not used by append fixture"}

func _run() -> void:
	var jobs: Node
	for i in range(200):
		jobs = get_tree().root.find_child("Tiiny Jobs", true, false)
		if jobs != null and jobs.get("available"):
			break
		await get_tree().create_timer(0.05).timeout
	if jobs == null or not jobs.get("available"):
		_fail("Built-in Jobs service unavailable")
		return
	var chat := get_tree().root.find_child("Tiiny Assistant", true, false)
	if chat == null or chat.get("jobs_service") != jobs:
		_fail("Chat is not connected to the shared Jobs service")
		return
	var mode := OS.get_environment("TIINY_JOBS_TEST_MODE")
	if mode not in ["chat_restore", "model_failed_restore"]:
		var lease: String = jobs.acquire_device(self, "fixture")
		if lease.is_empty() or chat._acquire_device("fixture chat") or jobs.release_device(self, "wrong") or not jobs.release_device(self, lease):
			_fail("Shared device lease did not exclude competing owners")
			return
		if not chat._acquire_device("fixture chat"):
			_fail("Chat could not acquire released device lease")
			return
		var model_manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
		if model_manager == null or model_manager._acquire_device("fixture models"):
			_fail("Model manager raced a chat lease")
			return
		chat._release_device()
		if not model_manager._acquire_device("fixture models"):
			_fail("Model manager could not acquire released device lease")
			return
		model_manager._release_device()
	if mode in ["model_apply", "model_failed", "model_wait_cancel", "model_apply_restore"]:
		var actual := get_tree().get_first_node_in_group("tiiny_setup_manager")
		actual.remove_from_group("tiiny_setup_manager")
		var fake = load("res://fake_model_manager.gd").new()
		get_tree().root.add_child(fake)
		var settings := EditorInterface.get_editor_settings()
		settings.set_setting("tiiny_ai/models/coding_model", "code")
		fake.fixture_state = {"models": {"code": {"name": "Code", "type": "Text Generation", "supported": ["Tool Use"], "npu": 47, "bytes": 100, "installed": true, "max_context": 32768}, "image": {"name": "Image", "type": "Text-to-Image", "npu": 23, "bytes": 100, "installed": true, "max_context": 0}}, "loaded": {"code": 47, "image": 23}, "npu_total": 100, "npu_used": 70, "disk_free": 100 * 1073741824, "disk_total": 200 * 1073741824, "connection": "a".repeat(64)}
		fake.draft_initialized = true
		fake.draft = {"roles": {}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
		for role in fake.ROLES:
			fake.draft.roles[role] = {"model": "code" if role == "coding_model" else "image" if role == "image_model" else "", "context": 8192 if role == "coding_model" else 0, "warm": role == "coding_model"}
		fake.omit_effect = mode == "model_failed"
		if mode == "model_apply_restore":
			fake.fixture_state.loaded.erase("code")
			fake.fixture_state.npu_used = 23
			settings.set_setting("_tiiny_ai/applied_configuration", fake.draft.duplicate(true))
			fake.next_restore_check_msec = Time.get_ticks_msec() + 60000
		await fake.check_config()
		if not fake.plan.get("ok", false):
			_fail("Could not check fake model configuration")
			return
		var competing_lease := ""
		if mode == "model_wait_cancel":
			competing_lease = jobs.acquire_device(self, "blocking fixture")
			if competing_lease.is_empty():
				_fail("Could not acquire competing fixture lease")
				return
		fake.apply_config()
		var entries: Array = jobs.queue.snapshot().jobs
		if entries.size() != 1 or entries[0].operation != "model_apply" or entries[0].state != "queued" or not fake.calls.is_empty():
			_fail("Apply did not enter the shared FIFO before device work: " + str(entries) + " message=" + fake.message)
			return
		var id: String = entries[0].id
		var deadline := Time.get_ticks_msec() + 15000
		if mode == "model_wait_cancel":
			while jobs.get_job_status(id).get("state") == "queued" and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.05).timeout
			await get_tree().create_timer(0.1).timeout
			if not jobs.executor.cancel_current():
				_fail("Could not cancel model job waiting for device lease")
				return
		while jobs.get_job_status(id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var result: Dictionary = jobs.get_job_status(id)
		if mode == "model_wait_cancel":
			if result.state != "cancelled" or not fake.calls.is_empty() or not jobs.release_device(self, competing_lease):
				_fail("Waiting model job did not cancel before any device command: " + str(result))
				return
			print("Built-in Jobs %s passed" % mode)
			get_tree().quit(0)
			return
		var expected := "interrupted" if mode == "model_failed" else "completed"
		var expected_calls := [["load", "code"], ["unload", "image"]] if mode == "model_apply_restore" else [["unload", "image"]]
		if result.get("state") != expected or fake.calls != expected_calls or not fake.fixture_state.loaded.has("code"):
			_fail("Queued model Apply outcome incorrect: " + str(result) + " calls=" + str(fake.calls))
			return
		var operation: Dictionary = result.attempts.back().device_operations.back()
		if operation.verb != "unload" or operation.model != "image" or operation.connection != "a".repeat(64) or operation.state != ("started" if mode == "model_failed" else "verified"):
			_fail("Model operation journal incorrect: " + str(operation))
			return
		if mode == "model_apply_restore":
			if result.attempts.back().device_operations.size() != 2 or result.attempts.back().device_operations[0].verb != "load" or result.attempts.back().device_operations[0].state != "verified":
				_fail("Apply did not verify coding-model restoration before changing other models")
				return
		if mode in ["model_apply", "model_apply_restore"]:
			var saved: Variant = settings.get_setting("_tiiny_ai/applied_configuration")
			if not saved is Dictionary or saved.get("roles", {}).get("coding_model", {}).get("model") != "code":
				_fail("Verified coding model configuration was not persisted")
				return
			if JSON.stringify(result).contains("fixture-key"):
				_fail("Device credentials were persisted in the model job")
				return
		if mode == "model_failed" and not jobs.acquire_device(self, "competing fixture").is_empty():
			_fail("Uncertain model operation released the device lease")
			return
		if mode == "model_failed":
			var before: Array = fake.calls.duplicate(true)
			var inspection: Dictionary = await fake.inspect_interrupted_model_job(id)
			var inspected: Dictionary = jobs.get_job_status(id)
			if inspection.has("error") or inspected.state != "interrupted" or not inspected.attempts.back().has("device_observation") or fake.calls != before or not jobs.device_recovery_pending():
				_fail("Device inspection did not preserve the stopped job: " + str(inspection))
				return
	elif mode == "model_failed_restore":
		var entries: Array = jobs.queue.snapshot().jobs
		if entries.size() != 1 or entries[0].state != "interrupted" or entries[0].attempts.back().device_operations.back().state != "started":
			_fail("Uncertain model operation was not preserved on restart: " + str(entries))
			return
		if not jobs.acquire_device(self, "competing fixture").is_empty() or jobs.queue.resolve(entries[0].id, "retry"):
			_fail("Interrupted model operation allowed blind retry or device access")
			return
		var actual := get_tree().get_first_node_in_group("tiiny_setup_manager")
		actual.remove_from_group("tiiny_setup_manager")
		var fake = load("res://fake_model_manager.gd").new()
		get_tree().root.add_child(fake)
		fake.fixture_state = {"models": {"image": {"name": "Image", "type": "Text-to-Image", "npu": 23, "bytes": 100, "installed": true, "max_context": 0, "state": "running"}}, "loaded": {"image": 23}, "npu_total": 100, "npu_used": 23, "disk_free": 100 * 1073741824, "disk_total": 200 * 1073741824, "connection": "a".repeat(64)}
		fake.fixture_state.connection = "c".repeat(64)
		var wrong: Dictionary = await fake.inspect_interrupted_model_job(entries[0].id)
		if not wrong.has("error") or not fake.calls.is_empty() or not jobs.device_recovery_pending():
			_fail("Device inspection accepted a different device")
			return
		fake.fixture_state.connection = "a".repeat(64)
		var inspection: Dictionary = await fake.inspect_interrupted_model_job(entries[0].id)
		var recovered: Dictionary = jobs.get_job_status(entries[0].id)
		if inspection.has("error") or recovered.state != "interrupted" or not recovered.attempts.back().device_observation.loaded or not fake.calls.is_empty() or not jobs.device_recovery_pending():
			_fail("Read-only device inspection after restart failed: " + str(inspection))
			return
		jobs.abandon_id = entries[0].id
		jobs._on_abandon_confirmed()
		var recovered_lease: String = jobs.acquire_device(self, "after explicit acknowledgement")
		if jobs.get_job_status(entries[0].id).state != "skipped" or jobs.device_recovery_pending() or recovered_lease.is_empty():
			_fail("Explicit acknowledgement did not resolve shared uncertainty: job=" + str(jobs.get_job_status(entries[0].id)) + " marker=" + str(jobs._device_marker()) + " lease=" + str(not recovered_lease.is_empty()) + " holder=" + str(jobs.device_purpose))
			return
		jobs.release_device(self, recovered_lease)
	elif mode in ["model_restore", "model_restore_download", "model_restore_capacity", "model_preflight", "model_preflight_stale", "model_preflight_cancel", "model_restore_stale", "model_resource_preflight", "model_resource_preflight_stale", "model_schedule", "model_schedule_capacity", "model_schedule_restore", "model_schedule_disconnect"]:
		var actual := get_tree().get_first_node_in_group("tiiny_setup_manager")
		actual.remove_from_group("tiiny_setup_manager")
		var fake = load("res://fake_model_manager.gd").new()
		get_tree().root.add_child(fake)
		var settings := EditorInterface.get_editor_settings()
		settings.set_setting("tiiny_ai/models/coding_model", "code")
		fake.fixture_state = {"models": {"code": {"name": "Code", "type": "Text Generation", "supported": ["Tool Use"], "npu": 47, "bytes": 100, "installed": mode != "model_restore_download", "max_context": 32768}, "image": {"name": "Image", "type": "Text-to-Image", "npu": 23, "bytes": 100, "installed": true, "max_context": 0}}, "loaded": {"image": 23}, "npu_total": 100, "npu_used": 80 if mode == "model_restore_capacity" else 23, "disk_free": 100 * 1073741824, "disk_total": 200 * 1073741824, "connection": "b".repeat(64)}
		if mode in ["model_schedule", "model_schedule_capacity", "model_schedule_restore", "model_schedule_disconnect"]:
			fake.fixture_state.loaded = {"code": 47.0, "image": 23.0}
			fake.fixture_state.npu_used = 70.0
			fake.fixture_state.models["special"] = {"name": "Special", "type": "Text-to-Image", "supported": [], "npu": 10, "bytes": 100, "installed": true, "max_context": 0}
			fake.fixture_state.models["big_image"] = {"name": "Big image", "type": "Text-to-Image", "supported": [], "npu": 60, "bytes": 100, "installed": true, "max_context": 0}
		if mode == "model_schedule_restore":
			fake.fixture_state.loaded = {"code": 47.0, "special": 10.0}
			fake.fixture_state.npu_used = 57.0
		var saved := {"roles": {}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
		for role in fake.ROLES:
			saved.roles[role] = {"model": "code" if role == "coding_model" else "", "context": 8192 if role == "coding_model" else 0, "warm": role == "coding_model"}
		if mode in ["model_schedule", "model_schedule_capacity", "model_schedule_disconnect"]:
			saved.roles.image_model = {"model": "image", "context": 0, "warm": true}
		if mode == "model_schedule_restore":
			saved.roles.image_model = {"model": "image", "context": 0, "warm": true}
		settings.set_setting("_tiiny_ai/applied_configuration", saved)
		if mode in ["model_preflight_stale", "model_resource_preflight_stale"]:
			fake.fixture_state.loaded = {"code": 47.0}
			fake.fixture_state.npu_used = 47.0
			fake.snapshot = fake.fixture_state.duplicate(true)
			fake.snapshot["time"] = Time.get_ticks_msec() - 120000
			fake.connected = true
			fake.connection_identity = "b".repeat(64)
			settings.set_setting("_tiiny_ai/applied_configuration", {})
		fake.draft = saved.duplicate(true)
		fake.draft_initialized = true
		fake.next_restore_check_msec = Time.get_ticks_msec() + 60000
		var deadline := Time.get_ticks_msec() + 15000
		if mode in ["model_preflight", "model_preflight_stale", "model_preflight_cancel", "model_resource_preflight", "model_resource_preflight_stale"]:
			fake.wait_for_cancel = mode == "model_preflight_cancel"
			var fake_chat = load("res://fake_restore_chat.gd").new()
			add_child(fake_chat)
			fake_chat.jobs_service = jobs
			jobs.chat_service = fake_chat
			var connection: Dictionary = fake_chat._inference_connection()
			var hash: String = (connection.url + "|" + connection.host + "|" + connection.key).sha256_text()
			var accepted: Dictionary
			if mode in ["model_resource_preflight", "model_resource_preflight_stale"]:
				accepted = jobs.append_job("preflight", "resource_shape", {"description": "triangle", "model": "code", "connection_hash": hash, "timeout_ms": 15000})
			else:
				accepted = jobs.append_job("preflight", "chat_turn", {"prompt": "hello", "context": "", "custom_prompt": "", "model": "code", "connection_hash": hash, "conversation": [], "timeout_ms": 15000})
			if mode in ["model_resource_preflight", "model_resource_preflight_stale"]:
				while fake_chat.resource_submissions.is_empty() and Time.get_ticks_msec() < deadline:
					await get_tree().create_timer(0.05).timeout
				var expected_calls: Array = [] if mode == "model_resource_preflight_stale" else [["load", "code"]]
				if fake_chat.resource_submissions.is_empty() or fake.calls != expected_calls:
					_fail("Resource preflight did not restore the coding model: " + str(jobs.get_job_status(accepted.id)))
					return
				var response := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": '{"points":[[0,0],[32,0],[0,32]]}'}}]}).to_utf8_buffer()
				fake_chat.resource_submissions[0].request_completed.emit(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), response)
				while jobs.get_job_status(accepted.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
					await get_tree().create_timer(0.05).timeout
				if jobs.get_job_status(accepted.id).get("state") != "completed":
					_fail("Resource generation did not complete after restoration: " + str(jobs.get_job_status(accepted.id)))
					return
				if mode == "model_resource_preflight_stale" and jobs.queue.snapshot().jobs.any(func(job): return job.operation == "model_restore"):
					_fail("Stale resource preflight queued a redundant restoration")
					return
				print("Built-in Jobs %s passed" % mode)
				get_tree().quit(0)
				return
			if mode == "model_preflight_cancel":
				while fake.calls.is_empty() and Time.get_ticks_msec() < deadline:
					await get_tree().create_timer(0.05).timeout
				if fake.calls.is_empty() or not jobs.executor.cancel_current():
					_fail("Could not cancel running model preflight")
					return
				while jobs.get_job_status(accepted.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
					await get_tree().create_timer(0.05).timeout
				var cancelled: Dictionary = jobs.get_job_status(accepted.id)
				if cancelled.state != "interrupted" or not fake_chat.submissions.is_empty() or not jobs.acquire_device(self, "competing fixture").is_empty():
					_fail("Cancelled preflight did not preserve uncertainty: " + str(cancelled))
					return
				print("Built-in Jobs %s passed" % mode)
				get_tree().quit(0)
				return
			while fake_chat.submissions.is_empty() and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.05).timeout
			var expected_calls: Array = [] if mode == "model_preflight_stale" else [["load", "code"]]
			if fake_chat.submissions.is_empty() or fake.calls != expected_calls:
				_fail("Running chat did not restore its coding model before inference: " + str(fake.calls) + " / " + str(jobs.get_job_status(accepted.id)))
				return
			var attempt: Dictionary = jobs.get_job_status(accepted.id).attempts.back()
			if not attempt.get("device_started", false) or (mode != "model_preflight_stale" and attempt.device_operations.back().state != "verified"):
				_fail("Chat preflight did not durably verify restoration")
				return
			var classified := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer()
			await fake_chat._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), classified)
			while fake_chat.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.05).timeout
			await fake_chat._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "done"}}]}).to_utf8_buffer())
			while jobs.get_job_status(accepted.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.05).timeout
			if jobs.get_job_status(accepted.id).get("state") != "completed":
				_fail("Chat did not complete after preflight restoration: " + str(jobs.get_job_status(accepted.id)))
				return
			if mode == "model_preflight_stale" and jobs.queue.snapshot().jobs.any(func(job): return job.operation == "model_restore"):
				_fail("Stale chat preflight queued a redundant restoration")
				return
		else:
			if mode in ["model_schedule", "model_schedule_capacity"]:
				var requested := "special" if mode == "model_schedule" else "big_image"
				var fake_chat = load("res://fake_restore_chat.gd").new()
				add_child(fake_chat)
				fake_chat.jobs_service = jobs
				var raw: Variant = fake_chat._append_job_tool({"operation": "model_schedule", "role": "image_model", "model": requested})
				if raw is String and raw.begins_with("Error:"):
					_fail("Specialized scheduling was not accepted by the dock tool: " + raw); return
				var submitted: Variant = JSON.parse_string(raw)
				if not submitted is Dictionary or not submitted.get("accepted", false) or not submitted.get("id") is String:
					_fail("Specialized scheduling was not accepted by the dock tool: " + str(submitted)); return
				var accepted := {"id": submitted.id}
				fake_chat.queue_free()
				while jobs.get_job_status(accepted.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
					await get_tree().create_timer(0.05).timeout
				var scheduled: Dictionary = jobs.get_job_status(accepted.id)
				if mode == "model_schedule_capacity":
					if scheduled.state != "failed" or not fake.calls.is_empty() or not str(scheduled.get("result", {}).get("error", "")).contains("retaining the scripting model"):
						_fail("Impossible specialized schedule mutated the device or lacked a clear error: " + str(scheduled) + " calls=" + str(fake.calls)); return
				else:
					var expected_calls := [["unload", "image"], ["load", "special"], ["unload", "special"], ["load", "image"]]
					if scheduled.state != "completed" or fake.calls != expected_calls:
						_fail("Specialized schedule did not evict, load, and restore: " + str(scheduled) + " calls=" + str(fake.calls)); return
					if not fake.fixture_state.loaded.has("code") or not fake.fixture_state.loaded.has("image") or fake.fixture_state.loaded.has("special"):
						_fail("Specialized schedule did not restore the configured warm set: " + str(fake.fixture_state.loaded)); return
					var operations: Array = scheduled.attempts.back().get("device_operations", [])
					if operations.size() != 4 or not operations.all(func(operation): return operation.state == "verified"):
						_fail("Specialized schedule did not verify every device operation: " + str(operations)); return
				print("Built-in Jobs %s passed" % mode)
				get_tree().quit(0)
				return
			if mode == "model_schedule_restore":
				fake.calls.clear()
				await fake._fail_schedule("fixture failure", {"changed": true, "uncertain": false}, "b".repeat(64), saved, "code")
				if fake.calls != [["unload", "special"], ["load", "image"]] or not fake.fixture_state.loaded.has("image") or fake.fixture_state.loaded.has("special"):
					_fail("Failure path did not restore the configured warm set: " + str(fake.calls) + " loaded=" + str(fake.fixture_state.loaded)); return
				if not fake.message.contains("warm set was restored"):
					_fail("Failure path did not report restoration: " + fake.message); return
				fake.fixture_state.loaded = {"code": 47.0, "special": 10.0}
				fake.fixture_state.npu_used = 57.0
				fake.calls.clear()
				fake.model_job_cancelled = true
				await fake._fail_schedule("fixture cancellation", {"changed": true, "uncertain": false}, "b".repeat(64), saved, "code")
				fake.model_job_cancelled = false
				if fake.calls != [["unload", "special"], ["load", "image"]] or not fake.fixture_state.loaded.has("image"):
					_fail("Cancellation path did not restore the configured warm set: " + str(fake.calls)); return
				print("Built-in Jobs %s passed" % mode)
				get_tree().quit(0)
				return
			if mode == "model_schedule_disconnect":
				fake.snapshot_error = "Device request failed (connection 1, HTTP 0)."
				var schedule_params := {"role": "image_model", "model": "special", "connection": "b".repeat(64), "timeout_ms": 15000}
				var first: Dictionary = jobs.append_job("schedule-disconnect", "model_schedule", schedule_params)
				while jobs.get_job_status(first.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
					await get_tree().create_timer(0.05).timeout
				var failed: Dictionary = jobs.get_job_status(first.id)
				if failed.state != "failed" or not fake.calls.is_empty() or not str(failed.get("result", {}).get("error", "")).contains("unavailable or changed"):
					_fail("Disconnected schedule mutated the device or lacked a clear error: " + str(failed) + " calls=" + str(fake.calls)); return
				var duplicate: Dictionary = jobs.append_job("schedule-disconnect", "model_schedule", schedule_params)
				if duplicate.get("id", "") != first.id or jobs.queue.snapshot().jobs.size() != 1:
					_fail("Disconnected schedule was duplicated: " + str(duplicate)); return
				fake.snapshot_error = ""
				if not jobs.queue.resolve(first.id, "skip"):
					_fail("Could not resolve the failed schedule"); return
				if not jobs.queue.set_paused(false):
					_fail("Could not resume dispatch after the failed schedule"); return
				var recovered: Dictionary = jobs.append_job("schedule-recovered", "model_schedule", schedule_params)
				while jobs.get_job_status(recovered.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
					await get_tree().create_timer(0.05).timeout
				if jobs.get_job_status(recovered.id).get("state") != "completed" or not fake.fixture_state.loaded.has("image") or fake.fixture_state.loaded.has("special"):
					_fail("Recovered schedule did not complete or restore: " + str(jobs.get_job_status(recovered.id))); return
				print("Built-in Jobs %s passed" % mode)
				get_tree().quit(0)
				return
			if mode == "model_restore_stale":
				jobs.queue.set_paused(true)
				await fake.refresh_device()
				settings.set_setting("tiiny_ai/models/coding_model", "different-code")
				jobs.queue.set_paused(false)
			elif mode == "model_restore_download":
				fake.snapshot_error = "Device request failed (connection 1, HTTP 0)."
				await fake.refresh_device()
				if fake.connected or not jobs.queue.snapshot().jobs.is_empty():
					_fail("Disconnected device queued restoration")
					return
				fake.snapshot_error = ""
				# The next monitor cycle detects reconnect without a manual refresh.
				fake.next_restore_check_msec = 0
			else:
				# Exercise the automatic startup monitor rather than a manual refresh.
				fake.next_restore_check_msec = 0
			while jobs.queue.snapshot().jobs.is_empty() and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.05).timeout
			var entries: Array = jobs.queue.snapshot().jobs
			if entries.size() != 1 or entries[0].operation != "model_restore":
				_fail("Coding restoration was not queued: " + str(entries) + " / " + fake.message)
				return
			var id: String = entries[0].id
			while jobs.get_job_status(id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.05).timeout
			var result: Dictionary = jobs.get_job_status(id)
			var expected := "failed" if mode == "model_restore_capacity" else "completed"
			if result.state != expected or not fake.fixture_state.loaded.has("image"):
				_fail("Coding restoration outcome incorrect: " + str(result) + " calls=" + str(fake.calls))
				return
			if mode == "model_restore_capacity":
				if not fake.calls.is_empty() or fake.is_ready() or fake.last_error_type != "capacity" or not fake.message.contains("capacity"):
					_fail("Insufficient capacity caused mutation or readiness")
					return
			elif mode == "model_restore_stale":
				if not fake.calls.is_empty():
					_fail("An obsolete restoration mutated the device")
					return
			else:
				var expected_calls := [["download", "code"], ["load", "code"]] if mode == "model_restore_download" else [["load", "code"]]
				if fake.calls != expected_calls or not fake.is_ready():
					_fail("Coding restoration did not verify the saved model: " + str(fake.calls) + " / " + fake.message)
					return
	elif mode == "queued_cancel":
		if not jobs.queue.set_paused(true):
			_fail("Could not pause queue for cancellation fixture")
			return
		var first: Dictionary = jobs.append_job("queued-cancel-first", "create_tree", {"destination": "res://assets/cancel_first.png", "timeout_ms": 30000})
		var second: Dictionary = jobs.append_job("queued-cancel-second", "create_tree", {"destination": "res://assets/cancel_second.png", "timeout_ms": 30000})
		if first.has("error") or second.has("error"):
			_fail("Could not append queued cancellation jobs: " + str(first) + " / " + str(second))
			return
		jobs._on_cancel_queued(first.id)
		var cancelled: Dictionary = jobs.get_job_status(first.id)
		if cancelled.state != "cancelled" or not cancelled.attempts.is_empty():
			_fail("Queued cancellation did not produce an empty cancelled job: " + str(cancelled))
			return
		if jobs.get_job_status(second.id).get("state") != "queued":
			_fail("Queued cancellation disturbed the following job")
			return
		var third: Dictionary = jobs.append_job("queued-cancel-third", "create_tree", {"destination": "res://assets/cancel_third.png", "timeout_ms": 30000})
		if third.has("error"):
			_fail("Could not append third queued cancellation job: " + str(third))
			return
		jobs._on_cancel_queued_all()
		if jobs.get_job_status(second.id).get("state") != "cancelled" or jobs.get_job_status(third.id).get("state") != "cancelled":
			_fail("Cancel-all did not cancel every queued job")
			return
		jobs._on_clear_job(first.id)
		if not jobs.get_job_status(first.id).get("hidden", false):
			_fail("Cancelled queued job could not be hidden")
			return
		print("Built-in Jobs queued_cancel passed")
		get_tree().quit()
		return
	elif mode == "create":
		EditorInterface.open_scene_from_path("res://target.tscn")
		for i in range(200):
			if EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == "res://target.tscn":
				break
			await get_tree().create_timer(0.05).timeout
		var scene := EditorInterface.get_edited_scene_root()
		if scene == null or scene.scene_file_path != "res://target.tscn":
			_fail("Scene failed to open")
			return
		var accepted: Dictionary = jobs.append_job("fixture-key", "create_tree", {"destination": "res://assets/tree.png", "timeout_ms": 30000})
		if not accepted.has("id") or accepted.sequence != 1:
			_fail("Append failed: " + str(accepted))
			return
		if not jobs.append_job("invalid", "create_tree", {"destination": "res://../bad.png", "timeout_ms": 30000}).has("error"):
			_fail("Invalid job accepted")
			return
		var revision: Variant = JSON.parse_string(chat._scene_revision_tool())
		if not revision is Dictionary or revision.get("scene_path") != "res://target.tscn":
			_fail("Chat could not inspect the saved scene")
			return
		var attachment: Variant = JSON.parse_string(chat._append_job_tool({"operation": "attach_tree_to_scene", "artifact_id": accepted.id + ":tree", "scene_path": revision.scene_path, "scene_sha256": revision.scene_sha256, "parent_path": ".", "node_name": "Tree"}))
		if not attachment is Dictionary or attachment.get("sequence") != 2:
			_fail("Attachment was not accepted: " + str(attachment))
			return
		var deadline := Time.get_ticks_msec() + 40000
		var state: Dictionary = {}
		while Time.get_ticks_msec() < deadline:
			state = jobs.get_job_status(attachment.id)
			if state.get("state") in ["completed", "failed", "interrupted"]:
				break
			await get_tree().create_timer(0.05).timeout
		var tree_job: Dictionary = jobs.get_job_status(accepted.id)
		if state.get("state") != "completed" or tree_job.attempts[0].publication.phase != "imported" or state.attempts[0].mutation.phase != "saved":
			_fail("Built-in job did not complete: " + str(state))
			return
		if not scene.get_node_or_null("Tree") is Sprite2D or scene.get_node("Tree").texture.resource_path != "res://assets/tree.png":
			_fail("Tree was not attached to the requested scene")
			return
		var packed := ResourceLoader.load("res://target.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		var saved := packed.instantiate() if packed else null
		if saved == null or not saved.get_node_or_null("Tree") is Sprite2D:
			_fail("Attachment was not saved")
			return
		saved.free()
		var manager := EditorInterface.get_editor_undo_redo()
		var history := manager.get_history_undo_redo(manager.get_object_history_id(scene))
		history.undo()
		if scene.has_node("Tree"):
			_fail("Attachment could not be undone")
			return
		history.redo()
		if not scene.has_node("Tree"):
			_fail("Attachment could not be redone")
			return
		if not ResourceLoader.load("res://assets/tree.png") is Texture2D:
			_fail("Imported texture unavailable")
			return
		if EditorInterface.get_resource_filesystem().get_filesystem_path("res://.tiiny") != null:
			_fail("Queue history appeared in imported project files")
			return
	elif mode == "restore":
		var duplicate: Dictionary = jobs.append_job("fixture-key", "create_tree", {"destination": "res://assets/tree.png", "timeout_ms": 30000})
		if not duplicate.get("duplicate", false) or jobs.get_job_status(duplicate.get("id", "")).get("state") != "completed":
			_fail("Completed job not restored: " + str(duplicate) + " / " + str(jobs.get("queue").snapshot()))
			return
		var orphan := Node.new()
		if jobs.acquire_device(orphan, "orphan fixture").is_empty():
			_fail("Could not acquire orphan fixture lease")
			return
		orphan.free()
		if not jobs.acquire_device(self, "competing fixture").is_empty():
			_fail("An orphaned lease was silently released")
			return
	elif mode in ["scene_recovery", "scene_prepare"]:
		EditorInterface.open_scene_from_path("res://target.tscn")
		for i in range(200):
			if EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == "res://target.tscn":
				break
			await get_tree().create_timer(0.05).timeout
		var scene := EditorInterface.get_edited_scene_root()
		if scene == null:
			_fail("Recovery scene did not open")
			return
		var store: RefCounted = jobs.get("queue")
		var tree: Dictionary = jobs.append_job("recovery-tree", "create_tree", {"destination": "res://assets/tree.png", "timeout_ms": 30000})
		var deadline := Time.get_ticks_msec() + 30000
		while jobs.get_job_status(tree.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var tree_job: Dictionary = jobs.get_job_status(tree.id)
		if tree_job.get("state") != "completed":
			_fail("Recovery tree failed")
			return
		store.set_paused(true)
		var revision := FileAccess.get_sha256("res://target.tscn")
		var parameters := {"artifact_id": tree.id + ":tree", "scene_path": "res://target.tscn", "scene_sha256": revision, "parent_path": ".", "node_name": "Recovered", "timeout_ms": 30000}
		var accepted: Dictionary = jobs.append_job("recover-saved", "attach_tree_to_scene", parameters)
		store.set_paused(false)
		store.start_next()
		var token := "a".repeat(32)
		var target := {"scene_path": parameters.scene_path, "scene_sha256": revision, "parent_path": ".", "node_name": "Recovered", "artifact_id": parameters.artifact_id, "artifact_sha256": tree_job.result.artifact.sha256, "mutation_token": token}
		if not store.mutation(accepted.id, "prepared", target):
			_fail("Could not prepare interrupted scene")
			return
		var sprite := Sprite2D.new()
		sprite.name = "Recovered"
		sprite.texture = ResourceLoader.load("res://assets/tree.png")
		sprite.set_meta("_tiiny_job_token", token)
		scene.add_child(sprite)
		sprite.owner = scene
		EditorInterface.mark_scene_as_unsaved()
		if EditorInterface.save_scene() != OK:
			_fail("Could not save recovery fixture")
			return
		if mode == "scene_prepare":
			print("Built-in Jobs scene_prepare passed")
			get_tree().quit(0)
			return
		var root_path := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
		var queue_path := root_path.path_join(".tiiny/jobs/queue.json")
		store.close()
		if not store.open(queue_path, root_path):
			_fail("Could not reopen interrupted queue")
			return
		var verifier: RefCounted = jobs.get("attach_script").new(store, root_path)
		var verified: Dictionary = verifier.reconcile(jobs.get_job_status(accepted.id))
		if not verified.get("ok", false) or jobs.get_job_status(accepted.id).get("state") != "completed" or not store.snapshot().paused:
			_fail("Saved attachment reconciliation failed: " + str(verified))
			return
		parameters.scene_sha256 = FileAccess.get_sha256("res://target.tscn")
		parameters.node_name = "Absent"
		var absent: Dictionary = jobs.append_job("recover-absent", "attach_tree_to_scene", parameters)
		store.set_paused(false)
		store.start_next()
		target.scene_sha256 = parameters.scene_sha256
		target.node_name = "Absent"
		target.mutation_token = "b".repeat(32)
		store.mutation(absent.id, "prepared", target)
		store.close()
		store.open(queue_path, root_path)
		verified = verifier.reconcile(jobs.get_job_status(absent.id))
		if not verified.get("ok", false) or jobs.get_job_status(absent.id).get("state") != "failed":
			_fail("Unchanged scene reconciliation failed: " + str(verified))
			return
		if not store.resolve(absent.id, "skip") or not store.snapshot().paused:
			_fail("Verified no-effect job did not require a decision")
			return
		parameters.scene_sha256 = FileAccess.get_sha256("res://target.tscn")
		parameters.node_name = "Alien"
		var ambiguous: Dictionary = jobs.append_job("recover-ambiguous", "attach_tree_to_scene", parameters)
		store.set_paused(false)
		store.start_next()
		target.scene_sha256 = parameters.scene_sha256
		target.node_name = "Alien"
		target.mutation_token = "c".repeat(32)
		store.mutation(ambiguous.id, "prepared", target)
		var unrelated := Sprite2D.new()
		unrelated.name = "Alien"
		scene.add_child(unrelated)
		unrelated.owner = scene
		EditorInterface.mark_scene_as_unsaved()
		EditorInterface.save_scene()
		store.close()
		store.open(queue_path, root_path)
		verified = verifier.reconcile(jobs.get_job_status(ambiguous.id))
		if verified.get("ok", false) or jobs.get_job_status(ambiguous.id).get("state") != "interrupted":
			_fail("Ambiguous scene was falsely reconciled")
			return
	elif mode == "worker_append":
		var store: RefCounted = jobs.get("queue")
		store.set_paused(true)
		var first: Variant = JSON.parse_string(chat._append_job_tool({"operation": "create_tree", "destination": "res://assets/first.png", "followup_destination": "res://assets/followup.png"}))
		var second: Dictionary = jobs.append_job("worker-second", "create_tree", {"destination": "res://assets/second.png", "timeout_ms": 30000})
		if not first is Dictionary or first.get("sequence") != 1 or second.get("sequence") != 2:
			_fail("Worker fixture submissions were not accepted in order")
			return
		store.set_paused(false)
		var deadline := Time.get_ticks_msec() + 30000
		while Time.get_ticks_msec() < deadline:
			var state: Dictionary = store.snapshot()
			if state.jobs[0].state in ["failed", "interrupted"] or (state.jobs.size() == 3 and state.jobs[2].state in ["completed", "failed", "interrupted"]):
				break
			await get_tree().create_timer(0.05).timeout
		var state: Dictionary = store.snapshot()
		if state.jobs.size() != 3 or state.jobs[0].state != "completed" or state.jobs[1].state != "completed" or state.jobs[2].state != "completed":
			_fail("Worker append did not complete in order: " + str(state))
			return
		if state.jobs[0].result.appended_jobs[0].id != state.jobs[2].id or state.jobs[2].parameters.destination != "res://assets/followup.png":
			_fail("Worker append acknowledgment was not retained")
			return
		var root_path := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
		var work := root_path.path_join(".godot/tiiny/asset_jobs").path_join(first.id + "-1")
		var worker: RefCounted = jobs.get("worker_script").new(work, OS.get_executable_path(), _unused_publish, Callable(jobs, "append_job"))
		worker.job = state.jobs[0]
		var replay: Dictionary = worker._accept_append_requests(DirAccess.open(work))
		if replay.get("accepted", []).size() != 1 or replay.accepted[0].id != state.jobs[2].id or store.snapshot().jobs.size() != 3:
			_fail("Worker append replay was not deduplicated")
			return
		var requests := FileAccess.open(work.path_join("append_requests.json"), FileAccess.WRITE)
		requests.store_string(JSON.stringify({"requests": [{"operation": "create_tree", "parameters": {"destination": "res://../escape.png", "timeout_ms": 60000}}]}))
		requests.close()
		if not worker._accept_append_requests(DirAccess.open(work)).has("error") or store.snapshot().jobs.size() != 3:
			_fail("Invalid worker append was accepted")
			return
		worker.job.id = "fresh-worker-fixture"
		worker.job.parameters.followup_destination = "res://../escape.png"
		if not worker._accept_append_requests(DirAccess.open(work)).has("error") or store.snapshot().jobs.size() != 3:
			_fail("Worker append bypassed the shared path validator")
			return
	elif mode == "scene_restore":
		EditorInterface.open_scene_from_path("res://target.tscn")
		for i in range(200):
			if EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == "res://target.tscn":
				break
			await get_tree().create_timer(0.05).timeout
		var restored: Dictionary = jobs.get("queue").snapshot()
		var interrupted: Dictionary = restored.jobs.back()
		if interrupted.state != "interrupted":
			_fail("Scene job was not interrupted on restart")
			return
		var root_path := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
		var verifier: RefCounted = jobs.get("attach_script").new(jobs.get("queue"), root_path)
		var verified: Dictionary = verifier.reconcile(interrupted)
		if not verified.get("ok", false) or jobs.get_job_status(interrupted.id).get("state") != "completed" or not jobs.get("queue").snapshot().paused:
			_fail("Scene recovery after restart failed: " + str(verified))
			return
		if EditorInterface.get_edited_scene_root().get_child_count() != 1:
			_fail("Recovery duplicated or lost the saved node")
			return
	elif mode == "resource_cancel":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		var result: Array = []
		fake.generate_shape_for_dialog("Cancelled polygon", func(shape, error): result.assign([shape, error]))
		var resource: Dictionary = jobs.get("queue").snapshot().jobs.back()
		var deadline := Time.get_ticks_msec() + 10000
		while fake.resource_submissions.is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.resource_submissions.is_empty() or not jobs.get("executor").cancel_current():
			_fail("Could not cancel running resource job")
			return
		var late := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": '{"points":[[0,0],[32,0],[0,32]]}'}}]}).to_utf8_buffer()
		fake.resource_submissions[0].request_completed.emit(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), late)
		while result.is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if result.size() != 2 or result[0] != null or str(result[1]).is_empty() or jobs.get_job_status(resource.id).get("state") != "interrupted":
			_fail("Cancelled resource accepted a late result or failed to stop")
			return
	elif mode == "chat_restore":
		var restored: Dictionary = jobs.get("queue").snapshot()
		if restored.jobs.back().state != "interrupted" or not restored.jobs.back().attempts.back().get("device_started", false):
			_fail("Interrupted device job was not restored")
			return
		if not jobs.acquire_device(self, "after restart").is_empty():
			_fail("Restart allowed new device work before reconciliation")
			return
	elif mode == "chat_protocol":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		var store: RefCounted = jobs.get("queue")
		if not store.set_paused(true): _fail("Could not pause queue for protocol fixture"); return
		fake.prompt.text = "Add some gravity."
		fake._generate()
		var snapshot: Dictionary = store.snapshot()
		if snapshot.jobs.size() != 1: _fail("Protocol chat was not queued"); return
		var id: String = snapshot.jobs[0].id
		store.set_paused(false)
		var deadline := Time.get_ticks_msec() + 30000
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1: _fail("Protocol chat did not dispatch classification"); return
		var classified := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), classified)
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 2: _fail("Protocol chat did not dispatch an answer"); return
		var first := {"id": "one", "type": "function", "function": {"name": "get_scene_tree", "arguments": "{}"}}
		var second := {"id": "two", "type": "function", "function": {"name": "get_workspace_context", "arguments": "{}"}}
		var reply := JSON.stringify({"choices": [{"message": {"role": "assistant", "tool_calls": [first, second]}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), reply)
		while jobs.get_job_status(id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var first_step: Dictionary = jobs.get_job_status(id)
		if first_step.get("state") != "completed" or not bool(first_step.get("result", {}).get("continued", false)):
			_fail("Multi-call step did not complete as continued: " + str(first_step)); return
		var next_id := str(first_step.get("result", {}).get("next_job", ""))
		if next_id.is_empty():
			_fail("Multi-call step did not name its continuation"); return
		if fake.tool_call_count != 2:
			_fail("Multi-call tool count was not preserved: " + str(fake.tool_call_count)); return
		while fake.submissions.size() < 3 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 3:
			_fail("Continuation step did not dispatch: submissions=" + str(fake.submissions.size())); return
		var tool_messages: Array = fake.turn_messages.slice(-2)
		if tool_messages.size() != 2 or tool_messages[0].get("tool_call_id") != "one" or tool_messages[1].get("tool_call_id") != "two":
			_fail("Multi-call tool results were not matched in order: " + str(tool_messages)); return
		var final_text := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "Multi-call complete."}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), final_text)
		while jobs.get_job_status(next_id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var final: Dictionary = jobs.get_job_status(next_id)
		if final.get("state") != "completed" or not final.attempts.back().get("device_confirmed", false):
			_fail("Multi-call chat did not complete as a confirmed job: " + str(final)); return
		if not str(final.get("result", {}).get("response", "")).contains("Multi-call complete"):
			_fail("Multi-call chat lost its final response: " + str(final)); return
		await get_tree().process_frame
		var completion_lease: String = jobs.acquire_device(self, "after multi-call completion")
		if jobs.device_recovery_pending() or completion_lease.is_empty():
			_fail("Multi-call completion retained an uncertain device lease: pending=" + str(jobs.device_recovery_pending()) + " lease=" + str(not completion_lease.is_empty())); return
		jobs.release_device(self, completion_lease)
		print("Built-in Jobs chat_protocol passed")
		get_tree().quit()
		return
	elif mode == "chat_chain":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		var store: RefCounted = jobs.get("queue")
		var bad_turn: Dictionary = jobs.append_job("bad-turn", "chat_turn", {"prompt": "x", "context": "", "custom_prompt": "", "model": "code", "connection_hash": "a".repeat(64), "conversation": [], "timeout_ms": 15000, "turn": {"id": "x", "step": 2}})
		if not bad_turn.has("error"):
			_fail("Malformed turn state was accepted")
			return
		fake.prompt.text = "Build a small game in steps."
		fake._generate()
		var deadline := Time.get_ticks_msec() + 30000
		var first_id: String = store.snapshot().jobs.back().id
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1: _fail("Chain chat did not dispatch classification"); return
		var classified := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), classified)
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 2: _fail("Chain chat did not dispatch the first answer"); return
		var round_one := {"id": "chain-one", "type": "function", "function": {"name": "get_scene_tree", "arguments": "{}"}}
		var reply_one := JSON.stringify({"choices": [{"message": {"role": "assistant", "tool_calls": [round_one]}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), reply_one)
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), reply_one)
		var after_duplicate: Array = store.snapshot().jobs.filter(func(job): return job.operation == "chat_turn")
		if after_duplicate.size() != 1:
			_fail("A continuation was persisted before the parent completed: " + str(after_duplicate.size())); return
		while jobs.get_job_status(first_id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var step_one: Dictionary = jobs.get_job_status(first_id)
		after_duplicate = store.snapshot().jobs.filter(func(job): return job.operation == "chat_turn")
		if after_duplicate.size() != 2:
			_fail("A repeated response created duplicate continuations: " + str(after_duplicate.size())); return
		var second_id := str(step_one.get("result", {}).get("next_job", ""))
		if step_one.get("state") != "completed" or not bool(step_one.get("result", {}).get("continued", false)) or second_id.is_empty():
			_fail("Chain step one did not continue: " + str(step_one)); return
		while fake.submissions.size() < 3 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 3: _fail("Chain step two did not dispatch"); return
		var round_two := {"id": "chain-two", "type": "function", "function": {"name": "get_workspace_context", "arguments": "{}"}}
		var reply_two := JSON.stringify({"choices": [{"message": {"role": "assistant", "tool_calls": [round_two]}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), reply_two)
		while jobs.get_job_status(second_id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var step_two: Dictionary = jobs.get_job_status(second_id)
		var third_id := str(step_two.get("result", {}).get("next_job", ""))
		if step_two.get("state") != "completed" or not bool(step_two.get("result", {}).get("continued", false)) or third_id.is_empty():
			_fail("Chain step two did not continue: " + str(step_two)); return
		if int(step_two.get("parameters", {}).get("turn", {}).get("step", 0)) != 2 or int(step_two.get("parameters", {}).get("turn", {}).get("rounds", 0)) != 1:
			_fail("Chain step two did not restore its step and round counters: " + str(step_two.get("parameters", {}))); return
		while fake.submissions.size() < 4 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 4: _fail("Chain step three did not dispatch"); return
		var final_text := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "Chain complete."}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), final_text)
		while jobs.get_job_status(third_id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var step_three: Dictionary = jobs.get_job_status(third_id)
		if step_three.get("state") != "completed" or not str(step_three.get("result", {}).get("response", "")).contains("Chain complete"):
			_fail("Chain final step did not record the response: " + str(step_three)); return
		if int(step_three.get("parameters", {}).get("turn", {}).get("step", 0)) != 3 or int(step_three.get("parameters", {}).get("turn", {}).get("rounds", 0)) != 2:
			_fail("Chain final step did not restore its step and round counters: " + str(step_three.get("parameters", {}))); return
		var chain_jobs: Array = store.snapshot().jobs.filter(func(job): return job.operation == "chat_turn")
		if chain_jobs.size() != 3:
			_fail("Chain did not produce three chat steps: " + str(chain_jobs.size())); return
		print("Built-in Jobs chat_chain passed")
		get_tree().quit()
		return
	elif mode == "chat_chain_prepare":
		var store: RefCounted = jobs.get("queue")
		if not store.set_paused(true):
			_fail("Could not pause for continuation restart")
			return
		var turn := {
			"id": "restart-turn",
			"step": 2,
			"system": "Fixture system",
			"messages": [
				{"role": "user", "content": "Restart request"},
				{"role": "assistant", "tool_calls": [{"id": "restart-call", "type": "function", "function": {"name": "get_scene_tree", "arguments": "{}"}}]},
				{"role": "tool", "tool_call_id": "restart-call", "content": "{\"ok\":true}"},
			],
			"rounds": 1,
			"count": 1,
			"calls": ["restart-call"],
			"failed": {},
			"ledger": [],
			"scene": {},
		}
		var accepted: Dictionary = jobs.append_job("restart-continuation", "chat_turn", {"prompt": "Restart request", "context": "", "custom_prompt": "", "model": "fixture-model", "connection_hash": "a".repeat(64), "conversation": turn.messages, "timeout_ms": 15000, "turn": turn})
		if not accepted.has("id"):
			_fail("Continuation was not accepted for restart: " + str(accepted))
			return
		print("Built-in Jobs chat_chain_prepare passed")
		get_tree().quit()
		return
	elif mode == "chat_chain_restore":
		var store: RefCounted = jobs.get("queue")
		var snapshot: Dictionary = store.snapshot()
		var found := false
		for job in snapshot.jobs:
			if job.operation != "chat_turn" or not job.parameters.get("turn") is Dictionary:
				continue
			var turn: Dictionary = job.parameters.turn
			if str(turn.get("id", "")) == "restart-turn" and int(turn.get("step", 0)) == 2 and int(turn.get("rounds", 0)) == 1 and Array(turn.get("messages", [])).size() == 3 and Array(turn.get("calls", [])) == ["restart-call"]:
				found = true
		if not found:
			_fail("Continuation state did not survive restart: " + str(snapshot))
			return
		print("Built-in Jobs chat_chain_restore passed")
		get_tree().quit()
		return
	elif mode == "device_acknowledge":
		var marker_path: String = jobs.get("device_lock_path")
		var marker_file := FileAccess.open(marker_path, FileAccess.WRITE)
		if marker_file == null:
			_fail("Could not write the fixture device marker")
			return
		marker_file.store_string(JSON.stringify({"schema": 1, "state": "uncertain", "project": "/tmp/other-project", "job": "other-1", "verb": "inference", "model": "fixture-model", "connection": "a".repeat(64)}))
		marker_file.close()
		if not jobs.acknowledge_foreign_device_marker():
			_fail("Foreign uncertain marker was not acknowledged")
			return
		var marker: Dictionary = jobs._device_marker()
		if marker.get("state") != "idle":
			_fail("Acknowledged marker is not idle: " + str(marker))
			return
		print("Built-in Jobs device_acknowledge passed")
		get_tree().quit()
		return
	elif mode == "queue_resume":
		var store: RefCounted = jobs.get("queue")
		if not store.set_paused(true):
			_fail("Could not pause the queue for the resume fixture")
			return
		var accepted: Dictionary = jobs.append_job("resume-fixture", "create_tree", {"destination": "res://assets/resume.png", "timeout_ms": 30000})
		if not accepted.has("id"):
			_fail("Resume fixture job was not accepted: " + str(accepted))
			return
		if not bool(store.snapshot().paused):
			_fail("Queue did not stay paused with a queued job")
			return
		jobs._resume_if_queued()
		if bool(store.snapshot().paused):
			_fail("Queue did not resume with a queued job")
			return
		var deadline := Time.get_ticks_msec() + 30000
		while jobs.get_job_status(accepted.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if jobs.get_job_status(accepted.id).get("state") != "completed":
			_fail("Resumed job did not complete: " + str(jobs.get_job_status(accepted.id)))
			return
		print("Built-in Jobs queue_resume passed")
		get_tree().quit()
		return
	elif mode == "chat_truncation":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		var store: RefCounted = jobs.get("queue")
		fake.prompt.text = "Build a complex arena."
		fake._generate()
		var deadline := Time.get_ticks_msec() + 30000
		var first_id: String = store.snapshot().jobs.back().id
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1: _fail("Truncation chat did not dispatch classification"); return
		var classified := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), classified)
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 2: _fail("Truncation chat did not dispatch an answer"); return
		var truncated := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": ""}, "finish_reason": "length"}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), truncated)
		while jobs.get_job_status(first_id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var first_step: Dictionary = jobs.get_job_status(first_id)
		var retry_id := str(first_step.get("result", {}).get("next_job", ""))
		if first_step.get("state") != "completed" or not bool(first_step.get("result", {}).get("continued", false)) or retry_id.is_empty():
			_fail("Truncated response did not queue a concise retry: " + str(first_step)); return
		while fake.submissions.size() < 3 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 3: _fail("Truncation retry did not dispatch"); return
		var last_message: Dictionary = Array(fake.submissions[2].messages).back()
		if last_message.get("role") != "user" or not str(last_message.get("content", "")).contains("cut off"):
			_fail("Truncation retry did not include the concise continuation prompt: " + str(last_message)); return
		var final_text := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "Arena complete."}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), final_text)
		while jobs.get_job_status(retry_id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var retry_step: Dictionary = jobs.get_job_status(retry_id)
		if retry_step.get("state") != "completed" or not str(retry_step.get("result", {}).get("response", "")).contains("Arena complete"):
			_fail("Truncation retry did not complete with the final response: " + str(retry_step)); return
		if int(retry_step.get("parameters", {}).get("turn", {}).get("truncations", 0)) != 1:
			_fail("Truncation retry did not persist its retry count: " + str(retry_step.get("parameters", {}))); return
		print("Built-in Jobs chat_truncation passed")
		get_tree().quit()
		return
	elif mode == "chat_empty":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		var store: RefCounted = jobs.get("queue")
		if not store.set_paused(true): _fail("Could not pause queue for empty fixture"); return
		fake.prompt.text = "add some gravity"
		fake._generate()
		var snapshot: Dictionary = store.snapshot()
		if snapshot.jobs.size() != 1: _fail("Empty-response chat was not queued"); return
		var id: String = snapshot.jobs[0].id
		store.set_paused(false)
		var deadline := Time.get_ticks_msec() + 10000
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1: _fail("Empty-response chat did not classify"); return
		var classified := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), classified)
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 2: _fail("Empty-response chat did not answer"); return
		var empty := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": ""}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), empty)
		while jobs.get_job_status(id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var final: Dictionary = jobs.get_job_status(id)
		if final.get("state") != "failed" or not str(final.get("result", {}).get("error", "")).contains("empty response"):
			_fail("Empty response was not a clear failure: " + str(final)); return
		if not final.attempts.back().get("device_confirmed", false) or jobs.device_recovery_pending() or jobs.acquire_device(self, "after empty failure").is_empty():
			_fail("Empty response retained an uncertain device lease"); return
		print("Built-in Jobs chat_empty passed")
		get_tree().quit()
		return
	elif mode == "chat_image_stale":
		var actual := get_tree().get_first_node_in_group("tiiny_setup_manager")
		actual.remove_from_group("tiiny_setup_manager")
		var image_manager := WarmImageManager.new()
		add_child(image_manager)
		image_manager.add_to_group("tiiny_setup_manager")
		var settings := EditorInterface.get_editor_settings()
		settings.set_setting("tiiny_ai/models/image_model", "fixture-image")
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.image_success_fixture = true
		fake.jobs_service = jobs
		jobs.chat_service = fake
		fake.prompt.text = "Generate an image."
		fake._generate()
		var id: String = jobs.queue.snapshot().jobs.back().id
		var deadline := Time.get_ticks_msec() + 30000
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1: _fail("Stale image classification did not start"); return
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer())
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 2: _fail("Stale image answer did not start"); return
		jobs.queue.set_paused(true)
		var call := {"id": "stale-image", "type": "function", "function": {"name": "generate_image", "arguments": JSON.stringify({"prompt": "fixture"})}}
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"choices": [{"message": {"role": "assistant", "tool_calls": [call]}}]}).to_utf8_buffer())
		while jobs.get_job_status(id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var chain: Array = jobs.queue.snapshot().jobs
		if chain.size() != 2 or chain[1].state != "queued": _fail("Image job did not wait in FIFO"); return
		settings.set_setting("tiiny_ai/models/image_model", "changed-image")
		jobs.queue.set_paused(false)
		var result: Dictionary = jobs.get_job_status(str(chain[1].id))
		while result.get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
			result = jobs.get_job_status(str(chain[1].id))
		if result.get("state") != "failed" or fake.image_asset_calls != 0 or jobs.queue.snapshot().jobs.size() != 2:
			_fail("Changed image selection was not rejected before device work: " + str(result)); return
		print("Built-in Jobs chat_image_stale passed")
		get_tree().quit()
		return
	elif mode == "chat_image_handoff":
		var actual := get_tree().get_first_node_in_group("tiiny_setup_manager")
		actual.remove_from_group("tiiny_setup_manager")
		var image_manager := WarmImageManager.new()
		add_child(image_manager)
		image_manager.add_to_group("tiiny_setup_manager")
		EditorInterface.get_editor_settings().set_setting("tiiny_ai/models/image_model", "fixture-image")
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.image_success_fixture = true
		fake.jobs_service = jobs
		jobs.chat_service = fake
		fake.prompt.text = "Generate an image and inspect the job."
		fake._generate()
		var first_id: String = jobs.queue.snapshot().jobs.back().id
		var deadline := Time.get_ticks_msec() + 30000
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1: _fail("Image handoff classification did not start"); return
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer())
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 2: _fail("Image handoff answer did not start"); return
		var image_call := {"id": "image-one", "type": "function", "function": {"name": "generate_image", "arguments": JSON.stringify({"prompt": "fixture"})}}
		var status_call := {"id": "status-two", "type": "function", "function": {"name": "get_job_status", "arguments": JSON.stringify({"id": first_id})}}
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"choices": [{"message": {"role": "assistant", "tool_calls": [image_call, status_call]}}]}).to_utf8_buffer())
		while fake.submissions.size() < 3 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 3: _fail("Image handoff did not resume the model: " + str(jobs.queue.snapshot())); return
		var messages: Array = fake.submissions.back().messages
		var tool_messages: Array = messages.filter(func(message): return message.get("role") == "tool")
		if tool_messages.size() != 2 or tool_messages[0].get("tool_call_id") != "image-one" or tool_messages[1].get("tool_call_id") != "status-two":
			_fail("Image and remaining tool results were not retained in order: " + str(tool_messages)); return
		var generated: Variant = JSON.parse_string(str(tool_messages[0].content))
		if not generated is Dictionary or not generated.get("ok", false) or not FileAccess.file_exists(str(generated.get("data", {}).get("path", ""))):
			_fail("Image tool did not return the generated artifact: " + str(generated)); return
		var chain: Array = jobs.queue.snapshot().jobs
		if chain.size() != 4 or chain[0].operation != "chat_turn" or chain[1].operation != "asset_generate" or chain[1].state != "completed" or chain[2].operation != "chat_turn" or chain[3].operation != "chat_turn":
			_fail("Image handoff did not use independent FIFO jobs: " + str(chain)); return
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "done"}}]}).to_utf8_buffer())
		while jobs.get_job_status(str(chain[3].id)).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if jobs.get_job_status(str(chain[3].id)).get("state") != "completed": _fail("Image turn did not finish"); return
		print("Built-in Jobs chat_image_handoff passed")
		get_tree().quit()
		return
	elif mode == "chat_image_uncertain":
		var actual := get_tree().get_first_node_in_group("tiiny_setup_manager")
		actual.remove_from_group("tiiny_setup_manager")
		var image_manager := WarmImageManager.new()
		add_child(image_manager)
		image_manager.add_to_group("tiiny_setup_manager")
		EditorInterface.get_editor_settings().set_setting("tiiny_ai/models/image_model", "fixture-image")
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.image_timeout_fixture = true
		fake.jobs_service = jobs
		jobs.chat_service = fake
		fake.prompt.text = "Generate an image."
		fake._generate()
		var id: String = jobs.queue.snapshot().jobs.back().id
		var deadline := Time.get_ticks_msec() + 30000
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1: _fail("Image fixture classification did not start"); return
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer())
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 2: _fail("Image fixture answer did not start"); return
		var call := {"id": "image-call", "type": "function", "function": {"name": "generate_image", "arguments": JSON.stringify({"prompt": "fixture"})}}
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"choices": [{"message": {"role": "assistant", "tool_calls": [call]}}]}).to_utf8_buffer())
		while jobs.get_job_status(id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		while jobs.queue.snapshot().jobs.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var chain: Array = jobs.queue.snapshot().jobs
		var stopped: Dictionary = jobs.get_job_status(str(chain.back().id))
		while stopped.get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
			stopped = jobs.get_job_status(str(chain.back().id))
		var marker: Dictionary = jobs._device_marker()
		if stopped.get("operation") != "asset_generate" or stopped.get("state") != "interrupted" or marker.get("model") != "fixture-image" or not jobs.device_recovery_pending() or jobs.queue.snapshot().jobs.size() != 2:
			_fail("Uncertain image request did not stop without a continuation: " + str(stopped)); return
		print("Built-in Jobs chat_image_uncertain passed")
		get_tree().quit()
		return
	elif mode == "chat_second_request_uncertain":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		fake.prompt.text = "Exercise the second request."
		fake._generate()
		var id: String = jobs.queue.snapshot().jobs.back().id
		var deadline := Time.get_ticks_msec() + 30000
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1: _fail("Classification did not start"); return
		var classified := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), classified)
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var running: Dictionary = jobs.get_job_status(id)
		if fake.submissions.size() < 2 or running.attempts.back().get("device_confirmed", false) or not jobs.device_recovery_pending():
			_fail("The answer request did not establish a fresh uncertainty boundary: " + str(running)); return
		await fake._request_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
		while jobs.get_job_status(id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var stopped: Dictionary = jobs.get_job_status(id)
		if stopped.get("state") != "interrupted" or not jobs.device_recovery_pending() or jobs.queue.resolve(id, "retry"):
			_fail("An uncertain answer request was not stopped for reconciliation: " + str(stopped)); return
		print("Built-in Jobs chat_second_request_uncertain passed")
		get_tree().quit()
		return
	elif mode == "chat":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		var store: RefCounted = jobs.get("queue")
		if not store.set_paused(true):
			_fail("Could not pause queue")
			return
		fake.prompt.text = "Original request"
		fake.context_marker = "original"
		fake._generate()
		var snapshot: Dictionary = store.snapshot()
		if snapshot.jobs.size() != 1 or snapshot.jobs[0].operation != "chat_turn" or snapshot.jobs[0].state != "queued":
			_fail("Chat was not durably queued: " + str(snapshot))
			return
		if JSON.stringify(snapshot).contains("fixture-queued-secret"):
			_fail("Chat credentials were stored in the queue")
			return
		var id: String = snapshot.jobs[0].id
		var before_chat: Dictionary = jobs.append_job("before-chat-finish", "create_tree", {"destination": "res://assets/before.png", "timeout_ms": 30000})
		if before_chat.get("sequence") != 2:
			_fail("Job appended behind chat was not ordered")
			return
		fake.prompt.text = "Changed after acceptance"
		fake.context_marker = "changed"
		await get_tree().create_timer(0.2).timeout
		if not fake.submissions.is_empty():
			_fail("Paused chat dispatched early")
			return
		store.set_paused(false)
		var deadline := Time.get_ticks_msec() + 30000
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1:
			_fail("Queued chat did not dispatch")
			return
		if str(fake.submissions[0].messages.back().content) != "Original request":
			_fail("Classification did not use the accepted prompt")
			return
		var classified := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), classified)
		await get_tree().process_frame
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 2:
			_fail("Classified chat did not dispatch an answer")
			return
		var messages: Array = fake.submissions[1].messages
		var answer_text := str(messages.back().content)
		if not answer_text.contains("Original request") or answer_text.contains("Changed after acceptance") or not answer_text.contains("Marker: original"):
			_fail("Queued chat did not retain accepted context")
			return
		var tool_call := {"id": "append-during-chat", "type": "function", "function": {"name": "append_job", "arguments": JSON.stringify({"operation": "create_tree", "destination": "res://assets/during.png"})}}
		var tool_reply := JSON.stringify({"choices": [{"message": {"role": "assistant", "tool_calls": [tool_call]}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), tool_reply)
		await get_tree().process_frame
		var tool_result: Variant = JSON.parse_string(fake.turn_messages.back().content)
		if not tool_result is Dictionary or tool_result.get("sequence") != 3:
			_fail("Assistant append did not reach the queue tail")
			return
		while jobs.get_job_status(id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var first_step: Dictionary = jobs.get_job_status(id)
		if first_step.get("state") != "completed" or not bool(first_step.get("result", {}).get("continued", false)):
			_fail("First chat step did not complete as continued: " + str(first_step))
			return
		var next_id := str(first_step.get("result", {}).get("next_job", ""))
		if next_id.is_empty():
			_fail("First chat step did not name its continuation")
			return
		var resource_callback: Array = []
		fake.generate_shape_for_dialog("Fixture polygon", func(shape, error): resource_callback.assign([shape, error]))
		snapshot = store.snapshot()
		var resource_id: String = snapshot.jobs.back().id
		if snapshot.jobs.back().operation != "resource_shape" or snapshot.jobs.back().sequence != 5 or not resource_callback.is_empty():
			_fail("Resource generation did not append behind current work")
			return
		while fake.submissions.size() < 3 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 3:
			_fail("Continuation step did not dispatch after preceding jobs")
			return
		var reply := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "Fixture answer"}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), reply)
		while jobs.get_job_status(next_id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if jobs.get_job_status(next_id).get("state") != "completed" or jobs.get_job_status(next_id).result.response != "Fixture answer":
			_fail("Queued chat result was not committed on the continuation")
			return
		while fake.resource_submissions.is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.resource_submissions.is_empty() or not resource_callback.is_empty():
			_fail("Resource callback ran before the queued request")
			return
		var shape_reply := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": '{"points":[[0,0],[32,0],[0,32]]}'}}]}).to_utf8_buffer()
		fake.resource_submissions[0].request_completed.emit(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), shape_reply)
		while resource_callback.is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if resource_callback.size() != 2 or not resource_callback[0] is ConvexPolygonShape2D or jobs.get_job_status(resource_id).get("state") != "completed":
			_fail("Resource result was not validated and committed before callback")
			return
		fake.prompt.text = "Failing request"
		var previous_submissions: int = fake.submissions.size()
		fake._generate()
		snapshot = store.snapshot()
		var failed_id: String = snapshot.jobs.back().id
		while fake.submissions.size() <= previous_submissions and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() <= previous_submissions:
			_fail("Later chat did not dispatch after preceding jobs")
			return
		await fake._request_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
		while jobs.get_job_status(failed_id).get("state") == "running" and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if jobs.get_job_status(failed_id).get("state") != "interrupted" or store.resolve(failed_id, "retry"):
			_fail("Unknown device outcome did not stop for reconciliation")
			return
		if not jobs.acquire_device(self, "after timeout").is_empty():
			_fail("Device lease was released despite an uncertain remote outcome")
			return
	elif mode == "chat_abandon":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		var store: RefCounted = jobs.get("queue")
		fake.prompt.text = "Abandon after timeout"
		fake._generate()
		var deadline := Time.get_ticks_msec() + 10000
		while fake.submissions.is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.is_empty():
			_fail("Abandon fixture did not dispatch")
			return
		var id: String = store.snapshot().jobs.back().id
		await fake._request_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
		while jobs.get_job_status(id).get("state") == "running" and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if jobs.get_job_status(id).get("state") != "interrupted":
			_fail("Timeout did not leave the device job interrupted")
			return
		if not jobs.acquire_device(self, "before abandon").is_empty():
			_fail("Interrupted device job did not hold the lease")
			return
		jobs.abandon_id = id
		jobs._on_abandon_confirmed()
		if jobs.get_job_status(id).state != "skipped" or not store.snapshot().stop_reason.is_empty() or not store.snapshot().paused:
			_fail("Interrupted device job could not be abandoned")
			return
		var token: String = jobs.acquire_device(self, "after abandon")
		if token.is_empty():
			_fail("Device lease was not released after abandon")
			return
		jobs.release_device(self, token)
	elif mode in ["stale", "missing"]:
		EditorInterface.open_scene_from_path("res://target.tscn")
		for i in range(200):
			if EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == "res://target.tscn":
				break
			await get_tree().create_timer(0.05).timeout
		var scene := EditorInterface.get_edited_scene_root()
		if scene == null or scene.scene_file_path != "res://target.tscn":
			_fail("Scene failed to open")
			return
		var path := "res://assets/tree.png"
		if mode == "missing":
			var conflict := FileAccess.open(path, FileAccess.WRITE)
			conflict.store_string("existing file")
			conflict.close()
		var tree: Dictionary = jobs.append_job("tree", "create_tree", {"destination": path, "timeout_ms": 30000})
		var revision := "0".repeat(64) if mode == "stale" else FileAccess.get_sha256("res://target.tscn")
		var attach: Dictionary = jobs.append_job("attach", "attach_tree_to_scene", {"artifact_id": tree.id + ":tree", "scene_path": "res://target.tscn", "scene_sha256": revision, "parent_path": ".", "node_name": "Tree", "timeout_ms": 30000})
		var deadline := Time.get_ticks_msec() + 40000
		var watched: String = attach.id if mode == "stale" else tree.id
		while Time.get_ticks_msec() < deadline and jobs.get_job_status(watched).get("state") in ["queued", "running"]:
			await get_tree().create_timer(0.05).timeout
		if jobs.get_job_status(watched).get("state") != "failed":
			_fail("Expected job failure did not occur")
			return
		if mode == "missing":
			var store: RefCounted = jobs.get("queue")
			if not store.resolve(tree.id, "skip") or not store.set_paused(false):
				_fail("Could not explicitly skip failed tree")
				return
			while Time.get_ticks_msec() < deadline and jobs.get_job_status(attach.id).get("state") in ["queued", "running"]:
				await get_tree().create_timer(0.05).timeout
		var result: Dictionary = jobs.get_job_status(attach.id)
		if result.get("state") != "failed" or scene.has_node("Tree"):
			_fail("Invalid attachment mutated the scene: " + str(result))
			return
		if mode == "stale" and not result.result.error.contains("changed"):
			_fail("Stale scene diagnostic missing")
			return
		if mode == "missing" and not result.result.error.contains("missing"):
			_fail("Missing artifact diagnostic missing")
			return
	else:
		_fail("Unknown fixture mode")
		return
	print("Built-in Jobs %s passed" % mode)
	get_tree().quit(0)
