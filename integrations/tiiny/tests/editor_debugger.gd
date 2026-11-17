@tool
extends EditorPlugin

var dock: Node
var provider: RefCounted
var debugger_node: Object

func _enter_tree() -> void:
	_run.call_deferred()

func _frames(count: int) -> void:
	for index in range(count):
		await get_tree().process_frame

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func _wait_for(predicate: Callable, timeout_ms := 10000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()): return true
		await get_tree().create_timer(0.05).timeout
	return false

func _run() -> void:
	await _frames(10)
	dock = get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if dock == null: _fail("Tiiny dock is missing"); return
	dock.call("_ensure_workspace_registry")
	provider = dock.get("workspace_debugger")
	debugger_node = dock.get("debugger_node")
	if provider == null:
		print("debugger diagnostics: script=", dock.get("workspace_debugger_script"), " registry=", dock.get("workspace_registry"), " node=", debugger_node)
	if provider == null or debugger_node == null: _fail("Debugger provider/bridge is missing"); return
	var invalid_path: Dictionary = await provider.execute("set_breakpoint", {"path": "res://missing.gd", "line": 1})
	if _code(invalid_path) != "invalid_breakpoint": _fail("Missing script breakpoint was accepted: " + str(invalid_path)); return
	var invalid_line: Dictionary = await provider.execute("set_breakpoint", {"path": "res://debuggee.gd", "line": 0})
	if _code(invalid_line) != "invalid_breakpoint": _fail("Invalid breakpoint line was accepted: " + str(invalid_line)); return
	EditorInterface.play_custom_scene("res://debug_scene.tscn")
	if not await _wait_for(func(): return bool(debugger_node.call("tiiny_debugger_state").get("session_active", false)), 10000):
		_fail("Debugger session did not start"); return
	var created: Dictionary = await provider.execute("set_breakpoint", {"path": "res://debuggee.gd", "line": 8})
	if not created.get("ok", false): _fail("Breakpoint was not set: " + str(created)); return
	var state: Dictionary = debugger_node.call("tiiny_debugger_state")
	if int(state.get("breakpoints", 0)) < 1: _fail("Breakpoint did not reach the editor debugger state"); return
	if not await _wait_for(func(): return bool(debugger_node.call("tiiny_debugger_state").get("breaked", false)) and not Array(debugger_node.call("tiiny_stack_frames")).is_empty(), 15000):
		_fail("Scene did not pause at the breakpoint: " + str(debugger_node.call("tiiny_debugger_state"))); return
	var paused: Dictionary = debugger_node.call("tiiny_debugger_state")
	if not bool(paused.get("debuggable", false)) or not str(paused.get("script_file", "")).ends_with("debuggee.gd"):
		_fail("Paused state is not grounded in the fixture script: " + str(paused)); return
	var frames_result: Dictionary = await provider.execute("get_stack_frames", {})
	if not frames_result.get("ok", false) or Array(frames_result.get("data", {}).get("frames", [])).is_empty():
		_fail("Paused stack frames are missing: " + str(frames_result)); return
	var frame: Dictionary = frames_result.data.frames[0]
	if not str(frame.get("file", "")).ends_with("debuggee.gd"): _fail("Stack frame file is wrong: " + str(frame)); return
	var selected: Dictionary = await provider.execute("select_stack_frame", {"frame": 0})
	if not selected.get("ok", false): _fail("Stack frame selection failed: " + str(selected)); return
	var variables: Dictionary = await provider.execute("get_stack_variables", {})
	if not variables.get("ok", false): _fail("Paused variables are missing: " + str(variables)); return
	var groups: Dictionary = variables.get("data", {}).get("variables", {})
	if not groups.get("Members", {}).has("counter") or int(groups.Members.counter) != 7 or not groups.get("Locals", {}).has("doubled"):
		_fail("Paused variables do not contain counter=7 and doubled: " + str(groups)); return
	print("Paused locals: ", JSON.stringify(groups))
	var runtime: Dictionary = await provider.execute("get_runtime_tree", {})
	if not runtime.get("ok", false): _fail("Runtime tree request failed: " + str(runtime)); return
	if Array(runtime.get("data", {}).get("nodes", [])).is_empty(): _fail("Runtime tree returned no live nodes"); return
	print("Runtime tree nodes: ", Array(runtime.get("data", {}).get("nodes", [])).size())
	var stepped: Dictionary = await provider.execute("debug_next", {})
	if not stepped.get("ok", false): _fail("Step over failed: " + str(stepped)); return
	if not await _wait_for(func():
		var current: Array = debugger_node.call("tiiny_stack_frames")
		return bool(debugger_node.call("tiiny_debugger_state").get("breaked", false)) and not current.is_empty() and int(current[0].get("line", 0)) > 8, 10000):
		_fail("Step over did not pause on a later line: " + str(debugger_node.call("tiiny_debugger_state")) + " frames=" + str(debugger_node.call("tiiny_stack_frames"))); return
	print("Step over reached frame: ", JSON.stringify(debugger_node.call("tiiny_stack_frames")[0]))
	var continued: Dictionary = await provider.execute("debug_continue", {})
	if not continued.get("ok", false): _fail("Continue failed: " + str(continued)); return
	if not await _wait_for(func(): return not bool(debugger_node.call("tiiny_debugger_state").get("breaked", false)), 5000):
		_fail("Debugger remained paused after continue"); return
	var stale: Dictionary = await provider.execute("get_stack_frames", {})
	if _code(stale) != "not_paused": _fail("Continued execution did not invalidate paused frames: " + str(stale)); return
	if not await _wait_for(func(): return not bool(debugger_node.call("tiiny_debugger_state").get("session_active", false)), 8000):
		_fail("Fixture debugger session did not end"); return
	var offline: Dictionary = await provider.execute("get_runtime_tree", {})
	if _code(offline) != "no_session": _fail("Ended session still exposed runtime nodes: " + str(offline)); return
	var pause_offline: Dictionary = await provider.execute("debug_pause", {})
	if _code(pause_offline) != "debug_unavailable": _fail("Ended session accepted a pause command: " + str(pause_offline)); return
	var removed: Dictionary = await provider.execute("remove_breakpoint", {"path": "res://debuggee.gd", "line": 8})
	if not removed.get("ok", false): _fail("Breakpoint removal failed: " + str(removed)); return
	var final_state: Dictionary = debugger_node.call("tiiny_debugger_state")
	if int(final_state.get("breakpoints", 0)) != 0: _fail("Breakpoint remained after removal: " + str(final_state)); return
	print("Tiiny debugger integration passed.")
	get_tree().quit(0)

func _code(result: Dictionary) -> String:
	return str(result.get("error", {}).get("code", ""))
