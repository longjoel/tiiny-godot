#ifndef TIINY_AI_MANAGER_SOURCE_H
#define TIINY_AI_MANAGER_SOURCE_H

static const char *const TIINY_AI_MANAGER_SOURCE = R"TIINY_GD(
@tool
extends Node

signal log_message(message: String, message_type: int)
signal changed

const CODING_DEFAULT := "Qwen/Qwen3.6-35B-A3B"
const ROLES := {"coding_model": "Scripting", "image_model": "Image generation", "image_to_3d_model": "Image to 3D", "music_model": "Music", "speech_model": "Text to speech"}
const ROLE_TYPES := {"coding_model": ["Text Generation", "Image-Text-to-Text"], "image_model": ["Text-to-Image"], "image_to_3d_model": ["Image-to-3D"], "music_model": ["Music Generation"], "speech_model": ["Text-to-Speech"]}
const PLAN_LIFETIME := 60.0
var snapshot: Dictionary = {}
var draft: Dictionary = {}
var plan: Dictionary = {}
var busy := false
var applying := false
var connected := false
var message := "Refresh device data to configure models."
var operation_log := PackedStringArray()
var process_id := -1
var draft_initialized := false
var progress_reports := {}
var operation_started := 0

# The SDK emits a terminal UI. Keep only reported percentages, never terminal
# escape sequences or arbitrary CLI text, when forwarding progress to Output.
class ProgressReader:
	var pending := ""
	var ansi := RegEx.new()
	var percentage := RegEx.new()

	func _init() -> void:
		ansi.compile("\\x1b\\[[0-?]*[ -/]*[@-~]|\\x1b\\][^\\x07]*(?:\\x07|\\x1b\\\\)")
		percentage.compile("([0-9]{1,3}(?:\\.[0-9]+)?)\\s*%")

	func feed(bytes: PackedByteArray, flush := false) -> Array[float]:
		var ascii := PackedByteArray()
		for byte in bytes:
			if byte in [7, 9, 10, 13, 27] or (byte >= 32 and byte <= 126): ascii.append(byte)
		pending += ascii.get_string_from_utf8()
		if flush: pending += "\n"
		var end := maxi(pending.rfind("\n"), pending.rfind("\r"))
		if end < 0:
			pending = pending.right(8192)
			return []
		var complete := ansi.sub(pending.left(end + 1), "", true)
		pending = pending.substr(end + 1).right(8192)
		var values: Array[float] = []
		for result in percentage.search_all(complete):
			var value := float(result.get_string(1))
			if value >= 0 and value <= 100: values.append(value)
		return values

