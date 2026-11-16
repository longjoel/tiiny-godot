@tool
extends RefCounted

# Read-only workspace inspector. The provider never mutates the scene,
# resources, undo history, editor state, or project files.

const MAX_RESULT_BYTES := 16384
const MAX_STRING := 512
const MAX_COLLECTION := 64
const MAX_SIGNALS := 200
const USAGE_LABELS := {
	PROPERTY_USAGE_STORAGE: "storage",
	PROPERTY_USAGE_EDITOR: "editor",
	PROPERTY_USAGE_INTERNAL: "internal",
	PROPERTY_USAGE_CATEGORY: "category",
	PROPERTY_USAGE_GROUP: "group",
	PROPERTY_USAGE_SUBGROUP: "subgroup",
	PROPERTY_USAGE_READ_ONLY: "read_only",
	PROPERTY_USAGE_SECRET: "secret",
}

var api

func _init(p_api = null) -> void:
	api = p_api if p_api != null else EditorApi.new()

# Production adapter. Fixtures inject a RefCounted with the same methods so
# provider tests do not require a live editor.
class EditorApi extends RefCounted:
	func edited_root() -> Node:
		return EditorInterface.get_edited_scene_root()

	func selected_nodes() -> Array:
		var selection := EditorInterface.get_selection()
		return selection.get_selected_nodes() if selection != null else []

	func unsaved_scenes() -> PackedStringArray:
		return EditorInterface.get_unsaved_scenes()

	func is_playing() -> bool:
		return EditorInterface.is_playing_scene()

	func scene_hash(path: String) -> String:
		return FileAccess.get_sha256(path)

	func history_version(root: Node) -> int:
		var manager := EditorInterface.get_editor_undo_redo()
		if manager == null:
			return -1
		var history_id: int = manager.get_object_history_id(root)
		if history_id <= 0:
			return -1
		var history = manager.get_history_undo_redo(history_id)
		if history == null:
			return -1
		return int(history.get_version())

func definitions() -> Array:
	return [
		{
			"name": "get_workspace_context",
			"title": "Get workspace context",
			"description": "Return the edited scene identity, revision, root, selection summary, and edited-scene-only note.",
			"parameters": {"type": "object", "properties": {}, "additionalProperties": false},
			"risk": "read",
			"timeout_ms": 5000,
			"availability": Callable(self, "is_available"),
		},
		{
			"name": "get_scene_tree",
			"title": "Get scene tree",
			"description": "Return a bounded breadth-first tree of scene-relative paths, classes, ownership, and instance metadata.",
			"parameters": {"type": "object", "properties": {
				"max_depth": {"type": "integer", "minimum": 0, "maximum": 8},
				"max_nodes": {"type": "integer", "minimum": 1, "maximum": 500},
				"include_internal": {"type": "boolean"},
			}, "additionalProperties": false},
			"risk": "read",
			"timeout_ms": 5000,
			"availability": Callable(self, "is_available"),
		},
		{
			"name": "get_selection",
			"title": "Get selection",
			"description": "Return the selected scene nodes, or an empty state when nothing is selected.",
			"parameters": {"type": "object", "properties": {}, "additionalProperties": false},
			"risk": "read",
			"timeout_ms": 5000,
			"availability": Callable(self, "is_available"),
		},
		{
			"name": "inspect_node",
			"title": "Inspect node",
			"description": "Return class, ownership, script, groups, and bounded editor-visible properties for a scene-relative node path.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"max_properties": {"type": "integer", "minimum": 1, "maximum": 200},
			}, "required": ["path"], "additionalProperties": false},
			"risk": "read",
			"timeout_ms": 5000,
			"availability": Callable(self, "is_available"),
		},
		{
			"name": "inspect_resource",
			"title": "Inspect resource",
			"description": "Inspect a res:// resource or a resource-valued node property, with bounded properties and sub-resources.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"node_path": {"type": "string", "minLength": 1, "maxLength": 512},
				"property": {"type": "string", "minLength": 1, "maxLength": 512},
				"max_properties": {"type": "integer", "minimum": 1, "maximum": 120},
			}, "additionalProperties": false},
			"risk": "read",
			"timeout_ms": 5000,
			"availability": Callable(self, "is_available"),
		},
		{
			"name": "list_signals",
			"title": "List signals",
			"description": "List signal arguments and bounded connections for a scene-relative node path without emitting or connecting anything.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "minLength": 1, "maxLength": 512},
				"max_connections": {"type": "integer", "minimum": 1, "maximum": 100},
			}, "required": ["path"], "additionalProperties": false},
			"risk": "read",
			"timeout_ms": 5000,
			"availability": Callable(self, "is_available"),
		},
		{
			"name": "get_scene_revision",
			"title": "Get scene revision",
			"description": "Return the saved revision of the current clean scene for attachment compatibility.",
			"parameters": {"type": "object", "properties": {}, "additionalProperties": false},
			"risk": "read",
			"timeout_ms": 5000,
			"availability": Callable(self, "is_clean_available"),
		},
	]

