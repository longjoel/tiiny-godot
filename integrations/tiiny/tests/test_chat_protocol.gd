@tool
extends RefCounted

func _reply(message: Dictionary) -> PackedByteArray:
	return JSON.stringify({"choices": [{"message": message}]}).to_utf8_buffer()

func _call(id: String, path: String) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": "create_gdscript", "arguments": JSON.stringify({"path": path, "source": "extends Node\n"})}}

func _begin(dock: Control) -> void:
	dock.request_stage = "answer"
	dock.pending_prompt = "Create a fixture"
	dock.pending_key = "fixture-secret-key"
	dock.pending_model = "fixture-code"
	dock.send_button.disabled = true
	dock.shape_button.disabled = true
	dock._send_chat("Fixture system", dock.pending_prompt)

func _idle(dock: Control) -> bool:
	return not dock.send_button.disabled and not dock.shape_button.disabled

func _recover(dock: Control) -> bool:
	_begin(dock)
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _reply({"role": "assistant", "content": "Recovered", "tool_calls": null}))
	return _idle(dock) and dock.output.text.contains("Recovered")

func _tool(dock: Control, calls: Variant) -> void:
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _reply({"role": "assistant", "tool_calls": calls}))
	await dock.get_tree().process_frame

func run(plugin: EditorPlugin) -> String:
	var dock = load("res://fake_chat.gd").new()
	plugin.add_child(dock)
	var logs: Array[String] = []
	dock.log_message.connect(func(message: String, _kind: int): logs.append(message))
	if not await _recover(dock): return "Basic text response failed."
	# Malformed envelopes and transport failures unlock controls and allow a new turn.
	for envelope in [{}, {"choices": []}, {"choices": [null]}, {"choices": [{"message": {"role": "user", "content": "wrong role"}}]}]:
		_begin(dock)
		await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify(envelope).to_utf8_buffer())
		if not _idle(dock) or not await _recover(dock): return "Malformed envelope prevented recovery."
	_begin(dock)
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), "not JSON".to_utf8_buffer())
	if not _idle(dock) or not await _recover(dock): return "Invalid JSON prevented recovery."
	_begin(dock)
	await dock._request_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
	if not _idle(dock) or not await _recover(dock): return "Timeout prevented recovery."
	_begin(dock)
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 401, PackedStringArray(), JSON.stringify({"error": {"message": "fixture-secret-key data:image/png;base64,fixture"}}).to_utf8_buffer())
	if not _idle(dock) or not await _recover(dock): return "HTTP failure prevented recovery."
	if logs.any(func(line): return "fixture-secret-key" in line or "base64,fixture" in line): return "Server error body leaked into Output."
	dock.submit_error = ERR_CANT_CONNECT
	_begin(dock)
	if not _idle(dock): return "Immediate initial request failure locked controls."
	dock.submit_error = OK
	if not await _recover(dock): return "Initial request start failure prevented recovery."
	# Validate before dispatch: none of these calls may create the requested file.
	var empty_id := _call("", "res://invalid_call.gd")
	var wrong_type := _call("bad-type", "res://invalid_call.gd")
	wrong_type.type = "custom"
	var wrong_arguments := _call("bad-arguments", "res://invalid_call.gd")
	wrong_arguments.function.arguments = {"path": "res://invalid_call.gd", "source": "extends Node\n"}
	var invalid_json := _call("bad-json", "res://invalid_call.gd")
	invalid_json.function.arguments = "{"
	var wrong_name := _call("bad-name", "res://invalid_call.gd")
	wrong_name.function.name = 4
	for calls in [[{}], [1], [empty_id], [wrong_type], [wrong_arguments], [invalid_json], [wrong_name], [_call("long".repeat(40), "res://invalid_call.gd")], [_call("a", "res://invalid_call.gd"), _call("b", "res://invalid_call.gd")], "not an array"]:
		_begin(dock)
		var before: int = dock.submissions.size()
		await _tool(dock, calls)
		if FileAccess.file_exists("res://invalid_call.gd"): return "Malformed tool call created a file before validation."
		if dock.submissions.size() != before or not _idle(dock) or not await _recover(dock): return "Malformed tool call continued or prevented recovery."
	_begin(dock)
	dock.tool_rounds = 4
	await _tool(dock, [_call("limit", "res://invalid_call.gd")])
	if FileAccess.file_exists("res://invalid_call.gd") or not _idle(dock): return "Tool round limit did not stop execution."
	# A valid unknown tool returns a matched tool error, never a mutation.
	_begin(dock)
	var unknown := _call("unknown", "res://invalid_call.gd")
	unknown.function.name = "unsupported_fixture_tool"
	await _tool(dock, [unknown])
	var result: Dictionary = dock.turn_messages.back()
	if result.get("role") != "tool" or result.get("tool_call_id") != "unknown" or not str(result.get("content")).begins_with("Error:"): return "Unsupported tool did not return a matched failure."
	if FileAccess.file_exists("res://invalid_call.gd"): return "Unsupported tool mutated the project."
	if dock.submissions.back().messages.back() != result: return "Continuation omitted the tool result."
	if not await _recover(dock): return "Unsupported tool prevented a subsequent turn."
	# The path validator must reject traversal without writing outside the project.
	_begin(dock)
	await _tool(dock, [_call("traversal", "res://../escape.gd")])
	if not str(dock.turn_messages.back().content).begins_with("Error:"): return "Traversal did not fail."
	# Complete a normal tool/result/final-answer turn without resetting its history.
	_begin(dock)
	await _tool(dock, [_call("normal", "res://normal.gd")])
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _reply({"role": "assistant", "content": "Tool completed"}))
	if not _idle(dock) or dock.conversation.back().get("content") != "Tool completed" or dock.conversation[-2].get("tool_call_id") != "normal": return "Normal tool/result/final-answer flow failed."
	# Successful mutation remains visible and in context after a continuation error.
	_begin(dock)
	await _tool(dock, [_call("create", "res://completed.gd")])
	if not FileAccess.file_exists("res://completed.gd") or not dock.output.text.contains("res://completed.gd"): return "Completed tool effect was not visible."
	if dock.conversation.back().get("tool_call_id") != "create": return "Completed effect was not retained in context."
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 503, PackedStringArray(), PackedByteArray())
	if not _idle(dock) or not dock.output.text.contains("res://completed.gd"): return "Continuation failure hid completed work or locked controls."
	if not await _recover(dock): return "Continuation failure prevented the next turn."
	# Repeated IDs in one turn must not dispatch another mutation.
	_begin(dock)
	await _tool(dock, [_call("repeat", "res://first.gd")])
	await _tool(dock, [_call("repeat", "res://invalid_call.gd")])
	if FileAccess.file_exists("res://invalid_call.gd") or not _idle(dock): return "Repeated tool ID dispatched a second mutation."
	# A new call cannot overwrite an existing file, including on a later turn.
	_begin(dock)
	var overwrite := _call("overwrite", "res://completed.gd")
	overwrite.function.arguments = JSON.stringify({"path": "res://completed.gd", "source": "extends Resource\n"})
	await _tool(dock, [overwrite])
	if FileAccess.get_file_as_string("res://completed.gd") != "extends Node\n" or not str(dock.turn_messages.back().content).begins_with("Error:"): return "Existing script was overwritten."
	# Immediate continuation-start errors must preserve the same completion guarantees.
	_begin(dock)
	dock.submit_error = ERR_CANT_CONNECT
	await _tool(dock, [_call("start-error", "res://start_error.gd")])
	if not _idle(dock) or not dock.output.text.contains("res://start_error.gd"): return "Failed continuation start lost completed work."
	dock.submit_error = OK
	if not await _recover(dock): return "Immediate continuation failure prevented recovery."
	# A full context must have a usable escape without erasing prior artifact logs.
	dock.conversation.assign([{"role": "user", "content": "x".repeat(20000)}])
	_begin(dock)
	if not _idle(dock): return "Context overflow locked controls."
	var previous_output: String = dock.output.text
	for child in dock.get_children():
		if child is Button and child.text == "New conversation": child.pressed.emit()
	if not dock.conversation.is_empty() or dock.output.text != previous_output: return "Conversation reset lost results or retained full context."
	if not await _recover(dock): return "New conversation did not recover from a full context."
	dock.queue_free()
	await plugin.get_tree().process_frame
	print("Offline chat protocol and continuation recovery passed (fake HTTP boundary, real temporary script creation).")
	return ""
