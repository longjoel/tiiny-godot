@tool
extends RefCounted

## Workspace coding tools: bounded, root-confined file access, hash-guarded
## writes and patches, read-only git inspection, and owned command execution.
##
## File edits are explicitly not scene-undoable. The editor bridge (scan,
## reload, dirty-scene state) is supplied by the dock as a Callable so this
## provider stays usable in pure fixtures.

const MAX_READ_BYTES := 262144
const MAX_READ_LINES := 1000
const MAX_WRITE_BYTES := 1048576
const MAX_SEARCH_MATCHES := 500
const MAX_SEARCH_FILES := 5000
const MAX_LIST_ENTRIES := 2000
const MAX_COMMAND_OUTPUT := 262144
const MAX_COMMAND_TIMEOUT_MS := 300000
const MAX_DIFF_CHARS := 8000
const MAX_LINE_CHARS := 240
const MAX_RECURSION := 12

const DENIED_DIRS := [".git", ".godot", ".import", ".ssh", ".gnupg"]
const DENIED_FILES := [".netrc", ".git-credentials", ".env", "id_rsa", "id_ed25519", "credentials.json", "auth.json"]
const BINARY_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "bmp", "tga", "svg", "ico", "exr", "hdr", "dds", "ktx", "wav", "ogg", "mp3", "flac", "mp4", "webm", "glb", "gltf", "obj", "fbx", "blend", "dae", "stl", "mtl", "res", "scn", "ttf", "otf", "woff", "woff2", "zip", "gz", "7z", "so", "dll", "dylib", "exe", "bin"]
const HEADLESS_FLAGS := ["--headless", "--path", "--script", "-s", "--quit", "--quit-after", "--check-only", "--import", "--verbose", "-v", "--debug", "--fixed-fps", "--time-scale", "--rendering-method", "--rendering-driver", "--display-driver", "--audio-driver", "--log-file", "--no-header", "--disable-vsync", "--single-threaded-scene", "--max-fps", "--resolution", "--position", "--write-movie"]
const HEADLESS_VALUE_FLAGS := ["--path", "--script", "-s", "--quit-after", "--fixed-fps", "--time-scale", "--rendering-method", "--rendering-driver", "--display-driver", "--audio-driver", "--log-file", "--max-fps", "--resolution", "--position", "--write-movie"]

const ASSET_KINDS := {
	"png": "image", "jpg": "image", "jpeg": "image", "webp": "image", "svg": "image",
	"bmp": "image", "tga": "image", "exr": "image", "hdr": "image", "dds": "image", "ktx": "image",
	"glb": "model", "gltf": "model", "obj": "model", "fbx": "model", "blend": "model",
	"dae": "model", "stl": "model", "ply": "model",
	"wav": "audio", "ogg": "audio", "mp3": "audio",
	"tscn": "scene", "scn": "scene",
	"gd": "script", "cs": "script",
	"tres": "resource", "res": "resource",
}

# Probe executed with --script in the user's project. It instantiates a saved
# scene, steps physics, optionally presses input actions, and writes measured
# body motion plus sampled positions to a JSON file. The editor side decides
# which checks pass; the probe only records evidence.
const RUNTIME_PROBE_SOURCE := """extends SceneTree

const SAMPLE_STRIDE := 6
const SAMPLE_LIMIT := 24

var spec: Dictionary = {}
var frames := 0
var frame_limit := 180
var nodes: Array = []
var records: Array = []
var done := false

func _initialize() -> void:
	var user_args := OS.get_cmdline_user_args()
	if user_args.is_empty():
		_finish({"error": "missing_spec"})
		return
	var text := FileAccess.get_file_as_string(str(user_args[0]))
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		_finish({"error": "invalid_spec"})
		return
	spec = parsed
	frame_limit = maxi(10, int(spec.get("frames", 180)))
	var packed: Variant = load(str(spec.get("scene", "")))
	if not packed is PackedScene:
		_finish({"error": "scene_load_failed"})
		return
	var scene: Node = (packed as PackedScene).instantiate()
	if scene == null:
		_finish({"error": "instantiate_failed"})
		return
	root.add_child(scene)
	_collect(scene, scene)
	physics_frame.connect(_tick)

func _collect(node: Node, scene_root: Node) -> void:
	if node is CharacterBody2D or node is RigidBody2D:
		var position := _pos(node)
		nodes.append(node)
		records.append({
			"path": "." if node == scene_root else str(scene_root.get_path_to(node)),
			"class": node.get_class(),
			"start": [position.x, position.y],
			"end": [position.x, position.y],
			"max_y": position.y,
			"end_vy": 0.0,
			"min_vy_after_action": 0.0,
			"end_on_floor": false,
			"sampled": [],
		})
	for child in node.get_children():
		_collect(child, scene_root)

func _tick() -> void:
	if done:
		return
	frames += 1
	for entry in spec.get("actions", []):
		if not entry is Dictionary:
			continue
		var action := str(entry.get("action", ""))
		if action.is_empty():
			continue
		var start := int(entry.get("frame", 1))
		var hold := maxi(1, int(entry.get("hold", 2)))
		if frames == start:
			Input.action_press(action)
			for index in records.size():
				records[index]["action_y"] = float(records[index]["end"][1])
		elif frames == start + hold:
			Input.action_release(action)
	# The physics_frame signal fires before _physics_process, so this records the
	# state produced by the previous physics step. That is enough for motion and
	# landing checks and keeps the probe free of engine-internal hooks.
	for index in nodes.size():
		var node: Node = nodes[index]
		if not is_instance_valid(node):
			continue
		var record: Dictionary = records[index]
		var position := _pos(node)
		record["end"] = [position.x, position.y]
		record["max_y"] = maxf(float(record["max_y"]), position.y)
		if node is CharacterBody2D:
			record["end_on_floor"] = (node as CharacterBody2D).is_on_floor()
			record["end_vy"] = (node as CharacterBody2D).velocity.y
			if record.has("action_y"):
				record["min_vy_after_action"] = minf(float(record["min_vy_after_action"]), (node as CharacterBody2D).velocity.y)
		elif node is RigidBody2D:
			record["end_vy"] = (node as RigidBody2D).linear_velocity.y
		if frames % SAMPLE_STRIDE == 0 and record.sampled.size() < SAMPLE_LIMIT:
			record["sampled"].append([frames, position.x, position.y])
	if frames >= frame_limit:
		_release_all()
		done = true
		_finish({})

func _release_all() -> void:
	for entry in spec.get("actions", []):
		if entry is Dictionary:
			var action := str(entry.get("action", ""))
			if not action.is_empty():
				Input.action_release(action)

func _finish(payload: Dictionary) -> void:
	payload["frames"] = frames
	payload["bodies"] = records
	payload["actions"] = spec.get("actions", [])
	var output := str(spec.get("output", ""))
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(payload))
			file.close()
	quit(0)

func _pos(node: Node) -> Vector2:
	if node is Node2D:
		return (node as Node2D).global_position
	return Vector2.ZERO
"""

var project_root := ""
var editor_bridge: Callable
var asset_overview_cache := {"at": -100000, "text": ""}
var approve_command: Callable
var approve_edit: Callable
var approve_headless: Callable
var approve_discard: Callable
var before_commit: Callable
var allow_shell_commands := false
var cancel_requested := false
# One owned shell job at a time; the queue is serial. The dock starts the
# coroutine and polls it so the editor thread never blocks.
var shell_job_running := false
var shell_job_cancelled := false
var shell_job_pid := 0
var shell_job_stage := ""
var shell_job_result: Dictionary = {}

func _init(p_root := "") -> void:
	project_root = str(p_root).strip_edges()
	if project_root.is_empty():
		project_root = ProjectSettings.globalize_path("res://")
	project_root = project_root.simplify_path().trim_suffix("/")

