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

class ContinuationWorker extends RefCounted:
	var validator: Callable
	var operation := "chat_turn"
	func _init(p_validator: Callable, p_operation := "chat_turn") -> void:
		validator = p_validator
		operation = p_operation
	func start(_job: Dictionary) -> String:
		return ""
	func poll() -> Dictionary:
		return {"state": "completed", "result": {"response": ""}, "continuation": {"step": 2}, "continuation_operation": operation}
	func cancel() -> void:
		pass

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
	var handoff_path := root.path_join("executor-handoff.json")
	if FileAccess.file_exists(handoff_path):
		DirAccess.remove_absolute(handoff_path)
	var handoff = Queue.new()
	check(handoff.open(handoff_path, "executor-handoff"), "open handoff queue")
	var parent: Dictionary = handoff.append("parent", "fixture", {}, validate)
	var accept_chat := func(operation: String, parameters: Dictionary) -> String:
		return "" if operation == "chat_turn" and parameters.get("step") == 2 else "invalid"
	var factory := func(_job: Dictionary) -> RefCounted:
		return ContinuationWorker.new(accept_chat)
	var handoff_executor = Executor.new(handoff, factory, get_clock)
	handoff_executor.tick()
	check(handoff_executor.cancel_current(), "cancel racing handoff")
	handoff_executor.tick()
	var snapshot: Dictionary = handoff.snapshot()
	check(snapshot.jobs[0].state == "completed" and snapshot.jobs[0].result.next_job == snapshot.jobs[1].id, "completed handoff is preserved when cancellation races it")
	check(snapshot.paused and handoff.start_next().is_empty(), "cancel racing completion pauses the successor")
	check(not handoff.finish_with_continuation(parent.id, {}, {"step": 2}, accept_chat), "executor cannot commit a duplicate successor")
	handoff.close()
	var typed_path := root.path_join("executor-typed-handoff.json")
	if FileAccess.file_exists(typed_path):
		DirAccess.remove_absolute(typed_path)
	var typed = Queue.new()
	check(typed.open(typed_path, "executor-typed-handoff"), "open typed handoff queue")
	typed.append("parent", "fixture", {}, validate)
	var accept_tool := func(operation: String, parameters: Dictionary) -> String:
		return "" if operation == "tool_fixture" and parameters.get("step") == 2 else "invalid"
	var typed_factory := func(_job: Dictionary) -> RefCounted:
		return ContinuationWorker.new(accept_tool, "tool_fixture")
	var typed_executor = Executor.new(typed, typed_factory, get_clock)
	typed_executor.tick()
	typed_executor.tick()
	var typed_snapshot: Dictionary = typed.snapshot()
	check(typed_snapshot.jobs.size() == 2 and typed_snapshot.jobs[1].operation == "tool_fixture" and typed_snapshot.jobs[0].result.next_job == typed_snapshot.jobs[1].id, "executor commits a validated tool successor")
	typed.close()
	print("job executor failures: ", failures)
	quit(1 if failures else 0)
