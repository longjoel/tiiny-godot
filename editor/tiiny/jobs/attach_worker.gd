@tool
extends RefCounted

# A deliberately narrow editor mutation: add one Sprite2D under an explicitly
# named Node2D in the currently open, clean scene. No arbitrary script runs.
var queue: RefCounted
var project_root: String
var finished: Dictionary = {}

func _init(p_queue: RefCounted, p_root: String) -> void:
	queue = p_queue
	project_root = p_root

func _fail(message: String) -> String:
	return message

func _safe_file(path: String) -> bool:
	if not path.begins_with("res://") or path.contains("\\"):
		return false
	var parts := path.trim_prefix("res://").split("/", true)
	var directory := project_root
	for part in parts:
		if part.is_empty() or part.begins_with("."):
			return false
		var access := DirAccess.open(directory)
		if access == null or access.is_link(part):
			return false
		directory = directory.path_join(part)
	return true

func start(job: Dictionary) -> String:
	var params: Dictionary = job.parameters
	var scene_path: String = params.scene_path
	var artifact_id: String = params.artifact_id
	var parent_path: String = params.parent_path
	var node_name: String = params.node_name
	if not _safe_file(scene_path) or not scene_path.ends_with(".tscn"):
		return _fail("Scene path is invalid or contains a symbolic link")
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.scene_file_path != scene_path or scene_path in EditorInterface.get_unsaved_scenes():
		return _fail("Open the intended scene and save its existing changes before attachment")
	if FileAccess.get_sha256(scene_path) != params.scene_sha256:
		return _fail("Target scene changed since the job was accepted")
	var parent := root.get_node_or_null(NodePath(parent_path))
	if not parent is Node2D or (parent != root and parent.owner != root):
		return _fail("The intended parent is not an editable Node2D in the scene")
	if parent.has_node(NodePath(node_name)):
		return _fail("The intended node name already exists")
	var artifact := {}
	for prior in queue.snapshot().jobs:
		if prior.sequence >= job.sequence:
			break
		if prior.state == "completed" and prior.operation == "create_tree":
			var candidate: Variant = prior.result.get("artifact")
			if candidate is Dictionary and candidate.get("id") == artifact_id:
				artifact = candidate
				break
	if artifact.is_empty():
		return _fail("The explicit tree artifact is missing or incomplete")
	var asset_path: String = str(artifact.get("path", ""))
	var asset_hash: String = str(artifact.get("sha256", ""))
	if not _safe_file(asset_path) or not asset_path.ends_with(".png") or asset_hash.length() != 64 or FileAccess.get_sha256(asset_path) != asset_hash:
		return _fail("The tree artifact changed or is unavailable")
	var texture := ResourceLoader.load(asset_path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE)
	if not texture is Texture2D or texture.get_width() != 64 or texture.get_height() != 64:
		return _fail("The tree artifact is not an imported texture")
	# Recheck immediately before the effect. The journal is durable before the
	# undo action; any later failure remains interrupted until reconciled.
	if EditorInterface.get_edited_scene_root() != root or scene_path in EditorInterface.get_unsaved_scenes() or FileAccess.get_sha256(scene_path) != params.scene_sha256 or parent.has_node(NodePath(node_name)) or FileAccess.get_sha256(asset_path) != asset_hash:
		return _fail("Scene or artifact changed before attachment")
	var target := {"scene_path": scene_path, "scene_sha256": params.scene_sha256, "parent_path": parent_path, "node_name": node_name, "artifact_id": artifact_id, "artifact_sha256": asset_hash, "mutation_token": Crypto.new().generate_random_bytes(16).hex_encode()}
	if not queue.mutation(job.id, "prepared", target):
		return _fail("Could not record attachment intent")
	var sprite := Sprite2D.new()
	sprite.name = node_name
	sprite.texture = texture
	sprite.set_meta("_tiiny_job_token", target.mutation_token)
	var history := EditorInterface.get_editor_undo_redo()
	history.create_action("Attach generated tree", UndoRedo.MERGE_DISABLE, root)
	history.add_do_method(parent, "add_child", sprite, true)
	history.add_do_method(sprite, "set_owner", root)
	history.add_do_reference(sprite)
	history.add_undo_method(parent, "remove_child", sprite)
	history.commit_action()
	if sprite.get_parent() != parent or sprite.owner != root or sprite.name != node_name:
		finished = {"state": "failed", "result": {"error": "Attachment could not be verified"}}
		return ""
	if not queue.mutation(job.id, "applied", {"node_path": str(root.get_path_to(sprite))}):
		finished = {"state": "failed", "result": {"error": "Could not record attachment"}}
		return ""
	if EditorInterface.get_edited_scene_root() != root or FileAccess.get_sha256(scene_path) != params.scene_sha256:
		finished = {"state": "failed", "result": {"error": "Scene changed before saving"}}
		return ""
	if EditorInterface.save_scene() != OK:
		finished = {"state": "failed", "result": {"error": "Could not save attached scene"}}
		return ""
	var node_path := str(root.get_path_to(sprite))
	var saved_scene := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var verified_root := saved_scene.instantiate() if saved_scene != null else null
	var verified_node: Node = verified_root.get_node_or_null(NodePath(node_path)) if verified_root != null else null
	var verified: bool = verified_node is Sprite2D and verified_node.texture != null and verified_node.texture.resource_path == asset_path and verified_node.get_meta("_tiiny_job_token", "") == target.mutation_token
	if verified_root != null:
		verified_root.free()
	if not verified or FileAccess.get_sha256(asset_path) != asset_hash:
		finished = {"state": "failed", "result": {"error": "Saved attachment failed validation"}}
		return ""
	var saved_hash := FileAccess.get_sha256(scene_path)
	if saved_hash.is_empty() or not queue.mutation(job.id, "saved", {"scene_sha256": saved_hash}):
		finished = {"state": "failed", "result": {"error": "Could not verify or record the saved scene"}}
		return ""
	finished = {"state": "completed", "result": {"scene": scene_path, "scene_sha256": saved_hash, "node_path": node_path, "artifact_id": artifact_id, "artifact_path": asset_path}}
	return ""