func is_available() -> bool:
	var root: Node = api.edited_root()
	return is_instance_valid(root) and not root.scene_file_path.is_empty()

func is_clean_available() -> bool:
	var root: Node = api.edited_root()
	if not is_instance_valid(root) or root.scene_file_path.is_empty():
		return false
	return not Array(api.unsaved_scenes()).has(root.scene_file_path)

# Public seams for editor-owned transaction recipes and fixtures.
func scene_context(turn_context: Dictionary = {}) -> Dictionary:
	return _scene_context(turn_context)

func resolve_scene_node(root: Node, path: String) -> Dictionary:
	return _resolve_node(root, path)

func node_summary(node: Node, root: Node) -> Dictionary:
	return _node_summary(node, root)

func execute(name: String, arguments: Dictionary, turn_context: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result: Dictionary
	if not (arguments is Dictionary):
		result = _error("invalid_arguments", "Arguments must be an object.")
	else:
		var context := _scene_context(turn_context)
		if context.has("error"):
			result = context
		else:
			match name:
				"get_workspace_context": result = _workspace_context(context)
				"get_scene_tree": result = _scene_tree(context, arguments)
				"get_selection": result = _selection(context)
				"inspect_node": result = _inspect_node(context, arguments)
				"inspect_resource": result = _inspect_resource(context, arguments)
				"list_signals": result = _list_signals(context, arguments)
				"get_scene_revision": result = _scene_revision(context)
				_: result = _error("invalid_arguments", "Unknown workspace tool: " + name)
	result = _trim_result(result)
	result["tool"] = name
	result["duration_ms"] = maxi(0, int((Time.get_ticks_usec() - started) / 1000))
	var call_id := str(turn_context.get("call_id", ""))
	if not call_id.is_empty(): result["call_id"] = call_id
	result = _trim_result(result)
	return result

### Scene identity

func _scene_context(turn_context: Dictionary) -> Dictionary:
	if not (turn_context is Dictionary):
		return _error("invalid_arguments", "turn_context must be an object.")
	var root: Node = api.edited_root()
	if not is_instance_valid(root):
		return _error("no_scene", "No edited scene is open.")
	var scene_path := root.scene_file_path
	if scene_path.is_empty():
		return _error("scene_not_saved", "Save the scene once before using workspace tools.")
	var file_hash: String = str(api.scene_hash(scene_path))
	if file_hash.is_empty():
		return _error("scene_unreadable", "Could not read the saved scene revision.")
	var version: int = int(api.history_version(root))
	if version < 0:
		return _error("history_unavailable", "The edited scene has no editor undo history.")
	var revision: String = "sha256:" + file_hash
	var session_revision := "undo:%d" % version
	var context := {
		"root": root,
		"scene_path": scene_path,
		"revision": revision,
		"file_hash": file_hash,
		"session_revision": session_revision,
		"dirty": Array(api.unsaved_scenes()).has(scene_path),
		"playing": bool(api.is_playing()),
		"root_instance_id": int(root.get_instance_id()),
	}
	var stale := _validate_turn_context(turn_context, context)
	if not stale.is_empty(): return stale
	context["scene"] = _scene_summary(context)
	return context

func _validate_turn_context(turn_context: Dictionary, context: Dictionary) -> Dictionary:
	for key in ["scene_path", "revision", "session_revision"]:
		if not turn_context.has(key): continue
		if not (turn_context[key] is String):
			return _error("invalid_arguments", "Invalid turn context field: " + key)
		if turn_context[key] != context[key]:
			return _error("stale_scene", "The scene changed since it was inspected. Re-inspect before continuing.")
	if turn_context.has("root_instance_id"):
		var expected: Variant = turn_context.root_instance_id
		if not (expected is int or expected is float):
			return _error("invalid_arguments", "Invalid turn context field: root_instance_id")
		if int(expected) != int(context.root_instance_id):
			return _error("stale_scene", "The edited scene root changed. Re-inspect before continuing.")
	return {}

func _scene_summary(context: Dictionary) -> Dictionary:
	return {
		"path": context.scene_path,
		"revision": context.revision,
		"session_revision": context.session_revision,
		"dirty": context.dirty,
		"root": ".",
		"root_instance_id": context.root_instance_id,
		"playing": context.playing,
		"edited_scene_only": true,
	}

func _with_scene(result: Dictionary, context: Dictionary) -> Dictionary:
	if not result.get("ok", false):
		result["scene_revision"] = context.revision
		return result
	var data: Dictionary = result.get("data", {})
	data["scene"] = context.scene
	result["data"] = data
	result["scene_revision"] = context.revision
	return result

### Tools

func _workspace_context(context: Dictionary) -> Dictionary:
	var selected := _selected_in_scene(context.root)
	var data := {"selection": selected, "selected_count": selected.size()}
	return _with_scene(_ok(data, "Workspace: %s with %d selected node%s." % [context.scene_path, selected.size(), "" if selected.size() == 1 else "s"]), context)

func _scene_tree(context: Dictionary, arguments: Dictionary) -> Dictionary:
	var max_depth := _int_argument(arguments, "max_depth", 4, 0, 8)
	if max_depth < 0: return _error("invalid_arguments", "max_depth must be between 0 and 8.", "max_depth")
	var max_nodes := _int_argument(arguments, "max_nodes", 200, 1, 500)
	if max_nodes < 1: return _error("invalid_arguments", "max_nodes must be between 1 and 500.", "max_nodes")
	var include_internal := false
	if arguments.has("include_internal"):
		if not (arguments.include_internal is bool):
			return _error("invalid_arguments", "include_internal must be a boolean.", "include_internal")
		include_internal = bool(arguments.include_internal)
	var queue: Array = [[context.root, 0]]
	var nodes: Array = []
	var truncated := {"nodes": false, "depth": false}
	while not queue.is_empty():
		if nodes.size() >= max_nodes:
			truncated.nodes = true
			break
		var item: Array = queue.pop_front()
		var node: Node = item[0]
		var depth: int = item[1]
		nodes.append(_node_summary(node, context.root))
		var visible_children := node.get_child_count(include_internal)
		if depth >= max_depth:
			if visible_children > 0: truncated.depth = true
			continue
		for child in node.get_children(include_internal):
			queue.append([child, depth + 1])
	var data := {"nodes": nodes, "truncated": truncated}
	return _with_scene(_ok(data, "Scene tree: %d node%s%s." % [nodes.size(), "" if nodes.size() == 1 else "s", " (truncated)" if truncated.nodes or truncated.depth else ""]), context)

func _selection(context: Dictionary) -> Dictionary:
	var nodes := _selected_in_scene(context.root)
	var data := {"nodes": nodes, "selected_count": nodes.size(), "truncated": {"nodes": false}}
	return _with_scene(_ok(data, "No nodes selected" if nodes.is_empty() else "%d node%s selected." % [nodes.size(), "" if nodes.size() == 1 else "s"]), context)

func _inspect_node(context: Dictionary, arguments: Dictionary) -> Dictionary:
	if not arguments.has("path") or not (arguments.get("path") is String) or str(arguments.get("path")).is_empty():
		return _error("invalid_arguments", "path is required.", "path")
	var path := str(arguments.get("path", ""))
	var max_properties := _int_argument(arguments, "max_properties", 80, 1, 200)
	if max_properties < 1: return _error("invalid_arguments", "max_properties must be between 1 and 200.", "max_properties")
	var found := _resolve_node(context.root, path)
	if found.has("error"): return found
	var node: Node = found.node
	var properties := _property_list(node, max_properties)
	var summary := _node_summary(node, context.root)
	summary["groups"] = _string_array(node.get_groups())
	summary["child_count"] = node.get_child_count()
	var data := {"node": summary, "properties": properties.items, "truncated": {"properties": properties.truncated}}
	return _with_scene(_ok(data, "Inspected %s [%s] with %d editor propert%s." % [path, node.get_class(), properties.items.size(), "y" if properties.items.size() == 1 else "ies"]), context)

func _inspect_resource(context: Dictionary, arguments: Dictionary) -> Dictionary:
	var path := str(arguments.get("path", ""))
	var node_path := str(arguments.get("node_path", ""))
	var property := str(arguments.get("property", ""))
	var has_path := not path.is_empty()
	var has_property := not node_path.is_empty() and not property.is_empty()
	if has_path == has_property:
		return _error("invalid_arguments", "Provide either path, or node_path and property.")
	var max_properties := _int_argument(arguments, "max_properties", 60, 1, 120)
	if max_properties < 1: return _error("invalid_arguments", "max_properties must be between 1 and 120.", "max_properties")
	var resource: Resource
	if has_path:
		if not path.begins_with("res://") or ".." in path.split("/") or path.length() > 512:
			return _error("invalid_path", "Resource paths must be a res:// path without traversal.")
		if not ResourceLoader.exists(path):
			return _error("not_found", "No resource exists at " + path)
		resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) as Resource
		if resource == null:
			return _error("not_found", "No resource exists at " + path)
	else:
		var found := _resolve_node(context.root, node_path)
		if found.has("error"): return found
		if not _valid_property_name(property):
			return _error("invalid_arguments", "Invalid property name.", "property")
		var value: Variant = found.node.get(property)
		if not (value is Resource):
			return _error("not_a_resource", "The selected property is not a Resource.")
		resource = value
	var properties := _property_list(resource, max_properties)
	var sub_resources: Array = []
	for property_info in resource.get_property_list():
		var property_name := str(property_info.get("name", ""))
		if property_name.is_empty() or property_name.begins_with("metadata/"): continue
		var value: Variant = resource.get(property_name)
		if value is Resource:
			sub_resources.append(_resource_reference(value))
			if sub_resources.size() >= 32: break
	var data := {
		"resource": {"class": resource.get_class(), "path": resource.resource_path, "name": resource.resource_name, "embedded": resource.resource_path.is_empty() or "::" in resource.resource_path},
		"properties": properties.items,
		"sub_resources": sub_resources,
		"truncated": {"properties": properties.truncated, "sub_resources": sub_resources.size() >= 32},
	}
	return _with_scene(_ok(data, "Inspected %s with %d propert%s." % [str(data.resource.path if not str(data.resource.path).is_empty() else data.resource.class), properties.items.size(), "y" if properties.items.size() == 1 else "ies"]), context)

