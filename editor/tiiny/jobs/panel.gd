@tool
extends VBoxContainer

signal log_message(message: String, message_type: int)

# Built-in script dependencies are injected before this node enters the tree.
var queue_script: Script
var executor_script: Script
var worker_script: Script
var publisher_script: Script
var attach_script: Script
var chat_service: Node
var queue: RefCounted
var executor: RefCounted
var root_path := ""
var available := false
var list: ItemList
var details: TextEdit
var summary: Label
var pause_button: Button
var cancel_button: Button
var retry_button: Button
var skip_button: Button
var reconcile_button: Button
var recovery_dialog: AcceptDialog
var elapsed_update := 0.0
var selected_id := ""
var recovery: RefCounted
var recovery_job: Dictionary = {}
var recovery_artifact: Dictionary = {}
var device_holder: WeakRef
var device_token := ""
var device_purpose := ""
var device_process_lock: RefCounted
var device_lock_path := ""

class ChatWorker extends RefCounted:
	var chat: WeakRef
	var job: Dictionary
	var polled := false
	var cancelled_before_start := false
	func _init(owner: Node) -> void:
		chat = weakref(owner)
	func start(value: Dictionary) -> String:
		job = value.duplicate(true)
		return ""
	func poll() -> Dictionary:
		var owner: Object = chat.get_ref()
		if not is_instance_valid(owner):
			return {"state": "running", "stage": "Chat unavailable; outcome requires recovery"}
		if cancelled_before_start:
			owner.cancel_pending_chat()
			return {"state": "cancelled", "result": {"error": "Cancelled before device execution"}}
		polled = true
		return owner.poll_queued_chat(job)
	func cancel() -> void:
		var owner: Object = chat.get_ref()
		if not polled:
			cancelled_before_start = true
		elif is_instance_valid(owner):
			owner.cancel_queued_chat(job.id)
	func committed(state: String) -> void:
		var owner: Object = chat.get_ref()
		if is_instance_valid(owner):
			owner.finalize_queued_chat(state)

class ResourceWorker extends RefCounted:
	var chat: WeakRef
	var job: Dictionary
	var polled := false
	var cancelled_before_start := false
	func _init(owner: Node) -> void:
		chat = weakref(owner)
	func start(value: Dictionary) -> String:
		job = value.duplicate(true)
		return ""
	func poll() -> Dictionary:
		var owner: Object = chat.get_ref()
		if not is_instance_valid(owner):
			return {"state": "running", "stage": "Resource handler unavailable; outcome requires recovery"}
		if cancelled_before_start:
			return {"state": "cancelled", "result": {"error": "Cancelled before device execution"}}
		polled = true
		return owner.poll_resource_job(job)
	func cancel() -> void:
		var owner: Object = chat.get_ref()
		if not polled:
			cancelled_before_start = true
		elif is_instance_valid(owner):
			owner.cancel_resource_job(job.id)
	func committed(state: String) -> void:
		var owner: Object = chat.get_ref()
		if is_instance_valid(owner):
			owner.finalize_resource_job(job.id, state)

func _ready() -> void:
	name = "Tiiny Jobs"
	add_to_group("tiiny_job_manager")
	_build_ui()
	root_path = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var editor_paths: Object = EditorInterface.get_editor_paths()
	if editor_paths == null:
		summary.text = "Jobs unavailable: editor data directory is unavailable"
		return
	var device_directory: String = editor_paths.get_data_dir().path_join("tiiny")
	if DirAccess.make_dir_recursive_absolute(device_directory) != OK:
		summary.text = "Jobs unavailable: cannot create the device coordination directory"
		return
	device_lock_path = device_directory.path_join("device")
	if queue_script == null or executor_script == null or worker_script == null or publisher_script == null or attach_script == null:
		summary.text = "Jobs unavailable: missing built-in components"
		return
	queue = queue_script.new()
	if not queue.open(root_path.path_join(".tiiny/jobs/queue.json"), root_path):
		summary.text = "Jobs unavailable: " + queue.error
		log_message.emit(summary.text, 2)
		return
	var work_root := root_path.path_join(".godot/tiiny/asset_jobs")
	if DirAccess.make_dir_recursive_absolute(work_root) != OK:
		summary.text = "Jobs unavailable: cannot create working directory"
		queue.close()
		return
	executor = executor_script.new(queue, _make_worker)
	available = true
	_start_recovery()
	_refresh()

func _exit_tree() -> void:
	if queue != null:
		queue.close()