# Pure functions are shared by the editor UI and offline planner tests.
class Planner:
	static func normalize(raw: Array, npu: Dictionary, storage: Dictionary) -> Dictionary:
		var models := {}
		for item in raw:
			if not item is Dictionary:
				continue
			var id := str(item.get("model_id", item.get("fullname", "")))
			if id.is_empty():
				continue
			var tags: Variant = item.get("tags", [])
			var tag: Dictionary = tags[0] if tags is Array and not tags.is_empty() and tags[0] is Dictionary else {}
			models[id] = {"id": id, "name": str(item.get("name", id)), "type": str(item.get("type", "")), "description": str(item.get("desc", "")), "supported": item.get("supported", []), "bytes": int(tag.get("size", -1)), "npu": float(item.get("npu_usage", -1)), "max_context": int(item.get("context_window", 0)) if item.get("context_window") != null else 0, "installed": str(item.get("status", "")) in ["downloaded", "running", "loaded"], "loaded": false, "build": str(tag.get("build_id", tag.get("version", ""))), "state": str(item.get("status", "unknown"))}
		var loaded := {}
		for item in npu.get("models", []):
			if not item is Dictionary:
				continue
			var id := str(item.get("model_id", ""))
			loaded[id] = float(item.get("npu_usage", -1))
			if models.has(id):
				models[id].loaded = true
				models[id].installed = true
		return {"models": models, "loaded": loaded, "npu_total": float(npu.get("npu_total", -1)), "npu_used": float(npu.get("npu_used", -1)), "disk_total": int(storage.get("total_bytes", -1)), "disk_free": int(storage.get("remaining_bytes", -1))}

	static func suitable(role: String, model: Dictionary) -> bool:
		if not ROLE_TYPES.get(role, []).has(model.get("type", "")): return false
		# The scripting model coordinates tools; a prompt enhancer is not a coordinator.
		return role != "coding_model" or model.get("supported", []).has("Tool Use")

	static func check(state: Dictionary, config: Dictionary, active_coding: String) -> Dictionary:
		var errors := PackedStringArray()
		var warnings := PackedStringArray()
		var actions: Array[Dictionary] = []
		var required: Array[String] = []
		var warm: Array[String] = []
		var models: Dictionary = state.get("models", {})
		var loaded: Dictionary = state.get("loaded", {})
		var roles: Dictionary = config.get("roles", {})
		for role in ROLE_TYPES:
			var selection: Dictionary = roles.get(role, {})
			var id := str(selection.get("model", ""))
			if id.is_empty():
				if role == "coding_model": errors.append("Choose a scripting model.")
				continue
			if not models.has(id) or not suitable(role, models[id]):
				errors.append("%s is not compatible with %s." % [id, ROLES[role]])
				continue
			if not required.has(id): required.append(id)
			if role == "coding_model" or bool(selection.get("warm", false)):
				if not warm.has(id): warm.append(id)
			if role == "coding_model":
				var context := int(selection.get("context", 0))
				if context < 2048 or models[id].max_context <= 0 or context > models[id].max_context:
					errors.append("Scripting context must fit the model's reported context window.")
		for id in config.get("extra_warm", []):
			if not models.has(id):
				errors.append("Unknown keep-loaded model: " + str(id))
				continue
			if not required.has(id): required.append(id)
			if not warm.has(id): warm.append(id)
		var coding_id := str(roles.get("coding_model", {}).get("model", ""))
		var reserve := float(config.get("npu_reserve", 5))
		var disk_reserve := float(config.get("disk_reserve_gib", 2)) * 1073741824.0
		if reserve < 0 or reserve > 50: errors.append("NPU reserve must be between 0 and 50 units.")
		if disk_reserve < 0: errors.append("SSD reserve cannot be negative.")
		var used := 0.0
		var added_bytes := 0.0
		var scratch_bytes := 0.0
		for id in warm:
			if models[id].npu < 0: errors.append("Unknown NPU allocation for " + id)
			else: used += models[id].npu
		for id in required:
			if not models[id].installed:
				if models[id].bytes <= 0:
					errors.append("Unknown download size for " + id)
				else:
					added_bytes += models[id].bytes
					scratch_bytes = maxf(scratch_bytes, models[id].bytes)
				actions.append({"verb": "download", "id": id})
		var known_used := 0.0
		for id in loaded:
			if float(loaded[id]) < 0: errors.append("Unknown running NPU allocation for " + str(id))
			else: known_used += float(loaded[id])
		var overhead := maxf(0, float(state.get("npu_used", -1)) - known_used)
		used += overhead
		var total := float(state.get("npu_total", -1))
		if total <= 0 or float(state.get("npu_used", -1)) < 0: errors.append("NPU capacity is unavailable.")
		elif used + reserve > total: errors.append("Keep-loaded models need %.0f NPU units plus %.0f reserved; only %.0f exist." % [used, reserve, total])
		if int(state.get("disk_free", -1)) < 0: errors.append("SSD free space is unavailable.")
		elif added_bytes + scratch_bytes + disk_reserve > float(state.disk_free): errors.append("SSD headroom is insufficient for downloads, staging allowance, and reserve.")
		# Keep the previous scripting model until the replacement has loaded.
		if loaded.has(active_coding) and active_coding != coding_id and models.has(coding_id):
			if models[coding_id].npu < 0 or float(loaded[active_coding]) + models[coding_id].npu + overhead + reserve > total:
				errors.append("The new and current scripting models cannot coexist during a protected switch. No model will be unloaded.")
		for id in loaded:
			if not warm.has(id) and id != active_coding: actions.append({"verb": "unload", "id": id})
		if not coding_id.is_empty() and models.has(coding_id) and not loaded.has(coding_id): actions.append({"verb": "load", "id": coding_id})
		if loaded.has(active_coding) and active_coding != coding_id and not warm.has(active_coding): actions.append({"verb": "unload", "id": active_coding})
		for id in warm:
			if id != coding_id and not loaded.has(id): actions.append({"verb": "load", "id": id})
		for id in required:
			if not warm.has(id) and models[id].npu >= 0 and used + models[id].npu + reserve > total:
				warnings.append("%s will be downloaded but cannot run alongside this whole warm set; it will require a different configuration." % models[id].name)
		warnings.append("Context is a client-side request budget. This SDK exposes no load-time context allocation control; reducing it does not reduce the model's NPU units.")
		warnings.append("NPU figures are device allocation units. SSD forecasts include one largest-download staging allowance; actual runtime and unpacking use must still be verified.")
		return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "actions": actions, "warm": warm, "required": required, "npu_projected": used, "npu_remaining": total - used, "download_bytes": added_bytes, "disk_projected_free": float(state.get("disk_free", 0)) - added_bytes, "disk_peak_free": float(state.get("disk_free", 0)) - added_bytes - scratch_bytes, "npu_reserve": reserve, "disk_reserve": disk_reserve}

