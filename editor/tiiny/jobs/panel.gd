@tool
extends VBoxContainer

signal log_message(message: String, message_type: int)

const COLUMNS := [
	{"key": "queued", "title": "Queued"},
	{"key": "running", "title": "Running"},
	{"key": "attention", "title": "Needs attention"},
	{"key": "completed", "title": "Completed"},
	{"key": "failed", "title": "Failed"},
]

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
var board: HBoxContainer
var columns := {}
var column_counts := {}
var details_dialog: AcceptDialog
var details_text: TextEdit
var summary: Label
var pause_button: Button
var cancel_button: Button
var recovery_dialog: AcceptDialog
var abandon_dialog: ConfirmationDialog
var abandon_id := ""
var elapsed_update := 0.0
var card_signature := ""
var running_stage: Label
var running_elapsed: Label
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
	var preflight_done := false
	var preflight_cancelled := false
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
		if not preflight_done and not owner._manager_ready():
			var manager: Node = owner.get_tree().get_first_node_in_group("tiiny_setup_manager")
			if manager == null or not manager.has_method("poll_model_preflight"):
				owner.cancel_pending_chat()
				return {"state": "failed", "result": {"error": "Tiiny model manager is unavailable"}}
			var ready: Dictionary = manager.poll_model_preflight(job)
			if ready.get("state") == "running": return ready
			if ready.get("state") != "completed" or preflight_cancelled:
				owner.cancel_pending_chat()
				return {"state": "cancelled" if preflight_cancelled else "failed", "result": ready.get("result", {"error": "Coding-model restoration cancelled"})}
		preflight_done = true
		polled = true
		return owner.poll_queued_chat(job)
	func cancel() -> void:
		var owner: Object = chat.get_ref()
		if not preflight_done and is_instance_valid(owner):
			var manager: Node = owner.get_tree().get_first_node_in_group("tiiny_setup_manager")
			if manager != null and manager.has_method("cancel_model_job") and manager.cancel_model_job(job.id):
				preflight_cancelled = true
				return
		if not polled:
			cancelled_before_start = true
		elif is_instance_valid(owner):
			owner.cancel_queued_chat(job.id)
	func committed(state: String) -> void:
		var owner: Object = chat.get_ref()
		if is_instance_valid(owner):
			owner.finalize_queued_chat(state)
			var manager: Node = owner.get_tree().get_first_node_in_group("tiiny_setup_manager")
			if manager != null and manager.has_method("finalize_model_job"):
				manager.finalize_model_job(job.id, state)

class ResourceWorker extends RefCounted:
	var chat: WeakRef
	var job: Dictionary
	var polled := false
	var cancelled_before_start := false
	var preflight_done := false
	var preflight_cancelled := false
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
		if not preflight_done and not owner._manager_ready():
			var manager: Node = owner.get_tree().get_first_node_in_group("tiiny_setup_manager")
			if manager == null or not manager.has_method("poll_model_preflight"):
				return owner._resource_job_error("failed", "Tiiny model manager is unavailable")
			var ready: Dictionary = manager.poll_model_preflight(job)
			if ready.get("state") == "running": return ready
			if ready.get("state") != "completed" or preflight_cancelled:
				return owner._resource_job_error("cancelled" if preflight_cancelled else "failed", str(ready.get("result", {}).get("error", "Coding-model restoration cancelled")))
		preflight_done = true
		polled = true
		return owner.poll_resource_job(job)
	func cancel() -> void:
		var owner: Object = chat.get_ref()
		if not preflight_done and is_instance_valid(owner):
			var manager: Node = owner.get_tree().get_first_node_in_group("tiiny_setup_manager")
			if manager != null and manager.has_method("cancel_model_job") and manager.cancel_model_job(job.id):
				preflight_cancelled = true
				return
		if not polled:
			cancelled_before_start = true
		elif is_instance_valid(owner):
			owner.cancel_resource_job(job.id)
	func committed(state: String) -> void:
		var owner: Object = chat.get_ref()
		if is_instance_valid(owner):
			owner.finalize_resource_job(job.id, state)
			var manager: Node = owner.get_tree().get_first_node_in_group("tiiny_setup_manager")
			if manager != null and manager.has_method("finalize_model_job"):
				manager.finalize_model_job(job.id, state)

