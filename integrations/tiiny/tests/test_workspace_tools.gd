extends SceneTree

## Pure fixture for the workspace coding provider: path confinement,
## binary/large reads, hash-guarded writes and patches, git, commands,
## the editor bridge, and tool-mode filtering. Run from the repository root:
##   bin/godot.linuxbsd.editor.x86_64 --headless --path . \
##       --script integrations/tiiny/tests/test_workspace_tools.gd

const Workspace = preload("res://editor/tiiny/tools/workspace.gd")
const Registry = preload("res://editor/tiiny/tools/registry.gd")

class LinkFailureWorkspace extends "res://editor/tiiny/tools/workspace.gd":
	func _link_no_replace(_source: String, _target: String) -> int:
		return 1

var failures := 0
var project := ""
var workspace
var outside := ""
var bridge_calls := 0
var bridge_state := {"path": "", "dirty": false, "saved": false}
var bridge_unsaved: Array = []
var bridge_unsaved_files: Array = []
var bridge_reloads := 0
var command_approved := false
var edit_approved := false
var headless_approved := false
var discard_approved := false
var edit_hook: Callable
var approved_actions: Array = []

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		print("FAIL: ", message)
		failures += 1
	else:
		print("ok: ", message)

func error_code(result: Dictionary) -> String:
	return str(result.get("error", {}).get("code", ""))

func file_text(path: String) -> String:
	return FileAccess.get_file_as_string(path)

func write_file(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("fixture could not write " + path)
		return
	file.store_string(text)
	file.close()

func fake_bridge(action: String, payload: Dictionary) -> Dictionary:
	bridge_calls += 1
	match action:
		"scan_filesystem":
			return {"ok": true, "scanned": true}
		"edited_scene":
			return bridge_state.duplicate(true)
		"scene_state":
			var path := str(payload.get("path", ""))
			return {"path": path, "open": true, "dirty": path in bridge_unsaved, "script_dirty": path in bridge_unsaved_files, "current": str(bridge_state.get("path", "")) == path, "unsaved_scenes": bridge_unsaved.duplicate()}
		"reload_scene":
			bridge_reloads += 1
			return {"ok": true, "path": str(payload.get("path", ""))}
	return {"ok": false, "error": {"code": "unknown", "message": action}}

func approve_command_callable(command: String, _cwd: String) -> bool:
	return command_approved

func approve_edit_callable(action: String, path: String, _reason: String) -> bool:
	approved_actions.append([action, path])
	if edit_hook.is_valid():
		edit_hook.call(action, path)
	return edit_approved

func approve_headless_callable(_args: Array, _cwd: String) -> bool:
	return headless_approved

func approve_discard_callable(_path: String) -> bool:
	return discard_approved

func _initialize() -> void:
	OS.delay_msec(10)
	var base := "/tmp/tiiny-workspace-tools-" + Crypto.new().generate_random_bytes(4).hex_encode()
	project = base.path_join("project")
	outside = base.path_join("outside")
	DirAccess.make_dir_recursive_absolute(project.path_join("scripts"))
	DirAccess.make_dir_recursive_absolute(project.path_join("assets"))
	DirAccess.make_dir_recursive_absolute(outside)
	write_file(project.path_join("project.godot"), 'config_version=5\n[application]\nconfig/name="Workspace Tools Fixture"\n')
	write_file(project.path_join("scripts/player.gd"), "extends Node\n\nvar speed := 1\n")
	write_file(project.path_join("scripts/notes.txt"), "alpha\nfind me here\nomega\n")
	write_file(project.path_join("scripts/again.txt"), "find me here\nfind me here\n")
	var binary_file := FileAccess.open(project.path_join("assets/binary.png"), FileAccess.WRITE)
	binary_file.store_buffer(PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0]))
	binary_file.close()
	write_file(project.path_join("assets/large.txt"), "x".repeat(300000))
	write_file(outside.path_join("secret.txt"), "outside secret\n")
	write_file(project.path_join("check.gd"), "extends SceneTree\n\nfunc _initialize() -> void:\n\tprint(\"TIINY_HEADLESS_OK\")\n\tquit(0)\n")
	write_file(project.path_join("slow.gd"), "extends SceneTree\n\nfunc _initialize() -> void:\n\tFileAccess.open(\"res://slow_pid.txt\", FileAccess.WRITE).store_string(str(OS.get_process_id()))\n\tOS.delay_msec(8000)\n\tquit(0)\n")
	write_file(project.path_join("noisy.gd"), "extends SceneTree\n\nfunc _initialize() -> void:\n\tprint(\"n\".repeat(400000))\n\tquit(0)\n")
	var dir := DirAccess.open(project)
	dir.create_link(outside.path_join("secret.txt"), project.path_join("escape_link.txt"))
	dir.create_link(project.path_join("scripts/notes.txt"), project.path_join("inside_link.txt"))
	DirAccess.make_dir_recursive_absolute(project.path_join(".git"))
	write_file(project.path_join(".git/config"), "[core]\n")
	write_file(project.path_join("id_rsa"), "not a real key\n")

	workspace = Workspace.new(project)
	workspace.editor_bridge = Callable(self, "fake_bridge")
	workspace.approve_command = Callable(self, "approve_command_callable")
	workspace.approve_edit = Callable(self, "approve_edit_callable")
	workspace.approve_headless = Callable(self, "approve_headless_callable")
	workspace.approve_discard = Callable(self, "approve_discard_callable")

	await _path_tests()
	await _read_tests()
	await _project_instruction_tests()
	await _write_tests()
	await _patch_tests()
	await _move_delete_tests()
	await _git_tests()
	await _command_tests()
	await _bridge_tests()
	await _mode_tests()

	var leftovers: Array = Array(DirAccess.open(project.path_join("scripts")).get_files()).filter(func(name): return ".tiiny-tmp-" in name)
	check(leftovers.is_empty(), "atomic writes left no temporary files")
	workspace = null
	DirAccess.remove_absolute(project.path_join("escape_link.txt"))
	DirAccess.remove_absolute(project.path_join("inside_link.txt"))
	OS.execute("rm", ["-rf", base])
	if failures == 0:
		print("Workspace tools pure fixture passed.")
		quit(0)
	else:
		print("Workspace tools pure fixture failed: ", failures)
		quit(1)

