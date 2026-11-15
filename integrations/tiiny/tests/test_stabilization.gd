@tool
extends RefCounted

func _nodes(node: Node) -> Array[Node]:
	var nodes: Array[Node] = [node]
	for child in node.get_children(true): nodes.append_array(_nodes(child))
	return nodes

func _frames(plugin: EditorPlugin, count := 3) -> void:
	for i in range(count): await plugin.get_tree().process_frame

func _drive_cli(manager: Node, result: Array) -> void:
	result.append(await manager._run_cli(["load", "fixture-model"]))

func _processes(plugin: EditorPlugin, manager: Node) -> String:
	var settings := EditorInterface.get_editor_settings()
	var original: String = settings.get_setting("tiiny_ai/advanced/cli_path")
	settings.set_setting("tiiny_ai/advanced/cli_path", "/does/not/exist/tiiny")
	if await manager._run_cli(["load", "fixture-model"]) == 0: return "Missing SDK returned success."
	var stub := ProjectSettings.globalize_path("res://slow-tiiny")
	var pid_file := ProjectSettings.globalize_path("res://worker.pid")
	var file := FileAccess.open(stub, FileAccess.WRITE)
	file.store_string("#!/bin/sh\nprintf '%s' \"$$\" > " + manager._shell_quote(pid_file) + "\ntrap '' TERM HUP\nwhile :; do sleep 1; done\n")
	file.close()
	OS.execute("chmod", PackedStringArray(["+x", stub]))
	settings.set_setting("tiiny_ai/advanced/cli_path", stub)
	for shutdown in [false, true]:
		if FileAccess.file_exists(pid_file): DirAccess.remove_absolute(pid_file)
		var worker = load("res://manager.gd").new()
		plugin.add_child(worker)
		var result: Array = []
		_drive_cli.call_deferred(worker, result)
		var deadline := Time.get_ticks_msec() + 3000
		while not FileAccess.file_exists(pid_file) and Time.get_ticks_msec() < deadline:
			await plugin.get_tree().create_timer(0.02).timeout
		if not FileAccess.file_exists(pid_file): return "Slow SDK did not start."
		var pid := int(FileAccess.get_file_as_string(pid_file))
		var started := Time.get_ticks_msec()
		if shutdown: plugin.remove_child(worker)
		else: worker.stop_cli()
		while result.is_empty() and Time.get_ticks_msec() - started < 3000:
			await plugin.get_tree().create_timer(0.02).timeout
		if result.is_empty() or result[0] == 0: return "Slow SDK cancellation/shutdown failed to finish."
		if Time.get_ticks_msec() - started > 2000: return "SDK cleanup blocked the editor."
		await plugin.get_tree().create_timer(0.1).timeout
		var stat_path := "/proc/%d/stat" % pid
		if FileAccess.file_exists(stat_path) and not FileAccess.open(stat_path, FileAccess.READ).get_line().contains(") Z "):
			return "SDK child survived cancellation/shutdown."
		worker.queue_free()
	settings.set_setting("tiiny_ai/advanced/cli_path", original)
	print("Missing/slow SDK, cancellation, child cleanup and editor-tree shutdown passed.")
	return ""

