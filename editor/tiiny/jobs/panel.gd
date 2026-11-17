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
var acknowledge_button: Button
var recovery_dialog: AcceptDialog
var abandon_dialog: ConfirmationDialog
var acknowledge_dialog: ConfirmationDialog
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
var inspecting_model_job := ""

class ChatWorker extends RefCounted:
	var chat: WeakRef
	var validator: Callable
	var job: Dictionary
	var polled := false
	var cancelled_before_start := false
	var preflight_done := false
	var preflight_cancelled := false
	var preflight_refresh_attempted := false
	func _init(owner: Node, p_validator: Callable) -> void:
		chat = weakref(owner)
		validator = p_validator
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
			if not preflight_refresh_attempted and manager.has_method("refresh_for_preflight"):
				if manager.busy or manager.applying:
					return {"state": "running", "stage": "Waiting for Tiiny"}
				preflight_refresh_attempted = true
				manager.refresh_for_preflight()
				return {"state": "running", "stage": "Revalidating Tiiny device state"}
			if manager.busy and str(manager.model_job_id).is_empty():
				return {"state": "running", "stage": "Revalidating Tiiny device state"}
			var ready: Dictionary = manager.poll_model_preflight(job)
			if ready.get("state") == "running": return ready
			if ready.get("state") != "completed" or preflight_cancelled:
				owner.cancel_pending_chat()
				return {"state": "cancelled" if preflight_cancelled else "failed", "result": ready.get("result", {"error": "Coding-model restoration cancelled"})}
		preflight_done = true
		polled = true
		var result: Dictionary = owner.poll_queued_chat(job)
		if result.get("state") == "completed" and not owner.confirm_device_success(job.id):
			owner._set_status("Could not clear the shared device recovery record.")
			return {"state": "failed", "result": {"error": "Could not clear the shared device recovery record."}}
		return result
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
	var preflight_refresh_attempted := false
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
			if not preflight_refresh_attempted and manager.has_method("refresh_for_preflight"):
				if manager.busy or manager.applying:
					return {"state": "running", "stage": "Waiting for Tiiny"}
				preflight_refresh_attempted = true
				manager.refresh_for_preflight()
				return {"state": "running", "stage": "Revalidating Tiiny device state"}
			if manager.busy and str(manager.model_job_id).is_empty():
				return {"state": "running", "stage": "Revalidating Tiiny device state"}
			var ready: Dictionary = manager.poll_model_preflight(job)
			if ready.get("state") == "running": return ready
			if ready.get("state") != "completed" or preflight_cancelled:
				return owner._resource_job_error("cancelled" if preflight_cancelled else "failed", str(ready.get("result", {}).get("error", "Coding-model restoration cancelled")))
		preflight_done = true
		polled = true
		var result: Dictionary = owner.poll_resource_job(job)
		if result.get("state") == "completed" and not owner.confirm_device_success(job.id):
			return owner._resource_job_error("failed", "Could not clear the shared device recovery record.")
		return result
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

