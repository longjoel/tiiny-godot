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
	var affected_paths := {}
	var affected_nodes: Array = []
	for path in created_nodes: affected_paths[path] = true
	for op in ops:
		if not op is Dictionary: continue
		var kind := str(op.get("op", ""))
		if kind == "remove_node":
			affected_paths[str(op.get("target", ""))] = true
		elif kind == "reparent_node":
			var target: Variant = op.get("__target")
			if target is Node and is_instance_valid(target): affected_paths[str(root.get_path_to(target))] = true
		elif kind == "duplicate_node":
			var copy: Variant = op.get("__copy")
			if copy is Node and is_instance_valid(copy): affected_paths[str(root.get_path_to(copy))] = true
		elif kind == "instantiate_scene":
			var instance: Variant = op.get("__instance")
			if instance is Node and is_instance_valid(instance): affected_paths[str(root.get_path_to(instance))] = true
		elif kind == "connect_signal":
			var source: Variant = op.get("__source_node")
			if source is Node and is_instance_valid(source): affected_paths[str(root.get_path_to(source))] = true
	for path in affected_paths: affected_nodes.append(path)
	var created_resources: Array = []
	for id in resources:
		var resource: Resource = resources[id]
		if is_instance_valid(resource): created_resources.append(resource.resource_path if not resource.resource_path.is_empty() else resource.get_class())
	var affected: Array = []
	for path in affected_nodes:
		affected.append({"kind": "node", "scene_path": context.scene_path, "path": path})
	for resource in created_resources:
		affected.append({"kind": "resource", "scene_path": context.scene_path, "resource": resource})
	var token := str(turn_context.get("undo_group", ""))
	if token.is_empty(): token = "tiiny:" + Crypto.new().generate_random_bytes(8).hex_encode()
	var data := {"recipe": recipe_name, "action_name": action_name, "scene": scene, "created": {"nodes": created_nodes, "resources": created_resources}, "dirty": true}
	var extra: Variant = built.get("data", {})
	if extra is Dictionary:
		for key in extra: data[key] = extra[key]
	var result := {"ok": true, "summary": str(built.get("summary", "Applied recipe " + recipe_name + ".")), "data": data, "affected": affected, "undo_group": token, "scene_revision": str(scene.get("revision", context.revision))}
	return result