func definitions() -> Array:
	return [
		{
			"name": "list_files",
			"title": "List workspace files",
			"description": "List files and directories inside the project. Paths are res:// or project-relative; .git/.godot and credential paths are excluded.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"recursive": {"type": "boolean"},
				"max_entries": {"type": "integer", "minimum": 1, "maximum": 2000},
			}, "required": ["path"], "additionalProperties": false},
			"risk": "read", "timeout_ms": 15000, "mode": "workspace",
		},
		{
			"name": "read_file",
			"title": "Read workspace text file",
			"description": "Read a bounded, root-confined text file and its SHA-256. Binary assets return metadata only. Editing requires the returned hash.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"offset": {"type": "integer", "minimum": 1},
				"limit": {"type": "integer", "minimum": 1, "maximum": 1000},
				"max_bytes": {"type": "integer", "minimum": 1024, "maximum": 262144},
			}, "required": ["path"], "additionalProperties": false},
			"risk": "read", "timeout_ms": 15000, "mode": "workspace",
		},
		{
			"name": "search_text",
			"title": "Search project text",
			"description": "Literal (default) or explicitly requested regex search across project text files. Binary files are skipped; results are bounded.",
			"parameters": {"type": "object", "properties": {
				"query": {"type": "string", "minLength": 1, "maxLength": 500},
				"glob": {"type": "string", "maxLength": 256},
				"max_matches": {"type": "integer", "minimum": 1, "maximum": 500},
				"regex": {"type": "boolean"},
			}, "required": ["query"], "additionalProperties": false},
			"risk": "read", "timeout_ms": 30000, "mode": "workspace",
		},
		{
			"name": "file_info",
			"title": "Workspace file information",
			"description": "Return type, size, SHA-256 for files, modified time, and binary state for a root-confined path. Symlinks are rejected rather than followed.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
			}, "required": ["path"], "additionalProperties": false},
			"risk": "read", "timeout_ms": 10000, "mode": "workspace",
		},
		{
			"name": "write_file",
			"title": "Write workspace file",
			"description": "Atomically write a bounded text file. Overwriting requires the current SHA-256; creating requires create:true. GDScript is parse-checked before commit. Not scene-undoable.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"content": {"type": "string", "maxLength": 1048576},
				"expected_sha256": {"type": "string", "minLength": 64, "maxLength": 64},
				"create": {"type": "boolean"},
			}, "required": ["path", "content"], "additionalProperties": false},
			"risk": "mutating", "timeout_ms": 20000, "mode": "workspace",
		},
		{
			"name": "apply_patch",
			"title": "Apply workspace patch",
			"description": "Apply one exact old/new block or a unified-diff subset to a text file after verifying its SHA-256. Rejects stale hashes, ambiguous context, and partial application.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"expected_sha256": {"type": "string", "minLength": 64, "maxLength": 64},
				"patch": {"type": "string", "minLength": 1, "maxLength": 1048576},
			}, "required": ["path", "expected_sha256", "patch"], "additionalProperties": false},
			"risk": "mutating", "timeout_ms": 20000, "mode": "workspace",
		},
		{
			"name": "create_file",
			"title": "Create workspace file",
			"description": "Create a new text file after explicit user approval. Never overwrites; fails if the path exists.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"content": {"type": "string", "maxLength": 1048576},
				"reason": {"type": "string", "maxLength": 1000},
			}, "required": ["path", "content"], "additionalProperties": false},
			"risk": "mutating", "timeout_ms": 20000, "mode": "workspace",
		},
		{
			"name": "move_file",
			"title": "Move workspace file",
			"description": "Move a file inside the project after explicit user approval. Verifies the source SHA-256, refuses existing destinations, and never overwrites.",
			"parameters": {"type": "object", "properties": {
				"source": {"type": "string", "minLength": 1, "maxLength": 512},
				"target": {"type": "string", "minLength": 1, "maxLength": 512},
				"expected_sha256": {"type": "string", "minLength": 64, "maxLength": 64},
				"reason": {"type": "string", "maxLength": 1000},
			}, "required": ["source", "target", "expected_sha256"], "additionalProperties": false},
			"risk": "mutating", "timeout_ms": 20000, "mode": "workspace",
		},
		{
			"name": "delete_file",
			"title": "Delete workspace file",
			"description": "Delete one text file after explicit user approval. Requires the current SHA-256 and refuses directories.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"expected_sha256": {"type": "string", "minLength": 64, "maxLength": 64},
				"reason": {"type": "string", "maxLength": 1000},
			}, "required": ["path", "expected_sha256"], "additionalProperties": false},
			"risk": "destructive", "timeout_ms": 20000, "mode": "workspace",
		},
		{
			"name": "git_status",
			"title": "Git status",
			"description": "Read-only, root-confined git status for the project. No network or history-rewriting commands.",
			"parameters": {"type": "object", "properties": {}, "additionalProperties": false},
			"risk": "read", "timeout_ms": 20000, "mode": "workspace",
		},
		{
			"name": "git_diff",
			"title": "Git diff",
			"description": "Read-only, bounded git diff. Optionally limit to one project path and request the staged diff.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "maxLength": 512},
				"staged": {"type": "boolean"},
				"max_chars": {"type": "integer", "minimum": 200, "maximum": 40000},
			}, "additionalProperties": false},
			"risk": "read", "timeout_ms": 20000, "mode": "workspace",
		},
		{
			"name": "git_log",
			"title": "Git log",
			"description": "Read-only, bounded git log for the project.",
			"parameters": {"type": "object", "properties": {
				"max_count": {"type": "integer", "minimum": 1, "maximum": 50},
			}, "additionalProperties": false},
			"risk": "read", "timeout_ms": 20000, "mode": "workspace",
		},
		{
			"name": "run_godot_headless",
			"title": "Run Godot headless",
			"description": "Run the editor binary against the project with an allowlisted argument list. Godot scripts execute project code on the host, so this requires the allow_shell_commands setting and explicit per-run approval. Bounded output and timeout; the owned process group is cleaned up.",
			"parameters": {"type": "object", "properties": {
				"args": {"type": "array", "maxItems": 32, "items": {"type": "string", "minLength": 1, "maxLength": 512}},
				"timeout_ms": {"type": "integer", "minimum": 1000, "maximum": 300000},
			}, "required": ["args"], "additionalProperties": false},
			"risk": "long_running", "timeout_ms": 300000, "mode": "workspace",
		},
		{
			"name": "verify_scene_runtime",
			"title": "Verify scene runtime",
			"description": "Run a saved scene headlessly and report measured body motion plus scene-load, error, gravity, landing, and jump checks. Optional input actions. Requires allow_shell_commands and per-run approval; no scene edits.",
			"parameters": {"type": "object", "properties": {
				"scene_path": {"type": "string", "minLength": 1, "maxLength": 512},
				"frames": {"type": "integer", "minimum": 10, "maximum": 600},
				"actions": {"type": "array", "maxItems": 4, "items": {"type": "object", "properties": {
					"action": {"type": "string", "minLength": 1, "maxLength": 64},
					"frame": {"type": "integer", "minimum": 1, "maximum": 600},
					"hold": {"type": "integer", "minimum": 1, "maximum": 120},
				}, "required": ["action"], "additionalProperties": false}},
				"checks": {"type": "array", "maxItems": 5, "items": {"type": "string", "enum": ["scene_loads", "no_errors", "gravity", "lands", "jump"]}},
				"timeout_ms": {"type": "integer", "minimum": 1000, "maximum": 120000},
			}, "additionalProperties": false},
			"risk": "long_running", "timeout_ms": 120000, "mode": "both",
		},
		{
			"name": "run_command",
			"title": "Run host command (gated)",
			"description": "Run a shell command inside the project root. Disabled unless the advanced allow_shell_commands setting is enabled and the user explicitly approves this command. Host code execution.",
			"parameters": {"type": "object", "properties": {
				"command": {"type": "string", "minLength": 1, "maxLength": 4000},
				"cwd": {"type": "string", "maxLength": 512},
				"timeout_ms": {"type": "integer", "minimum": 1000, "maximum": 300000},
			}, "required": ["command"], "additionalProperties": false},
			"risk": "destructive", "timeout_ms": 300000, "mode": "workspace",
		},
		{
			"name": "reload_scene",
			"title": "Reload scene from disk",
			"description": "Reload an open scene after external edits. Refuses a dirty scene unless discard_unsaved is explicitly true, so unsaved editor state is never silently lost.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"discard_unsaved": {"type": "boolean"},
			}, "required": ["path"], "additionalProperties": false},
			"risk": "mutating", "timeout_ms": 20000, "mode": "both",
		},
		{
			"name": "scan_filesystem",
			"title": "Scan project files",
			"description": "Rescan the editor filesystem after external file changes so imports and scripts resolve.",
			"parameters": {"type": "object", "properties": {}, "additionalProperties": false},
			"risk": "read", "timeout_ms": 30000, "mode": "both",
		},
		{
			"name": "check_gdscript",
			"title": "Check GDScript",
			"description": "Compile GDScript in memory and return the first error with its line, plus base class, methods, signals, and target compatibility. Writes and runs nothing. @tool is ignored; preloading another .gd is refused.",
			"parameters": {"type": "object", "properties": {
				"source": {"type": "string", "minLength": 1, "maxLength": 100000},
				"target_class": {"type": "string", "minLength": 1, "maxLength": 128},
			}, "required": ["source"], "additionalProperties": false},
			"risk": "read", "timeout_ms": 5000, "mode": "both",
		},
		{
			"name": "lookup_docs",
			"title": "Look up Godot docs",
			"description": "Look up the built-in Godot class reference offline. Use class_name for a class summary, member for a method, property, signal, or constant (exact or partial), or query to search class names. Returns signatures and documentation; read-only and no process.",
			"parameters": {"type": "object", "properties": {
				"class_name": {"type": "string", "minLength": 1, "maxLength": 128},
				"member": {"type": "string", "minLength": 1, "maxLength": 128},
				"query": {"type": "string", "minLength": 1, "maxLength": 128},
			}, "additionalProperties": false},
			"risk": "read", "timeout_ms": 15000, "mode": "both",
		},
		{
			"name": "find_assets",
			"title": "Find project assets",
			"description": "List existing project images, models, audio, scenes, scripts, and resources with size, image dimensions and average color, alpha, and files that reference them. Use it before generating or importing an asset; reuse an existing path instead of creating a duplicate.",
			"parameters": {"type": "object", "properties": {
				"kind": {"type": "string", "enum": ["all", "image", "model", "audio", "scene", "script", "resource"]},
				"query": {"type": "string", "maxLength": 128},
				"path": {"type": "string", "maxLength": 512},
				"max": {"type": "integer", "minimum": 1, "maximum": 100},
				"used": {"type": "boolean"},
			}, "additionalProperties": false},
			"risk": "read", "timeout_ms": 20000, "mode": "both",
		},
		{
			"name": "capture_scene_view",
			"title": "Capture scene view",
			"description": "Capture the editor's rendered 2D or 3D view into a local image for the next model request. Requires a vision-capable coding model; read-only and does not save into the project.",
			"parameters": {"type": "object", "properties": {
				"view": {"type": "string", "enum": ["2d", "3d"]},
				"max_px": {"type": "integer", "minimum": 128, "maximum": 1024},
			}, "additionalProperties": false},
			"risk": "read", "timeout_ms": 10000, "mode": "both",
		},
		{
			"name": "capture_player_view",
			"title": "Capture player view",
			"description": "Capture the running player output when the editor exposes an embedded game view. Returns a precise unavailable result when the game window is external, because the whole editor UI is not the game.",
			"parameters": {"type": "object", "properties": {
				"max_px": {"type": "integer", "minimum": 128, "maximum": 1024},
			}, "additionalProperties": false},
			"risk": "read", "timeout_ms": 10000, "mode": "both",
		},
	]

func execute(name: String, arguments: Dictionary, _context: Dictionary = {}) -> Dictionary:
	cancel_requested = false
	match name:
		"list_files": return _list_files(arguments)
		"read_file": return _read_file(arguments)
		"search_text": return _search_text(arguments)
		"file_info": return _file_info(arguments)
		"write_file": return await _write_file(arguments)
		"apply_patch": return _apply_patch(arguments)
		"create_file": return await _create_file(arguments)
		"move_file": return await _move_file(arguments)
		"delete_file": return await _delete_file(arguments)
		"git_status": return await _git(["status", "--short", "--branch", "--", "."] + _git_excludes(), "Git status", 20000)
		"git_diff": return await _git_diff(arguments)
		"git_log": return await _git_log(arguments)
		"run_godot_headless": return await _run_godot_headless(arguments)
		"verify_scene_runtime": return await _verify_scene_runtime(arguments)
		"run_command": return await _run_command(arguments)
		"reload_scene": return await _reload_scene(arguments)
		"scan_filesystem": return _scan_filesystem()
		"check_gdscript": return _check_gdscript(arguments)
		"lookup_docs": return _lookup_docs(arguments)
		"find_assets": return _find_assets(arguments)
		"capture_scene_view": return await _capture_scene_view(arguments)
		"capture_player_view": return _capture_player_view(arguments)
	return _error("unknown_tool", "Unknown workspace tool: " + name)

### Paths

func _project_root_denies(parts: Array) -> Dictionary:
	for part in parts:
		var lower := str(part).to_lower()
		if DENIED_DIRS.has(lower):
			return _error("denied_path", "The path contains editor or repository internals: " + lower)
		if DENIED_FILES.has(lower):
			return _error("denied_path", "The path looks like a credential file: " + lower)
	return {}

func _canonical(raw: String, allow_root := true) -> Dictionary:
	var input := raw.strip_edges()
	if input.is_empty():
		input = "res://"
	if input.contains("\n") or input.contains("\r") or _has_nul(input) or input.contains("\\"):
		return _error("invalid_path", "The path contains invalid characters.")
	if input.begins_with("user://") or input.begins_with("uid://") or input.begins_with("uid:") or input.begins_with("~"):
		return _error("path_escape", "Only res:// or project-relative paths are allowed.")
	if input.begins_with("/") or (input.length() >= 2 and input[1] == ":"):
		return _error("path_escape", "Absolute paths outside the project root are rejected.")
	var relative := input.trim_prefix("res://")
	var parts: Array[String] = []
	for part in relative.split("/", false):
		if part == ".":
			continue
		if part == "..":
			return _error("path_escape", "Parent traversal is rejected.")
		parts.append(part)
	if parts.is_empty() and not allow_root:
		return _error("invalid_path", "A file path is required.")
	var denied := _project_root_denies(parts)
	if not denied.is_empty():
		return denied
	var relative_path := "/".join(parts)
	var absolute := project_root if relative_path.is_empty() else project_root.path_join(relative_path)
	absolute = absolute.simplify_path()
	var root := project_root.simplify_path().trim_suffix("/")
	if absolute != root and not absolute.begins_with(root + "/"):
		return _error("path_escape", "The resolved path leaves the project root.")
	var cursor := root
	for index in parts.size():
		var dir := DirAccess.open(cursor)
		if dir == null:
			break
		if dir.is_link(parts[index]):
			return _error("symlink_rejected", "Symlinks are rejected for workspace access: " + "/".join(parts.slice(0, index + 1)))
		cursor = cursor.path_join(parts[index])
	return {"absolute": absolute, "res": "res://" + relative_path, "relative": relative_path}

func _existing_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _error("not_found", "File does not exist: " + path)
	return {}

### Read tools

const MAX_PROJECT_INSTRUCTIONS_BYTES := 8192

# Root project instructions. This is project data, read directly rather than
# through the workspace tool mode. Invalid UTF-8 and symlinks are rejected.
func read_project_instructions() -> Dictionary:
	var resolved := _canonical("res://AGENTS.md", false)
	if resolved.has("error"): return resolved
	if not FileAccess.file_exists(str(resolved.absolute)):
		return _error("not_found", "AGENTS.md is not present.")
	var file := FileAccess.open(str(resolved.absolute), FileAccess.READ)
	if file == null:
		return _error("unreadable", "AGENTS.md could not be read.")
	var total := int(file.get_length())
	var bytes := file.get_buffer(mini(total, MAX_PROJECT_INSTRUCTIONS_BYTES))
	file.close()
	var truncated := total > MAX_PROJECT_INSTRUCTIONS_BYTES
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		# A byte-bounded prefix may cut a multi-byte character. Trim only while
		# the file was truncated; otherwise the file itself is not UTF-8.
		while truncated and not bytes.is_empty() and text.to_utf8_buffer() != bytes:
			bytes = bytes.slice(0, bytes.size() - 1)
			text = bytes.get_string_from_utf8()
		if text.to_utf8_buffer() != bytes:
			return _error("not_utf8", "AGENTS.md is not valid UTF-8 text.")
	if text.find(String.chr(0)) >= 0:
		return _error("not_utf8", "AGENTS.md is not text.")
	return {"ok": true, "text": text, "sha256": text.sha256_text(), "truncated": truncated}

func _list_files(arguments: Dictionary) -> Dictionary:
	var resolved := _canonical(str(arguments.get("path", "res://")))
	if resolved.has("error"): return resolved
	if FileAccess.file_exists(str(resolved.absolute)):
		return _error("is_file", "The path is a file; use read_file or file_info.")
	if not DirAccess.dir_exists_absolute(str(resolved.absolute)):
		return _error("not_found", "Directory does not exist: " + str(resolved.res))
	var recursive := bool(arguments.get("recursive", false))
	var limit := clampi(int(arguments.get("max_entries", 500)), 1, MAX_LIST_ENTRIES)
	var entries: Array = []
	var truncated := false
	var stack: Array = [{"absolute": str(resolved.absolute), "res": str(resolved.res), "depth": 0}]
	while not stack.is_empty() and not truncated:
		var current: Dictionary = stack.pop_back()
		var dir := DirAccess.open(str(current.absolute))
		if dir == null:
			continue
		var dirs: Array = []
		var files: Array = []
		dir.list_dir_begin()
		var entry := dir.get_next()
		while not entry.is_empty():
			if entry != "." and entry != ".." and not dir.is_link(entry):
				var lower := entry.to_lower()
				if not DENIED_DIRS.has(lower) and not DENIED_FILES.has(lower):
					if dir.current_is_dir():
						dirs.append(entry)
					else:
						files.append(entry)
			entry = dir.get_next()
		dir.list_dir_end()
		dirs.sort()
		files.sort()
		for name in dirs:
			if entries.size() >= limit:
				truncated = true
				break
			var child_abs := str(current.absolute).path_join(name)
			var child_res := str(current.res).path_join(name)
			entries.append({"path": child_res, "type": "dir", "size": 0})
			if recursive and int(current.depth) < MAX_RECURSION:
				stack.append({"absolute": child_abs, "res": child_res, "depth": int(current.depth) + 1})
		for name in files:
			if entries.size() >= limit:
				truncated = true
				break
			var child_abs := str(current.absolute).path_join(name)
			var file_res := str(current.res).path_join(name)
			entries.append({"path": file_res, "type": "file", "size": _file_size(child_abs)})
	entries.sort_custom(func(a, b): return str(a.path) < str(b.path))
	return {
		"ok": true,
		"summary": "Listed %d entries in %s%s." % [entries.size(), str(resolved.res), ", truncated" if truncated else ""],
		"data": {"path": str(resolved.res), "entries": entries, "truncated": truncated, "recursive": recursive},
		"affected": [],
	}