func _ready() -> void:
	add_to_group("tiiny_setup_manager")
	var settings := EditorInterface.get_editor_settings()
	for obsolete in ["tiiny_ai/device/enable_model_management", "tiiny_ai/device/setup_complete"]:
		if settings.has_setting(obsolete): settings.erase(obsolete)
	var default_cli := OS.get_environment("HOME").path_join(".local/tiiny/bin/tiiny")
	if not FileAccess.file_exists(default_cli): default_cli = "tiiny"
	for entry in [["tiiny_ai/advanced/cli_path", default_cli], ["tiiny_ai/advanced/device_address", ""], ["tiiny_ai/models/configuration", ""], ["tiiny_ai/models/coding_model", CODING_DEFAULT], ["tiiny_ai/models/image_model", ""], ["tiiny_ai/models/image_to_3d_model", ""], ["tiiny_ai/models/music_model", ""], ["tiiny_ai/models/speech_model", ""], ["tiiny_ai/models/context_tokens", 8192]]:
		if not settings.has_setting(entry[0]): settings.set_setting(entry[0], entry[1])
	draft = {"roles": {}, "extra_warm": [], "npu_reserve": 5, "disk_reserve_gib": 2}
	for role in ROLES:
		draft.roles[role] = {"model": str(settings.get_setting("tiiny_ai/models/" + role)), "context": int(settings.get_setting("tiiny_ai/models/context_tokens")) if role == "coding_model" else 0, "warm": role == "coding_model"}
	if settings.has_setting("_tiiny_ai/applied_configuration"):
		var saved: Variant = settings.get_setting("_tiiny_ai/applied_configuration")
		if saved is Dictionary and saved.has("roles"):
			draft = saved.duplicate(true)
			draft_initialized = true
	# No downloads, loads, or unloads at startup. The settings panel requests a read-only refresh.

func create_configuration_panel() -> Control:
	var panel := ConfigurationPanel.new()
	panel.manager = self
	return panel

func is_ready() -> bool:
	var coding_id := str(EditorInterface.get_editor_settings().get_setting("tiiny_ai/models/coding_model"))
	return connected and not applying and snapshot.get("loaded", {}).has(coding_id)

func is_model_loaded(id: String) -> bool:
	return connected and not applying and snapshot.get("loaded", {}).has(id)

func _initialize_draft_from_snapshot() -> void:
	if draft_initialized: return
	draft_initialized = true
	var assigned: Array[String] = []
	for role in ROLES:
		var id := str(draft.roles[role].model)
		assigned.append(id)
		draft.roles[role].warm = role == "coding_model" or snapshot.loaded.has(id)
	for id in snapshot.loaded:
		if not assigned.has(id): draft.extra_warm.append(id)

func update_draft(value: Dictionary) -> void:
	if busy: return
	draft = value.duplicate(true)
	plan = {}
	message = "Configuration changed. Check Config before applying."
	changed.emit()

func _report(text: String) -> void:
	message = text
	log_message.emit("Tiiny models: " + text, 0)
	changed.emit()

func _connection() -> Dictionary:
	var settings := EditorInterface.get_editor_settings()
	var config_path := OS.get_environment("HOME").path_join(".local/tiiny/config.json")
	var config: Dictionary = {}
	if FileAccess.file_exists(config_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(config_path))
		if parsed is Dictionary: config = parsed
	var address := str(settings.get_setting("tiiny_ai/advanced/device_address")).strip_edges()
	if address.is_empty(): address = str(config.get("deviceAddress", "")).strip_edges()
	var key := str(settings.get_setting("tiiny_ai/advanced/api_key")).strip_edges()
	if key.is_empty(): key = OS.get_environment("TIINY_API_KEY").strip_edges()
	if key.is_empty(): key = str(config.get("account", {}).get("authKey", ""))
	if address.is_empty(): return {"error": "Set Device / Address or connect the Tiiny SDK first."}
	if key.is_empty(): return {"error": "Set the Tiiny API key or authenticate the SDK first."}
	if address.contains("/") or address.contains(" "):
		return {"error": "Device / Address must be a hostname or IP address, without a URL scheme or path."}
	if address.count(":") > 1 and not address.begins_with("["): address = "[" + address + "]"
	return {"base": "http://" + address.trim_suffix("/"), "key": key, "identity": (address + "|" + key).sha256_text()}

