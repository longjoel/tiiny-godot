@tool
extends RefCounted

# Class-agnostic scene transaction executor plus editor-owned recipes.
# Recipes declare typed operations; this file does not know CollisionShape2D,
# RectangleShape2D, or any other recipe class.

const MAX_OPS := 64
const MAX_VALUE := 512

var inspector
var recipes := {}

func _init(p_inspector = null) -> void:
	inspector = p_inspector
	_register_default_recipes()

func definitions() -> Array:
	var result: Array = []
	for name in recipes:
		result.append(recipes[name].duplicate(true))
	result.sort_custom(func(a, b): return str(a.name) < str(b.name))
	return result

func register_recipe(recipe: Dictionary) -> String:
	if not recipe is Dictionary or not recipe.get("name") is String or str(recipe.name).is_empty():
		return "Invalid recipe definition"
	if not recipe.get("validate") is Callable or not recipe.get("build") is Callable:
		return "Recipe requires validate and build callables"
	recipes[str(recipe.name)] = recipe.duplicate(true)
	return ""

func execute(name: String, parameters: Dictionary, turn_context: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result: Dictionary
	if not recipes.has(name):
		result = _error("unknown_recipe", "Unknown scene recipe: " + name)
	elif not (parameters is Dictionary):
		result = _error("invalid_arguments", "Recipe parameters must be an object.")
	else:
		var context: Dictionary = inspector.scene_context(turn_context)
		if context.has("error"):
			result = _error(str(context.error.code), str(context.error.message))
		elif context.dirty:
			result = _error("scene_dirty", "Save the scene before applying an edit.")
		else:
			var validation: Dictionary = recipes[name].validate.call(parameters, context)
			if not validation.get("ok", false):
				result = _error(str(validation.get("code", "validation_failed")), str(validation.get("message", "Recipe validation failed.")))
			else:
				var built: Dictionary = recipes[name].build.call(validation.request)
				if not built.get("ok", false):
					result = _error(str(built.get("code", "invalid_operation")), str(built.get("message", "Recipe could not build operations.")))
				else:
					result = _execute(context, built, name, turn_context)
	result["tool"] = name
	result["duration_ms"] = maxi(0, int((Time.get_ticks_usec() - started) / 1000))
	var call_id := str(turn_context.get("call_id", ""))
	if not call_id.is_empty(): result["call_id"] = call_id
	return result

### Generic executor

func _execute(context: Dictionary, built: Dictionary, recipe_name: String, turn_context: Dictionary) -> Dictionary:
	var ops: Array = built.get("ops", [])
	if ops.is_empty() or ops.size() > MAX_OPS:
		return _error("invalid_operation", "Recipe produced no operations or too many operations.")
	var root: Node = context.root
	var prepared := _prepare(ops, root, context)
	if prepared.has("error"): return prepared
	var nodes: Dictionary = prepared.nodes
	var resources: Dictionary = prepared.resources
	var op_by_id: Dictionary = prepared.op_by_id
	var manager := EditorInterface.get_editor_undo_redo()
	var history_id: int = manager.get_object_history_id(root)
	if history_id <= 0: return _error("outcome_unknown", "The edited scene has no undo history.")
	var history = manager.get_history_undo_redo(history_id)
	var before_count := int(history.get_history_count())
	var action_name := _action_name(recipe_name, built)
	manager.create_action(action_name, UndoRedo.MERGE_DISABLE, root)
	for op in ops:
		_apply_do(manager, op, nodes, resources, op_by_id, root)
	manager.commit_action()
	var after_count := int(history.get_history_count())
	if after_count != before_count + 1 and str(history.get_current_action_name()) != action_name:
		return _error("undo_failed", "The transaction did not create exactly one undo action.")
	var postcondition := _verify(ops, nodes, resources, op_by_id, root)
	if not postcondition.is_empty():
		var undone := history.undo()
		if undone and _scene_is_clean_after_undo(ops, nodes, resources, op_by_id, root):
			return _error("undo_failed", postcondition)
		return _error("outcome_unknown", postcondition + " The edit may remain visible.")
	var after: Dictionary = inspector.scene_context({})
	var scene: Dictionary = after.get("scene", {})
	var created_nodes: Array = []
	for id in nodes:
		var node: Node = nodes[id]
		if is_instance_valid(node): created_nodes.append(str(root.get_path_to(node)))
	var created_resources: Array = []
	for id in resources:
		var resource: Resource = resources[id]
		if is_instance_valid(resource): created_resources.append(resource.resource_path if not resource.resource_path.is_empty() else resource.get_class())
	var affected: Array = []
	for path in created_nodes:
		affected.append({"kind": "node", "scene_path": context.scene_path, "path": path})
	for resource in created_resources:
		affected.append({"kind": "resource", "scene_path": context.scene_path, "resource": resource})
	var token := str(turn_context.get("undo_group", ""))
	if token.is_empty(): token = "tiiny:" + Crypto.new().generate_random_bytes(8).hex_encode()
	var data := {"recipe": recipe_name, "scene": scene, "created": {"nodes": created_nodes, "resources": created_resources}, "dirty": true}
	var result := {"ok": true, "summary": str(built.get("summary", "Applied recipe " + recipe_name + ".")), "data": data, "affected": affected, "undo_group": token, "scene_revision": str(scene.get("revision", context.revision))}
	return result

func _prepare(ops: Array, root: Node, context: Dictionary) -> Dictionary:
	var nodes := {}
	var resources := {}
	var op_by_id := {}
	for op in ops:
		if not op is Dictionary or not op.get("op") is String:
			return _error("invalid_operation", "Operation must be an object with an op.")
		var kind := str(op.op)
		var id := str(op.get("id", ""))
		if kind in ["create_node", "create_resource"]:
			if id.is_empty() or op_by_id.has(id) or id.length() > 64:
				return _error("invalid_operation", "Operation IDs must be unique and non-empty.")
			op_by_id[id] = op
	for op in ops:
		var kind := str(op.op)
		match kind:
			"create_node":
				var class_error: Dictionary = _validate_class(op, "Node")
				if not class_error.is_empty(): return class_error
				var name := str(op.get("name", ""))
				if not _valid_name(name): return _error("invalid_name", "Invalid node name.")
				var node = ClassDB.instantiate(str(op.class))
				if node == null or not node is Node: return _error("class_not_instantiable", "Could not instantiate " + str(op.class))
				node.name = name
				nodes[str(op.id)] = node
			"create_resource":
				var class_error: Dictionary = _validate_class(op, "Resource")
				if not class_error.is_empty(): return class_error
				var resource = ClassDB.instantiate(str(op.class))
				if resource == null or not resource is Resource: return _error("class_not_instantiable", "Could not instantiate " + str(op.class))
				var properties: Variant = op.get("properties", {})
				if not (properties is Dictionary): return _error("invalid_operation", "Resource properties must be an object.")
				for property in properties:
					var info := _property_info(resource, str(property))
					if info.is_empty(): return _error("property_missing", "Resource property does not exist: " + str(property))
					if not _value_compatible(info, properties[property]): return _error("type_mismatch", "Resource property type mismatch: " + str(property))
					resource.set(str(property), properties[property])
				resources[str(op.id)] = resource
			_:
				pass
	var error := _validate_references(ops, nodes, resources, op_by_id, root, context)
	if not error.is_empty():
		for id in nodes: nodes[id].free()
		for id in resources: resources[id] = null
		return error
	return {"nodes": nodes, "resources": resources, "op_by_id": op_by_id}

func _validate_class(op: Dictionary, base: String) -> Dictionary:
	var cls := str(op.get("class", ""))
	if cls.is_empty() or not ClassDB.class_exists(cls): return _error("class_not_found", "Class does not exist: " + cls)
	if not ClassDB.can_instantiate(cls): return _error("class_not_instantiable", "Class cannot be instantiated: " + cls)
	if cls != base and not ClassDB.is_parent_class(cls, base): return _error("invalid_operation", "Class is not a " + base + ": " + cls)
	return {}

func _validate_references(ops: Array, nodes: Dictionary, resources: Dictionary, op_by_id: Dictionary, root: Node, context: Dictionary) -> Dictionary:
	for op in ops:
		var kind := str(op.op)
		match kind:
			"add_child":
				var parent := _target_node(str(op.get("parent", "")), root, nodes, op_by_id)
				if parent == null: return _error("target_missing", "add_child parent is missing.")
				var node := _target_node(str(op.get("node", "")), root, nodes, op_by_id)
				if node == null: return _error("target_missing", "add_child node is missing.")
				if node.get_parent() != null: return _error("invalid_operation", "Node already has a parent.")
				if parent == node or node.is_ancestor_of(parent): return _error("invalid_parent", "Invalid parent cycle.")
				if parent.get_node_or_null(NodePath(str(node.name))) != null: return _error("name_conflict", "A sibling already uses the node name.")
			"set_owner":
				var node := _target_node(str(op.get("node", "")), root, nodes, op_by_id)
				var owner := _target_node(str(op.get("owner", "")), root, nodes, op_by_id)
				if node == null: return _error("target_missing", "set_owner node is missing.")
				if owner == null: return _error("target_missing", "set_owner owner is missing.")
				var plan_parent := _planned_parent(node, ops, root, nodes, op_by_id)
				if plan_parent == null or (owner != plan_parent and not owner.is_ancestor_of(plan_parent)):
					return _error("invalid_operation", "set_owner owner is not an ancestor.")
			"set_property":
				var target = _target_object(str(op.get("target", "")), root, nodes, resources, op_by_id)
				if target == null: return _error("target_missing", "set_property target is missing.")
				var property := str(op.get("property", ""))
				var info := _property_info(target, property)
				if info.is_empty(): return _error("property_missing", "Property does not exist: " + property)
				if _read_only(target, property, info): return _error("property_not_writable", "Property is not writable: " + property)
				var value: Variant = _operation_value(op.get("value"), nodes, resources, op_by_id)
				if not _value_compatible(info, value): return _error("type_mismatch", "Property type mismatch: " + property)
			_:
				pass
	return {}

func _planned_parent(node: Node, ops: Array, root: Node, nodes: Dictionary, op_by_id: Dictionary) -> Node:
	for op in ops:
		if str(op.op) == "add_child" and _target_node(str(op.get("node", "")), root, nodes, op_by_id) == node:
			return _target_node(str(op.get("parent", "")), root, nodes, op_by_id)
	return node.get_parent()

func _target_node(id: String, root: Node, nodes: Dictionary, op_by_id: Dictionary) -> Node:
	if nodes.has(id): return nodes[id]
	if op_by_id.has(id) and str(op_by_id[id].op) != "create_node": return null
	var found: Dictionary = inspector.resolve_scene_node(root, id)
	return found.node if found.has("node") else null

func _target_object(id: String, root: Node, nodes: Dictionary, resources: Dictionary, op_by_id: Dictionary) -> Object:
	if nodes.has(id): return nodes[id]
	if resources.has(id): return resources[id]
	var found: Dictionary = inspector.resolve_scene_node(root, id)
	return found.node if found.has("node") else null

func _operation_value(value: Variant, nodes: Dictionary, resources: Dictionary, op_by_id: Dictionary) -> Variant:
	if value is Dictionary and value.has("ref"):
		var id := str(value.ref)
		if resources.has(id): return resources[id]
		if nodes.has(id): return nodes[id]
	return value

func _apply_do(manager: Object, op: Dictionary, nodes: Dictionary, resources: Dictionary, op_by_id: Dictionary, root: Node) -> void:
	var kind := str(op.op)
	match kind:
		"create_node":
			manager.add_do_reference(nodes[str(op.id)])
		"add_child":
			var parent := _target_node(str(op.parent), root, nodes, op_by_id)
			var node := _target_node(str(op.node), root, nodes, op_by_id)
			manager.add_do_method(parent, "add_child", node, true)
			manager.add_undo_method(parent, "remove_child", node)
		"set_owner":
			var node := _target_node(str(op.node), root, nodes, op_by_id)
			var owner := _target_node(str(op.owner), root, nodes, op_by_id)
			manager.add_do_property(node, "owner", owner)
			manager.add_undo_property(node, "owner", null)
		"set_property":
			var target = _target_object(str(op.target), root, nodes, resources, op_by_id)
			var value: Variant = _operation_value(op.value, nodes, resources, op_by_id)
			manager.add_do_property(target, str(op.property), value)
			manager.add_undo_property(target, str(op.property), target.get(str(op.property)))
		_:
			pass

func _verify(ops: Array, nodes: Dictionary, resources: Dictionary, op_by_id: Dictionary, root: Node) -> String:
	for op in ops:
		if str(op.op) == "create_node":
			var node: Node = nodes[str(op.id)]
			if not is_instance_valid(node) or not node.is_inside_tree(): return "Created node is not in the scene."
			if str(node.name) != str(op.get("name", "")): return "Created node name changed."
	for op in ops:
		if str(op.op) == "add_child":
			var parent := _target_node(str(op.parent), root, nodes, op_by_id)
			var node := _target_node(str(op.node), root, nodes, op_by_id)
			if node.get_parent() != parent: return "Created node parent changed."
		elif str(op.op) == "set_owner":
			var node := _target_node(str(op.node), root, nodes, op_by_id)
			var owner := _target_node(str(op.owner), root, nodes, op_by_id)
			if node.get_owner() != owner: return "Created node owner changed."
		elif str(op.op) == "set_property":
			var target = _target_object(str(op.target), root, nodes, resources, op_by_id)
			var value: Variant = _operation_value(op.value, nodes, resources, op_by_id)
			if target.get(str(op.property)) != value: return "Planned property was not applied."
	for op in ops:
		if str(op.op) == "create_resource":
			var resource: Resource = resources[str(op.id)]
			if not is_instance_valid(resource): return "Created resource became invalid."
			for property in op.get("properties", {}):
				if resource.get(str(property)) != op.properties[property]: return "Resource property was not applied: " + str(property)
	return ""

func _scene_is_clean_after_undo(ops: Array, nodes: Dictionary, resources: Dictionary, op_by_id: Dictionary, root: Node) -> bool:
	for op in ops:
		if str(op.op) == "create_node":
			var node: Node = nodes[str(op.id)]
			if is_instance_valid(node) and node.is_inside_tree(): return false
	return true

### Property helpers

func _property_info(object: Object, name: String) -> Dictionary:
	for info in object.get_property_list():
		if str(info.get("name", "")) == name:
			return info
	return {}

func _read_only(object: Object, name: String, info: Dictionary) -> bool:
	if int(info.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY: return true
	return not object.has_method("set_" + name)

func _value_compatible(info: Dictionary, value: Variant) -> bool:
	var type := int(info.get("type", TYPE_NIL))
	if type == TYPE_OBJECT:
		if value == null: return true
		if not value is Object: return false
		var cls := str(info.get("class_name", ""))
		if cls.is_empty(): return true
		for candidate in cls.split(",", false):
			if value.get_class() == candidate or ClassDB.is_parent_class(value.get_class(), candidate):
				return true
		return false
	if type == TYPE_NIL: return value == null
	return typeof(value) == type

func _valid_name(name: String) -> bool:
	return not name.is_empty() and name.length() <= 128 and name.validate_node_name() == name

func _action_name(recipe_name: String, built: Dictionary) -> String:
	var readable := str(built.get("action_name", ""))
	return readable if not readable.is_empty() else "Tiiny " + recipe_name.replace("_", " ")

### Default recipe

func _register_default_recipes() -> void:
	register_recipe({
		"name": "add_rectangular_collision_shape",
		"title": "Add rectangular collision shape",
		"description": "Create one CollisionShape2D under a physics body and assign an owned RectangleShape2D. One undo action.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "minLength": 1, "maxLength": 512},
			"width": {"type": "number", "exclusiveMinimum": 0, "maximum": 100000},
			"height": {"type": "number", "exclusiveMinimum": 0, "maximum": 100000},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
		}, "required": ["parent_path", "width", "height"], "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 15000,
		"validate": Callable(self, "_validate_collision"),
		"build": Callable(self, "_build_collision"),
	})

func _validate_collision(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_path := str(params.get("parent_path", ""))
	var width: Variant = params.get("width")
	var height: Variant = params.get("height")
	if parent_path.is_empty() or parent_path.length() > 512:
		return {"ok": false, "code": "invalid_arguments", "message": "parent_path is required."}
	if not (width is int or width is float) or not is_finite(float(width)) or float(width) <= 0 or float(width) > 100000:
		return {"ok": false, "code": "invalid_dimensions", "message": "width must be finite and greater than zero."}
	if not (height is int or height is float) or not is_finite(float(height)) or float(height) <= 0 or float(height) > 100000:
		return {"ok": false, "code": "invalid_dimensions", "message": "height must be finite and greater than zero."}
	var found: Dictionary = inspector.resolve_scene_node(context.root, parent_path)
	if found.has("error"):
		return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	var parent: Node = found.node
	if not parent is CollisionObject2D:
		return {"ok": false, "code": "invalid_parent", "message": "The parent must be a CollisionObject2D."}
	if parent != context.root and parent.get_owner() != context.root:
		return {"ok": false, "code": "read_only_instance", "message": "The parent must be owned by the edited scene."}
	for child in parent.get_children(false):
		if child is CollisionShape2D:
			return {"ok": false, "code": "target_conflict", "message": "The parent already has a direct CollisionShape2D."}
	var name := str(params.get("node_name", "")).strip_edges()
	if name.is_empty(): name = _unique_name(parent, "CollisionShape2D")
	elif not _valid_name(name):
		return {"ok": false, "code": "invalid_name", "message": "Invalid node name."}
	if parent.get_node_or_null(NodePath(name)) != null:
		return {"ok": false, "code": "name_conflict", "message": "A node named " + name + " already exists."}
	return {"ok": true, "request": {"parent_path": parent_path, "width": float(width), "height": float(height), "node_name": name}}

func _build_collision(request: Dictionary) -> Dictionary:
	return {"ok": true, "action_name": "Add CollisionShape2D (%.0f×%.0f)" % [request.width, request.height], "summary": "Added %s under %s with an owned %.0f×%.0f RectangleShape2D." % [request.node_name, request.parent_path, request.width, request.height], "ops": [
		{"op": "create_node", "id": "shape", "class": "CollisionShape2D", "name": request.node_name},
		{"op": "create_resource", "id": "rectangle", "class": "RectangleShape2D", "properties": {"size": Vector2(request.width, request.height)}},
		{"op": "add_child", "parent": request.parent_path, "node": "shape"},
		{"op": "set_owner", "node": "shape", "owner": "."},
		{"op": "set_property", "target": "shape", "property": "shape", "value": {"ref": "rectangle"}},
	]}

func _unique_name(parent: Node, base: String) -> String:
	var candidate := base
	var suffix := 2
	while parent.get_node_or_null(NodePath(candidate)) != null:
		candidate = base + str(suffix)
		suffix += 1
	return candidate

### Result helpers

func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "summary": message, "error": {"code": code, "message": message}}
