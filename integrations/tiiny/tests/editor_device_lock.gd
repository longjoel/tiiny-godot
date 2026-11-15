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
	var lease: String = jobs.acquire_device(self, "cross-process fixture")
	if mode == "blocked":
		if not lease.is_empty():
			_fail("Another editor acquired the device lease")
			return
	elif mode in ["owner", "free"]:
		if lease.is_empty():
			_fail("Expected device lease was unavailable")
			return
		if mode == "owner":
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
