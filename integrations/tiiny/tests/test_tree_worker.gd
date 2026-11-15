extends SceneTree

const Queue = preload("res://editor/tiiny/jobs/queue.gd")
const Executor = preload("res://editor/tiiny/jobs/executor.gd")
const Worker = preload("res://editor/tiiny/jobs/tree_worker.gd")
var failures := 0
var base := ""
var promoted := ""
var workers := 0
var publications := 0
var queue: RefCounted

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func validate(operation: String, parameters: Dictionary) -> String:
	return "" if operation == "create_tree" and parameters.get("timeout_ms") == 10000 else "invalid"

func publish(_job: Dictionary, artifact: Dictionary) -> Dictionary:
	publications += 1
	if FileAccess.file_exists(promoted):
		return {"error": "Destination already exists"}
	if FileAccess.get_sha256(artifact.path) != artifact.sha256:
		return {"error": "Staged artifact changed"}
	if DirAccess.copy_absolute(artifact.path, promoted) != OK:
		return {"error": "Copy failed"}
	artifact.path = promoted
	return {"ok": true, "artifact": artifact}

func create_worker(_job: Dictionary) -> RefCounted:
	workers += 1
	return Worker.new(base.path_join("attempt-%d" % workers), OS.get_executable_path(), publish)

func _initialize() -> void:
	# Editor-only classes are available while the script main loop initializes.
	queue = Queue.new()
	var temp := OS.get_environment("TIINY_QUEUE_TEST_DIR")
	base = temp.path_join("tree-%d-%d" % [OS.get_process_id(), int(Time.get_unix_time_from_system() * 1000000)])
	if temp.is_empty() or DirAccess.make_dir_recursive_absolute(base) != OK or not queue.open(base.path_join("queue.json"), "tree-test"):
		push_error("Cannot open fixture queue")
		quit(1)
		return
	call_deferred("run")

func run() -> void:
	promoted = base.path_join("promoted.png")
	var first: Dictionary = queue.append("tree-1", "create_tree", {"timeout_ms": 10000}, validate)
	queue.append("tree-2", "create_tree", {"timeout_ms": 10000}, validate)
	var executor = Executor.new(queue, create_worker)
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		executor.tick()
		if queue.snapshot().jobs[1].state == "failed":
			break
		await process_frame
	var state: Dictionary = queue.snapshot()
	check(state.jobs[0].state == "completed", "reviewed generator completed")
	check(state.jobs[0].result.artifact.id == first.id + ":tree", "explicit artifact id")
	check(state.jobs[1].state == "failed", "destination conflict stops second job")
	check(state.jobs[1].result.error == "Destination already exists", "conflict diagnostic")
	var image := Image.new()
	check(image.load(promoted) == OK and image.get_width() == 64 and image.get_height() == 64, "published image loads")
	check(FileAccess.get_sha256(promoted) == state.jobs[0].result.artifact.sha256, "published hash matches")
	var invalid_root := base.path_join("invalid")
	DirAccess.make_dir_absolute(invalid_root)
	var validator = Worker.new(invalid_root, OS.get_executable_path(), publish)
	validator.job = {"id": "invalid"}
	var bad := FileAccess.open(invalid_root.path_join("tree.png"), FileAccess.WRITE)
	bad.store_string("not a valid image")
	bad.close()
	var calls_before := publications
	check(validator._validate_and_publish({}).state == "failed", "malformed PNG rejected")
	DirAccess.remove_absolute(invalid_root.path_join("tree.png"))
	var directory := DirAccess.open(invalid_root)
	check(directory.create_link(promoted, invalid_root.path_join("tree.png")) == OK, "create symlink fixture")
	check(validator._validate_and_publish({}).state == "failed", "symlink output rejected")
	check(publications == calls_before, "invalid output never reaches publication")
	queue.close()
	print("tree worker failures: ", failures)
	quit(1 if failures else 0)