func _read_file(arguments: Dictionary) -> Dictionary:
	var resolved := _canonical(str(arguments.get("path", "")))
	if resolved.has("error"): return resolved
	var absolute := str(resolved.absolute)
	var missing := _existing_file(absolute)
	if not missing.is_empty(): return missing
	if DirAccess.dir_exists_absolute(absolute):
		return _error("is_directory", "The path is a directory: " + str(resolved.res))
	var sha := FileAccess.get_sha256(absolute)
	var size := _file_size(absolute)
	var max_bytes := clampi(int(arguments.get("max_bytes", MAX_READ_BYTES)), 1024, MAX_READ_BYTES)
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return _error("read_failed", "Could not open the file (error %d)." % FileAccess.get_open_error())
	var bytes := file.get_buffer(mini(size, max_bytes))
	file.close()
	if _is_binary(str(resolved.res), bytes):
		return {"ok": true, "summary": "Read metadata for binary file %s (%d bytes); no content returned." % [str(resolved.res), size], "data": {"path": str(resolved.res), "sha256": sha, "size": size, "content": "", "binary": true, "truncated": size > max_bytes}, "affected": []}
	var text := bytes.get_string_from_utf8()
	var lines := text.split("\n")
	var offset := clampi(int(arguments.get("offset", 1)), 1, maxi(1, lines.size()))
	var limit := clampi(int(arguments.get("limit", 400)), 1, MAX_READ_LINES)
	var selected: Array = lines.slice(offset - 1, mini(lines.size(), offset - 1 + limit))
	var content := "\n".join(selected)
	var truncated := offset > 1 or offset - 1 + limit < lines.size() or size > max_bytes
	return {
		"ok": true,
		"summary": "Read %s (%d bytes, lines %d-%d%s)." % [str(resolved.res), size, offset, offset - 1 + selected.size(), ", truncated" if truncated else ""],
		"data": {"path": str(resolved.res), "sha256": sha, "size": size, "content": content, "binary": false, "truncated": truncated, "line_count": lines.size(), "offset": offset, "limit": limit},
		"affected": [],
	}

func _search_text(arguments: Dictionary) -> Dictionary:
	var query := str(arguments.get("query", ""))
	if query.is_empty() or query.length() > 500:
		return _error("invalid_arguments", "Search requires a query of 1-500 characters.")
	var glob := str(arguments.get("glob", "**/*")).strip_edges()
	if glob.is_empty(): glob = "**/*"
	var use_regex := bool(arguments.get("regex", false))
	var limit := clampi(int(arguments.get("max_matches", 200)), 1, MAX_SEARCH_MATCHES)
	var regex: RegEx = null
	if use_regex:
		regex = RegEx.new()
		if regex.compile(query) != OK:
			return _error("invalid_arguments", "The regular expression could not be compiled.")
	var matches: Array = []
	var files_scanned := 0
	var truncated := false
	var stack: Array = [{"absolute": project_root, "res": "res://", "depth": 0}]
	while not stack.is_empty() and not truncated:
		var current: Dictionary = stack.pop_back()
		var dir := DirAccess.open(str(current.absolute))
		if dir == null: continue
		var dirs: Array = []
		var files: Array = []
		dir.list_dir_begin()
		var entry := dir.get_next()
		while not entry.is_empty():
			if entry != "." and entry != ".." and not dir.is_link(entry) and not DENIED_DIRS.has(entry.to_lower()) and not DENIED_FILES.has(entry.to_lower()):
				if dir.current_is_dir(): dirs.append(entry)
				else: files.append(entry)
			entry = dir.get_next()
		dir.list_dir_end()
		dirs.sort()
		files.sort()
		for name in dirs:
			if int(current.depth) < MAX_RECURSION:
				stack.append({"absolute": str(current.absolute).path_join(name), "res": str(current.res).path_join(name), "depth": int(current.depth) + 1})
		for name in files:
			if files_scanned >= MAX_SEARCH_FILES:
				truncated = true
				break
			var file_res := str(current.res).path_join(name)
			var relative := file_res.trim_prefix("res://")
			if not _glob_matches(glob, relative):
				continue
			if BINARY_EXTENSIONS.has(relative.get_extension().to_lower()):
				continue
			var absolute := str(current.absolute).path_join(name)
			if not FileAccess.file_exists(absolute):
				continue
			var size := _file_size(absolute)
			if size > MAX_READ_BYTES:
				continue
			var file := FileAccess.open(absolute, FileAccess.READ)
			if file == null: continue
			var bytes := file.get_buffer(size)
			file.close()
			if _is_binary(file_res, bytes):
				continue
			files_scanned += 1
			var text := bytes.get_string_from_utf8()
			var lines := text.split("\n")
			for line_index in lines.size():
				var line := lines[line_index].trim_suffix("\r")
				var column := -1
				if use_regex:
					var found := regex.search(line)
					if found != null: column = found.get_start()
				else:
					column = line.find(query)
				if column < 0:
					continue
				matches.append({"path": file_res, "line": line_index + 1, "column": column + 1, "text": line.left(MAX_LINE_CHARS)})
				if matches.size() >= limit:
					truncated = true
					break
			if truncated:
				break
	return {
		"ok": true,
		"summary": "Found %d match%s for %s%s." % [matches.size(), "" if matches.size() == 1 else "es", JSON.stringify(query), ", truncated" if truncated else ""],
		"data": {"query": query, "glob": glob, "regex": use_regex, "matches": matches, "truncated": truncated, "files_scanned": files_scanned},
		"affected": [],
	}

func _file_info(arguments: Dictionary) -> Dictionary:
	var resolved := _canonical(str(arguments.get("path", "")))
	if resolved.has("error"): return resolved
	var absolute := str(resolved.absolute)
	var is_dir := DirAccess.dir_exists_absolute(absolute)
	var is_file := FileAccess.file_exists(absolute)
	if not is_dir and not is_file:
		return _error("not_found", "Path does not exist: " + str(resolved.res))
	var data := {"path": str(resolved.res), "absolute": absolute, "type": "dir" if is_dir else "file", "size": 0, "sha256": "", "modified": 0, "binary": false, "symlink": false}
	if is_file:
		data.size = _file_size(absolute)
		data.sha256 = FileAccess.get_sha256(absolute)
		data.binary = BINARY_EXTENSIONS.has(str(resolved.res).get_extension().to_lower())
	if is_dir or is_file:
		data.modified = FileAccess.get_modified_time(absolute)
	return {"ok": true, "summary": "%s is a %s (%d bytes)." % [str(resolved.res), str(data.type), int(data.size)], "data": data, "affected": []}

### Writes and patches

func _write_file(arguments: Dictionary) -> Dictionary:
	return await _write_candidate(str(arguments.get("path", "")), str(arguments.get("content", "")), str(arguments.get("expected_sha256", "")), bool(arguments.get("create", false)), true)

func _create_file(arguments: Dictionary) -> Dictionary:
	var path := str(arguments.get("path", ""))
	var content := str(arguments.get("content", ""))
	var resolved := _canonical(path, false)
	if resolved.has("error"): return resolved
	if FileAccess.file_exists(str(resolved.absolute)):
		return _error("file_exists", "Refusing to overwrite an existing file: " + str(resolved.res))
	if content.to_utf8_buffer().size() > MAX_WRITE_BYTES:
		return _error("too_large", "Refusing to write more than 1 MiB.")
	if str(resolved.res).ends_with(".gd"):
		var script_error := _validate_script(content)
		if not script_error.is_empty(): return script_error
	var approved := await _ask_edit("create", str(resolved.res), str(arguments.get("reason", "")))
	if not approved.is_empty(): return approved
	return await _write_candidate(path, content, "", true, false)

func _write_candidate(path: String, content: String, expected_sha256: String, create: bool, require_approval := true) -> Dictionary:
	var resolved := _canonical(path, false)
	if resolved.has("error"): return resolved
	var absolute := str(resolved.absolute)
	if DirAccess.dir_exists_absolute(absolute):
		return _error("is_directory", "The path is a directory: " + str(resolved.res))
	if content.to_utf8_buffer().size() > MAX_WRITE_BYTES:
		return _error("too_large", "Refusing to write more than 1 MiB.")
	var exists := FileAccess.file_exists(absolute)
	var before_sha := ""
	if exists:
		if create:
			return _error("file_exists", "Refusing to overwrite an existing file: " + str(resolved.res))
		if expected_sha256.length() != 64 or not expected_sha256.is_valid_hex_number(false):
			return _error("missing_hash", "Overwriting %s requires the current 64-character SHA-256; read the file first." % str(resolved.res))
		before_sha = FileAccess.get_sha256(absolute)
		if before_sha != expected_sha256:
			return _error("stale_hash", "The file changed since it was read (current SHA-256 %s); no write was applied." % before_sha)
	else:
		if not create:
			return _error("missing_file", "The file does not exist; pass create:true to create it.")
		var parent := absolute.get_base_dir()
		if not DirAccess.dir_exists_absolute(parent):
			return _error("not_found", "The parent directory does not exist: " + parent)
		if require_approval:
			var create_approval := await _ask_edit("create", str(resolved.res), "write_file with create:true")
			if not create_approval.is_empty(): return create_approval
			# Approval yields to other processes; do not follow a parent that was
			# replaced with a symlink while the dialog was open.
			var checked_path := _canonical(str(resolved.res), false)
			if checked_path.has("error"): return checked_path
	var dirty := _dirty_scene_error(str(resolved.res))
	if not dirty.is_empty(): return dirty
	if str(resolved.res).ends_with(".gd"):
		var error := _validate_script(content)
		if not error.is_empty(): return error
	var before_text := FileAccess.get_file_as_string(absolute) if exists else ""
	var committed := _atomic_write(absolute, content, before_sha, not exists)
	if committed.has("error"): return committed
	_notify_scan()
	return {
		"ok": true,
		"summary": "%s %s (%d bytes). File edits are not scene-undoable." % ["Wrote" if exists else "Created", str(resolved.res), content.to_utf8_buffer().size()],
		"data": {"path": str(resolved.res), "before_sha256": before_sha, "after_sha256": FileAccess.get_sha256(absolute), "created": not exists, "diff": _bounded_diff(before_text, content), "undo": "not scene-undoable"},
		"affected": [{"kind": "file", "path": str(resolved.res)}],
	}

func _apply_patch(arguments: Dictionary) -> Dictionary:
	var resolved := _canonical(str(arguments.get("path", "")), false)
	if resolved.has("error"): return resolved
	var missing := _existing_file(str(resolved.absolute))
	if not missing.is_empty(): return missing
	if DirAccess.dir_exists_absolute(str(resolved.absolute)):
		return _error("is_directory", "The path is a directory: " + str(resolved.res))
	if BINARY_EXTENSIONS.has(str(resolved.res).get_extension().to_lower()):
		return _error("binary_file", "Refusing to patch a binary file: " + str(resolved.res))
	var expected := str(arguments.get("expected_sha256", ""))
	if expected.length() != 64 or not expected.is_valid_hex_number(false):
		return _error("missing_hash", "Patching requires the current 64-character SHA-256 of the file.")
	var before_sha := FileAccess.get_sha256(str(resolved.absolute))
	if before_sha != expected:
		return _error("stale_hash", "The file changed since it was read (current SHA-256 %s); no patch was applied." % before_sha)
	var source := FileAccess.get_file_as_string(str(resolved.absolute))
	var patch := str(arguments.get("patch", ""))
	if patch.is_empty():
		return _error("invalid_patch", "The patch is empty.")
	var exact_markers := patch.contains("<<<<<<<") and patch.contains("=======") and patch.contains(">>>>>>>")
	var patched := _apply_exact_block(source, patch) if exact_markers else _apply_unified(source, patch)
	if patched.has("error"): return patched
	if patched.get("unchanged", false):
		return _error("invalid_patch", "The patch did not change the file.")
	var candidate := str(patched.content)
	if candidate.to_utf8_buffer().size() > MAX_WRITE_BYTES:
		return _error("too_large", "Refusing to write a result larger than 1 MiB.")
	var dirty := _dirty_scene_error(str(resolved.res))
	if not dirty.is_empty(): return dirty
	if str(resolved.res).ends_with(".gd"):
		var error := _validate_script(candidate)
		if not error.is_empty(): return error
	var committed := _atomic_write(str(resolved.absolute), candidate, before_sha, false)
	if committed.has("error"): return committed
	_notify_scan()
	var diff := _bounded_diff(source, candidate)
	return {
		"ok": true,
		"summary": "Patched %s (%d hunks). File edits are not scene-undoable." % [str(resolved.res), int(patched.get("hunks", 1))],
		"data": {"path": str(resolved.res), "before_sha256": before_sha, "after_sha256": FileAccess.get_sha256(str(resolved.absolute)), "hunks": int(patched.get("hunks", 1)), "diff": diff, "undo": "not scene-undoable"},
		"affected": [{"kind": "file", "path": str(resolved.res)}],
	}

