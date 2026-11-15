@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _run() -> void:
	var jobs := get_tree().get_first_node_in_group("tiiny_job_manager")
	if jobs == null or not jobs.available:
		_fail("Jobs service unavailable")
		return
	var mode := OS.get_environment("TIINY_LOCK_TEST_MODE")
	if mode == "model_recover":
		var entries: Array = jobs.queue.snapshot().jobs
		if entries.is_empty() or entries.back().state != "interrupted" or not jobs.device_recovery_pending():
			_fail("Interrupted model marker was not retained")
			return
		var id: String = entries.back().id
		if not jobs.acknowledge_model_uncertainty(id) or not jobs.queue.abandon(id) or jobs.device_recovery_pending():
			_fail("Explicit model recovery did not clear the shared marker")
			return
		print("Device lock model_recover passed")
		get_tree().quit(0)
		return
	var lease: String = jobs.acquire_device(self, "cross-process fixture")
	if mode in ["blocked", "model_blocked"]:
		if not lease.is_empty():
			_fail("Another editor acquired the device lease")
			return
		if mode == "model_blocked" and not jobs.device_recovery_pending():
			_fail("Shared model recovery marker was not visible")
			return
	elif mode in ["owner", "free", "model_owner", "inference_owner", "corrupt_owner"]:
		if lease.is_empty():
			_fail("Expected device lease was unavailable")
			return
		if mode == "model_owner":
			var accepted: Dictionary = jobs.append_job("model-crash", "model_restore", {"model": "fixture-model", "connection": "a".repeat(64), "timeout_ms": 30000})
			var started: Dictionary = jobs.queue.start_next()
			if accepted.has("error") or started.get("id") != accepted.get("id") or not jobs.begin_model_operation(self, lease, accepted.id, "download", "fixture-model", "a".repeat(64)):
				_fail("Could not persist model operation before the simulated crash")
				return
			if jobs.release_device(self, lease):
				_fail("Uncertain model operation released its lease")
				return
		if mode == "inference_owner":
			jobs.queue.set_paused(false)
			var accepted: Dictionary = jobs.append_job("inference-crash", "chat_turn", {"prompt": "fixture", "context": "", "custom_prompt": "", "model": "fixture-model", "connection_hash": "a".repeat(64), "conversation": [], "timeout_ms": 30000})
			var started: Dictionary = jobs.queue.start_next()
			if accepted.has("error") or started.get("id") != accepted.get("id") or not jobs.begin_device_request(self, lease, accepted.id, "fixture-model", "a".repeat(64)):
				_fail("Could not persist inference before the simulated crash")
				return
			if jobs.release_device(self, lease):
				_fail("Uncertain inference released its lease")
				return
		if mode == "corrupt_owner" and not jobs.device_process_lock.commit("{broken"):
			_fail("Could not write the corrupt recovery fixture")
			return
		if mode in ["owner", "model_owner", "inference_owner", "corrupt_owner"]:
			var file := FileAccess.open(OS.get_environment("TIINY_LOCK_TEST_READY"), FileAccess.WRITE)
			file.store_string("ready")
			file.close()
			while true:
				await get_tree().create_timer(0.1).timeout
		jobs.release_device(self, lease)
	else:
		_fail("Unknown lock test mode")
		return
	print("Device lock %s passed" % mode)
	get_tree().quit(0)
