@tool
extends "res://manager.gd"

var fixture_state: Dictionary = {}
var calls: Array = []
var fail_command := false
var omit_effect := false

func _get_json(_connection: Dictionary, _path: String) -> Dictionary:
	return {"data": [{"model_id": "fixture-model", "progress": 42.5}]}

func _fetch_snapshot() -> Dictionary:
	var copy := fixture_state.duplicate(true)
	copy["time"] = Time.get_ticks_msec()
	return copy

func _run_cli(arguments: Array) -> int:
	calls.append(arguments.duplicate())
	if fail_command: return 1
	if omit_effect: return 0
	match arguments[0]:
		"unload": fixture_state.loaded.erase(arguments[1])
		"load": fixture_state.loaded[arguments[1]] = fixture_state.models[arguments[1]].npu
		"download": fixture_state.models[arguments[1]].installed = true
	return 0
