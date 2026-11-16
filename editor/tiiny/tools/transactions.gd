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
	var data := {"recipe": recipe_name, "action_name": action_name, "scene": scene, "created": {"nodes": created_nodes, "resources": created_resources}, "dirty": true}
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
		if kind in ["create_node", "create_resource", "create_resource_value"]:
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
			"create_resource_value":
				var value: Variant = op.get("resource")
				if not value is Resource: return _error("invalid_operation", "Recipe resource value must be a Resource.")
				resources[str(op.id)] = value
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
			"call_method":
				var target = _target_object(str(op.get("target", "")), root, nodes, resources, op_by_id)
				if target == null: return _error("target_missing", "call_method target is missing.")
				var method := str(op.get("method", ""))
				if method.is_empty() or not target.has_method(method): return _error("method_missing", "Method does not exist: " + method)
				if not op.get("args", []) is Array or op.args.size() > 8: return _error("invalid_operation", "Method arguments must be a bounded array.")
				if op.has("undo_method"):
					var undo_method := str(op.get("undo_method", ""))
					if undo_method.is_empty() or not target.has_method(undo_method): return _error("method_missing", "Undo method does not exist: " + undo_method)
					if not op.get("undo_args", []) is Array or op.undo_args.size() > 8: return _error("invalid_operation", "Undo method arguments must be a bounded array.")
				if op.has("verify_method"):
					var verify_method := str(op.get("verify_method", ""))
					if verify_method.is_empty() or not target.has_method(verify_method): return _error("method_missing", "Verify method does not exist: " + verify_method)
					if not op.get("verify_args", []) is Array or op.verify_args.size() > 8: return _error("invalid_operation", "Verify method arguments must be a bounded array.")
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
		"create_resource_value":
			manager.add_do_reference(resources[str(op.id)])
		"call_method":
			var target = _target_object(str(op.target), root, nodes, resources, op_by_id)
			_add_undo_redo_call(manager, true, target, str(op.method), _operation_args(op.get("args", []), nodes, resources, op_by_id))
			if op.has("undo_method"):
				_add_undo_redo_call(manager, false, target, str(op.undo_method), _operation_args(op.get("undo_args", []), nodes, resources, op_by_id))
		_:
			pass

func _operation_args(value: Variant, nodes: Dictionary, resources: Dictionary, op_by_id: Dictionary) -> Array:
	var result: Array = []
	if not value is Array: return result
	for item in value: result.append(_operation_value(item, nodes, resources, op_by_id))
	return result

func _add_undo_redo_call(manager: Object, is_do: bool, target: Object, method: String, args: Array) -> void:
	var adder := Callable(manager, "add_do_method" if is_do else "add_undo_method")
	adder.callv([target, method] + args)

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
			if not _values_equal(target.get(str(op.property)), value): return "Planned property was not applied."
		elif str(op.op) == "call_method" and op.has("verify_method"):
			var target = _target_object(str(op.target), root, nodes, resources, op_by_id)
			var args := _operation_args(op.get("verify_args", []), nodes, resources, op_by_id)
			var actual: Variant = target.callv(str(op.verify_method), args)
			if actual != op.get("expect", true): return "Planned method postcondition failed: " + str(op.verify_method)
	for op in ops:
		if str(op.op) == "create_resource":
			var resource: Resource = resources[str(op.id)]
			if not is_instance_valid(resource): return "Created resource became invalid."
			for property in op.get("properties", {}):
				if not _values_equal(resource.get(str(property)), op.properties[property]): return "Resource property was not applied: " + str(property)
	return ""

func _values_equal(a: Variant, b: Variant) -> bool:
	if a is float and b is float: return is_equal_approx(float(a), float(b))
	if a is Vector2 and b is Vector2: return a.is_equal_approx(b)
	if a is Vector3 and b is Vector3: return a.is_equal_approx(b)
	if a is Color and b is Color: return a.is_equal_approx(b)
	return a == b

