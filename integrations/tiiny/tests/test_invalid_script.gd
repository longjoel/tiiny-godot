extends SceneTree

func _initialize() -> void:
	# GDScript.reload emits one expected parse diagnostic. Keep this test separate
	# from the editor suite, where every script diagnostic remains unexpected.
	var dock = load("res://chat.gd").new()
	var result: String = dock._create_script_tool("res://invalid_source.gd", "extends Node\nfunc broken(:\n")
	if not result.begins_with("Error: Generated script failed validation") or FileAccess.file_exists("res://invalid_source.gd"):
		quit(1)
		return
	dock.free()
	print("Invalid generated script rejected before file creation (expected parse diagnostic).")
	quit()