func _prepare(ops: Array, root: Node, context: Dictionary) -> Dictionary:
	var nodes := {}
	var resources := {}
	var op_by_id := {}
	for op in ops:
		if op is Dictionary and str(op.get("op", "")) == "assign_resource":
			op["op"] = "set_property"
			op["value"] = {"ref": str(op.get("resource", ""))}
	for op in ops:
		if not op is Dictionary or not op.get("op") is String:
			return _error("invalid_operation", "Operation must be an object with an op.")
		var kind := str(op.op)
		var id := str(op.get("id", ""))
		if kind in ["create_node", "create_resource", "create_resource_value", "create_node_value"]:
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
				var node_properties: Variant = op.get("properties", {})
				if not (node_properties is Dictionary): return _error("invalid_operation", "Node properties must be an object.")
				for property in node_properties:
					var info := _property_info(node, str(property))
					if info.is_empty(): return _error("property_missing", "Node property does not exist: " + str(property))
					if _read_only(node, str(property), info): return _error("property_not_writable", "Node property is not writable: " + str(property))
					var coerced: Variant = _coerce_value(info, node_properties[property])
					if not _value_compatible(info, coerced): return _error("type_mismatch", "Node property type mismatch: " + str(property))
					node_properties[property] = coerced
					node.set(str(property), coerced)
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
					if int(info.get("usage", 0)) & PROPERTY_USAGE_INTERNAL: return _error("property_not_writable", "Resource property is internal: " + str(property))
					var coerced: Variant = _coerce_value(info, properties[property])
					if not _value_compatible(info, coerced): return _error("type_mismatch", "Resource property type mismatch: " + str(property))
					properties[property] = coerced
					resource.set(str(property), coerced)
				resources[str(op.id)] = resource
			"create_resource_value":
				var value: Variant = op.get("resource")
				if not value is Resource: return _error("invalid_operation", "Recipe resource value must be a Resource.")
				resources[str(op.id)] = value
			"create_node_value":
				var node_value: Variant = op.get("node")
				if not node_value is Node or node_value.get_parent() != null: return _error("invalid_operation", "Recipe node value must be an unparented Node.")
				nodes[str(op.id)] = node_value
			_: pass
	for op in ops:
		if not op is Dictionary: return _error("invalid_operation", "Operation must be an object.")
		var kind := str(op.get("op", ""))
		if kind == "instantiate_scene":
			var packed: Variant = ResourceLoader.load(str(op.get("path", "")), "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
			if not packed is PackedScene: return _error("artifact_invalid", "PackedScene could not be loaded: " + str(op.get("path", "")))
			var instance: Node = packed.instantiate()
			if instance == null: return _error("artifact_invalid", "PackedScene could not be instantiated.")
			instance.name = str(op.get("name", ""))
			var instance_parent := _target_node(str(op.get("parent", "")), root, nodes, op_by_id)
			if instance_parent == null: instance.free(); return _error("target_missing", "instantiate_scene parent is missing.")
			op["__instance"] = instance
			op["__parent_node"] = instance_parent
		elif kind == "duplicate_node":
			var target := _target_node(str(op.get("target", "")), root, nodes, op_by_id)
			if target == null: return _error("target_missing", "duplicate_node target is missing.")
			if target == root or (target.get_owner() != root): return _error("read_only_instance", "duplicate_node target must be owned by the edited scene.")
			var copy: Node = target.duplicate()
			if copy == null: return _error("invalid_operation", "Node could not be duplicated.")
			copy.name = str(op.get("new_name", ""))
			op["__copy"] = copy
			op["__target"] = target
			op["__parent_node"] = target.get_parent()
		elif kind == "remove_node":
			var target := _target_node(str(op.get("target", "")), root, nodes, op_by_id)
			if target == null: return _error("target_missing", "remove_node target is missing.")
			if target == root or target.get_parent() == null or target.get_owner() != root: return _error("read_only_instance", "remove_node target must be an owned non-root node.")
			op["__target"] = target
			op["__parent"] = target.get_parent()
			op["__index"] = target.get_index()
			op["__owner"] = target.get_owner()
		elif kind == "reparent_node":
			var target := _target_node(str(op.get("target", "")), root, nodes, op_by_id)
			var parent := _target_node(str(op.get("parent", "")), root, nodes, op_by_id)
			if target == null or parent == null: return _error("target_missing", "reparent_node target or parent is missing.")
			if target == root or target.get_owner() != root or (parent != root and parent.get_owner() != root): return _error("read_only_instance", "reparent_node target/parent must be owned by the edited scene.")
			op["__target"] = target
			op["__parent_node"] = parent
			op["__old_parent"] = target.get_parent()
			op["__old_index"] = target.get_index()
			op["__old_owner"] = target.get_owner()
	for op in ops:
		if op is Dictionary and str(op.get("op", "")) == "connect_signal":
			op["__source_node"] = _target_node(str(op.get("source", "")), root, nodes, op_by_id)
			op["__target_node"] = _target_node(str(op.get("target", "")), root, nodes, op_by_id)
	var error := _validate_references(ops, nodes, resources, op_by_id, root, context)
	if not error.is_empty():
		for id in nodes: nodes[id].free()
		for id in resources: resources[id] = null
		for op in ops:
			if op is Dictionary:
				if op.has("__instance") and op["__instance"] is Node: op["__instance"].free()
				if op.has("__copy") and op["__copy"] is Node: op["__copy"].free()
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
				if int(info.get("usage", 0)) & PROPERTY_USAGE_INTERNAL: return _error("property_not_writable", "Property is internal: " + property)
				if _read_only(target, property, info): return _error("property_not_writable", "Property is not writable: " + property)
				var value: Variant = _coerce_value(info, _operation_value(op.get("value"), nodes, resources, op_by_id))
				op["value"] = value
				if not _value_compatible(info, value): return _error("type_mismatch", "Property type mismatch: " + property)
			"instantiate_scene":
				var parent := _target_node(str(op.get("parent", "")), root, nodes, op_by_id)
				if parent == null: return _error("target_missing", "instantiate_scene parent is missing.")
				if parent != root and parent.get_owner() != root: return _error("read_only_instance", "instantiate_scene parent must be owned by the edited scene.")
				if not _valid_name(str(op.get("name", ""))): return _error("invalid_name", "Invalid instance name.")
				if parent.get_node_or_null(NodePath(str(op.get("name", "")))) != null: return _error("name_conflict", "A sibling already uses the instance name.")
				var instance: Variant = op.get("__instance")
				if not instance is Node: return _error("invalid_operation", "PackedScene instance is missing.")
			"duplicate_node":
				var target := _target_node(str(op.get("target", "")), root, nodes, op_by_id)
				if target == null: return _error("target_missing", "duplicate_node target is missing.")
				var parent := target.get_parent()
				if parent == null: return _error("invalid_operation", "duplicate_node target has no parent.")
				if parent.get_node_or_null(NodePath(str(op.get("new_name", "")))) != null: return _error("name_conflict", "A sibling already uses the duplicate name.")
				if not op.get("__copy") is Node: return _error("invalid_operation", "Node duplicate is missing.")
			"remove_node":
				var target := _target_node(str(op.get("target", "")), root, nodes, op_by_id)
				if target == null: return _error("target_missing", "remove_node target is missing.")
			"reparent_node":
				var target := _target_node(str(op.get("target", "")), root, nodes, op_by_id)
				var parent := _target_node(str(op.get("parent", "")), root, nodes, op_by_id)
				if target == null or parent == null: return _error("target_missing", "reparent_node target or parent is missing.")
				if target == parent or target.is_ancestor_of(parent): return _error("invalid_parent", "reparent_node cannot create a cycle.")
				if parent != target.get_parent() and parent.get_node_or_null(NodePath(str(target.name))) != null: return _error("name_conflict", "The new parent already has a child with that name.")
			"connect_signal":
				var source := _target_node(str(op.get("source", "")), root, nodes, op_by_id)
				var target := _target_node(str(op.get("target", "")), root, nodes, op_by_id)
				if source == null or target == null: return _error("target_missing", "connect_signal source or target is missing.")
				var signal_name := str(op.get("signal", ""))
				var method_name := str(op.get("method", ""))
				if not source.has_signal(signal_name): return _error("signal_missing", "Signal does not exist: " + signal_name)
				if not target.has_method(method_name): return _error("method_missing", "Target method does not exist: " + method_name)
				if source.is_connected(signal_name, Callable(target, method_name)): return _error("already_connected", "Signal is already connected.")
			"attach_script":
				var target := _target_node(str(op.get("target", "")), root, nodes, op_by_id)
				if target == null: return _error("target_missing", "attach_script target is missing.")
				if target != root and target.get_owner() != root and not nodes.values().has(target): return _error("read_only_instance", "attach_script target must be owned by the edited scene.")
				var script: Variant = ResourceLoader.load(str(op.get("path", "")), "", ResourceLoader.CACHE_MODE_REUSE)
				if not script is GDScript: return _error("artifact_invalid", "Script did not load as GDScript.")
				var base_type := str(script.get_instance_base_type())
				if base_type.is_empty() or not ClassDB.is_parent_class(target.get_class(), base_type):
					return _error("invalid_target", "The script base class %s is incompatible with %s (%s)." % [base_type if not base_type.is_empty() else "unknown", str(op.get("target", "")), target.get_class()])
				op["__target"] = target
				op["__script"] = script
				op["__old_script"] = target.get_script()
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
		"create_node_value":
			manager.add_do_reference(nodes[str(op.id)])
		"instantiate_scene":
			var instance: Node = op["__instance"]
			var parent: Node = op["__parent_node"]
			manager.add_do_reference(instance)
			manager.add_do_method(parent, "add_child", instance, true)
			manager.add_do_property(instance, "owner", root)
			manager.add_undo_method(parent, "remove_child", instance)
		"duplicate_node":
			var copy: Node = op["__copy"]
			var parent: Node = op["__parent_node"]
			manager.add_do_reference(copy)
			manager.add_do_method(parent, "add_child", copy, true)
			manager.add_do_property(copy, "owner", root)
			for child in copy.get_children(true):
				manager.add_do_method(child, "set_owner", copy)
			manager.add_undo_method(parent, "remove_child", copy)
		"remove_node":
			var target: Node = op["__target"]
			var parent: Node = op["__parent"]
			var old_owner: Node = op["__owner"]
			manager.add_do_method(parent, "remove_child", target)
			manager.add_undo_method(parent, "add_child", target, true)
			manager.add_undo_method(parent, "move_child", target, int(op["__index"]))
			manager.add_undo_method(target, "set_owner", old_owner)
		"reparent_node":
			var target: Node = op["__target"]
			var parent: Node = op["__parent_node"]
			var old_parent: Node = op["__old_parent"]
			var old_owner: Node = op["__old_owner"]
			manager.add_do_method(target, "reparent", parent)
			manager.add_undo_method(target, "reparent", old_parent)
			manager.add_undo_method(old_parent, "move_child", target, int(op["__old_index"]))
			manager.add_undo_method(target, "set_owner", old_owner)
		"connect_signal":
			var source: Node = op["__source_node"]
			var target: Node = op["__target_node"]
			var callback := Callable(target, str(op.method))
			manager.add_do_method(source, "connect", str(op.signal), callback)
			manager.add_undo_method(source, "disconnect", str(op.signal), callback)
		"attach_script":
			var target: Node = op["__target"]
			var script: Script = op["__script"]
			manager.add_do_reference(script)
			manager.add_do_property(target, "script", script)
			manager.add_undo_property(target, "script", op["__old_script"])
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
		elif str(op.op) == "instantiate_scene":
			var instance: Variant = op.get("__instance")
			if not instance is Node or not instance.is_inside_tree(): return "Instantiated scene is not in the scene."
			if str(instance.name) != str(op.get("name", "")): return "Instantiated scene name changed."
		elif str(op.op) == "duplicate_node":
			var copy: Variant = op.get("__copy")
			if not copy is Node or not copy.is_inside_tree(): return "Duplicated node is not in the scene."
			if str(copy.name) != str(op.get("new_name", "")): return "Duplicated node name changed."
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
		elif str(op.op) == "remove_node":
			var target: Node = op["__target"]
			if target.is_inside_tree(): return "Removed node is still in the scene."
		elif str(op.op) == "reparent_node":
			var target: Node = op["__target"]
			var parent: Node = op["__parent_node"]
			if target.get_parent() != parent: return "Reparented node has the wrong parent."
		elif str(op.op) == "connect_signal":
			var source: Node = op["__source_node"]
			var target: Node = op["__target_node"]
			if not source.is_connected(str(op.signal), Callable(target, str(op.method))): return "Signal was not connected."
		elif str(op.op) == "attach_script":
			var target: Node = op["__target"]
			if target.get_script() != op["__script"]: return "Script was not attached."
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
		elif str(op.op) == "create_node_value":
			var node: Node = nodes[str(op.id)]
			if is_instance_valid(node) and node.is_inside_tree(): return false
		elif str(op.op) == "call_method" and op.has("verify_method"):
			var target = _target_object(str(op.target), root, nodes, resources, op_by_id)
			var args := _operation_args(op.get("verify_args", []), nodes, resources, op_by_id)
			var actual: Variant = target.callv(str(op.verify_method), args)
			if actual != op.get("undo_expect", not op.get("expect", true)): return false
		elif str(op.op) == "instantiate_scene":
			var instance: Variant = op.get("__instance")
			if instance is Node and instance.is_inside_tree(): return false
		elif str(op.op) == "duplicate_node":
			var copy: Variant = op.get("__copy")
			if copy is Node and copy.is_inside_tree(): return false
		elif str(op.op) == "remove_node":
			var target: Node = op["__target"]
			if not target.is_inside_tree(): return false
		elif str(op.op) == "reparent_node":
			var target: Node = op["__target"]
			if target.get_parent() != op.get("__old_parent"): return false
		elif str(op.op) == "connect_signal":
			var source: Node = op["__source_node"]
			var target: Node = op["__target_node"]
			if source.is_connected(str(op.signal), Callable(target, str(op.method))): return false
		elif str(op.op) == "attach_script":
			var target: Node = op["__target"]
			if target.get_script() != op["__old_script"]: return false
	return true

### Property helpers

func _property_info(object: Object, name: String) -> Dictionary:
	for info in object.get_property_list():
		if str(info.get("name", "")) == name:
			return info
	return {}

func _read_only(_object: Object, _name: String, info: Dictionary) -> bool:
	return bool(int(info.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY)

func _coerce_value(info: Dictionary, value: Variant) -> Variant:
	var type := int(info.get("type", TYPE_NIL))
	if type == TYPE_STRING_NAME and value is String: return StringName(value)
	if type == TYPE_NODE_PATH and value is String: return NodePath(value)
	if type in [TYPE_VECTOR2, TYPE_VECTOR2I] and value is Dictionary and value.has("x") and value.has("y"):
		return Vector2(float(value.x), float(value.y)) if type == TYPE_VECTOR2 else Vector2i(int(value.x), int(value.y))
	if type in [TYPE_VECTOR3, TYPE_VECTOR3I] and value is Dictionary and value.has("x") and value.has("y") and value.has("z"):
		return Vector3(float(value.x), float(value.y), float(value.z)) if type == TYPE_VECTOR3 else Vector3i(int(value.x), int(value.y), int(value.z))
	if type == TYPE_VECTOR2 and value is Array and value.size() == 2:
		return Vector2(float(value[0]), float(value[1]))
	if type == TYPE_VECTOR3 and value is Array and value.size() == 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	if type == TYPE_COLOR:
		if value is String: return Color.from_string(value, Color.WHITE)
		if value is Array and value.size() in [3, 4]:
			return Color(float(value[0]), float(value[1]), float(value[2]), float(value[3]) if value.size() == 4 else 1.0)
		if value is Dictionary and value.has("r") and value.has("g") and value.has("b"):
			return Color(float(value.r), float(value.g), float(value.b), float(value.get("a", 1.0)))
	if type == TYPE_RECT2 and value is Dictionary and value.has("x") and value.has("y") and value.has("w") and value.has("h"):
		return Rect2(float(value.x), float(value.y), float(value.w), float(value.h))
	if type == TYPE_RECT2 and value is Array and value.size() == 4:
		return Rect2(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	if type == TYPE_PACKED_VECTOR2_ARRAY and value is Array:
		var points := PackedVector2Array()
		for item in value:
			if item is Dictionary and item.has("x") and item.has("y"):
				points.append(Vector2(float(item.x), float(item.y)))
			elif item is Array and item.size() == 2:
				points.append(Vector2(float(item[0]), float(item[1])))
			else:
				return value
		return points
	if type == TYPE_PACKED_VECTOR3_ARRAY and value is Array:
		var points3 := PackedVector3Array()
		for item in value:
			if item is Dictionary and item.has("x") and item.has("y") and item.has("z"):
				points3.append(Vector3(float(item.x), float(item.y), float(item.z)))
			elif item is Array and item.size() == 3:
				points3.append(Vector3(float(item[0]), float(item[1]), float(item[2])))
			else:
				return value
		return points3
	if type == TYPE_PACKED_FLOAT32_ARRAY and value is Array:
		var floats := PackedFloat32Array()
		for item in value:
			if not (item is int or item is float): return value
			floats.append(float(item))
		return floats
	if type == TYPE_PACKED_FLOAT64_ARRAY and value is Array:
		var doubles := PackedFloat64Array()
		for item in value:
			if not (item is int or item is float): return value
			doubles.append(float(item))
		return doubles
	if type == TYPE_PACKED_INT32_ARRAY and value is Array:
		var ints := PackedInt32Array()
		for item in value:
			if not (item is int or item is float): return value
			ints.append(int(item))
		return ints
	if type == TYPE_PACKED_INT64_ARRAY and value is Array:
		var longs := PackedInt64Array()
		for item in value:
			if not (item is int or item is float): return value
			longs.append(int(item))
		return longs
	if type == TYPE_PACKED_STRING_ARRAY and value is Array:
		var strings := PackedStringArray()
		for item in value:
			if not item is String: return value
			strings.append(str(item))
		return strings
	return value

func _value_compatible(info: Dictionary, value: Variant) -> bool:
	var type := int(info.get("type", TYPE_NIL))
	if type == TYPE_STRING_NAME and value is String: return true
	if type == TYPE_NODE_PATH and value is String: return true
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
	register_recipe({
		"name": "import_generated_model",
		"title": "Import generated 3D model",
		"description": "Validate a generated GLB/GLTF artifact and instance its meshes and materials into the scene.",
		"parameters": {"type": "object", "properties": {
			"path": {"type": "string", "minLength": 1, "maxLength": 512},
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
		}, "required": ["path"], "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 30000,
		"validate": Callable(self, "_validate_import_model"),
		"build": Callable(self, "_build_import_model"),
	})
	register_recipe({
		"name": "import_generated_audio",
		"title": "Import generated audio",
		"description": "Validate a generated WAV/OGG artifact and add it to an AudioStreamPlayer.",
		"parameters": {"type": "object", "properties": {
			"path": {"type": "string", "minLength": 1, "maxLength": 512},
			"parent_path": {"type": "string", "maxLength": 512},
			"player_name": {"type": "string", "minLength": 1, "maxLength": 128},
		}, "required": ["path"], "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 30000,
		"validate": Callable(self, "_validate_import_audio"),
		"build": Callable(self, "_build_import_audio"),
	})
	register_recipe({
		"name": "add_sprite_from_image",
		"title": "Add Sprite2D from image",
		"description": "Create a Sprite2D using an imported texture, such as a generated image.",
		"parameters": {"type": "object", "properties": {
			"path": {"type": "string", "minLength": 1, "maxLength": 512},
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"scale_x": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
			"scale_y": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
		}, "required": ["path"], "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 15000,
		"validate": Callable(self, "_validate_sprite"),
		"build": Callable(self, "_build_sprite"),
	})
	register_recipe({
		"name": "add_particles_2d",
		"title": "Add 2D particle effect",
		"description": "Create a GPUParticles2D with a configured ParticleProcessMaterial. One undo action.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"amount": {"type": "integer", "minimum": 1, "maximum": 4096},
			"lifetime": {"type": "number", "exclusiveMinimum": 0, "maximum": 60},
			"gravity": {"type": "number", "minimum": -10000, "maximum": 10000},
			"initial_velocity": {"type": "number", "minimum": 0, "maximum": 10000},
			"spread": {"type": "number", "minimum": 0, "maximum": 360},
			"scale": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
			"color": {"type": "string", "maxLength": 32},
		}, "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 15000,
		"validate": Callable(self, "_validate_particles"),
		"build": Callable(self, "_build_particles_2d"),
	})
	register_recipe({
		"name": "add_particles_3d",
		"title": "Add 3D particle effect",
		"description": "Create a GPUParticles3D with a configured ParticleProcessMaterial. One undo action.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"amount": {"type": "integer", "minimum": 1, "maximum": 4096},
			"lifetime": {"type": "number", "exclusiveMinimum": 0, "maximum": 60},
			"gravity": {"type": "number", "minimum": -1000, "maximum": 1000},
			"initial_velocity": {"type": "number", "minimum": 0, "maximum": 1000},
			"spread": {"type": "number", "minimum": 0, "maximum": 360},
			"scale": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
			"color": {"type": "string", "maxLength": 32},
		}, "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 15000,
		"validate": Callable(self, "_validate_particles"),
		"build": Callable(self, "_build_particles_3d"),
	})
	register_recipe({
		"name": "add_mesh_collision",
		"title": "Add collision to imported mesh",
		"description": "Create a StaticBody3D with a trimesh CollisionShape3D matching an existing MeshInstance3D. One undo action.",
		"parameters": {"type": "object", "properties": {
			"target_path": {"type": "string", "minLength": 1, "maxLength": 512},
			"body_name": {"type": "string", "minLength": 1, "maxLength": 128},
		}, "required": ["target_path"], "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 30000,
		"validate": Callable(self, "_validate_mesh_collision"),
		"build": Callable(self, "_build_mesh_collision"),
	})
	register_recipe({
		"name": "add_tilemap_layer",
		"title": "Add TileMapLayer",
		"description": "Create a TileMapLayer with a TileSet and optional atlas source from an image. One undo action.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"texture_path": {"type": "string", "maxLength": 512},
			"tile_width": {"type": "integer", "minimum": 1, "maximum": 4096},
			"tile_height": {"type": "integer", "minimum": 1, "maximum": 4096},
			"paint_origin": {"type": "boolean"},
		}, "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 15000,
		"validate": Callable(self, "_validate_tilemap"), "build": Callable(self, "_build_tilemap"),
	})
	register_recipe({
		"name": "add_gridmap",
		"title": "Add GridMap",
		"description": "Create a GridMap with a one-cell MeshLibrary. One undo action.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"cell_size": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
			"paint_origin": {"type": "boolean"},
		}, "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 15000,
		"validate": Callable(self, "_validate_gridmap"), "build": Callable(self, "_build_gridmap"),
	})
	register_recipe({
		"name": "add_animated_sprite",
		"title": "Add AnimatedSprite2D",
		"description": "Create an AnimatedSprite2D with a SpriteFrames animation from image paths. One undo action.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"texture_paths": {"type": "array", "maxItems": 32, "items": {"type": "string", "maxLength": 512}},
			"animation_name": {"type": "string", "maxLength": 128},
			"fps": {"type": "number", "exclusiveMinimum": 0, "maximum": 120},
		}, "required": ["texture_paths"], "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 30000,
		"validate": Callable(self, "_validate_animated_sprite"), "build": Callable(self, "_build_animated_sprite"),
	})
	register_recipe({
		"name": "apply_theme",
		"title": "Apply theme and font size",
		"description": "Create and assign a Theme with a default font size and optional font. One undo action.",
		"parameters": {"type": "object", "properties": {
			"target_path": {"type": "string", "minLength": 1, "maxLength": 512},
			"font_size": {"type": "integer", "minimum": 1, "maximum": 256},
			"font_path": {"type": "string", "maxLength": 512},
		}, "required": ["target_path"], "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 15000,
		"validate": Callable(self, "_validate_theme"), "build": Callable(self, "_build_theme"),
	})
	register_recipe({
		"name": "configure_audio_loop",
		"title": "Configure audio loop",
		"description": "Duplicate an AudioStreamPlayer stream and enable or disable looping. One undo action.",
		"parameters": {"type": "object", "properties": {
			"target_path": {"type": "string", "minLength": 1, "maxLength": 512},
			"enabled": {"type": "boolean"},
		}, "required": ["target_path"], "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 15000,
		"validate": Callable(self, "_validate_audio_loop"), "build": Callable(self, "_build_audio_loop"),
	})
	register_recipe({
		"name": "add_navigation_region",
		"title": "Add NavigationRegion3D",
		"description": "Create a NavigationRegion3D with a configured NavigationMesh. Baking is not performed. One undo action.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"agent_radius": {"type": "number", "minimum": 0, "maximum": 1000},
			"cell_size": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
		}, "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 15000,
		"validate": Callable(self, "_validate_navigation"), "build": Callable(self, "_build_navigation"),
	})
	register_recipe({
		"name": "add_animation_tree",
		"title": "Add AnimationTree state",
		"description": "Create an AnimationTree with a one-state AnimationNodeStateMachine bound to an existing AnimationPlayer. One undo action.",
		"parameters": {"type": "object", "properties": {
			"animation_player_path": {"type": "string", "minLength": 1, "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"state_name": {"type": "string", "maxLength": 128},
		}, "required": ["animation_player_path"], "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 15000,
		"validate": Callable(self, "_validate_animation_tree"), "build": Callable(self, "_build_animation_tree"),
	})
	register_recipe({
		"name": "add_weather_3d",
		"title": "Add 3D weather particles",
		"description": "Create a GPUParticles3D rain/snow field with an emission box. One undo action.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"amount": {"type": "integer", "minimum": 1, "maximum": 4096},
			"extent": {"type": "number", "exclusiveMinimum": 0, "maximum": 10000},
			"speed": {"type": "number", "minimum": 0, "maximum": 10000},
			"color": {"type": "string", "maxLength": 32},
		}, "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 15000,
		"validate": Callable(self, "_validate_weather"), "build": Callable(self, "_build_weather"),
	})
	register_recipe({
		"name": "add_trail_3d",
		"title": "Add 3D trail",
		"description": "Create a native Trail3D ribbon under a 3D parent. One undo action.",
		"parameters": {"type": "object", "properties": {
			"parent_path": {"type": "string", "maxLength": 512},
			"node_name": {"type": "string", "minLength": 1, "maxLength": 128},
			"width": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
			"lifetime": {"type": "number", "exclusiveMinimum": 0, "maximum": 60},
			"color": {"type": "string", "maxLength": 32},
		}, "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 15000,
		"validate": Callable(self, "_validate_trail"), "build": Callable(self, "_build_trail"),
	})
	register_recipe({
		"name": "play_animation",
		"title": "Play existing animation",
		"description": "Set the current/autoplay animation on an existing AnimationPlayer, including imported skeleton clips. One undo action.",
		"parameters": {"type": "object", "properties": {
			"target_path": {"type": "string", "minLength": 1, "maxLength": 512},
			"animation": {"type": "string", "maxLength": 128},
			"autoplay": {"type": "boolean"},
		}, "required": ["target_path"], "additionalProperties": false},
		"risk": "mutating", "timeout_ms": 15000,
		"validate": Callable(self, "_validate_play_animation"), "build": Callable(self, "_build_play_animation"),
	})
	register_recipe({
		"name": "apply_editor_transaction",
		"title": "Apply typed editor transaction",
		"description": "Compose bounded typed scene edits: create/set nodes and resources, structure, instantiate, and connect signals. One undo action; no scripts, files, methods, or editor internals.",
		"parameters": {"type": "object", "properties": {
			"expected_scene_revision": {"type": "string", "maxLength": 256},
			"expected_session_revision": {"type": "string", "maxLength": 128},
			"operations": {"type": "array", "maxItems": 16, "items": {"type": "object", "properties": {
				"op": {"type": "string", "enum": ["create_node", "set_property", "create_resource", "assign_resource", "add_child", "set_owner", "remove_node", "reparent_node", "duplicate_node", "instantiate_scene", "connect_signal", "attach_script"]},
				"id": {"type": "string", "maxLength": 64},
				"class": {"type": "string", "maxLength": 128},
				"parent": {"type": "string", "maxLength": 512},
				"name": {"type": "string", "maxLength": 128},
				"target": {"type": "string", "maxLength": 512},
				"property": {"type": "string", "maxLength": 128},
				"value": {},
				"resource": {"type": "string", "maxLength": 64},
				"properties": {"type": "object"},
				"path": {"type": "string", "maxLength": 512},
				"source": {"type": "string", "maxLength": 512},
				"signal": {"type": "string", "maxLength": 128},
				"method": {"type": "string", "maxLength": 128},
				"new_name": {"type": "string", "maxLength": 128},
			}, "additionalProperties": false}},
		}, "required": ["operations"], "additionalProperties": false},
		"risk": "mutating",
		"timeout_ms": 30000,
		"validate": Callable(self, "_validate_generic"),
		"build": Callable(self, "_build_generic"),
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

func _validate_import_model(params: Dictionary, context: Dictionary) -> Dictionary:
	var path := str(params.get("path", "")).strip_edges()
	if not path.begins_with("res://") or ".." in path.split("/") or not (path.ends_with(".glb") or path.ends_with(".gltf")):
		return {"ok": false, "code": "invalid_arguments", "message": "A res:// .glb or .gltf artifact path is required."}
	if not FileAccess.file_exists(path):
		return {"ok": false, "code": "artifact_missing", "message": "Generated model artifact is missing: " + path}
	var packed: Variant = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
	if not packed is PackedScene:
		return {"ok": false, "code": "artifact_invalid", "message": "Generated model did not load as a PackedScene: " + path}
	var instance: Node = packed.instantiate()
	if instance == null:
		return {"ok": false, "code": "artifact_invalid", "message": "Generated model could not be instantiated."}
	var mesh_nodes: Array = instance.find_children("*", "MeshInstance3D", true, false)
	if mesh_nodes.is_empty():
		instance.free()
		return {"ok": false, "code": "artifact_invalid", "message": "Generated model contains no MeshInstance3D nodes."}
	var meshes: Array[String] = []
	var materials: Array[String] = []
	for mesh_node in mesh_nodes:
		meshes.append(str(mesh_node.name))
		var mesh: Mesh = mesh_node.mesh
		if mesh == null: continue
		for surface in mesh.get_surface_count():
			var material = mesh_node.get_active_material(surface)
			materials.append(material.get_class() if material != null else "none")
	var parent_path := str(params.get("parent_path", ".")).strip_edges()
	if parent_path.is_empty(): parent_path = "."
	var found: Dictionary = inspector.resolve_scene_node(context.root, parent_path)
	if found.has("error"):
		instance.free()
		return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	var parent: Node = found.node
	if parent != context.root and parent.get_owner() != context.root:
		instance.free()
		return {"ok": false, "code": "read_only_instance", "message": "The model parent must be owned by the edited scene."}
	var node_name := str(params.get("node_name", "")).strip_edges()
	if node_name.is_empty(): node_name = _unique_name(parent, "GeneratedModel" if str(instance.name).is_empty() else str(instance.name))
	elif not _valid_name(node_name):
		instance.free()
		return {"ok": false, "code": "invalid_name", "message": "Invalid model node name."}
	if parent.get_node_or_null(NodePath(node_name)) != null:
		instance.free()
		return {"ok": false, "code": "name_conflict", "message": "A node named " + node_name + " already exists."}
	instance.name = node_name
	return {"ok": true, "request": {"path": path, "parent_path": parent_path, "node_name": node_name, "instance": instance, "meshes": meshes, "materials": materials}}

func _build_import_model(request: Dictionary) -> Dictionary:
	return {"ok": true, "action_name": "Import generated model " + request.node_name, "summary": "Imported %s under %s with %d mesh(es) and %d material surface(s). Topology and PBR maps are unverified." % [request.path, request.parent_path, Array(request.meshes).size(), Array(request.materials).size()], "data": {"artifact": request.path, "meshes": request.meshes, "materials": request.materials, "validation": {"topology": "unverified", "pbr_maps": "unverified"}}, "ops": [
		{"op": "create_node_value", "id": "model", "node": request.instance},
		{"op": "add_child", "parent": request.parent_path, "node": "model"},
		{"op": "set_owner", "node": "model", "owner": "."},
	]}

func _validate_import_audio(params: Dictionary, context: Dictionary) -> Dictionary:
	var path := str(params.get("path", "")).strip_edges()
	if not path.begins_with("res://") or ".." in path.split("/") or not (path.ends_with(".wav") or path.ends_with(".ogg")):
		return {"ok": false, "code": "invalid_arguments", "message": "A res:// .wav or .ogg artifact path is required."}
	if not FileAccess.file_exists(path):
		return {"ok": false, "code": "artifact_missing", "message": "Generated audio artifact is missing: " + path}
	var stream: Variant = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
	if not stream is AudioStream:
		return {"ok": false, "code": "artifact_invalid", "message": "Generated audio did not load as an AudioStream: " + path}
	var parent_path := str(params.get("parent_path", ".")).strip_edges()
	if parent_path.is_empty(): parent_path = "."
	var found: Dictionary = inspector.resolve_scene_node(context.root, parent_path)
	if found.has("error"):
		return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	var parent: Node = found.node
	if parent != context.root and parent.get_owner() != context.root:
		return {"ok": false, "code": "read_only_instance", "message": "The audio parent must be owned by the edited scene."}
	var player_name := str(params.get("player_name", "")).strip_edges()
	if player_name.is_empty(): player_name = _unique_name(parent, "AudioStreamPlayer")
	elif not _valid_name(player_name):
		return {"ok": false, "code": "invalid_name", "message": "Invalid audio player name."}
	if parent.get_node_or_null(NodePath(player_name)) != null:
		return {"ok": false, "code": "name_conflict", "message": "A node named " + player_name + " already exists."}
	var channels := -1
	if stream is AudioStreamWAV:
		channels = 2 if stream.is_stereo() else 1
	return {"ok": true, "request": {"path": path, "parent_path": parent_path, "player_name": player_name, "stream": stream, "duration": stream.get_length(), "channels": channels}}

func _build_import_audio(request: Dictionary) -> Dictionary:
	return {"ok": true, "action_name": "Import generated audio " + request.player_name, "summary": "Imported %s into %s (%.2fs). Looping and seamlessness are unverified." % [request.path, request.player_name, request.duration], "data": {"artifact": request.path, "duration": request.duration, "channels": request.channels, "validation": {"loop": "unverified"}}, "ops": [
		{"op": "create_node", "id": "player", "class": "AudioStreamPlayer", "name": request.player_name},
		{"op": "create_resource_value", "id": "stream", "resource": request.stream},
		{"op": "add_child", "parent": request.parent_path, "node": "player"},
		{"op": "set_owner", "node": "player", "owner": "."},
		{"op": "set_property", "target": "player", "property": "stream", "value": {"ref": "stream"}},
	]}

func _validate_sprite(params: Dictionary, context: Dictionary) -> Dictionary:
	var path := str(params.get("path", "")).strip_edges()
	var lowered := path.to_lower()
	if not path.begins_with("res://") or ".." in path.split("/") or not (lowered.ends_with(".png") or lowered.ends_with(".jpg") or lowered.ends_with(".jpeg") or lowered.ends_with(".webp") or lowered.ends_with(".svg")):
		return {"ok": false, "code": "invalid_arguments", "message": "A res:// image path is required."}
	if not FileAccess.file_exists(path):
		return {"ok": false, "code": "artifact_missing", "message": "Sprite image is missing: " + path}
	var texture: Variant = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
	if not texture is Texture2D:
		return {"ok": false, "code": "artifact_invalid", "message": "Sprite image did not import as a Texture2D: " + path}
	var parent_path := str(params.get("parent_path", ".")).strip_edges()
	if parent_path.is_empty(): parent_path = "."
	var found: Dictionary = inspector.resolve_scene_node(context.root, parent_path)
	if found.has("error"):
		return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	var parent: Node = found.node
	if parent != context.root and parent.get_owner() != context.root:
		return {"ok": false, "code": "read_only_instance", "message": "The sprite parent must be owned by the edited scene."}
	var node_name := str(params.get("node_name", "")).strip_edges()
	if node_name.is_empty(): node_name = _unique_name(parent, "GeneratedSprite")
	elif not _valid_name(node_name):
		return {"ok": false, "code": "invalid_name", "message": "Invalid sprite node name."}
	if parent.get_node_or_null(NodePath(node_name)) != null:
		return {"ok": false, "code": "name_conflict", "message": "A node named " + node_name + " already exists."}
	var scale_x := float(params.get("scale_x", 1.0))
	var scale_y := float(params.get("scale_y", 1.0))
	if scale_x <= 0 or scale_y <= 0 or scale_x > 1000 or scale_y > 1000:
		return {"ok": false, "code": "invalid_arguments", "message": "Sprite scale must be positive and bounded."}
	return {"ok": true, "request": {"path": path, "parent_path": parent_path, "node_name": node_name, "texture": texture, "size": texture.get_size(), "scale": Vector2(scale_x, scale_y)}}

func _build_sprite(request: Dictionary) -> Dictionary:
	var ops: Array = [
		{"op": "create_resource_value", "id": "texture", "resource": request.texture},
		{"op": "create_node", "id": "sprite", "class": "Sprite2D", "name": request.node_name},
		{"op": "add_child", "parent": request.parent_path, "node": "sprite"},
		{"op": "set_owner", "node": "sprite", "owner": "."},
		{"op": "set_property", "target": "sprite", "property": "texture", "value": {"ref": "texture"}},
	]
	if request.scale != Vector2.ONE:
		ops.append({"op": "set_property", "target": "sprite", "property": "scale", "value": request.scale})
	return {"ok": true, "action_name": "Add Sprite2D " + request.node_name, "summary": "Added Sprite2D %s under %s using %s (%s)." % [request.node_name, request.parent_path, request.path, str(request.size)], "data": {"artifact": request.path, "size": [request.size.x, request.size.y], "scale": [request.scale.x, request.scale.y]}, "ops": ops}

func _validate_generic(params: Dictionary, context: Dictionary) -> Dictionary:
	var ops: Variant = params.get("operations")
	if not ops is Array or ops.is_empty() or ops.size() > 16:
		return {"ok": false, "code": "invalid_arguments", "message": "operations must contain between 1 and 16 typed operations."}
	var expected_scene := str(params.get("expected_scene_revision", ""))
	if not expected_scene.is_empty() and expected_scene != str(context.get("revision", "")):
		return {"ok": false, "code": "stale_scene", "message": "The edited scene revision changed; inspect it again."}
	var expected_session := str(params.get("expected_session_revision", ""))
	if not expected_session.is_empty() and expected_session != str(context.get("session_revision", "")):
		return {"ok": false, "code": "stale_scene", "message": "The scene edit history changed; inspect it again."}
	for index in ops.size():
		var op: Variant = ops[index]
		if op is Dictionary and str(op.get("op", "")) in ["create_node", "create_resource"] and str(op.get("id", "")).is_empty():
			var auto_name := str(op.get("name", ""))
			op["id"] = auto_name if not auto_name.is_empty() else "auto_" + str(index)
		if op is Dictionary and str(op.get("op", "")) in ["set_property", "assign_resource"] and not op.has("target") and op.get("path") is String:
			op["target"] = op.path
	var ids := {}
	for op in ops:
		if not op is Dictionary or not op.get("op") is String:
			return {"ok": false, "code": "invalid_operation", "message": "Each operation must be an object with an op."}
		var kind := str(op.op)
		var id := str(op.get("id", ""))
		if kind in ["create_node", "create_resource"]:
			if id.is_empty() or ids.has(id) or id.length() > 64:
				return {"ok": false, "code": "invalid_operation", "message": "Created node/resource IDs must be unique and non-empty."}
			ids[id] = true
	for index in ops.size():
		var op: Dictionary = ops[index]
		var kind := str(op.op)
		match kind:
			"create_node":
				if not _generic_class_ok(str(op.get("class", "")), "Node"):
					return {"ok": false, "code": "invalid_class", "message": "Node class is not allowed or not instantiable: " + str(op.get("class", ""))}
				if not _valid_name(str(op.get("name", ""))):
					return {"ok": false, "code": "invalid_name", "message": "Each created node needs a valid unique name."}
				if not op.get("parent") is String or str(op.parent).is_empty(): return {"ok": false, "code": "invalid_arguments", "message": "create_node parent is required."}
				if op.has("properties") and not op.properties is Dictionary: return {"ok": false, "code": "invalid_arguments", "message": "create_node properties must be an object."}
				if op.has("properties") and not _generic_refs_ok(op.properties, ids): return {"ok": false, "code": "invalid_reference", "message": "Initial properties may only reference resources/nodes created earlier in this transaction."}
			"create_resource":
				if not _generic_class_ok(str(op.get("class", "")), "Resource"):
					return {"ok": false, "code": "invalid_class", "message": "Resource class is not allowed or not instantiable: " + str(op.get("class", ""))}
				if op.has("properties") and not op.properties is Dictionary: return {"ok": false, "code": "invalid_arguments", "message": "create_resource properties must be an object."}
				if op.has("properties") and not _generic_refs_ok(op.properties, ids): return {"ok": false, "code": "invalid_reference", "message": "Initial properties may only reference resources/nodes created earlier in this transaction."}
			"set_property":
				if not op.get("target") is String or not op.get("property") is String or str(op.property).is_empty(): return {"ok": false, "code": "invalid_arguments", "message": "set_property needs target and property."}
				if not op.has("value"): return {"ok": false, "code": "invalid_arguments", "message": "set_property needs a value."}
				if not _generic_refs_ok(op.value, ids): return {"ok": false, "code": "invalid_reference", "message": "Property values may only reference resources/nodes created earlier in this transaction."}
			"assign_resource":
				if not op.get("target") is String or not op.get("property") is String or not op.get("resource") is String: return {"ok": false, "code": "invalid_arguments", "message": "assign_resource needs target, property, and resource."}
				if not ids.has(str(op.resource)): return {"ok": false, "code": "invalid_reference", "message": "assign_resource must reference a resource created in this transaction."}
			"add_child":
				if not op.get("parent") is String or not op.get("node") is String: return {"ok": false, "code": "invalid_arguments", "message": "add_child needs parent and node."}
			"set_owner":
				if not op.get("node") is String or not op.get("owner") is String: return {"ok": false, "code": "invalid_arguments", "message": "set_owner needs node and owner."}
			"remove_node":
				if not op.get("target") is String or str(op.target) == ".": return {"ok": false, "code": "invalid_arguments", "message": "remove_node needs a non-root target."}
			"reparent_node":
				if not op.get("target") is String or not op.get("parent") is String: return {"ok": false, "code": "invalid_arguments", "message": "reparent_node needs target and parent."}
			"duplicate_node":
				if not op.get("target") is String or not _valid_name(str(op.get("new_name", ""))): return {"ok": false, "code": "invalid_arguments", "message": "duplicate_node needs a target and valid new_name."}
			"instantiate_scene":
				var path := str(op.get("path", ""))
				if not path.begins_with("res://") or ".." in path.split("/") or not (path.ends_with(".tscn") or path.ends_with(".scn")) or not FileAccess.file_exists(path):
					return {"ok": false, "code": "invalid_arguments", "message": "instantiate_scene needs an existing res:// PackedScene path."}
				if not op.get("parent") is String or not _valid_name(str(op.get("name", ""))): return {"ok": false, "code": "invalid_arguments", "message": "instantiate_scene needs parent and a valid name."}
			"connect_signal":
				if not op.get("source") is String or not op.get("signal") is String or not op.get("target") is String or not op.get("method") is String:
					return {"ok": false, "code": "invalid_arguments", "message": "connect_signal needs source, signal, target, and method."}
				if str(op.signal).is_empty() or str(op.method).is_empty(): return {"ok": false, "code": "invalid_arguments", "message": "Signal and method names cannot be empty."}
			"attach_script":
				var script_path := str(op.get("path", ""))
				if not op.get("target") is String or not script_path.begins_with("res://") or ".." in script_path.split("/") or not script_path.ends_with(".gd") or not FileAccess.file_exists(script_path):
					return {"ok": false, "code": "invalid_arguments", "message": "attach_script needs an owned target and an existing res:// .gd path."}
				if not ResourceLoader.load(script_path, "", ResourceLoader.CACHE_MODE_REUSE) is GDScript:
					return {"ok": false, "code": "artifact_invalid", "message": "Script did not load as GDScript: " + script_path}
			_:
				return {"ok": false, "code": "invalid_operation", "message": "Unsupported editor operation: " + kind}
	return {"ok": true, "request": {"ops": ops.duplicate(true)}}

func _build_generic(request: Dictionary) -> Dictionary:
	var count := Array(request.ops).size()
	var expanded: Array = []
	for op in request.ops:
		expanded.append(op)
		if op is Dictionary and str(op.get("op", "")) == "create_node":
			expanded.append({"op": "add_child", "parent": str(op.get("parent", "")), "node": str(op.get("id", ""))})
			expanded.append({"op": "set_owner", "node": str(op.get("id", "")), "owner": "."})
	return {"ok": true, "action_name": "Apply editor transaction", "summary": "Applied %d typed editor operation(s) in one undo action." % count, "data": {"operation_count": count}, "ops": expanded}

func _generic_class_ok(cls: String, base: String) -> bool:
	if cls.is_empty() or not ClassDB.class_exists(cls) or not ClassDB.can_instantiate(cls): return false
	if cls.begins_with("Editor") or cls in ["OS", "Engine", "Script", "GDScript", "PackedScene", "MainLoop", "SceneTree"]: return false
	return cls == base or ClassDB.is_parent_class(cls, base)

func _generic_refs_ok(value: Variant, ids: Dictionary) -> bool:
	if value is Dictionary:
		if value.has("ref"):
			return value.ref is String and ids.has(str(value.ref))
		for key in value:
			if not _generic_refs_ok(value[key], ids): return false
		return true
	if value is Array:
		for item in value:
			if not _generic_refs_ok(item, ids): return false
	return true

func _validate_particles(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_path := str(params.get("parent_path", ".")).strip_edges()
	if parent_path.is_empty(): parent_path = "."
	var found: Dictionary = inspector.resolve_scene_node(context.root, parent_path)
	if found.has("error"):
		return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	var parent: Node = found.node
	if parent != context.root and parent.get_owner() != context.root:
		return {"ok": false, "code": "read_only_instance", "message": "The particle parent must be owned by the edited scene."}
	var node_name := str(params.get("node_name", "")).strip_edges()
	if node_name.is_empty(): node_name = _unique_name(parent, "Particles")
	elif not _valid_name(node_name):
		return {"ok": false, "code": "invalid_name", "message": "Invalid particle node name."}
	if parent.get_node_or_null(NodePath(node_name)) != null:
		return {"ok": false, "code": "name_conflict", "message": "A node named " + node_name + " already exists."}
	var amount := int(params.get("amount", 24))
	var lifetime := float(params.get("lifetime", 1.0))
	var gravity := float(params.get("gravity", 200.0))
	var velocity := float(params.get("initial_velocity", 60.0))
	var spread := float(params.get("spread", 45.0))
	var scale := float(params.get("scale", 4.0))
	if amount < 1 or amount > 4096 or lifetime <= 0 or lifetime > 60 or not is_finite(gravity) or not is_finite(velocity) or spread < 0 or spread > 360 or scale <= 0 or scale > 1000:
		return {"ok": false, "code": "invalid_arguments", "message": "Particle amount/lifetime/gravity/velocity/spread/scale are out of range."}
	var color := Color(1.0, 0.7, 0.3)
	if params.get("color") is String and not str(params.color).strip_edges().is_empty():
		color = Color.from_string(str(params.color), color)
	return {"ok": true, "request": {"parent_path": parent_path, "node_name": node_name, "amount": amount, "lifetime": lifetime, "gravity": gravity, "initial_velocity": velocity, "spread": spread, "scale": scale, "color": color}}

func _particle_ops(request: Dictionary, particle_class: String, is_3d: bool) -> Dictionary:
	var material_ops: Array = [
		{"op": "create_resource", "id": "material", "class": "ParticleProcessMaterial", "properties": {
			"direction": Vector3(0, 1, 0),
			"gravity": Vector3(0, request.gravity if not is_3d else -request.gravity, 0),
			"initial_velocity_min": request.initial_velocity,
			"initial_velocity_max": request.initial_velocity,
			"spread": request.spread,
			"scale_min": request.scale,
			"scale_max": request.scale,
			"color": request.color,
		}},
		{"op": "create_node", "id": "particles", "class": particle_class, "name": request.node_name},
		{"op": "add_child", "parent": request.parent_path, "node": "particles"},
		{"op": "set_owner", "node": "particles", "owner": "."},
		{"op": "set_property", "target": "particles", "property": "amount", "value": request.amount},
		{"op": "set_property", "target": "particles", "property": "lifetime", "value": request.lifetime},
		{"op": "set_property", "target": "particles", "property": "emitting", "value": true},
		{"op": "set_property", "target": "particles", "property": "process_material", "value": {"ref": "material"}},
	]
	return {"ok": true, "action_name": "Add " + particle_class, "summary": "Added %s with %d particles, lifetime %.1fs, color %s." % [request.node_name, request.amount, request.lifetime, request.color.to_html(false)], "data": {"particle_class": particle_class, "amount": request.amount, "lifetime": request.lifetime}, "ops": material_ops}

func _build_particles_2d(request: Dictionary) -> Dictionary:
	return _particle_ops(request, "GPUParticles2D", false)

func _build_particles_3d(request: Dictionary) -> Dictionary:
	return _particle_ops(request, "GPUParticles3D", true)

func _validate_mesh_collision(params: Dictionary, context: Dictionary) -> Dictionary:
	var target_path := str(params.get("target_path", "")).strip_edges()
	if target_path.is_empty(): return {"ok": false, "code": "invalid_arguments", "message": "target_path is required."}
	var found: Dictionary = inspector.resolve_scene_node(context.root, target_path)
	if found.has("error"): return {"ok": false, "code": str(found.error.code), "message": str(found.error.message)}
	var target: Node = found.node
	if not target is MeshInstance3D or target.mesh == null:
		return {"ok": false, "code": "invalid_target", "message": "Choose an owned MeshInstance3D with a mesh."}
	if target.get_parent() == null or (target.get_parent() != context.root and target.get_parent().get_owner() != context.root):
		return {"ok": false, "code": "read_only_instance", "message": "The mesh parent must be owned by the edited scene."}
	var body_name := str(params.get("body_name", "")).strip_edges()
	if body_name.is_empty(): body_name = _unique_name(target.get_parent(), "MeshBody")
	elif not _valid_name(body_name):
		return {"ok": false, "code": "invalid_name", "message": "Invalid collision body name."}
	if target.get_parent().get_node_or_null(NodePath(body_name)) != null:
		return {"ok": false, "code": "name_conflict", "message": "A node named " + body_name + " already exists."}
	return {"ok": true, "request": {"target_path": target_path, "body_name": body_name, "parent_path": str(context.root.get_path_to(target.get_parent())) if target.get_parent() != context.root else ".", "mesh": target.mesh}}

func _build_mesh_collision(request: Dictionary) -> Dictionary:
	var shape: ConcavePolygonShape3D = request.mesh.create_trimesh_shape()
	if shape == null: return {"ok": false, "code": "invalid_mesh", "message": "The mesh could not produce a trimesh collision shape."}
	return {"ok": true, "action_name": "Add collision for " + str(request.target_path), "summary": "Created an owned StaticBody3D and trimesh CollisionShape3D for %s." % request.target_path, "data": {"artifact": str(request.target_path)}, "ops": [
		{"op": "create_resource_value", "id": "shape", "resource": shape},
		{"op": "create_node", "id": "body", "class": "StaticBody3D", "name": request.body_name},
		{"op": "create_node", "id": "collision", "class": "CollisionShape3D", "name": "CollisionShape3D"},
		{"op": "add_child", "parent": request.parent_path, "node": "body"},
		{"op": "set_owner", "node": "body", "owner": "."},
		{"op": "add_child", "parent": "body", "node": "collision"},
		{"op": "set_owner", "node": "collision", "owner": "body"},
		{"op": "set_property", "target": "collision", "property": "shape", "value": {"ref": "shape"}},
	]}

func _owned_parent(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_path := str(params.get("parent_path", ".")).strip_edges()
	if parent_path.is_empty(): parent_path = "."
	var found: Dictionary = inspector.resolve_scene_node(context.root, parent_path)
	if found.has("error"): return {"error": found}
	var parent: Node = found.node
	if parent != context.root and parent.get_owner() != context.root:
		return {"error": {"code": "read_only_instance", "message": "The parent must be owned by the edited scene."}}
	return {"parent": parent, "parent_path": parent_path}

func _node_name(params: Dictionary, parent: Node, base: String) -> Dictionary:
	var name := str(params.get("node_name", "")).strip_edges()
	if name.is_empty(): name = _unique_name(parent, base)
	elif not _valid_name(name): return {"error": {"code": "invalid_name", "message": "Invalid node name."}}
	if parent.get_node_or_null(NodePath(name)) != null: return {"error": {"code": "name_conflict", "message": "A node named " + name + " already exists."}}
	return {"name": name}

func _validate_tilemap(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_result := _owned_parent(params, context)
	if parent_result.has("error"): return {"ok": false, "code": parent_result.error.code, "message": parent_result.error.message}
	var name_result := _node_name(params, parent_result.parent, "TileMapLayer")
	if name_result.has("error"): return {"ok": false, "code": name_result.error.code, "message": name_result.error.message}
	var tw := int(params.get("tile_width", 16)); var th := int(params.get("tile_height", 16))
	if tw < 1 or th < 1 or tw > 4096 or th > 4096: return {"ok": false, "code": "invalid_arguments", "message": "Tile size must be between 1 and 4096."}
	var texture: Variant = null
	var texture_path := str(params.get("texture_path", "")).strip_edges()
	if not texture_path.is_empty():
		if not texture_path.begins_with("res://") or ".." in texture_path.split("/") or not FileAccess.file_exists(texture_path):
			return {"ok": false, "code": "invalid_arguments", "message": "Tile texture must be an existing res:// image."}
		texture = ResourceLoader.load(texture_path, "", ResourceLoader.CACHE_MODE_REUSE)
		if not texture is Texture2D: return {"ok": false, "code": "artifact_invalid", "message": "Tile texture did not load as Texture2D."}
	return {"ok": true, "request": {"parent_path": parent_result.parent_path, "node_name": name_result.name, "texture": texture, "tile_size": Vector2i(tw, th), "paint": bool(params.get("paint_origin", false))}}

func _build_tilemap(request: Dictionary) -> Dictionary:
	var tileset := TileSet.new()
	tileset.tile_size = request.tile_size
	var has_source := false
	if request.texture is Texture2D:
		var source := TileSetAtlasSource.new()
		source.texture = request.texture
		source.texture_region_size = request.tile_size
		source.create_tile(Vector2i.ZERO)
		tileset.add_source(source, 0)
		has_source = true
	var ops: Array = [
		{"op": "create_resource_value", "id": "tileset", "resource": tileset},
		{"op": "create_node", "id": "layer", "class": "TileMapLayer", "name": request.node_name},
		{"op": "add_child", "parent": request.parent_path, "node": "layer"},
		{"op": "set_owner", "node": "layer", "owner": "."},
		{"op": "set_property", "target": "layer", "property": "tile_set", "value": {"ref": "tileset"}},
	]
	if request.paint and has_source:
		ops.append({"op": "call_method", "target": "layer", "method": "set_cell", "args": [Vector2i.ZERO, 0, Vector2i.ZERO, 0], "undo_method": "erase_cell", "undo_args": [Vector2i.ZERO]})
	return {"ok": true, "action_name": "Add TileMapLayer", "summary": "Added %s with a %dx%d TileSet%s." % [request.node_name, request.tile_size.x, request.tile_size.y, " and one painted tile" if request.paint and has_source else ""], "data": {"has_source": has_source, "tile_size": [request.tile_size.x, request.tile_size.y]}, "ops": ops}

func _validate_gridmap(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_result := _owned_parent(params, context)
	if parent_result.has("error"): return {"ok": false, "code": parent_result.error.code, "message": parent_result.error.message}
	var name_result := _node_name(params, parent_result.parent, "GridMap")
	if name_result.has("error"): return {"ok": false, "code": name_result.error.code, "message": name_result.error.message}
	var size := float(params.get("cell_size", 1.0))
	if size <= 0 or size > 1000: return {"ok": false, "code": "invalid_arguments", "message": "cell_size must be positive and bounded."}
	return {"ok": true, "request": {"parent_path": parent_result.parent_path, "node_name": name_result.name, "cell_size": size, "paint": bool(params.get("paint_origin", true))}}

func _build_gridmap(request: Dictionary) -> Dictionary:
	var library := MeshLibrary.new()
	library.create_item(0)
	library.set_item_name(0, "Cell")
	library.set_item_mesh(0, BoxMesh.new())
	var ops: Array = [
		{"op": "create_resource_value", "id": "library", "resource": library},
		{"op": "create_node", "id": "grid", "class": "GridMap", "name": request.node_name},
		{"op": "add_child", "parent": request.parent_path, "node": "grid"},
		{"op": "set_owner", "node": "grid", "owner": "."},
		{"op": "set_property", "target": "grid", "property": "mesh_library", "value": {"ref": "library"}},
		{"op": "set_property", "target": "grid", "property": "cell_size", "value": Vector3.ONE * request.cell_size},
	]
	if request.paint:
		ops.append({"op": "call_method", "target": "grid", "method": "set_cell_item", "args": [Vector3i.ZERO, 0], "undo_method": "set_cell_item", "undo_args": [Vector3i.ZERO, -1]})
	return {"ok": true, "action_name": "Add GridMap", "summary": "Added %s with a one-cell MeshLibrary%s." % [request.node_name, " and one painted cell" if request.paint else ""], "data": {"cell_size": request.cell_size}, "ops": ops}

func _validate_animated_sprite(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_result := _owned_parent(params, context)
	if parent_result.has("error"): return {"ok": false, "code": parent_result.error.code, "message": parent_result.error.message}
	var name_result := _node_name(params, parent_result.parent, "AnimatedSprite2D")
	if name_result.has("error"): return {"ok": false, "code": name_result.error.code, "message": name_result.error.message}
	var paths: Variant = params.get("texture_paths")
	if not paths is Array or paths.is_empty() or paths.size() > 32: return {"ok": false, "code": "invalid_arguments", "message": "texture_paths must contain 1-32 image paths."}
	var textures: Array = []
	for path in paths:
		if not path is String or not path.begins_with("res://") or ".." in path.split("/") or not FileAccess.file_exists(path): return {"ok": false, "code": "artifact_missing", "message": "Sprite frame image is missing: " + str(path)}
		var texture: Variant = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
		if not texture is Texture2D: return {"ok": false, "code": "artifact_invalid", "message": "Sprite frame is not a Texture2D: " + str(path)}
		textures.append(texture)
	var animation := str(params.get("animation_name", "default")).strip_edges()
	if animation.is_empty(): animation = "default"
	var fps := float(params.get("fps", 8.0))
	if fps <= 0 or fps > 120: return {"ok": false, "code": "invalid_arguments", "message": "fps must be between 0 and 120."}
	return {"ok": true, "request": {"parent_path": parent_result.parent_path, "node_name": name_result.name, "textures": textures, "animation": animation, "fps": fps}}

func _build_animated_sprite(request: Dictionary) -> Dictionary:
	var frames := SpriteFrames.new()
	if request.animation != "default": frames.add_animation(request.animation)
	for texture in request.textures: frames.add_frame(request.animation, texture)
	frames.set_animation_speed(request.animation, request.fps)
	return {"ok": true, "action_name": "Add AnimatedSprite2D", "summary": "Added %s with %d frame(s) in %s at %.1f fps." % [request.node_name, Array(request.textures).size(), request.animation, request.fps], "data": {"animation": request.animation, "frames": Array(request.textures).size()}, "ops": [
		{"op": "create_resource_value", "id": "frames", "resource": frames},
		{"op": "create_node", "id": "sprite", "class": "AnimatedSprite2D", "name": request.node_name},
		{"op": "add_child", "parent": request.parent_path, "node": "sprite"},
		{"op": "set_owner", "node": "sprite", "owner": "."},
		{"op": "set_property", "target": "sprite", "property": "sprite_frames", "value": {"ref": "frames"}},
		{"op": "set_property", "target": "sprite", "property": "animation", "value": request.animation},
		{"op": "set_property", "target": "sprite", "property": "autoplay", "value": request.animation},
	]}

func _validate_theme(params: Dictionary, context: Dictionary) -> Dictionary:
	var target_path := str(params.get("target_path", "")).strip_edges()
	var found: Dictionary = inspector.resolve_scene_node(context.root, target_path)
	if found.has("error"): return {"ok": false, "code": found.error.code, "message": found.error.message}
	var target: Node = found.node
	if not target is Control: return {"ok": false, "code": "invalid_target", "message": "Theme target must be a Control."}
	if target != context.root and target.get_owner() != context.root: return {"ok": false, "code": "read_only_instance", "message": "Theme target must be owned by the edited scene."}
	var font_size := int(params.get("font_size", 16))
	if font_size < 1 or font_size > 256: return {"ok": false, "code": "invalid_arguments", "message": "font_size must be between 1 and 256."}
	var font: Variant = null
	var font_path := str(params.get("font_path", "")).strip_edges()
	if not font_path.is_empty():
		if not font_path.begins_with("res://") or not FileAccess.file_exists(font_path): return {"ok": false, "code": "artifact_missing", "message": "Font file is missing: " + font_path}
		font = ResourceLoader.load(font_path, "", ResourceLoader.CACHE_MODE_REUSE)
		if not font is Font: return {"ok": false, "code": "artifact_invalid", "message": "Font did not load as a Font."}
	return {"ok": true, "request": {"target_path": target_path, "font_size": font_size, "font": font}}

func _build_theme(request: Dictionary) -> Dictionary:
	var theme := Theme.new()
	theme.default_font_size = request.font_size
	if request.font is Font: theme.default_font = request.font
	return {"ok": true, "action_name": "Apply theme", "summary": "Applied a Theme with default font size %d to %s." % [request.font_size, request.target_path], "data": {"font_size": request.font_size}, "ops": [
		{"op": "create_resource_value", "id": "theme", "resource": theme},
		{"op": "set_property", "target": request.target_path, "property": "theme", "value": {"ref": "theme"}},
	]}

func _validate_audio_loop(params: Dictionary, context: Dictionary) -> Dictionary:
	var target_path := str(params.get("target_path", "")).strip_edges()
	var found: Dictionary = inspector.resolve_scene_node(context.root, target_path)
	if found.has("error"): return {"ok": false, "code": found.error.code, "message": found.error.message}
	var target: Node = found.node
	if not target is AudioStreamPlayer or target.stream == null: return {"ok": false, "code": "invalid_target", "message": "Target must be an AudioStreamPlayer with a stream."}
	if target != context.root and target.get_owner() != context.root: return {"ok": false, "code": "read_only_instance", "message": "Audio target must be owned by the edited scene."}
	return {"ok": true, "request": {"target_path": target_path, "enabled": bool(params.get("enabled", true))}}

func _build_audio_loop(request: Dictionary) -> Dictionary:
	var found: Dictionary = inspector.resolve_scene_node(EditorInterface.get_edited_scene_root(), request.target_path)
	var target: AudioStreamPlayer = found.get("node")
	var copy := target.stream.duplicate()
	if copy == null: return {"ok": false, "code": "invalid_operation", "message": "Audio stream could not be duplicated."}
	if copy is AudioStreamWAV:
		copy.loop_mode = AudioStreamWAV.LOOP_FORWARD if request.enabled else AudioStreamWAV.LOOP_DISABLED
	elif copy.get("loop") != null:
		copy.set("loop", request.enabled)
	else:
		return {"ok": false, "code": "invalid_operation", "message": "This audio stream does not expose a loop setting."}
	return {"ok": true, "action_name": "Configure audio loop", "summary": ("Enabled" if request.enabled else "Disabled") + " looping for " + request.target_path + " on a duplicated stream.", "ops": [
		{"op": "create_resource_value", "id": "stream", "resource": copy},
		{"op": "set_property", "target": request.target_path, "property": "stream", "value": {"ref": "stream"}},
	]}

func _validate_navigation(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_result := _owned_parent(params, context)
	if parent_result.has("error"): return {"ok": false, "code": parent_result.error.code, "message": parent_result.error.message}
	var name_result := _node_name(params, parent_result.parent, "NavigationRegion3D")
	if name_result.has("error"): return {"ok": false, "code": name_result.error.code, "message": name_result.error.message}
	var radius := float(params.get("agent_radius", 0.5)); var cell := float(params.get("cell_size", 0.25))
	if radius < 0 or radius > 1000 or cell <= 0 or cell > 1000: return {"ok": false, "code": "invalid_arguments", "message": "Navigation radius/cell size are out of range."}
	return {"ok": true, "request": {"parent_path": parent_result.parent_path, "node_name": name_result.name, "agent_radius": radius, "cell_size": cell}}

func _build_navigation(request: Dictionary) -> Dictionary:
	var navmesh := NavigationMesh.new()
	navmesh.agent_radius = request.agent_radius
	navmesh.cell_size = request.cell_size
	return {"ok": true, "action_name": "Add NavigationRegion3D", "summary": "Added %s with a NavigationMesh; baking is not performed." % request.node_name, "data": {"bake": "not_requested"}, "ops": [
		{"op": "create_resource_value", "id": "navmesh", "resource": navmesh},
		{"op": "create_node", "id": "region", "class": "NavigationRegion3D", "name": request.node_name},
		{"op": "add_child", "parent": request.parent_path, "node": "region"},
		{"op": "set_owner", "node": "region", "owner": "."},
		{"op": "set_property", "target": "region", "property": "navigation_mesh", "value": {"ref": "navmesh"}},
	]}

func _validate_animation_tree(params: Dictionary, context: Dictionary) -> Dictionary:
	var found: Dictionary = inspector.resolve_scene_node(context.root, str(params.get("animation_player_path", "")))
	if found.has("error"): return {"ok": false, "code": found.error.code, "message": found.error.message}
	var player: Node = found.node
	if not player is AnimationPlayer or player.get_animation_list().is_empty(): return {"ok": false, "code": "invalid_target", "message": "AnimationTree target must be an AnimationPlayer with at least one animation."}
	if player.get_parent() == null or (player.get_parent() != context.root and player.get_parent().get_owner() != context.root): return {"ok": false, "code": "read_only_instance", "message": "AnimationPlayer parent must be owned by the edited scene."}
	var state_name := str(params.get("state_name", "")).strip_edges()
	if state_name.is_empty(): state_name = str(player.get_animation_list()[0])
	if not player.has_animation(state_name): return {"ok": false, "code": "invalid_arguments", "message": "AnimationPlayer has no animation named " + state_name}
	var name_result := _node_name(params, player.get_parent(), "AnimationTree")
	if name_result.has("error"): return {"ok": false, "code": name_result.error.code, "message": name_result.error.message}
	return {"ok": true, "request": {"player": player, "parent_path": str(context.root.get_path_to(player.get_parent())) if player.get_parent() != context.root else ".", "node_name": name_result.name, "state_name": state_name, "anim_player": NodePath("../" + str(player.name))}}

func _build_animation_tree(request: Dictionary) -> Dictionary:
	var machine := AnimationNodeStateMachine.new()
	var state := AnimationNodeAnimation.new()
	state.animation = request.state_name
	machine.add_node(request.state_name, state, Vector2.ZERO)
	return {"ok": true, "action_name": "Add AnimationTree", "summary": "Added %s with state %s bound to %s." % [request.node_name, request.state_name, request.player.name], "data": {"state": request.state_name}, "ops": [
		{"op": "create_resource_value", "id": "machine", "resource": machine},
		{"op": "create_node", "id": "tree", "class": "AnimationTree", "name": request.node_name},
		{"op": "add_child", "parent": request.parent_path, "node": "tree"},
		{"op": "set_owner", "node": "tree", "owner": "."},
		{"op": "set_property", "target": "tree", "property": "anim_player", "value": request.anim_player},
		{"op": "set_property", "target": "tree", "property": "tree_root", "value": {"ref": "machine"}},
		{"op": "set_property", "target": "tree", "property": "active", "value": true},
	]}

func _validate_weather(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_result := _owned_parent(params, context)
	if parent_result.has("error"): return {"ok": false, "code": parent_result.error.code, "message": parent_result.error.message}
	var name_result := _node_name(params, parent_result.parent, "Weather")
	if name_result.has("error"): return {"ok": false, "code": name_result.error.code, "message": name_result.error.message}
	var amount := int(params.get("amount", 200)); var extent := float(params.get("extent", 10.0)); var speed := float(params.get("speed", 12.0))
	if amount < 1 or amount > 4096 or extent <= 0 or extent > 10000 or speed < 0 or speed > 10000: return {"ok": false, "code": "invalid_arguments", "message": "Weather amount/extent/speed are out of range."}
	var color := Color(0.7, 0.8, 1.0)
	if params.get("color") is String and not str(params.color).strip_edges().is_empty(): color = Color.from_string(str(params.color), color)
	return {"ok": true, "request": {"parent_path": parent_result.parent_path, "node_name": name_result.name, "amount": amount, "extent": extent, "speed": speed, "color": color}}

func _build_weather(request: Dictionary) -> Dictionary:
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	material.emission_box_extents = Vector3(request.extent, 1.0, request.extent)
	material.direction = Vector3(0, -1, 0)
	material.spread = 8.0
	material.gravity = Vector3(0, -9.8, 0)
	material.initial_velocity_min = request.speed
	material.initial_velocity_max = request.speed
	material.scale_min = 0.05
	material.scale_max = 0.05
	material.color = request.color
	return {"ok": true, "action_name": "Add 3D weather", "summary": "Added %s with %d weather particles across a %.1f unit box." % [request.node_name, request.amount, request.extent], "data": {"amount": request.amount, "extent": request.extent}, "ops": [
		{"op": "create_resource", "id": "material", "class": "ParticleProcessMaterial", "properties": {"direction": Vector3(0, -1, 0), "gravity": Vector3(0, -9.8, 0), "initial_velocity_min": request.speed, "initial_velocity_max": request.speed, "spread": 8.0, "scale_min": 0.05, "scale_max": 0.05, "color": request.color, "emission_shape": ParticleProcessMaterial.EMISSION_SHAPE_BOX, "emission_box_extents": Vector3(request.extent, 1.0, request.extent)}},
		{"op": "create_node", "id": "weather", "class": "GPUParticles3D", "name": request.node_name},
		{"op": "add_child", "parent": request.parent_path, "node": "weather"},
		{"op": "set_owner", "node": "weather", "owner": "."},
		{"op": "set_property", "target": "weather", "property": "amount", "value": request.amount},
		{"op": "set_property", "target": "weather", "property": "lifetime", "value": 4.0},
		{"op": "set_property", "target": "weather", "property": "emitting", "value": true},
		{"op": "set_property", "target": "weather", "property": "process_material", "value": {"ref": "material"}},
	]}

func _validate_trail(params: Dictionary, context: Dictionary) -> Dictionary:
	var parent_result := _owned_parent(params, context)
	if parent_result.has("error"): return {"ok": false, "code": parent_result.error.code, "message": parent_result.error.message}
	var name_result := _node_name(params, parent_result.parent, "Trail3D")
	if name_result.has("error"): return {"ok": false, "code": name_result.error.code, "message": name_result.error.message}
	var width := float(params.get("width", 0.2)); var lifetime := float(params.get("lifetime", 1.0))
	if width <= 0 or width > 1000 or lifetime <= 0 or lifetime > 60: return {"ok": false, "code": "invalid_arguments", "message": "Trail width/lifetime are out of range."}
	var color := Color(0.4, 0.8, 1.0)
	if params.get("color") is String and not str(params.color).strip_edges().is_empty(): color = Color.from_string(str(params.color), color)
	return {"ok": true, "request": {"parent_path": parent_result.parent_path, "node_name": name_result.name, "width": width, "lifetime": lifetime, "color": color}}

func _build_trail(request: Dictionary) -> Dictionary:
	return {"ok": true, "action_name": "Add Trail3D", "summary": "Added %s Trail3D ribbon (width %.2f, lifetime %.1fs)." % [request.node_name, request.width, request.lifetime], "data": {"width": request.width, "lifetime": request.lifetime}, "ops": [
		{"op": "create_node", "id": "trail", "class": "Trail3D", "name": request.node_name},
		{"op": "add_child", "parent": request.parent_path, "node": "trail"},
		{"op": "set_owner", "node": "trail", "owner": "."},
		{"op": "set_property", "target": "trail", "property": "width", "value": request.width},
		{"op": "set_property", "target": "trail", "property": "lifetime", "value": request.lifetime},
		{"op": "set_property", "target": "trail", "property": "color", "value": request.color},
		{"op": "set_property", "target": "trail", "property": "emitting", "value": true},
	]}

func _validate_play_animation(params: Dictionary, context: Dictionary) -> Dictionary:
	var found: Dictionary = inspector.resolve_scene_node(context.root, str(params.get("target_path", "")))
	if found.has("error"): return {"ok": false, "code": found.error.code, "message": found.error.message}
	var player: Node = found.node
	if not player is AnimationPlayer: return {"ok": false, "code": "invalid_target", "message": "Target must be an AnimationPlayer."}
	if player != context.root and player.get_owner() != context.root: return {"ok": false, "code": "read_only_instance", "message": "AnimationPlayer must be owned by the edited scene."}
	var animations: Array = player.get_animation_list()
	if animations.is_empty(): return {"ok": false, "code": "invalid_target", "message": "AnimationPlayer has no animations."}
	var animation := str(params.get("animation", "")).strip_edges()
	if animation.is_empty(): animation = str(animations[0])
	if not player.has_animation(animation): return {"ok": false, "code": "invalid_arguments", "message": "AnimationPlayer has no animation named " + animation}
	return {"ok": true, "request": {"target_path": str(params.get("target_path", "")), "animation": animation, "autoplay": bool(params.get("autoplay", true))}}

func _build_play_animation(request: Dictionary) -> Dictionary:
	var ops: Array = [{"op": "set_property", "target": request.target_path, "property": "current_animation", "value": request.animation}]
	if request.autoplay: ops.append({"op": "set_property", "target": request.target_path, "property": "autoplay", "value": request.animation})
	return {"ok": true, "action_name": "Play animation " + request.animation, "summary": "Set %s to animation %s." % [request.target_path, request.animation], "data": {"animation": request.animation}, "ops": ops}

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