class AssetWorker extends RefCounted:
	var chat: WeakRef
	var validator: Callable
	var job: Dictionary
	var polled := false
	var cancelled_before_start := false
	func _init(owner: Node, p_validator: Callable) -> void:
		chat = weakref(owner)
		validator = p_validator
	func start(value: Dictionary) -> String:
		job = value.duplicate(true)
		return ""
	func poll() -> Dictionary:
		var owner: Object = chat.get_ref()
		if not is_instance_valid(owner):
			return {"state": "running", "stage": "Asset handler unavailable; outcome requires recovery"}
		if cancelled_before_start:
			return {"state": "cancelled", "result": {"error": "Cancelled before device execution"}}
		polled = true
		var result: Dictionary = owner.poll_asset_job(job)
		if result.get("state") == "completed" and not owner.confirm_device_success(job.id):
			return {"state": "failed", "result": {"error": "Could not clear the shared device recovery record."}}
		if result.get("state") == "completed" and job.parameters.has("chat_handoff"):
			var continuation: Dictionary = owner.prepare_image_tool_successor(job, result.get("result", {}))
			if continuation.is_empty():
				return {"state": "failed", "result": {"error": "Image was generated, but the turn continuation could not be prepared.", "artifact": result.get("result", {}).get("artifact", "")}}
			result["continuation"] = continuation
		return result
	func cancel() -> void:
		var owner: Object = chat.get_ref()
		if not polled:
			cancelled_before_start = true
		elif is_instance_valid(owner):
			owner.cancel_asset_job(job.id)
	func committed(state: String) -> void:
		var owner: Object = chat.get_ref()
		if is_instance_valid(owner):
			owner.finalize_asset_job(state)

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
	acknowledge_button = Button.new()
	acknowledge_button.text = "Acknowledge device"
	acknowledge_button.tooltip_text = "Clear an uncertain device record left by another project after confirming its remote outcome is unknown."
	acknowledge_button.pressed.connect(_on_acknowledge_device)
	acknowledge_button.visible = false
	actions.add_child(acknowledge_button)
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
			"queued":
				clear.text = "Cancel all"
				clear.pressed.connect(_on_cancel_queued_all)
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
	acknowledge_dialog = ConfirmationDialog.new()
	acknowledge_dialog.title = "Acknowledge uncertain device record"
	acknowledge_dialog.ok_button_text = "Clear device record"
	acknowledge_dialog.confirmed.connect(_on_acknowledge_confirmed)
	add_child(acknowledge_dialog)

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
	if operation == "model_schedule":
		var schedule_keys := parameters.keys()
		schedule_keys.sort()
		if not (schedule_keys == ["connection", "model", "role", "timeout_ms"] or schedule_keys == ["connection", "model", "restore", "role", "timeout_ms"]):
			return "Invalid specialized-model schedule"
		if not parameters.get("role") is String or parameters.role.is_empty() or parameters.role.length() > 64 or not parameters.get("model") is String or parameters.model.is_empty() or parameters.model.length() > 512 or not parameters.get("connection") is String or parameters.connection.length() != 64 or not parameters.connection.is_valid_hex_number(false) or not parameters.get("timeout_ms") is int or parameters.timeout_ms < 1000 or parameters.timeout_ms > 7200000:
			return "Invalid specialized-model schedule"
		if parameters.has("restore") and not parameters.get("restore") is bool:
			return "Invalid specialized-model restoration flag"
		return ""
	if operation == "asset_generate":
		for key in parameters:
			if str(key) not in ["kind", "model", "connection_hash", "timeout_ms", "image_path", "image_artifact_id", "stage", "text", "voice", "manage_model", "chat_handoff"]:
				return "Invalid asset-generation request"
		if parameters.has("manage_model") and (not parameters.manage_model is bool or parameters.get("kind") != "image"):
			return "Automatic model scheduling is only available for image generation"
		if parameters.has("chat_handoff"):
			var handoff: Variant = parameters.chat_handoff
			if parameters.get("kind") != "image" or not handoff is Dictionary or handoff.size() != 3 or not handoff.get("chat") is Dictionary or not handoff.chat.has("turn") or not handoff.get("call") is Dictionary or not handoff.get("remaining") is Array:
				return "Invalid image turn handoff"
			if not _validate_chat(handoff.chat).is_empty() or not _valid_pending_calls([handoff.call] + handoff.remaining):
				return "Invalid image turn handoff"
			if handoff.call.name != "generate_image" or handoff.call.arguments.get("prompt") != parameters.get("text") or handoff.call.id not in handoff.chat.turn.calls:
				return "Image turn handoff does not match the request"
			for pending in handoff.remaining:
				if pending.id in handoff.chat.turn.calls: return "Pending tool call was already executed"
			if JSON.stringify(parameters).to_utf8_buffer().size() > 24 * 1024 * 1024: return "Image turn handoff is too large"
		if not parameters.get("kind") in ["image", "image_to_3d", "speech"] or not parameters.get("model") is String or parameters.model.is_empty() or parameters.model.length() > 512 or not parameters.get("connection_hash") is String or parameters.connection_hash.length() != 64 or not parameters.connection_hash.is_valid_hex_number(false) or not parameters.get("timeout_ms") is int or parameters.timeout_ms < 1000 or parameters.timeout_ms > 7200000:
			return "Invalid asset-generation request"
		if parameters.kind == "image_to_3d":
			var has_path := parameters.get("image_path") is String and not str(parameters.image_path).strip_edges().is_empty()
			var has_artifact := parameters.get("image_artifact_id") is String and str(parameters.image_artifact_id).ends_with(":image") and str(parameters.image_artifact_id).length() <= 128 and str(parameters.image_artifact_id).length() > 6
			if has_path == has_artifact or not parameters.get("stage") in ["shape", "both"]:
				return "Invalid image-to-3D request"
		elif not parameters.get("text") is String or str(parameters.text).strip_edges().is_empty() or str(parameters.text).length() > 10000:
			return "Invalid speech request"
		if parameters.has("voice") and not parameters.get("voice") is String:
			return "Invalid speech voice"
		return ""
	if operation == "resource_shape":
		if parameters.size() != 4 or not parameters.get("description") is String or parameters.description.strip_edges().is_empty() or parameters.description.length() > 100000 or not parameters.get("model") is String or parameters.model.is_empty() or not parameters.get("connection_hash") is String or parameters.connection_hash.length() != 64 or not parameters.get("timeout_ms") is int or parameters.timeout_ms < 0 or parameters.timeout_ms > 86400000:
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
	if parameters.size() not in [7, 8]:
		return "Invalid chat job parameters"
	for key in strings:
		if not parameters.get(key) is String:
			return "Invalid chat job parameters"
	if parameters.prompt.strip_edges().is_empty() or parameters.prompt.length() > 100000 or parameters.context.length() > 100000 or parameters.model.is_empty() or parameters.connection_hash.length() != 64:
		return "Invalid chat request"
	if not parameters.get("conversation") is Array:
		return "Invalid chat context"
	if not parameters.get("timeout_ms") is int or parameters.timeout_ms < 0 or parameters.timeout_ms > 86400000:
		return "Invalid time limit"
	if parameters.has("turn"):
		var turn: Variant = parameters.turn
		if not turn is Dictionary or turn.size() not in [10, 11, 12]:
			return "Invalid turn state"
		for key in ["id", "system"]:
			if not turn.get(key) is String:
				return "Invalid turn state"
		if str(turn.id).is_empty() or str(turn.id).length() > 128:
			return "Invalid turn state"
		if not turn.get("step") is int and not turn.get("step") is float:
			return "Invalid turn state"
		if int(turn.step) < 1 or int(turn.step) > 1000:
			return "Invalid turn state"
		if not turn.get("messages") is Array or not turn.get("calls") is Array or not turn.get("ledger") is Array:
			return "Invalid turn state"
		if (not turn.get("rounds") is int and not turn.get("rounds") is float) or (not turn.get("count") is int and not turn.get("count") is float):
			return "Invalid turn state"
		if not turn.get("failed") is Dictionary or not turn.get("scene") is Dictionary:
			return "Invalid turn state"
		if turn.has("truncations") and not turn.get("truncations") is int and not turn.get("truncations") is float:
			return "Invalid turn state"
		if turn.has("pending_calls") and (not turn.pending_calls is Array or not _valid_pending_calls(turn.pending_calls)):
			return "Invalid pending tool calls"
		if turn.has("pending_calls"):
			for pending in turn.pending_calls:
				if pending.id in turn.calls: return "Pending tool call was already executed"
	if JSON.stringify(parameters).to_utf8_buffer().size() > 24 * 1024 * 1024:
		return "Chat context is too large to queue"
	return ""