func _list_signals(context: Dictionary, arguments: Dictionary) -> Dictionary:
	if not arguments.has("path") or not (arguments.get("path") is String) or str(arguments.get("path")).is_empty():
		return _error("invalid_arguments", "path is required.", "path")
	var path := str(arguments.get("path", ""))
	var max_connections := _int_argument(arguments, "max_connections", 50, 1, 100)
	if max_connections < 1: return _error("invalid_arguments", "max_connections must be between 1 and 100.", "max_connections")
	var found := _resolve_node(context.root, path)
	if found.has("error"): return found
	var node: Node = found.node
	var signals: Array = []
	var total_connections := 0
	var truncated := {"signals": false, "connections": false}
	for signal_info in node.get_signal_list():
		if signals.size() >= MAX_SIGNALS:
			truncated.signals = true
			break
		var connections: Array = []
		for connection in node.get_signal_connection_list(str(signal_info.get("name", ""))):
			if total_connections >= max_connections:
				truncated.connections = true
				break
			connections.append(_connection_summary(connection, context.root))
			total_connections += 1
		signals.append({"name": str(signal_info.get("name", "")), "args": _signal_args(signal_info), "connections": connections})
	var data := {"signals": signals, "truncated": truncated}
	return _with_scene(_ok(data, "Listed %d signal%s and %d connection%s." % [signals.size(), "" if signals.size() == 1 else "s", total_connections, "" if total_connections == 1 else "s"]), context)

