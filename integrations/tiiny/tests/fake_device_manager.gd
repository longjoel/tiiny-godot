@tool
extends "res://manager.gd"

# Fake manager for story 03 device lifecycle testing.
# Extends the base fake_manager.gd pattern with device binding,
# stall detection, and error type fixtures.

var fixture_state := {"models": {}, "loaded": {}, "npu_total": 100, "npu_used": 0, "disk_total": 200 * 1073741824, "disk_free": 80 * 1073741824, "connection": "fixture"}
var fixture_call_log := PackedStringArray()
var error_simulation := "none"  # "none", "disconnect", "auth", "capacity"
var stall_download := false
var stall_at_percent := 50.0
var stall_count := 0

func _get_json(_connection: Dictionary, path: String) -> Dictionary:
	fixture_call_log.append(path)
	# Simulate error conditions
	if error_simulation == "disconnect":
		if "status" in path: return {"error": "Could not start the device request (Connection refused)."}
		return {"data": []}
	if error_simulation == "auth":
		return {"error": "Device request failed (connection 0, HTTP 401)."}
	if error_simulation == "capacity":
		return {"data": {"npu_total": 0, "npu_used": 0, "models": []}}
	# Normal fixture behavior
	match path:
		"/api/v1/models/online_models":
			if stall_download:
				fixture_state["stall_reported"] = stall_count
				stall_count += 1
			return {"data": [{"model_id": "fixture-model", "progress": stall_at_percent if stall_download else 100.0}]}
		"/api/v1/models/npu/status":
			return {"data": fixture_state.duplicate()}
		"/api/v1/sys/storage":
			return {"data": {"total_bytes": fixture_state.disk_total, "remaining_bytes": fixture_state.disk_free}}
	return {"error": "Unknown fixture path: " + path}

func _fetch_snapshot() -> Dictionary:
	if error_simulation == "capacity":
		return {"data": {"npu_total": 0, "npu_used": 0, "models": []}}
	var copy := fixture_state.duplicate(true)
	copy["time"] = Time.get_ticks_msec()
	return copy

func _run_cli(arguments: Array) -> int:
	fixture_call_log.append(str(arguments))
	if error_simulation == "disconnect":
		return ERR_UNAVAILABLE
	# Track the model's loaded state
	match arguments[0]:
		"unload":
			fixture_state["loaded"].erase(arguments[1])
		"load":
			var expected_npu := 0.0
			if fixture_state["models"].has(arguments[1]) and fixture_state["models"][arguments[1]].get("npu", -1) >= 0:
				expected_npu = fixture_state["models"][arguments[1]]["npu"]
			else:
				expected_npu = 5.0  # Default assumption
			fixture_state["loaded"][arguments[1]] = expected_npu
		"download":
			fixture_state["models"][arguments[1]]["installed"] = true
			fixture_state["stall_reported"] = stall_count
			stall_count += 1
	return 0