func _valid_pending_calls(calls: Array) -> bool:
	if calls.size() > 16: return false
	var seen := {}
	for call in calls:
		if not call is Dictionary or call.size() != 3 or not call.get("id") is String or str(call.id).is_empty() or str(call.id).length() > 128 or not call.get("name") is String or str(call.name).is_empty() or str(call.name).length() > 128 or not call.get("arguments") is Dictionary or seen.has(call.id):
			return false
		seen[call.id] = true
	return true

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
	if operation == "asset_generate" and parameters.get("kind") == "image_to_3d" and parameters.get("image_artifact_id") is String:
		var producer_id: String = parameters.image_artifact_id.trim_suffix(":image")
		var producer: Dictionary = get_job_status(producer_id)
		if producer.get("operation") != "asset_generate" or producer.get("parameters", {}).get("kind") != "image":
			return {"error": "Artifact must reference an accepted image-generation job"}
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

# This record lives beside the cross-process device lock, not in a project.
# It survives an editor crash even though the OS correctly releases the lock.
func _device_marker() -> Dictionary:
	if not FileAccess.file_exists(device_lock_path): return {"state": "idle"}
	var file := FileAccess.open(device_lock_path, FileAccess.READ)
	if file == null or file.get_length() > 8192: return {"state": "invalid"}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or parsed.get("schema") != 1 or parsed.get("state") not in ["idle", "uncertain"]:
		return {"state": "invalid"}
	if parsed.state == "uncertain" and (not parsed.get("project") is String or parsed.project.is_empty() or not parsed.get("job") is String or parsed.job.is_empty()):
		return {"state": "invalid"}
	if parsed.state == "uncertain" and (parsed.get("verb") not in ["download", "load", "unload", "inference"] or not parsed.get("model") is String or parsed.model.is_empty() or parsed.model.length() > 512 or not parsed.get("connection") is String or parsed.connection.length() != 64 or not parsed.connection.is_valid_hex_number(false)):
		return {"state": "invalid"}
	return parsed

