@tool
extends RefCounted

func _reply(message: Dictionary) -> PackedByteArray:
	return JSON.stringify({"choices": [{"message": message}]}).to_utf8_buffer()

func _call(id: String, path: String) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": "create_gdscript", "arguments": JSON.stringify({"path": path, "source": "extends Node\n", "reason": "fixture fallback"})}}

func _begin(dock: Control, prompt := "Create a fixture") -> void:
	dock.request_stage = "answer"
	dock.pending_prompt = prompt
	dock.pending_key = "fixture-secret-key"
	dock.pending_model = "fixture-code"
	dock.send_button.disabled = true
	dock._send_chat("Fixture system", dock.pending_prompt)

func _idle(dock: Control) -> bool:
	return not dock.send_button.disabled

func _recover(dock: Control) -> bool:
	_begin(dock)
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _reply({"role": "assistant", "content": "Recovered", "tool_calls": null}))
	return _idle(dock) and dock.history_text().contains("Recovered")

func _tool(dock: Control, calls: Variant) -> void:
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _reply({"role": "assistant", "tool_calls": calls}))
	await dock.get_tree().process_frame

func run(plugin: EditorPlugin) -> String:
	var dock = load("res://fake_chat.gd").new()
	plugin.add_child(dock)
	dock.jobs_service = plugin.get_tree().root.find_child("Tiiny Jobs", true, false)
	var real_dock := plugin.get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if real_dock == null or real_dock.get("workspace_coding_script") == null: return "Workspace provider unavailable to chat fixture."
	dock.workspace_coding = real_dock.get("workspace_coding_script").new(ProjectSettings.globalize_path("res://"))
	dock.workspace_coding.approve_edit = Callable(dock, "_approve_file_edit")
	var logs: Array[String] = []
	dock.log_message.connect(func(message: String, _kind: int): logs.append(message))
	if not await _recover(dock): return "Basic text response failed."
	if dock.jobs_service == null or not dock.jobs_service.available: return "Built-in Jobs service unavailable to chat fixture."
	_begin(dock)
	var append := {"id": "job-append", "type": "function", "function": {"name": "append_job", "arguments": JSON.stringify({"operation": "create_tree", "destination": "res://chat_fixture_tree.png"})}}
	await _tool(dock, [append])
	var accepted: Variant = JSON.parse_string(dock.turn_messages.back().content)
	if not accepted is Dictionary or not accepted.get("accepted", false) or not accepted.get("id") is String or not accepted.get("sequence") is float: return "Chat did not receive a durable job acceptance."
	if not str(accepted.message).contains("not yet known"): return "Chat claimed the job had completed."
	var job_id: String = accepted.id
	_begin(dock)
	var status_call := {"id": "job-status", "type": "function", "function": {"name": "get_job_status", "arguments": JSON.stringify({"id": job_id})}}
	await _tool(dock, [status_call])
	var job_status: Variant = JSON.parse_string(dock.turn_messages.back().content)
	if not job_status is Dictionary or job_status.get("id") != job_id or job_status.get("state") not in ["queued", "running", "completed"]: return "Chat job status did not report the accepted job."
	_begin(dock)
	append.function.arguments = JSON.stringify({"operation": "create_tree", "destination": "res://../escape.png"})
	append.id = "job-invalid"
	await _tool(dock, [append])
	if not str(dock.turn_messages.back().content).begins_with("Error:"): return "Invalid job was accepted by chat."
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and dock.jobs_service.get_job_status(job_id).get("state") in ["queued", "running"]:
		await plugin.get_tree().create_timer(0.05).timeout
	if dock.jobs_service.get_job_status(job_id).get("state") != "completed": return "Chat-submitted fixture did not complete."
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
	for calls in [[{}], [1], [empty_id], [wrong_type], [wrong_arguments], [invalid_json], [wrong_name], [_call("long".repeat(40), "res://invalid_call.gd")], [_call("dup", "res://invalid_call.gd"), _call("dup", "res://invalid_call.gd")], "not an array"]:
		_begin(dock)
		var before: int = dock.submissions.size()
		await _tool(dock, calls)
		if FileAccess.file_exists("res://invalid_call.gd"): return "Malformed tool call created a file before validation."
		if dock.submissions.size() != before or not _idle(dock) or not await _recover(dock): return "Malformed tool call continued or prevented recovery."
	_begin(dock)
	dock.tool_rounds = 100
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
	# Multiple well-formed calls execute sequentially and return matched results.
	_begin(dock)
	var multi_a := _call("multi-a", "res://multi_a.gd")
	var multi_b := _call("multi-b", "res://multi_b.gd")
	await _tool(dock, [multi_a, multi_b])
	if not FileAccess.file_exists("res://multi_a.gd") or not FileAccess.file_exists("res://multi_b.gd"): return "Multi-call did not execute both tools."
	var multi_results: Array = dock.turn_messages.slice(-2)
	if multi_results.size() != 2 or multi_results[0].get("tool_call_id") != "multi-a" or multi_results[1].get("tool_call_id") != "multi-b": return "Multi-call results were not matched in order."
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _reply({"role": "assistant", "content": "Multi completed"}))
	if not _idle(dock) or dock.conversation.back().get("content") != "Multi completed": return "Multi-call final answer failed."
	# Hermes-style text tool calls are parsed only when the whole response is markup.
	_begin(dock)
	var text_call := "<tool_call>\n<function=create_gdscript>\n<parameter=path>\nres://text_call.gd\n</parameter>\n<parameter=source>\nextends Node\n</parameter>\n<parameter=reason>\ntext call fixture\n</parameter>\n</function>\n</tool_call>"
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _reply({"role": "assistant", "content": text_call}))
	if not FileAccess.file_exists("res://text_call.gd"): return "Hermes-style text tool call was not executed."
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _reply({"role": "assistant", "content": "Text call completed"}))
	if not _idle(dock) or dock.conversation.back().get("content") != "Text call completed": return "Text tool-call continuation failed."
	_begin(dock)
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _reply({"role": "assistant", "content": "<tool_call>not a valid call</tool_call>"}))
	if FileAccess.file_exists("res://text_invalid.gd") or not _idle(dock): return "Malformed text tool call was executed or locked controls."
	# Successful mutation remains visible and in context after a continuation error.
	_begin(dock)
	await _tool(dock, [_call("create", "res://completed.gd")])
	if not FileAccess.file_exists("res://completed.gd") or not dock.history_text().contains("res://completed.gd"): return "Completed tool effect was not visible."
	if dock.conversation.back().get("tool_call_id") != "create": return "Completed effect was not retained in context."
	await dock._request_completed(HTTPRequest.RESULT_SUCCESS, 503, PackedStringArray(), PackedByteArray())
	if not _idle(dock) or not dock.history_text().contains("res://completed.gd"): return "Continuation failure hid completed work or locked controls."
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
	if not _idle(dock) or not dock.history_text().contains("res://start_error.gd"): return "Failed continuation start lost completed work."
	dock.submit_error = OK
	if not await _recover(dock): return "Immediate continuation failure prevented recovery."
	# New chat clears model context and the dock history; the queue retains the results.
	_begin(dock, "x".repeat(20000))
	if not _idle(dock): return "Context overflow locked controls."
	var retained_tool_log: String = dock.history_text()
	dock.new_chat_button.pressed.emit()
	if not dock.conversation.is_empty() or not dock.history_text().is_empty() or retained_tool_log.is_empty(): return "New chat did not clear context and history."
	if not await _recover(dock): return "New conversation did not recover from a full context."
	dock.queue_free()
	await plugin.get_tree().process_frame
	print("Offline chat protocol and continuation recovery passed (fake HTTP boundary, real temporary script creation).")
	return ""
