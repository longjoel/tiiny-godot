extends SceneTree

const Waiter = preload("res://integrations/tiiny/tests/live_turn_wait.gd")

class FakeJobs extends Node:
	var reads := 0
	var fail_child := false
	func get_job_status(id: String) -> Dictionary:
		reads += 1
		if id == "first":
			return {"state": "completed", "result": {"continued": true, "next_job": "second"}}
		if id == "second" and reads < 3:
			return {"state": "running", "result": {}}
		if id == "second":
			return {"state": "failed" if fail_child else "completed", "result": {"response": "done"}}
		return {"error": "unknown job"}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var fixture := Waiter.new()
	var jobs := FakeJobs.new()
	if not await fixture.wait_for_turn(self, jobs, "first", 5000) or jobs.reads < 3:
		push_error("Turn waiter returned before the final continuation completed")
		quit(1)
		return
	jobs.reads = 0
	jobs.fail_child = true
	if await fixture.wait_for_turn(self, jobs, "first", 5000):
		push_error("Turn waiter reported success for a failed continuation")
		quit(1)
		return
	if not fixture.reason.contains("second failed"):
		push_error("Turn waiter omitted the terminal job state: " + fixture.reason)
		quit(1)
		return
	jobs.free()
	print("Live turn waiter fixture passed")
	quit(0)