# Reconciliation is read-only until the queue records its decision. It never
# opens a different scene or saves the user's work on the user's behalf.
func reconcile(job: Dictionary) -> Dictionary:
	if job.get("state") != "interrupted" or job.get("operation") != "attach_tree_to_scene" or not job.get("attempts") is Array or job.attempts.is_empty():
		return {"error": "No interrupted scene attachment"}
	var journal: Dictionary = job.attempts.back().get("mutation", {})
	var target: Dictionary = journal.get("target", {})
	var params: Dictionary = job.get("parameters", {})
	for field in ["scene_path", "scene_sha256", "parent_path", "node_name", "artifact_id"]:
		if not target.get(field) is String or target[field] != params.get(field):
			return {"error": "Attachment journal does not match the accepted target"}
	var token: String = str(target.get("mutation_token", ""))
	var asset_hash: String = str(target.get("artifact_sha256", ""))
	if token.length() != 32 or not token.is_valid_hex_number(false) or asset_hash.length() != 64 or not _safe_file(target.scene_path):
		return {"error": "Attachment journal cannot be verified"}
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.scene_file_path != target.scene_path or target.scene_path in EditorInterface.get_unsaved_scenes():
		return {"error": "Open the intended scene and save or discard its changes before checking"}
	var current_hash := FileAccess.get_sha256(target.scene_path)
	var parent := root.get_node_or_null(NodePath(target.parent_path))
	if current_hash.is_empty() or not parent is Node2D:
		return {"error": "The scene or intended parent cannot be verified"}
	var live_node := parent.get_node_or_null(NodePath(target.node_name))
	if current_hash == target.scene_sha256 and live_node == null and journal.phase in ["prepared", "applied"]:
		if queue.reconcile_scene(job.id, "not_applied", {"scene_sha256": current_hash}):
			return {"ok": true, "message": "Scene is unchanged. Choose retry or skip, then resume."}
		return {"error": "Could not record the reconciliation"}
	if not live_node is Sprite2D or live_node.get_meta("_tiiny_job_token", "") != token:
		return {"error": "The saved attachment cannot be identified; the queue remains stopped"}
	var artifact := {}
	for prior in queue.snapshot().jobs:
		if prior.sequence >= job.sequence:
			break
		if prior.state == "completed" and prior.operation == "create_tree" and prior.result.get("artifact") is Dictionary and prior.result.artifact.get("id") == target.artifact_id:
			artifact = prior.result.artifact
			break
	var asset_path: String = str(artifact.get("path", ""))
	if artifact.get("sha256") != asset_hash or not _safe_file(asset_path) or FileAccess.get_sha256(asset_path) != asset_hash or live_node.texture == null or live_node.texture.resource_path != asset_path:
		return {"error": "The attachment's artifact cannot be verified"}
	if journal.phase == "saved" and journal.events.back().details.get("scene_sha256") != current_hash:
		return {"error": "The saved scene changed after the attachment"}
	# Read the saved scene's state without instantiating arbitrary scene scripts.
	var packed := ResourceLoader.load(target.scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return {"error": "Could not read the saved scene"}
	var expected_path := str(root.get_path_to(live_node))
	var scene_state := packed.get_state()
	var saved_match := false
	for index in scene_state.get_node_count():
		if str(scene_state.get_node_path(index)).trim_prefix("./") != expected_path.trim_prefix("./") or scene_state.get_node_type(index) != "Sprite2D":
			continue
		var saved_token := ""
		var saved_texture: Resource
		for property in scene_state.get_node_property_count(index):
			var name := str(scene_state.get_node_property_name(index, property))
			if name == "metadata/_tiiny_job_token":
				saved_token = str(scene_state.get_node_property_value(index, property))
			elif name == "texture":
				saved_texture = scene_state.get_node_property_value(index, property)
		saved_match = saved_token == token and saved_texture != null and saved_texture.resource_path == asset_path
		break
	if not saved_match or FileAccess.get_sha256(target.scene_path) != current_hash or FileAccess.get_sha256(asset_path) != asset_hash:
		return {"error": "The saved attachment does not match the recorded effect"}
	var evidence := {"scene": target.scene_path, "scene_sha256": current_hash, "node_path": expected_path, "artifact_id": target.artifact_id, "artifact_path": asset_path, "mutation_token": token}
	if not queue.reconcile_scene(job.id, "completed", evidence):
		return {"error": "Could not record the reconciliation"}
	return {"ok": true, "message": "Saved attachment verified. Resume the queue when ready."}

func poll() -> Dictionary:
	return finished.duplicate(true) if not finished.is_empty() else {"state": "running", "stage": "Attaching tree"}

func cancel() -> void:
	# The editor mutation is synchronous. Once committed it must be observed
	# and, if needed, undone with the editor's undo system.
	pass