func device_recovery_pending() -> bool:
	return _device_marker().get("state") != "idle"

func device_uncertainty_blocks_readiness() -> bool:
	var marker := _device_marker()
	if marker.get("state") == "idle": return false
	# A known, live local request owns the lease; this is not a recovered crash.
	if marker.get("state") == "uncertain" and marker.get("project") == root_path and not device_token.is_empty() and get_job_status(str(marker.get("job", ""))).get("state") == "running":
		return false
	return true

func _owns_device(owner: Object, token: String) -> bool:
	return device_holder != null and device_holder.get_ref() == owner and not token.is_empty() and token == device_token and device_process_lock != null

# Both journals are committed before starting a model command. A crash between
# them cannot launch the command; a crash afterward leaves the shared marker.
func begin_model_operation(owner: Object, token: String, id: String, verb: String, model: String, connection: String) -> bool:
	if not _owns_device(owner, token) or device_purpose == "inspect interrupted model": return false
	var marker := _device_marker()
	if marker.get("state") != "idle" and not (marker.get("state") == "uncertain" and marker.get("project") == root_path and marker.get("job") == id): return false
	if not queue.begin_device_operation(id, verb, model, connection): return false
	return device_process_lock.commit(JSON.stringify({"schema": 1, "state": "uncertain", "project": root_path, "job": id, "verb": verb, "model": model, "connection": connection}))

func begin_device_request(owner: Object, token: String, id: String, model: String, connection: String) -> bool:
	if not _owns_device(owner, token) or device_purpose == "inspect interrupted model" or model.is_empty() or model.length() > 512 or connection.length() != 64 or not connection.is_valid_hex_number(false): return false
	if device_recovery_pending() or not queue.device_started(id): return false
	return device_process_lock.commit(JSON.stringify({"schema": 1, "state": "uncertain", "project": root_path, "job": id, "verb": "inference", "model": model, "connection": connection}))

func confirm_device_request(owner: Object, token: String, id: String) -> bool:
	if not _owns_device(owner, token): return false
	var marker := _device_marker()
	if marker.get("state") == "idle": return true
	if marker.get("state") != "uncertain" or marker.get("project") != root_path or marker.get("job") != id or marker.get("verb") != "inference": return false
	var job := get_job_status(id)
	if job.get("state") != "running" or job.get("attempts", []).is_empty() or not job.attempts.back().get("device_started", false): return false
	if not device_process_lock.commit(JSON.stringify({"schema": 1, "state": "idle"})): return false
	return queue.confirm_device_request(id)

