@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _run() -> void:
	var jobs: Node
	for i in range(200):
		jobs = get_tree().root.find_child("Tiiny Jobs", true, false)
		if jobs != null and jobs.get("available"):
			break
		await get_tree().create_timer(0.05).timeout
	if jobs == null or not jobs.get("available"):
		_fail("Built-in Jobs service unavailable")
		return
	var chat := get_tree().root.find_child("Tiiny Assistant", true, false)
	if chat == null or chat.get("jobs_service") != jobs:
		_fail("Chat is not connected to the shared Jobs service")
		return
	var mode := OS.get_environment("TIINY_JOBS_TEST_MODE")
	if mode == "create":
		EditorInterface.open_scene_from_path("res://target.tscn")
		for i in range(200):
			if EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == "res://target.tscn":
				break
			await get_tree().create_timer(0.05).timeout
		var scene := EditorInterface.get_edited_scene_root()
		if scene == null or scene.scene_file_path != "res://target.tscn":
			_fail("Scene failed to open")
			return
		var accepted: Dictionary = jobs.append_job("fixture-key", "create_tree", {"destination": "res://assets/tree.png", "timeout_ms": 30000})
		if not accepted.has("id") or accepted.sequence != 1:
			_fail("Append failed: " + str(accepted))
			return
		if not jobs.append_job("invalid", "create_tree", {"destination": "res://../bad.png", "timeout_ms": 30000}).has("error"):
			_fail("Invalid job accepted")
			return
		var attachment: Dictionary = jobs.append_job("attach-key", "attach_tree_to_scene", {"artifact_id": accepted.id + ":tree", "scene_path": "res://target.tscn", "scene_sha256": FileAccess.get_sha256("res://target.tscn"), "parent_path": ".", "node_name": "Tree", "timeout_ms": 30000})
		if attachment.get("sequence") != 2:
			_fail("Attachment was not accepted: " + str(attachment))
			return
		var deadline := Time.get_ticks_msec() + 40000
		var state: Dictionary = {}
		while Time.get_ticks_msec() < deadline:
			state = jobs.get_job_status(attachment.id)
			if state.get("state") in ["completed", "failed", "interrupted"]:
				break
			await get_tree().create_timer(0.05).timeout
		var tree_job: Dictionary = jobs.get_job_status(accepted.id)
		if state.get("state") != "completed" or tree_job.attempts[0].publication.phase != "imported" or state.attempts[0].mutation.phase != "saved":
			_fail("Built-in job did not complete: " + str(state))
			return
		if not scene.get_node_or_null("Tree") is Sprite2D or scene.get_node("Tree").texture.resource_path != "res://assets/tree.png":
			_fail("Tree was not attached to the requested scene")
			return
		var packed := ResourceLoader.load("res://target.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		var saved := packed.instantiate() if packed else null
		if saved == null or not saved.get_node_or_null("Tree") is Sprite2D:
			_fail("Attachment was not saved")
			return
		saved.free()
		var manager := EditorInterface.get_editor_undo_redo()
		var history := manager.get_history_undo_redo(manager.get_object_history_id(scene))
		history.undo()
		if scene.has_node("Tree"):
			_fail("Attachment could not be undone")
			return
		history.redo()
		if not scene.has_node("Tree"):
			_fail("Attachment could not be redone")
			return
		if not ResourceLoader.load("res://assets/tree.png") is Texture2D:
			_fail("Imported texture unavailable")
			return
		if EditorInterface.get_resource_filesystem().get_filesystem_path("res://.tiiny") != null:
			_fail("Queue history appeared in imported project files")
			return
	elif mode == "restore":
		var duplicate: Dictionary = jobs.append_job("fixture-key", "create_tree", {"destination": "res://assets/tree.png", "timeout_ms": 30000})
		if not duplicate.get("duplicate", false) or jobs.get_job_status(duplicate.get("id", "")).get("state") != "completed":
			_fail("Completed job not restored: " + str(duplicate) + " / " + str(jobs.get("queue").snapshot()))
			return
	else:
		_fail("Unknown fixture mode")
		return
	print("Built-in Jobs %s passed" % mode)
	get_tree().quit(0)