func _build_ui() -> void:
	var actions := HBoxContainer.new()
	add_child(actions)
	pause_button = Button.new()
	pause_button.pressed.connect(_on_pause)
	actions.add_child(pause_button)
	cancel_button = Button.new()
	cancel_button.text = "Cancel current"
	cancel_button.pressed.connect(_on_cancel)
	actions.add_child(cancel_button)
	retry_button = Button.new()
	retry_button.text = "Retry"
	retry_button.pressed.connect(_on_retry)
	actions.add_child(retry_button)
	skip_button = Button.new()
	skip_button.text = "Skip"
	skip_button.pressed.connect(_on_skip)
	actions.add_child(skip_button)
	reconcile_button = Button.new()
	reconcile_button.text = "Check recovery"
	reconcile_button.pressed.connect(_on_reconcile)
	actions.add_child(reconcile_button)
	recovery_dialog = AcceptDialog.new()
	recovery_dialog.title = "Job recovery"
	add_child(recovery_dialog)
	summary = Label.new()
	add_child(summary)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	list = ItemList.new()
	list.custom_minimum_size = Vector2(260, 150)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.item_selected.connect(_on_selected)
	split.add_child(list)
	details = TextEdit.new()
	details.editable = false
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.custom_minimum_size = Vector2(300, 150)
	split.add_child(details)

func _validate(operation: String, parameters: Dictionary) -> String:
	if operation == "resource_shape":
		if parameters.size() != 4 or not parameters.get("description") is String or parameters.description.strip_edges().is_empty() or parameters.description.length() > 100000 or not parameters.get("model") is String or parameters.model.is_empty() or not parameters.get("connection_hash") is String or parameters.connection_hash.length() != 64 or not parameters.get("timeout_ms") is int or parameters.timeout_ms < 1000 or parameters.timeout_ms > 3600000:
			return "Invalid resource-generation request"
		return ""
	if operation == "chat_turn":
		return _validate_chat(parameters)
	if operation == "attach_tree_to_scene":
		return _validate_attachment(parameters)
	if operation != "create_tree":
		return "Unsupported job operation"
	if parameters.size() not in [2, 3] or not parameters.has("destination") or not parameters.has("timeout_ms") or (parameters.size() == 3 and not parameters.has("followup_destination")):
		return "A destination and time limit are required"
	var error := _validate_tree_path(parameters.destination)
	if not error.is_empty():
		return error
	if parameters.has("followup_destination"):
		error = _validate_tree_path(parameters.followup_destination)
		if not error.is_empty():
			return error
		if parameters.followup_destination == parameters.destination:
			return "The follow-up destination must be different"
	if not parameters.timeout_ms is int or parameters.timeout_ms < 1000 or parameters.timeout_ms > 300000:
		return "Invalid time limit"
	return ""

func _validate_tree_path(path: Variant) -> String:
	if not path is String or not path.begins_with("res://") or not path.ends_with(".png") or path.contains("\\"):
		return "Destination must be a res:// PNG path"
	var relative: String = path.trim_prefix("res://")
	for part in relative.split("/", true):
		if part.is_empty() or part.begins_with("."):
			return "Invalid destination path"
	if not DirAccess.dir_exists_absolute(root_path.path_join(relative).get_base_dir()):
		return "Destination folder does not exist"
	return ""

func _validate_chat(parameters: Dictionary) -> String:
	var strings := ["prompt", "context", "custom_prompt", "model", "connection_hash"]
	if parameters.size() != 7:
		return "Invalid chat job parameters"
	for key in strings:
		if not parameters.get(key) is String:
			return "Invalid chat job parameters"
	if parameters.prompt.strip_edges().is_empty() or parameters.prompt.length() > 100000 or parameters.context.length() > 100000 or parameters.model.is_empty() or parameters.connection_hash.length() != 64:
		return "Invalid chat request"
	if not parameters.get("conversation") is Array:
		return "Invalid chat context"
	if not parameters.get("timeout_ms") is int or parameters.timeout_ms < 1000 or parameters.timeout_ms > 3600000:
		return "Invalid time limit"
	if JSON.stringify(parameters).to_utf8_buffer().size() > 24 * 1024 * 1024:
		return "Chat context is too large to queue"
	return ""