class ModelWorker extends RefCounted:
	var manager: WeakRef
	var job: Dictionary
	var cancelled_before_start := false
	var polled := false
	func _init(owner: Node) -> void:
		manager = weakref(owner)
	func start(value: Dictionary) -> String:
		job = value.duplicate(true)
		return ""
	func poll() -> Dictionary:
		if cancelled_before_start:
			return {"state": "cancelled", "result": {"error": "Cancelled before device execution"}}
		var owner: Object = manager.get_ref()
		if not is_instance_valid(owner):
			return {"state": "running", "stage": "Model manager unavailable; outcome requires recovery"}
		polled = true
		return owner.poll_model_job(job)
	func cancel() -> void:
		var owner: Object = manager.get_ref()
		if not polled:
			cancelled_before_start = true
		elif is_instance_valid(owner):
			if not owner.cancel_model_job(job.id):
				cancelled_before_start = true
	func committed(state: String) -> void:
		var owner: Object = manager.get_ref()
		if is_instance_valid(owner):
			owner.finalize_model_job(job.id, state)

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
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	summary = Label.new()
	summary.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	actions.add_child(summary)

	var board_scroll := ScrollContainer.new()
	board_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board_scroll.custom_minimum_size.y = 220
	board_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	board_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(board_scroll)
	board = HBoxContainer.new()
	board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board.add_theme_constant_override("separation", 8)
	board_scroll.add_child(board)
	for spec in COLUMNS:
		var column := VBoxContainer.new()
		column.custom_minimum_size.x = 190
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.size_flags_vertical = Control.SIZE_EXPAND_FILL
		board.add_child(column)
		var header := HBoxContainer.new()
		column.add_child(header)
		var title := Label.new()
		title.text = spec.title
		title.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		header.add_child(title)
		var count := Label.new()
		count.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		header.add_child(count)
		var gap := Control.new()
		gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(gap)
		var clear := Button.new()
		clear.text = "Clear"
		clear.flat = true
		clear.add_theme_font_size_override("font_size", 11)
		header.add_child(clear)
		match spec.key:
			"completed": clear.pressed.connect(_on_clear_completed)
			"failed": clear.pressed.connect(_on_clear_failed)
			_: clear.visible = false
		var column_scroll := ScrollContainer.new()
		column_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		column_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		column.add_child(column_scroll)
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_theme_constant_override("separation", 4)
		column_scroll.add_child(box)
		columns[spec.key] = {"box": box, "count": count, "clear": clear}
		column_counts[spec.key] = 0

	details_dialog = AcceptDialog.new()
	details_dialog.title = "Job details"
	details_dialog.ok_button_text = "Close"
	details_dialog.min_size = Vector2i(620, 420)
	details_dialog.unresizable = false
	add_child(details_dialog)
	details_text = TextEdit.new()
	details_text.editable = false
	details_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	details_dialog.add_child(details_text)

	recovery_dialog = AcceptDialog.new()
	recovery_dialog.title = "Job recovery"
	add_child(recovery_dialog)
	abandon_dialog = ConfirmationDialog.new()
	abandon_dialog.title = "Abandon interrupted job"
	abandon_dialog.ok_button_text = "Abandon job"
	abandon_dialog.confirmed.connect(_on_abandon_confirmed)
	add_child(abandon_dialog)

func _validate(operation: String, parameters: Dictionary) -> String:
	if operation == "model_restore":
		if parameters.size() != 3 or not parameters.get("model") is String or parameters.model.is_empty() or parameters.model.length() > 512 or not parameters.get("connection") is String or parameters.connection.length() != 64 or not parameters.connection.is_valid_hex_number(false) or not parameters.get("timeout_ms") is int or parameters.timeout_ms < 1000 or parameters.timeout_ms > 7200000:
			return "Invalid coding-model restoration"
		return ""
	if operation == "model_apply":
		if parameters.size() != 2 or not parameters.get("approved") is Dictionary or not parameters.get("timeout_ms") is int or parameters.timeout_ms < 1000 or parameters.timeout_ms > 7200000:
			return "Invalid model configuration job"
		var approved: Dictionary = parameters.approved
		if not approved.get("draft") is Dictionary or not approved.get("actions") is Array or approved.actions.size() > 128 or not approved.get("connection") is String or approved.connection.length() != 64 or not approved.connection.is_valid_hex_number(false):
			return "Invalid approved model configuration"
		return ""
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
	if job.operation in ["model_apply", "model_restore"]:
		var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
		return ModelWorker.new(manager) if is_instance_valid(manager) else null
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

func _on_pause() -> void:
	if available:
		queue.set_paused(not queue.snapshot().paused)
		_refresh()

func _on_cancel() -> void:
	if available:
		executor.cancel_current()
		_refresh()

# A device-started interruption has no verifiable workspace effect but its
# remote outcome is unknown. Only the user can acknowledge that before skip.
func _is_abandonable(job: Dictionary) -> bool:
	if job.get("state") != "interrupted" or not job.get("attempts") is Array or job.attempts.is_empty():
		return false
	var attempt: Dictionary = job.attempts.back()
	return attempt.get("device_started", false) and not attempt.has("mutation") and not attempt.has("publication")