func _scene_revision(context: Dictionary) -> Dictionary:
	if context.dirty:
		return _error("scene_dirty", "Save the scene before requesting its attachment revision.")
	var result := _ok({"scene_path": context.scene_path, "scene_sha256": context.file_hash}, "Scene revision: " + context.scene_path)
	result["scene_revision"] = context.revision
	return result

### Node and property helpers

func _resolve_node(root: Node, path: String) -> Dictionary:
	if path.is_empty() or path.length() > 512 or path.begins_with("/") or "\\" in path or ":" in path or ".." in path.split("/"):
		return _error("invalid_path", "Node paths must be scene-relative without traversal.")
	var node := root.get_node_or_null(NodePath(path))
	if node == null:
		return _error("target_missing", "No node exists at " + path)
	if node != root and not root.is_ancestor_of(node):
		return _error("outside_scene", "The node is not under the edited scene root.")
	return {"node": node}

func _selected_in_scene(root: Node) -> Array:
	var nodes: Array = []
	for node in api.selected_nodes():
		if not is_instance_valid(node) or not (node is Node): continue
		if node != root and not root.is_ancestor_of(node): continue
		if nodes.size() >= 200: break
		nodes.append(_node_summary(node, root))
	return nodes

func _node_summary(node: Node, root: Node) -> Dictionary:
	var owner_path: Variant = null
	var owner := node.get_owner()
	if owner != null:
		owner_path = "." if owner == root else str(root.get_path_to(owner))
	var script := ""
	var attached: Variant = node.get_script()
	if attached is Script and not attached.resource_path.is_empty(): script = attached.resource_path
	var editable := false
	if node != root and root.is_ancestor_of(node):
		editable = root.is_editable_instance(node)
	return {
		"path": "." if node == root else str(root.get_path_to(node)),
		"name": str(node.name),
		"class": node.get_class(),
		"owner": owner_path,
		"scene_file_path": node.get_scene_file_path(),
		"instance_placeholder": node.get_scene_instance_load_placeholder(),
		"editable": editable,
		"script": script,
		"child_count": node.get_child_count(false),
	}