func _validate_attachment(parameters: Dictionary) -> String:
	if parameters.size() != 6:
		return "Attachment requires an artifact, scene revision, parent and node name"
	for key in ["artifact_id", "scene_path", "scene_sha256", "parent_path", "node_name"]:
		if not parameters.get(key) is String or parameters[key].is_empty():
			return "Invalid attachment parameters"
	if not parameters.get("timeout_ms") is int or parameters.timeout_ms < 1000 or parameters.timeout_ms > 300000:
		return "Invalid time limit"
	if not parameters.artifact_id.ends_with(":tree") or parameters.artifact_id.length() > 128:
		return "Invalid artifact reference"
	if not parameters.scene_path.begins_with("res://") or not parameters.scene_path.ends_with(".tscn") or parameters.scene_path.contains("\\"):
		return "Invalid scene path"
	for component in parameters.scene_path.trim_prefix("res://").split("/", true):
		if component.is_empty() or component.begins_with("."):
			return "Invalid scene path"
	if parameters.scene_sha256.length() != 64 or not parameters.scene_sha256.is_valid_hex_number(false):
		return "Invalid scene revision"
	if parameters.parent_path != ".":
		for component in parameters.parent_path.split("/", true):
			if component.is_empty() or component in [".", ".."] or component.contains(":") or component.contains("\\"):
				return "Invalid parent path"
	if parameters.node_name.length() > 100 or parameters.node_name != parameters.node_name.validate_node_name() or parameters.node_name in [".", ".."]:
		return "Invalid node name"
	return ""

# User, assistant and reviewed worker adapters must call this same service.
func append_job(key: String, operation: String, parameters: Dictionary) -> Dictionary:
	if not available:
		return {"error": "Jobs unavailable"}
	if operation == "attach_tree_to_scene" and parameters.get("artifact_id") is String:
		var producer_id: String = parameters.artifact_id.trim_suffix(":tree")
		var producer: Dictionary = get_job_status(producer_id)
		if producer.get("operation") != "create_tree":
			return {"error": "Artifact must reference an accepted tree job"}
	var result: Dictionary = queue.append(key, operation, parameters, _validate)
	if result.has("id"):
		log_message.emit("Job %s accepted at position %d." % [result.id, result.sequence], 0)
		_refresh()
	return result

func get_job_status(id: String) -> Dictionary:
	if not available:
		return {"error": "Jobs unavailable"}
	for job in queue.snapshot().jobs:
		if job.id == id:
			return job
	return {"error": "Job not found"}

# All editor-owned device clients use this shared, nonblocking lease. It is
# intentionally separate from job dispatch: queued inference still needs to
# enter the FIFO, and a lease is not an alternative queue.
func acquire_device(owner: Object, purpose: String) -> String:
	if not available or not is_instance_valid(owner) or purpose.is_empty():
		return ""
	for job in queue.snapshot().jobs:
		if job.state == "interrupted" and not job.attempts.is_empty() and job.attempts.back().get("device_started", false):
			return ""
	# Losing the owner does not prove an in-flight device request stopped.
	# Keep the lease closed rather than handing the device to another client.
	if not device_token.is_empty():
		return ""
	# Every editor using the same Godot data directory holds this OS lock for
	# the whole operation, including its verification and terminal transition.
	var process_lock: RefCounted = ClassDB.instantiate("TiinyJobStorage")
	if process_lock == null or not process_lock.acquire(device_lock_path):
		return ""
	device_process_lock = process_lock
	device_holder = weakref(owner)
	device_token = Crypto.new().generate_random_bytes(16).hex_encode()
	device_purpose = purpose
	return device_token

func release_device(owner: Object, token: String) -> bool:
	if device_holder == null or device_holder.get_ref() != owner or token.is_empty() or token != device_token:
		return false
	device_holder = null
	device_token = ""
	device_purpose = ""
	if device_process_lock != null:
		device_process_lock.release()
		device_process_lock = null
	return true

func _make_worker(job: Dictionary) -> RefCounted:
	if job.operation == "resource_shape":
		return ResourceWorker.new(chat_service) if is_instance_valid(chat_service) else null
	if job.operation == "chat_turn":
		return ChatWorker.new(chat_service) if is_instance_valid(chat_service) else null
	if job.operation == "attach_tree_to_scene":
		return attach_script.new(queue, root_path)
	if job.operation != "create_tree":
		return null
	var attempt: int = job.attempts.back().number
	var path := root_path.path_join(".godot/tiiny/asset_jobs").path_join(job.id + "-" + str(attempt))
	var publisher: RefCounted = publisher_script.new(queue, root_path, EditorInterface.get_resource_filesystem())
	return worker_script.new(path, OS.get_executable_path(), publisher, Callable(self, "append_job"))

func _process(delta: float) -> void:
	if not available:
		return
	if recovery != null:
		var result: Dictionary = recovery.publish(recovery_job, recovery_artifact)
		if not result.get("pending", false):
			if not result.get("ok", false):
				log_message.emit("Job recovery stopped: " + str(result.get("error", "unknown error")), 2)
			recovery = null
			recovery_job = {}
			recovery_artifact = {}
	else:
		executor.tick()
	elapsed_update += delta
	if elapsed_update >= 0.25:
		elapsed_update = 0.0
		_refresh()

