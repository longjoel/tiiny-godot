@tool
extends EditorPlugin

## Editor fixture for story 18: the injected workspace provider, dirty-scene
## safeguards, reload/scan bridge, tool-mode filtering in the dock, and
## file-change action cards. Run through check_workspace_tools.py.

var failures := 0

class ArtifactJobsFixture extends Node:
	var records := {}
	func get_job_status(id: String) -> Dictionary:
		return records.get(id, {})

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	failures += 1
	get_tree().quit(1)

func _wait_for_scene(path: String) -> bool:
	for index in range(300):
		var root := EditorInterface.get_edited_scene_root()
		if root != null and root.scene_file_path == path:
			return true
		await get_tree().process_frame
	return false

func _approval_signal(dock: Object) -> Variant:
	_emit_approval.call_deferred(dock)
	return await dock.approval_closed

func _emit_approval(dock: Object) -> void:
	dock.approval_closed.emit(true)

func _run() -> void:
	for index in range(30):
		await get_tree().process_frame
	var dock := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if dock == null:
		_fail("Tiiny dock is missing")
		return
	if not dock.has_method("_workspace_bridge"):
		_fail("The workspace editor bridge is missing")
		return
	var provider_script: Script = dock.get("workspace_coding_script")
	if provider_script == null:
		_fail("The workspace coding script was not injected into the dock")
		return
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting("tiiny_ai/advanced/tool_mode") or not settings.has_setting("tiiny_ai/advanced/allow_shell_commands"):
		_fail("Workspace tool settings are not registered")
		return
	if bool(settings.get_setting("tiiny_ai/advanced/allow_shell_commands")):
		_fail("Host command execution must default to disabled")
		return

	dock.call("_refresh_registry_availability")
	var provider: Object = dock.get("workspace_coding")
	if provider == null:
		_fail("The dock did not instantiate the workspace provider")
		return
	var script_file := FileAccess.open("res://buffer_guard.gd", FileAccess.WRITE)
	script_file.store_string("extends Node\n")
	script_file.close()
	var guarded_script := load("res://buffer_guard.gd") as Script
	EditorInterface.edit_script(guarded_script)
	for index in range(5):
		await get_tree().process_frame
	var script_editor := EditorInterface.get_script_editor()
	var base := script_editor.get_current_editor().get_base_editor() as CodeEdit
	base.insert_text_at_caret("# unsaved\n")
	for index in range(5):
		await get_tree().process_frame
	if not "res://buffer_guard.gd" in script_editor.get_unsaved_files():
		_fail("The fixture did not create a dirty script buffer")
		return
	var script_hash := FileAccess.get_sha256("res://buffer_guard.gd")
	for request in [
		["write_file", {"path": "res://buffer_guard.gd", "content": "extends Node\n# replacement\n", "expected_sha256": script_hash}],
		["apply_patch", {"path": "res://buffer_guard.gd", "patch": "<<<<<<<\nextends Node\n=======\nextends Node\n# replacement\n>>>>>>>\n", "expected_sha256": script_hash}],
		["move_file", {"source": "res://buffer_guard.gd", "target": "res://buffer_moved.gd", "expected_sha256": script_hash}],
		["delete_file", {"path": "res://buffer_guard.gd", "expected_sha256": script_hash}],
	]:
		var rejected: Dictionary = await provider.execute(request[0], request[1])
		if str(rejected.get("error", {}).get("code", "")) != "script_dirty":
			_fail("Dirty script buffer was not protected: " + str(rejected))
			return
	if FileAccess.get_sha256("res://buffer_guard.gd") != script_hash or not base.text.contains("# unsaved"):
		_fail("Dirty script protection changed disk or buffer contents")
		return
	var registry: Object = dock.get("workspace_registry")
	if registry == null:
		_fail("The dock did not instantiate the registry")
		return
	# The approval result must come from the signal argument. A lambda that
	# assigns to a captured local only changes its by-value copy, so the dialog
	# would always report Cancel.
	var approval_result: Variant = await _approval_signal(dock)
	if not bool(approval_result):
		_fail("The approval signal did not return the confirmed value")
		return
	var settings_read: Dictionary = await registry.execute("get_project_settings", {})
	if not settings_read.get("ok", false) or not settings_read.get("data", {}).get("settings", {}).has("display/window/size/viewport_width"):
		_fail("Project settings were not readable: " + str(settings_read))
		return
	var original_width := int(settings_read.data.settings.get("display/window/size/viewport_width", 0))
	var settings_write: Dictionary = await registry.execute("set_project_setting", {"name": "display/window/size/viewport_width", "value": original_width + 16})
	if not settings_write.get("ok", false) or int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)) != original_width + 16:
		_fail("Project setting was not applied: " + str(settings_write))
		return
	var settings_restore: Dictionary = await registry.execute("set_project_setting", {"name": "display/window/size/viewport_width", "value": original_width})
	if not settings_restore.get("ok", false):
		_fail("Project setting was not restored: " + str(settings_restore))
		return
	var settings_reject: Dictionary = await registry.execute("set_project_setting", {"name": "application/config/name", "value": 5})
	if settings_reject.get("ok", false):
		_fail("Project setting accepted a wrong value type")
		return
	var png := Image.create(2, 3, false, Image.FORMAT_RGBA8)
	png.fill(Color.RED)
	if png.save_png("res://reference.png") != OK:
		_fail("Could not create reference image fixture"); return
	var valid_reference: Dictionary = dock.call("_validated_reference_image", "res://reference.png")
	if valid_reference.has("error") or int(valid_reference.get("width", 0)) != 2 or int(valid_reference.get("height", 0)) != 3 or str(valid_reference.get("sha256", "")) != FileAccess.get_sha256("res://reference.png"):
		_fail("Valid reference image was not validated: " + str(valid_reference)); return
	var bogus := FileAccess.open("res://invalid.png", FileAccess.WRITE)
	bogus.store_string("not a PNG\n".repeat(10))
	bogus.close()
	for bad_path in ["res://invalid.png", "res://../reference.png", "res://.godot/secret.png", "/tmp/reference.png", "res://missing.png"]:
		var bad_reference: Dictionary = dock.call("_validated_reference_image", bad_path)
		if not bad_reference.has("error"):
			_fail("Invalid reference image was accepted: " + bad_path); return
	dock.asset_job_parameters = {"kind": "image_to_3d", "image_path": "res://invalid.png", "stage": "shape"}
	dock.asset_phase = ""
	dock.call("_start_asset_submit")
	if dock.asset_phase != "error" or dock.asset_request != null:
		_fail("Invalid reference reached the asset HTTP request"); return
	dock.asset_job_parameters = {}
	dock.asset_phase = ""
	var oversized_header := FileAccess.get_file_as_bytes("res://reference.png")
	oversized_header[16] = 0
	oversized_header[17] = 0
	oversized_header[18] = 0x20
	oversized_header[19] = 0
	var oversized := FileAccess.open("res://oversized.png", FileAccess.WRITE)
	oversized.store_buffer(oversized_header)
	oversized.close()
	if not Dictionary(dock.call("_validated_reference_image", "res://oversized.png")).has("error"):
		_fail("Oversized PNG dimensions were accepted"); return
	var project_dir := DirAccess.open("res://")
	if project_dir.create_link(ProjectSettings.globalize_path("res://reference.png"), ProjectSettings.globalize_path("res://reference_link.png")) == OK:
		if not Dictionary(dock.call("_validated_reference_image", "res://reference_link.png")).has("error"):
			_fail("Symlinked reference image was accepted"); return
	# Exercise the queued image response without a Tiiny device.
	dock.asset_job_id = "fixture-image-job"
	dock.asset_job_parameters = {"kind": "image"}
	dock.asset_job_started = false
	dock.asset_job_cancel = false
	var png_body := JSON.stringify({"data": [{"b64_json": Marshalls.raw_to_base64(FileAccess.get_file_as_bytes("res://reference.png"))}]}).to_utf8_buffer()
	var fake_request := HTTPRequest.new()
	dock.add_child(fake_request)
	dock.asset_request = fake_request
	dock.call("_on_asset_response", HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), png_body, fake_request, "submit_image")
	var produced_path := str(dock.asset_artifact_path)
	if dock.asset_phase != "import" or produced_path.is_empty() or not FileAccess.file_exists(produced_path):
		_fail("Image job did not save a validated PNG"); return
	var image_deadline := Time.get_ticks_msec() + 15000
	while not dock.call("_asset_import_ready") and Time.get_ticks_msec() < image_deadline:
		await get_tree().create_timer(0.05).timeout
	if not dock.call("_asset_import_ready"):
		_fail("Image job artifact did not import as a Texture2D"); return
	var finish: Dictionary = dock.call("_finish_asset_job", "completed", "")
	var produced: Dictionary = finish.get("result", {})
	if str(produced.get("artifact_id", "")) != "fixture-image-job:image" or str(produced.get("artifact_sha256", "")) != FileAccess.get_sha256(produced_path):
		_fail("Image job did not report its artifact identity and hash: " + str(produced)); return
	var jobs := get_tree().get_first_node_in_group("tiiny_job_manager")
	if jobs == null or not str(jobs.call("_validate", "asset_generate", {"kind": "image", "model": "fixture", "connection_hash": "a".repeat(64), "timeout_ms": 60000, "text": "fixture image"})).is_empty():
		_fail("Jobs rejected a valid queued image-generation request"); return
	var parameters := {"kind": "image_to_3d", "model": "fixture", "connection_hash": "a".repeat(64), "timeout_ms": 60000, "image_artifact_id": "producer:image", "stage": "shape"}
	if not str(jobs.call("_validate", "asset_generate", parameters)).is_empty():
		_fail("Jobs rejected a valid image artifact reference"); return
	if not jobs.queue.set_paused(true):
		_fail("Could not pause the fixture queue"); return
	var submitted_image: Dictionary = jobs.append_job("fixture-producer", "asset_generate", {"kind": "image", "model": "fixture", "connection_hash": "a".repeat(64), "timeout_ms": 60000, "text": "fixture image"})
	if not submitted_image.has("id"):
		_fail("Could not enqueue image producer: " + str(submitted_image)); return
	var downstream_parameters := parameters.duplicate(true)
	downstream_parameters.image_artifact_id = str(submitted_image.id) + ":image"
	var submitted_3d: Dictionary = jobs.append_job("fixture-consumer", "asset_generate", downstream_parameters)
	if not submitted_3d.has("id") or int(submitted_3d.sequence) <= int(submitted_image.sequence):
		_fail("Could not append FIFO 3D consumer: " + str(submitted_3d)); return
	downstream_parameters.image_artifact_id = "missing-producer:image"
	if not jobs.append_job("fixture-missing", "asset_generate", downstream_parameters).has("error"):
		_fail("Jobs accepted an image reference to a missing producer"); return
	var fake_jobs := ArtifactJobsFixture.new()
	add_child(fake_jobs)
	var old_jobs: Node = dock.jobs_service
	dock.jobs_service = fake_jobs
	fake_jobs.records = {
		"producer": {"operation": "asset_generate", "parameters": {"kind": "image"}, "state": "completed", "sequence": 1, "result": {"artifact": produced_path, "artifact_id": "producer:image", "artifact_sha256": FileAccess.get_sha256(produced_path)}},
		"consumer": {"sequence": 2},
	}
	var resolved_artifact: Dictionary = dock.call("_resolve_image_job_artifact", "producer:image", "consumer")
	if resolved_artifact.has("error") or str(resolved_artifact.get("path", "")) != produced_path or str(resolved_artifact.get("sha256", "")) != FileAccess.get_sha256(produced_path):
		_fail("Completed prior image artifact was not resolved: " + str(resolved_artifact)); return
	var original_png := FileAccess.get_file_as_bytes(produced_path)
	var changed_png := Image.create(2, 3, false, Image.FORMAT_RGBA8)
	changed_png.fill(Color.BLUE)
	if changed_png.save_png(produced_path) != OK or not Dictionary(dock.call("_resolve_image_job_artifact", "producer:image", "consumer")).has("error"):
		_fail("Changed image artifact content was accepted"); return
	var restore_png := FileAccess.open(produced_path, FileAccess.WRITE)
	restore_png.store_buffer(original_png)
	restore_png.close()
	fake_jobs.records.producer.result.artifact_sha256 = "0".repeat(64)
	if not Dictionary(dock.call("_resolve_image_job_artifact", "producer:image", "consumer")).has("error"):
		_fail("Changed image artifact hash was accepted"); return
	dock.asset_job_parameters = {"kind": "image_to_3d", "image_artifact_id": "producer:image", "stage": "shape"}
	dock.asset_job_id = "consumer"
	dock.asset_phase = ""
	dock.call("_start_asset_submit")
	if dock.asset_phase != "error" or dock.asset_request != null or not FileAccess.file_exists(produced_path):
		_fail("Invalid producer artifact reached HTTP or removed the intermediate"); return
	dock.asset_job_id = ""
	dock.asset_job_parameters = {}
	dock.asset_phase = ""
	fake_jobs.records.producer.result.artifact_sha256 = FileAccess.get_sha256(produced_path)
	fake_jobs.records.producer.state = "skipped"
	if not Dictionary(dock.call("_resolve_image_job_artifact", "producer:image", "consumer")).has("error"):
		_fail("Skipped image producer was accepted"); return
	fake_jobs.records.producer.state = "completed"
	fake_jobs.records.consumer.sequence = 1
	if not Dictionary(dock.call("_resolve_image_job_artifact", "producer:image", "consumer")).has("error"):
		_fail("Image producer was accepted without FIFO ordering"); return
	dock.jobs_service = old_jobs
	fake_jobs.queue_free()
	var original_approve: Callable = provider.approve_edit
	provider.approve_edit = func(_action: String, _path: String, _reason: String) -> bool: return false
	var denied_create: Dictionary = await dock._registry_create_gdscript({"path": "res://legacy_create.gd", "source": "extends Node\n", "reason": "fixture"}, {})
	if str(denied_create.get("error", {}).get("code", "")) != "approval_required" or FileAccess.file_exists("res://legacy_create.gd"):
		_fail("Legacy script creation did not respect denied approval: " + str(denied_create))
		return
	provider.approve_edit = func(_action: String, _path: String, _reason: String) -> bool: return true
	var approved_create: Dictionary = await dock._registry_create_gdscript({"path": "res://legacy_create.gd", "source": "extends Node\n", "reason": "fixture"}, {})
	if not bool(approved_create.get("ok", false)) or FileAccess.get_file_as_string("res://legacy_create.gd") != "extends Node\n":
		_fail("Approved legacy script creation failed: " + str(approved_create))
		return
	var repeat_create: Dictionary = await dock._registry_create_gdscript({"path": "res://legacy_create.gd", "source": "extends Resource\n", "reason": "fixture"}, {})
	if str(repeat_create.get("error", {}).get("code", "")) != "file_exists" or FileAccess.get_file_as_string("res://legacy_create.gd") != "extends Node\n":
		_fail("Legacy script creation overwrote an existing file")
		return
	provider.approve_edit = original_approve

	var compile_ok: Dictionary = await registry.execute("check_gdscript", {"source": "extends CharacterBody2D\n\nfunc _ready() -> void:\n\tpass\n", "target_class": "CharacterBody2D"})
	if not compile_ok.get("ok", false) or str(compile_ok.get("data", {}).get("base_class", "")) != "CharacterBody2D":
		_fail("check_gdscript did not compile a valid script: " + str(compile_ok)); return
	var compile_side_effect := "user://check_gdscript_tool_static.txt"
	if FileAccess.file_exists(compile_side_effect):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(compile_side_effect))
	var tool_static: Dictionary = await registry.execute("check_gdscript", {"source": "@tool\nextends Node\n\nstatic func _static_init() -> void:\n\tFileAccess.open(\"user://check_gdscript_tool_static.txt\", FileAccess.WRITE).store_string(\"ran\")\n"})
	if not bool(tool_static.get("ok", false)) or not bool(tool_static.get("data", {}).get("tool_annotation_removed", false)) or FileAccess.file_exists(compile_side_effect):
		_fail("check_gdscript ran a @tool static initializer: " + str(tool_static)); return
	var docs_member: Dictionary = await registry.execute("lookup_docs", {"class_name": "CharacterBody2D", "member": "move_and_slide"})
	if not bool(docs_member.get("ok", false)) or not str(docs_member.get("data", {}).get("detail", "")).contains("CharacterBody2D.move_and_slide") or str(docs_member.get("data", {}).get("documentation", "")).is_empty():
		_fail("lookup_docs did not return method documentation: " + str(docs_member)); return
	var docs_class: Dictionary = await registry.execute("lookup_docs", {"class_name": "CharacterBody2D"})
	var docs_members: Array = docs_class.get("data", {}).get("members", [])
	if not bool(docs_class.get("ok", false)) or str(docs_class.get("data", {}).get("detail", "")).is_empty() or not docs_members.any(func(member): return str(member.get("name", "")) == "move_and_slide"):
		_fail("lookup_docs did not return a class summary: " + str(docs_class)); return
	var docs_search: Dictionary = await registry.execute("lookup_docs", {"query": "body2d"})
	if not bool(docs_search.get("ok", false)) or not Array(docs_search.get("data", {}).get("matches", [])).has("CharacterBody2D"):
		_fail("lookup_docs class search did not find CharacterBody2D: " + str(docs_search)); return
	var docs_partial: Dictionary = await registry.execute("lookup_docs", {"class_name": "CharacterBody2D", "member": "move"})
	if not bool(docs_partial.get("ok", false)) or Array(docs_partial.get("data", {}).get("matches", [])).is_empty():
		_fail("lookup_docs member search returned no matches: " + str(docs_partial)); return
	var docs_missing: Dictionary = await registry.execute("lookup_docs", {"class_name": "CharacterBody2D", "member": "definitely_not_a_member"})
	if str(docs_missing.get("error", {}).get("code", "")) != "not_found":
		_fail("lookup_docs accepted an unknown member: " + str(docs_missing)); return
	var docs_invalid: Dictionary = await registry.execute("lookup_docs", {})
	if str(docs_invalid.get("error", {}).get("code", "")) != "invalid_arguments":
		_fail("lookup_docs accepted an empty request: " + str(docs_invalid)); return
	# verify_scene_runtime reports data.scene as a path string. Auto-save and
	# action cards must not treat that string as a scene dictionary.
	EditorInterface.get_editor_settings().set_setting("tiiny_ai/advanced/auto_save_scene", true)
	dock.call("_auto_save_after_edit", {"ok": true, "data": {"scene": "res://main.tscn"}})
	var asset_context := str(dock.call("_editor_context"))
	if not asset_context.contains("Assets:"):
		_fail("Editor context did not summarize existing assets: " + asset_context); return
	var attachment_image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	attachment_image.fill(Color(0.2, 0.5, 0.9, 1.0))
	var attachment: Dictionary = dock.call("_store_attachment", attachment_image, "fixture", "fixture.png")
	if attachment.is_empty() or not str(attachment.get("path", "")).begins_with("user://") or int(attachment.get("width", 0)) != 4 or int(attachment.get("height", 0)) != 4:
		_fail("Attachment storage did not produce a bounded user:// PNG: " + str(attachment)); return
	var text_content: Variant = dock.call("_attachment_content", "plain text", [])
	if not text_content is String or str(text_content) != "plain text":
		_fail("Plain text content changed when no image was attached"); return
	var image_content: Variant = dock.call("_attachment_content", "What is this?", [attachment])
	if not image_content is Array or Array(image_content).size() != 2:
		_fail("Attachment content did not build text and image parts: " + str(image_content)); return
	var materialized: Array = dock.call("_materialize_messages", [{"role": "user", "content": image_content}])
	if not JSON.stringify(materialized).contains("data:image/png;base64,"):
		_fail("Materialized message did not contain an image data URI"); return
	var sanitized: Array = dock.call("_sanitize_visual_messages", materialized)
	var sanitized_json := JSON.stringify(sanitized)
	if sanitized_json.contains("data:image") or not sanitized_json.contains('"type":"image"'):
		_fail("Trace sanitizer did not redact image bytes: " + sanitized_json); return
	EditorInterface.get_editor_settings().set_setting("tiiny_ai/models/context_tokens", 8192)
	var budget_payload := {"messages": [{"role": "user", "content": [{"type": "text", "text": "x".repeat(4000)}, {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA=="}}]}]}
	if bool(dock.call("_check_context_budget", budget_payload)):
		_fail("Image content was not counted by the context budget"); return
	EditorInterface.get_editor_settings().set_setting("tiiny_ai/models/context_tokens", 65536)
	if bool(dock.call("_thinking_enabled")):
		_fail("Model thinking should default off"); return
	if not bool(EditorInterface.get_editor_settings().get_setting("tiiny_ai/advanced/unload_idle_models")):
		_fail("Idle-model unloading should default on"); return
	var long_messages: Array[Dictionary] = []
	for index in range(80):
		long_messages.append({"role": "user", "content": "u".repeat(1000)})
		long_messages.append({"role": "assistant", "content": "a".repeat(1000)})
	var trimmed_history: Array = dock.call("_trim_conversation", long_messages)
	if trimmed_history.size() >= long_messages.size() or str(trimmed_history[0].get("role", "")) != "user" or not str(trimmed_history[0].get("content", "")).contains("trimmed"):
		_fail("History trimming did not keep a bounded user-led history: " + str(trimmed_history.size())); return
	var task_chat = load("res://fake_chat.gd").new()
	add_child(task_chat)
	await get_tree().process_frame
	task_chat.workspace_inspector_script = dock.get("workspace_inspector_script")
	task_chat.workspace_transactions_script = dock.get("workspace_transactions_script")
	task_chat.workspace_registry_script = dock.get("workspace_registry_script")
	task_chat.workspace_coding_script = dock.get("workspace_coding_script")
	task_chat._ensure_workspace_registry()
	task_chat.workspace_registry.set_tool_mode("workspace")
	task_chat.turn_id = "task-read"
	task_chat.turn_role = "task"
	task_chat.turn_system = "task system"
	task_chat.turn_messages.clear()
	task_chat.turn_ledger.clear()
	task_chat.turn_failed_calls.clear()
	task_chat.turn_signature_counts.clear()
	task_chat.turn_last_signature = ""
	await task_chat._execute_turn_calls([{"id": "task-read-1", "name": "list_files", "arguments": {"path": "res://"}}])
	await task_chat._execute_turn_calls([{"id": "task-read-2", "name": "list_files", "arguments": {"path": "res://"}}])
	var repeated_task: Variant = JSON.parse_string(str(task_chat.turn_messages.back().get("content", "")))
	if not repeated_task is Dictionary or str(repeated_task.get("error", {}).get("code", "")) != "repeated_call" or not str(repeated_task.get("summary", "")).contains("submit_result"):
		_fail("Repeated read-only task call did not force a submit_result nudge: " + str(repeated_task)); return
	task_chat.queue_free()
	var edited_task = load("res://fake_chat.gd").new()
	add_child(edited_task)
	await get_tree().process_frame
	edited_task.workspace_inspector_script = dock.get("workspace_inspector_script")
	edited_task.workspace_transactions_script = dock.get("workspace_transactions_script")
	edited_task.workspace_registry_script = dock.get("workspace_registry_script")
	edited_task.workspace_coding_script = dock.get("workspace_coding_script")
	edited_task._ensure_workspace_registry()
	edited_task.workspace_registry.set_tool_mode("workspace")
	edited_task.turn_id = "task-edited-read"
	edited_task.turn_role = "task"
	edited_task.turn_system = "task system"
	edited_task.turn_messages.clear()
	edited_task.turn_ledger.clear()
	edited_task.turn_ledger.append({"affected": ["res://run-and-jump.tscn"], "undo_group": ""})
	edited_task.turn_failed_calls.clear()
	edited_task.turn_signature_counts.clear()
	edited_task.turn_last_signature = ""
	await edited_task._execute_turn_calls([{"id": "edited-read-1", "name": "list_files", "arguments": {"path": "res://"}}])
	# A real edit result resets the consecutive-call marker. Clear it here so the
	# second read exercises only the task read-only guard's edit exemption.
	edited_task.turn_last_signature = ""
	await edited_task._execute_turn_calls([{"id": "edited-read-2", "name": "list_files", "arguments": {"path": "res://"}}])
	var post_edit_read: Variant = JSON.parse_string(str(edited_task.turn_messages.back().get("content", "")))
	if not post_edit_read is Dictionary or not bool(post_edit_read.get("ok", false)) or str(post_edit_read.get("error", {}).get("code", "")) == "repeated_call":
		_fail("Post-edit re-read was blocked by the task read-only guard: " + str(post_edit_read)); return
	edited_task.queue_free()
	var chat = load("res://fake_chat.gd").new()
	add_child(chat)
	await get_tree().process_frame
	chat.workspace_inspector_script = dock.get("workspace_inspector_script")
	chat.workspace_transactions_script = dock.get("workspace_transactions_script")
	chat.workspace_registry_script = dock.get("workspace_registry_script")
	chat.workspace_coding_script = dock.get("workspace_coding_script")
	chat.pending_prompt = "What is this?"
	chat.pending_model = "fixture-model"
	chat.pending_attachments = [attachment]
	chat._start_answer()
	if chat.submissions.is_empty():
		_fail("Attachment chat did not submit a payload"); return
	var sent: Dictionary = chat.submissions.back()
	var user_message: Dictionary = sent.messages[1] if sent.messages.size() > 1 else {}
	if not user_message.get("content") is Array or not JSON.stringify(user_message.content).contains("data:image/png;base64,"):
		_fail("Attachment chat payload did not contain an image content part: " + str(user_message)); return
	chat.queue_free()
	var scene_capture: Dictionary = await provider.execute("capture_scene_view", {"view": "2d"})
	if not bool(scene_capture.get("ok", false)) and str(scene_capture.get("error", {}).get("code", "")) != "capture_failed":
		_fail("capture_scene_view did not report a clear headless result: " + str(scene_capture)); return
	var player_capture: Dictionary = await provider.execute("capture_player_view", {})
	if str(player_capture.get("error", {}).get("code", "")) != "unavailable":
		_fail("capture_player_view did not report that the player window is unavailable: " + str(player_capture)); return
	settings.set_setting("tiiny_ai/models/coding_model_type", "Image-Text-to-Text")
	settings.set_setting("tiiny_ai/models/coding_model_vision", true)
	dock.call("_refresh_registry_availability")
	var vision_tools: Array = Array(registry.tools_payload()).map(func(tool): return str(tool.function.name))
	if not ("capture_scene_view" in vision_tools and "capture_player_view" in vision_tools and "classify_visual" in vision_tools):
		_fail("Vision-capable tool payload omitted a visual tool: " + str(vision_tools)); return
	var vision_image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	vision_image.fill(Color(0.1, 0.6, 0.9, 1.0))
	if vision_image.save_png("res://vision_fixture.png") != OK:
		_fail("Could not create the vision fixture image"); return
	var prepared: Dictionary = await dock.call("_prepare_vision_image", {"source": "texture", "path": "res://vision_fixture.png"})
	if not str(prepared.get("path", "")).begins_with("user://") or str(prepared.get("sha256", "")).length() != 64:
		_fail("Vision image preparation did not produce a bounded user:// PNG: " + str(prepared)); return
	dock.call("_vision_cache_put", str(prepared.sha256), "classify this", "fixture-model", {"description": "a blue square", "labels": ["blue", "square"]})
	var cached: Dictionary = dock.call("_vision_cache_get", str(prepared.sha256), "classify this", "fixture-model")
	if str(cached.get("description", "")) != "a blue square" or not Array(cached.get("labels", [])).has("blue"):
		_fail("Vision cache did not return the stored classification: " + str(cached)); return
	var cache_miss: Dictionary = dock.call("_vision_cache_get", str(prepared.sha256), "different prompt", "fixture-model")
	if not cache_miss.is_empty():
		_fail("Vision cache ignored the prompt version: " + str(cache_miss)); return
	var cache_chat = load("res://fake_chat.gd").new()
	add_child(cache_chat)
	await get_tree().process_frame
	cache_chat.queued_chat_parameters = {"model": "fixture-model", "connection_hash": "a".repeat(64), "timeout_ms": 120000}
	var cache_call := {"id": "vision-cache", "name": "classify_visual", "arguments": {"source": "texture", "path": str(prepared.path), "prompt": "classify this"}}
	var cache_job: Dictionary = await cache_chat.call("_prepare_vision_tool_job", cache_call, [])
	if not bool(cache_job.get("result", {}).get("data", {}).get("cached", false)):
		_fail("Cached visual classification did not skip the queued job: " + str(cache_job)); return
	cache_chat.queue_free()
	var successor_chat = load("res://fake_chat.gd").new()
	add_child(successor_chat)
	await get_tree().process_frame
	var handoff := {
		"chat": {
			"turn": {"id": "turn-vision", "messages": [], "failed": {}, "ledger": [], "calls": ["vision-call"], "count": 1},
			"conversation": [],
		},
		"call": {"id": "vision-call", "name": "classify_visual", "arguments": {"source": "texture", "path": "res://vision_fixture.png"}},
		"remaining": [],
	}
	var successor: Variant = successor_chat.call("prepare_vision_tool_successor", {"parameters": {"kind": "vision", "chat_handoff": handoff}}, {"ok": true, "description": "a blue player", "labels": ["player"]})
	if not successor is Dictionary or not JSON.stringify(successor.get("turn", {}).get("messages", [])).contains("a blue player") or Array(successor.get("turn", {}).get("ledger", [])).size() != 1:
		_fail("Visual classification successor did not append a tool result and ledger entry: " + str(successor)); return
	successor_chat.asset_job_parameters = {"kind": "vision", "image_sha256": str(prepared.sha256), "text": "classify this", "source": "texture", "path": "res://vision_fixture.png", "model": "fixture-model"}
	successor_chat.vision_phase = "done"
	successor_chat.vision_description = "a blue square"
	successor_chat.vision_labels = ["blue"]
	var finished: Dictionary = successor_chat.call("_finish_asset_job", "completed", "")
	if str(finished.get("state", "")) != "completed" or not bool(finished.get("result", {}).get("ok", false)) or str(finished.get("result", {}).get("description", "")) != "a blue square":
		_fail("Visual classification completion did not return the cached result shape: " + str(finished)); return
	var inner_json := "```json\n" + JSON.stringify({"description": "a player on a platform", "labels": ["player", "platform"]}) + "\n```"
	var response_body := JSON.stringify({"choices": [{"message": {"content": inner_json}}]}).to_utf8_buffer()
	successor_chat.call("_on_vision_completed", HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), response_body)
	if str(successor_chat.vision_phase) != "done" or str(successor_chat.vision_description) != "a player on a platform" or not Array(successor_chat.vision_labels).has("player"):
		_fail("Visual classification response parsing did not extract description and labels: " + str(successor_chat.vision_description)); return
	successor_chat.queue_free()
	var vision_params := {"kind": "vision", "image_path": str(prepared.path), "image_sha256": str(prepared.sha256), "path": "res://vision_fixture.png", "source": "texture", "text": "classify this", "model": "fixture-model", "connection_hash": "a".repeat(64), "timeout_ms": 120000}
	var jobs_service_node: Variant = dock.get("jobs_service")
	if jobs_service_node != null and jobs_service_node.has_method("_validate"):
		var validation := str(jobs_service_node.call("_validate", "asset_generate", vision_params))
		if not validation.is_empty():
			_fail("Vision job validation rejected valid parameters: " + validation); return

	settings.set_setting("tiiny_ai/advanced/tool_mode", "editor")
	dock.call("_refresh_registry_availability")
	var editor_tools: Array = Array(registry.tools_payload()).map(func(tool): return str(tool.function.name))
	if "list_files" in editor_tools or "run_command" in editor_tools:
		_fail("Editor mode advertised workspace coding tools")
		return
	if not dock.call("tool_mode_text").contains("Editor mode"):
		_fail("The dock does not display the editor mode")
		return
	settings.set_setting("tiiny_ai/advanced/tool_mode", "workspace")
	dock.call("_refresh_registry_availability")
	var workspace_tools: Array = Array(registry.tools_payload()).map(func(tool): return str(tool.function.name))
	if not ("list_files" in workspace_tools and "apply_patch" in workspace_tools):
		_fail("Workspace mode did not advertise file tools")
		return
	if "apply_editor_transaction" in workspace_tools or "append_job" in workspace_tools:
		_fail("Workspace mode advertised editor-only tools")
		return
	if "run_command" in workspace_tools or "run_godot_headless" in workspace_tools:
		_fail("execution tools were advertised while host commands are disabled")
		return
	settings.set_setting("tiiny_ai/advanced/allow_shell_commands", true)
	dock.call("_refresh_registry_availability")
	workspace_tools = Array(registry.tools_payload()).map(func(tool): return str(tool.function.name))
	if not ("run_command" in workspace_tools and "run_godot_headless" in workspace_tools):
		_fail("execution tools were not advertised after enabling host commands")
		return
	settings.set_setting("tiiny_ai/advanced/allow_shell_commands", false)
	dock.call("_refresh_registry_availability")
	if not dock.call("tool_mode_text").contains("not scene-undoable"):
		_fail("The dock does not warn that workspace edits are not scene-undoable")
		return
	settings.set_setting("tiiny_ai/advanced/tool_mode", "hybrid")
	dock.call("_refresh_registry_availability")
	var hybrid_tools: Array = Array(registry.tools_payload()).map(func(tool): return str(tool.function.name))
	if not ("list_files" in hybrid_tools and "configure_audio_bus" in hybrid_tools):
		_fail("Hybrid mode did not advertise both tool families")
		return
	settings.set_setting("tiiny_ai/advanced/tool_mode", "editor")

	EditorInterface.open_scene_from_path("res://dirty.tscn")
	if not await _wait_for_scene("res://dirty.tscn"):
		_fail("Dirty fixture scene did not open")
		return
	var root := EditorInterface.get_edited_scene_root()
	var label := root.get_node_or_null("Label") as Label
	if label == null:
		_fail("Dirty fixture label is missing")
		return
	var manager := EditorInterface.get_editor_undo_redo()
	var attach_args := {"path": "res://combined.gd", "source": "extends Node2D\n", "target": ".", "reason": "fixture"}
	provider.approve_edit = func(_action: String, _path: String, _reason: String) -> bool: return false
	var denied_combined: Dictionary = await registry.execute("create_and_attach_gdscript", attach_args, {})
	if str(denied_combined.get("error", {}).get("code", "")) != "approval_required" or FileAccess.file_exists("res://combined.gd") or root.get_script() != null:
		_fail("Denied create-and-attach changed state: " + str(denied_combined)); return
	var incompatible_args := attach_args.duplicate()
	incompatible_args.source = "extends Node3D\n"
	var invalid_combined: Dictionary = await dock._registry_create_and_attach_gdscript(incompatible_args, {})
	if invalid_combined.get("ok", false) or FileAccess.file_exists("res://combined.gd") or root.get_script() != null:
		_fail("Invalid create-and-attach changed state: " + str(invalid_combined)); return
	var invalid_source_args := attach_args.duplicate()
	invalid_source_args.source = "extends Node2D\nfunc broken(:\n"
	var invalid_source: Dictionary = await registry.execute("create_and_attach_gdscript", invalid_source_args, {})
	if invalid_source.get("ok", false) or FileAccess.file_exists("res://combined.gd") or root.get_script() != null:
		_fail("Invalid GDScript created partial state: " + str(invalid_source)); return
	var missing_args := attach_args.duplicate()
	missing_args.target = "MissingNode"
	var missing_target: Dictionary = await registry.execute("create_and_attach_gdscript", missing_args, {})
	if missing_target.get("ok", false) or FileAccess.file_exists("res://combined.gd") or root.get_script() != null:
		_fail("Missing target created partial state: " + str(missing_target)); return
	var foreign_args := attach_args.duplicate()
	foreign_args.path = "res://foreign.cs"
	var foreign_script: Dictionary = await registry.execute("create_and_attach_gdscript", foreign_args, {})
	if foreign_script.get("ok", false) or FileAccess.file_exists("res://foreign.cs") or root.get_script() != null:
		_fail("Non-GDScript path created partial state: " + str(foreign_script)); return
	var stale_context: Dictionary = await registry.execute("create_and_attach_gdscript", attach_args, {"revision": "sha256:stale"})
	if str(stale_context.get("error", {}).get("code", "")) != "stale_scene" or FileAccess.file_exists("res://combined.gd") or root.get_script() != null:
		_fail("Stale create-and-attach context changed state: " + str(stale_context)); return
	var existing_args := attach_args.duplicate()
	existing_args.path = "res://legacy_create.gd"
	var existing_script: Dictionary = await registry.execute("create_and_attach_gdscript", existing_args, {})
	if existing_script.get("ok", false) or FileAccess.get_file_as_string("res://legacy_create.gd") != "extends Node\n" or root.get_script() != null:
		_fail("Existing script was overwritten or attached: " + str(existing_script)); return
	var attach_existing: Dictionary = await registry.execute("attach_script", {"target": ".", "path": "res://legacy_create.gd"}, {})
	if not attach_existing.get("ok", false) or root.get_script() == null or str(root.get_script().resource_path) != "res://legacy_create.gd":
		_fail("attach_script did not attach the existing file: " + str(attach_existing)); return
	var attach_history = manager.get_history_undo_redo(manager.get_object_history_id(root))
	if not attach_history.undo() or root.get_script() != null:
		_fail("attach_script undo failed"); return
	var matching_args := {"path": "res://legacy_create.gd", "source": "extends Node\n", "target": ".", "reason": "fixture"}
	var matching: Dictionary = await registry.execute("create_and_attach_gdscript", matching_args, {})
	if not matching.get("ok", false) or root.get_script() == null or bool(matching.get("data", {}).get("file_created", true)):
		_fail("Matching existing script was not attached: " + str(matching)); return
	if not attach_history.undo() or root.get_script() != null:
		_fail("Matching attach undo failed"); return
	provider.approve_edit = func(_action: String, _path: String, _reason: String) -> bool:
		manager.create_action("fixture change during approval", UndoRedo.MERGE_DISABLE, root)
		manager.add_do_property(label, "text", "changed during approval")
		manager.add_undo_property(label, "text", label.text)
		manager.commit_action()
		return true
	var stale_combined: Dictionary = await registry.execute("create_and_attach_gdscript", attach_args, {})
	if stale_combined.get("ok", false) or FileAccess.file_exists("res://combined.gd") or root.get_script() != null or label.text != "changed during approval":
		_fail("Stale create-and-attach did not preserve the intervening scene change: " + str(stale_combined)); return
	var changed_history = manager.get_history_undo_redo(manager.get_object_history_id(root))
	if not changed_history.undo() or label.text != "saved text":
		_fail("Could not restore scene after approval-race fixture"); return
	provider.approve_edit = func(_action: String, _path: String, _reason: String) -> bool: return true
	var combined: Dictionary = await registry.execute("create_and_attach_gdscript", attach_args, {})
	if not combined.get("ok", false) or not FileAccess.file_exists("res://combined.gd") or root.get_script() == null or not bool(combined.get("data", {}).get("scene_attached", false)):
		_fail("Create-and-attach failed: " + str(combined)); return
	var history = manager.get_history_undo_redo(manager.get_object_history_id(root))
	if not history.undo() or root.get_script() != null or not FileAccess.file_exists("res://combined.gd"):
		_fail("Create-and-attach undo did not preserve its separate file effect"); return
	if not history.redo() or root.get_script() == null:
		_fail("Create-and-attach redo failed"); return
	EditorInterface.save_scene()
	EditorInterface.reload_scene_from_path("res://dirty.tscn")
	if not await _wait_for_scene("res://dirty.tscn"):
		_fail("Combined script scene did not reload"); return
	root = EditorInterface.get_edited_scene_root()
	label = root.get_node_or_null("Label") as Label
	if root.get_script() == null or str(root.get_script().resource_path) != "res://combined.gd" or label == null:
		_fail("Combined script attachment did not survive save and reload"); return
	var new_node_args := {"path": "res://combined_child.gd", "source": "extends Node2D\n", "target": ".", "node_class": "Node2D", "node_name": "ScriptedChild", "reason": "fixture"}
	var bad_node_args := new_node_args.duplicate()
	bad_node_args.node_class = "Node3D"
	var bad_node: Dictionary = await registry.execute("create_and_attach_gdscript", bad_node_args, {})
	if bad_node.get("ok", false) or FileAccess.file_exists("res://combined_child.gd") or root.has_node("ScriptedChild"):
		_fail("Invalid new-node script created partial state: " + str(bad_node)); return
	var instanced_args := new_node_args.duplicate()
	instanced_args.target = "Instance/Inner"
	var instance_result: Dictionary = await registry.execute("create_and_attach_gdscript", instanced_args, {})
	if instance_result.get("ok", false) or FileAccess.file_exists("res://combined_child.gd") or root.get_node("Instance/Inner").has_node("ScriptedChild"):
		_fail("Create-and-attach crossed an instanced child boundary: " + str(instance_result)); return
	instanced_args.erase("node_class")
	instanced_args.erase("node_name")
	var instance_attach: Dictionary = await registry.execute("create_and_attach_gdscript", instanced_args, {})
	if instance_attach.get("ok", false) or FileAccess.file_exists("res://combined_child.gd") or root.get_node("Instance/Inner").get_script() != null:
		_fail("Create-and-attach modified an instanced child: " + str(instance_attach)); return
	var new_node: Dictionary = await registry.execute("create_and_attach_gdscript", new_node_args, {})
	var scripted_child := root.get_node_or_null("ScriptedChild")
	if not new_node.get("ok", false) or scripted_child == null or scripted_child.get_script() == null:
		_fail("Create-and-attach new node failed: " + str(new_node)); return
	var child_history = manager.get_history_undo_redo(manager.get_object_history_id(root))
	if not child_history.undo() or root.has_node("ScriptedChild") or not FileAccess.file_exists("res://combined_child.gd"):
		_fail("New scripted node undo did not preserve its file"); return
	if not child_history.redo() or root.get_node_or_null("ScriptedChild") == null or root.get_node("ScriptedChild").get_script() == null:
		_fail("New scripted node redo failed"); return
	EditorInterface.save_scene()
	EditorInterface.reload_scene_from_path("res://dirty.tscn")
	if not await _wait_for_scene("res://dirty.tscn"):
		_fail("New scripted node scene did not reload"); return
	root = EditorInterface.get_edited_scene_root()
	label = root.get_node_or_null("Label") as Label
	scripted_child = root.get_node_or_null("ScriptedChild")
	if scripted_child == null or scripted_child.get_script() == null or str(scripted_child.get_script().resource_path) != "res://combined_child.gd" or label == null:
		_fail("New scripted node did not survive save and reload"); return
	var failure_args := {"path": "res://partial_effect.gd", "source": "extends Node2D\n", "target": ".", "node_class": "Node2D", "node_name": "NotAttached", "reason": "fixture"}
	provider.before_commit = func(_path: String, action: String) -> void:
		if action == "create":
			manager.create_action("fixture change at file commit", UndoRedo.MERGE_DISABLE, root)
			manager.add_do_property(label, "text", "changed at commit")
			manager.add_undo_property(label, "text", label.text)
			manager.commit_action()
	var partial: Dictionary = await registry.execute("create_and_attach_gdscript", failure_args, {})
	provider.before_commit = Callable()
	if partial.get("ok", false) or not bool(partial.get("data", {}).get("file_created", false)) or bool(partial.get("data", {}).get("scene_attached", true)) or not FileAccess.file_exists("res://partial_effect.gd") or root.has_node("NotAttached") or label.text != "changed at commit":
		_fail("Failure after file creation was not reported accurately: " + str(partial)); return
	var partial_history = manager.get_history_undo_redo(manager.get_object_history_id(root))
	if not partial_history.undo() or label.text != "saved text":
		_fail("Could not restore the intervening scene edit"); return
	provider.approve_edit = original_approve
	manager.create_action("workspace-tools-fixture-dirty", UndoRedo.MERGE_DISABLE, root)
	manager.add_do_property(label, "text", "unsaved editor text")
	manager.add_undo_property(label, "text", label.text)
	manager.commit_action()
	if not (root.scene_file_path in EditorInterface.get_unsaved_scenes()):
		_fail("The fixture scene did not become dirty")
		return
	var scene_state: Dictionary = dock.call("_workspace_bridge", "scene_state", {"path": root.scene_file_path})
	if not bool(scene_state.get("dirty", false)) or not bool(scene_state.get("open", false)) or not Array(scene_state.get("unsaved_scenes", [])).has(root.scene_file_path):
		_fail("The editor bridge did not report the dirty scene tab")
		return
	var scene_before := FileAccess.get_file_as_string("res://dirty.tscn")
	var scene_hash := FileAccess.get_sha256("res://dirty.tscn")
	var dirty_write: Dictionary = await provider.execute("write_file", {"path": "res://dirty.tscn", "content": scene_before.replace("DirtyRoot", "ChangedRoot"), "expected_sha256": scene_hash})
	if str(dirty_write.get("error", {}).get("code", "")) != "scene_dirty":
		_fail("A dirty open scene was not protected from a file write: " + str(dirty_write))
		return
	if FileAccess.get_file_as_string("res://dirty.tscn") != scene_before:
		_fail("The dirty scene file changed despite rejection")
		return
	if label.text != "unsaved editor text":
		_fail("Unsaved editor state was lost")
		return
	var dirty_reload: Dictionary = await provider.execute("reload_scene", {"path": "res://dirty.tscn"})
	if str(dirty_reload.get("error", {}).get("code", "")) != "scene_dirty":
		_fail("Reload did not refuse unsaved editor state")
		return
	var dirty_move: Dictionary = await provider.execute("move_file", {"source": "res://dirty.tscn", "target": "res://dirty_moved.tscn", "expected_sha256": scene_hash})
	if str(dirty_move.get("error", {}).get("code", "")) != "scene_dirty":
		_fail("Move did not refuse unsaved editor state")
		return
	var dirty_delete: Dictionary = await provider.execute("delete_file", {"path": "res://dirty.tscn", "expected_sha256": scene_hash})
	if str(dirty_delete.get("error", {}).get("code", "")) != "scene_dirty":
		_fail("Delete did not refuse unsaved editor state")
		return

	# Exercise the real editor bridge while the dirty scene is in a different tab.
	EditorInterface.open_scene_from_path("res://other.tscn")
	if not await _wait_for_scene("res://other.tscn"):
		_fail("Second fixture scene did not open")
		return
	var noncurrent_state: Dictionary = dock.call("_workspace_bridge", "scene_state", {"path": "res://dirty.tscn"})
	if not bool(noncurrent_state.get("dirty", false)) or bool(noncurrent_state.get("current", true)):
		_fail("The bridge did not identify the non-current dirty tab: " + str(noncurrent_state))
		return
	for request in [
		["write_file", {"path": "res://dirty.tscn", "content": scene_before, "expected_sha256": scene_hash}],
		["move_file", {"source": "res://dirty.tscn", "target": "res://dirty_moved.tscn", "expected_sha256": scene_hash}],
		["delete_file", {"path": "res://dirty.tscn", "expected_sha256": scene_hash}],
		["reload_scene", {"path": "res://dirty.tscn"}],
	]:
		var rejected: Dictionary = await provider.execute(request[0], request[1])
		if str(rejected.get("error", {}).get("code", "")) != "scene_dirty":
			_fail("A non-current dirty scene was not protected from %s: %s" % [request[0], str(rejected)])
			return
	provider.approve_discard = func(_path: String) -> bool: return false
	var denied_discard: Dictionary = await provider.execute("reload_scene", {"path": "res://dirty.tscn", "discard_unsaved": true})
	if str(denied_discard.get("error", {}).get("code", "")) != "approval_required" or label.text != "unsaved editor text" or FileAccess.get_file_as_string("res://dirty.tscn") != scene_before:
		_fail("Denied discard did not preserve the non-current dirty scene")
		return
	EditorInterface.open_scene_from_path("res://dirty.tscn")
	if not await _wait_for_scene("res://dirty.tscn") or label.text != "unsaved editor text":
		_fail("The dirty scene did not retain its in-memory changes when reopened")
		return

	var save_result: Dictionary = await dock.call("_registry_save_scene", {}, {})
	if not save_result.get("ok", false):
		_fail("Saving the dirty fixture failed: " + str(save_result))
		return
	if root.scene_file_path in EditorInterface.get_unsaved_scenes():
		_fail("The scene remained dirty after save")
		return
	# The HTTPRequest completion callback is deferred, so a save from that path
	# must not create a foreground progress dialog while the queue is flushing.
	dock.call_deferred("_registry_save_scene", {}, {})
	for index in range(5):
		await get_tree().process_frame
	var saved_text := FileAccess.get_file_as_string("res://dirty.tscn")
	var saved_hash := FileAccess.get_sha256("res://dirty.tscn")
	var renamed := saved_text.replace("DirtyRoot", "ReloadedRoot")
	var write_result: Dictionary = await provider.execute("write_file", {"path": "res://dirty.tscn", "content": renamed, "expected_sha256": saved_hash})
	if not write_result.get("ok", false):
		_fail("Writing a saved scene file failed: " + str(write_result))
		return
	var reload_result: Dictionary = await provider.execute("reload_scene", {"path": "res://dirty.tscn"})
	if not reload_result.get("ok", false):
		_fail("Reloading the edited scene failed: " + str(reload_result))
		return
	for index in range(120):
		await get_tree().process_frame
		if EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().name == "ReloadedRoot":
			break
	root = EditorInterface.get_edited_scene_root()
	if root == null or root.name != "ReloadedRoot":
		_fail("Reload did not replace the edited scene with the file contents")
		return
	label = root.get_node_or_null("Label") as Label
	if label == null:
		_fail("Reloaded fixture label is missing")
		return
	manager.create_action("workspace-tools-fixture-discard", UndoRedo.MERGE_DISABLE, root)
	manager.add_do_property(label, "text", "discard this text")
	manager.add_undo_property(label, "text", label.text)
	manager.commit_action()
	EditorInterface.open_scene_from_path("res://other.tscn")
	if not await _wait_for_scene("res://other.tscn"):
		_fail("Could not switch away for the discard test")
		return
	provider.approve_discard = func(_path: String) -> bool: return true
	var approved_discard: Dictionary = await provider.execute("reload_scene", {"path": "res://dirty.tscn", "discard_unsaved": true})
	if not bool(approved_discard.get("ok", false)):
		_fail("Approved discard of the non-current scene failed: " + str(approved_discard))
		return
	await get_tree().process_frame
	EditorInterface.open_scene_from_path("res://dirty.tscn")
	if not await _wait_for_scene("res://dirty.tscn"):
		_fail("Could not reopen the discarded scene")
		return
	root = EditorInterface.get_edited_scene_root()
	label = root.get_node_or_null("Label") as Label
	if label == null or label.text != "unsaved editor text" or "res://dirty.tscn" in EditorInterface.get_unsaved_scenes():
		_fail("Approved discard did not restore the saved scene contents")
		return

	var scan_fixture := "res://scan_fixture.txt"
	var scan_file := FileAccess.open(scan_fixture, FileAccess.WRITE)
	scan_file.store_string("scan fixture\n")
	scan_file.close()
	var scan_result: Dictionary = provider.execute("scan_filesystem", {})
	if not scan_result.get("ok", false):
		_fail("Filesystem scan through the bridge failed: " + str(scan_result))
		return
	var info: Dictionary = provider.execute("file_info", {"path": scan_fixture})
	if not info.get("ok", false):
		_fail("The scanned fixture file is not readable")
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(scan_fixture))

	var read_result: Dictionary = await provider.execute("read_file", {"path": "res://dirty.tscn"})
	var read_hash := str(read_result.get("data", {}).get("sha256", ""))
	# The card fixture is a deterministic test of the card itself; approval is
	# covered by the pure fixture and the dock dialog, so auto-approve here.
	provider.approve_edit = func(_action: String, _path: String, _reason: String) -> bool: return true
	var card_result: Dictionary = await provider.execute("write_file", {"path": "res://card_fixture.gd", "content": "extends Node\n", "create": true})
	if not card_result.get("ok", false):
		_fail("Card fixture write failed: " + str(card_result))
		return
	dock.call("_append_action_card", card_result, {})
	var found_undo_note := false
	var found_diff_button := false
	for card in dock.get("action_cards"):
		var node: Variant = card.get("card", null)
		if not is_instance_valid(node): continue
		for child in node.find_children("*", "Label", true, false):
			if str(child.text).contains("not scene-undoable"):
				found_undo_note = true
		for child in node.find_children("*", "Button", true, false):
			if str(child.text) == "Review diff":
				found_diff_button = true
	if not found_undo_note or not found_diff_button:
		_fail("A file-change action card did not show the undo warning and diff review")
		return
	if read_hash.is_empty():
		_fail("The workspace read did not return a SHA-256")
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://card_fixture.gd"))

	print("Workspace coding editor integration passed.")
	get_tree().quit(0)