# Clear only after all commands in the running attempt were verified. This is
# done before the worker releases its lease or reports successful completion.
func confirm_model_operations(owner: Object, token: String, id: String) -> bool:
	if not _owns_device(owner, token): return false
	var marker := _device_marker()
	if marker.get("state") == "idle": return true
	if marker.get("state") != "uncertain" or marker.get("project") != root_path or marker.get("job") != id or marker.get("verb") not in ["download", "load", "unload"]: return false
	var job := get_job_status(id)
	if job.get("state") != "running" or job.get("attempts", []).is_empty(): return false
	var operations: Array = job.attempts.back().get("device_operations", [])
	if operations.is_empty() or operations.back().get("state") != "verified": return false
	if not device_process_lock.commit(JSON.stringify({"schema": 1, "state": "idle"})): return false
	return queue.confirm_device_request(id)

# The user has explicitly acknowledged an uncertain outcome. The marker must
# match this project and job; a different project's uncertainty is untouched.
func acknowledge_model_uncertainty(id: String) -> bool:
	var marker := _device_marker()
	if marker.get("state") == "idle": return true # Legacy jobs may predate the shared marker.
	if marker.get("state") != "uncertain" or marker.get("project") != root_path or marker.get("job") != id: return false
	var lock: RefCounted = device_process_lock
	var temporary := false
	if lock == null:
		lock = ClassDB.instantiate("TiinyJobStorage")
		if lock == null or not lock.acquire(device_lock_path): return false
		temporary = true
	# Re-read while locked in case another process resolved or changed it.
	marker = _device_marker()
	var ok: bool = marker.get("state") == "idle" or (marker.get("state") == "uncertain" and marker.get("project") == root_path and marker.get("job") == id and lock.commit(JSON.stringify({"schema": 1, "state": "idle"})))
	if temporary: lock.release()
	return ok

# Clear an uncertain record left by another project. The owning project's queue
# is not available here, so this is an explicit user acknowledgement rather than
# a job resolution. It never claims the remote operation stopped.
func acknowledge_foreign_device_marker() -> bool:
	var marker := _device_marker()
	if marker.get("state") == "idle": return true
	if marker.get("state") != "uncertain": return false
	var lock: RefCounted = device_process_lock
	var temporary := false
	if lock == null:
		lock = ClassDB.instantiate("TiinyJobStorage")
		if lock == null or not lock.acquire(device_lock_path): return false
		temporary = true
	marker = _device_marker()
	var ok: bool = marker.get("state") == "idle" or (marker.get("state") == "uncertain" and lock.commit(JSON.stringify({"schema": 1, "state": "idle"})))
	if temporary: lock.release()
	return ok

func _on_acknowledge_device() -> void:
	var marker := _device_marker()
	if marker.get("state") != "uncertain":
		_refresh()
		return
	acknowledge_dialog.dialog_text = "The shared device record is uncertain for %s (job %s, %s). Another project may have left an inference or model operation unfinished.\n\nClearing it allows new device work, but the remote outcome will not be recovered. Check the device before continuing. Clear the record?" % [str(marker.get("project", "")), str(marker.get("job", "")), str(marker.get("verb", ""))]
	acknowledge_dialog.popup_centered()

func _on_acknowledge_confirmed() -> void:
	if not acknowledge_foreign_device_marker():
		summary.text = "Could not clear the shared device record."
		_refresh()
		return
	log_message.emit("Cleared an uncertain device record after explicit acknowledgement.", 0)
	_refresh()