func _column_for(state: String) -> String:
	if state == "running":
		return "running"
	if state == "interrupted":
		return "attention"
	if state == "completed":
		return "completed"
	if state in ["failed", "cancelled", "skipped"]:
		return "failed"
	return "queued"

func _state_color(state: String) -> Color:
	match state:
		"queued": return Color(0.55, 0.75, 1.0)
		"running": return Color(0.45, 0.85, 0.55)
		"interrupted": return Color(1.0, 0.75, 0.35)
		"completed": return Color(0.5, 0.75, 0.95)
		"failed", "cancelled": return Color(1.0, 0.45, 0.45)
		"skipped": return Color(0.6, 0.6, 0.6)
	return Color(0.7, 0.7, 0.7)

func _preview(text: Variant, limit := 400) -> String:
	var value := str(text).strip_edges()
	return value if value.length() <= limit else value.left(limit) + "…"

func _job_title(job: Dictionary) -> String:
	var label := "#%d %s" % [int(job.sequence), str(job.operation)]
	if job.operation == "model_apply":
		return label + " — Apply model configuration"
	if job.operation == "model_restore":
		return label + " — Restore " + str(job.parameters.get("model", "coding model"))
	if job.operation == "chat_turn":
		return label + " — " + _preview(job.parameters.get("prompt", ""), 90)
	if job.operation == "resource_shape":
		return label + " — " + _preview(job.parameters.get("description", ""), 90)
	if job.operation == "create_tree":
		return label + " — " + str(job.parameters.get("destination", ""))
	if job.operation == "attach_tree_to_scene":
		return label + " — " + str(job.parameters.get("node_name", "")) + " in " + str(job.parameters.get("scene_path", ""))
	return label

func _card_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.flat = true
	button.add_theme_font_size_override("font_size", 11)
	button.pressed.connect(callback)
	return button

func _update_running_card() -> void:
	if is_instance_valid(running_stage):
		running_stage.text = "running" + (" · " + executor.stage if not executor.stage.is_empty() else "")
	if is_instance_valid(running_elapsed):
		running_elapsed.text = "%.1f s" % ((Time.get_ticks_msec() - executor.started_msec) / 1000.0)

func _make_card(job: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(_on_card_input.bind(str(job.id)))
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6)
	style.bg_color = Color(0.5, 0.5, 0.5, 0.1)
	style.border_width_left = 3
	style.border_color = _state_color(str(job.state))
	card.add_theme_stylebox_override("panel", style)
	card.tooltip_text = "Double-click for job details."
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 3)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(content)
	var title := Label.new()
	title.text = _job_title(job)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(title)
	var state := Label.new()
	state.text = str(job.state) + " · attempts %d" % job.attempts.size()
	state.add_theme_font_size_override("font_size", 11)
	state.add_theme_color_override("font_color", _state_color(str(job.state)))
	state.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(state)
	if job.state == "running":
		running_stage = state
		running_elapsed = Label.new()
		running_elapsed.add_theme_font_size_override("font_size", 11)
		running_elapsed.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(running_elapsed)
		_update_running_card()
	if job.state in ["failed", "cancelled", "interrupted"] and job.result.has("error") and not str(job.result.error).is_empty():
		var error := Label.new()
		error.text = _preview(job.result.error, 160)
		error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		error.add_theme_font_size_override("font_size", 11)
		error.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45))
		error.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(error)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 2)
	content.add_child(buttons)
	if job.state == "running":
		buttons.add_child(_card_button("Cancel", func(): executor.cancel_current()))
	elif job.state in ["failed", "cancelled"]:
		buttons.add_child(_card_button("Retry", func(): _on_retry_job(str(job.id))))
		buttons.add_child(_card_button("Clear", func(): _on_clear_job(str(job.id))))
	elif job.state == "interrupted":
		if job.operation == "attach_tree_to_scene":
			buttons.add_child(_card_button("Check", func(): _on_check_job(str(job.id))))
		if _is_abandonable(job):
			buttons.add_child(_card_button("Skip", func(): _on_skip_job(str(job.id))))
	elif job.state in ["completed", "skipped"]:
		buttons.add_child(_card_button("Clear", func(): _on_clear_job(str(job.id))))
	return card

