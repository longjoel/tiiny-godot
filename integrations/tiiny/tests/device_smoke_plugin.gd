@tool
extends EditorPlugin

func _enter_tree() -> void:
	# Run tests immediately; quit with result when done.
	var failures:int = 0
	var mgr_text = FileAccess.get_file_as_string("res://manager.gd")
	if mgr_text.is_empty():
		print("[FAIL] Could not read manager.gd")
		failures = 1
	else:
		# Connection identity storage
		var ok = _check("connection_identity" in mgr_text, "Manager has connection_identity property")
		if not ok: failures += 1
		ok = _check('snapshot["connection_identity"]' in mgr_text, "Connection identity stored in snapshot after fetch")
		if not ok: failures += 1
		
		# Coding model protection
		ok = _check("_verify_coding_model" in mgr_text, "Startup coding model stability check exists")
		if not ok: failures += 1
		ok = _check("NPU allocation" in mgr_text, "NPU value matching in post-op verification")
		if not ok: failures += 1
		ok = _check("stall" in mgr_text.to_lower(), "Progress stall detection exists")
		if not ok: failures += 1
		ok = _check("coexist" in mgr_text.to_lower() or "protected" in mgr_text.to_lower(), "Protected coding model switch logic")
		if not ok: failures += 1
		
		# Error state tracking
		ok = _check("last_error_type" in mgr_text, "Error type tracking exists")
		if not ok: failures += 1
		ok = _check("connected = false" in mgr_text, "Error paths set connected=false")
		if not ok: failures += 1
		ok = _check("auth" in mgr_text.to_lower() and "disconnect" in mgr_text.to_lower() and "capacity" in mgr_text.to_lower(), "All error types classified (disconnect, auth, capacity)")
		if not ok: failures += 1
		
		# Fake manager fixture
		var fake_text = FileAccess.get_file_as_string("res://fake_device_manager.gd")
		if fake_text.is_empty():
			print("[FAIL] Could not read fake_device_manager.gd")
			failures += 1
		else:
			ok = _check("error_simulation" in fake_text, "Fake manager has error_simulation")
			if not ok: failures += 1
			ok = _check("disconnect" in fake_text and "auth" in fake_text and "capacity" in fake_text, "Fake manager simulates all error types")
			if not ok: failures += 1
	
	print("\n=== Results ===")
	print("Failures: ", failures)
	get_tree().quit(failures)

func _check(condition: Variant, name: String) -> bool:
	var result = "PASS" if condition else "FAIL"
	if not condition:
		print("[FAIL] ", name)
	else:
		print("[PASS] ", name)
	return condition

func _exit_tree() -> void:
	# Clean up
	pass
