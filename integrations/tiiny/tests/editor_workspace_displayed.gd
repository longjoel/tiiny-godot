@tool
extends EditorPlugin

## Displayed capture of the Tiiny Chat dock in workspace and hybrid modes.

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _capture(path: String) -> bool:
	for index in range(5):
		await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return false
	return image.save_png(path) == OK

func _run() -> void:
	for index in range(30):
		await get_tree().process_frame
	var dock := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if dock == null:
		_fail("Tiiny dock is missing")
		return
	DisplayServer.window_set_size(Vector2i(1280, 820))
	await get_tree().process_frame
	if dock.get_parent() != null and dock.get_parent().has_method("make_visible"):
		dock.get_parent().call("make_visible")
	for index in range(5):
		await get_tree().process_frame
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("tiiny_ai/advanced/tool_mode", "workspace")
	dock.call("_refresh_registry_availability")
	for index in range(5):
		await get_tree().process_frame
	var label: Label = dock.get("mode_label")
	if label == null or not label.is_visible_in_tree() or not label.text.contains("Workspace coding mode"):
		_fail("The workspace mode label is not visible: " + (str(label.text) if label != null else "missing") + " visible=" + str(label.is_visible_in_tree() if label != null else false))
		return
	if not await _capture("/tmp/tiiny-story18-mode-workspace.png"):
		_fail("Could not capture the workspace mode")
		return
	settings.set_setting("tiiny_ai/advanced/tool_mode", "hybrid")
	dock.call("_refresh_registry_availability")
	await get_tree().process_frame
	if label == null or not label.text.contains("Hybrid mode"):
		_fail("The hybrid mode label is not visible")
		return
	if not await _capture("/tmp/tiiny-story18-mode-hybrid.png"):
		_fail("Could not capture the hybrid mode")
		return
	settings.set_setting("tiiny_ai/advanced/tool_mode", "editor")
	print("Displayed workspace mode capture passed")
	get_tree().quit(0)