func _get_json(connection: Dictionary, path: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 12.0
	req.body_size_limit = 16 * 1024 * 1024
	add_child(req)
	var error := req.request(connection.base + path, ["Host: p8800.api.tiiny", "Authorization: Bearer " + connection.key])
	if error != OK:
		req.queue_free()
		return {"error": "Could not start the device request (%d)." % error}
	var result: Array = await req.request_completed
	req.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200: return {"error": "Device request failed (connection %d, HTTP %d)." % [result[0], result[1]]}
	var parsed: Variant = JSON.parse_string(result[3].get_string_from_utf8())
	if not parsed is Array and not parsed is Dictionary: return {"error": "The device returned invalid JSON."}
	return {"data": parsed}

func _fetch_snapshot() -> Dictionary:
	var connection := _connection()
	if connection.has("error"): return connection
	var raw := await _get_json(connection, "/api/v1/models/online_models")
	if raw.has("error"): return raw
	var npu := await _get_json(connection, "/api/v1/models/npu/status")
	if npu.has("error"): return npu
	var storage := await _get_json(connection, "/api/v1/sys/storage")
	if storage.has("error"): return storage
	if not raw.data is Array or not npu.data is Dictionary or not storage.data is Dictionary: return {"error": "Unsupported Tiiny inventory/capacity response."}
	var result := Planner.normalize(raw.data, npu.data, storage.data)
	result["connection"] = connection.identity
	result["time"] = Time.get_ticks_msec()
	return result

func refresh_device() -> void:
	if busy: return
	busy = true
	plan = {}
	_report("Reading catalog, loaded models, and SSD capacity…")
	var result := await _fetch_snapshot()
	busy = false
	if result.has("error"):
		connected = false
		_report(result.error + " No device changes were made.")
		return
	snapshot = result
	_initialize_draft_from_snapshot()
	connected = true
	_report("Device data refreshed. Choose changes, then Check Config.")

func check_config() -> void:
	if busy: return
	busy = true
	plan = {}
	_report("Checking configuration against fresh device state…")
	var result := await _fetch_snapshot()
	busy = false
	if result.has("error"):
		connected = false
		_report(result.error + " Apply is disabled.")
		return
	snapshot = result
	_initialize_draft_from_snapshot()
	connected = true
	plan = Planner.check(snapshot, draft, str(EditorInterface.get_editor_settings().get_setting("tiiny_ai/models/coding_model")))
	plan["draft"] = draft.duplicate(true)
	plan["checked_at"] = Time.get_ticks_msec()
	plan["connection"] = snapshot.connection
	_report("Check passed — review pending operations before Apply." if plan.ok else "Check failed — resolve the listed issues. No device changes were made.")

func apply_config() -> void:
	if busy or not plan.get("ok", false): return
	var assistant := get_tree().get_first_node_in_group("tiiny_ai_editor_dock")
	if assistant and assistant.has_method("is_inference_busy") and assistant.is_inference_busy():
		_report("Wait for the current chat/resource request to finish before applying model changes.")
		return
	if draft != plan.get("draft", {}) or Time.get_ticks_msec() - int(plan.get("checked_at", 0)) > PLAN_LIFETIME * 1000:
		plan = {}
		_report("Configuration check expired or changed. Check Config again.")
		return
	busy = true
	applying = true
	var approved := plan.duplicate(true)
	_report("Revalidating the approved plan…")
	var fresh := await _fetch_snapshot()
	if fresh.has("error") or fresh.get("connection") != approved.connection:
		await _apply_failed("Device changed or became unavailable. Check Config again.")
		return
	var settings := EditorInterface.get_editor_settings()
	var old_coding := str(settings.get_setting("tiiny_ai/models/coding_model"))
	var rechecked := Planner.check(fresh, approved.draft, old_coding)
	if not rechecked.ok or rechecked.actions != approved.actions:
		await _apply_failed("The plan changed since Check Config. Review a new check before applying.")
		return
	operation_log.clear()
	for action in rechecked.actions:
		_report("%s %s…" % [str(action.verb).capitalize(), action.id])
		operation_log.append("%s %s" % [action.verb, action.id])
		var exit_code := await _run_cli([action.verb, action.id])
		if exit_code != 0:
			await _apply_failed("Operation failed (%d). Earlier operations may have completed; refresh and check again." % exit_code)
			return
		var observed := await _fetch_snapshot()
		if observed.has("error"):
			await _apply_failed("Could not verify the device after an operation. Stopped; refresh before retrying.")
			return
		var verified := false
		if action.verb == "load": verified = observed.loaded.has(action.id)
		elif action.verb == "unload": verified = not observed.loaded.has(action.id)
		elif action.verb == "download": verified = observed.models.has(action.id) and observed.models[action.id].installed
		if not verified:
			await _apply_failed("Tiiny did not confirm the requested %s. Stopped before the next operation." % action.verb)
			return
		var protected_id: String = approved.draft.roles.coding_model.model if observed.loaded.has(approved.draft.roles.coding_model.model) else old_coding
		if fresh.loaded.has(old_coding) and not observed.loaded.has(protected_id):
			await _apply_failed("The scripting model became unavailable. Stopped; check and restore the configuration before continuing.")
			return
		snapshot = observed
	var final := await _fetch_snapshot()
	if final.has("error"):
		await _apply_failed("Could not verify the completed configuration.")
		return
	for id in rechecked.warm:
		if not final.loaded.has(id):
			await _apply_failed("Required model is not loaded: " + id)
			return
	snapshot = final
	connected = true
	for role in ROLES: settings.set_setting("tiiny_ai/models/" + role, approved.draft.roles[role].model)
	var coding_id: String = approved.draft.roles.coding_model.model
	settings.set_setting("tiiny_ai/models/coding_model_type", final.models[coding_id].type)
	settings.set_setting("tiiny_ai/models/context_tokens", approved.draft.roles.coding_model.context)
	settings.set_setting("_tiiny_ai/applied_configuration", approved.draft)
	busy = false
	applying = false
	plan = {}
	_report("Configuration applied and verified. Chat uses the selected scripting model and request context budget.")

func _apply_failed(reason: String) -> void:
	var current := await _fetch_snapshot()
	if not current.has("error"): snapshot = current
	connected = not current.has("error")
	busy = false
	applying = false
	plan = {}
	_report(reason)

static func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\"'\"'") + "'"

