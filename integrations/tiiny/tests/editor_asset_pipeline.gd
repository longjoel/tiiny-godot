@tool
extends EditorPlugin

class FakeManager extends Node:
	var jobs: Node
	var external_model_job_id := ""
	var model_job_cancelled := false
	var cancel_observed := false
	var image_loaded := false
	var wait_for_cancel := false
	var fail_restore := false
	var operations: Array = []
	func is_ready() -> bool: return true
	func is_model_loaded(model: String) -> bool: return image_loaded if model == "auto-image" else true
	func cancel_model_job(id: String) -> bool:
		if id != external_model_job_id: return false
		model_job_cancelled = true
		cancel_observed = true
		return true
	func ensure_model_loaded_for_job(_role: String, model: String, id: String, owner: Object, token: String) -> Dictionary:
		if not jobs.begin_model_operation(owner, token, id, "load", model, "a".repeat(64)):
			return {"ok": false, "error": "Could not journal load"}
		operations.append("load")
		if wait_for_cancel:
			while not model_job_cancelled:
				await get_tree().create_timer(0.05).timeout
			return {"ok": false, "uncertain": true, "error": "Cancelled during model load"}
		image_loaded = true
		if not jobs.queue.verify_device_operation(id): return {"ok": false, "uncertain": true}
		return {"ok": true, "already_loaded": false, "identity": "a".repeat(64)}
	func restore_configured_set_for_job(_identity: String, id: String, owner: Object, token: String) -> Dictionary:
		if not jobs.begin_model_operation(owner, token, id, "unload", "auto-image", "a".repeat(64)):
			return {"ok": false, "error": "Could not journal restore", "uncertain": true}
		operations.append("unload")
		if fail_restore:
			return {"ok": false, "uncertain": true, "error": "Fixture restore outcome unknown"}
		image_loaded = false
		return {"ok": jobs.queue.verify_device_operation(id)}

