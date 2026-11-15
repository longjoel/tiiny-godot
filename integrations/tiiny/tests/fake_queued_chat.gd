@tool
extends "res://chat.gd"

var submissions: Array[Dictionary] = []
var resource_submissions: Array[HTTPRequest] = []
var context_marker := "queued"

func _manager_ready() -> bool:
	return true

func _editor_context() -> String:
	return "\n\n--- Editor context ---\nMarker: " + context_marker

func _inference_connection() -> Dictionary:
	return {"url": "http://fixture/v1", "host": "fixture", "key": "fixture-queued-secret"}

func _coding_model() -> String:
	return "fixture-model"

func _submit_chat(payload: Dictionary) -> int:
	submissions.append(payload.duplicate(true))
	return OK

func _submit_resource_request(req: HTTPRequest, _connection: Dictionary, _body: String) -> int:
	resource_submissions.append(req)
	return OK
