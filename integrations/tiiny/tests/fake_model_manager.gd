@tool
extends "res://manager.gd"

var fixture_state: Dictionary = {}
var calls: Array = []
var fail_command := false
var omit_effect := false
var partial_load := false
var snapshot_error := ""
var error_after_command := ""
var wait_for_cancel := false

# The planner/transport fixture isolates the Apply state machine. The built-in
# Jobs fixture exercises production submission and its persistent journal.
func fixture_apply_config() -> void:
	if busy or not plan.get("ok", false): return
	if draft != plan.get("draft", {}) or Time.get_ticks_msec() - int(plan.get("checked_at", 0)) > PLAN_LIFETIME * 1000:
		plan = {}
		return
	if not _acquire_device("apply models"):
		return
	var approved: Dictionary = plan.duplicate(true)
	await _execute_model_configuration(approved)

func _connection() -> Dictionary:
	return {"identity": str(fixture_state.get("connection", "fixture")), "base": "http://fixture", "key": "fixture"}

func _get_json(_connection: Dictionary, _path: String) -> Dictionary:
	return {"data": [{"model_id": "fixture-model", "progress": 42.5}]}

func _fetch_snapshot() -> Dictionary:
	if not snapshot_error.is_empty(): return {"error": snapshot_error}
	var copy := fixture_state.duplicate(true)
	copy["time"] = Time.get_ticks_msec()
	return copy

func _run_cli(arguments: Array) -> int:
	calls.append(arguments.duplicate())
	if wait_for_cancel:
		while not model_job_cancelled:
			await get_tree().create_timer(0.05).timeout
		return ERR_SKIP
	if fail_command: return 1
	if not error_after_command.is_empty():
		snapshot_error = error_after_command
		return 0
	if omit_effect: return 0
	match arguments[0]:
		"unload": fixture_state.loaded.erase(arguments[1])
		"load": fixture_state.loaded[arguments[1]] = fixture_state.models[arguments[1]].npu + (1.0 if partial_load else 0.0)
		"download": fixture_state.models[arguments[1]].installed = true
	return 0
