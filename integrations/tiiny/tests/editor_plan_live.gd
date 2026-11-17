@tool
extends EditorPlugin

## Gated live sample: the warm coding model must decompose a request with
## submit_plan, run dependent task jobs that return submit_result records, and
## let the deferred join compose the final answer. This is one tool-choice
## trace, not a success-rate evaluation.

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _run() -> void:
	for index in range(25):
		await get_tree().process_frame
	var dock := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
	var jobs := get_tree().get_first_node_in_group("tiiny_job_manager")
	if dock == null or manager == null or jobs == null or not jobs.available:
		_fail("Tiiny dock or manager unavailable")
		return
	await manager.refresh_device()
	if not manager.connected:
		_fail("Live device not connected: " + manager.message)
		return
	var models: Dictionary = manager.snapshot.get("models", {})
	var loaded: Array = manager.snapshot.get("loaded", {}).keys()
	var coding := ""
	for id in loaded:
		if manager.Planner.suitable("coding_model", models.get(id, {})):
			coding = str(id)
			break
	if coding.is_empty():
		_fail("No warm compatible coding model")
		return
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("tiiny_ai/models/coding_model", coding)
	var max_context := int(models.get(coding, {}).get("max_context", 0))
	settings.set_setting("tiiny_ai/models/context_tokens", max_context if max_context > 0 else 32768)
	settings.set_setting("tiiny_ai/advanced/request_timeout_seconds", 300)
	settings.set_setting("tiiny_ai/advanced/tool_mode", "editor")
	await manager.refresh_device()
	var warm_before: Array = manager.snapshot.get("loaded", {}).keys()
	warm_before.sort()

	dock.prompt.text = "Use submit_plan with exactly two tasks. Task id first has no dependencies and asks you to state in one sentence why a Marker2D is useful. Task id second depends on first and asks you to name one Godot node type suggested by the first result. Each task must finish by calling submit_result with status completed. Do not edit the scene, do not use any image or shell tool, and do not answer in text before submit_plan."
	var before_submit: int = jobs.queue.snapshot().jobs.size()
	dock.call("_generate")
	var queued: Array = jobs.queue.snapshot().jobs
	if queued.size() != before_submit + 1:
		_fail("Live plan turn was not submitted: " + dock.status.text)
		return
	var deadline := Time.get_ticks_msec() + 1200000
	var plan_root := ""
	var join_id := ""
	while Time.get_ticks_msec() < deadline:
		for job in jobs.queue.snapshot().jobs:
			if bool(job.get("result", {}).get("plan_pending", false)) and job.get("result", {}).has("join_job"):
				plan_root = str(job.id)
				join_id = str(job.result.join_job)
				break
		if not plan_root.is_empty():
			var join_job: Dictionary = jobs.get_job_status(join_id)
			if str(join_job.get("state", "")) in ["completed", "failed", "cancelled"]:
				break
		await get_tree().create_timer(0.25).timeout
	if plan_root.is_empty():
		_fail("The live model did not submit a completed plan. Jobs: " + str(jobs.queue.snapshot().jobs) + " status: " + dock.status.text)
		return
	var root: Dictionary = jobs.get_job_status(plan_root)
	var join: Dictionary = jobs.get_job_status(join_id)
	if str(join.get("state", "")) != "completed":
		_fail("The plan join did not complete: " + str(join))
		return
	if Array(root.get("result", {}).get("children", [])).size() != 2:
		_fail("The live plan did not run two children: " + str(root))
		return
	var completed := 0
	for child_id in root.result.children:
		var child: Dictionary = jobs.get_job_status(str(child_id))
		if child.get("result", {}).has("structured_result"):
			completed += 1
	if completed != 2:
		_fail("The live plan children did not return structured results: " + str(root))
		return
	if str(root.get("result", {}).get("plan_rollup", "")) not in ["completed", "partial"]:
		_fail("The live plan rollup was not resolved: " + str(root.get("result", {})))
		return
	if str(join.get("result", {}).get("response", "")).strip_edges().is_empty():
		_fail("The live plan join produced no final answer")
		return
	await manager.refresh_device()
	var warm_after: Array = manager.snapshot.get("loaded", {}).keys()
	warm_after.sort()
	if warm_after != warm_before:
		_fail("Live plan turn changed model residency")
		return
	print("Live plan trace passed with ", coding, "; jobs: ", jobs.queue.snapshot().jobs, "; final: ", str(join.get("result", {}).get("response", "")).left(800))
	get_tree().quit(0)