func _move_file(arguments: Dictionary) -> Dictionary:
	var source := _canonical(str(arguments.get("source", "")), false)
	if source.has("error"): return source
	var target := _canonical(str(arguments.get("target", "")), false)
	if target.has("error"): return target
	if str(source.res) == str(target.res):
		return _error("invalid_arguments", "Source and target are the same path.")
	var missing := _existing_file(str(source.absolute))
	if not missing.is_empty(): return missing
	var dirty := _dirty_scene_error(str(source.res))
	if not dirty.is_empty(): return dirty
	if FileAccess.file_exists(str(target.absolute)):
		return _error("file_exists", "The target already exists; refusing to overwrite: " + str(target.res))
	var expected := str(arguments.get("expected_sha256", ""))
	var before_sha := FileAccess.get_sha256(str(source.absolute))
	if expected != before_sha:
		return _error("stale_hash", "The source changed since it was read (current SHA-256 %s); no move was applied." % before_sha)
	if not DirAccess.dir_exists_absolute(str(target.absolute).get_base_dir()):
		return _error("not_found", "The target directory does not exist.")
	var approved := await _ask_edit("move", str(source.res), str(arguments.get("reason", "")))
	if not approved.is_empty(): return approved
	# The approval dialog yields to other editors and processes. Revalidate both
	# path components before following either path again.
	var checked_source := _canonical(str(source.res), false)
	if checked_source.has("error"): return checked_source
	var checked_target := _canonical(str(target.res), false)
	if checked_target.has("error"): return checked_target
	dirty = _dirty_scene_error(str(source.res))
	if not dirty.is_empty(): return dirty
	if before_commit.is_valid():
		before_commit.call(str(target.absolute), "move")
	if FileAccess.get_sha256(str(source.absolute)) != before_sha:
		return _error("stale_hash", "The source changed while approval was pending; no move was applied.")
	if FileAccess.file_exists(str(target.absolute)):
		return _error("file_exists", "The target appeared while approval was pending; nothing was overwritten.")
	var linked := _link_no_replace(str(source.absolute), str(target.absolute))
	if linked != 0:
		if FileAccess.file_exists(str(target.absolute)):
			return _error("file_exists", "The target appeared while approval was pending; nothing was overwritten.")
		if FileAccess.get_sha256(str(source.absolute)) != before_sha:
			return _error("stale_hash", "The source changed again before commit; no move was applied.")
		return _error("write_failed", "Could not move the file without overwriting; the source was preserved (hard links may be unsupported here).")
	else:
		var remove_error := DirAccess.remove_absolute(str(source.absolute))
		if remove_error != OK:
			return _error("write_failed", "The target was created but the source could not be removed; both files remain (error %d)." % remove_error)
	_notify_scan()
	return {
		"ok": true,
		"summary": "Moved %s to %s. File edits are not scene-undoable." % [str(source.res), str(target.res)],
		"data": {"source": str(source.res), "path": str(target.res), "before_sha256": before_sha, "after_sha256": FileAccess.get_sha256(str(target.absolute)), "undo": "not scene-undoable"},
		"affected": [{"kind": "file", "path": str(target.res)}],
	}

func _delete_file(arguments: Dictionary) -> Dictionary:
	var resolved := _canonical(str(arguments.get("path", "")), false)
	if resolved.has("error"): return resolved
	var missing := _existing_file(str(resolved.absolute))
	if not missing.is_empty(): return missing
	var before_sha := FileAccess.get_sha256(str(resolved.absolute))
	if str(arguments.get("expected_sha256", "")) != before_sha:
		return _error("stale_hash", "The file changed since it was read (current SHA-256 %s); nothing was deleted." % before_sha)
	var dirty := _dirty_scene_error(str(resolved.res))
	if not dirty.is_empty(): return dirty
	if not str(resolved.res).ends_with(".gd") and _file_size(str(resolved.absolute)) > MAX_WRITE_BYTES:
		return _error("too_large", "Refusing to delete files larger than 1 MiB without direct editor action.")
	var approved := await _ask_edit("delete", str(resolved.res), str(arguments.get("reason", "")))
	if not approved.is_empty(): return approved
	var checked_path := _canonical(str(resolved.res), false)
	if checked_path.has("error"): return checked_path
	dirty = _dirty_scene_error(str(resolved.res))
	if not dirty.is_empty(): return dirty
	if before_commit.is_valid():
		before_commit.call(str(resolved.absolute), "delete")
	if FileAccess.get_sha256(str(resolved.absolute)) != before_sha:
		return _error("stale_hash", "The file changed while approval was pending; nothing was deleted.")
	var error := DirAccess.remove_absolute(str(resolved.absolute))
	if error != OK:
		return _error("write_failed", "Could not delete the file (error %d)." % error)
	_notify_scan()
	return {
		"ok": true,
		"summary": "Deleted %s. File edits are not scene-undoable." % str(resolved.res),
		"data": {"path": str(resolved.res), "before_sha256": before_sha, "deleted": true, "undo": "not scene-undoable"},
		"affected": [{"kind": "file", "path": str(resolved.res)}],
	}

func _ask_edit(action: String, path: String, reason: String) -> Dictionary:
	if not approve_edit.is_valid():
		return _error("approval_required", "Explicit user approval is required to %s %s." % [action, path])
	var approved: Variant = await approve_edit.call(action, path, reason)
	if not bool(approved):
		return _error("approval_required", "The user did not approve the %s of %s." % [action, path])
	return {}

func _atomic_write(absolute: String, content: String, expected_sha256: String, create_only: bool) -> Dictionary:
	var temporary := absolute + ".tiiny-tmp-" + Crypto.new().generate_random_bytes(6).hex_encode()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _error("write_failed", "Could not open a temporary file (error %d)." % FileAccess.get_open_error())
	file.store_string(content)
	file.flush()
	file.close()
	var expected_hash := content.sha256_text()
	if FileAccess.get_sha256(temporary) != expected_hash:
		DirAccess.remove_absolute(temporary)
		return _error("write_failed", "The temporary file did not match the requested content; the file was not changed.")
	if before_commit.is_valid():
		before_commit.call(absolute, "create" if create_only else "overwrite")
	if create_only:
		if FileAccess.file_exists(absolute):
			DirAccess.remove_absolute(temporary)
			return _error("file_exists", "A file appeared at the destination before commit; it was not overwritten: " + absolute)
		var linked := _link_no_replace(temporary, absolute)
		if linked:
			DirAccess.remove_absolute(temporary)
			if FileAccess.file_exists(absolute):
				return _error("file_exists", "A file appeared at the destination before commit; it was not overwritten: " + absolute)
			return _error("write_failed", "Could not commit the new file without overwriting (hard links may be unsupported here).")
		DirAccess.remove_absolute(temporary)
		return {}
	if FileAccess.get_sha256(absolute) != expected_sha256:
		DirAccess.remove_absolute(temporary)
		return _error("stale_hash", "The file changed again before commit; no write was applied.")
	var error := DirAccess.rename_absolute(temporary, absolute)
	if error != OK:
		DirAccess.remove_absolute(temporary)
		return _error("write_failed", "Could not commit the write atomically (error %d); the original file was not changed." % error)
	return {}

func _link_no_replace(source: String, target: String) -> int:
	if OS.get_name() not in ["Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		return -1
	return OS.execute("ln", [source, target])

func _validate_script(source: String) -> Dictionary:
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		return _error("script_invalid", "The updated GDScript failed to parse; the file was not changed.")
	return {}

func _apply_exact_block(source: String, patch: String) -> Dictionary:
	var lines := patch.split("\n")
	var old_start := -1
	var new_start := -1
	var end := -1
	for index in lines.size():
		var line := lines[index].trim_suffix("\r")
		if old_start < 0 and line.begins_with("<<<<<<<"):
			old_start = index + 1
		elif old_start >= 0 and new_start < 0 and line.begins_with("======="):
			new_start = index + 1
		elif new_start >= 0 and line.begins_with(">>>>>>>"):
			end = index
			break
	if old_start < 0 or new_start < 0 or end < 0:
		return _error("invalid_patch", "The patch is neither an exact block nor a unified diff.")
	var old_text := "\n".join(_strip_cr(lines.slice(old_start, new_start - 1)))
	var new_text := "\n".join(_strip_cr(lines.slice(new_start, end)))
	var matches := source.count(old_text)
	if matches != 1:
		return _error("patch_conflict", "The exact old block matched %d times; a unique match is required." % matches)
	return {"content": source.replace(old_text, new_text), "hunks": 1}

func _apply_unified(source: String, patch: String) -> Dictionary:
	var hunks: Array = []
	var current: Dictionary = {}
	var header_seen := false
	for raw_line in patch.split("\n"):
		var line := raw_line.trim_suffix("\r")
		if line.begins_with("@@"):
			if not current.is_empty():
				hunks.append(current)
			var regex := RegEx.new()
			regex.compile("^@@\\s+-(\\d+)(?:,(\\d+))?\\s+\\+(\\d+)(?:,(\\d+))?\\s+@@")
			var found := regex.search(line)
			if found == null:
				return _error("invalid_patch", "Malformed unified-diff hunk header: " + line)
			current = {"start": int(found.get_string(1)), "count": int(found.get_string(2)) if not found.get_string(2).is_empty() else 1, "lines": []}
			header_seen = true
			continue
		if not header_seen:
			continue
		if line.begins_with("---") or line.begins_with("+++"):
			continue
		if current.is_empty():
			continue
		if line.begins_with("\\"):
			continue
		if line.is_empty():
			continue
		var prefix := line.substr(0, 1)
		if prefix == " " or prefix == "-" or prefix == "+":
			current.lines.append({"kind": prefix, "text": line.substr(1)})
		else:
			return _error("invalid_patch", "Unsupported patch line: " + line.left(80))
	if not current.is_empty():
		hunks.append(current)
	if hunks.is_empty():
		return _error("invalid_patch", "The patch contains no hunks.")
	var source_lines := source.split("\n")
	var output: Array = []
	var cursor := 0
	for hunk in hunks:
		var start := int(hunk.start) - 1
		if start < cursor or start > source_lines.size():
			return _error("patch_conflict", "Hunk start %d is out of order or outside the file." % (start + 1))
		output.append_array(source_lines.slice(cursor, start))
		cursor = start
		for entry in hunk.lines:
			if str(entry.kind) == "+":
				output.append(str(entry.text))
				continue
			if cursor >= source_lines.size() or str(source_lines[cursor]) != str(entry.text):
				return _error("patch_conflict", "Hunk context does not match line %d; no patch was applied." % (cursor + 1))
			if str(entry.kind) != "-":
				output.append(str(entry.text))
			cursor += 1
	output.append_array(source_lines.slice(cursor))
	var result := "\n".join(output)
	return {"content": result, "hunks": hunks.size(), "unchanged": result == source}

### Git

func _git(arguments: Array, label: String, timeout_ms: int) -> Dictionary:
	if not DirAccess.dir_exists_absolute(project_root.path_join(".git")):
		return _error("not_a_repository", "The project root is not a git repository.")
	var args: Array = ["-C", project_root, "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]
	args.append_array(arguments)
	var run: Dictionary = await _spawn("git", args, project_root, timeout_ms)
	if run.has("error"): return run
	if int(run.exit_code) != 0 and not str(run.stderr).strip_edges().is_empty():
		return _error("git_failed", _redact(str(run.stderr)).strip_edges().left(2000))
	return {
		"ok": true,
		"summary": "%s collected (%d ms)." % [label, int(run.duration_ms)],
		"data": {"output": _filter_git_output(_redact(str(run.stdout))), "truncated": bool(run.output_truncated), "exit_code": int(run.exit_code)},
		"affected": [],
	}

func _git_diff(arguments: Dictionary) -> Dictionary:
	var args: Array = ["diff", "--no-color", "--no-ext-diff", "--no-textconv"]
	if bool(arguments.get("staged", false)):
		args.append("--cached")
	var path := str(arguments.get("path", "")).strip_edges()
	args.append("--")
	if not path.is_empty():
		var resolved := _canonical(path)
		if resolved.has("error"): return resolved
		args.append(str(resolved.relative))
	else:
		args.append(".")
	args.append_array(_git_excludes())
	var result: Dictionary = await _git(args, "Git diff", 20000)
	if result.has("error"): return result
	var limit := clampi(int(arguments.get("max_chars", 20000)), 200, 40000)
	var output := str(result.data.output)
	result.data.diff = output.left(limit)
	result.data.truncated = bool(result.data.truncated) or output.length() > limit
	result.data.output = result.data.diff
	result.summary = "Collected %d characters of git diff%s." % [result.data.diff.length(), ", truncated" if result.data.truncated else ""]
	return result

func _git_excludes() -> Array:
	var excludes: Array = []
	for name in DENIED_FILES:
		excludes.append(":(exclude,icase)" + name)
		excludes.append(":(exclude,icase)**/" + name)
	for directory in DENIED_DIRS:
		excludes.append(":(exclude,icase)" + directory)
		excludes.append(":(exclude,icase)**/" + directory + "/**")
	return excludes

func _filter_git_output(output: String) -> String:
	var kept: Array = []
	for line in output.split("\n"):
		var lower := line.to_lower()
		var denied := false
		for name in DENIED_FILES + DENIED_DIRS:
			var needle := str(name)
			if lower.contains("/" + needle) or lower.contains(" " + needle) or lower.ends_with(needle) or lower.contains("\t" + needle):
				denied = true
				break
		if not denied:
			kept.append(line)
	return "\n".join(kept)

func _git_log(arguments: Dictionary) -> Dictionary:
	var count := clampi(int(arguments.get("max_count", 20)), 1, 50)
	return await _git(["log", "--no-color", "--oneline", "-n", str(count)], "Git log", 20000)

### Execution

func _capture_scene_view(arguments: Dictionary) -> Dictionary:
	var view := str(arguments.get("view", "2d")).strip_edges()
	if not view in ["2d", "3d"]:
		return _error("invalid_arguments", "view must be 2d or 3d.")
	var max_px := clampi(int(arguments.get("max_px", 1024)), 128, 1024)
	var viewport: SubViewport = EditorInterface.get_editor_viewport_2d() if view == "2d" else EditorInterface.get_editor_viewport_3d()
	if viewport == null:
		return _error("capture_failed", "The %s editor viewport is unavailable." % view)
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		await (loop as SceneTree).process_frame
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return _error("capture_failed", "The %s editor viewport produced no image; run the editor with rendering enabled." % view)
	var record := _store_visual_attachment(image, "scene_" + view, "scene_" + view + ".png", max_px)
	if record.is_empty():
		return _error("capture_failed", "The captured view was empty or exceeded the attachment limits.")
	return {
		"ok": true,
		"summary": "Captured the rendered %s view (%d×%d)." % [view, int(record.width), int(record.height)],
		"data": {
			"visual": {
				"id": str(record.id),
				"path": str(record.path),
				"width": int(record.width),
				"height": int(record.height),
				"name": str(record.name),
				"source": str(record.source),
				"prompt": "This is the rendered %s view of the edited scene. Describe the layout, the player, platforms, camera, and any visible issues." % view,
			},
		},
		"affected": [],
	}

func _capture_player_view(_arguments: Dictionary) -> Dictionary:
	return _error("unavailable", "The running player window is not capturable in this build. Paste an OS screenshot of the game into the chat, or use capture_scene_view for the editor scene.")

func _store_visual_attachment(image: Image, source: String, name: String, max_px: int) -> Dictionary:
	if image == null or image.is_empty():
		return {}
	var width := image.get_width()
	var height := image.get_height()
	var max_edge := maxi(width, height)
	if max_edge > max_px:
		var scale := float(max_px) / float(max_edge)
		image.resize(maxi(1, int(width * scale)), maxi(1, int(height * scale)), Image.INTERPOLATE_BILINEAR)
	var bytes := image.save_png_to_buffer()
	if bytes.is_empty() or bytes.size() > 2 * 1024 * 1024:
		return {}
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return {}
	context.update(bytes)
	var digest := context.finish().hex_encode()
	if digest.is_empty():
		return {}
	var identity := ProjectSettings.globalize_path("res://").sha256_text().substr(0, 12)
	var directory := "user://tiiny_chat/attachments/" + identity
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory)) != OK:
		return {}
	var path := directory.path_join(digest + ".png")
	if not FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return {}
		file.store_buffer(bytes)
		file.close()
	return {
		"id": "sha256:" + digest,
		"path": path,
		"source": source,
		"name": name,
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": bytes.size(),
	}