func _property_list(object: Object, maximum: int) -> Dictionary:
	var items: Array = []
	var truncated := false
	for property_info in object.get_property_list():
		var property_name := str(property_info.get("name", ""))
		var usage := int(property_info.get("usage", 0))
		if not _include_property(property_name, usage): continue
		if items.size() >= maximum:
			truncated = true
			break
		var value: Variant = object.get(property_name)
		items.append({
			"name": property_name,
			"type": type_string(int(property_info.get("type", TYPE_NIL))),
			"hint": int(property_info.get("hint", PROPERTY_HINT_NONE)),
			"hint_string": str(property_info.get("hint_string", "")).left(MAX_STRING),
			"class_name": str(property_info.get("class_name", "")),
			"usage": _usage_labels(usage),
			"writable": _writable(object, property_name, usage),
			"value": _safe_value(value),
		})
	return {"items": items, "truncated": truncated}

func _include_property(name: String, usage: int) -> bool:
	if name.is_empty() or name.begins_with("metadata/"): return false
	if (usage & (PROPERTY_USAGE_INTERNAL | PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_SECRET)) != 0: return false
	return (usage & (PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE)) != 0

func _writable(object: Object, name: String, usage: int) -> bool:
	if (usage & PROPERTY_USAGE_READ_ONLY) != 0: return false
	return object.has_method("set_" + name)

func _usage_labels(usage: int) -> Array:
	var labels: Array = []
	for flag in USAGE_LABELS:
		if (usage & flag) != 0: labels.append(USAGE_LABELS[flag])
	return labels

func _signal_args(signal_info: Dictionary) -> Array:
	var result: Array = []
	for argument in signal_info.get("args", []):
		if not (argument is Dictionary): continue
		result.append({"name": str(argument.get("name", "")), "type": type_string(int(argument.get("type", TYPE_NIL))), "class_name": str(argument.get("class_name", ""))})
	return result

