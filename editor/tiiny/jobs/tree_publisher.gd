@tool
extends RefCounted

# The owner supplies the canonical project root and its EditorFileSystem. This
# publisher only accepts the reviewed tree worker's staged output. It remains
# pending until the editor has imported and loaded the published Texture2D.
var queue: RefCounted
var project_root: String
var filesystem: Object
var phase := "new"
var destination := ""
var destination_absolute := ""
var accepted_job := ""
var accepted_hash := ""
var scan_requested := false
var terminal: Dictionary = {}
var recovering := false

# Only an interrupted attempt with a journaled link can be reconciled here.
# Missing or changed files remain unresolved for an explicit decision; this
# method does not infer that a previous worker failed without side effects.
func begin_recovery(job: Dictionary) -> Dictionary:
	if phase != "new" or not project_root.is_absolute_path() or filesystem == null or job.get("state") != "interrupted" or not job.get("attempts") is Array or job.attempts.is_empty():
		return {"error": "No interrupted publication"}
	var journal: Dictionary = job.attempts.back().get("publication", {})
	if journal.get("phase") not in ["prepared", "published", "imported"] or not journal.get("artifact") is Dictionary:
		return {"error": "No recoverable publication"}
	var source: String = journal.get("source", "")
	destination = str(journal.get("destination", ""))
	var artifact: Dictionary = journal.artifact.duplicate(true)
	if not _safe_relative(source) or not source.begins_with(".godot/tiiny/asset_jobs/") or not _safe_relative(destination) or destination.begins_with(".godot/") or destination.begins_with(".tiiny/") or not destination.ends_with(".png"):
		return {"error": "Invalid publication journal"}
	accepted_job = str(job.get("id", ""))
	accepted_hash = str(artifact.get("sha256", ""))
	destination_absolute = project_root.path_join(destination)
	if accepted_hash.length() != 64 or not queue.publication_same_file(accepted_job, project_root) or FileAccess.get_sha256(destination_absolute) != accepted_hash:
		return {"error": "Published artifact identity could not be verified"}
	recovering = true
	phase = "published"
	return {"ok": true, "artifact": artifact}

func _init(p_queue: RefCounted, p_root: String, p_filesystem: Object) -> void:
	queue = p_queue
	project_root = p_root.trim_suffix("/")
	filesystem = p_filesystem

func _safe_relative(path: String) -> bool:
	if path.is_empty() or path.is_absolute_path() or path.contains("\\"):
		return false
	for part in path.split("/", true):
		if part.is_empty() or part == "." or part == "..":
			return false
	return true

func publish(job: Dictionary, artifact: Dictionary) -> Dictionary:
	if not terminal.is_empty():
		return terminal.duplicate(true)
	if phase == "new":
		var requested: Variant = job.get("parameters", {}).get("destination")
		var source: Variant = artifact.get("path")
		if not project_root.is_absolute_path() or filesystem == null or not requested is String or not source is String:
			return _fail("Invalid publication request")
		if not requested.begins_with("res://") or not requested.ends_with(".png") or not source.begins_with(project_root + "/"):
			return _fail("Invalid output or staging path")
		destination = requested.trim_prefix("res://")
		var source_relative: String = source.trim_prefix(project_root + "/")
		if not _safe_relative(destination) or not _safe_relative(source_relative) or destination.begins_with(".godot/") or destination.begins_with(".tiiny/") or not source_relative.begins_with(".godot/tiiny/asset_jobs/"):
			return _fail("Invalid output or staging path")
		destination_absolute = project_root.path_join(destination)
		if FileAccess.file_exists(destination_absolute + ".import"):
			return _fail("Destination import metadata already exists")
		accepted_job = str(job.get("id", ""))
		accepted_hash = str(artifact.get("sha256", ""))
		if accepted_job.is_empty() or accepted_hash.length() != 64 or FileAccess.get_sha256(source) != accepted_hash:
			return _fail("Staged artifact changed before publication")
		if not queue.publication(accepted_job, "prepared", {"source": source_relative, "destination": destination, "artifact": artifact.duplicate(true)}):
			return _fail("Could not record publication intent")
		var link_result: String = queue.publish_link(accepted_job, project_root)
		if link_result != "published":
			return _fail("Publication failed: " + link_result)
		phase = "published"
	if str(job.get("id", "")) != accepted_job or str(artifact.get("sha256", "")) != accepted_hash:
		return _fail("Publication request changed")
	if not queue.publication_same_file(accepted_job, project_root) or FileAccess.get_sha256(destination_absolute) != accepted_hash:
		return _fail("Published artifact changed before import")
	if not scan_requested:
		if filesystem.is_scanning() or filesystem.is_importing():
			return {"pending": true, "stage": "Waiting for editor import"}
		scan_requested = true
		filesystem.scan()
		return {"pending": true, "stage": "Importing tree"}
	if filesystem.is_scanning() or filesystem.is_importing():
		return {"pending": true, "stage": "Importing tree"}
	var resource_path := "res://" + destination
	if not ResourceLoader.exists(resource_path, "Texture2D"):
		return {"pending": true, "stage": "Waiting for imported texture"}
	var texture := ResourceLoader.load(resource_path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE)
	if not texture is Texture2D or texture.get_width() != 64 or texture.get_height() != 64:
		return _fail("Imported texture failed validation")
	if not queue.publication_same_file(accepted_job, project_root) or FileAccess.get_sha256(destination_absolute) != accepted_hash:
		return _fail("Published artifact changed during import")
	var published := artifact.duplicate(true)
	published.path = resource_path
	if recovering:
		if not queue.reconcile(accepted_job, "completed", {"artifact": published, "reconciled": true}):
			return _fail("Could not record reconciled texture")
	elif not queue.publication(accepted_job, "imported", {"resource_path": resource_path}):
		return _fail("Could not record imported texture")
	terminal = {"ok": true, "artifact": published}
	return terminal.duplicate(true)

func _fail(message: String) -> Dictionary:
	terminal = {"error": message}
	return terminal.duplicate(true)
