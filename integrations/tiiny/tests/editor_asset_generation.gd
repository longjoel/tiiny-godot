@tool
extends EditorPlugin

const SPEECH_MODEL := "Supertone/supertonic-3"
const MODEL_3D := "Tencent/Hunyuan3d-2.1"

var dock: Node
var jobs: Node
var manager: Node
var settings: Object
var old_speech := ""
var old_3d := ""
var old_applied: Variant = null

func _enter_tree() -> void:
	_run.call_deferred()

func _frames(count: int) -> void:
	for index in range(count):
		await get_tree().process_frame

func _fail(message: String) -> void:
	push_error(message)
	_restore_settings()
	get_tree().quit(1)

func _restore_settings() -> void:
	if settings == null: return
	settings.set_setting("tiiny_ai/models/speech_model", old_speech)
	settings.set_setting("tiiny_ai/models/image_to_3d_model", old_3d)
	if old_applied != null:
		settings.set_setting("_tiiny_ai/applied_configuration", old_applied)

func _cli(arguments: String) -> int:
	var cli := str(settings.get_setting("tiiny_ai/advanced/cli_path"))
	var command := cli + " -y " + arguments
	return OS.execute("timeout", PackedStringArray(["--signal=TERM", "--kill-after=5s", "3600s", "script", "-q", "-e", "-c", command, "/dev/null"]))

func _wait_for(predicate: Callable, timeout_ms := 30000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()): return true
		await get_tree().create_timer(0.2).timeout
	return false

func _job_state(id: String) -> Dictionary:
	return jobs.get_job_status(id)

func _wait_job(id: String, timeout_ms := 120000) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var state := str(_job_state(id).get("state", ""))
		if state in ["completed", "failed", "cancelled", "interrupted", "skipped"]:
			return _job_state(id)
		await get_tree().create_timer(0.5).timeout
	return _job_state(id)

func _submit(arguments: Dictionary) -> Dictionary:
	var raw: Variant = dock.call("_append_job_tool", arguments)
	if raw is String and raw.begins_with("Error:"):
		_fail("Job submission failed: " + raw)
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	if not parsed is Dictionary or not parsed.get("accepted", false) or not parsed.get("id") is String:
		_fail("Job submission was not accepted: " + str(parsed))
		return {}
	return parsed

func _ensure_ready() -> bool:
	if manager.is_ready(): return true
	if not manager.busy: manager.refresh_device(true)
	return await _wait_for(func(): return manager.is_ready(), 30000)

func _wait_model_loaded(model: String) -> bool:
	if not manager.busy: manager.refresh_device(true)
	return await _wait_for(func(): return manager.is_model_loaded(model), 60000)