# Recovery may read the matching device while the ordinary lease is blocked.
# This restricted lease cannot begin a model command or clear the marker.
func acquire_device_for_inspection(owner: Object, id: String) -> String:
	if not available or not is_instance_valid(owner): return ""
	var job := get_job_status(id)
	if job.get("state") != "interrupted" or job.get("attempts", []).is_empty() or job.attempts.back().get("device_operations", []).is_empty(): return ""
	var marker := _device_marker()
	if marker.get("state") != "idle" and not (marker.get("state") == "uncertain" and marker.get("project") == root_path and marker.get("job") == id): return ""
	if not device_token.is_empty():
		return device_token if device_holder != null and device_holder.get_ref() == owner else ""
	var lock: RefCounted = ClassDB.instantiate("TiinyJobStorage")
	if lock == null or not lock.acquire(device_lock_path): return ""
	marker = _device_marker()
	if marker.get("state") != "idle" and not (marker.get("state") == "uncertain" and marker.get("project") == root_path and marker.get("job") == id):
		lock.release()
		return ""
	device_process_lock = lock
	device_holder = weakref(owner)
	device_token = Crypto.new().generate_random_bytes(16).hex_encode()
	device_purpose = "inspect interrupted model"
	return device_token

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
	if device_recovery_pending():
		process_lock.release()
		return ""
	device_process_lock = process_lock
	device_holder = weakref(owner)
	device_token = Crypto.new().generate_random_bytes(16).hex_encode()
	device_purpose = purpose
	return device_token

func release_device(owner: Object, token: String) -> bool:
	if device_holder == null or device_holder.get_ref() != owner or token.is_empty() or token != device_token:
		return false
	if device_recovery_pending() and device_purpose != "inspect interrupted model":
		return false
	device_holder = null
	device_token = ""
	device_purpose = ""
	if device_process_lock != null:
		device_process_lock.release()
		device_process_lock = null
	return true

func _make_worker(job: Dictionary) -> RefCounted:
	if job.operation in ["model_apply", "model_restore", "model_schedule"]:
		var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
		return ModelWorker.new(manager) if is_instance_valid(manager) else null
	if job.operation == "resource_shape":
		return ResourceWorker.new(chat_service) if is_instance_valid(chat_service) else null
	if job.operation == "asset_generate":
		return AssetWorker.new(chat_service, _validate) if is_instance_valid(chat_service) else null
	if job.operation == "chat_turn":
		return ChatWorker.new(chat_service, _validate) if is_instance_valid(chat_service) else null
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
	if job.operation == "model_schedule":
		return label + " — Schedule " + str(job.parameters.get("model", "specialized model"))
	if job.operation == "asset_generate":
		return label + " — " + str(job.parameters.get("kind", "asset")) + " " + str(job.parameters.get("model", ""))
	if job.operation == "chat_turn":
		var step := ""
		if job.parameters.get("turn") is Dictionary:
			step = " (step %d)" % int(job.parameters.turn.get("step", 1))
		return label + " — " + _preview(job.parameters.get("prompt", ""), 90) + step
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
	elif job.state == "queued":
		buttons.add_child(_card_button("Cancel", func(): _on_cancel_queued(str(job.id))))
	elif job.state in ["failed", "cancelled"]:
		buttons.add_child(_card_button("Retry", func(): _on_retry_job(str(job.id))))
		buttons.add_child(_card_button("Clear", func(): _on_clear_job(str(job.id))))
	elif job.state == "interrupted":
		if job.operation == "attach_tree_to_scene" or (not job.attempts.is_empty() and job.attempts.back().has("device_operations")):
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

func _on_cancel_queued(id: String) -> void:
	if available and queue.cancel_queued(id):
		_refresh()

func _on_cancel_queued_all() -> void:
	if not available:
		return
	for job in queue.snapshot().jobs:
		if job.state == "queued":
			queue.cancel_queued(job.id)
	_refresh()

func _skip_with_tool_result(job: Dictionary, decision: String) -> bool:
	if job.get("operation") == "asset_generate" and job.get("parameters", {}).has("chat_handoff"):
		if not is_instance_valid(chat_service) or not chat_service.has_method("prepare_image_tool_successor"):
			return false
		var continuation: Dictionary = chat_service.prepare_image_tool_successor(job, job.get("result", {}), true, decision == "abandon")
		return not continuation.is_empty() and queue.skip_with_successor(str(job.id), decision, "chat_turn", continuation, _validate)
	return queue.abandon(str(job.id)) if decision == "abandon" else queue.resolve(str(job.id), "skip")

