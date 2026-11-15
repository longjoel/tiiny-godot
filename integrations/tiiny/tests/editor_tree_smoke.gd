@tool
extends EditorPlugin

const Queue = preload("res://job_scripts/queue.gd")
const Executor = preload("res://job_scripts/executor.gd")
const Worker = preload("res://job_scripts/tree_worker.gd")
const Publisher = preload("res://job_scripts/tree_publisher.gd")
var queue: RefCounted
var root := ""
var count := 0

func _enter_tree() -> void:
	_run.call_deferred()

func _validate(operation: String, parameters: Dictionary) -> String:
	return "" if operation == "create_tree" and parameters.get("destination") == "res://assets/tree.png" else "invalid"

func _worker(_job: Dictionary) -> RefCounted:
	count += 1
	var publisher = Publisher.new(queue, root, EditorInterface.get_resource_filesystem())
	return Worker.new(root.path_join(".godot/tiiny/asset_jobs/attempt-%d" % count), OS.get_executable_path(), publisher)

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _run() -> void:
	root = ProjectSettings.globalize_path("res://").trim_suffix("/")
	DirAccess.make_dir_recursive_absolute(root.path_join(".godot/tiiny/asset_jobs"))
	queue = Queue.new()
	if not queue.open(root.path_join(".godot/tiiny/queue.json"), "editor-tree-fixture"):
		_fail("Queue open failed: " + queue.error)
		return
	var first: Dictionary = queue.append("first", "create_tree", {"destination": "res://assets/tree.png", "timeout_ms": 30000}, _validate)
	queue.append("second", "create_tree", {"destination": "res://assets/tree.png", "timeout_ms": 30000}, _validate)
	var executor = Executor.new(queue, _worker)
	var deadline := Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < deadline:
		executor.tick()
		var snapshot: Dictionary = queue.snapshot()
		if snapshot.jobs[1].state == "failed" or snapshot.jobs[0].state in ["failed", "interrupted"]:
			break
		await get_tree().create_timer(0.02).timeout
	var snapshot: Dictionary = queue.snapshot()
	if snapshot.jobs[0].state != "completed" or snapshot.jobs[1].state != "failed":
		_fail("Unexpected job states: " + JSON.stringify(snapshot))
		return
	if snapshot.jobs[0].attempts[0].publication.phase != "imported" or snapshot.jobs[0].result.artifact.id != first.id + ":tree":
		_fail("Publication or artifact missing")
		return
	if not ResourceLoader.load("res://assets/tree.png") is Texture2D:
		_fail("Published texture did not load")
		return
	if not snapshot.jobs[1].result.error.contains("conflict") and not snapshot.jobs[1].result.error.contains("metadata"):
		_fail("Second destination did not conflict")
		return
	queue.close()
	# Simulate an editor restart after the link but before import was recorded.
	var recovery_path := root.path_join(".godot/tiiny/recovery.json")
	var before = Queue.new()
	if not before.open(recovery_path, "recovery-fixture"):
		_fail("Recovery queue open failed")
		return
	var recovery_job: Dictionary = before.append("recovery", "create_tree", {"destination": "res://assets/recovered.png"}, func(_op, _params): return "")
	before.start_next()
	var source := ".godot/tiiny/asset_jobs/recovery/tree.png"
	DirAccess.make_dir_recursive_absolute(root.path_join(source.get_base_dir()))
	DirAccess.copy_absolute(root.path_join("assets/tree.png"), root.path_join(source))
	var artifact := {"id": recovery_job.id + ":tree", "path": root.path_join(source), "sha256": FileAccess.get_sha256(root.path_join(source)), "format": "png", "recipe": "tree-fixture-v1"}
	if not before.publication(recovery_job.id, "prepared", {"source": source, "destination": "assets/recovered.png", "artifact": artifact}) or before.publish_link(recovery_job.id, root) != "published":
		_fail("Could not prepare recovery fixture")
		return
	before.close()
	var after = Queue.new()
	if not after.open(recovery_path, "recovery-fixture"):
		_fail("Recovery reopen failed")
		return
	var interrupted: Dictionary = after.snapshot().jobs[0]
	var recovery = Publisher.new(after, root, EditorInterface.get_resource_filesystem())
	var recovery_start: Dictionary = recovery.begin_recovery(interrupted)
	if not recovery_start.get("ok", false):
		_fail("Recovery identity failed: " + str(recovery_start))
		return
	var recovered: Dictionary = {"pending": true}
	deadline = Time.get_ticks_msec() + 20000
	while recovered.get("pending", false) and Time.get_ticks_msec() < deadline:
		recovered = recovery.publish(interrupted, recovery_start.artifact)
		await get_tree().create_timer(0.02).timeout
	if not recovered.get("ok", false) or after.snapshot().jobs[0].state != "completed" or not after.snapshot().paused:
		_fail("Recovery failed: " + str(recovered))
		return
	after.close()
	print("Editor tree publication and import passed")
	get_tree().quit(0)
