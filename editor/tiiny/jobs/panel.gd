@tool
extends VBoxContainer

signal log_message(message: String, message_type: int)

# Built-in script dependencies are injected before this node enters the tree.
var queue_script: Script
var executor_script: Script
var worker_script: Script
var publisher_script: Script
var attach_script: Script
var queue: RefCounted
var executor: RefCounted
var root_path := ""
var available := false
var list: ItemList
var details: TextEdit
var summary: Label
var destination: LineEdit
var attachment_name: LineEdit
var pause_button: Button
var cancel_button: Button
var retry_button: Button
var skip_button: Button
var elapsed_update := 0.0
var selected_id := ""
var recovery: RefCounted
var recovery_job: Dictionary = {}
var recovery_artifact: Dictionary = {}

func _ready() -> void:
	name = "Tiiny Jobs"
	_build_ui()
	root_path = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
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
	destination = LineEdit.new()
	destination.placeholder_text = "res://assets/tree.png"
	destination.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	destination.tooltip_text = "Path for the new tree image. The parent folder must already exist."
	actions.add_child(destination)
	var append := Button.new()
	append.text = "Add tree job"
	append.pressed.connect(_on_append)
	actions.add_child(append)
	attachment_name = LineEdit.new()
	attachment_name.text = "Tree"
	attachment_name.custom_minimum_size.x = 80
	attachment_name.tooltip_text = "Name for the node attached to the open scene root."
	actions.add_child(attachment_name)
	var attach := Button.new()
	attach.text = "Attach selected"
	attach.pressed.connect(_on_attach)
	actions.add_child(attach)
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
	if operation == "attach_tree_to_scene":
		return _validate_attachment(parameters)
	if operation != "create_tree":
		return "Unsupported job operation"
	if parameters.size() != 2 or not parameters.has("destination") or not parameters.has("timeout_ms"):
		return "A destination and time limit are required"
	var path: Variant = parameters.destination
	if not path is String or not path.begins_with("res://") or not path.ends_with(".png") or path.contains("\\"):
		return "Destination must be a res:// PNG path"
	var relative: String = path.trim_prefix("res://")
	for part in relative.split("/", true):
		if part.is_empty() or part.begins_with("."):
			return "Invalid destination path"
	if not DirAccess.dir_exists_absolute(root_path.path_join(relative).get_base_dir()):
		return "Destination folder does not exist"
	if not parameters.timeout_ms is int or parameters.timeout_ms < 1000 or parameters.timeout_ms > 300000:
		return "Invalid time limit"
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

func _make_worker(job: Dictionary) -> RefCounted:
	if job.operation == "attach_tree_to_scene":
		return attach_script.new(queue, root_path)
	if job.operation != "create_tree":
		return null
	var attempt: int = job.attempts.back().number
	var path := root_path.path_join(".godot/tiiny/asset_jobs").path_join(job.id + "-" + str(attempt))
	var publisher: RefCounted = publisher_script.new(queue, root_path, EditorInterface.get_resource_filesystem())
	return worker_script.new(path, OS.get_executable_path(), publisher)

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

func _on_append() -> void:
	var key := Crypto.new().generate_random_bytes(16).hex_encode()
	var result := append_job(key, "create_tree", {"destination": destination.text.strip_edges(), "timeout_ms": 60000})
	if result.has("error"):
		summary.text = result.error
	else:
		selected_id = result.id
		_refresh()

func _on_attach() -> void:
	var producer := get_job_status(selected_id)
	var scene := EditorInterface.get_edited_scene_root()
	if producer.get("operation") != "create_tree" or scene == null or scene.scene_file_path.is_empty() or scene.scene_file_path in EditorInterface.get_unsaved_scenes():
		summary.text = "Select a tree job and open a saved scene."
		return
	var parameters := {"artifact_id": selected_id + ":tree", "scene_path": scene.scene_file_path, "scene_sha256": FileAccess.get_sha256(scene.scene_file_path), "parent_path": ".", "node_name": attachment_name.text.strip_edges(), "timeout_ms": 60000}
	var result := append_job(Crypto.new().generate_random_bytes(16).hex_encode(), "attach_tree_to_scene", parameters)
	if result.has("error"):
		summary.text = result.error
	else:
		selected_id = result.id
		_refresh()

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
	for job in state.jobs:
		if job.state in ["failed", "cancelled"]:
			resolvable = true
			break
	retry_button.disabled = not resolvable
	skip_button.disabled = not resolvable
	list.clear()
	for job in state.jobs:
		list.add_item("%d  %s  —  %s" % [job.sequence, job.operation, job.state])
		var index := list.item_count - 1
		list.set_item_metadata(index, job.id)
		if job.id == selected_id:
			list.select(index)
	_refresh_details()

func _refresh_details() -> void:
	if not available:
		return
	var job := get_job_status(selected_id)
	if job.has("error"):
		details.text = "Select a job to see its details."
		return
	var lines := ["Job: " + str(job.id), "State: " + str(job.state), "Destination: " + str(job.parameters.get("destination", "")), "Attempts: " + str(job.attempts.size())]
	if job.state == "running":
		lines.append("Stage: " + executor.stage)
		lines.append("Elapsed: %.1f s" % ((Time.get_ticks_msec() - executor.started_msec) / 1000.0))
	if not job.result.is_empty():
		lines.append("Result: " + JSON.stringify(job.result, "  "))
	for attempt in job.attempts:
		if attempt.has("result") and not attempt.result.is_empty():
			lines.append("Attempt %s: %s" % [attempt.number, JSON.stringify(attempt.result)])
	details.text = "\n".join(lines)