func _record_progress(arguments: Array, percent: float, source: String) -> void:
	if arguments.size() < 2 or percent < 0 or percent > 100: return
	var now := Time.get_ticks_msec()
	var previous: Dictionary = progress_reports.get(source, {})
	if not previous.is_empty() and int(previous.percent) == int(percent) and now - int(previous.time) < 10000: return
	progress_reports[source] = {"percent": percent, "time": now}
	var text := "%s %s · %.1f%% (%s) · %ds elapsed" % [str(arguments[0]).capitalize(), arguments[1], percent, source, int((now - operation_started) / 1000)]
	message = text
	operation_log.append(text)
	if operation_log.size() > 200: operation_log.remove_at(0)
	log_message.emit("Tiiny models: " + text, 0)
	# The panel reads the status without rebuilding controls for every update.

func _poll_download_progress(connection: Dictionary, arguments: Array) -> void:
	var result := await _get_json(connection, "/api/v1/models/online_models")
	if result.has("error") or not result.get("data") is Array: return
	for model in result.data:
		if model is Dictionary and str(model.get("model_id", model.get("fullname", ""))) == str(arguments[1]):
			var progress: Variant = model.get("progress")
			if progress is int or progress is float: _record_progress(arguments, float(progress), "device")
			return

func _drain_progress(process: Dictionary, reader: ProgressReader, arguments: Array) -> void:
	for pipe in [process.stdio, process.stderr]:
		for index in range(8):
			var bytes: PackedByteArray = pipe.get_buffer(8192)
			if bytes.is_empty(): break
			for value in reader.feed(bytes):
				# Download task totals come from device polling, not a per-file SDK bar.
				if arguments[0] != "download": _record_progress(arguments, value, "SDK")

func _run_cli(arguments: Array) -> int:
	if OS.get_name() != "Linux": return ERR_UNAVAILABLE
	var settings := EditorInterface.get_editor_settings()
	var connection := _connection()
	if connection.has("error"): return ERR_UNCONFIGURED
	# Explicit address pins CLI operations to the device whose plan was checked.
	var device: String = connection.base.trim_prefix("http://").trim_prefix("[").trim_suffix("]")
	var parts := PackedStringArray([_shell_quote(str(settings.get_setting("tiiny_ai/advanced/cli_path"))), "--device-address", _shell_quote(device), "-y"])
	for arg in arguments: parts.append(_shell_quote(str(arg)))
	var command := ["--signal=TERM", "--kill-after=5s", "3600s", "script", "-q", "-e", "-c", " ".join(parts), "/dev/null"]
	var process := OS.execute_with_pipe("timeout", PackedStringArray(command), false)
	if process.is_empty(): return ERR_CANT_FORK
	process_id = int(process.pid)
	progress_reports.clear()
	operation_started = Time.get_ticks_msec()
	var reader := ProgressReader.new()
	var next_poll := operation_started
	while OS.is_process_running(process_id):
		_drain_progress(process, reader, arguments)
		if arguments[0] == "download" and Time.get_ticks_msec() >= next_poll:
			await _poll_download_progress(connection, arguments)
			next_poll = Time.get_ticks_msec() + 3000
		await get_tree().create_timer(0.1).timeout
	_drain_progress(process, reader, arguments)
	for value in reader.feed(PackedByteArray(), true):
		if arguments[0] != "download": _record_progress(arguments, value, "SDK")
	var code := OS.get_process_exit_code(process_id)
	process_id = -1
	if arguments[0] == "download": await _poll_download_progress(connection, arguments)
	process.stdio.close()
	process.stderr.close()
	return code

func _exit_tree() -> void:
	if process_id > 0:
		# timeout forwards TERM to its subprocess group; do not block editor shutdown.
		OS.execute("kill", PackedStringArray(["-TERM", str(process_id)]))

