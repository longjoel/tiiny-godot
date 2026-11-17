@tool
extends "res://chat.gd"

var submissions: Array[Dictionary] = []
var submit_error := OK

# This is the only outbound chat boundary; no sockets or credentials are used.
func _submit_chat(payload: Dictionary) -> int:
	submissions.append(payload.duplicate(true))
	return submit_error

# Fixture-only substitute for the real user confirmation dialog.
func _approve_file_edit(_action: String, _path: String, _reason: String) -> bool:
	return true
