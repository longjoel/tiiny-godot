extends SceneTree

const Queue = preload("res://editor/tiiny/jobs/queue.gd")
const Executor = preload("res://editor/tiiny/jobs/executor.gd")
var failures := 0
var now := 0
var workers: Array = []

class FakeWorker extends RefCounted:
	var polls := 0
	var cancelled := false
	var finish_on_cancel := false
	var id := ""
	func start(job: Dictionary) -> String:
		id = job.id
		return ""
	func poll() -> Dictionary:
		polls += 1
		if cancelled:
			return {"state": "completed" if finish_on_cancel else "cancelled", "result": {"artifact": id} if finish_on_cancel else {}}
		if polls < 2:
			return {"state": "running", "stage": "Working"}
		return {"state": "completed", "result": {"artifact": id}}
	func cancel() -> void:
		cancelled = true

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func validate(operation: String, _parameters: Dictionary) -> String:
	return "" if operation == "fixture" else "unsupported"

func make_worker(_job: Dictionary) -> RefCounted:
	var worker := FakeWorker.new()
	workers.append(worker)
	return worker

func get_clock() -> int:
	return now

func _initialize() -> void:
	var root := OS.get_environment("TIINY_QUEUE_TEST_DIR")
	if root.is_empty():
		push_error("TIINY_QUEUE_TEST_DIR is required")
		quit(1)
		return
	var path := root.path_join("executor.json")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var queue = Queue.new()
	check(queue.open(path, "executor-test"), "open")
	var first: Dictionary = queue.append("first", "fixture", {}, validate)
	var second: Dictionary = queue.append("second", "fixture", {"timeout_ms": 10}, validate)
	var executor = Executor.new(queue, make_worker, get_clock)
	executor.tick()
	check(executor.current.id == first.id and workers.size() == 1, "first started")
	executor.tick()
	check(executor.stage == "Working" and workers.size() == 1, "no overlap")
	executor.tick()
	check(queue.snapshot().jobs[0].state == "completed", "completion recorded")
	executor.tick()
	check(executor.current.id == second.id, "second started")
	now = 10
	executor.tick()
	check(queue.snapshot().jobs[1].state == "failed", "timeout stops after cancellation confirmed")
	check(queue.snapshot().stop_reason == "Job exceeded its time limit", "timeout reason")
	check(queue.append("third", "fixture", {}, validate).sequence == 3, "append while stopped")
	executor.tick()
	check(workers.size() == 2, "no dispatch after timeout")
	check(queue.resolve(second.id, "skip"), "skip timed out job")
	check(queue.set_paused(false), "resume after skip")
	executor.tick()
	workers.back().finish_on_cancel = true
	check(executor.cancel_current(), "cancel current")
	executor.tick()
	check(queue.snapshot().jobs[2].state == "completed", "completion racing cancellation preserved")
	check(queue.snapshot().paused, "completion racing cancellation pauses dispatch")
	queue.close()
	print("job executor failures: ", failures)
	quit(1 if failures else 0)