func _find_assets(arguments: Dictionary) -> Dictionary:
	var kind := str(arguments.get("kind", "all")).strip_edges()
	if kind not in ["all", "image", "model", "audio", "scene", "script", "resource"]:
		return _error("invalid_arguments", "Unknown asset kind: " + kind)
	var query := str(arguments.get("query", "")).strip_edges().to_lower()
	var max_results := clampi(int(arguments.get("max", 30)), 1, 100)
	var root := _canonical(str(arguments.get("path", "res://")), true)
	if root.has("error"): return root
	if not DirAccess.dir_exists_absolute(str(root.absolute)):
		return _error("not_found", "The asset path does not exist: " + str(root.res))
	var scan := _scan_asset_files(str(root.absolute), str(root.res), 5000)
	if scan.has("error"): return scan
	var candidates: Array = []
	for entry in scan.files:
		if kind != "all" and str(entry.kind) != kind: continue
		if not query.is_empty() and not str(entry.path).to_lower().contains(query): continue
		candidates.append(entry)
	var refs := _asset_references(scan.files, candidates)
	if arguments.has("used"):
		var wanted := bool(arguments.used)
		var filtered: Array = []
		for entry in candidates:
			var used := not Array(refs.get(str(entry.path), [])).is_empty()
			if used == wanted:
				filtered.append(entry)
		candidates = filtered
	candidates.sort_custom(func(a, b):
		var a_refs := Array(refs.get(str(a.path), [])).size()
		var b_refs := Array(refs.get(str(b.path), [])).size()
		if a_refs != b_refs: return a_refs > b_refs
		if int(a.modified) != int(b.modified): return int(a.modified) > int(b.modified)
		return str(a.path) < str(b.path))
	var total := candidates.size()
	var shown: Array = candidates.slice(0, max_results)
	var assets: Array = []
	for entry in shown:
		var item := {
			"path": str(entry.path),
			"kind": str(entry.kind),
			"bytes": int(entry.bytes),
			"modified": str(entry.modified_text),
			"imported": bool(entry.imported),
		}
		if str(entry.kind) == "image":
			var metadata := _image_metadata(str(entry.absolute), int(entry.bytes))
			for key in metadata:
				item[key] = metadata[key]
		var used_in: Array = refs.get(str(entry.path), [])
		if not used_in.is_empty():
			item["used_in"] = used_in.slice(0, 5)
		assets.append(item)
	var label := "asset" if kind == "all" else kind
	var summary := "Found %d %s%s under %s." % [total, label, "" if total == 1 else "s", str(root.res)]
	if total == 0:
		summary += " No matching asset exists; generate one only if none fits."
	elif assets.size() < total:
		summary += " Showing %d; narrow with kind, query, path, or used." % assets.size()
	else:
		summary += " Reuse an existing path instead of creating a duplicate."
	return {
		"ok": true,
		"summary": summary.left(1200),
		"data": {
			"path": str(root.res),
			"kind": kind,
			"count": total,
			"assets": assets,
			"truncated": assets.size() < total,
			"scan_truncated": bool(scan.truncated),
		},
		"affected": [],
	}

func _asset_kind(path: String) -> String:
	return str(ASSET_KINDS.get(path.get_extension().to_lower(), ""))

func _scan_asset_files(base_absolute: String, base_res: String, limit: int) -> Dictionary:
	var files: Array = []
	var stack: Array = [{"absolute": base_absolute, "res": base_res}]
	var truncated := false
	while not stack.is_empty():
		if files.size() >= limit:
			truncated = true
			break
		var current: Dictionary = stack.pop_back()
		var dir := DirAccess.open(str(current.absolute))
		if dir == null: continue
		dir.list_dir_begin()
		var entry_name := dir.get_next()
		while not entry_name.is_empty():
			if entry_name == "." or entry_name == "..":
				entry_name = dir.get_next()
				continue
			if dir.is_link(entry_name) or entry_name.begins_with("."):
				entry_name = dir.get_next()
				continue
			if not _project_root_denies([entry_name.to_lower()]).is_empty():
				entry_name = dir.get_next()
				continue
			var child_absolute := str(current.absolute).path_join(entry_name)
			var child_res := str(current.res).path_join(entry_name)
			if dir.current_is_dir():
				stack.append({"absolute": child_absolute, "res": child_res})
			else:
				var kind := _asset_kind(entry_name)
				if not kind.is_empty():
					var bytes := 0
					var file := FileAccess.open(child_absolute, FileAccess.READ)
					if file != null:
						bytes = int(file.get_length())
						file.close()
					var modified := int(FileAccess.get_modified_time(child_absolute))
					files.append({
						"path": child_res,
						"absolute": child_absolute,
						"kind": kind,
						"bytes": bytes,
						"modified": modified,
						"modified_text": Time.get_datetime_string_from_unix_time(modified, true),
						"imported": FileAccess.file_exists(child_absolute + ".import"),
					})
			entry_name = dir.get_next()
		dir.list_dir_end()
	return {"files": files, "truncated": truncated}

func _asset_references(files: Array, candidates: Array) -> Dictionary:
	var refs := {}
	var paths: Array = []
	for entry in candidates:
		paths.append(str(entry.path))
		refs[str(entry.path)] = []
	if paths.is_empty(): return refs
	if paths.size() > 500:
		paths = paths.slice(0, 500)
	var scanned := 0
	var budget := 3 * 1024 * 1024
	for entry in files:
		if scanned >= 300 or budget <= 0: break
		if str(entry.kind) not in ["scene", "script", "resource"]: continue
		if int(entry.bytes) > 1024 * 1024: continue
		var text := FileAccess.get_file_as_string(str(entry.absolute))
		if text.is_empty(): continue
		budget -= text.length()
		scanned += 1
		for asset_path in paths:
			if text.contains(str(asset_path)):
				var used_in: Array = refs[str(asset_path)]
				if not used_in.has(str(entry.path)) and used_in.size() < 5:
					used_in.append(str(entry.path))
	return refs

func _image_metadata(path: String, bytes: int) -> Dictionary:
	if bytes <= 0 or bytes > 8 * 1024 * 1024:
		return {}
	if not _image_header_ok(path, path.get_extension().to_lower()):
		return {}
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return {}
	var size := image.get_size()
	var result := {"size": [size.x, size.y]}
	if size.x <= 0 or size.y <= 0 or size.x * size.y > 16000000:
		return result
	var sample: Image = image.duplicate()
	sample.resize(maxi(1, mini(8, int(size.x))), maxi(1, mini(8, int(size.y))), Image.INTERPOLATE_BILINEAR)
	var total := Color(0, 0, 0, 0)
	var has_alpha := false
	for y in sample.get_height():
		for x in sample.get_width():
			var color: Color = sample.get_pixel(x, y)
			total += color
			if color.a < 0.99: has_alpha = true
	var count := float(sample.get_width() * sample.get_height())
	var average := Color(total.r / count, total.g / count, total.b / count, total.a / count)
	result["average_color"] = "#" + average.to_html(false)
	result["has_alpha"] = has_alpha
	return result