func _start_recovery() -> void:
	for job in queue.snapshot().jobs:
		if job.state != "interrupted" or job.attempts.is_empty() or not job.attempts.back().has("publication"):
			continue
		var candidate: RefCounted = publisher_script.new(queue, root_path, EditorInterface.get_resource_filesystem())
		var result: Dictionary = candidate.begin_recovery(job)
		if result.get("ok", false):
			recovery = candidate
			recovery_job = job
			recovery_artifact = result.artifact
		break

func _on_selected(index: int) -> void:
	selected_id = str(list.get_item_metadata(index))
	_refresh_details()

func _on_pause() -> void:
	if available:
		queue.set_paused(not queue.snapshot().paused)
		_refresh()

func _on_cancel() -> void:
	if available:
		executor.cancel_current()
		_refresh()

func _resolve(decision: String) -> void:
	if not available:
		return
	for job in queue.snapshot().jobs:
		if job.state in ["failed", "cancelled"]:
			queue.resolve(job.id, decision)
			break
	_refresh()

func _on_retry() -> void:
	_resolve("retry")

func _on_skip() -> void:
	_resolve("skip")

func _on_reconcile() -> void:
	if not available:
		return
	var message := "No interrupted scene attachment is available to check."
	for job in queue.snapshot().jobs:
		if job.state == "interrupted" and job.operation == "attach_tree_to_scene":
			var verifier: RefCounted = attach_script.new(queue, root_path)
			var result: Dictionary = verifier.reconcile(job)
			message = str(result.get("message", result.get("error", "Recovery could not be verified.")))
			break
	recovery_dialog.dialog_text = message
	recovery_dialog.popup_centered()
	log_message.emit("Job recovery: " + message, 0)
	_refresh()

func _refresh() -> void:
	if not available:
		return
	var state: Dictionary = queue.snapshot()
	var stopped: bool = not state.stop_reason.is_empty()
	var running: bool = not executor.current.is_empty()
	summary.text = "Stopped: " + state.stop_reason if stopped else ("Paused" if state.paused else ("Running: " + executor.stage if running else "Ready"))
	pause_button.text = "Resume" if state.paused else "Pause"
	pause_button.disabled = stopped
	cancel_button.disabled = not running
	var resolvable := false
	var scene_recovery := false
	for job in state.jobs:
		if job.state in ["failed", "cancelled"]:
			resolvable = true
		if job.state == "interrupted" and job.operation == "attach_tree_to_scene":
			scene_recovery = true
	retry_button.disabled = not resolvable
	skip_button.disabled = not resolvable
	reconcile_button.disabled = not scene_recovery
	list.clear()
	for job in state.jobs:
		list.add_item("%d  %s  —  %s" % [job.sequence, job.operation, job.state])
		var index := list.item_count - 1
		list.set_item_metadata(index, job.id)
		if job.id == selected_id:
			list.select(index)
	_refresh_details()

func _preview(text: Variant, limit := 400) -> String:
	var value := str(text).strip_edges()
	return value if value.length() <= limit else value.left(limit) + "…"

func _refresh_details() -> void:
	if not available:
		return
	var job := get_job_status(selected_id)
	if job.has("error"):
		details.text = "Select a job to see its details."
		return
	var lines := ["Job: " + str(job.id), "Operation: " + str(job.operation), "State: " + str(job.state), "Attempts: " + str(job.attempts.size())]
	if job.operation == "chat_turn":
		lines.append("Prompt: " + _preview(job.parameters.get("prompt", "")))
		lines.append("Model: " + str(job.parameters.get("model", "")))
	elif job.operation == "resource_shape":
		lines.append("Description: " + _preview(job.parameters.get("description", "")))
		lines.append("Model: " + str(job.parameters.get("model", "")))
	elif job.operation == "create_tree":
		lines.append("Destination: " + str(job.parameters.get("destination", "")))
		if job.parameters.has("followup_destination"):
			lines.append("Follow-up: " + str(job.parameters.get("followup_destination")))
	elif job.operation == "attach_tree_to_scene":
		lines.append("Scene: " + str(job.parameters.get("scene_path", "")))
		lines.append("Parent: " + str(job.parameters.get("parent_path", "")) + " · Node: " + str(job.parameters.get("node_name", "")))
	if job.state == "running":
		lines.append("Stage: " + executor.stage)
		lines.append("Elapsed: %.1f s" % ((Time.get_ticks_msec() - executor.started_msec) / 1000.0))
	if not job.result.is_empty():
		lines.append("Result: " + JSON.stringify(job.result, "  "))
	for attempt in job.attempts:
		if attempt.has("result") and not attempt.result.is_empty():
			lines.append("Attempt %s: %s" % [attempt.number, JSON.stringify(attempt.result)])
	details.text = "\n".join(lines)