func _on_clear_job(id: String) -> void:
	if not available:
		return
	var job := get_job_status(id)
	if job.has("error") or job.state == "interrupted":
		return
	if job.state == "cancelled" and job.attempts.is_empty():
		if queue.hide(id):
			_refresh()
		return
	if job.state in ["failed", "cancelled"]:
		var marker := _device_marker()
		if marker.get("state") == "uncertain" and marker.get("project") == root_path and marker.get("job") == id:
			if not acknowledge_model_uncertainty(id):
				summary.text = "Could not clear the shared device record."
				_refresh()
				return
		if not _skip_with_tool_result(job, "skip"):
			return
	if not queue.hide(id):
		return
	_resume_if_queued()
	_refresh()

func _resume_if_queued() -> void:
	for job in queue.snapshot().jobs:
		if job.state == "queued":
			queue.set_paused(false)
			return

func _on_clear_completed() -> void:
	if not available:
		return
	queue.hide_state("completed")
	_refresh()

func _on_clear_failed() -> void:
	if not available:
		return
	for job in queue.snapshot().jobs:
		if job.state == "cancelled" and job.attempts.is_empty():
			queue.hide(job.id)
		elif job.state in ["failed", "cancelled"]:
			var marker := _device_marker()
			if marker.get("state") == "uncertain" and marker.get("project") == root_path and marker.get("job") == job.id:
				if not acknowledge_model_uncertainty(job.id):
					summary.text = "Could not clear the shared device record."
					_refresh()
					return
			if not _skip_with_tool_result(job, "skip"):
				summary.text = "Could not preserve a failed tool result."
				_refresh()
				return
	queue.hide_state("skipped")
	_resume_if_queued()
	_refresh()

func _on_skip_job(id: String) -> void:
	var job := get_job_status(id)
	if job.has("error") or not _is_abandonable(job) or not inspecting_model_job.is_empty():
		return
	abandon_id = id
	if job.operation in ["model_apply", "model_restore", "model_schedule"]:
		abandon_dialog.dialog_text = "Job %s was interrupted during a model operation. Its remote outcome is unknown, and the device lease is held until this is resolved.\n\nAbandoning marks the job skipped and releases the lease. Refresh the device and check the configuration before trying again. Continue?" % id
	else:
		abandon_dialog.dialog_text = "Job %s was interrupted after the device request started. Its remote outcome is unknown, and the device lease is held until this is resolved.\n\nAbandoning marks the job skipped and releases the lease. A response that was never recorded, or a tool effect it performed, will not be recovered. Continue?" % id
	abandon_dialog.popup_centered()

func _on_abandon_confirmed() -> void:
	if not available or abandon_id.is_empty() or not inspecting_model_job.is_empty():
		return
	var id := abandon_id
	abandon_id = ""
	var job := get_job_status(id)
	if job.has("error") or not _is_abandonable(job):
		summary.text = "The interrupted job changed before acknowledgement."
		_refresh()
		return
	if not job.get("attempts", []).is_empty() and job.attempts.back().get("device_started", false) and not acknowledge_model_uncertainty(id):
		summary.text = "Could not acknowledge the shared device recovery record."
		_refresh()
		return
	if not _skip_with_tool_result(job, "abandon"):
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
	if not available or not inspecting_model_job.is_empty():
		return
	var job := get_job_status(id)
	if job.has("error") or job.state != "interrupted":
		return
	if not job.attempts.is_empty() and job.attempts.back().has("device_operations"):
		var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
		if manager == null or not manager.has_method("inspect_interrupted_model_job"):
			recovery_dialog.dialog_text = "Tiiny model manager is unavailable."
			recovery_dialog.popup_centered()
			return
		inspecting_model_job = id
		var observation: Dictionary = await manager.inspect_interrupted_model_job(id)
		inspecting_model_job = ""
		var description := str(observation.get("message", observation.get("error", "Device inspection failed.")))
		recovery_dialog.dialog_text = description
		recovery_dialog.popup_centered()
		log_message.emit("Job recovery: " + description, 0)
		_refresh()
		return
	if job.operation != "attach_tree_to_scene": return
	var verifier: RefCounted = attach_script.new(queue, root_path)
	var result: Dictionary = verifier.reconcile(job)
	var message := str(result.get("message", result.get("error", "Recovery could not be verified.")))
	recovery_dialog.dialog_text = message
	recovery_dialog.popup_centered()
	log_message.emit("Job recovery: " + message, 0)
	_refresh()

