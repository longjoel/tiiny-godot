@tool
extends EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _unused_publish(_job: Dictionary, _artifact: Dictionary) -> Dictionary:
	return {"error": "Not used by append fixture"}

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
	if mode != "chat_restore":
		var lease: String = jobs.acquire_device(self, "fixture")
		if lease.is_empty() or chat._acquire_device("fixture chat") or jobs.release_device(self, "wrong") or not jobs.release_device(self, lease):
			_fail("Shared device lease did not exclude competing owners")
			return
		if not chat._acquire_device("fixture chat"):
			_fail("Chat could not acquire released device lease")
			return
		var model_manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
		if model_manager == null or model_manager._acquire_device("fixture models"):
			_fail("Model manager raced a chat lease")
			return
		chat._release_device()
		if not model_manager._acquire_device("fixture models"):
			_fail("Model manager could not acquire released device lease")
			return
		model_manager._release_device()
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
		var revision: Variant = JSON.parse_string(chat._scene_revision_tool())
		if not revision is Dictionary or revision.get("scene_path") != "res://target.tscn":
			_fail("Chat could not inspect the saved scene")
			return
		var attachment: Variant = JSON.parse_string(chat._append_job_tool({"operation": "attach_tree_to_scene", "artifact_id": accepted.id + ":tree", "scene_path": revision.scene_path, "scene_sha256": revision.scene_sha256, "parent_path": ".", "node_name": "Tree"}))
		if not attachment is Dictionary or attachment.get("sequence") != 2:
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
		var orphan := Node.new()
		if jobs.acquire_device(orphan, "orphan fixture").is_empty():
			_fail("Could not acquire orphan fixture lease")
			return
		orphan.free()
		if not jobs.acquire_device(self, "competing fixture").is_empty():
			_fail("An orphaned lease was silently released")
			return
	elif mode in ["scene_recovery", "scene_prepare"]:
		EditorInterface.open_scene_from_path("res://target.tscn")
		for i in range(200):
			if EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == "res://target.tscn":
				break
			await get_tree().create_timer(0.05).timeout
		var scene := EditorInterface.get_edited_scene_root()
		if scene == null:
			_fail("Recovery scene did not open")
			return
		var store: RefCounted = jobs.get("queue")
		var tree: Dictionary = jobs.append_job("recovery-tree", "create_tree", {"destination": "res://assets/tree.png", "timeout_ms": 30000})
		var deadline := Time.get_ticks_msec() + 30000
		while jobs.get_job_status(tree.id).get("state") in ["queued", "running"] and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		var tree_job: Dictionary = jobs.get_job_status(tree.id)
		if tree_job.get("state") != "completed":
			_fail("Recovery tree failed")
			return
		store.set_paused(true)
		var revision := FileAccess.get_sha256("res://target.tscn")
		var parameters := {"artifact_id": tree.id + ":tree", "scene_path": "res://target.tscn", "scene_sha256": revision, "parent_path": ".", "node_name": "Recovered", "timeout_ms": 30000}
		var accepted: Dictionary = jobs.append_job("recover-saved", "attach_tree_to_scene", parameters)
		store.set_paused(false)
		store.start_next()
		var token := "a".repeat(32)
		var target := {"scene_path": parameters.scene_path, "scene_sha256": revision, "parent_path": ".", "node_name": "Recovered", "artifact_id": parameters.artifact_id, "artifact_sha256": tree_job.result.artifact.sha256, "mutation_token": token}
		if not store.mutation(accepted.id, "prepared", target):
			_fail("Could not prepare interrupted scene")
			return
		var sprite := Sprite2D.new()
		sprite.name = "Recovered"
		sprite.texture = ResourceLoader.load("res://assets/tree.png")
		sprite.set_meta("_tiiny_job_token", token)
		scene.add_child(sprite)
		sprite.owner = scene
		EditorInterface.mark_scene_as_unsaved()
		if EditorInterface.save_scene() != OK:
			_fail("Could not save recovery fixture")
			return
		if mode == "scene_prepare":
			print("Built-in Jobs scene_prepare passed")
			get_tree().quit(0)
			return
		var root_path := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
		var queue_path := root_path.path_join(".tiiny/jobs/queue.json")
		store.close()
		if not store.open(queue_path, root_path):
			_fail("Could not reopen interrupted queue")
			return
		var verifier: RefCounted = jobs.get("attach_script").new(store, root_path)
		var verified: Dictionary = verifier.reconcile(jobs.get_job_status(accepted.id))
		if not verified.get("ok", false) or jobs.get_job_status(accepted.id).get("state") != "completed" or not store.snapshot().paused:
			_fail("Saved attachment reconciliation failed: " + str(verified))
			return
		parameters.scene_sha256 = FileAccess.get_sha256("res://target.tscn")
		parameters.node_name = "Absent"
		var absent: Dictionary = jobs.append_job("recover-absent", "attach_tree_to_scene", parameters)
		store.set_paused(false)
		store.start_next()
		target.scene_sha256 = parameters.scene_sha256
		target.node_name = "Absent"
		target.mutation_token = "b".repeat(32)
		store.mutation(absent.id, "prepared", target)
		store.close()
		store.open(queue_path, root_path)
		verified = verifier.reconcile(jobs.get_job_status(absent.id))
		if not verified.get("ok", false) or jobs.get_job_status(absent.id).get("state") != "failed":
			_fail("Unchanged scene reconciliation failed: " + str(verified))
			return
		if not store.resolve(absent.id, "skip") or not store.snapshot().paused:
			_fail("Verified no-effect job did not require a decision")
			return
		parameters.scene_sha256 = FileAccess.get_sha256("res://target.tscn")
		parameters.node_name = "Alien"
		var ambiguous: Dictionary = jobs.append_job("recover-ambiguous", "attach_tree_to_scene", parameters)
		store.set_paused(false)
		store.start_next()
		target.scene_sha256 = parameters.scene_sha256
		target.node_name = "Alien"
		target.mutation_token = "c".repeat(32)
		store.mutation(ambiguous.id, "prepared", target)
		var unrelated := Sprite2D.new()
		unrelated.name = "Alien"
		scene.add_child(unrelated)
		unrelated.owner = scene
		EditorInterface.mark_scene_as_unsaved()
		EditorInterface.save_scene()
		store.close()
		store.open(queue_path, root_path)
		verified = verifier.reconcile(jobs.get_job_status(ambiguous.id))
		if verified.get("ok", false) or jobs.get_job_status(ambiguous.id).get("state") != "interrupted":
			_fail("Ambiguous scene was falsely reconciled")
			return
	elif mode == "worker_append":
		var store: RefCounted = jobs.get("queue")
		store.set_paused(true)
		var first: Variant = JSON.parse_string(chat._append_job_tool({"operation": "create_tree", "destination": "res://assets/first.png", "followup_destination": "res://assets/followup.png"}))
		var second: Dictionary = jobs.append_job("worker-second", "create_tree", {"destination": "res://assets/second.png", "timeout_ms": 30000})
		if not first is Dictionary or first.get("sequence") != 1 or second.get("sequence") != 2:
			_fail("Worker fixture submissions were not accepted in order")
			return
		store.set_paused(false)
		var deadline := Time.get_ticks_msec() + 30000
		while Time.get_ticks_msec() < deadline:
			var state: Dictionary = store.snapshot()
			if state.jobs[0].state in ["failed", "interrupted"] or (state.jobs.size() == 3 and state.jobs[2].state in ["completed", "failed", "interrupted"]):
				break
			await get_tree().create_timer(0.05).timeout
		var state: Dictionary = store.snapshot()
		if state.jobs.size() != 3 or state.jobs[0].state != "completed" or state.jobs[1].state != "completed" or state.jobs[2].state != "completed":
			_fail("Worker append did not complete in order: " + str(state))
			return
		if state.jobs[0].result.appended_jobs[0].id != state.jobs[2].id or state.jobs[2].parameters.destination != "res://assets/followup.png":
			_fail("Worker append acknowledgment was not retained")
			return
		var root_path := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
		var work := root_path.path_join(".godot/tiiny/asset_jobs").path_join(first.id + "-1")
		var worker: RefCounted = jobs.get("worker_script").new(work, OS.get_executable_path(), _unused_publish, Callable(jobs, "append_job"))
		worker.job = state.jobs[0]
		var replay: Dictionary = worker._accept_append_requests(DirAccess.open(work))
		if replay.get("accepted", []).size() != 1 or replay.accepted[0].id != state.jobs[2].id or store.snapshot().jobs.size() != 3:
			_fail("Worker append replay was not deduplicated")
			return
		var requests := FileAccess.open(work.path_join("append_requests.json"), FileAccess.WRITE)
		requests.store_string(JSON.stringify({"requests": [{"operation": "create_tree", "parameters": {"destination": "res://../escape.png", "timeout_ms": 60000}}]}))
		requests.close()
		if not worker._accept_append_requests(DirAccess.open(work)).has("error") or store.snapshot().jobs.size() != 3:
			_fail("Invalid worker append was accepted")
			return
		worker.job.id = "fresh-worker-fixture"
		worker.job.parameters.followup_destination = "res://../escape.png"
		if not worker._accept_append_requests(DirAccess.open(work)).has("error") or store.snapshot().jobs.size() != 3:
			_fail("Worker append bypassed the shared path validator")
			return
	elif mode == "scene_restore":
		EditorInterface.open_scene_from_path("res://target.tscn")
		for i in range(200):
			if EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == "res://target.tscn":
				break
			await get_tree().create_timer(0.05).timeout
		var restored: Dictionary = jobs.get("queue").snapshot()
		var interrupted: Dictionary = restored.jobs.back()
		if interrupted.state != "interrupted":
			_fail("Scene job was not interrupted on restart")
			return
		var root_path := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
		var verifier: RefCounted = jobs.get("attach_script").new(jobs.get("queue"), root_path)
		var verified: Dictionary = verifier.reconcile(interrupted)
		if not verified.get("ok", false) or jobs.get_job_status(interrupted.id).get("state") != "completed" or not jobs.get("queue").snapshot().paused:
			_fail("Scene recovery after restart failed: " + str(verified))
			return
		if EditorInterface.get_edited_scene_root().get_child_count() != 1:
			_fail("Recovery duplicated or lost the saved node")
			return
	elif mode == "resource_cancel":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		var result: Array = []
		fake.generate_shape_for_dialog("Cancelled polygon", func(shape, error): result.assign([shape, error]))
		var resource: Dictionary = jobs.get("queue").snapshot().jobs.back()
		var deadline := Time.get_ticks_msec() + 10000
		while fake.resource_submissions.is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.resource_submissions.is_empty() or not jobs.get("executor").cancel_current():
			_fail("Could not cancel running resource job")
			return
		var late := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": '{"points":[[0,0],[32,0],[0,32]]}'}}]}).to_utf8_buffer()
		fake.resource_submissions[0].request_completed.emit(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), late)
		while result.is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if result.size() != 2 or result[0] != null or str(result[1]).is_empty() or jobs.get_job_status(resource.id).get("state") != "interrupted":
			_fail("Cancelled resource accepted a late result or failed to stop")
			return
	elif mode == "chat_restore":
		var restored: Dictionary = jobs.get("queue").snapshot()
		if restored.jobs.back().state != "interrupted" or not restored.jobs.back().attempts.back().get("device_started", false):
			_fail("Interrupted device job was not restored")
			return
		if not jobs.acquire_device(self, "after restart").is_empty():
			_fail("Restart allowed new device work before reconciliation")
			return
	elif mode == "chat":
		var fake = load("res://fake_queued_chat.gd").new()
		add_child(fake)
		fake.jobs_service = jobs
		jobs.chat_service = fake
		var store: RefCounted = jobs.get("queue")
		if not store.set_paused(true):
			_fail("Could not pause queue")
			return
		fake.prompt.text = "Original request"
		fake.context_marker = "original"
		fake._generate()
		var snapshot: Dictionary = store.snapshot()
		if snapshot.jobs.size() != 1 or snapshot.jobs[0].operation != "chat_turn" or snapshot.jobs[0].state != "queued":
			_fail("Chat was not durably queued: " + str(snapshot))
			return
		if JSON.stringify(snapshot).contains("fixture-queued-secret"):
			_fail("Chat credentials were stored in the queue")
			return
		var id: String = snapshot.jobs[0].id
		var before_chat: Dictionary = jobs.append_job("before-chat-finish", "create_tree", {"destination": "res://assets/before.png", "timeout_ms": 30000})
		if before_chat.get("sequence") != 2:
			_fail("Job appended behind chat was not ordered")
			return
		fake.prompt.text = "Changed after acceptance"
		fake.context_marker = "changed"
		await get_tree().create_timer(0.2).timeout
		if not fake.submissions.is_empty():
			_fail("Paused chat dispatched early")
			return
		store.set_paused(false)
		var deadline := Time.get_ticks_msec() + 10000
		while fake.submissions.size() < 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 1:
			_fail("Queued chat did not dispatch")
			return
		if str(fake.submissions[0].messages.back().content) != "Original request":
			_fail("Classification did not use the accepted prompt")
			return
		var classified := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "general"}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), classified)
		await get_tree().process_frame
		while fake.submissions.size() < 2 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() < 2:
			_fail("Classified chat did not dispatch an answer")
			return
		var messages: Array = fake.submissions[1].messages
		var answer_text := str(messages.back().content)
		if not answer_text.contains("Original request") or answer_text.contains("Changed after acceptance") or not answer_text.contains("Marker: original"):
			_fail("Queued chat did not retain accepted context")
			return
		var tool_call := {"id": "append-during-chat", "type": "function", "function": {"name": "append_job", "arguments": JSON.stringify({"operation": "create_tree", "destination": "res://assets/during.png"})}}
		var tool_reply := JSON.stringify({"choices": [{"message": {"role": "assistant", "tool_calls": [tool_call]}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), tool_reply)
		await get_tree().process_frame
		var tool_result: Variant = JSON.parse_string(fake.turn_messages.back().content)
		if not tool_result is Dictionary or tool_result.get("sequence") != 3 or fake.submissions.size() != 3:
			_fail("Assistant append did not reach the queue tail")
			return
		var resource_callback: Array = []
		fake.generate_shape_for_dialog("Fixture polygon", func(shape, error): resource_callback.assign([shape, error]))
		snapshot = store.snapshot()
		var resource_id: String = snapshot.jobs.back().id
		if snapshot.jobs.back().operation != "resource_shape" or snapshot.jobs.back().sequence != 4 or not resource_callback.is_empty():
			_fail("Resource generation did not append behind current work")
			return
		var reply := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "Fixture answer"}}]}).to_utf8_buffer()
		await fake._request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), reply)
		while jobs.get_job_status(id).get("state") == "running" and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if jobs.get_job_status(id).get("state") != "completed" or jobs.get_job_status(id).result.response != "Fixture answer":
			_fail("Queued chat result was not committed")
			return
		while fake.resource_submissions.is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.resource_submissions.is_empty() or not resource_callback.is_empty():
			_fail("Resource callback ran before the queued request")
			return
		var shape_reply := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": '{"points":[[0,0],[32,0],[0,32]]}'}}]}).to_utf8_buffer()
		fake.resource_submissions[0].request_completed.emit(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), shape_reply)
		while resource_callback.is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if resource_callback.size() != 2 or not resource_callback[0] is ConvexPolygonShape2D or jobs.get_job_status(resource_id).get("state") != "completed":
			_fail("Resource result was not validated and committed before callback")
			return
		fake.prompt.text = "Failing request"
		var previous_submissions: int = fake.submissions.size()
		fake._generate()
		snapshot = store.snapshot()
		var failed_id: String = snapshot.jobs.back().id
		while fake.submissions.size() <= previous_submissions and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if fake.submissions.size() <= previous_submissions:
			_fail("Later chat did not dispatch after preceding jobs")
			return
		await fake._request_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
		while jobs.get_job_status(failed_id).get("state") == "running" and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.05).timeout
		if jobs.get_job_status(failed_id).get("state") != "interrupted" or store.resolve(failed_id, "retry"):
			_fail("Unknown device outcome did not stop for reconciliation")
			return
		if not jobs.acquire_device(self, "after timeout").is_empty():
			_fail("Device lease was released despite an uncertain remote outcome")
			return
	elif mode in ["stale", "missing"]:
		EditorInterface.open_scene_from_path("res://target.tscn")
		for i in range(200):
			if EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == "res://target.tscn":
				break
			await get_tree().create_timer(0.05).timeout
		var scene := EditorInterface.get_edited_scene_root()
		if scene == null or scene.scene_file_path != "res://target.tscn":
			_fail("Scene failed to open")
			return
		var path := "res://assets/tree.png"
		if mode == "missing":
			var conflict := FileAccess.open(path, FileAccess.WRITE)
			conflict.store_string("existing file")
			conflict.close()
		var tree: Dictionary = jobs.append_job("tree", "create_tree", {"destination": path, "timeout_ms": 30000})
		var revision := "0".repeat(64) if mode == "stale" else FileAccess.get_sha256("res://target.tscn")
		var attach: Dictionary = jobs.append_job("attach", "attach_tree_to_scene", {"artifact_id": tree.id + ":tree", "scene_path": "res://target.tscn", "scene_sha256": revision, "parent_path": ".", "node_name": "Tree", "timeout_ms": 30000})
		var deadline := Time.get_ticks_msec() + 40000
		var watched: String = attach.id if mode == "stale" else tree.id
		while Time.get_ticks_msec() < deadline and jobs.get_job_status(watched).get("state") in ["queued", "running"]:
			await get_tree().create_timer(0.05).timeout
		if jobs.get_job_status(watched).get("state") != "failed":
			_fail("Expected job failure did not occur")
			return
		if mode == "missing":
			var store: RefCounted = jobs.get("queue")
			if not store.resolve(tree.id, "skip") or not store.set_paused(false):
				_fail("Could not explicitly skip failed tree")
				return
			while Time.get_ticks_msec() < deadline and jobs.get_job_status(attach.id).get("state") in ["queued", "running"]:
				await get_tree().create_timer(0.05).timeout
		var result: Dictionary = jobs.get_job_status(attach.id)
		if result.get("state") != "failed" or scene.has_node("Tree"):
			_fail("Invalid attachment mutated the scene: " + str(result))
			return
		if mode == "stale" and not result.result.error.contains("changed"):
			_fail("Stale scene diagnostic missing")
			return
		if mode == "missing" and not result.result.error.contains("missing"):
			_fail("Missing artifact diagnostic missing")
			return
	else:
		_fail("Unknown fixture mode")
		return
	print("Built-in Jobs %s passed" % mode)
	get_tree().quit(0)
