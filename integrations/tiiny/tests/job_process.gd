extends SceneTree

const Queue = preload("res://editor/tiiny/jobs/queue.gd")

func validate(operation: String, _parameters: Dictionary) -> String:
	return "" if operation == "fixture" else "unsupported"

func _initialize() -> void:
	var root := OS.get_environment("TIINY_QUEUE_TEST_DIR")
	var mode := OS.get_environment("TIINY_QUEUE_TEST_MODE")
	var queue = Queue.new()
	var opened: bool = queue.open(root.path_join("process.json"), "process-test")
	if mode == "contend":
		quit(1 if opened else 0)
		return
	if not opened:
		push_error("Failed to open queue: " + queue.error)
		quit(1)
		return
	if mode in ["owner", "publication_owner"]:
		if queue.append("process", "fixture", {}, validate).get("sequence") != 1 or queue.start_next().is_empty():
			quit(1)
			return
		if mode == "publication_owner":
			DirAccess.make_dir_absolute(root.path_join("stage"))
			DirAccess.make_dir_absolute(root.path_join("assets"))
			var staged := FileAccess.open(root.path_join("stage/tree.png"), FileAccess.WRITE)
			staged.store_string("fixture")
			staged.close()
			var id: String = queue.snapshot().jobs[0].id
			if not queue.publication(id, "prepared", {"source": "stage/tree.png", "destination": "assets/tree.png", "artifact": {"id": id + ":tree"}}) or queue.publish_link(id, root) != "published":
				quit(1)
				return
		var marker := FileAccess.open(root.path_join("ready"), FileAccess.WRITE)
		marker.store_string("ready")
		marker.close()
		while true:
			OS.delay_msec(100)
	elif mode in ["recover", "publication_recover"]:
		var state: Dictionary = queue.snapshot()
		if state.jobs.size() != 1 or state.jobs[0].state != "interrupted" or state.stop_reason.is_empty() or not queue.start_next().is_empty():
			push_error("Interrupted outcome was not stopped")
			quit(1)
			return
		if mode == "publication_recover" and (state.jobs[0].attempts[0].publication.phase != "published" or not FileAccess.file_exists(root.path_join("assets/tree.png"))):
			push_error("Publication journal or output was lost")
			quit(1)
			return
		queue.close()
		quit(0)
	else:
		quit(1)
