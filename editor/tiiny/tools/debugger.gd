@tool
extends RefCounted

# Read/control bridge for the built-in editor debugger. The C++ bridge returns
# bounded, JSON-safe snapshots; this provider adds schemas and structured
# results for the tool registry. No debuggee code is evaluated from here.

var debugger_node: Object

func definitions() -> Array:
	return [
		{"name": "get_debugger_state", "title": "Get debugger state", "description": "Read the current debugger session and pause state. Runtime data, not the edited scene.", "parameters": {"type": "object", "properties": {}, "additionalProperties": false}, "risk": "read", "timeout_ms": 5000},
		{"name": "get_stack_frames", "title": "Get paused stack frames", "description": "Read stack frames from the paused debugger session.", "parameters": {"type": "object", "properties": {}, "additionalProperties": false}, "risk": "read", "timeout_ms": 5000},
		{"name": "get_stack_variables", "title": "Get paused locals and members", "description": "Read locals, members, and globals for the selected paused stack frame.", "parameters": {"type": "object", "properties": {}, "additionalProperties": false}, "risk": "read", "timeout_ms": 5000},
		{"name": "select_stack_frame", "title": "Select paused stack frame", "description": "Select a paused stack frame and request its variables. Frame 0 is the innermost frame.", "parameters": {"type": "object", "properties": {"frame": {"type": "integer", "minimum": 0, "maximum": 1024}}, "required": ["frame"], "additionalProperties": false}, "risk": "read", "timeout_ms": 5000},
		{"name": "get_runtime_tree", "title": "Get runtime scene tree", "description": "Read the running scene tree from the debugger session. Runtime identities and types only; property values require a selected remote node.", "parameters": {"type": "object", "properties": {}, "additionalProperties": false}, "risk": "read", "timeout_ms": 5000},
		{"name": "inspect_runtime_node", "title": "Inspect runtime node identity", "description": "Find a running node by runtime path and report its identity. Property values are explicitly unavailable without a selected remote node.", "parameters": {"type": "object", "properties": {"path": {"type": "string", "minLength": 1, "maxLength": 512}}, "required": ["path"], "additionalProperties": false}, "risk": "read", "timeout_ms": 5000},
		{"name": "set_breakpoint", "title": "Set breakpoint", "description": "Set a breakpoint on an existing project script line and synchronize the editor debugger.", "parameters": {"type": "object", "properties": {"path": {"type": "string", "minLength": 1, "maxLength": 512}, "line": {"type": "integer", "minimum": 1, "maximum": 1000000}}, "required": ["path", "line"], "additionalProperties": false}, "risk": "mutating", "timeout_ms": 5000},
		{"name": "remove_breakpoint", "title": "Remove breakpoint", "description": "Remove a breakpoint from an existing project script line.", "parameters": {"type": "object", "properties": {"path": {"type": "string", "minLength": 1, "maxLength": 512}, "line": {"type": "integer", "minimum": 1, "maximum": 1000000}}, "required": ["path", "line"], "additionalProperties": false}, "risk": "mutating", "timeout_ms": 5000},
		{"name": "debug_continue", "title": "Continue execution", "description": "Resume the paused debugger session. Pause data becomes stale.", "parameters": {"type": "object", "properties": {}, "additionalProperties": false}, "risk": "mutating", "timeout_ms": 5000},
		{"name": "debug_step", "title": "Step into", "description": "Step into the next script statement in the paused debugger session.", "parameters": {"type": "object", "properties": {}, "additionalProperties": false}, "risk": "mutating", "timeout_ms": 5000},
		{"name": "debug_next", "title": "Step over", "description": "Step over the next script statement in the paused debugger session.", "parameters": {"type": "object", "properties": {}, "additionalProperties": false}, "risk": "mutating", "timeout_ms": 5000},
		{"name": "debug_pause", "title": "Pause execution", "description": "Request a pause in the active debugger session.", "parameters": {"type": "object", "properties": {}, "additionalProperties": false}, "risk": "mutating", "timeout_ms": 5000},
	]

