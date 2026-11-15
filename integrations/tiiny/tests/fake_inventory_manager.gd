@tool
extends "res://manager.gd"

# Exercise production refresh/check paths; only the connection/HTTP boundary is fake.
var responses := {}
var requests: Array[String] = []

func _connection() -> Dictionary:
	return {"base": "fixture", "key": "fixture", "identity": "fixture"}

func _get_json(_connection_data: Dictionary, path: String) -> Dictionary:
	requests.append(path)
	return responses.get(path, {"error": "Fixture catalog unavailable."}).duplicate(true)

func _run_cli(_arguments: Array) -> int:
	push_error("Read-only inventory tests must never execute the SDK.")
	return ERR_UNAVAILABLE
