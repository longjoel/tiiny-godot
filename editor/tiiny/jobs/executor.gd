@tool
extends RefCounted

# One executor owns one queue and one worker. A worker's completed response
# means its outputs have already been validated and committed, not merely that
# its process exited. Workers must expose start(job), poll(), and cancel().
var queue: RefCounted
var worker_factory: Callable
var worker: RefCounted
var current: Dictionary = {}
var stage := ""
var started_msec := 0
var deadline_msec := 0
var cancel_reason := ""
var clock: Callable
var ticking := false

func _init(p_queue: RefCounted, p_factory: Callable, p_clock: Callable = Callable()) -> void:
	queue = p_queue
	worker_factory = p_factory
	clock = p_clock if p_clock.is_valid() else Time.get_ticks_msec

# Called on the editor thread. Workers must not block in these methods.
func tick() -> void:
	# Editor import may pump the main loop while a poll is in progress.
	if ticking:
		return
	ticking = true
	_tick_impl()
	ticking = false

func _tick_impl() -> void:
	if worker != null:
		if deadline_msec > 0 and int(clock.call()) >= deadline_msec and cancel_reason.is_empty():
			_request_cancel("Job exceeded its time limit")
		var status: Variant = worker.poll()
		if not status is Dictionary or status.get("state") not in ["running", "completed", "failed", "cancelled"]:
			# An invalid reply cannot prove that the worker has stopped.
			stage = "Worker returned an invalid status; awaiting reconciliation"
			return
		stage = str(status.get("stage", status.state))
		if status.state == "running":
			return
		var result: Variant = status.get("result", {})
		if not result is Dictionary:
			result = {"error": "Worker returned an invalid result"}
			status.state = "failed"
		if not cancel_reason.is_empty():
			# A worker may have committed an effect before cancellation. Preserve
			# its completed result and pause before allowing any later dispatch.
			if status.state == "completed":
				if not queue.set_paused(true):
					return
			else:
				result["error"] = cancel_reason
				status.state = "failed" if cancel_reason != "Cancelled by user" else "cancelled"
		var finished := false
		if status.state == "completed" and status.get("plan") is Dictionary:
			if worker.get("validator") is Callable:
				var plan: Dictionary = status.plan
				var plan_result: Dictionary = result.duplicate(true)
				plan_result["plan_pending"] = true
				plan_result["plan"] = plan.get("plan", {})
				plan_result["join_turn"] = plan.get("join_turn", {})
				plan_result["plan_call"] = plan.get("plan_call", {})
				finished = queue.finish_with_plan(current.id, plan_result, plan.get("children", []), worker.validator)
			if not finished and queue.error.is_empty():
				status.state = "failed"
				result = {"error": "Could not commit the plan; no child jobs were queued."}
				finished = queue.finish(current.id, status.state, result)
		elif status.state == "completed" and status.get("continuation") is Dictionary:
			if worker.get("validator") is Callable:
				var operation: Variant = status.get("continuation_operation", "chat_turn")
				if operation is String and not operation.is_empty():
					finished = queue.finish_with_successor(current.id, result, operation, status.continuation, worker.validator)
			if not finished and queue.error.is_empty():
				status.state = "failed"
				result = {"error": "Could not commit the next turn step; no continuation was queued."}
				finished = queue.finish(current.id, status.state, result)
		else:
			finished = queue.finish(current.id, status.state, result)
		if finished:
			var finished_id: String = str(current.id)
			var finished_state: String = str(status.state)
			for job in queue.snapshot().jobs:
				if job.id == finished_id:
					finished_state = str(job.state)
					break
			if worker.has_method("committed"):
				worker.committed(finished_state)
			worker = null
			current = {}
			cancel_reason = ""
		return
	var job: Dictionary = queue.start_next()
	if job.is_empty():
		return
	current = job
	started_msec = int(clock.call())
	var timeout_ms: int = int(job.parameters.get("timeout_ms", 0))
	deadline_msec = started_msec + timeout_ms if timeout_ms > 0 else 0
	stage = "Starting"
	var candidate: Variant = worker_factory.call(job.duplicate(true)) if worker_factory.is_valid() else null
	if not candidate is RefCounted or not candidate.has_method("start") or not candidate.has_method("poll") or not candidate.has_method("cancel"):
		queue.finish(job.id, "failed", {"error": "No supported worker"})
		current = {}
		return
	worker = candidate
	var start_result: Variant = worker.start(job.duplicate(true))
	if start_result is String and not start_result.is_empty():
		# start() may return an error only if it started no external work.
		if queue.finish(job.id, "failed", {"error": start_result}):
			worker = null
			current = {}

func cancel_current() -> bool:
	if worker == null or not cancel_reason.is_empty():
		return false
	_request_cancel("Cancelled by user")
	return true

func _request_cancel(reason: String) -> void:
	cancel_reason = reason
	stage = "Stopping"
	worker.cancel()
