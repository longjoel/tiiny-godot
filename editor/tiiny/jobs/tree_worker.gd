@tool
extends RefCounted

# This is the only executable recipe. It runs in a disposable Godot project;
# it is not a sandbox for arbitrary scripts. Publication is supplied by the
# editor service and must validate and journal the destination before success.
const RECIPE := '''extends SceneTree
func _initialize() -> void:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	for y in range(7, 47):
		var half := int((y - 7) * 0.65)
		for x in range(maxi(0, 32 - half), mini(64, 33 + half)):
			image.set_pixel(x, y, Color(0.12, 0.48, 0.21, 1))
	for y in range(44, 61):
		for x in range(28, 36):
			image.set_pixel(x, y, Color(0.38, 0.22, 0.10, 1))
	var err := image.save_png("res://tree.png")
	print("Tree fixture generated" if err == OK else "Tree fixture failed")
	quit(0 if err == OK else 1)
'''
const MAX_LOG_BYTES := 65536
const MAX_OUTPUT_BYTES := 1048576
var root: String
var executable: String
var publish: Callable
var publisher_owner: RefCounted
var process: Dictionary = {}
var pid := -1
var job: Dictionary = {}
var log_bytes := PackedByteArray()
var failure := ""
var stopping := false
var finished: Dictionary = {}
var publication_artifact: Dictionary = {}
var publication_result: Dictionary = {}

func _init(p_root: String, p_executable: String, p_publish: Variant) -> void:
	root = p_root
	executable = p_executable
	if p_publish is Callable:
		publish = p_publish
	elif p_publish is RefCounted and p_publish.has_method("publish"):
		publisher_owner = p_publish
		publish = Callable(publisher_owner, "publish")

# root must be a newly reserved, manager-owned per-attempt directory; neither
# the recipe nor the destination can be supplied by the job.
func start(p_job: Dictionary) -> String:
	job = p_job.duplicate(true)
	if not root.is_absolute_path() or not executable.is_absolute_path() or not publish.is_valid():
		return "Invalid worker configuration"
	if DirAccess.make_dir_absolute(root) != OK:
		return "Cannot reserve isolated worker directory"
	var project := FileAccess.open(root.path_join("project.godot"), FileAccess.WRITE)
	if project == null:
		return "Cannot create worker project"
	project.store_string("config_version=5\n[application]\nconfig/name=\"Tiiny Tree Fixture\"\n")
	project.close()
	var script := FileAccess.open(root.path_join("generator.gd"), FileAccess.WRITE)
	if script == null:
		return "Cannot create reviewed generator"
	script.store_string(RECIPE)
	script.close()
	process = OS.execute_with_pipe(executable, PackedStringArray(["--headless", "--path", root, "--script", "res://generator.gd"]), false)
	if process.is_empty():
		return "Could not start generator"
	pid = process.pid
	return ""

func _drain(pipe: FileAccess) -> void:
	if pipe == null:
		return
	var available := int(pipe.get_length())
	while available > 0:
		var chunk := pipe.get_buffer(mini(available, 4096))
		if chunk.is_empty():
			break
		if log_bytes.size() + chunk.size() > MAX_LOG_BYTES:
			failure = "Worker exceeded its output limit"
			cancel()
			return
		log_bytes.append_array(chunk)
		available = int(pipe.get_length())

func poll() -> Dictionary:
	if not finished.is_empty():
		return finished.duplicate(true)
	if not publication_artifact.is_empty():
		if stopping:
			finished = {"state": "cancelled", "result": publication_result.duplicate(true)}
			return finished.duplicate(true)
		return _poll_publication()
	if pid < 0:
		return {"state": "failed", "result": {"error": "Worker was not started"}}
	_drain(process.stdio)
	_drain(process.stderr)
	if OS.is_process_running(pid):
		return {"state": "running", "stage": "Stopping" if stopping else "Generating tree"}
	_drain(process.stdio)
	_drain(process.stderr)
	var exit_code := OS.get_process_exit_code(pid)
	var result := {"log": log_bytes.get_string_from_utf8(), "exit_code": exit_code}
	if not failure.is_empty():
		result["error"] = failure
		finished = {"state": "failed", "result": result}
	elif stopping:
		finished = {"state": "cancelled", "result": result}
	elif exit_code != 0:
		result["error"] = "Generator exited unsuccessfully"
		finished = {"state": "failed", "result": result}
	else:
		return _validate_and_publish(result)
	return finished.duplicate(true)

func _validate_and_publish(result: Dictionary) -> Dictionary:
	var dir := DirAccess.open(root)
	var output := root.path_join("tree.png")
	if dir == null or dir.is_link("tree.png") or not FileAccess.file_exists(output):
		result["error"] = "Generator did not produce a regular output"
		return {"state": "failed", "result": result}
	var file := FileAccess.open(output, FileAccess.READ)
	if file == null or file.get_length() < 8 or file.get_length() > MAX_OUTPUT_BYTES:
		result["error"] = "Generator output has an invalid size"
		return {"state": "failed", "result": result}
	file.close()
	var bytes := FileAccess.get_file_as_bytes(output)
	if bytes.size() < 8 or bytes.slice(0, 8) != PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]):
		result["error"] = "Generator output is not a PNG"
		return {"state": "failed", "result": result}
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK or image.get_width() != 64 or image.get_height() != 64:
		result["error"] = "Generator output is not the declared tree image"
		return {"state": "failed", "result": result}
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	var artifact := {"id": job.id + ":tree", "path": output, "sha256": hash.finish().hex_encode(), "format": "png", "recipe": "tree-fixture-v1"}
	publication_artifact = artifact
	publication_result = result
	return _poll_publication()

func _poll_publication() -> Dictionary:
	var publication: Variant = publish.call(job.duplicate(true), publication_artifact.duplicate(true))
	if publication is Dictionary and publication.get("pending", false):
		return {"state": "running", "stage": str(publication.get("stage", "Importing tree"))}
	if not publication is Dictionary or not publication.get("ok", false):
		publication_result["error"] = str(publication.get("error", "Publication failed")) if publication is Dictionary else "Invalid publication result"
		finished = {"state": "failed", "result": publication_result}
	else:
		publication_result["artifact"] = publication.get("artifact", publication_artifact)
		finished = {"state": "completed", "result": publication_result}
	return finished.duplicate(true)

func cancel() -> void:
	if pid >= 0 and not stopping:
		stopping = true
		if OS.is_process_running(pid):
			OS.kill(pid)