func refresh_board() -> void:
	_refresh()

func is_paused() -> bool:
	return available and bool(queue.snapshot().paused)

func is_stopped() -> bool:
	return available and not str(queue.snapshot().stop_reason).is_empty()

func resume() -> bool:
	if not available:
		return false
	return queue.set_paused(false)

func _refresh() -> void:
	if not available:
		return
	var state: Dictionary = queue.snapshot()
	var stopped: bool = not state.stop_reason.is_empty()
	var running: bool = not executor.current.is_empty()
	summary.text = "Stopped: " + state.stop_reason if stopped else ("Paused" if state.paused else ("Running: " + executor.stage if running else "Ready"))
	var marker := _device_marker()
	if not stopped and not running and marker.get("state") == "uncertain":
		summary.text = "Tiiny requires review in %s (job %s)." % [marker.project, marker.job]
	elif not stopped and not running and marker.get("state") == "invalid":
		summary.text = "Tiiny recovery record is unreadable; device access is stopped."
	if is_instance_valid(acknowledge_button):
		acknowledge_button.visible = marker.get("state") == "uncertain"
		acknowledge_button.disabled = not stopped and running
	pause_button.text = "Resume" if state.paused else "Pause"
	pause_button.disabled = stopped
	cancel_button.disabled = not running
	var signature := _jobs_signature(state.jobs)
	if signature != card_signature:
		card_signature = signature
		_rebuild_board(state.jobs)
	else:
		_update_running_card()

func show_job(id: String) -> void:
	_show_details(id)

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
		if job.get("result", {}).has("reasoning"):
			lines.append("Reasoning:\n" + str(job.result.reasoning))
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
	elif job.operation == "model_schedule":
		lines.append("Role: " + str(job.parameters.get("role", "")))
		lines.append("Model: " + str(job.parameters.get("model", "")))
		lines.append("Restore warm set: " + str(job.parameters.get("restore", true)))
	elif job.operation == "asset_generate":
		lines.append("Kind: " + str(job.parameters.get("kind", "")))
		lines.append("Model: " + str(job.parameters.get("model", "")))
		if job.parameters.has("image_path"): lines.append("Reference: " + str(job.parameters.image_path))
		if job.parameters.has("image_artifact_id"): lines.append("Image artifact: " + str(job.parameters.image_artifact_id))
		if job.parameters.has("text"): lines.append("Text: " + _preview(job.parameters.text))
	if _is_abandonable(job):
		lines.append("Remote outcome: unknown. Skip abandons this job and releases the device lease.")
	if job.state == "running":
		lines.append("Stage: " + executor.stage)
		lines.append("Elapsed: %.1f s" % ((Time.get_ticks_msec() - executor.started_msec) / 1000.0))
	if not job.result.is_empty():
		lines.append("Result: " + JSON.stringify(job.result, "  "))
	for attempt in job.attempts:
		if attempt.has("device_operations"):
			lines.append("Device operations: " + JSON.stringify(attempt.device_operations, "  "))
		if attempt.has("device_observation"):
			lines.append("Last device check: " + JSON.stringify(attempt.device_observation, "  "))
		if attempt.has("result") and not attempt.result.is_empty():
			lines.append("Attempt %s: %s" % [attempt.number, JSON.stringify(attempt.result)])
	return "\n".join(lines)