func execute(name: String, arguments: Dictionary, _context: Dictionary = {}) -> Dictionary:
	if debugger_node == null:
		return _error("debugger_unavailable", "The editor debugger is unavailable.")
	match name:
		"get_debugger_state":
			var state: Dictionary = _state()
			var summary := "Debugger session is unavailable."
			if bool(state.get("available", false)):
				if bool(state.get("breaked", false)):
					summary = "Debugger session %s is paused at %s:%s." % [str(state.get("session", -1)), str(state.get("script_file", "")), str(state.get("script_line", -1))]
				elif bool(state.get("session_active", false)):
					summary = "Debugger session %s is running; pause data is unavailable." % str(state.get("session", -1))
				else:
					summary = "No active debugger session."
			return {"ok": true, "summary": summary, "data": state, "affected": [{"kind": "debugger", "session": int(state.get("session", -1))}]}
		"get_stack_frames":
			var state: Dictionary = _state()
			if not bool(state.get("breaked", false)):
				return _error("not_paused", "Execution is not paused; stack frames are unavailable.")
			var frames: Array = debugger_node.call("tiiny_stack_frames")
			return {"ok": true, "summary": "Read %d paused stack frame(s) from session %s." % [frames.size(), str(state.get("session", -1))], "data": {"state": state, "frames": frames}, "affected": [{"kind": "debugger", "session": int(state.get("session", -1))}]}
		"get_stack_variables":
			var state: Dictionary = _state()
			if not bool(state.get("breaked", false)):
				return _error("not_paused", "Execution is not paused; locals and members are unavailable.")
			var groups: Dictionary = debugger_node.call("tiiny_stack_variables")
			if groups.is_empty():
				var frame := int(state.get("selected_frame", -1))
				debugger_node.call("tiiny_select_stack_frame", maxi(0, frame))
				await Engine.get_main_loop().create_timer(0.25).timeout
				groups = debugger_node.call("tiiny_stack_variables")
			var count := 0
			for group in groups.values():
				if group is Dictionary: count += group.size()
			return {"ok": true, "summary": "Read %d paused variable(s) for frame %s." % [count, str(state.get("selected_frame", -1))], "data": {"state": state, "variables": groups}, "affected": [{"kind": "debugger", "session": int(state.get("session", -1))}]}
		"select_stack_frame":
			var selected: Dictionary = debugger_node.call("tiiny_select_stack_frame", int(arguments.get("frame", 0)))
			if not bool(selected.get("ok", false)):
				return _error("frame_unavailable", str(selected.get("error", "Stack frame is unavailable.")))
			await Engine.get_main_loop().create_timer(0.2).timeout
			return {"ok": true, "summary": "Selected paused stack frame %d." % int(arguments.get("frame", 0)), "data": selected, "affected": [{"kind": "debugger", "session": int(_state().get("session", -1))}]}
		"get_runtime_tree":
			var state: Dictionary = _state()
			if not bool(state.get("session_active", false)):
				return _error("no_session", "No active debugger session.")
			var nodes: Array = debugger_node.call("tiiny_runtime_tree")
			if nodes.is_empty() and debugger_node.has_method("request_remote_tree"):
				debugger_node.call("request_remote_tree")
				await Engine.get_main_loop().create_timer(0.2).timeout
				nodes = debugger_node.call("tiiny_runtime_tree")
			return {"ok": true, "summary": "Read %d runtime node(s) from the running scene. Values are not included." % nodes.size(), "data": {"state": state, "source": "runtime", "nodes": nodes}, "affected": []}
		"inspect_runtime_node":
			var state: Dictionary = _state()
			if not bool(state.get("session_active", false)):
				return _error("no_session", "No active debugger session.")
			var path := str(arguments.get("path", ""))
			for entry in debugger_node.call("tiiny_runtime_tree"):
				if entry is Dictionary and (str(entry.get("path", "")) == path or str(entry.get("name", "")) == path):
					var detail: Dictionary = entry.duplicate(true)
					detail["properties_available"] = false
					detail["note"] = "Runtime property values are unavailable until the node is selected in the Remote scene tree; use the debugger state/stack tools for observed values."
					return {"ok": true, "summary": "Found runtime node %s (%s). Property values were not inferred." % [path, str(entry.get("type", "unknown"))], "data": detail, "affected": [{"kind": "runtime_node", "path": path}]}
			return _error("runtime_node_missing", "Runtime node was not found in the current debugger tree: " + path)
		"set_breakpoint", "remove_breakpoint":
			var enabled := name == "set_breakpoint"
			var result: Dictionary = debugger_node.call("tiiny_set_breakpoint", str(arguments.get("path", "")), int(arguments.get("line", 0)), enabled)
			if not bool(result.get("ok", false)):
				return _error("invalid_breakpoint", str(result.get("error", "Breakpoint could not be changed.")))
			return {"ok": true, "summary": ("Set" if enabled else "Removed") + " breakpoint at %s:%d." % [str(result.get("path", "")), int(result.get("line", 0))], "data": result, "affected": [{"kind": "breakpoint", "path": str(result.get("path", "")), "line": int(result.get("line", 0))}]}
		"debug_continue", "debug_step", "debug_next", "debug_pause":
			var command := name.trim_prefix("debug_")
			var result: Dictionary = debugger_node.call("tiiny_debug_command", command)
			if not bool(result.get("ok", false)):
				return _error("debug_unavailable", str(result.get("error", "Debugger command failed.")))
			return {"ok": true, "summary": "Debugger command %s accepted; pause data may now be stale." % command, "data": result, "affected": [{"kind": "debugger", "session": int(result.get("state", {}).get("session", -1))}]}
	return _error("unknown_tool", "Unknown debugger tool: " + name)

func _state() -> Dictionary:
	if debugger_node == null: return {"available": false, "source": "runtime"}
	return debugger_node.call("tiiny_debugger_state")

func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "summary": message, "error": {"code": code, "message": message}}