func _run() -> void:
	await _frames(10)
	dock = get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	jobs = get_tree().get_first_node_in_group("tiiny_job_manager")
	manager = get_tree().get_first_node_in_group("tiiny_setup_manager")
	if dock == null or jobs == null or manager == null: _fail("Tiiny dock/Jobs/manager is missing"); return
	settings = EditorInterface.get_editor_settings()
	old_speech = str(settings.get_setting("tiiny_ai/models/speech_model"))
	old_3d = str(settings.get_setting("tiiny_ai/models/image_to_3d_model"))
	old_applied = settings.get_setting("_tiiny_ai/applied_configuration")
	if not old_applied is Dictionary or old_applied.is_empty():
		var coding := str(settings.get_setting("tiiny_ai/models/coding_model"))
		var roles := {}
		for role in manager.ROLES:
			roles[role] = {"model": coding if role == "coding_model" else "", "context": 8192 if role == "coding_model" else 0, "warm": role == "coding_model"}
		settings.set_setting("_tiiny_ai/applied_configuration", {"roles": roles, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2})
	settings.set_setting("tiiny_ai/models/speech_model", SPEECH_MODEL)
	settings.set_setting("tiiny_ai/models/image_to_3d_model", MODEL_3D)
	if not await _ensure_ready(): _fail("Tiiny is not ready: " + str(manager.message)); return

	# Model swap: unload TTS, then load it through the queued scheduler while
	# the coding model stays resident.
	_cli("unload " + SPEECH_MODEL)
	var speech_schedule: Dictionary = _submit({"operation": "model_schedule", "role": "speech_model", "model": SPEECH_MODEL, "restore": false})
	var speech_loaded: Dictionary = await _wait_job(speech_schedule.id, 180000)
	var speech_ready: bool = await _wait_model_loaded(SPEECH_MODEL)
	if speech_loaded.state != "completed" or not speech_ready:
		_fail("Speech model swap did not complete: " + str(speech_loaded)); return
	if not manager.is_model_loaded(str(settings.get_setting("tiiny_ai/models/coding_model"))):
		_fail("Coding model was evicted during the speech model swap"); return

	# Generator-backed speech success.
	var speech_job: Dictionary = _submit({"operation": "asset_generate", "kind": "speech", "text": "Hello from the Tiiny live asset integration test."})
	var speech_result: Dictionary = await _wait_job(speech_job.id, 300000)
	if speech_result.state != "completed":
		_fail("Speech asset job failed: " + str(speech_result)); return
	var speech_path := str(speech_result.get("result", {}).get("artifact", ""))
	var speech_stream: Variant = ResourceLoader.load(speech_path, "", ResourceLoader.CACHE_MODE_REUSE)
	if not speech_stream is AudioStream or speech_stream.get_length() <= 0:
		_fail("Speech artifact did not import as a playable AudioStream: " + speech_path); return
	EditorInterface.open_scene_from_path("res://speech_scene.tscn")
	if not await _wait_for(func(): return EditorInterface.get_edited_scene_root() != null and EditorInterface.get_edited_scene_root().scene_file_path == "res://speech_scene.tscn", 15000):
		_fail("Speech scene did not open"); return
	if not dock.call("_ensure_workspace_registry"):
		_fail("Workspace transactions are unavailable for speech attachment"); return
	var transactions: RefCounted = dock.get("workspace_transactions")
	if transactions == null:
		_fail("Workspace transactions are missing"); return
	var attach: Dictionary = transactions.execute("import_generated_audio", {"path": speech_path, "player_name": "GeneratedSpeech"})
	var speech_root := EditorInterface.get_edited_scene_root()
	var player := speech_root.get_node_or_null("GeneratedSpeech") as AudioStreamPlayer
	if not attach.get("ok", false) or player == null or player.stream == null or player.stream.resource_path != speech_path:
		_fail("Generated speech was not attached to an audio player: " + str(attach)); return
	print("Live generated speech to audio player passed: ", speech_path)
	print("Live speech asset passed: ", speech_path, " duration=", speech_stream.get_length())
	if not speech_result.attempts.back().get("device_confirmed", false):
		_fail("Speech job did not record a confirmed device request"); return

	# Model swap for 3D, then a real reference-image-to-3D job.
	_cli("unload " + MODEL_3D)
	var model_schedule: Dictionary = _submit({"operation": "model_schedule", "role": "image_to_3d_model", "model": MODEL_3D, "restore": false})
	var model_loaded: Dictionary = await _wait_job(model_schedule.id, 300000)
	var model_ready: bool = await _wait_model_loaded(MODEL_3D)
	if model_loaded.state != "completed" or not model_ready:
		_fail("3D model swap did not complete: " + str(model_loaded)); return
	if not manager.is_model_loaded(str(settings.get_setting("tiiny_ai/models/coding_model"))):
		_fail("Coding model was evicted during the 3D model swap"); return
	# Deterministic downstream failure and confirmed cleanup.
	var failed_job: Dictionary = _submit({"operation": "asset_generate", "kind": "image_to_3d", "image_path": "res://missing-reference.png", "stage": "shape"})
	var failed_result: Dictionary = await _wait_job(failed_job.id, 60000)
	if failed_result.state != "failed" or not str(failed_result.get("result", {}).get("error", "")).contains("missing"):
		_fail("Missing reference did not fail clearly: " + str(failed_result)); return
	var recovery_lease: String = jobs.acquire_device(self, "after confirmed asset failure")
	if jobs.device_recovery_pending() or recovery_lease.is_empty():
		_fail("Confirmed asset failure retained the device lease"); return
	jobs.release_device(self, recovery_lease)
	if not jobs.queue.resolve(failed_job.id, "skip") or not jobs.queue.set_paused(false):
		_fail("Could not resolve the failed asset job"); return
	print("Live asset failure cleanup passed")

	var model_job: Dictionary = _submit({"operation": "asset_generate", "kind": "image_to_3d", "image_path": "res://reference.png", "stage": "shape"})
	var model_result: Dictionary = await _wait_job(model_job.id, 900000)
	if model_result.state != "completed":
		_fail("Reference-image-to-3D job failed: " + str(model_result)); return
	var model_path := str(model_result.get("result", {}).get("artifact", ""))
	var packed: Variant = ResourceLoader.load(model_path, "", ResourceLoader.CACHE_MODE_REUSE)
	var packed_instance: Node = packed.instantiate() if packed is PackedScene else null
	if packed_instance == null or packed_instance.find_children("*", "MeshInstance3D", true, false).is_empty():
		_fail("3D artifact did not import with a mesh: " + model_path); return
	print("Live 3D asset passed: ", model_path)

	# Cancellation: stop a running 3D task and require explicit acknowledgement.
	var cancel_job: Dictionary = _submit({"operation": "asset_generate", "kind": "image_to_3d", "image_path": "res://reference.png", "stage": "shape"})
	if not await _wait_for(func(): return _job_state(cancel_job.id).get("attempts", []).size() > 0 and _job_state(cancel_job.id).attempts.back().get("device_started", false), 60000):
		_fail("Cancellation target never started"); return
	if not jobs.executor.cancel_current(): _fail("Could not cancel the asset job"); return
	var cancelled: Dictionary = await _wait_job(cancel_job.id, 30000)
	if cancelled.state != "interrupted":
		_fail("Cancelled asset job did not become interrupted: " + str(cancelled)); return
	if not jobs.acknowledge_model_uncertainty(cancel_job.id) or not jobs.queue.abandon(cancel_job.id):
		_fail("Could not acknowledge the cancelled asset job"); return
	if dock.has_method("release_uncertain_device"): dock.release_uncertain_device(cancel_job.id)
	if not jobs.queue.set_paused(false): _fail("Could not resume after cancellation"); return
	print("Live asset cancellation/acknowledgement passed")

	_restore_settings()
	_cli("unload " + MODEL_3D)
	_cli("unload " + SPEECH_MODEL)
	print("Tiiny live asset generation passed.")
	get_tree().quit(0)

func _exit_tree() -> void:
	_restore_settings()