func _enter_tree() -> void:
	_run.call_deferred()

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _wait_job(jobs: Node, id: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		var record: Dictionary = jobs.get_job_status(id)
		if record.get("state", "") in ["completed", "failed", "interrupted", "cancelled"]: return record
		await get_tree().create_timer(0.05).timeout
	return jobs.get_job_status(id)

func _run() -> void:
	for index in range(30): await get_tree().process_frame
	var jobs: Node = get_tree().get_first_node_in_group("tiiny_job_manager")
	var real_dock: Node = get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	var real_manager: Node = get_tree().get_first_node_in_group("tiiny_setup_manager")
	if jobs == null or real_dock == null or real_manager == null or not jobs.available:
		_fail("Fixture editor services are unavailable"); return
	jobs.queue.set_paused(true)
	real_manager.remove_from_group("tiiny_setup_manager")
	var manager := FakeManager.new()
	manager.jobs = jobs
	get_tree().root.add_child(manager)
	manager.add_to_group("tiiny_setup_manager")
	var fake = load("res://fake_asset_pipeline_chat.gd").new()
	get_tree().root.add_child(fake)
	fake.jobs_service = jobs
	fake.workspace_inspector_script = real_dock.workspace_inspector_script
	fake.workspace_transactions_script = real_dock.workspace_transactions_script
	fake.workspace_registry_script = real_dock.workspace_registry_script
	fake.workspace_coding_script = real_dock.workspace_coding_script
	jobs.chat_service = fake
	var image := Image.create(2, 3, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	fake.reference_png = image.save_png_to_buffer()
	var scene := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	scene.add_child(mesh)
	mesh.owner = scene
	var document := GLTFDocument.new()
	var gltf := GLTFState.new()
	if document.append_from_scene(scene, gltf) != OK:
		_fail("Could not construct fixture model"); return
	scene.free()
	fake.fixture_glb = document.generate_buffer(gltf)
	if fake.fixture_glb.is_empty(): _fail("Could not encode fixture GLB"); return
	var identity := "http://fixture/v1|fixture|fixture-key".sha256_text()
	var producer: Dictionary = jobs.append_job("pipeline-image", "asset_generate", {"kind": "image", "model": "image", "connection_hash": identity, "timeout_ms": 60000, "text": "fixture"})
	if not producer.has("id"): _fail("Image producer was not queued: " + str(producer)); return
	var consumer: Dictionary = jobs.append_job("pipeline-3d", "asset_generate", {"kind": "image_to_3d", "model": "model", "connection_hash": identity, "timeout_ms": 60000, "image_artifact_id": str(producer.id) + ":image", "stage": "shape"})
	if not consumer.has("id"): _fail("3D consumer was not queued: " + str(consumer)); return
	jobs.queue.set_paused(false)
	var first: Dictionary = await _wait_job(jobs, producer.id)
	var second: Dictionary = await _wait_job(jobs, consumer.id)
	if first.get("state") != "completed" or second.get("state") != "failed" or fake.image_responses != 1 or fake.model_submissions != 1 or not fake.submitted_image_matches:
		_fail("Pipeline did not reach expected downstream failure: " + str(first) + " / " + str(second)); return
	var image_path := str(first.get("result", {}).get("artifact", ""))
	var image_hash := FileAccess.get_sha256(image_path)
	if image_hash.is_empty() or image_hash != str(first.result.get("artifact_sha256", "")):
		_fail("Producer artifact was not preserved after failure"); return
	if not jobs.queue.resolve(consumer.id, "retry") or not jobs.queue.set_paused(false):
		_fail("Could not retry downstream job"); return
	var retried: Dictionary = await _wait_job(jobs, consumer.id)
	if retried.get("state") != "completed" or Array(retried.get("attempts", [])).size() != 2 or Array(first.get("attempts", [])).size() != 1 or fake.image_responses != 1 or fake.model_submissions != 2 or FileAccess.get_sha256(image_path) != image_hash:
		_fail("Pipeline retry did not preserve the intermediate: " + str(retried)); return
	var output_path := str(retried.get("result", {}).get("artifact", ""))
	var packed: Variant = ResourceLoader.load(output_path, "", ResourceLoader.CACHE_MODE_REUSE)
	var imported: Node = packed.instantiate() if packed is PackedScene else null
	var contains_mesh := imported != null and not imported.find_children("*", "MeshInstance3D", true, false).is_empty()
	if imported != null: imported.free()
	if not contains_mesh or str(retried.result.get("image_artifact_id", "")) != str(producer.id) + ":image" or str(retried.result.get("image_sha256", "")) != image_hash:
		_fail("Retried 3D result or artifact lineage is invalid: " + str(retried)); return
	EditorInterface.get_editor_settings().set_setting("tiiny_ai/models/image_model", "auto-image")
	var accepted: Variant = JSON.parse_string(fake._append_job_tool({"operation": "asset_generate", "kind": "image", "text": "managed fixture"}))
	if not accepted is Dictionary or not accepted.get("accepted", false):
		_fail("The assistant could not queue managed image generation: " + str(accepted)); return
	var managed: Dictionary = accepted
	var managed_job: Dictionary = jobs.get_job_status(str(managed.id))
	if not bool(managed_job.get("parameters", {}).get("manage_model", false)) or int(managed_job.parameters.timeout_ms) != 7200000:
		_fail("Assistant image job did not select on-demand scheduling and its own budget"); return
	var managed_result: Dictionary = await _wait_job(jobs, str(managed.get("id", "")))
	if managed_result.get("state") != "completed" or manager.operations != ["load", "unload"] or manager.image_loaded or not FileAccess.file_exists(str(managed_result.get("result", {}).get("artifact", ""))):
		_fail("Managed image did not load, generate and restore: " + str(managed_result)); return
	if Array(managed_result.attempts.back().get("device_operations", [])).size() != 2 or jobs.device_recovery_pending():
		_fail("Managed image model operations were not verified and cleared"); return
	fake.fail_image = true
	var failed_image: Dictionary = jobs.append_job("managed-image-failure", "asset_generate", {"kind": "image", "model": "auto-image", "connection_hash": identity, "timeout_ms": 60000, "text": "failure fixture", "manage_model": true})
	var failed_result: Dictionary = await _wait_job(jobs, str(failed_image.get("id", "")))
	if failed_result.get("state") != "failed" or manager.image_loaded or manager.operations != ["load", "unload", "load", "unload"] or jobs.device_recovery_pending():
		_fail("Known image failure did not restore the warm set: " + str(failed_result)); return
	if not jobs.queue.resolve(failed_image.id, "skip") or not jobs.queue.set_paused(false):
		_fail("Could not resolve known image failure"); return
	fake.fail_image = false
	manager.fail_restore = true
	var restore_fail: Dictionary = jobs.append_job("managed-restore-failure", "asset_generate", {"kind": "image", "model": "auto-image", "connection_hash": identity, "timeout_ms": 60000, "text": "restore failure fixture", "manage_model": true})
	var restore_result: Dictionary = await _wait_job(jobs, str(restore_fail.get("id", "")))
	var retained := str(restore_result.get("result", {}).get("artifact", ""))
	if restore_result.get("state") != "interrupted" or not jobs.device_recovery_pending() or retained.is_empty() or not FileAccess.file_exists(retained) or FileAccess.get_sha256(retained) != str(restore_result.get("result", {}).get("artifact_sha256", "")):
		_fail("Restore failure did not preserve the generated image and uncertainty: " + str(restore_result)); return
	# Simulate the user's explicit device inspection and acknowledgement.
	manager.fail_restore = false
	manager.image_loaded = false
	if not jobs.acknowledge_model_uncertainty(restore_fail.id) or not jobs.queue.abandon(restore_fail.id) or not fake.release_uncertain_device(restore_fail.id) or not jobs.queue.set_paused(false):
		_fail("Could not acknowledge the simulated restore failure"); return
	fake.timeout_image = true
	var before_timeout_operations: int = manager.operations.size()
	var timed_out: Dictionary = jobs.append_job("managed-image-timeout", "asset_generate", {"kind": "image", "model": "auto-image", "connection_hash": identity, "timeout_ms": 60000, "text": "timeout fixture", "manage_model": true})
	var timeout_result: Dictionary = await _wait_job(jobs, str(timed_out.get("id", "")))
	if timeout_result.get("state") != "interrupted" or not jobs.device_recovery_pending() or not manager.image_loaded or manager.operations.slice(before_timeout_operations) != ["load"]:
		_fail("An uncertain image request initiated restoration or did not stop: " + str(timeout_result)); return
	fake.timeout_image = false
	manager.image_loaded = false
	if not jobs.acknowledge_model_uncertainty(timed_out.id) or not jobs.queue.abandon(timed_out.id) or not fake.release_uncertain_device(timed_out.id) or not jobs.queue.set_paused(false):
		_fail("Could not acknowledge the simulated image timeout"); return
	manager.wait_for_cancel = true
	var cancelled: Dictionary = jobs.append_job("managed-image-cancel", "asset_generate", {"kind": "image", "model": "auto-image", "connection_hash": identity, "timeout_ms": 60000, "text": "cancel fixture", "manage_model": true})
	var deadline := Time.get_ticks_msec() + 10000
	while manager.external_model_job_id.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if manager.external_model_job_id.is_empty() or not jobs.executor.cancel_current():
		_fail("Could not cancel image-model loading"); return
	var cancelled_result: Dictionary = await _wait_job(jobs, str(cancelled.get("id", "")))
	if cancelled_result.get("state") != "interrupted" or not jobs.device_recovery_pending() or not manager.cancel_observed:
		_fail("Cancelled model load did not preserve uncertainty: " + str(cancelled_result)); return
	print("Queued image-to-3D pipeline fixture passed.")
	get_tree().quit(0)
