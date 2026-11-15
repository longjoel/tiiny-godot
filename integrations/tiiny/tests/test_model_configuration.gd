extends SceneTree

class SettingsFixture extends RefCounted:
	var values := {"tiiny_ai/connection/api_url": "fixture-url", "tiiny_ai/connection/api_key": "fixture-key", "tiiny_ai/device/address": "fixture-address", "tiiny_ai/device/cli_path": "old-cli", "tiiny_ai/advanced/cli_path": "chosen-cli"}
	func has_setting(key: String) -> bool: return values.has(key)
	func get_setting(key: String) -> Variant: return values[key]
	func set_setting(key: String, value: Variant) -> void: values[key] = value
	func erase(key: String) -> void: values.erase(key)

func _initialize() -> void:
	var settings := SettingsFixture.new()
	var chat = load("res://chat.gd")
	chat._migrate_connection_settings(settings)
	assert(settings.values == {"tiiny_ai/advanced/api_url": "fixture-url", "tiiny_ai/advanced/api_key": "fixture-key", "tiiny_ai/advanced/device_address": "fixture-address", "tiiny_ai/advanced/cli_path": "chosen-cli"})
	chat._migrate_connection_settings(settings)
	assert(settings.values.size() == 4)
	var script = load("res://manager.gd")
	var planner = script.Planner
	var reader = script.ProgressReader.new()
	assert(reader.feed("\u001b[3".to_utf8_buffer()).is_empty())
	assert(reader.feed("2m25.0%\u001b[0m\r".to_utf8_buffer()) == [25.0])
	assert(reader.feed("Terminal title: \u001b]0;secret 99%\u0007 45%\n".to_utf8_buffer()) == [45.0])
	assert(reader.feed("UTF-8 ███ 75%\r".to_utf8_buffer()) == [75.0])
	assert(reader.feed("100%".to_utf8_buffer()).is_empty())
	assert(reader.feed(PackedByteArray(), true) == [100.0])
	var raw := [
		{"model_id": "code", "name": "Code", "type": "Image-Text-to-Text", "supported": ["Tool Use"], "npu_usage": 47, "context_window": 32768, "status": "running", "tags": [{"size": 16 * 1073741824, "build_id": "a"}]},
		{"model_id": "image", "name": "Image", "type": "Text-to-Image", "npu_usage": 23, "status": "running", "tags": [{"size": 10 * 1073741824}]},
		{"model_id": "large", "name": "Large", "type": "Text Generation", "supported": ["Tool Use"], "context_window": 32768, "npu_usage": 60, "status": "not_downloaded", "tags": [{"size": 20 * 1073741824}]}
	]
	var npu := {"npu_total": 100, "npu_used": 70, "models": [{"model_id": "code", "npu_usage": 47}, {"model_id": "image", "npu_usage": 23}]}
	var storage := {"total_bytes": 200 * 1073741824, "remaining_bytes": 100 * 1073741824}
	var state: Dictionary = planner.normalize(raw, npu, storage)
	var config := {"roles": {"coding_model": {"model": "code", "context": 8192, "warm": true}, "image_model": {"model": "image", "context": 0, "warm": true}}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
	var saved := config.duplicate(true)
	for role in script.ROLES:
		if not saved.roles.has(role): saved.roles[role] = {"model": "", "context": 0, "warm": false}
	var approved := {"draft": saved, "actions": [{"verb": "load", "id": "code"}], "connection": "a".repeat(64), "active_coding": "code"}
	assert(script._valid_approved_configuration(approved))
	var invalid_approved := approved.duplicate(true)
	invalid_approved.actions = [{"verb": "delete", "id": "code"}]
	assert(not script._valid_approved_configuration(invalid_approved))
	invalid_approved = approved.duplicate(true)
	invalid_approved.actions = [null]
	assert(not script._valid_approved_configuration(invalid_approved))
	invalid_approved = approved.duplicate(true)
	invalid_approved.connection = "wrong"
	assert(not script._valid_approved_configuration(invalid_approved))
	var result: Dictionary = planner.check(state, config, "code")
	assert(result.ok and result.actions.is_empty())
	assert(result.npu_projected == 70 and result.npu_remaining == 30)
	assert(result.download_bytes == 0)
	assert(config.roles.image_model.warm) # Planning must not mutate the draft.
	var reserved := config.duplicate(true)
	reserved.npu_reserve = 40
	assert(not planner.check(state, reserved, "code").ok)
	reserved = config.duplicate(true)
	reserved.disk_reserve_gib = 101
	assert(not planner.check(state, reserved, "code").ok)
	var duplicate := config.duplicate(true)
	duplicate.extra_warm = ["image"]
	assert(planner.check(state, duplicate, "code").npu_projected == 70)
	var bad := config.duplicate(true)
	bad.roles.coding_model.model = "image"
	assert(not planner.check(state, bad, "code").ok)
	bad = config.duplicate(true)
	bad.roles.coding_model.context = 65536
	assert(not planner.check(state, bad, "code").ok)
	bad = config.duplicate(true)
	bad.extra_warm = ["large"]
	assert(not planner.check(state, bad, "code").ok)
	var low_disk := state.duplicate(true)
	low_disk.disk_free = 30 * 1073741824
	low_disk.models["new_image"] = state.models.image.duplicate(true)
	low_disk.models.new_image.installed = false
	low_disk.models.new_image.bytes = 20 * 1073741824
	bad = config.duplicate(true)
	bad.roles.image_model = {"model": "new_image", "context": 0, "warm": false}
	var disk_check: Dictionary = planner.check(low_disk, bad, "code")
	assert(not disk_check.ok and disk_check.npu_projected <= 95)
	assert(Array(disk_check.errors).any(func(error): return "SSD" in error))
	bad = config.duplicate(true)
	bad.npu_reserve = -1
	assert(not planner.check(state, bad, "code").ok)
	var switched := config.duplicate(true)
	switched.roles.coding_model.model = "large"
	switched.roles.image_model.warm = false
	assert(not planner.check(state, switched, "code").ok) # protected old+new do not fit
	var enhancer := state.duplicate(true)
	enhancer.models.code.supported = ["Prompt Enhance"]
	assert(not planner.check(enhancer, config, "code").ok)
	var no_size := state.duplicate(true)
	no_size.models.large.bytes = -1
	assert(not planner.check(no_size, switched, "code").ok)
	var no_npu := state.duplicate(true)
	no_npu.models.image.npu = -1
	assert(not planner.check(no_npu, config, "code").ok)
	var unload := config.duplicate(true)
	unload.roles.image_model.warm = false
	var unloading: Dictionary = planner.check(state, unload, "code")
	assert(unloading.ok and unloading.actions == [{"verb": "unload", "id": "image"}])
	assert(not unloading.actions.any(func(action): return action.verb == "unload" and action.id == "code"))
	assert(state.loaded.has("image")) # Plan has no effects on observed state.
	var unknown := state.duplicate(true)
	unknown.npu_total = -1
	assert(not planner.check(unknown, config, "code").ok)
	# Exercise the actual panel in a headless SceneTree with fixture data.
	var manager = script.new()
	manager.snapshot = state.duplicate(true)
	manager.snapshot.models["extra"] = state.models.image.duplicate(true)
	manager.snapshot.models.extra.name = "Extra installed model"
	manager.snapshot["time"] = Time.get_ticks_msec()
	manager.connected = true
	manager.draft = config.duplicate(true)
	for role in manager.ROLES:
		if not manager.draft.roles.has(role): manager.draft.roles[role] = {"model": "", "context": 0, "warm": false}
	var panel: Control = manager.create_configuration_panel()
	root.add_child.call_deferred(panel)
	await process_frame
	assert(panel.find_child("ConfigurationStatus", true, false) != null)
	var advanced: FoldableContainer = panel.find_child("AdvancedHeadroom", true, false)
	assert(advanced != null and advanced.folded)
	assert(panel.find_children("*", "Tree", true, false).is_empty(), "No duplicate inventory table before a plan is checked.")
	panel._show_model_info("code")
	await process_frame
	var info: AcceptDialog = panel.find_child("ModelInformation", true, false)
	assert(info != null and info.visible)
	info.hide()
	await process_frame
	var table: GridContainer = panel.find_child("ModelTable", true, false)
	var table_scroll: ScrollContainer = panel.find_child("ModelTableScroll", true, false)
	assert(table != null and table_scroll != null)
	assert(table.get_child_count() == 9 * (1 + manager.ROLES.size() + 1), "Only unassigned installed models should add rows.")
	assert(table.get_combined_minimum_size().x >= 1000)
	for width in [600, 1400]:
		panel.size = Vector2(width, 1000)
		await process_frame
		await process_frame
		assert(table.size.y < 330, "Task rows must not grow into vertically wrapped text.")
		for cell in table.get_children():
			assert(cell.size.y < 50, "Table cells must remain compact single-line controls.")
			if cell is Label: assert(cell.autowrap_mode == TextServer.AUTOWRAP_OFF)
		if width == 600: assert(table_scroll.get_h_scroll_bar().visible)
	manager.plan = {"ok": true, "checked_at": Time.get_ticks_msec() - 61000}
	panel._process(0)
	assert(panel.apply_button.disabled and panel.apply_button.text == "Check expired")
	var edited: Dictionary = manager.draft.duplicate(true)
	edited.roles.image_model.warm = false
	manager.update_draft(edited)
	assert(manager.plan.is_empty())
	assert(not manager.draft.roles.image_model.warm)
	panel.queue_free()
	await process_frame
	manager.free()
	print("Model configuration planner and panel: all checks passed (no device access).")
	quit()