func _on_card_input(event: InputEvent, id: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
		_show_details(id)

func _rebuild_board(jobs: Array) -> void:
	for key in columns:
		var box: VBoxContainer = columns[key]["box"]
		for child in box.get_children():
			box.remove_child(child)
			child.queue_free()
		column_counts[key] = 0
	running_stage = null
	running_elapsed = null
	for job in jobs:
		if job.get("hidden", false):
			continue
		var key := _column_for(str(job.state))
		if not columns.has(key):
			continue
		columns[key]["box"].add_child(_make_card(job))
		column_counts[key] += 1
	for key in columns:
		columns[key]["count"].text = str(column_counts[key])
		columns[key]["clear"].disabled = column_counts[key] == 0

func _jobs_signature(jobs: Array) -> String:
	var parts := PackedStringArray()
	for job in jobs:
		if job.get("hidden", false):
			continue
		parts.append("%s:%s:%d:%s" % [str(job.id), str(job.state), job.attempts.size(), str(job.get("result", {}).get("error", ""))])
	return "|".join(parts)

func _on_retry_job(id: String) -> void:
	if not available:
		return
	if queue.resolve(id, "retry"):
		_refresh()

func _on_clear_job(id: String) -> void:
	if not available:
		return
	var job := get_job_status(id)
	if job.has("error") or job.state == "interrupted":
		return
	if job.state in ["failed", "cancelled"] and not queue.resolve(id, "skip"):
		return
	if not queue.hide(id):
		return
	_refresh()

func _on_clear_completed() -> void:
	if not available:
		return
	queue.hide_state("completed")
	_refresh()

func _on_clear_failed() -> void:
	if not available:
		return
	for job in queue.snapshot().jobs:
		if job.state in ["failed", "cancelled"]:
			queue.resolve(job.id, "skip")
	queue.hide_state("skipped")
	_refresh()

func _on_skip_job(id: String) -> void:
	var job := get_job_status(id)
	if job.has("error") or not _is_abandonable(job):
		return
	abandon_id = id
	if job.operation in ["model_apply", "model_restore"]:
		abandon_dialog.dialog_text = "Job %s was interrupted during a model operation. Its remote outcome is unknown, and the device lease is held until this is resolved.\n\nAbandoning marks the job skipped and releases the lease. Refresh the device and check the configuration before trying again. Continue?" % id
	else:
		abandon_dialog.dialog_text = "Job %s was interrupted after the device request started. Its remote outcome is unknown, and the device lease is held until this is resolved.\n\nAbandoning marks the job skipped and releases the lease. A response that was never recorded, or a tool effect it performed, will not be recovered. Continue?" % id
	abandon_dialog.popup_centered()

func _on_abandon_confirmed() -> void:
	if not available or abandon_id.is_empty():
		return
	var id := abandon_id
	abandon_id = ""
	if not queue.abandon(id):
		summary.text = "Could not abandon the interrupted job."
		_refresh()
		return
	if is_instance_valid(chat_service) and chat_service.has_method("release_uncertain_device"):
		chat_service.release_uncertain_device(id)
	var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
	if manager != null and manager.has_method("release_uncertain_model_job"):
		manager.release_uncertain_model_job(id)
	log_message.emit("Job %s abandoned after an uncertain device outcome. Resume when ready." % id, 0)
	_refresh()

func _on_check_job(id: String) -> void:
	if not available:
		return
	var job := get_job_status(id)
	if job.has("error") or job.state != "interrupted" or job.operation != "attach_tree_to_scene":
		return
	var verifier: RefCounted = attach_script.new(queue, root_path)
	var result: Dictionary = verifier.reconcile(job)
	var message := str(result.get("message", result.get("error", "Recovery could not be verified.")))
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
	var signature := _jobs_signature(state.jobs)
	if signature != card_signature:
		card_signature = signature
		_rebuild_board(state.jobs)
	else:
		_update_running_card()

func _show_details(id: String) -> void:
	if not available:
		return
	var text := _job_details_text(id)
	if text.is_empty():
		return
	details_text.text = text
	details_dialog.popup_centered(Vector2i(660, 440))

func _job_details_text(id: String) -> String:
	var job := get_job_status(id)
	if job.has("error"):
		return ""
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
	if _is_abandonable(job):
		lines.append("Remote outcome: unknown. Skip abandons this job and releases the device lease.")
	if job.state == "running":
		lines.append("Stage: " + executor.stage)
		lines.append("Elapsed: %.1f s" % ((Time.get_ticks_msec() - executor.started_msec) / 1000.0))
	if not job.result.is_empty():
		lines.append("Result: " + JSON.stringify(job.result, "  "))
	for attempt in job.attempts:
		if attempt.has("result") and not attempt.result.is_empty():
			lines.append("Attempt %s: %s" % [attempt.number, JSON.stringify(attempt.result)])
	return "\n".join(lines)