func _image_header_ok(path: String, extension: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return false
	var prefix := file.get_buffer(16)
	file.close()
	match extension:
		"png":
			return prefix.size() >= 16 and prefix[0] == 0x89 and prefix[1] == 0x50 and prefix[2] == 0x4E and prefix[3] == 0x47 and prefix.slice(12, 16).get_string_from_ascii() == "IHDR"
		"jpg", "jpeg":
			return prefix.size() >= 3 and prefix[0] == 0xFF and prefix[1] == 0xD8 and prefix[2] == 0xFF
		"webp":
			return prefix.size() >= 12 and prefix.slice(0, 4).get_string_from_ascii() == "RIFF" and prefix.slice(8, 12).get_string_from_ascii() == "WEBP"
		"bmp":
			return prefix.size() >= 2 and prefix[0] == 0x42 and prefix[1] == 0x4D
	return true

func asset_overview() -> Dictionary:
	var now := Time.get_ticks_msec()
	if now - int(asset_overview_cache.at) < 5000:
		return {"ok": true, "text": str(asset_overview_cache.text)}
	if project_root.is_empty():
		return {"ok": true, "text": ""}
	var scan := _scan_asset_files(project_root, "res://", 5000)
	if scan.has("error"): return scan
	var counts := {"image": 0, "model": 0, "audio": 0, "scene": 0, "script": 0, "resource": 0}
	var images: Array = []
	for entry in scan.files:
		var kind := str(entry.kind)
		counts[kind] = int(counts.get(kind, 0)) + 1
		if kind == "image" and images.size() < 4:
			images.append(str(entry.path).trim_prefix("res://"))
	var parts: Array = []
	for kind in ["image", "model", "audio", "scene", "script", "resource"]:
		var count := int(counts[kind])
		if count > 0:
			parts.append("%d %s%s" % [count, kind, "" if count == 1 else "s"])
	var text := ", ".join(parts)
	if not images.is_empty():
		text += "; images include " + ", ".join(images)
	asset_overview_cache = {"at": now, "text": text}
	return {"ok": true, "text": text}

func _lookup_docs(arguments: Dictionary) -> Dictionary:
	var native_class := str(arguments.get("class_name", "")).strip_edges()
	var member := str(arguments.get("member", "")).strip_edges()
	var query := str(arguments.get("query", "")).strip_edges()
	if native_class.is_empty() and query.is_empty():
		return _error("invalid_arguments", "Provide class_name, query, or Class.member.")
	if native_class.is_empty():
		var dot := query.find(".")
		if dot > 0:
			native_class = query.substr(0, dot).strip_edges()
			if member.is_empty():
				member = query.substr(dot + 1).strip_edges()
		elif ClassDB.class_exists(query):
			native_class = query
		else:
			return _docs_search(query)
	if native_class.is_empty():
		return _error("invalid_arguments", "A class name is required before the dot.")
	if not member.is_empty() and member.length() > 128:
		return _error("invalid_arguments", "member is too long.")
	var protocol: Variant = Engine.get_singleton("GDScriptLanguageProtocol")
	if protocol == null:
		return _error("docs_unavailable", "The GDScript language service is unavailable; built-in docs cannot be read.")
	var raw: Variant = protocol.get_native_docs(native_class, "")
	if not raw is Dictionary:
		var matches := _docs_class_matches(native_class)
		if not matches.is_empty():
			return {
				"ok": true,
				"summary": "No exact class named %s. Matches: %s." % [native_class, ", ".join(PackedStringArray(matches))],
				"data": {"query": native_class, "matches": matches, "truncated": matches.size() >= 20},
				"affected": [],
			}
		return _error("not_found", "No Godot class named " + native_class + ".", {"class": native_class})
	var children := _docs_children(raw)
	if member.is_empty():
		return _docs_class_summary(native_class, raw, children)
	var exact: Dictionary = {}
	var partial: Array = []
	var lower := member.to_lower()
	for child in children:
		if not child is Dictionary: continue
		var child_name := str(child.get("name", ""))
		if child_name == member:
			exact = child
			break
		if child_name.to_lower().contains(lower):
			partial.append(child)
	if not exact.is_empty():
		return _docs_member_result(native_class, exact)
	if not partial.is_empty():
		var matches: Array = []
		for child in partial:
			matches.append(_docs_member_line(child))
			if matches.size() >= 20: break
		return {
			"ok": true,
			"summary": "%d member%s in %s match '%s'." % [matches.size(), "" if matches.size() == 1 else "s", native_class, member],
			"data": {"class": native_class, "member": member, "matches": matches, "truncated": partial.size() > matches.size()},
			"affected": [],
		}
	return _error("not_found", "No member named %s in %s. Use a partial member name or omit member for the class summary." % [member, native_class], {"class": native_class, "member": member})

func _docs_search(query: String) -> Dictionary:
	var matches := _docs_class_matches(query)
	if matches.is_empty():
		return _error("not_found", "No Godot class matches '" + query + "'.")
	if matches.size() == 1:
		var protocol: Variant = Engine.get_singleton("GDScriptLanguageProtocol")
		if protocol != null:
			var raw: Variant = protocol.get_native_docs(str(matches[0]), "")
			if raw is Dictionary:
				return _docs_class_summary(str(matches[0]), raw, _docs_children(raw))
	return {
		"ok": true,
		"summary": "Classes matching '%s': %s." % [query, ", ".join(PackedStringArray(matches))],
		"data": {"query": query, "matches": matches, "truncated": matches.size() >= 20},
		"affected": [],
	}

func _docs_class_matches(query: String) -> Array:
	var lower := query.to_lower()
	var matches: Array = []
	for name in ClassDB.get_class_list():
		if str(name).to_lower().contains(lower):
			matches.append(str(name))
	matches.sort_custom(func(a, b):
		var a_lower := str(a).to_lower()
		var b_lower := str(b).to_lower()
		var a_exact := a_lower == lower
		var b_exact := b_lower == lower
		if a_exact != b_exact: return a_exact
		var a_prefix := a_lower.begins_with(lower)
		var b_prefix := b_lower.begins_with(lower)
		if a_prefix != b_prefix: return a_prefix
		return str(a) < str(b))
	return matches.slice(0, 20)

func _docs_class_summary(native_class: String, raw: Dictionary, children: Array) -> Dictionary:
	var members: Array = []
	for child in children:
		if not child is Dictionary: continue
		members.append(_docs_member_line(child))
		if members.size() >= 80: break
	var detail := str(raw.get("detail", "class " + native_class))
	var documentation := str(raw.get("documentation", "")).left(4000)
	return {
		"ok": true,
		"summary": ("%s (%d member%s%s)." % [detail, children.size(), "" if children.size() == 1 else "s", ", first 80 shown" if children.size() > members.size() else ""]).left(1200),
		"data": {
			"class": native_class,
			"detail": detail,
			"documentation": documentation,
			"members": members,
			"member_count": children.size(),
			"truncated": children.size() > members.size(),
		},
		"affected": [],
	}

func _docs_member_result(native_class: String, member: Dictionary) -> Dictionary:
	var name := str(member.get("name", ""))
	var detail := str(member.get("detail", ""))
	var kind := _docs_kind_name(int(member.get("kind", 0)))
	return {
		"ok": true,
		"summary": ("%s.%s (%s): %s" % [native_class, name, kind, detail]).left(1200),
		"data": {
			"class": native_class,
			"member": name,
			"kind": kind,
			"detail": detail,
			"documentation": str(member.get("documentation", "")).left(6000),
			"deprecated": bool(member.get("deprecated", false)),
		},
		"affected": [],
	}

func _docs_member_line(member: Dictionary) -> Dictionary:
	return {
		"name": str(member.get("name", "")),
		"detail": str(member.get("detail", "")),
		"kind": _docs_kind_name(int(member.get("kind", 0))),
		"deprecated": bool(member.get("deprecated", false)),
	}

func _docs_kind_name(kind: int) -> String:
	var names := {
		5: "class", 6: "method", 7: "property", 8: "field", 9: "constructor",
		10: "enum", 11: "interface", 12: "function", 13: "variable", 14: "constant",
		22: "enum member", 23: "struct", 24: "event", 25: "operator", 26: "type parameter",
	}
	return str(names.get(kind, "symbol"))

func _docs_children(raw: Dictionary) -> Array:
	var value: Variant = raw.get("children", [])
	return value if value is Array else []

func _check_gdscript(arguments: Dictionary) -> Dictionary:
	var source := str(arguments.get("source", ""))
	if source.strip_edges().is_empty():
		return _error("invalid_arguments", "source must contain GDScript.")
	if source.length() > 100000:
		return _error("invalid_arguments", "source is too long; limit it to 100000 characters.")
	var target_class := str(arguments.get("target_class", "")).strip_edges()
	if not target_class.is_empty() and not ClassDB.class_exists(target_class):
		return _error("invalid_arguments", "Unknown target class: " + target_class)
	var script_preload := _script_preload(source)
	if not script_preload.is_empty():
		return _error("unsafe_source", "The check cannot resolve preload of another GDScript (%s); resolving it can run that script's static initializer. Remove the preload to check this snippet safely, or validate it through create_and_attach_gdscript with approval." % script_preload)
	var sanitized := _strip_tool_annotation(source)
	var script := GDScript.new()
	script.source_code = sanitized
	var compile_error := script.reload()
	if compile_error != OK:
		var kind := str(script.get_last_error_kind())
		var line := int(script.get_last_error_line())
		var message := str(script.get_last_error())
		if message.is_empty():
			message = "The script did not compile (error %d)." % compile_error
		var where := (" at line %d" % line) if line > 0 else ""
		return {
			"ok": false,
			"summary": ("%s%s: %s" % ["Compile" if kind == "compile" else "Parse", where, message]).left(1200),
			"error": {"code": "compile_error" if kind == "compile" else "parse_error", "message": message, "line": line, "kind": kind},
			"data": {"line": line, "kind": kind, "error_code": int(compile_error)},
			"affected": [],
		}
	var base_class := str(script.get_instance_base_type())
	if base_class.is_empty():
		base_class = "RefCounted"
	var methods: Array = []
	for method in script.get_script_method_list():
		if not method is Dictionary: continue
		var method_name := str(method.get("name", ""))
		if method_name.is_empty() or method_name in methods: continue
		methods.append(method_name)
		if methods.size() >= 80: break
	var signals: Array = []
	for signal_info in script.get_script_signal_list():
		if not signal_info is Dictionary: continue
		var signal_name := str(signal_info.get("name", ""))
		if signal_name.is_empty() or signal_name in signals: continue
		signals.append(signal_name)
		if signals.size() >= 40: break
	if not target_class.is_empty() and not ClassDB.is_parent_class(target_class, base_class):
		return {
			"ok": false,
			"summary": "The script compiles but extends %s, which cannot attach to %s." % [base_class, target_class],
			"error": {"code": "incompatible_target", "message": "The script base class is incompatible with the target node class."},
			"data": {"base_class": base_class, "target_class": target_class, "methods": methods, "signals": signals},
			"affected": [],
		}
	var details := "extends %s, %d method%s" % [base_class, methods.size(), "" if methods.size() == 1 else "s"]
	if not target_class.is_empty():
		details += "; compatible with %s" % target_class
	return {
		"ok": true,
		"summary": "GDScript compiles: " + details + ".",
		"data": {
			"base_class": base_class,
			"target_class": target_class,
			"methods": methods,
			"signals": signals,
			"tool_annotation_removed": sanitized != source,
			"preloaded": source.contains("preload("),
		},
		"affected": [],
	}

func _strip_tool_annotation(source: String) -> String:
	var regex := RegEx.new()
	if regex.compile("(?m)^[ \\t]*@tool\\b[^\\n]*") != OK:
		return source
	return regex.sub(source, "", false)

func _script_preload(source: String) -> String:
	var regex := RegEx.new()
	if regex.compile("preload\\(\\s*[\"']([^\"']+\\.gd)[\"']") != OK:
		return ""
	var found := regex.search(source)
	return str(found.get_string(1)) if found != null else ""

func _run_godot_headless(arguments: Dictionary) -> Dictionary:
	var spec := _headless_spec(arguments)
	if spec.has("error"): return spec
	if not allow_shell_commands:
		return _error("command_disabled", "Headless project execution is disabled. Enable tiiny_ai/advanced/allow_shell_commands and approve each run, because --script executes project code on the host.")
	var approved := false
	if approve_headless.is_valid():
		approved = bool(await approve_headless.call(spec.argv.duplicate(), project_root))
	if not approved:
		return _error("approval_required", "The user did not approve running project code headlessly.")
	return await _execute_shell_spec(spec)

func _verify_scene_runtime(arguments: Dictionary) -> Dictionary:
	var scene_path := str(arguments.get("scene_path", "")).strip_edges()
	if scene_path.is_empty():
		if not editor_bridge.is_valid():
			return _error("invalid_arguments", "A scene_path is required when no edited scene is available.")
		var state: Dictionary = editor_bridge.call("edited_scene", {})
		scene_path = str(state.get("path", ""))
		if scene_path.is_empty():
			return _error("no_scene", "Open a saved scene or pass scene_path.")
		if bool(state.get("dirty", false)):
			return _error("scene_dirty", "Save the scene before runtime verification; the run loads the saved file.")
	if not scene_path.begins_with("res://") or not (scene_path.ends_with(".tscn") or scene_path.ends_with(".scn")):
		return _error("invalid_arguments", "scene_path must be a saved res:// .tscn or .scn path.")
	var canonical := _canonical(scene_path, false)
	if canonical.has("error"): return canonical
	if not FileAccess.file_exists(str(canonical.absolute)):
		return _error("not_found", "The scene does not exist: " + scene_path)
	if editor_bridge.is_valid():
		var current: Dictionary = editor_bridge.call("edited_scene", {})
		if str(current.get("path", "")) == scene_path and bool(current.get("dirty", false)):
			return _error("scene_dirty", "Save the scene before runtime verification; the run loads the saved file.")
	if not allow_shell_commands:
		return _error("command_disabled", "Runtime verification is disabled. Enable tiiny_ai/advanced/allow_shell_commands and approve the run, because it executes project scripts on the host.")
	var frames := clampi(int(arguments.get("frames", 180)), 10, 600)
	var actions := _runtime_actions(arguments.get("actions", []))
	if actions.has("error"): return actions
	var checks := _runtime_checks(arguments.get("checks", []))
	if checks.has("error"): return checks
	var timeout_ms := clampi(int(arguments.get("timeout_ms", 30000)), 1000, 120000)
	var directory := ProjectSettings.globalize_path("user://tiiny_runtime")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return _error("execution_failed", "Could not create the runtime probe directory.")
	var token := Crypto.new().generate_random_bytes(6).hex_encode()
	var probe_path := directory.path_join("probe_" + token + ".gd")
	var spec_path := directory.path_join("spec_" + token + ".json")
	var output_path := directory.path_join("result_" + token + ".json")
	var probe_file := FileAccess.open(probe_path, FileAccess.WRITE)
	if probe_file == null:
		return _error("execution_failed", "Could not write the runtime probe.")
	probe_file.store_string(RUNTIME_PROBE_SOURCE)
	probe_file.close()
	var spec_file := FileAccess.open(spec_path, FileAccess.WRITE)
	if spec_file == null:
		_runtime_remove([probe_path])
		return _error("execution_failed", "Could not write the runtime probe specification.")
	spec_file.store_string(JSON.stringify({"scene": str(canonical.res), "frames": frames, "actions": actions.actions, "output": output_path}))
	spec_file.close()
	var argv := ["--headless", "--path", project_root, "--script", probe_path, "--", spec_path]
	var approved := false
	if approve_headless.is_valid():
		approved = bool(await approve_headless.call(argv.duplicate(), project_root))
	if not approved:
		_runtime_remove([probe_path, spec_path])
		return _error("approval_required", "The user did not approve running the scene's project code headlessly.")
	var spec := {"kind": "headless", "argv": argv, "cwd_res": "res://", "cwd_abs": project_root, "timeout_ms": timeout_ms}
	var run := await _execute_shell_spec(spec)
	var stderr_text := str(run.get("data", {}).get("stderr", ""))
	var stdout_text := str(run.get("data", {}).get("stdout", ""))
	if not run.get("ok", false):
		_runtime_remove([probe_path, spec_path, output_path])
		if run.get("error", {}).get("code", "") == "timeout":
			return run
		return _error("runtime_failed", str(run.get("summary", "The runtime probe failed.")), {"stderr": _tail_text(stderr_text, 3000), "stdout": _tail_text(stdout_text, 1000)})
	var payload: Variant = null
	if FileAccess.file_exists(output_path):
		payload = JSON.parse_string(FileAccess.get_file_as_string(output_path))
	_runtime_remove([probe_path, spec_path, output_path])
	if not payload is Dictionary:
		return _error("probe_failed", "The runtime probe did not write a usable result.", {"stderr": _tail_text(stderr_text, 3000), "stdout": _tail_text(stdout_text, 1000)})
	if payload.has("error"):
		return _runtime_probe_error(str(payload.error), stderr_text, stdout_text)
	return _runtime_report(scene_path, frames, payload, checks.checks, stderr_text, int(run.get("data", {}).get("duration_ms", 0)))

func _runtime_actions(raw: Variant) -> Dictionary:
	if not raw is Array:
		return _error("invalid_arguments", "actions must be an array.")
	if raw.size() > 4:
		return _error("invalid_arguments", "At most 4 input actions can be simulated.")
	var actions: Array = []
	for entry in raw:
		if not entry is Dictionary:
			return _error("invalid_arguments", "Each action must be an object with action, frame, and hold.")
		var action := str(entry.get("action", "")).strip_edges()
		if action.is_empty() or action.length() > 64 or not action.is_valid_identifier():
			return _error("invalid_arguments", "Input action names must be identifiers of at most 64 characters.")
		if not InputMap.has_action(action) and not ProjectSettings.has_setting("input/" + action):
			return _error("invalid_arguments", "Input action is not defined: %s. Use a built-in ui_* action or define the action in the project input map first." % action)
		var frame_value: Variant = entry.get("frame", 60)
		var hold_value: Variant = entry.get("hold", 2)
		if not (frame_value is int or frame_value is float) or not (hold_value is int or hold_value is float):
			return _error("invalid_arguments", "Action frame and hold must be numbers.")
		actions.append({"action": action, "frame": clampi(int(frame_value), 1, 600), "hold": clampi(int(hold_value), 1, 120)})
	return {"actions": actions}

func _runtime_checks(raw: Variant) -> Dictionary:
	var allowed := ["scene_loads", "no_errors", "gravity", "lands", "jump"]
	if not raw is Array:
		return _error("invalid_arguments", "checks must be an array.")
	if raw.is_empty():
		return {"checks": ["scene_loads", "no_errors"]}
	var checks: Array = []
	for value in raw:
		var name := str(value)
		if not allowed.has(name):
			return _error("invalid_arguments", "Unknown runtime check: " + name)
		if not checks.has(name):
			checks.append(name)
	return {"checks": checks}

func _runtime_probe_error(code: String, stderr_text: String, stdout_text: String) -> Dictionary:
	var message := "The runtime probe could not run the scene."
	match code:
		"scene_load_failed": message = "The scene could not be loaded. Check that it is a saved .tscn and that its scripts parse."
		"instantiate_failed": message = "The scene could not be instantiated."
		"invalid_spec", "missing_spec": message = "The runtime probe received an invalid specification."
	return _error(code, message, {"stderr": _tail_text(stderr_text, 3000), "stdout": _tail_text(stdout_text, 1000)})

func _runtime_report(scene_path: String, frames: int, payload: Dictionary, checks: Array, stderr_text: String, duration_ms: int) -> Dictionary:
	var bodies: Array = payload.get("bodies", [])
	var details := {}
	var failed: Array = []
	for name in checks:
		var passed := true
		var detail := ""
		match name:
			"scene_loads":
				detail = "Scene %s instantiated and ran for %d frames." % [scene_path, int(payload.get("frames", frames))]
			"no_errors":
				var error_line := _runtime_error_line(stderr_text)
				passed = error_line.is_empty()
				detail = "No script or load errors were reported." if passed else "Error output: " + error_line
			"gravity":
				var fall := 0.0
				var fall_path := ""
				for body in bodies:
					if not body is Dictionary: continue
					var delta := float(body.get("max_y", 0.0)) - float(body.start[1])
					if delta > fall:
						fall = delta
						fall_path = str(body.get("path", "?"))
				passed = fall >= 2.0
				detail = ("A body fell %.1f px under gravity." % fall) if passed else "No body fell vertically; gravity may be missing or blocked."
				if passed and not fall_path.is_empty():
					detail += " (" + fall_path + ")"
			"lands":
				var grounded: Array = []
				for body in bodies:
					if body is Dictionary and bool(body.get("end_on_floor", false)):
						grounded.append(str(body.get("path", "?")))
				passed = not grounded.is_empty()
				detail = ("On the floor at the final frame: " + ", ".join(grounded)) if passed else "No CharacterBody2D reported is_on_floor at the final frame."
			"jump":
				var jumped: Array = []
				for body in bodies:
					if body is Dictionary and float(body.get("min_vy_after_action", 0.0)) <= -1.0:
						jumped.append(str(body.get("path", "?")))
				passed = not jumped.is_empty()
				detail = ("Upward velocity after an action: " + ", ".join(jumped)) if passed else "No body moved upward after the requested input action; check the action name and jump handling."
		if not passed: failed.append(name)
		details[name] = {"passed": passed, "detail": detail}
	var summary := "Runtime verification %s for %s (%d frames): %s." % ["passed" if failed.is_empty() else "failed", scene_path, int(payload.get("frames", frames)), ", ".join(checks)]
	if not failed.is_empty():
		summary += " Failed: " + ", ".join(failed) + ". " + str(details[failed[0]].detail)
	return {
		"ok": true,
		"summary": summary.left(1200),
		"data": {
			"scene": scene_path,
			"frames": int(payload.get("frames", frames)),
			"passed": failed.is_empty(),
			"checks": details,
			"failed": failed,
			"bodies": bodies,
			"actions": payload.get("actions", []),
			"stderr": _tail_text(stderr_text, 3000),
			"duration_ms": duration_ms,
		},
		"affected": [],
	}

func _runtime_error_line(stderr_text: String) -> String:
	for line in stderr_text.split("\n"):
		for marker in ["SCRIPT ERROR", "Parse Error", "Invalid call", "Failed loading resource", "Can't load script"]:
			if line.contains(marker):
				return line.strip_edges().left(400)
	return ""

func _runtime_remove(paths: Array) -> void:
	for path in paths:
		if FileAccess.file_exists(str(path)):
			DirAccess.remove_absolute(str(path))

func _tail_text(text: String, limit: int) -> String:
	if text.length() <= limit: return text
	return text.right(limit)

func _headless_spec(arguments: Dictionary) -> Dictionary:
	var raw_args: Variant = arguments.get("args", [])
	if not raw_args is Array or raw_args.is_empty():
		return _error("invalid_arguments", "run_godot_headless requires a non-empty args array.")
	var args: Array = []
	for value in raw_args:
		if not value is String or str(value).is_empty() or str(value).length() > 512 or str(value).contains("\n") or _has_nul(str(value)):
			return _error("invalid_arguments", "Headless arguments must be bounded non-empty strings.")
		args.append(str(value))
	for index in args.size():
		var value := str(args[index])
		var previous := str(args[index - 1]) if index > 0 else ""
		if index > 0 and HEADLESS_VALUE_FLAGS.has(previous):
			if previous in ["--script", "-s"]:
				var script_path := _canonical(value, false)
				if script_path.has("error"): return script_path
				if not FileAccess.file_exists(str(script_path.absolute)):
					return _error("not_found", "The headless script does not exist: " + str(script_path.res))
			elif previous in ["--log-file", "--write-movie"]:
				var output_path := _canonical(value, false)
				if output_path.has("error"): return output_path
		elif value.begins_with("-"):
			if not HEADLESS_FLAGS.has(value):
				return _error("invalid_arguments", "The headless flag is not allowlisted: " + value)
		else:
			return _error("invalid_arguments", "The headless value is not attached to an allowlisted flag: " + value)
	var path_index := args.find("--path")
	if path_index >= 0:
		var given := str(args[path_index + 1]) if path_index + 1 < args.size() else ""
		var resolved := _canonical(given if not given.is_empty() else "res://")
		if resolved.has("error"): return resolved
		if str(resolved.relative) != "." and str(resolved.absolute) != project_root:
			return _error("path_escape", "Headless runs are confined to the project root.")
		args.remove_at(path_index + 1)
		args.remove_at(path_index)
	if not args.has("--headless"):
		args.push_front("--headless")
	args.push_front(project_root)
	args.push_front("--path")
	return {"kind": "headless", "argv": args, "cwd_res": "res://", "cwd_abs": project_root, "timeout_ms": clampi(int(arguments.get("timeout_ms", 60000)), 1000, MAX_COMMAND_TIMEOUT_MS)}

func _command_spec(arguments: Dictionary) -> Dictionary:
	var command := str(arguments.get("command", "")).strip_edges()
	if command.is_empty() or command.length() > 4000 or _has_nul(command):
		return _error("invalid_arguments", "The command is empty or too long.")
	var cwd := _canonical(str(arguments.get("cwd", "res://")))
	if cwd.has("error"): return cwd
	if not DirAccess.dir_exists_absolute(str(cwd.absolute)):
		return _error("not_found", "The working directory does not exist: " + str(cwd.res))
	return {"kind": "command", "command": command, "cwd_res": str(cwd.res), "cwd_abs": str(cwd.absolute), "timeout_ms": clampi(int(arguments.get("timeout_ms", 60000)), 1000, MAX_COMMAND_TIMEOUT_MS)}

func _run_command(arguments: Dictionary) -> Dictionary:
	if not allow_shell_commands:
		return _error("command_disabled", "Host command execution is disabled. Enable tiiny_ai/advanced/allow_shell_commands and approve a command explicitly.")
	var spec := _command_spec(arguments)
	if spec.has("error"): return spec
	var approved := false
	if approve_command.is_valid():
		approved = bool(await approve_command.call(str(spec.command), str(spec.cwd_res)))
	if not approved:
		return _error("approval_required", "The user did not approve running this host command.")
	return await _execute_shell_spec(spec)

func _execute_shell_spec(spec: Dictionary, cancelled_check: Callable = Callable()) -> Dictionary:
	var timeout_ms := int(spec.get("timeout_ms", 60000))
	var note_pid := Callable(self, "_note_shell_pid") if shell_job_running else Callable()
	var run: Dictionary
	if spec.kind == "command":
		run = await _spawn("/bin/sh", ["-c", str(spec.command)], str(spec.cwd_abs), timeout_ms, cancelled_check, note_pid)
	else:
		var argv: Array = spec.argv
		run = await _spawn(OS.get_executable_path(), argv.duplicate(), str(spec.cwd_abs), timeout_ms, cancelled_check, note_pid)
	if run.has("error"): return run
	if bool(run.get("cancelled", false)):
		return _error("cancelled", "The command was cancelled and its process group was stopped.")
	if bool(run.get("timed_out", false)):
		return _error("timeout", "The command exceeded %d ms and its process group was stopped." % timeout_ms, {"exit_code": int(run.exit_code), "stdout": _redact(str(run.stdout)), "stderr": _redact(str(run.stderr))})
	var ok := int(run.exit_code) == 0
	var command_label := str(spec.command) if spec.kind == "command" else " ".join(PackedStringArray(spec.argv))
	var summary := ("Command" if spec.kind == "command" else "Headless Godot") + " exited %d in %d ms%s." % [int(run.exit_code), int(run.duration_ms), " with bounded output" if bool(run.output_truncated) else ""]
	if not ok: summary += " " + _first_line(str(run.stderr))
	var result := {
		"ok": ok,
		"summary": summary,
		"data": {"command": _redact(command_label), "cwd": str(spec.cwd_res), "exit_code": int(run.exit_code), "stdout": _redact(str(run.stdout)), "stderr": _redact(str(run.stderr)), "truncated": bool(run.output_truncated), "timed_out": false, "duration_ms": int(run.duration_ms)},
		"affected": [],
	}
	if not ok:
		result["error"] = {"code": "command_failed", "message": "The command exited with a non-zero status."}
	return result

# Pre-approve a shell tool call and return job parameters. Approval happens once,
# before the job is queued; execution revalidates the setting and the digest.
func prepare_shell_job(tool_name: String, arguments: Dictionary) -> Dictionary:
	if not allow_shell_commands:
		return _error("command_disabled", "Host command execution is disabled. Enable tiiny_ai/advanced/allow_shell_commands and approve a command explicitly.")
	var spec: Dictionary
	if tool_name == "run_command":
		spec = _command_spec(arguments)
	elif tool_name == "run_godot_headless":
		spec = _headless_spec(arguments)
	else:
		return _error("invalid_arguments", "Unsupported shell tool: " + tool_name)
	if spec.has("error"): return spec
	var approved := false
	if tool_name == "run_command":
		if approve_command.is_valid():
			approved = bool(await approve_command.call(str(spec.command), str(spec.cwd_res)))
	else:
		if approve_headless.is_valid():
			approved = bool(await approve_headless.call(spec.argv.duplicate(), project_root))
	if not approved:
		return _error("approval_required", "The user did not approve this command." if tool_name == "run_command" else "The user did not approve running project code headlessly.")
	var parameters := {
		"kind": str(spec.kind),
		"cwd": str(spec.cwd_res),
		"timeout_ms": int(spec.timeout_ms),
		"approval": {"at": int(Time.get_unix_time_from_system()), "tool": tool_name},
	}
	if spec.kind == "command":
		parameters["command"] = str(spec.command)
	else:
		parameters["argv"] = spec.argv.duplicate()
	parameters.approval["digest"] = _shell_digest(parameters)
	return {"ok": true, "parameters": parameters}

func _execute_shell_parameters(parameters: Dictionary) -> Dictionary:
	if not allow_shell_commands:
		return _error("command_disabled", "Host command execution is disabled. Enable tiiny_ai/advanced/allow_shell_commands.")
	var approval: Variant = parameters.get("approval", {})
	if not approval is Dictionary or str(approval.get("digest", "")) != _shell_digest(parameters):
		return _error("approval_invalid", "The shell approval does not match this job; queue it again.")
	var cwd := _canonical(str(parameters.get("cwd", "res://")))
	if cwd.has("error"): return cwd
	if not DirAccess.dir_exists_absolute(str(cwd.absolute)):
		return _error("not_found", "The working directory does not exist: " + str(cwd.res))
	var spec := {
		"kind": str(parameters.get("kind", "")),
		"cwd_res": str(cwd.res),
		"cwd_abs": str(cwd.absolute),
		"timeout_ms": clampi(int(parameters.get("timeout_ms", 60000)), 1000, MAX_COMMAND_TIMEOUT_MS),
	}
	if spec.kind == "command":
		var command := str(parameters.get("command", ""))
		if command.strip_edges().is_empty() or command.length() > 4000 or _has_nul(command):
			return _error("invalid_arguments", "The command is empty or too long.")
		spec["command"] = command
	else:
		var argv: Variant = parameters.get("argv", [])
		if not argv is Array or argv.is_empty() or argv.size() > 128:
			return _error("invalid_arguments", "Headless arguments are missing or too long.")
		for value in argv:
			if not value is String or str(value).is_empty() or str(value).length() > 512 or str(value).contains("\n") or _has_nul(str(value)):
				return _error("invalid_arguments", "Headless arguments must be bounded non-empty strings.")
		spec["argv"] = Array(argv).duplicate()
	return await _execute_shell_spec(spec, Callable(self, "_shell_cancelled"))

func _shell_digest(parameters: Dictionary) -> String:
	var payload := {
		"kind": str(parameters.get("kind", "")),
		"cwd": str(parameters.get("cwd", "")),
		"timeout_ms": int(parameters.get("timeout_ms", 0)),
	}
	if str(parameters.get("kind", "")) == "command":
		payload["command"] = str(parameters.get("command", ""))
	else:
		var argv_value: Variant = parameters.get("argv", [])
		payload["argv"] = argv_value.duplicate() if argv_value is Array else []
	return JSON.stringify(payload).sha256_text()

func start_shell_job(parameters: Dictionary) -> String:
	if shell_job_running:
		return "A shell job is already running."
	shell_job_running = true
	shell_job_cancelled = false
	shell_job_pid = 0
	shell_job_result = {}
	shell_job_stage = "Starting " + ("headless Godot" if str(parameters.get("kind", "")) == "headless" else "host command")
	_run_shell_job(parameters)
	return ""

func _run_shell_job(parameters: Dictionary) -> void:
	var result: Dictionary = await _execute_shell_parameters(parameters)
	shell_job_result = result
	shell_job_stage = "Finished"
	shell_job_running = false

func poll_shell_job() -> Dictionary:
	if shell_job_running:
		return {"state": "running", "stage": shell_job_stage, "pid": shell_job_pid}
	if shell_job_result.is_empty():
		return {"state": "running", "stage": "Starting"}
	return {"state": "completed" if bool(shell_job_result.get("ok", false)) else "failed", "result": shell_job_result}

func cancel_shell_job() -> void:
	shell_job_cancelled = true

func _shell_cancelled() -> bool:
	return shell_job_cancelled

func _note_shell_pid(pid: int) -> void:
	shell_job_pid = pid
	shell_job_stage = "Running (pid %d)" % pid

func _spawn(executable: String, args: Array, cwd: String, timeout_ms: int, cancel_check: Callable = Callable(), on_start: Callable = Callable()) -> Dictionary:
	if executable.contains("/") and not FileAccess.file_exists(executable):
		return _error("not_found", "Executable not found: " + executable)
	var search_path := OS.get_environment("PATH")
	if search_path.is_empty(): search_path = "/usr/local/bin:/usr/bin:/bin"
	var environment := ["PATH=" + search_path, "LANG=C.UTF-8", "LC_ALL=C.UTF-8"]
	for key in ["HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"]:
		var value := OS.get_environment(key)
		if not value.is_empty(): environment.append(key + "=" + value)
	# Godot already calls setsid() for pipe children, so the tracked pid is the
	# session and process-group leader; a negative-pid kill cleans up the group.
	var shell_script := "cd -- \"$1\" || exit 97; shift; exec \"$@\""
	var command_args: Array = []
	var env_path := "/usr/bin/env" if FileAccess.file_exists("/usr/bin/env") else "env"
	var sh_path := "/bin/sh" if FileAccess.file_exists("/bin/sh") else "sh"
	command_args.append(env_path)
	command_args.append("-i")
	command_args.append_array(environment)
	command_args.append(sh_path)
	command_args.append("-c")
	command_args.append(shell_script)
	command_args.append("tiiny-cwd")
	command_args.append(cwd)
	command_args.append(executable)
	command_args.append_array(args)
	var info := OS.execute_with_pipe(str(command_args[0]), PackedStringArray(command_args.slice(1)), false)
	if info.is_empty():
		return _error("spawn_failed", "Could not start the owned process.")
	var pid := int(info.pid)
	if on_start.is_valid(): on_start.call(pid)
	var stdio: FileAccess = info.stdio
	var stderr_pipe: FileAccess = info.stderr
	var stdout := PackedByteArray()
	var stderr := PackedByteArray()
	var output_truncated := false
	var timed_out := false
	var cancelled := false
	var started := Time.get_ticks_msec()
	var deadline := started + timeout_ms
	while true:
		stdout.append_array(_read_available(stdio))
		stderr.append_array(_read_available(stderr_pipe))
		if stdout.size() > MAX_COMMAND_OUTPUT or stderr.size() > MAX_COMMAND_OUTPUT:
			output_truncated = true
			_kill_owned(pid)
			break
		if not OS.is_process_running(pid):
			break
		if cancel_requested or (cancel_check.is_valid() and bool(cancel_check.call())):
			cancelled = true
			_kill_owned(pid)
			break
		if Time.get_ticks_msec() >= deadline:
			timed_out = true
			_kill_owned(pid)
			break
		await _yield_frame()
	stdout.append_array(_read_available(stdio))
	stderr.append_array(_read_available(stderr_pipe))
	if output_truncated:
		stdout = stdout.slice(0, MAX_COMMAND_OUTPUT)
		stderr = stderr.slice(0, MAX_COMMAND_OUTPUT)
	return {
		"exit_code": OS.get_process_exit_code(pid),
		"stdout": stdout.get_string_from_utf8(),
		"stderr": stderr.get_string_from_utf8(),
		"output_truncated": output_truncated,
		"timed_out": timed_out,
		"cancelled": cancelled,
		"duration_ms": Time.get_ticks_msec() - started,
	}

func _read_available(pipe: FileAccess) -> PackedByteArray:
	if pipe == null: return PackedByteArray()
	var available := int(pipe.get_length())
	if available <= 0: return PackedByteArray()
	return pipe.get_buffer(mini(available, 8192))

func _kill_owned(pid: int) -> void:
	if OS.get_name() == "Linux":
		OS.execute("kill", ["-KILL", "--", "-%d" % pid])
	for index in range(100):
		if not OS.is_process_running(pid):
			return
		OS.delay_msec(10)
	if OS.is_process_running(pid):
		OS.kill(pid)

func _yield_frame() -> void:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		await (loop as SceneTree).process_frame
	else:
		OS.delay_msec(5)

### Editor bridge

func _reload_scene(arguments: Dictionary) -> Dictionary:
	var resolved := _canonical(str(arguments.get("path", "")), false)
	if resolved.has("error"): return resolved
	if not str(resolved.res).ends_with(".tscn") and not str(resolved.res).ends_with(".scn"):
		return _error("invalid_arguments", "reload_scene requires a scene path.")
	if not FileAccess.file_exists(str(resolved.absolute)):
		return _error("not_found", "Scene does not exist: " + str(resolved.res))
	if not editor_bridge.is_valid():
		return _error("unavailable", "The editor bridge is unavailable; reload from the editor UI.")
	var state := _scene_state(str(resolved.res))
	if bool(state.get("dirty", false)):
		if not bool(arguments.get("discard_unsaved", false)):
			return _error("scene_dirty", "The scene has unsaved changes. Save it, or request an explicit discard decision.")
		var approved := false
		if approve_discard.is_valid():
			approved = bool(await approve_discard.call(str(resolved.res)))
		if not approved:
			return _error("approval_required", "The user did not approve discarding unsaved scene changes; nothing was reloaded.")
	var result: Variant = editor_bridge.call("reload_scene", {"path": str(resolved.res), "discard_unsaved": bool(arguments.get("discard_unsaved", false))})
	if result is Dictionary and result.has("error"):
		return result
	return {"ok": true, "summary": "Reloaded %s from disk." % str(resolved.res), "data": {"path": str(resolved.res), "dirty": false}, "affected": [{"kind": "file", "path": str(resolved.res)}]}

func _scan_filesystem() -> Dictionary:
	if not editor_bridge.is_valid():
		return _error("unavailable", "The editor bridge is unavailable; scan from the editor UI.")
	var result: Variant = editor_bridge.call("scan_filesystem", {})
	if result is Dictionary and result.has("error"): return result
	return {"ok": true, "summary": "Rescanned the project filesystem.", "data": {"scanned": true}, "affected": []}

### Helpers

func _file_size(absolute: String) -> int:
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null: return 0
	var size := int(file.get_length())
	file.close()
	return size

func _is_binary(path: String, bytes: PackedByteArray) -> bool:
	if BINARY_EXTENSIONS.has(path.get_extension().to_lower()):
		return true
	if bytes.find(0) >= 0:
		return true
	if bytes.is_empty():
		return false
	return bytes.get_string_from_utf8().to_utf8_buffer() != bytes

func _scene_state(path: String) -> Dictionary:
	if not editor_bridge.is_valid():
		return {}
	var state: Variant = editor_bridge.call("scene_state", {"path": path})
	if state is Dictionary:
		return state
	state = editor_bridge.call("edited_scene", {})
	if state is Dictionary and str(state.get("path", "")) == path:
		return state
	return {}

func _dirty_scene_error(path: String) -> Dictionary:
	var state := _scene_state(path)
	if bool(state.get("script_dirty", false)):
		return _error("script_dirty", "The editor has unsaved changes to %s. Save or close that buffer before changing the file." % path)
	if bool(state.get("dirty", false)):
		return _error("scene_dirty", "An open editor tab for %s has unsaved changes. Save, close, or explicitly reload it before editing the file, so no editor state is lost." % path)
	return {}

func _notify_scan() -> void:
	if editor_bridge.is_valid():
		editor_bridge.call("scan_filesystem", {})

func _glob_matches(glob: String, path: String) -> bool:
	if glob == "**/*" or glob == "*":
		return true
	if glob.begins_with("**/"):
		var suffix := glob.substr(3)
		return path.match(suffix) or path.get_file().match(suffix)
	return path.match(glob)

func _has_nul(text: String) -> bool:
	for index in text.length():
		if text.unicode_at(index) == 0:
			return true
	return false

func _strip_cr(lines: Array) -> Array:
	var result: Array = []
	for line in lines:
		result.append(str(line).trim_suffix("\r"))
	return result

func _bounded_diff(before: String, after: String) -> String:
	var old_lines := before.split("\n")
	var new_lines := after.split("\n")
	var prefix := 0
	while prefix < old_lines.size() and prefix < new_lines.size() and old_lines[prefix] == new_lines[prefix]:
		prefix += 1
	var suffix := 0
	while suffix < old_lines.size() - prefix and suffix < new_lines.size() - prefix and old_lines[old_lines.size() - 1 - suffix] == new_lines[new_lines.size() - 1 - suffix]:
		suffix += 1
	var lines: Array = ["@@ -%d,%d +%d,%d @@" % [prefix + 1, old_lines.size() - prefix - suffix, prefix + 1, new_lines.size() - prefix - suffix]]
	for index in range(prefix, old_lines.size() - suffix):
		lines.append("-" + str(old_lines[index]))
	for index in range(prefix, new_lines.size() - suffix):
		lines.append("+" + str(new_lines[index]))
	var text := "\n".join(lines)
	return text.left(MAX_DIFF_CHARS)

func _redact(text: String) -> String:
	var result := text
	var replacements: Array = [
		["(?i)(authorization:\\s*bearer\\s+)\\S+", "$1<redacted>"],
		["(?i)((?:api[_-]?key|token|secret)[\"'\\s:=]+)[A-Za-z0-9_\\-\\.]{8,}", "$1<redacted>"],
		["(https?://[^\\s:/@]+:)[^\\s@/]+(@)", "$1<redacted>$2"],
		["\\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\\b", "<redacted>"],
		["\\bsk-[A-Za-z0-9]{20,}\\b", "<redacted>"],
	]
	for replacement in replacements:
		var regex := RegEx.new()
		if regex.compile(str(replacement[0])) != OK: continue
		result = regex.sub(result, str(replacement[1]), true)
	return result

func _first_line(text: String) -> String:
	for line in text.split("\n"):
		if not line.strip_edges().is_empty():
			return line.strip_edges().left(300)
	return ""

func _error(code: String, message: String, extra: Dictionary = {}) -> Dictionary:
	var error := {"code": code, "message": message}
	var result := {"ok": false, "summary": message, "error": error, "affected": []}
	if not extra.is_empty(): result["data"] = extra
	return result