func _scene_is_clean_after_undo(ops: Array, nodes: Dictionary, resources: Dictionary, op_by_id: Dictionary, root: Node) -> bool:
	for op in ops:
		if str(op.op) == "create_node":
			var node: Node = nodes[str(op.id)]
			if is_instance_valid(node) and node.is_inside_tree(): return false
		elif str(op.op) == "call_method" and op.has("verify_method"):
			var target = _target_object(str(op.target), root, nodes, resources, op_by_id)
			var args := _operation_args(op.get("verify_args", []), nodes, resources, op_by_id)
			var actual: Variant = target.callv(str(op.verify_method), args)
			if actual != op.get("undo_expect", not op.get("expect", true)): return false
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
	register_recipe({
		"name": "add_torch_flicker",
		"title": "Add torch flicker animation",
		"description": "Create a native looping light-energy animation; no script.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "maxLength": 512},
			"light_path": {"type": "string", "maxLength": 512},
			"player_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"duration": {"type": "number", "exclusiveMinimum": 0, "maximum": 60},
			"min_energy": {"type": "number", "minimum": 0, "maximum": 100},
			"max_energy": {"type": "number", "minimum": 0, "maximum": 100},
			"steps": {"type": "integer", "minimum": 2, "maximum": 64},
		}, "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 15000,
		"validate": Callable(self, "_validate_torch"),
		"build": Callable(self, "_build_torch"),
	})
	register_recipe({
		"name": "assign_slippery_surface",
		"title": "Assign slippery physics material",
		"description": "Assign an owned low-friction PhysicsMaterial to a 2D physics body.",
		"parameters": {"type": "object", "properties": {
			"target_path": {"type": "string", "minLength": 1, "maxLength": 512},
			"friction": {"type": "number", "minimum": 0, "maximum": 1},
			"bounce": {"type": "number", "minimum": 0, "maximum": 1},
			"rough": {"type": "boolean"},
			"absorbent": {"type": "boolean"},
		}, "required": ["target_path"], "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 15000,
		"validate": Callable(self, "_validate_slippery"),
		"build": Callable(self, "_build_slippery"),
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

func _is_light(node: Node) -> bool:
	return node is Light2D or node is Light3D

func _find_owned_light(parent: Node, root: Node) -> Node:
	for child in parent.get_children(true):
		if _is_light(child) and (child == root or child.get_owner() == root):
			return child
		var nested := _find_owned_light(child, root)
		if nested != null: return nested
	return null

func _validate_torch(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_path := str(params.get("parent_path", "")).strip_edges()
	var light_path := str(params.get("light_path", "")).strip_edges()
	if parent_path.is_empty() and light_path.is_empty():
		return {"ok": false, "code": "invalid_arguments", "message": "Provide a light_path or a parent_path containing a light."}
	var root: Node = context.root
	var light: Node = null
	var parent: Node = null
	if not light_path.is_empty():
		var found: Dictionary = inspector.resolve_scene_node(root, light_path)
		if found.has("error"):
			return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
		light = found.node
		parent = light.get_parent()
	else:
		var found: Dictionary = inspector.resolve_scene_node(root, parent_path)
		if found.has("error"):
			return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
		parent = found.node
		light = parent if _is_light(parent) else _find_owned_light(parent, root)
	if light == null:
		return {"ok": false, "code": "target_missing", "message": "No owned Light2D or Light3D was found under the target. Add a light or name one explicitly; no script fallback was created."}
	if not _is_light(light):
		return {"ok": false, "code": "invalid_target", "message": "The target must be a Light2D or Light3D."}
	if light != root and light.get_owner() != root:
		return {"ok": false, "code": "read_only_instance", "message": "The light must be owned by the edited scene."}
	if parent == null:
		return {"ok": false, "code": "invalid_parent", "message": "The light has no parent for the AnimationPlayer."}
	if parent != root and parent.get_owner() != root:
		return {"ok": false, "code": "read_only_instance", "message": "The AnimationPlayer parent must be owned by the edited scene."}
	var name := str(params.get("player_name", "")).strip_edges()
	if name.is_empty(): name = _unique_name(parent, "AnimationPlayer")
	elif not _valid_name(name):
		return {"ok": false, "code": "invalid_name", "message": "Invalid AnimationPlayer name."}
	if parent.get_node_or_null(NodePath(name)) != null:
		return {"ok": false, "code": "name_conflict", "message": "A node named " + name + " already exists."}
	var duration := float(params.get("duration", 1.2))
	var min_energy := float(params.get("min_energy", 0.35))
	var max_energy := float(params.get("max_energy", 1.0))
	var steps := int(params.get("steps", 8))
	if duration <= 0 or duration > 60:
		return {"ok": false, "code": "invalid_arguments", "message": "duration must be greater than zero and at most 60 seconds."}
	if min_energy < 0 or max_energy > 100 or max_energy <= min_energy:
		return {"ok": false, "code": "invalid_energy", "message": "Energy values must satisfy 0 <= min_energy < max_energy <= 100."}
	if steps < 2 or steps > 64:
		return {"ok": false, "code": "invalid_arguments", "message": "steps must be between 2 and 64."}
	var property := "energy" if light is Light2D else "light_energy"
	var parent_path_result := str(root.get_path_to(parent)) if parent != root else "."
	var light_path_result := str(parent.get_path_to(light))
	return {"ok": true, "request": {"parent_path": parent_path_result, "light_path": str(root.get_path_to(light)), "track_path": light_path_result, "property": property, "player_name": name, "duration": duration, "min_energy": min_energy, "max_energy": max_energy, "steps": steps, "light_class": light.get_class()}}

func _build_torch(request: Dictionary) -> Dictionary:
	var animation := Animation.new()
	animation.length = request.duration
	animation.loop_mode = Animation.LOOP_LINEAR
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath(request.track_path + ":" + request.property))
	animation.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
	for index in int(request.steps):
		var time := float(request.duration) * float(index) / float(request.steps)
		var wave := sin(float(index) * 2.399963 + 0.7)
		var value := lerpf(float(request.min_energy), float(request.max_energy), 0.5 + 0.45 * wave)
		animation.track_insert_key(track, time, value)
	var library := AnimationLibrary.new()
	if library.add_animation("flicker", animation) != OK:
		return {"ok": false, "code": "invalid_animation", "message": "Could not add the flicker animation."}
	return {"ok": true, "action_name": "Add torch flicker animation", "summary": "Added %s with a native flicker animation for %s (%s energy, %.0f–%.0f, %.1fs). No script was generated." % [request.player_name, request.light_path, request.light_class, request.min_energy, request.max_energy, request.duration], "ops": [
		{"op": "create_node", "id": "player", "class": "AnimationPlayer", "name": request.player_name},
		{"op": "create_resource_value", "id": "animation", "resource": animation},
		{"op": "create_resource_value", "id": "library", "resource": library},
		{"op": "add_child", "parent": request.parent_path, "node": "player"},
		{"op": "set_owner", "node": "player", "owner": "."},
		{"op": "set_property", "target": "player", "property": "autoplay", "value": &"tiiny/flicker"},
		{"op": "call_method", "target": "player", "method": "add_animation_library", "args": ["tiiny", {"ref": "library"}], "undo_method": "remove_animation_library", "undo_args": ["tiiny"], "verify_method": "has_animation_library", "verify_args": ["tiiny"], "expect": true, "undo_expect": false},
	]}

func _validate_slippery(params: Dictionary, context: Dictionary) -> Dictionary:
	var target_path := str(params.get("target_path", "")).strip_edges()
	if target_path.is_empty() or target_path.length() > 512:
		return {"ok": false, "code": "invalid_arguments", "message": "target_path is required."}
	var found: Dictionary = inspector.resolve_scene_node(context.root, target_path)
	if found.has("error"):
		return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	var node: Node = found.node
	var body: Node = node
	if node is CollisionShape2D:
		body = node.get_parent()
	if not body is CollisionObject2D:
		return {"ok": false, "code": "invalid_target", "message": "Choose a 2D physics body (StaticBody2D, RigidBody2D, CharacterBody2D, Area2D) or its CollisionShape2D. No script fallback was created."}
	if body != context.root and body.get_owner() != context.root:
		return {"ok": false, "code": "read_only_instance", "message": "The physics body must be owned by the edited scene."}
	var friction := float(params.get("friction", 0.05))
	var bounce := float(params.get("bounce", 0.0))
	if friction < 0 or friction > 1 or bounce < 0 or bounce > 1:
		return {"ok": false, "code": "invalid_arguments", "message": "friction and bounce must be between 0 and 1."}
	var existing = body.get("physics_material_override")
	var previous := ""
	if existing is Resource:
		previous = existing.get_class() + (" at " + existing.resource_path if not existing.resource_path.is_empty() else "")
	return {"ok": true, "request": {"body_path": str(context.root.get_path_to(body)) if body != context.root else ".", "target_path": target_path, "friction": friction, "bounce": bounce, "rough": bool(params.get("rough", false)), "absorbent": bool(params.get("absorbent", false)), "previous": previous}}

func _build_slippery(request: Dictionary) -> Dictionary:
	var summary := "Assigned an owned PhysicsMaterial (friction %.2f, bounce %.2f) to %s." % [request.friction, request.bounce, request.body_path]
	if not str(request.previous).is_empty():
		summary += " The previous %s reference was replaced without modifying that resource; Undo restores it." % str(request.previous)
	return {"ok": true, "action_name": "Make %s slippery" % request.body_path, "summary": summary, "ops": [
		{"op": "create_resource", "id": "material", "class": "PhysicsMaterial", "properties": {"friction": request.friction, "bounce": request.bounce, "rough": request.rough, "absorbent": request.absorbent}},
		{"op": "set_property", "target": request.body_path, "property": "physics_material_override", "value": {"ref": "material"}},
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
