extends SceneTree

const Inspector = preload("res://editor/tiiny/tools/inspector.gd")
const SAVED_RESOURCE := "res://integrations/tiiny/tests/fixtures/workspace/rectangle.tres"

class FakeApi extends RefCounted:
	var scene_root: Node
	var selection: Array = []
	var unsaved: PackedStringArray = PackedStringArray()
	var playing := false
	var hash := "a".repeat(64)
	var version := 2

	func edited_root() -> Node: return scene_root
	func selected_nodes() -> Array: return selection
	func unsaved_scenes() -> PackedStringArray: return unsaved
	func is_playing() -> bool: return playing
	func scene_hash(_path: String) -> String: return hash
	func history_version(_root: Node) -> int: return version

var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func result_ok(result: Dictionary, expected := true) -> bool:
	return result.get("ok", false) == expected

func error_code(result: Dictionary) -> String:
	return str(result.get("error", {}).get("code", ""))

func _initialize() -> void:
	var scene_root := Node2D.new()
	scene_root.name = "Root"
	scene_root.set_scene_file_path("res://fixtures/workspace.tscn")
	root.add_child(scene_root)
	var player := Node2D.new()
	player.name = "Player"
	scene_root.add_child(player)
	player.owner = scene_root
	player.position = Vector2(12, 34)
	var shape := CollisionShape2D.new()
	shape.name = "Shape"
	player.add_child(shape)
	shape.owner = scene_root
	shape.shape = RectangleShape2D.new()
	shape.shape.size = Vector2(32, 16)
	var enemy := Node2D.new()
	enemy.name = "Enemy"
	scene_root.add_child(enemy)
	enemy.owner = scene_root
	enemy.set_scene_file_path("res://fixtures/enemy.tscn")
	scene_root.set_editable_instance(enemy, true)
	var receiver := Node2D.new()
	receiver.name = "Receiver"
	scene_root.add_child(receiver)
	receiver.owner = scene_root
	receiver.renamed.connect(Callable(receiver, "queue_free"))

	var api := FakeApi.new()
	api.scene_root = scene_root
	api.selection = [player]
	var inspector = Inspector.new(api)

	var context: Dictionary = inspector.execute("get_workspace_context", {})
	check(result_ok(context), "workspace context")
	check(context.data.scene.path == "res://fixtures/workspace.tscn", "scene path")
	check(context.data.scene.revision == "sha256:" + api.hash, "base revision")
	check(context.data.scene.session_revision == "undo:2", "session revision")
	check(not context.data.scene.dirty, "clean scene")
	check(context.data.selected_count == 1 and context.data.selection[0].path == "Player", "selection summary")
	var first_context := {"scene_path": context.data.scene.path, "revision": context.data.scene.revision, "session_revision": context.data.scene.session_revision, "root_instance_id": context.data.scene.root_instance_id}

	var tree: Dictionary = inspector.execute("get_scene_tree", {"max_depth": 2, "max_nodes": 100})
	check(result_ok(tree), "scene tree")
	var paths: Array = tree.data.nodes.map(func(node): return node.path)
	check(paths == [".", "Player", "Enemy", "Receiver", "Player/Shape"], "breadth-first paths: " + str(paths))
	check(tree.data.nodes[1].owner == "." and tree.data.nodes[2].scene_file_path == "res://fixtures/enemy.tscn", "ownership/instance metadata")
	check(tree.data.nodes[2].editable, "editable instance flag")
	check(not tree.data.nodes[0].editable, "root is not editable")
	var shallow: Dictionary = inspector.execute("get_scene_tree", {"max_depth": 0})
	check(shallow.data.nodes.size() == 1 and shallow.data.truncated.depth, "depth truncation")
	check(error_code(inspector.execute("get_scene_tree", {"max_depth": 9})) == "invalid_arguments", "max_depth bounds")
	check(error_code(inspector.execute("get_scene_tree", {"include_internal": "yes"})) == "invalid_arguments", "include_internal type")

	var selection: Dictionary = inspector.execute("get_selection", {})
	check(result_ok(selection) and selection.data.selected_count == 1 and selection.data.nodes[0].path == "Player", "selection tool")
	api.selection = []
	selection = inspector.execute("get_selection", {})
	check(result_ok(selection) and selection.data.nodes.is_empty(), "empty selection is not an error")

	var node: Dictionary = inspector.execute("inspect_node", {"path": "Player", "max_properties": 200})
	check(result_ok(node), "inspect node")
	check(node.data.node.class == "Node2D" and node.data.node.owner == ".", "node identity")
	check(node.data.node.groups == [], "groups")
	var position: Array = node.data.properties.filter(func(property): return property.name == "position")
	check(position.size() == 1 and position[0].type == "Vector2" and position[0].writable, "position property")
	check(position[0].value == "(12.0, 34.0)", "position value: " + str(position[0].value))
	check(not Array(node.data.properties).any(func(property): return property.name.begins_with("metadata/") or property.usage.has("category") or property.usage.has("secret")), "excluded properties")
	var limited: Dictionary = inspector.execute("inspect_node", {"path": "Player", "max_properties": 2})
	check(limited.data.properties.size() <= 2 and limited.data.truncated.properties, "property truncation")

	var embedded: Dictionary = inspector.execute("inspect_resource", {"node_path": "Player/Shape", "property": "shape"})
	check(result_ok(embedded) and embedded.data.resource.class == "RectangleShape2D" and embedded.data.resource.embedded, "embedded resource")
	check(Array(embedded.data.properties).any(func(property): return property.name == "size" and property.type == "Vector2"), "resource property")
	var saved: Dictionary = inspector.execute("inspect_resource", {"path": SAVED_RESOURCE})
	check(result_ok(saved) and saved.data.resource.path == SAVED_RESOURCE and not saved.data.resource.embedded, "saved resource")
	check(error_code(inspector.execute("inspect_resource", {"node_path": "Player", "property": "position"})) == "not_a_resource", "property type rejection")
	check(error_code(inspector.execute("inspect_resource", {"path": "res://fixtures/missing.tres"})) == "not_found", "missing resource")
	check(error_code(inspector.execute("inspect_resource", {"path": SAVED_RESOURCE, "node_path": "Player", "property": "shape"})) == "invalid_arguments", "resource argument exclusivity")
	check(error_code(inspector.execute("inspect_resource", {})) == "invalid_arguments", "resource requires arguments")

	var signals: Dictionary = inspector.execute("list_signals", {"path": "Receiver", "max_connections": 100})
	check(result_ok(signals), "signals")
	var renamed: Array = signals.data.signals.filter(func(entry): return entry.name == "renamed")
	check(renamed.size() == 1 and renamed[0].connections.size() == 1 and renamed[0].connections[0].target == "Receiver", "signal connection summary")
	check(not result_ok(inspector.execute("list_signals", {"path": "Missing"})), "missing signal target")

	check(error_code(inspector.execute("inspect_node", {"path": "/abs"})) == "invalid_path", "absolute path rejected")
	check(error_code(inspector.execute("inspect_node", {"path": "Player/../Player"})) == "invalid_path", "traversal rejected")
	check(error_code(inspector.execute("inspect_node", {"path": "Missing"})) == "target_missing", "missing target")
	check(error_code(inspector.execute("inspect_node", {})) == "invalid_arguments", "missing path")
	var transient := Node2D.new()
	transient.name = "Transient"
	scene_root.add_child(transient)
	transient.owner = scene_root
	check(result_ok(inspector.execute("inspect_node", {"path": "Transient"})), "transient target")
	scene_root.remove_child(transient)
	transient.free()
	check(error_code(inspector.execute("inspect_node", {"path": "Transient"})) == "target_missing", "deleted target")

	api.version = 3
	check(error_code(inspector.execute("get_workspace_context", {}, first_context)) == "stale_scene", "undo revision staleness")
	api.version = 2
	api.hash = "b".repeat(64)
	check(error_code(inspector.execute("get_workspace_context", {}, first_context)) == "stale_scene", "file revision staleness")
	api.hash = "a".repeat(64)
	var wrong_root := first_context.duplicate(true)
	wrong_root.root_instance_id = 1
	check(error_code(inspector.execute("get_workspace_context", {}, wrong_root)) == "stale_scene", "root identity staleness")

	api.unsaved = PackedStringArray([scene_root.scene_file_path])
	var dirty: Dictionary = inspector.execute("get_workspace_context", {})
	check(result_ok(dirty) and dirty.data.scene.dirty, "dirty scene inspectable")
	check(error_code(inspector.execute("get_scene_revision", {})) == "scene_dirty", "revision requires clean scene")
	api.unsaved = PackedStringArray()
	var revision: Dictionary = inspector.execute("get_scene_revision", {})
	check(result_ok(revision) and revision.data.scene_sha256 == "a".repeat(64), "compatibility revision")

	api.scene_root = null
	check(error_code(inspector.execute("get_workspace_context", {})) == "no_scene", "no scene")
	api.scene_root = scene_root
	var original_path := scene_root.scene_file_path
	scene_root.set_scene_file_path("")
	check(error_code(inspector.execute("get_workspace_context", {})) == "scene_not_saved", "never-saved scene")
	scene_root.set_scene_file_path(original_path)
	api.hash = ""
	check(error_code(inspector.execute("get_workspace_context", {})) == "scene_unreadable", "unreadable scene")
	api.hash = "a".repeat(64)
	api.version = -1
	check(error_code(inspector.execute("get_workspace_context", {})) == "history_unavailable", "missing history")
	api.version = 2
	check(error_code(inspector.execute("get_workspace_context", {}, {"scene_path": 1})) == "invalid_arguments", "malformed turn context")

	var counts := [scene_root.get_child_count(), api.selection.size(), api.version]
	for definition in inspector.definitions():
		var name := str(definition.name)
		var arguments := {}
		if name == "inspect_node" or name == "list_signals": arguments = {"path": "Player"}
		elif name == "inspect_resource": arguments = {"path": SAVED_RESOURCE}
		var call: Dictionary = inspector.execute(name, arguments)
		check(result_ok(call), "definition executes: " + name)
	check(counts == [scene_root.get_child_count(), api.selection.size(), api.version], "inspection is read-only")
	check(inspector.definitions().size() == 7, "seven definitions")

	var large_root := Node2D.new()
	large_root.name = "Large"
	large_root.set_scene_file_path("res://fixtures/workspace.tscn")
	root.add_child(large_root)
	for index in range(500):
		var child := Node2D.new()
		child.name = "Child%03d" % index
		large_root.add_child(child)
		child.owner = large_root
	api.scene_root = large_root
	var large: Dictionary = inspector.execute("get_scene_tree", {"max_nodes": 500})
	check(result_ok(large) and JSON.stringify(large).length() <= 16384, "result byte budget: " + str(JSON.stringify(large).length()))
	check(large.data.truncated.get("result", false) or large.data.truncated.get("nodes", false), "large result reports truncation")

	large_root.queue_free()
	scene_root.queue_free()
	print("workspace inspector failures: ", failures)
	quit(1 if failures else 0)