func _shapes(dock: Control) -> String:
	for text in ["not JSON", '{"points":[]}', '{"points":[[0,0],[1,1],[2,2]]}', '{"points":[[0,0],[0,0],[0,0]]}', '{"points":[[0,0],[1e999,1],[1,0]]}', '{"points":[[0,0],[100001,1],[1,0]]}', '{"points":[[0,0],[1,"bad"],[1,0]]}']:
		if dock._shape_from_text(text) != null: return "Invalid polygon was accepted."
	var too_many: Array = []
	for i in range(65): too_many.append([i, i * i])
	if dock._shape_from_text(JSON.stringify({"points": too_many})) != null: return "Oversized polygon accepted."
	var shape: ConvexPolygonShape2D = dock._shape_from_text('{"points":[[0,0],[32,0],[32,48],[0,48]]}')
	if shape == null or shape.points.size() != 4: return "Valid polygon failed."
	if ResourceSaver.save(shape, "res://fixture_shape.tres") != OK: return "Polygon save failed."
	var reopened = ResourceLoader.load("res://fixture_shape.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	if not reopened is ConvexPolygonShape2D or reopened.points != shape.points: return "Polygon did not survive reopen."
	print("Polygon validation and save/reopen passed.")
	return ""

func _open_resource(plugin: EditorPlugin) -> Window:
	for node in _nodes(plugin.get_tree().root):
		if node is PopupMenu:
			for i in range(node.item_count):
				if node.get_item_text(i) == "New Resource":
					node.id_pressed.emit(node.get_item_id(i))
					await _frames(plugin)
					for candidate in _nodes(plugin.get_tree().root):
						if candidate is ConfirmationDialog and candidate.visible and candidate.find_child("TypeOptions", true, false) != null: return candidate
	return null

func _select_type(plugin: EditorPlugin, dialog: Window, type: String) -> bool:
	var fields := dialog.find_children("*", "LineEdit", true, false)
	var search: LineEdit = fields[0] if not fields.is_empty() else null
	if search == null: return false
	search.text = type
	search.text_changed.emit(type)
	await _frames(plugin)
	var tree: Tree = dialog.find_child("TypeOptions", true, false)
	if tree == null: return false
	var item := tree.get_root()
	var stack: Array[TreeItem] = []
	if item: stack.append(item)
	while not stack.is_empty():
		item = stack.pop_back()
		if item.get_text(0).get_slice(" ", 0) == type:
			item.select(0)
			tree.item_selected.emit()
			return true
		var child := item.get_first_child()
		while child:
			stack.append(child)
			child = child.get_next()
	return false

func _dialogs(plugin: EditorPlugin, dock: Control) -> String:
	# Drive real native dialog signals; only inference is replaced by callbacks.
	var fake = load("res://fake_resource_responder.gd").new()
	plugin.add_child(fake)
	dock.remove_from_group("tiiny_ai_editor_dock")
	fake.add_to_group("tiiny_ai_editor_dock")
	for type in ["Image", "StandardMaterial3D", "ConvexPolygonShape2D"]:
		var dialog := await _open_resource(plugin)
		if dialog == null or not await _select_type(plugin, dialog, type): return "Resource dialog/type unavailable: " + type
		var prompt: TextEdit = dialog.find_child("TiinyResourcePrompt", true, false)
		if prompt.editable != (type == "ConvexPolygonShape2D"): return "Wrong resource prompt eligibility."
		prompt.text = ""
		dialog.get_ok_button().pressed.emit()
		await _frames(plugin)
		var resource = EditorInterface.get_inspector().get_edited_object()
		if resource == null or resource.get_class() != type or not fake.callbacks.is_empty(): return "Blank/ordinary resource creation was intercepted."
	var dialog := await _open_resource(plugin)
	if not await _select_type(plugin, dialog, "ConvexPolygonShape2D"): return "Polygon dialog unavailable."
	var prompt: TextEdit = dialog.find_child("TiinyResourcePrompt", true, false)
	prompt.text = "fixture polygon"
	dialog.get_ok_button().pressed.emit()
	if fake.callbacks.size() != 1: return "Polygon did not invoke AI exactly once."
	var old_callback: Callable = fake.callbacks.back()
	# Select away and back: checking only the final type would accept stale work.
	await _select_type(plugin, dialog, "Image")
	await _select_type(plugin, dialog, "ConvexPolygonShape2D")
	var shape := ConvexPolygonShape2D.new()
	shape.points = PackedVector2Array([Vector2.ZERO, Vector2(32, 0), Vector2(0, 32)])
	old_callback.call(shape, "")
	if not dialog.visible: return "Stale result completed after selection changed away and back."
	prompt.text = "second fixture"
	dialog.get_ok_button().pressed.emit()
	var cancelled: Callable = fake.callbacks.back()
	dialog.get_cancel_button().pressed.emit()
	await _frames(plugin)
	dialog = await _open_resource(plugin)
	await _select_type(plugin, dialog, "ConvexPolygonShape2D")
	cancelled.call(shape, "")
	if not dialog.visible: return "Cancelled result completed a reopened dialog."
	prompt = dialog.find_child("TiinyResourcePrompt", true, false)
	prompt.text = "accepted fixture"
	dialog.get_ok_button().pressed.emit()
	fake.callbacks.back().call(StandardMaterial3D.new(), "")
	if not dialog.visible: return "Wrong resource type was accepted as a polygon."
	dialog.get_ok_button().pressed.emit()
	fake.callbacks.back().call(shape, "")
	await _frames(plugin)
	var created = EditorInterface.get_inspector().get_edited_object()
	if not created is ConvexPolygonShape2D or created.points != shape.points: return "Accepted polygon was not assigned."
	fake.remove_from_group("tiiny_ai_editor_dock")
	dock.add_to_group("tiiny_ai_editor_dock")
	fake.queue_free()
	print("Native resource dialog ordinary/blank creation, selection changes, cancellation and late results passed.")
	return ""

func _ordinary_node(plugin: EditorPlugin, dock: Control) -> String:
	EditorInterface.open_scene_from_path("res://fixture.tscn")
	await _frames(plugin, 8)
	var root := EditorInterface.get_edited_scene_root()
	if root == null: return "Fixture scene failed to open."
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(root)
	var context: String = dock._editor_context()
	if not context.contains("res://fixture.tscn") or not context.contains("Selected node: . [Node2D]"): return "Dock context omitted the edited scene or selected node."
	var opened := false
	for node in _nodes(plugin.get_tree().root):
		if node is Button and node.get_tooltip().contains("Add/Create a New Node"):
			node.pressed.emit()
			opened = true
			break
	if not opened: return "Add Child Node button unavailable."
	await _frames(plugin)
	var dialog: ConfirmationDialog
	for node in _nodes(plugin.get_tree().root):
		if node is ConfirmationDialog and node.visible and node.find_child("TypeOptions", true, false) != null: dialog = node
	if dialog == null or not await _select_type(plugin, dialog, "Node2D"): return "Node dialog did not select Node2D."
	var prompt: TextEdit = dialog.find_child("TiinyResourcePrompt", true, false)
	if prompt.editable: return "Node creation incorrectly enables AI resource input."
	dialog.get_ok_button().pressed.emit()
	await _frames(plugin)
	if root.get_child_count() != 1 or not root.get_child(0) is Node2D: return "Ordinary node creation failed."
	EditorInterface.save_scene()
	print("Ordinary native node creation passed without AI invocation.")
	return ""

func _running_output(plugin: EditorPlugin, dock: Control) -> String:
	if OS.get_environment("TIINY_TEST_HTTP_URL").is_empty(): return ""
	EditorInterface.play_current_scene()
	await plugin.get_tree().create_timer(1.0).timeout
	if not EditorInterface.is_playing_scene(): return "Fixture scene did not start."
	dock._set_status("Story 01 status while fixture runs")
	await _frames(plugin, 5)
	var found := false
	for node in _nodes(plugin.get_tree().root):
		if node is RichTextLabel and node.get_parsed_text().contains("Tiiny AI: Story 01 status while fixture runs"): found = true
	EditorInterface.stop_playing_scene()
	await _frames(plugin, 5)
	if not found: return "Tiiny status did not reach Output while playing."
	print("Running scene and Tiiny Output logging passed.")
	return ""

func _http(plugin: EditorPlugin, manager: Node, dock: Control) -> String:
	var base := OS.get_environment("TIINY_TEST_HTTP_URL")
	if base.is_empty(): return ""
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("tiiny_ai/advanced/api_url", base + "/v1")
	settings.set_setting("tiiny_ai/advanced/device_address", base.trim_prefix("http://"))
	settings.set_setting("tiiny_ai/advanced/api_key", "fixture-secret-key")
	settings.set_setting("tiiny_ai/models/coding_model", "fixture-code")
	settings.set_setting("tiiny_ai/models/image_model", "fixture-image")
	await manager.refresh_device()
	if not manager.is_ready(): return "Real HTTP inventory/readiness failed."
	var other := OS.get_environment("TIINY_TEST_OTHER_HTTP_URL")
	if other.is_empty(): return "Second device fixture is missing."
	if await manager._run_cli(["load", "fixture-model"]) != 0: return "Bound CLI fixture failed."
	var arguments := FileAccess.get_file_as_string("res://cli-arguments").strip_edges().split("\n")
	if arguments.size() != 5 or arguments[0] != "--device-address" or arguments[1] != base.trim_prefix("http://"):
		return "CLI management targeted a different device from inference."
	settings.set_setting("tiiny_ai/advanced/device_address", "wrong-device")
	if manager.is_ready() or manager.is_model_loaded("fixture-code"): return "Changed device retained readiness from the old snapshot."
	settings.set_setting("tiiny_ai/advanced/device_address", base.trim_prefix("http://"))
	settings.set_setting("tiiny_ai/advanced/api_key", "different-key")
	if manager.is_ready(): return "Changed credentials retained readiness from the old snapshot."
	settings.set_setting("tiiny_ai/advanced/api_key", "fixture-secret-key")
	if manager._classify_error("Device request failed (connection 0, HTTP 401).") != "auth": return "Authentication failure was misclassified."
	if manager._classify_error("Device request failed (connection 1, HTTP 0).") != "disconnect": return "Disconnect was misclassified."
	if manager._classify_error("Insufficient NPU capacity") != "capacity": return "Capacity failure was misclassified."
	var draft: Dictionary = manager.draft.duplicate(true)
	draft.roles.coding_model = {"model": "fixture-code", "context": 8192, "warm": true}
	draft.roles.image_model = {"model": "fixture-image", "context": 0, "warm": true}
	draft.extra_warm = []
	manager.update_draft(draft)
	dock.pending_url = base + "/v1"
	dock.pending_key = "fixture-secret-key"
	dock.pending_host = ""
	dock.pending_model = "fixture-code"
	for user in ["normal", "http_failure", "malformed_response", "http_timeout", "normal"]:
		dock.request_stage = "answer"
		dock.request.timeout = 0.1 if user == "http_timeout" else 3.0
		dock.send_button.disabled = true
		if dock._submit_chat({"model": "fixture-code", "messages": [{"role": "user", "content": user}]}) != OK: return "HTTP request failed to start."
		await dock.request.request_completed
		await _frames(plugin)
		if dock.send_button.disabled: return "Real HTTP failure locked controls."
		if user == "normal" and not dock.history_text().contains("HTTP fixture OK"): return "Real HTTP chat response missing."
	var before: Dictionary = manager.snapshot.duplicate(true)
	manager.snapshot.time = Time.get_ticks_msec() - 61000
	if manager.is_ready() or manager.is_model_loaded("fixture-image"): return "Stale inventory reported readiness."
	manager.snapshot = before
	manager.busy = true
	if manager.is_ready(): return "Busy manager reported readiness."
	manager.busy = false
	settings.set_setting("tiiny_ai/advanced/api_url", other + "/v1")
	if not manager.inference_connection().has("error"): return "Inference allowed a different device."
	settings.set_setting("tiiny_ai/advanced/api_url", base + "/v1")
	# A stale snapshot revalidates automatically instead of requiring a manual Refresh.
	manager.snapshot.time = Time.get_ticks_msec() - 61000
	if manager.is_ready(): return "Stale inventory reported readiness before revalidation."
	var before_len: int = dock.history_text().length()
	dock.prompt.text = "auto refresh fixture"
	await dock._generate()
	var chat_deadline := Time.get_ticks_msec() + 20000
	while dock.send_button.disabled and Time.get_ticks_msec() < chat_deadline:
		await plugin.get_tree().create_timer(0.05).timeout
	if dock.send_button.disabled: return "Chat did not finish after automatic revalidation: " + dock.status.text
	if dock.history_text().length() <= before_len: return "Chat did not record a response after automatic revalidation."
	if not manager.is_ready(): return "Automatic revalidation did not restore readiness."
	for description in ["valid image", "invalid_png", "http_failure", "malformed_response"]:
		var result: String = await dock._generate_image_tool(description)
		if description == "valid image":
			if not result.begins_with("Generated image: "): return "HTTP image adapter failed: " + result
			var path := result.trim_prefix("Generated image: ")
			var image := Image.load_from_file(path)
			if image == null or image.get_size() != Vector2i(1, 1): return "Image fixture did not decode."
			var filesystem := EditorInterface.get_resource_filesystem()
			var deadline := Time.get_ticks_msec() + 10000
			while (not FileAccess.file_exists(path + ".import") or filesystem.is_scanning() or filesystem.is_importing()) and Time.get_ticks_msec() < deadline:
				await plugin.get_tree().create_timer(0.05).timeout
			if not ResourceLoader.load(path) is Texture2D: return "Generated PNG did not import as a Godot texture."
		else:
			if not result.begins_with("Error:"): return "Invalid HTTP image accepted."
	var result: Array = []
	dock.generate_shape_for_dialog("HTTP polygon", func(shape, error): result.assign([shape, error]))
	var shape_deadline := Time.get_ticks_msec() + 30000
	while result.is_empty() and Time.get_ticks_msec() < shape_deadline:
		await plugin.get_tree().create_timer(0.05).timeout
	if result.size() != 2 or not result[0] is ConvexPolygonShape2D: return "HTTP polygon request failed."
	await _frames(plugin, 10)
	print("Real loopback HTTP chat, timeout/error recovery, image decoding, polygon adapter and device binding passed.")
	return ""

func run(plugin: EditorPlugin, manager: Node, dock: Control) -> String:
	var error := await _processes(plugin, manager)
	if not error.is_empty(): return error
	error = _shapes(dock)
	if not error.is_empty(): return error
	error = await _dialogs(plugin, dock)
	if not error.is_empty(): return error
	error = await _ordinary_node(plugin, dock)
	if not error.is_empty(): return error
	error = await _http(plugin, manager, dock)
	if not error.is_empty(): return error
	return await _running_output(plugin, dock)

func run_live(plugin: EditorPlugin, manager: Node, dock: Control) -> String:
	var settings := EditorInterface.get_editor_settings()
	var before: Array = manager.snapshot.loaded.keys()
	before.sort()
	var selected := ""
	for id in before:
		if manager.Planner.suitable("coding_model", manager.snapshot.models.get(id, {})):
			selected = id
			if id == manager.CODING_DEFAULT: break
	if selected.is_empty(): return "No compatible coding model is already warm."
	settings.set_setting("tiiny_ai/models/coding_model", selected)
	settings.set_setting("tiiny_ai/models/coding_model_type", manager.snapshot.models[selected].type)
	settings.set_setting("tiiny_ai/models/context_tokens", 8192)
	settings.set_setting("tiiny_ai/advanced/request_timeout_seconds", 180)
	print("Live baseline warm set: ", before, "; coding model: ", selected, "; catalog build: ", manager.snapshot.models[selected].build)
	dock.prompt.text = "Reply with a single brief sentence confirming you can answer inside Godot. Do not use tools."
	dock._generate()
	var deadline := Time.get_ticks_msec() + 90000
	while dock.send_button.disabled and Time.get_ticks_msec() < deadline:
		await plugin.get_tree().create_timer(0.1).timeout
	if dock.send_button.disabled or dock.conversation.is_empty(): return "Real Tiiny chat failed: " + dock.status.text
	print("Real Tiiny chat passed; final text received.")
	await manager.refresh_device()
	var result: Array = []
	dock.generate_shape_for_dialog("A rectangle 32 pixels wide and 48 pixels tall, centered at the origin. Return JSON only.", func(shape, error): result.assign([shape, error]))
	var shape_deadline := Time.get_ticks_msec() + 180000
	while result.is_empty() and Time.get_ticks_msec() < shape_deadline:
		await plugin.get_tree().create_timer(0.1).timeout
	if result.size() != 2 or not result[0] is ConvexPolygonShape2D: return "Real polygon generation failed: " + str(result)
	if ResourceSaver.save(result[0], "res://live_polygon.tres") != OK: return "Could not save real polygon."
	var reopened = ResourceLoader.load("res://live_polygon.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	if not reopened is ConvexPolygonShape2D or reopened.points.size() < 3: return "Real polygon did not reopen."
	print("Real Tiiny polygon passed; saved/reopened with ", reopened.points.size(), " hull vertices.")
	await manager.refresh_device()
	var image_id := ""
	for id in before:
		if manager.snapshot.models.get(id, {}).get("type") == "Text-to-Image": image_id = id
	if not image_id.is_empty():
		settings.set_setting("tiiny_ai/models/image_model", image_id)
		var connection: Dictionary = manager.inference_connection()
		dock.pending_url = connection.url
		dock.pending_key = connection.key
		dock.pending_host = connection.host
		var image_result: String = await dock._generate_image_tool("A simple red square centered on a plain blue background, flat colors, no text.")
		if image_result.begins_with("Generated image: "):
			var path := image_result.trim_prefix("Generated image: ")
			var image := Image.load_from_file(path)
			if image == null: return "Real image file could not decode."
			var until := Time.get_ticks_msec() + 10000
			while not ResourceLoader.exists(path) and Time.get_ticks_msec() < until: await plugin.get_tree().create_timer(0.1).timeout
			if ResourceLoader.load(path) == null: return "Real image import did not produce a texture."
			print("Real Tiiny image passed; model: ", image_id, "; dimensions: ", image.get_size(), "; imported texture verified.")
		else:
			print("Real image adapter remains experimental/unverified: ", image_result)
	else:
		print("Real image smoke skipped: no image model already warm; adapter remains experimental/unverified.")
	await manager.refresh_device()
	var after: Array = manager.snapshot.loaded.keys()
	after.sort()
	if before != after: return "Device warm set changed during inference: " + str(after)
	print("Real inference smoke passed; original warm set unchanged, no restoration needed.")
	return ""
