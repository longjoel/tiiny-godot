extends SceneTree
const Queue = preload("res://editor/tiiny/jobs/queue.gd")
var failures := 0

func validate(operation: String, _parameters: Dictionary) -> String:
	return "" if operation == "fixture" else "invalid"

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func _initialize() -> void:
	var temp := OS.get_environment("TIINY_QUEUE_TEST_DIR")
	if temp.is_empty():
		push_error("TIINY_QUEUE_TEST_DIR is required")
		quit(1)
		return
	var root := temp.path_join("publication-%d-%d" % [OS.get_process_id(), int(Time.get_unix_time_from_system() * 1000000)])
	DirAccess.make_dir_recursive_absolute(root.path_join("stage"))
	DirAccess.make_dir_recursive_absolute(root.path_join("assets"))
	var file := FileAccess.open(root.path_join("stage/tree.png"), FileAccess.WRITE)
	file.store_string("fixture")
	file.close()
	var storage: RefCounted = ClassDB.instantiate("TiinyJobStorage")
	check(storage.acquire(root.path_join("queue.json")), "acquire")
	check(storage.link_exclusive(root, "stage/tree.png", "assets/tree.png") == "published", "publish")
	check(storage.same_file(root, "stage/tree.png", "assets/tree.png"), "publication identity")
	check(storage.link_exclusive(root, "stage/tree.png", "assets/tree.png") == "conflict", "no overwrite")
	check(FileAccess.get_file_as_string(root.path_join("assets/tree.png")) == "fixture", "existing data retained")
	check(storage.link_exclusive(root, "../outside", "assets/escape") == "invalid_path", "reject traversal")
	var dir := DirAccess.open(root)
	check(dir.create_link(root.path_join("assets"), root.path_join("redirect")) == OK, "create link fixture")
	check(storage.link_exclusive(root, "stage/tree.png", "redirect/tree2.png") == "invalid_path", "reject symlink parent")
	check(dir.create_link(root.path_join("stage/tree.png"), root.path_join("stage/link.png")) == OK, "create source link")
	check(storage.link_exclusive(root, "stage/link.png", "assets/link.png") == "invalid_source", "reject symlink source")
	storage.release()
	var queue = Queue.new()
	check(queue.open(root.path_join("jobs.json"), "publication-test"), "queue open")
	var job: Dictionary = queue.append("first", "fixture", {}, validate)
	check(queue.start_next().id == job.id, "start")
	check(queue.publication(job.id, "prepared", {"source": "stage/tree.png", "destination": "assets/queued.png", "artifact": {"id": job.id + ":tree", "sha256": FileAccess.get_sha256(root.path_join("stage/tree.png"))}}), "prepare")
	check(queue.publish_link(job.id, root) == "published", "journaled publish")
	queue.close()
	var recovered = Queue.new()
	check(recovered.open(root.path_join("jobs.json"), "publication-test"), "reopen after publication")
	check(recovered.snapshot().jobs[0].state == "interrupted", "published attempt requires reconciliation")
	check(recovered.snapshot().jobs[0].attempts[0].publication.phase == "published", "published journal persisted")
	check(recovered.start_next().is_empty(), "no automatic replay")
	recovered.close()
	print("job publication failures: ", failures)
	quit(1 if failures else 0)