func _path_tests() -> void:
	var cases := {
		"../outside": "path_escape",
		"res://../outside": "path_escape",
		"/etc/passwd": "path_escape",
		"user://secret": "path_escape",
		"res://.git/config": "denied_path",
		"res://id_rsa": "denied_path",
		"res://.godot/editor/x": "denied_path",
		"res://escape_link.txt": "symlink_rejected",
		"res://inside_link.txt": "symlink_rejected",
		"res://scripts\\player.gd": "invalid_path",
	}
	for path in cases:
		var result: Dictionary = workspace.execute("read_file", {"path": path})
		check(error_code(result) == str(cases[path]), "path rejected (%s) with %s, got %s" % [path, str(cases[path]), error_code(result)])
	var missing: Dictionary = workspace.execute("file_info", {"path": "res://missing.txt"})
	check(error_code(missing) == "not_found", "missing path reports not_found")
	var root_listing: Dictionary = workspace.execute("list_files", {"path": "res://", "recursive": true, "max_entries": 200})
	check(root_listing.get("ok", false), "recursive listing succeeds")
	check(Array(root_listing.data.entries).all(func(entry): return not str(entry.path).begins_with("res://.git") and not str(entry.path).ends_with("id_rsa")), "listing excludes denied paths")
	var limited: Dictionary = workspace.execute("list_files", {"path": "res://", "recursive": true, "max_entries": 2})
	check(limited.get("ok", false) and bool(limited.data.truncated), "listing reports truncation")

func _read_tests() -> void:
	var text: Dictionary = workspace.execute("read_file", {"path": "res://scripts/notes.txt"})
	check(text.get("ok", false) and "find me here" in str(text.data.content), "reads a text file")
	check(str(text.data.sha256) == FileAccess.get_sha256(project.path_join("scripts/notes.txt")), "read returns the real SHA-256")
	var offset: Dictionary = workspace.execute("read_file", {"path": "res://scripts/notes.txt", "offset": 2, "limit": 1})
	check(str(offset.data.content).begins_with("find me here") and bool(offset.data.truncated), "line offset and truncation")
	var binary: Dictionary = workspace.execute("read_file", {"path": "res://assets/binary.png"})
	check(binary.get("ok", false) and bool(binary.data.binary) and str(binary.data.content).is_empty(), "binary read returns metadata only")
	var large: Dictionary = workspace.execute("read_file", {"path": "res://assets/large.txt", "max_bytes": 4096})
	check(large.get("ok", false) and bool(large.data.truncated) and str(large.data.content).length() < 5000, "large read is bounded and reports truncation")
	var info: Dictionary = workspace.execute("file_info", {"path": "res://scripts/player.gd"})
	check(info.get("ok", false) and int(info.data.size) > 0 and str(info.data.type) == "file" and not bool(info.data.symlink), "file_info reports file metadata")
	var search: Dictionary = workspace.execute("search_text", {"query": "find me here", "glob": "**/*.txt", "max_matches": 100})
	check(search.get("ok", false) and Array(search.data.matches).size() == 3, "literal search finds expected matches")
	check(Array(search.data.matches).all(func(match): return not str(match.path).ends_with(".png")), "search skips binary files")
	var bounded: Dictionary = workspace.execute("search_text", {"query": "find me here", "glob": "**/*.txt", "max_matches": 1})
	check(bounded.get("ok", false) and bool(bounded.data.truncated) and Array(bounded.data.matches).size() == 1, "search reports truncation")
	var regex: Dictionary = workspace.execute("search_text", {"query": "f.nd me", "glob": "**/*.txt", "regex": true, "max_matches": 10})
	check(regex.get("ok", false) and Array(regex.data.matches).size() > 0, "explicit regex search works")
	var bad_regex: Dictionary = workspace.execute("search_text", {"query": "(", "regex": true})
	check(error_code(bad_regex) == "invalid_arguments", "invalid regex is rejected")

func _project_instruction_tests() -> void:
	var path := project.path_join("AGENTS.md")
	write_file(path, "Project conventions.\n- keep names short\n")
	var read: Dictionary = workspace.read_project_instructions()
	check(read.get("ok", false) and "keep names short" in str(read.text) and str(read.sha256) == FileAccess.get_sha256(path) and not bool(read.truncated), "project instructions are read with a hash")
	DirAccess.remove_absolute(path)
	check(error_code(workspace.read_project_instructions()) == "not_found", "missing project instructions report not_found")
	write_file(path, "x".repeat(9000))
	var large: Dictionary = workspace.read_project_instructions()
	check(large.get("ok", false) and bool(large.truncated) and str(large.text).length() <= 8192, "project instructions are bounded and report truncation")
	var invalid := FileAccess.open(path, FileAccess.WRITE)
	invalid.store_buffer(PackedByteArray([0xff, 0xfe, 0x00]))
	invalid.close()
	check(error_code(workspace.read_project_instructions()) == "not_utf8", "invalid project instructions are rejected")
	DirAccess.remove_absolute(path)
	var dir := DirAccess.open(project)
	dir.create_link(outside.path_join("secret.txt"), path)
	check(error_code(workspace.read_project_instructions()) == "symlink_rejected", "symlinked project instructions are rejected")
	DirAccess.remove_absolute(path)