class ConfigurationPanel extends VBoxContainer:
	var manager: Node
	var content: VBoxContainer
	var advanced_open := false
	var status_label: Label
	var rebuilding := false
	var age_label: Label
	var apply_button: Button

	func _ready() -> void:
		name = "Tiiny Model Management"
		content = VBoxContainer.new()
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.add_theme_constant_override("separation", 12)
		add_child(content)
		manager.changed.connect(_render)
		_render()
		if manager.snapshot.is_empty() and not manager.busy: manager.refresh_device.call_deferred()

	func _process(_delta: float) -> void:
		if is_instance_valid(age_label) and not manager.snapshot.is_empty():
			age_label.text = "Device snapshot age: %ds%s" % [int((Time.get_ticks_msec() - int(manager.snapshot.time)) / 1000), " · stale/unavailable" if not manager.connected else ""]
		if is_instance_valid(status_label): status_label.text = manager.message
		if is_instance_valid(apply_button):
			var expired := Time.get_ticks_msec() - int(manager.plan.get("checked_at", 0)) > PLAN_LIFETIME * 1000
			apply_button.disabled = manager.busy or not manager.plan.get("ok", false) or expired
			apply_button.text = "Check expired" if manager.plan.get("ok", false) and expired else "Apply"

	func _label(text: String, parent: Node = content) -> Label:
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		parent.add_child(label)
		return label

	func _button(text: String, callback: Callable, parent: Node) -> Button:
		var button := Button.new()
		button.text = text
		button.disabled = manager.busy
		button.pressed.connect(callback)
		parent.add_child(button)
		return button

	# Table labels must retain a readable minimum width. Autowrap labels have
	# almost no horizontal minimum, which lets GridContainer crush a column.
	func _cell(text: String, column: int, parent: Node, heading := false) -> Label:
		var label := Label.new()
		label.text = text
		label.tooltip_text = text
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.custom_minimum_size.x = [150, 240, 84, 112, 86, 78, 100, 108, 56][column]
		label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if heading: label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.83))
		parent.add_child(label)
		return label

	func _capacity(text: String, used: float, total: float, parent: Node) -> void:
		_label(text, parent)
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.custom_minimum_size.y = 12
		bar.max_value = maxf(total, 1)
		bar.value = maxf(used, 0)
		parent.add_child(bar)

	static func _size(bytes: float) -> String:
		return "Unknown" if bytes < 0 else "%.1f GiB" % (bytes / 1073741824.0)

	func _render() -> void:
		if not is_inside_tree() or rebuilding: return
		rebuilding = true
		for child in content.get_children():
			content.remove_child(child)
			child.queue_free()
		var snapshot: Dictionary = manager.snapshot
		var models: Dictionary = snapshot.get("models", {})
		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 12)
		content.add_child(header)
		var title := _label("Tiiny Model Management", header)
		title.add_theme_font_size_override("font_size", 18)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var connection := _label("Connected" if manager.connected else "Not connected", header)
		connection.autowrap_mode = TextServer.AUTOWRAP_OFF
		connection.add_theme_color_override("font_color", Color(0.65, 0.85, 0.7) if manager.connected else Color(0.9, 0.7, 0.5))
		_button("Refresh", manager.refresh_device, header)
		if not snapshot.is_empty():
			var capacity_row := HBoxContainer.new()
			capacity_row.add_theme_constant_override("separation", 24)
			content.add_child(capacity_row)
			var npu_box := VBoxContainer.new()
			npu_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			capacity_row.add_child(npu_box)
			var ssd_box := VBoxContainer.new()
			ssd_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			capacity_row.add_child(ssd_box)
			var total := float(snapshot.npu_total)
			_capacity("NPU · %.0f / %.0f units free" % [total - snapshot.npu_used, total], snapshot.npu_used, total, npu_box)
			_capacity("SSD · %s free / %s" % [_size(snapshot.disk_free), _size(snapshot.disk_total)], float(snapshot.disk_total) - float(snapshot.disk_free), snapshot.disk_total, ssd_box)
			if not manager.plan.is_empty():
				var forecast: Dictionary = manager.plan
				_capacity("After Apply · %.0f free / %.0f reserved" % [forecast.npu_remaining, forecast.npu_reserve], forecast.npu_projected, total, npu_box)
				_capacity("After downloads · %s free" % _size(forecast.disk_projected_free), float(snapshot.disk_total) - forecast.disk_projected_free, snapshot.disk_total, ssd_box)
			age_label = _label("")
		content.add_child(HSeparator.new())
		var scroll := ScrollContainer.new()
		scroll.name = "ModelTableScroll"
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		content.add_child(scroll)
		var grid := GridContainer.new()
		grid.name = "ModelTable"
		grid.columns = 9
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 8)
		scroll.add_child(grid)
		var headings := ["Task", "Model", "Context", "Tok/s", "SSD size", "NPU units", "Keep loaded", "On device", ""]
		for column in range(headings.size()): _cell(headings[column], column, grid, true)
		for role in ROLES:
			var selection: Dictionary = manager.draft.roles[role]
			var id := str(selection.model)
			var model: Dictionary = models.get(id, {})
			_cell(ROLES[role], 0, grid)
			var picker := OptionButton.new()
			picker.custom_minimum_size.x = 240
			picker.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			picker.clip_text = true
			picker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			picker.fit_to_longest_item = false
			picker.add_item("Choose model" if role == "coding_model" else "None")
			picker.set_item_metadata(0, "")
			var candidates: Array = models.keys()
			candidates.sort()
			for candidate in candidates:
				if not Planner.suitable(role, models[candidate]): continue
				picker.add_item(models[candidate].name + (" · installed" if models[candidate].installed else " · download"))
				picker.set_item_metadata(picker.item_count - 1, candidate)
				picker.set_item_tooltip(picker.item_count - 1, candidate + "\n" + str(models[candidate].description).left(1200))
				if candidate == id: picker.select(picker.item_count - 1)
			picker.disabled = manager.busy
			picker.item_selected.connect(func(index: int): _choose_model(role, str(picker.get_item_metadata(index))))
			grid.add_child(picker)
			var context := OptionButton.new()
			context.custom_minimum_size.x = 84
			context.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			context.tooltip_text = "Client-side request budget. Does not change Tiiny runtime allocation."
			context.add_item("—")
			context.set_item_metadata(0, 0)
			if role == "coding_model" and not model.is_empty():
				context.clear()
				for count in [2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144]:
					if count > int(model.max_context): continue
					context.add_item("%dK" % (count / 1024))
					context.set_item_metadata(context.item_count - 1, count)
					if count == int(selection.context): context.select(context.item_count - 1)
			context.disabled = manager.busy or role != "coding_model" or model.is_empty()
			context.item_selected.connect(func(index: int): _choose_context(role, int(context.get_item_metadata(index))))
			grid.add_child(context)
			_cell("Not measured", 3, grid).tooltip_text = "No comparable on-device token benchmark is available; catalog claims are not measurements."
			_cell(_size(float(model.get("bytes", -1))), 4, grid)
			_cell("—" if model.is_empty() else str(model.npu), 5, grid)
			var warm := CheckBox.new()
			warm.custom_minimum_size.x = 100
			warm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			warm.button_pressed = role == "coding_model" or bool(selection.warm) or manager.draft.extra_warm.has(id)
			warm.disabled = manager.busy or role == "coding_model" or id.is_empty()
			warm.tooltip_text = "Scripting is always kept loaded." if role == "coding_model" else "Desired state after Apply. Actual loaded state is shown separately."
			warm.toggled.connect(func(value: bool): _choose_warm(role, value))
			grid.add_child(warm)
			_cell("Loaded" if model.get("loaded", false) else "Installed" if model.get("installed", false) else "Not installed" if not id.is_empty() else "—", 7, grid)
			var info_button := _button("Info", _show_model_info.bind(id), grid)
			info_button.disabled = id.is_empty()
			info_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var assigned: Array[String] = []
		for role in ROLES: assigned.append(str(manager.draft.roles[role].model))
		for id in models:
			if not models[id].installed or assigned.has(id): continue
			_cell("Other installed", 0, grid)
			var name_label := _cell(str(models[id].name), 1, grid)
			name_label.tooltip_text = id
			_cell("—", 2, grid)
			_cell("—", 3, grid)
			_cell(_size(models[id].bytes), 4, grid)
			_cell(str(models[id].npu), 5, grid)
			var extra := CheckBox.new()
			extra.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			extra.custom_minimum_size.x = 100
			extra.button_pressed = manager.draft.extra_warm.has(id)
			extra.disabled = manager.busy
			extra.toggled.connect(func(value: bool): _choose_extra(id, value))
			grid.add_child(extra)
			_cell("Loaded" if models[id].loaded else "Installed", 7, grid)
			var info_button := _button("Info", _show_model_info.bind(id), grid)
			info_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var advanced := FoldableContainer.new()
		advanced.name = "AdvancedHeadroom"
		advanced.title = "Advanced headroom"
		advanced.folded = not advanced_open
		advanced.folding_changed.connect(func(folded: bool): advanced_open = not folded)
		content.add_child(advanced)
		var advanced_body := VBoxContainer.new()
		advanced.add_child(advanced_body)
		var reserves := HBoxContainer.new()
		advanced_body.add_child(reserves)
		_cell("Reserve NPU", 0, reserves)
		var npu_reserve := SpinBox.new()
		npu_reserve.min_value = 0
		npu_reserve.max_value = 50
		npu_reserve.value = manager.draft.npu_reserve
		npu_reserve.editable = not manager.busy
		npu_reserve.value_changed.connect(func(value: float): _choose_reserve("npu_reserve", value))
		reserves.add_child(npu_reserve)
		_cell("SSD reserve (GiB)", 0, reserves)
		var ssd_reserve := SpinBox.new()
		ssd_reserve.min_value = 0
		ssd_reserve.max_value = 100
		ssd_reserve.value = manager.draft.disk_reserve_gib
		ssd_reserve.editable = not manager.busy
		ssd_reserve.value_changed.connect(func(value: float): _choose_reserve("disk_reserve_gib", value))
		reserves.add_child(ssd_reserve)
		_label("Leave this capacity unused after Apply. Changes invalidate Check Config.", advanced_body)
		var plan_box := VBoxContainer.new()
		plan_box.name = "ConfigurationPlan"
		content.add_child(plan_box)
		if not manager.plan.is_empty():
			var plan: Dictionary = manager.plan
			var plan_header := HBoxContainer.new()
			plan_box.add_child(plan_header)
			var heading := _label("Change plan · %d operations" % plan.actions.size(), plan_header)
			heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_button("Details", _show_plan_details, plan_header)
			for error in plan.errors:
				_label(error, plan_box).add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
			if plan.actions.is_empty():
				_label("No model operations. Apply saves the checked configuration.", plan_box)
			else:
				var operations := Tree.new()
				operations.name = "PendingOperations"
				operations.columns = 2
				operations.hide_root = true
				operations.custom_minimum_size.y = clampi(plan.actions.size() * 28 + 8, 64, 160)
				operations.set_column_custom_minimum_width(0, 100)
				operations.set_column_expand(0, false)
				var root := operations.create_item()
				for action in plan.actions:
					var item := operations.create_item(root)
					item.set_text(0, str(action.verb).capitalize())
					item.set_text(1, str(action.id))
				plan_box.add_child(operations)
		status_label = _label(manager.message)
		status_label.name = "ConfigurationStatus"
		var actions := HBoxContainer.new()
		content.add_child(actions)
		actions.add_spacer(false)
		_button("Check Config", manager.check_config, actions)
		var apply := _button("Apply", manager.apply_config, actions)
		apply_button = apply
		apply.disabled = manager.busy or not manager.plan.get("ok", false)
		apply.tooltip_text = "Apply rechecks the device before executing the reviewed plan. Any draft edit invalidates the check."
		rebuilding = false

	func _show_information(title: String, text: String) -> void:
		var dialog := AcceptDialog.new()
		dialog.name = "ModelInformation"
		dialog.title = title
		var body := RichTextLabel.new()
		body.bbcode_enabled = false
		body.text = text
		body.custom_minimum_size = Vector2(480, 300)
		dialog.add_child(body)
		add_child(dialog)
		dialog.visibility_changed.connect(func():
			if not dialog.visible: dialog.queue_free())
		dialog.popup_centered_clamped(Vector2i(600, 420), 0.8)

	func _show_model_info(id: String) -> void:
		var model: Dictionary = manager.snapshot.get("models", {}).get(id, {})
		if model.is_empty(): return
		_show_information(str(model.name), "%s\n%s\nCapabilities: %s\nMaximum context: %s\n\n%s\n\nContext in this screen limits chat requests; it does not reconfigure Tiiny memory. Token/s is shown only when measured." % [id, model.type, ", ".join(model.supported), model.max_context, model.description])

	func _show_plan_details() -> void:
		var plan: Dictionary = manager.plan
		if plan.is_empty(): return
		_show_information("Plan details", "NPU after Apply: %.0f units used / %.0f free (%.0f left unused)\nDownloads: %s\nSSD after downloads: %s free\nSSD at peak staging: %s free\nSSD reserve: %s\n\n%s" % [plan.npu_projected, plan.npu_remaining, plan.npu_reserve, _size(plan.download_bytes), _size(plan.disk_projected_free), _size(plan.disk_peak_free), _size(plan.disk_reserve), "\n\n".join(plan.warnings)])

	func _choose_model(role: String, id: String) -> void:
		var config: Dictionary = manager.draft.duplicate(true)
		config.roles[role].model = id
		if role == "coding_model": config.roles[role].context = mini(8192, int(manager.snapshot.models.get(id, {}).get("max_context", 0)))
		manager.update_draft(config)

	func _choose_context(role: String, count: int) -> void:
		var config: Dictionary = manager.draft.duplicate(true)
		config.roles[role].context = count
		manager.update_draft(config)

	func _choose_warm(role: String, value: bool) -> void:
		var config: Dictionary = manager.draft.duplicate(true)
		config.roles[role].warm = value
		if not value: config.extra_warm.erase(str(config.roles[role].model))
		manager.update_draft(config)

	func _choose_extra(id: String, value: bool) -> void:
		var config: Dictionary = manager.draft.duplicate(true)
		if value and not config.extra_warm.has(id): config.extra_warm.append(id)
		elif not value: config.extra_warm.erase(id)
		manager.update_draft(config)

	func _choose_reserve(key: String, value: float) -> void:
		var config: Dictionary = manager.draft.duplicate(true)
		config[key] = value
		manager.update_draft(config)
)TIINY_GD";

#endif
