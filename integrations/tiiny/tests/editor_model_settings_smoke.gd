@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = [node]
	for child in node.get_children(true): result.append_array(_descendants(child))
	return result

func _find_section(item: TreeItem) -> TreeItem:
	if item == null: return null
	if item.get_metadata(0) == "tiiny_ai/models": return item
	var child := item.get_first_child()
	while child:
		var found := _find_section(child)
		if found: return found
		child = child.get_next()
	return null

func _fail(reason: String) -> void:
	push_error(reason)
	get_tree().quit(1)

func _test_apply_contract() -> bool:
	var fake = load("res://fake_manager.gd").new()
	get_tree().root.add_child(fake)
	await fake._poll_download_progress({}, ["download", "fixture-model"])
	if not fake.message.contains("42.5% (device)"): return false
	var progress_count: int = fake.operation_log.size()
	await fake._poll_download_progress({}, ["download", "fixture-model"])
	if fake.operation_log.size() != progress_count: return false
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("tiiny_ai/models/coding_model", "code")
	var fixture := {"models": {"code": {"name": "Code", "type": "Text Generation", "supported": ["Tool Use"], "npu": 47, "bytes": 100, "installed": true, "max_context": 32768}, "image": {"name": "Image", "type": "Text-to-Image", "npu": 23, "bytes": 100, "installed": true, "max_context": 0}}, "loaded": {"code": 47, "image": 23}, "npu_total": 100, "npu_used": 70, "disk_free": 100 * 1073741824, "disk_total": 200 * 1073741824, "connection": "fixture"}
	fake.fixture_state = fixture.duplicate(true)
	fake.draft_initialized = true
	fake.draft = {"roles": {}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
	for role in fake.ROLES:
		fake.draft.roles[role] = {"model": "code" if role == "coding_model" else "image" if role == "image_model" else "", "context": 8192 if role == "coding_model" else 0, "warm": role == "coding_model"}
	await fake.check_config()
	if not fake.plan.get("ok", false) or not fake.calls.is_empty(): return false
	await fake.apply_config()
	if fake.calls != [["unload", "image"]] or not fake.fixture_state.loaded.has("code"): return false
	# A stale device state invalidates the checked operations before any mutation.
	fake.fixture_state = fixture.duplicate(true)
	fake.calls.clear()
	await fake.check_config()
	fake.fixture_state.loaded.erase("image")
	await fake.apply_config()
	if not fake.calls.is_empty() or not fake.plan.is_empty(): return false
	# A false-positive CLI success cannot pass post-operation verification.
	fake.fixture_state = fixture.duplicate(true)
	fake.calls.clear()
	fake.omit_effect = true
	await fake.check_config()
	await fake.apply_config()
	if not fake.plan.is_empty() or fake.applying or fake.busy: return false
	if not fake.message.contains("did not confirm"): return false
	# Expired checks never invoke the mutating adapter.
	fake.calls.clear()
	await fake.check_config()
	fake.plan.checked_at = Time.get_ticks_msec() - 61000
	await fake.apply_config()
	if not fake.calls.is_empty() or not fake.plan.is_empty(): return false
	fake.fail_command = true
	fake.omit_effect = false
	fake.fixture_state = fixture.duplicate(true)
	fake.draft.roles.coding_model.context = 16384
	await fake.check_config()
	await fake.apply_config()
	if not fake.message.contains("Operation failed") or int(settings.get_setting("tiiny_ai/models/context_tokens")) != 8192: return false
	fake.queue_free()
	await get_tree().process_frame
	print("Staged Apply contract passed with fake transport; no device mutation.")
	return true

func _run() -> void:
	for count in range(10): await get_tree().process_frame
	var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
	if manager == null:
		_fail("Tiiny settings manager did not initialize.")
		return
	if OS.get_environment("TIINY_TEST_LIVE_READONLY") == "1":
		await manager.refresh_device()
		if not manager.connected:
			_fail("Live read-only refresh failed: " + manager.message)
			return
		await manager.check_config()
		if not manager.plan.get("ok", false):
			_fail("Live read-only Check Config did not pass: " + str(manager.plan.get("errors", [])))
			return
		print("Live read-only inventory and Check Config passed; no Apply was invoked.")
	else:
		if not await _test_apply_contract():
			_fail("Staged Apply contract failed.")
			return
		var assistant := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
		var short_request := {"messages": [{"role": "user", "content": "hello"}]}
		if not assistant._check_context_budget(short_request) or short_request.get("max_tokens") != 1024:
			_fail("Context budget did not configure the response allowance.")
			return
		if assistant._check_context_budget({"messages": [{"role": "user", "content": "x".repeat(10000)}]}):
			_fail("Context budget did not reject an oversized request.")
			return
		var settings := EditorInterface.get_editor_settings()
		settings.set_setting("tiiny_ai/advanced/cli_path", ProjectSettings.globalize_path("res://fake-tiiny"))
		settings.set_setting("tiiny_ai/advanced/device_address", "127.0.0.1")
		settings.set_setting("tiiny_ai/advanced/api_key", "fixture-key")
		if await manager._run_cli(["load", "fixture-model"]) != 0:
			_fail("Nonblocking CLI runner failed with the local stub.")
			return
		if not Array(manager.operation_log).any(func(line): return "25.0% (SDK)" in line) or not Array(manager.operation_log).any(func(line): return "100.0% (SDK)" in line):
			_fail("CLI progress percentages did not reach the operation log.")
			return
		print("Nonblocking CLI runner passed with local stub, no real SDK invocation.")
		# Opening the fixture panel must not touch the real device.
		manager.snapshot = {"models": {}, "loaded": {}, "npu_total": 100, "npu_used": 0, "disk_total": 100 * 1073741824, "disk_free": 80 * 1073741824, "time": Time.get_ticks_msec()}
		manager.connected = true
	var opened := false
	for node in _descendants(get_tree().root):
		if node is PopupMenu:
			for index in range(node.item_count):
				if node.get_item_text(index) == "Editor Settings...":
					node.id_pressed.emit(node.get_item_id(index))
					opened = true
					break
		if opened: break
	if not opened:
		_fail("Could not open the editor settings menu.")
		return
	for count in range(5): await get_tree().process_frame
	var dialog: Window
	for node in _descendants(get_tree().root):
		if node is Window and node.title == "Editor Settings": dialog = node
	if dialog == null:
		_fail("Editor Settings dialog not found.")
		return
	var selected := false
	for node in _descendants(dialog):
		if node is Tree:
			var item := _find_section(node.get_root())
			if item:
				item.select(0)
				node.item_selected.emit()
				selected = true
				break
	if not selected:
		_fail("Models section is missing from the settings tree.")
		return
	for count in range(5): await get_tree().process_frame
	var panels := 0
	for node in _descendants(dialog):
		if node.name == "Tiiny Model Management": panels += 1
	if panels != 1:
		_fail("Expected exactly one custom model configuration panel, found %d." % panels)
		return
	print("Editor Models section smoke check passed (fixture data, no device mutation).")
	dialog.hide()
	get_tree().quit()