func _write_tests() -> void:
	var created: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/new.gd", "content": "extends Node\n"})
	check(error_code(created) == "missing_file", "new file requires create:true")
	edit_approved = false
	var denied: Dictionary = await workspace.execute("create_file", {"path": "res://scripts/new.gd", "content": "extends Node\n"})
	check(error_code(denied) == "approval_required" and not FileAccess.file_exists(project.path_join("scripts/new.gd")), "create_file requires explicit approval")
	edit_approved = true
	var approved: Dictionary = await workspace.execute("create_file", {"path": "res://scripts/new.gd", "content": "extends Node\n", "reason": "fixture"})
	check(approved.get("ok", false) and FileAccess.file_exists(project.path_join("scripts/new.gd")), "approved create_file creates the file")
	check(Array(approved.affected).size() == 1 and str(approved.affected[0].kind) == "file", "create reports a file target")
	var duplicate: Dictionary = await workspace.execute("create_file", {"path": "res://scripts/new.gd", "content": "extends Node\n"})
	check(error_code(duplicate) == "file_exists", "create_file refuses an existing file")

	edit_approved = false
	var write_create_denied: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/write_new.gd", "content": "extends Node\n", "create": true})
	check(error_code(write_create_denied) == "approval_required" and not FileAccess.file_exists(project.path_join("scripts/write_new.gd")), "write_file create:true requires explicit approval")
	edit_approved = true
	var write_create: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/write_new.gd", "content": "extends Node\n", "create": true})
	check(write_create.get("ok", false) and FileAccess.file_exists(project.path_join("scripts/write_new.gd")), "approved write_file create:true creates the file")

	edit_hook = func(action: String, path: String) -> void:
		if action == "create" and path.ends_with("race_create.gd"):
			var file := FileAccess.open(project.path_join("scripts/race_create.gd"), FileAccess.WRITE)
			file.store_string("extends Node # external\n")
			file.close()
	var race_create: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/race_create.gd", "content": "extends Node\n", "create": true})
	check(error_code(race_create) == "file_exists" and file_text(project.path_join("scripts/race_create.gd")) == "extends Node # external\n", "a destination created during approval is not overwritten")
	edit_hook = func(action: String, path: String) -> void:
		if action == "create" and path.ends_with("race_create_file.gd"):
			var file := FileAccess.open(project.path_join("scripts/race_create_file.gd"), FileAccess.WRITE)
			file.store_string("extends Node # external create_file\n")
			file.close()
	var race_create_file: Dictionary = await workspace.execute("create_file", {"path": "res://scripts/race_create_file.gd", "content": "extends Node\n"})
	check(error_code(race_create_file) == "file_exists" and file_text(project.path_join("scripts/race_create_file.gd")) == "extends Node # external create_file\n", "create_file does not overwrite a destination created during approval")
	edit_hook = Callable()

	var no_hash: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/player.gd", "content": "extends Node\n"})
	check(error_code(no_hash) == "missing_hash", "overwrite requires the current hash")
	var original := file_text(project.path_join("scripts/player.gd"))
	var stale: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/player.gd", "content": "extends Node\n", "expected_sha256": "0".repeat(64)})
	check(error_code(stale) == "stale_hash" and file_text(project.path_join("scripts/player.gd")) == original, "stale hash changes nothing")
	var current := FileAccess.get_sha256(project.path_join("scripts/player.gd"))
	var written: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/player.gd", "content": "extends Node\n\nvar speed := 2\n", "expected_sha256": current})
	check(written.get("ok", false) and "speed := 2" in file_text(project.path_join("scripts/player.gd")), "valid hash overwrites atomically")
	check(str(written.data.before_sha256) == current and str(written.data.after_sha256) != current, "write reports before/after hashes")
	check(str(written.data.undo) == "not scene-undoable", "write declares it is not scene-undoable")

	var invalid_hash := FileAccess.get_sha256(project.path_join("scripts/player.gd"))
	var invalid: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/player.gd", "content": "extends Node(\n", "expected_sha256": invalid_hash})
	check(error_code(invalid) == "script_invalid" and file_text(project.path_join("scripts/player.gd")).contains("speed := 2"), "invalid GDScript is rejected before commit")

	var concurrent_source := file_text(project.path_join("scripts/notes.txt"))
	var stale_date := FileAccess.get_sha256(project.path_join("scripts/notes.txt"))
	write_file(project.path_join("scripts/notes.txt"), concurrent_source + "external\n")
	var concurrent: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/notes.txt", "content": "replaced\n", "expected_sha256": stale_date})
	check(error_code(concurrent) == "stale_hash" and "external" in file_text(project.path_join("scripts/notes.txt")), "concurrent edit is not overwritten")

	var commit_hash := FileAccess.get_sha256(project.path_join("scripts/player.gd"))
	workspace.before_commit = func(path: String, mode: String) -> void:
		if mode == "overwrite" and path.ends_with("player.gd"):
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string("changed at commit time\n")
			file.close()
	var commit_race: Dictionary = await workspace.execute("write_file", {"path": "res://scripts/player.gd", "content": "extends Node\n\nvar speed := 3\n", "expected_sha256": commit_hash})
	check(error_code(commit_race) == "stale_hash" and file_text(project.path_join("scripts/player.gd")) == "changed at commit time\n", "an edit during commit is not overwritten")
	workspace.before_commit = Callable()

func _patch_tests() -> void:
	var source := "extends Node\n\nvar speed := 2\nvar health := 10\n"
	write_file(project.path_join("scripts/patch_target.gd"), source)
	var hash := FileAccess.get_sha256(project.path_join("scripts/patch_target.gd"))
	var block := "<<<<<<<\nvar speed := 2\n=======\nvar speed := 5\n>>>>>>>\n"
	var exact: Dictionary = await workspace.execute("apply_patch", {"path": "res://scripts/patch_target.gd", "expected_sha256": hash, "patch": block})
	check(exact.get("ok", false) and "var speed := 5" in file_text(project.path_join("scripts/patch_target.gd")), "exact patch block applies")
	check("var health := 10" in file_text(project.path_join("scripts/patch_target.gd")), "patch preserves unrelated content")
	check(str(exact.data.diff).contains("-var speed := 2") and str(exact.data.diff).contains("+var speed := 5"), "patch returns a review diff")

	hash = FileAccess.get_sha256(project.path_join("scripts/patch_target.gd"))
	var ambiguous := "<<<<<<<\nvar\n=======\nlet\n>>>>>>>\n"
	var conflict: Dictionary = await workspace.execute("apply_patch", {"path": "res://scripts/patch_target.gd", "expected_sha256": hash, "patch": ambiguous})
	check(error_code(conflict) == "patch_conflict", "ambiguous exact block is rejected")
	check("var speed := 5" in file_text(project.path_join("scripts/patch_target.gd")), "rejected patch leaves the file unchanged")

	var unified := "@@ -1,5 +1,5 @@\n extends Node\n \n-var speed := 5\n+var speed := 7\n var health := 10\n"
	var patch_result: Dictionary = await workspace.execute("apply_patch", {"path": "res://scripts/patch_target.gd", "expected_sha256": hash, "patch": unified})
	check(patch_result.get("ok", false) and "var speed := 7" in file_text(project.path_join("scripts/patch_target.gd")), "unified diff applies")
	var wrong: Dictionary = await workspace.execute("apply_patch", {"path": "res://scripts/patch_target.gd", "expected_sha256": hash, "patch": unified})
	check(error_code(wrong) == "stale_hash", "reused hash is rejected after a patch")

	hash = FileAccess.get_sha256(project.path_join("scripts/patch_target.gd"))
	var invalid_script := "@@ -1,5 +1,5 @@\n extends Node\n \n-var speed := 7\n+var speed := (\n var health := 10\n"
	var invalid: Dictionary = await workspace.execute("apply_patch", {"path": "res://scripts/patch_target.gd", "expected_sha256": hash, "patch": invalid_script})
	check(error_code(invalid) == "script_invalid" and "speed := 7" in file_text(project.path_join("scripts/patch_target.gd")), "invalid patched script is not committed")

	hash = FileAccess.get_sha256(project.path_join("scripts/patch_target.gd"))
	var final_patch := "@@ -1,5 +1,5 @@\n extends Node\n \n-var speed := 7\n+var speed := 8\n var health := 10\n"
	workspace.before_commit = func(path: String, mode: String) -> void:
		if mode == "overwrite" and path.ends_with("patch_target.gd"):
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string("changed during patch commit\n")
			file.close()
	var patch_race: Dictionary = await workspace.execute("apply_patch", {"path": "res://scripts/patch_target.gd", "expected_sha256": hash, "patch": final_patch})
	check(error_code(patch_race) == "stale_hash" and file_text(project.path_join("scripts/patch_target.gd")) == "changed during patch commit\n", "a patch changed at commit time is not applied")
	workspace.before_commit = Callable()

func _move_delete_tests() -> void:
	var source := "res://scripts/notes.txt"
	var hash := FileAccess.get_sha256(project.path_join("scripts/notes.txt"))
	edit_approved = false
	var denied: Dictionary = await workspace.execute("move_file", {"source": source, "target": "res://scripts/moved.txt", "expected_sha256": hash})
	check(error_code(denied) == "approval_required" and FileAccess.file_exists(project.path_join("scripts/notes.txt")), "move requires approval")
	edit_approved = true
	edit_hook = func(action: String, path: String) -> void:
		if action == "move":
			bridge_unsaved_files.append(path)
	var dirty_buffer_move: Dictionary = await workspace.execute("move_file", {"source": source, "target": "res://scripts/moved.txt", "expected_sha256": hash})
	check(error_code(dirty_buffer_move) == "script_dirty" and FileAccess.file_exists(project.path_join("scripts/notes.txt")), "a buffer dirtied during move approval is protected")
	bridge_unsaved_files.clear()
	edit_hook = Callable()
	var moved: Dictionary = await workspace.execute("move_file", {"source": source, "target": "res://scripts/moved.txt", "expected_sha256": hash})
	check(moved.get("ok", false) and FileAccess.file_exists(project.path_join("scripts/moved.txt")) and not FileAccess.file_exists(project.path_join("scripts/notes.txt")), "approved move renames the file")
	hash = FileAccess.get_sha256(project.path_join("scripts/moved.txt"))
	var failing_link = LinkFailureWorkspace.new(project)
	failing_link.editor_bridge = Callable(self, "fake_bridge")
	failing_link.approve_edit = Callable(self, "approve_edit_callable")
	var link_failure: Dictionary = await failing_link.execute("move_file", {"source": "res://scripts/moved.txt", "target": "res://scripts/link_failure_target.txt", "expected_sha256": hash})
	check(error_code(link_failure) == "write_failed" and FileAccess.file_exists(project.path_join("scripts/moved.txt")) and not FileAccess.file_exists(project.path_join("scripts/link_failure_target.txt")), "move fails closed when no-overwrite linking fails")
	edit_approved = false
	var delete_denied: Dictionary = await workspace.execute("delete_file", {"path": "res://scripts/moved.txt", "expected_sha256": hash})
	check(error_code(delete_denied) == "approval_required" and FileAccess.file_exists(project.path_join("scripts/moved.txt")), "delete requires approval")

	edit_approved = true
	edit_hook = func(action: String, path: String) -> void:
		if action == "move" and path.ends_with("moved.txt"):
			var file := FileAccess.open(project.path_join("scripts/move_target.txt"), FileAccess.WRITE)
			file.store_string("target appeared during approval\n")
			file.close()
	var move_race: Dictionary = await workspace.execute("move_file", {"source": "res://scripts/moved.txt", "target": "res://scripts/move_target.txt", "expected_sha256": hash})
	check(error_code(move_race) == "file_exists" and FileAccess.file_exists(project.path_join("scripts/moved.txt")) and file_text(project.path_join("scripts/move_target.txt")) == "target appeared during approval\n", "a move destination created during approval is not overwritten")
	DirAccess.remove_absolute(project.path_join("scripts/move_target.txt"))

	workspace.before_commit = func(path: String, mode: String) -> void:
		if mode == "move" and path.ends_with("move_commit_target.txt"):
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string("target appeared at commit time\n")
			file.close()
	var move_commit_race: Dictionary = await workspace.execute("move_file", {"source": "res://scripts/moved.txt", "target": "res://scripts/move_commit_target.txt", "expected_sha256": hash})
	check(error_code(move_commit_race) == "file_exists" and FileAccess.file_exists(project.path_join("scripts/moved.txt")) and file_text(project.path_join("scripts/move_commit_target.txt")) == "target appeared at commit time\n", "a move destination created at commit time is not overwritten")
	workspace.before_commit = Callable()
	DirAccess.remove_absolute(project.path_join("scripts/move_commit_target.txt"))

	write_file(project.path_join("scripts/dirty_race.txt"), "dirty race\n")
	var dirty_race_hash := FileAccess.get_sha256(project.path_join("scripts/dirty_race.txt"))
	edit_hook = func(action: String, path: String) -> void:
		if action == "move" and path.ends_with("dirty_race.txt"):
			bridge_unsaved = ["res://scripts/dirty_race.txt"]
	var dirty_move_race: Dictionary = await workspace.execute("move_file", {"source": "res://scripts/dirty_race.txt", "target": "res://scripts/dirty_race_moved.txt", "expected_sha256": dirty_race_hash})
	check(error_code(dirty_move_race) == "scene_dirty" and FileAccess.file_exists(project.path_join("scripts/dirty_race.txt")), "a scene that becomes dirty during move approval is not moved")
	bridge_unsaved = []

	edit_hook = func(action: String, path: String) -> void:
		if action == "delete":
			bridge_unsaved_files.append(path)
	var dirty_buffer_delete: Dictionary = await workspace.execute("delete_file", {"path": "res://scripts/moved.txt", "expected_sha256": hash})
	check(error_code(dirty_buffer_delete) == "script_dirty" and FileAccess.file_exists(project.path_join("scripts/moved.txt")), "a buffer dirtied during delete approval is protected")
	bridge_unsaved_files.clear()
	edit_hook = func(action: String, path: String) -> void:
		if action == "delete" and path.ends_with("moved.txt"):
			var file := FileAccess.open(project.path_join("scripts/moved.txt"), FileAccess.WRITE)
			file.store_string("changed during approval\n")
			file.close()
	var delete_race: Dictionary = await workspace.execute("delete_file", {"path": "res://scripts/moved.txt", "expected_sha256": hash})
	check(error_code(delete_race) == "stale_hash" and file_text(project.path_join("scripts/moved.txt")) == "changed during approval\n", "a file changed during delete approval is preserved")
	edit_hook = Callable()
	write_file(project.path_join("scripts/delete_commit.txt"), "delete commit fixture\n")
	var delete_commit_hash := FileAccess.get_sha256(project.path_join("scripts/delete_commit.txt"))
	workspace.before_commit = func(path: String, mode: String) -> void:
		if mode == "delete" and path.ends_with("delete_commit.txt"):
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string("changed at delete commit time\n")
			file.close()
	var delete_commit_race: Dictionary = await workspace.execute("delete_file", {"path": "res://scripts/delete_commit.txt", "expected_sha256": delete_commit_hash})
	check(error_code(delete_commit_race) == "stale_hash" and file_text(project.path_join("scripts/delete_commit.txt")) == "changed at delete commit time\n", "a file changed at delete commit time is preserved")
	workspace.before_commit = Callable()
	DirAccess.remove_absolute(project.path_join("scripts/delete_commit.txt"))
	# Swap a checked parent directory for a link while approval is pending.
	DirAccess.make_dir_recursive_absolute(project.path_join("swap"))
	write_file(project.path_join("swap/victim.txt"), "same contents\n")
	write_file(outside.path_join("victim.txt"), "same contents\n")
	var swap_hash := FileAccess.get_sha256(project.path_join("swap/victim.txt"))
	edit_hook = func(action: String, _path: String) -> void:
		if action == "create":
			DirAccess.rename_absolute(project.path_join("swap"), project.path_join("swap_saved"))
			DirAccess.open(project).create_link(outside, project.path_join("swap"))
	var link_create: Dictionary = await workspace.execute("write_file", {"path": "res://swap/escape.txt", "content": "outside", "create": true})
	check(error_code(link_create) == "symlink_rejected" and not FileAccess.file_exists(outside.path_join("escape.txt")), "write_file rejects a parent changed to a symlink during approval")
	DirAccess.remove_absolute(project.path_join("swap"))
	DirAccess.rename_absolute(project.path_join("swap_saved"), project.path_join("swap"))
	var link_create_file: Dictionary = await workspace.execute("create_file", {"path": "res://swap/escape.txt", "content": "outside", "reason": "fixture"})
	check(error_code(link_create_file) == "symlink_rejected" and not FileAccess.file_exists(outside.path_join("escape.txt")), "create_file rejects a parent changed to a symlink during approval")
	DirAccess.remove_absolute(project.path_join("swap"))
	DirAccess.rename_absolute(project.path_join("swap_saved"), project.path_join("swap"))
	edit_hook = func(action: String, _path: String) -> void:
		if action == "delete":
			DirAccess.rename_absolute(project.path_join("swap"), project.path_join("swap_saved"))
			DirAccess.open(project).create_link(outside, project.path_join("swap"))
	var link_delete: Dictionary = await workspace.execute("delete_file", {"path": "res://swap/victim.txt", "expected_sha256": swap_hash})
	check(error_code(link_delete) == "symlink_rejected" and FileAccess.file_exists(outside.path_join("victim.txt")), "delete rejects a parent changed to a symlink during approval")
	DirAccess.remove_absolute(project.path_join("swap"))
	DirAccess.rename_absolute(project.path_join("swap_saved"), project.path_join("swap"))
	edit_hook = func(action: String, _path: String) -> void:
		if action == "move":
			DirAccess.rename_absolute(project.path_join("swap"), project.path_join("swap_saved"))
			DirAccess.open(project).create_link(outside, project.path_join("swap"))
	var link_move: Dictionary = await workspace.execute("move_file", {"source": "res://swap/victim.txt", "target": "res://scripts/link_moved.txt", "expected_sha256": swap_hash})
	check(error_code(link_move) == "symlink_rejected" and FileAccess.file_exists(outside.path_join("victim.txt")) and not FileAccess.file_exists(project.path_join("scripts/link_moved.txt")), "move rejects a parent changed to a symlink during approval")
	DirAccess.remove_absolute(project.path_join("swap"))
	DirAccess.rename_absolute(project.path_join("swap_saved"), project.path_join("swap"))
	var target_link_move: Dictionary = await workspace.execute("move_file", {"source": "res://scripts/moved.txt", "target": "res://swap/new.txt", "expected_sha256": FileAccess.get_sha256(project.path_join("scripts/moved.txt"))})
	check(error_code(target_link_move) == "symlink_rejected" and FileAccess.file_exists(project.path_join("scripts/moved.txt")) and not FileAccess.file_exists(outside.path_join("new.txt")), "move rejects a destination parent changed to a symlink during approval")
	DirAccess.remove_absolute(project.path_join("swap"))
	DirAccess.rename_absolute(project.path_join("swap_saved"), project.path_join("swap"))
	edit_hook = Callable()
	hash = FileAccess.get_sha256(project.path_join("scripts/moved.txt"))
	var deleted: Dictionary = await workspace.execute("delete_file", {"path": "res://scripts/moved.txt", "expected_sha256": hash})
	check(deleted.get("ok", false) and not FileAccess.file_exists(project.path_join("scripts/moved.txt")), "approved delete removes the file")

func _git_tests() -> void:
	var init := OS.execute("git", ["init", "-q", project])
	check(init == 0, "fixture git repository initialized")
	OS.execute("git", ["-C", project, "add", "project.godot", "scripts/player.gd"])
	OS.execute("git", ["-C", project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "fixture commit"])
	write_file(project.path_join("scripts/player.gd"), "extends Node\n\nvar speed := 9\n")
	var status: Dictionary = await workspace.execute("git_status", {})
	check(status.get("ok", false) and "scripts/player.gd" in str(status.data.output), "git status reports a modified file")
	var diff: Dictionary = await workspace.execute("git_diff", {"path": "res://scripts/player.gd"})
	check(diff.get("ok", false) and "+var speed := 9" in str(diff.data.diff), "git diff shows the change")
	var helper_path := project.path_join("diff_helper.sh")
	write_file(helper_path, "#!/bin/sh\nprintf invoked > '" + project.path_join("diff_helper_invoked") + "'\n")
	OS.execute("git", ["-C", project, "config", "diff.external", "sh " + helper_path])
	var helper_diff: Dictionary = await workspace.execute("git_diff", {"path": "res://scripts/player.gd"})
	check(helper_diff.get("ok", false) and "+var speed := 9" in str(helper_diff.data.diff) and not FileAccess.file_exists(project.path_join("diff_helper_invoked")), "git diff does not invoke repository-configured external helpers")
	OS.execute("git", ["-C", project, "config", "--unset", "diff.external"])
	write_file(project.path_join(".gitattributes"), "scripts/player.gd diff=fixture\n")
	OS.execute("git", ["-C", project, "config", "diff.fixture.textconv", "sh " + helper_path])
	var textconv_diff: Dictionary = await workspace.execute("git_diff", {"path": "res://scripts/player.gd"})
	check(textconv_diff.get("ok", false) and "+var speed := 9" in str(textconv_diff.data.diff) and not FileAccess.file_exists(project.path_join("diff_helper_invoked")), "git diff does not invoke repository-configured text conversion")
	OS.execute("git", ["-C", project, "config", "--unset", "diff.fixture.textconv"])
	OS.execute("chmod", ["+x", helper_path])
	OS.execute("git", ["-C", project, "config", "core.fsmonitor", helper_path])
	OS.execute("git", ["-C", project, "status", "--short"])
	check(FileAccess.file_exists(project.path_join("diff_helper_invoked")), "fixture verifies git would execute the configured fsmonitor")
	DirAccess.remove_absolute(project.path_join("diff_helper_invoked"))
	var helper_status: Dictionary = await workspace.execute("git_status", {})
	check(helper_status.get("ok", false) and not FileAccess.file_exists(project.path_join("diff_helper_invoked")), "git status does not invoke configured fsmonitor")
	OS.execute("git", ["-C", project, "config", "--unset", "core.fsmonitor"])
	write_file(project.path_join("scripts/player.gd"), "extends Node\n\nvar speed := 9\nconst TOKEN := \"ghp_abcdefghijklmnopqrstuvwxyz0123456789\"\n")
	var secret_diff: Dictionary = await workspace.execute("git_diff", {"path": "res://scripts/player.gd"})
	check(secret_diff.get("ok", false) and "ghp_abcdefghijklmnopqrstuvwxyz0123456789" not in str(secret_diff.data.diff) and "<redacted>" in str(secret_diff.data.diff), "git diff output redacts token-like values")
	write_file(project.path_join(".env"), "CREDENTIAL=SUPERSECRETVALUE\n")
	write_file(project.path_join(".ENV"), "CREDENTIAL=UPPERCASESECRET\n")
	DirAccess.make_dir_recursive_absolute(project.path_join(".godot"))
	write_file(project.path_join(".godot/private.txt"), "EDITORPRIVATEVALUE\n")
	OS.execute("git", ["-C", project, "add", ".env", ".ENV", ".godot/private.txt"])
	var filtered_status: Dictionary = await workspace.execute("git_status", {})
	check(filtered_status.get("ok", false) and ".env" not in str(filtered_status.data.output), "git status hides denied credential paths")
	var staged_secret: Dictionary = await workspace.execute("git_diff", {"staged": true})
	check(staged_secret.get("ok", false) and "SUPERSECRETVALUE" not in str(staged_secret.data.diff), "staged git diff excludes credential content")
	check(staged_secret.get("ok", false) and "UPPERCASESECRET" not in str(staged_secret.data.diff) and "EDITORPRIVATEVALUE" not in str(staged_secret.data.diff), "staged diff excludes case variants and denied editor directories")
	var all_diff: Dictionary = await workspace.execute("git_diff", {})
	check(all_diff.get("ok", false) and "SUPERSECRETVALUE" not in str(all_diff.data.diff), "unfiltered git diff excludes credential content")
	OS.execute("git", ["-C", project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "env fixture"])
	write_file(project.path_join(".env"), "CREDENTIAL=CHANGEDSECRET\n")
	var unstaged_secret: Dictionary = await workspace.execute("git_diff", {})
	check(unstaged_secret.get("ok", false) and "CHANGEDSECRET" not in str(unstaged_secret.data.diff), "unstaged git diff excludes changed credential content")
	write_file(project.path_join("scripts/player.gd"), "extends Node\n\nvar speed := 10\n")
	OS.execute("git", ["-C", project, "add", "scripts/player.gd"])
	OS.execute("git", ["-C", project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"])
	var redacted_log: Dictionary = await workspace.execute("git_log", {"max_count": 5})
	check(redacted_log.get("ok", false) and "ghp_abcdefghijklmnopqrstuvwxyz0123456789" not in str(redacted_log.data.output) and "<redacted>" in str(redacted_log.data.output), "git log redacts token-like commit text")
	var log: Dictionary = await workspace.execute("git_log", {"max_count": 5})
	check(log.get("ok", false) and "fixture commit" in str(log.data.output), "git log shows the commit")
	var outside_diff: Dictionary = await workspace.execute("git_diff", {"path": "../outside"})
	check(error_code(outside_diff) == "path_escape", "git diff path is root-confined")

func _command_tests() -> void:
	check(not workspace.allow_shell_commands, "shell commands default to disabled")
	var disabled: Dictionary = await workspace.execute("run_command", {"command": "echo hello"})
	check(error_code(disabled) == "command_disabled", "run_command is off by default")
	var headless_disabled: Dictionary = await workspace.execute("run_godot_headless", {"args": ["--script", "res://check.gd"]})
	check(error_code(headless_disabled) == "command_disabled", "headless project execution is off by default")
	for args in [["--quit"], ["--import"], ["--check-only", "--script", "res://check.gd"]]:
		var gated: Dictionary = await workspace.execute("run_godot_headless", {"args": args})
		check(error_code(gated) == "command_disabled", "headless project execution is gated without relying on a script flag: " + str(args))
	workspace.allow_shell_commands = true
	command_approved = false
	var unapproved: Dictionary = await workspace.execute("run_command", {"command": "echo hello"})
	check(error_code(unapproved) == "approval_required", "run_command requires explicit approval")
	command_approved = true
	var echo: Dictionary = await workspace.execute("run_command", {"command": "echo hello"})
	check(echo.get("ok", false) and str(echo.data.stdout).strip_edges() == "hello", "approved command runs and captures output")
	var pwd: Dictionary = await workspace.execute("run_command", {"command": "pwd"})
	check(pwd.get("ok", false) and str(pwd.data.stdout).strip_edges() == project, "approved command runs in the project root")
	var escaped: Dictionary = await workspace.execute("run_command", {"command": "pwd", "cwd": "../outside"})
	check(error_code(escaped) == "path_escape", "command cwd is root-confined")
	var secret: Dictionary = await workspace.execute("run_command", {"command": "printf 'Authorization: Bearer abcdef1234567890\\n'"})
	check(secret.get("ok", false) and "abcdef1234567890" not in str(secret.data.stdout) and "<redacted>" in str(secret.data.stdout), "command output redacts credentials")

	var noise: Dictionary = await workspace.execute("run_command", {"command": "yes x | head -c 400000", "timeout_ms": 5000})
	check(bool(noise.get("data", {}).get("truncated", false)) and str(noise.get("data", {}).get("stdout", "")).length() <= 262144, "command output is capped")

	var timeout: Dictionary = await workspace.execute("run_command", {"command": "sleep 30 & echo $! > child.pid; wait", "timeout_ms": 1000})
	check(error_code(timeout) == "timeout", "command timeout is reported")
	var child_path := project.path_join("child.pid")
	check(FileAccess.file_exists(child_path), "timeout fixture recorded a child pid")
	if FileAccess.file_exists(child_path):
		var child_pid := int(file_text(child_path).strip_edges())
		check(not OS.is_process_running(child_pid), "timed-out process group is cleaned up")
		DirAccess.remove_absolute(child_path)

	headless_approved = false
	var headless_denied: Dictionary = await workspace.execute("run_godot_headless", {"args": ["--script", "res://check.gd"], "timeout_ms": 60000})
	check(error_code(headless_denied) == "approval_required", "headless project code requires explicit approval")
	for args in [["--quit"], ["--import"], ["--check-only", "--script", "res://check.gd"]]:
		var denied: Dictionary = await workspace.execute("run_godot_headless", {"args": args})
		check(error_code(denied) == "approval_required", "each headless invocation requires approval: " + str(args))
	headless_approved = true
	var headless: Dictionary = await workspace.execute("run_godot_headless", {"args": ["--script", "res://check.gd"], "timeout_ms": 60000})
	check(headless.get("ok", false) and "TIINY_HEADLESS_OK" in str(headless.data.stdout), "headless Godot runs and returns output")
	var bad_flag: Dictionary = await workspace.execute("run_godot_headless", {"args": ["--definitely-not-a-flag"]})
	check(error_code(bad_flag) == "invalid_arguments", "headless flags are allowlisted")
	var outside_script: Dictionary = await workspace.execute("run_godot_headless", {"args": ["--script", "../outside/secret.gd"]})
	check(error_code(outside_script) == "path_escape", "headless script is root-confined")
	var outside_log: Dictionary = await workspace.execute("run_godot_headless", {"args": ["--log-file", "/tmp/tiiny-outside.log"]})
	check(error_code(outside_log) == "path_escape", "headless output paths are root-confined")

	var slow: Dictionary = await workspace.execute("run_godot_headless", {"args": ["--script", "res://slow.gd"], "timeout_ms": 1000})
	check(error_code(slow) == "timeout", "headless timeout is reported")
	var pid_path := project.path_join("slow_pid.txt")
	if FileAccess.file_exists(pid_path):
		check(not OS.is_process_running(int(file_text(pid_path).strip_edges())), "timed-out headless process is cleaned up")
	else:
		check(false, "slow headless fixture recorded its pid")
	var noisy: Dictionary = await workspace.execute("run_godot_headless", {"args": ["--script", "res://noisy.gd"], "timeout_ms": 60000})
	check(bool(noisy.get("data", {}).get("truncated", false)) and str(noisy.get("data", {}).get("stdout", "")).length() <= 262144, "headless output is capped")

func _bridge_tests() -> void:
	write_file(project.path_join("main.tscn"), '[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n')
	write_file(project.path_join("other.tscn"), '[gd_scene format=3]\n\n[node name="Other" type="Node2D"]\n')
	var hash := FileAccess.get_sha256(project.path_join("main.tscn"))
	bridge_state = {"path": "res://other.tscn", "dirty": false, "saved": true}
	bridge_unsaved = ["res://main.tscn"]
	var dirty: Dictionary = await workspace.execute("write_file", {"path": "res://main.tscn", "content": "[gd_scene format=3]\n", "expected_sha256": hash})
	check(error_code(dirty) == "scene_dirty", "a dirty non-current scene tab rejects a file write")
	var untouched: Dictionary = await workspace.execute("write_file", {"path": "res://other.tscn", "content": "[gd_scene format=3]\n", "expected_sha256": FileAccess.get_sha256(project.path_join("other.tscn"))})
	check(untouched.get("ok", false), "a clean non-current scene tab can be edited")
	write_file(project.path_join("scripts/dirty_tab.txt"), "dirty tab fixture\n")
	var dirty_tab_hash := FileAccess.get_sha256(project.path_join("scripts/dirty_tab.txt"))
	bridge_unsaved = ["res://main.tscn", "res://scripts/dirty_tab.txt"]
	var dirty_move: Dictionary = await workspace.execute("move_file", {"source": "res://scripts/dirty_tab.txt", "target": "res://scripts/dirty_tab_moved.txt", "expected_sha256": dirty_tab_hash})
	check(error_code(dirty_move) == "scene_dirty" and FileAccess.file_exists(project.path_join("scripts/dirty_tab.txt")), "move refuses an open dirty tab")
	var dirty_delete: Dictionary = await workspace.execute("delete_file", {"path": "res://scripts/dirty_tab.txt", "expected_sha256": dirty_tab_hash})
	check(error_code(dirty_delete) == "scene_dirty" and FileAccess.file_exists(project.path_join("scripts/dirty_tab.txt")), "delete refuses an open dirty tab")
	bridge_unsaved = ["res://main.tscn"]
	var reload: Dictionary = await workspace.execute("reload_scene", {"path": "res://main.tscn"})
	check(error_code(reload) == "scene_dirty", "reload refuses a dirty scene")
	var reloads_before := bridge_reloads
	var discard_denied: Dictionary = await workspace.execute("reload_scene", {"path": "res://main.tscn", "discard_unsaved": true})
	check(error_code(discard_denied) == "approval_required" and bridge_reloads == reloads_before, "discard requires an explicit user decision, not only a model flag")
	discard_approved = true
	var forced: Dictionary = await workspace.execute("reload_scene", {"path": "res://main.tscn", "discard_unsaved": true})
	check(forced.get("ok", false) and bridge_reloads == reloads_before + 1, "reload succeeds after explicit discard approval")
	bridge_unsaved = []
	bridge_state = {"path": "", "dirty": false, "saved": false}
	var scan: Dictionary = workspace.execute("scan_filesystem", {})
	check(scan.get("ok", false) and bridge_calls > 0, "scan_filesystem reaches the editor bridge")
	workspace.editor_bridge = Callable()
	var no_bridge: Dictionary = await workspace.execute("reload_scene", {"path": "res://main.tscn"})
	check(error_code(no_bridge) == "unavailable", "reload reports a missing editor bridge")
	workspace.editor_bridge = Callable(self, "fake_bridge")

func _mode_tests() -> void:
	var registry = Registry.new(null, null, null, workspace)
	var editor_tools: Array = Array(registry.tools_payload()).map(func(tool): return str(tool.function.name))
	var workspace_tools: Array = []
	check("list_files" not in editor_tools and "run_command" not in editor_tools, "editor mode hides workspace tools")
	check("read_project_file" in editor_tools and "scan_filesystem" in editor_tools, "editor mode keeps shared file/scan tools")
	check(registry.set_tool_mode("workspace"), "workspace mode is accepted")
	workspace_tools = Array(registry.tools_payload()).map(func(tool): return str(tool.function.name))
	check("list_files" in workspace_tools and "apply_patch" in workspace_tools, "workspace mode advertises file tools")
	check("append_job" not in workspace_tools and "save_edited_scene" not in workspace_tools, "workspace mode hides editor-only tools")
	check("read_project_file" in workspace_tools, "workspace mode keeps shared script tools")
	check(registry.set_tool_mode("hybrid"), "hybrid mode is accepted")
	var hybrid_tools: Array = Array(registry.tools_payload()).map(func(tool): return str(tool.function.name))
	check("list_files" in hybrid_tools and "append_job" in hybrid_tools, "hybrid mode advertises both families")
	check(not registry.set_tool_mode("everything"), "unknown tool modes are rejected")
	check(registry.get_tool_mode() == "hybrid", "rejected mode leaves the previous mode")
	check("Tool mode: hybrid" in registry.capability_summary(), "capability summary names the active mode")
	registry.set_tool_mode("editor")
	check(error_code(await registry.execute("list_files", {"path": "res://"})) == "tool_mode_denied", "editor mode denies workspace tool execution")
	registry.set_tool_mode("workspace")
	check(error_code(await registry.execute("append_job", {"operation": "create_tree"})) == "tool_mode_denied", "workspace mode denies editor tool execution")
	var listing: Dictionary = await registry.execute("list_files", {"path": "res://scripts"})
	check(listing.get("ok", false) and str(listing.get("tool", "")) == "list_files", "workspace registry dispatches to the provider")