func _connection_summary(connection: Dictionary, root: Node) -> Dictionary:
	var callable: Variant = connection.get("callable")
	var result := {"flags": int(connection.get("flags", 0)), "method": "", "target": "", "class": "", "external": false, "freed": false}
	if not (callable is Callable):
		result.freed = true
		return result
	result.method = str(callable.get_method())
	var target = callable.get_object()
	if not is_instance_valid(target):
		result.freed = true
		return result
	result.class = target.get_class()
	if target is Node and (target == root or root.is_ancestor_of(target)):
		result.target = "." if target == root else str(root.get_path_to(target))
	else:
		result.external = true
	return result

func _resource_reference(resource: Resource) -> Dictionary:
	return {"class": resource.get_class(), "path": resource.resource_path, "name": resource.resource_name, "embedded": resource.resource_path.is_empty() or "::" in resource.resource_path}

func _string_array(values: Array) -> Array:
	var result: Array = []
	for value in values:
		result.append(str(value))
		if result.size() >= MAX_COLLECTION: break
	return result

func _safe_value(value: Variant, depth := 0) -> Variant:
	if depth > 4: return "<max-depth>"
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT:
			return value
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(value).left(MAX_STRING)
		TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_RECT2, TYPE_RECT2I, TYPE_COLOR, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_BASIS, TYPE_QUATERNION, TYPE_PLANE, TYPE_AABB:
			return str(value)
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var packed: Array = []
			for item in value:
				if packed.size() >= MAX_COLLECTION: break
				packed.append(_safe_value(item, depth + 1))
			return packed
		TYPE_ARRAY:
			var array: Array = []
			for item in value:
				if array.size() >= MAX_COLLECTION: break
				array.append(_safe_value(item, depth + 1))
			return array
		TYPE_DICTIONARY:
			var dictionary := {}
			for key in value:
				if dictionary.size() >= MAX_COLLECTION: break
				dictionary[str(key).left(MAX_STRING)] = _safe_value(value[key], depth + 1)
			return dictionary
		TYPE_OBJECT:
			if value is Node:
				return {"class": value.get_class(), "path": str(value.get_path())}
			if value is Resource:
				return _resource_reference(value)
			if value == null: return null
			return {"class": value.get_class(), "value": "<object>"}
		TYPE_CALLABLE:
			return {"class": "Callable", "value": "<callable>"}
		TYPE_RID:
			return {"class": "RID", "value": "<rid>"}
		TYPE_SIGNAL:
			return {"class": "Signal", "value": "<signal>"}
	return {"class": type_string(typeof(value)), "value": "<unsupported>"}

func _valid_property_name(name: String) -> bool:
	return not name.is_empty() and name.length() <= 512 and not name.begins_with("/") and ".." not in name

func _int_argument(arguments: Dictionary, key: String, fallback: int, minimum: int, maximum: int) -> int:
	if not arguments.has(key):
		return fallback
	var value: Variant = arguments[key]
	if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floorf(float(value)):
		return -1
	var number := int(value)
	if number < minimum or number > maximum:
		return -1
	return number

### Result helpers

func _ok(data: Dictionary, summary: String) -> Dictionary:
	return {"ok": true, "summary": summary, "data": data}

func _error(code: String, message: String, field := "") -> Dictionary:
	var error := {"code": code, "message": message}
	if not field.is_empty(): error["field"] = field
	return {"ok": false, "summary": message, "error": error}

func _trim_result(result: Dictionary) -> Dictionary:
	if JSON.stringify(result).length() <= MAX_RESULT_BYTES:
		return result
	var data: Dictionary = result.get("data", {})
	var truncated: Dictionary = data.get("truncated", {})
	for key in ["signals", "properties", "sub_resources", "nodes", "selection"]:
		if not (data.get(key) is Array): continue
		while JSON.stringify(result).length() > MAX_RESULT_BYTES and not data[key].is_empty():
			data[key].pop_back()
			truncated["result"] = true
	if not truncated.is_empty(): data["truncated"] = truncated
	result["data"] = data
	while JSON.stringify(result).length() > MAX_RESULT_BYTES:
		var removed := false
		for key in ["signals", "properties", "sub_resources", "nodes", "selection"]:
			if not (data.get(key) is Array) or data[key].is_empty(): continue
			data[key].pop_back()
			truncated["result"] = true
			data["truncated"] = truncated
			removed = true
			break
		if not removed: break
	return result
