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
const SNAPSHOT_LIFETIME := 60.0
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
var device_lease := ""
var device_lease_owner: Node
var connection_identity := ""
var last_error_type := ""
var model_job_id := ""
var external_model_job_id := ""
var model_job_result: Dictionary = {}
var model_job_cancelled := false
var model_job_checkpoint_failed := false
var next_restore_check_msec := 0
var current_operation: Dictionary = {}
var current_progress := 0.0
var last_operation_failed := false
var last_busy_report_msec := 0

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

	static func schedule(state: Dictionary, config: Dictionary, role: String, requested: String, active_coding: String) -> Dictionary:
		var errors := PackedStringArray()
		var warnings := PackedStringArray()
		var temporary: Array[Dictionary] = []
		var models: Dictionary = state.get("models", {})
		var loaded: Dictionary = state.get("loaded", {})
		var roles: Dictionary = config.get("roles", {})
		var coding_id := str(roles.get("coding_model", {}).get("model", ""))
		if coding_id.is_empty() and not active_coding.is_empty(): coding_id = active_coding
		if coding_id.is_empty() or not models.has(coding_id):
			errors.append("Choose a compatible scripting model before scheduling specialized work.")
		elif not suitable("coding_model", models[coding_id]):
			errors.append("The configured scripting model is not compatible with tool use.")
		if requested.is_empty() or not models.has(requested):
			errors.append("Unknown model: " + requested)
		elif not suitable(role, models[requested]):
			errors.append("%s is not compatible with %s." % [requested, ROLES.get(role, role)])
		if not errors.is_empty():
			return {"ok": false, "errors": errors, "warnings": warnings, "temporary": [], "restore": [], "restore_ok": false, "restore_errors": PackedStringArray(), "requested": requested, "role": role, "coding": coding_id}
		if loaded.has(requested):
			warnings.append("%s is already loaded; no device changes are needed." % requested)
			return {"ok": true, "errors": errors, "warnings": warnings, "temporary": [], "restore": [], "restore_ok": true, "restore_errors": PackedStringArray(), "requested": requested, "role": role, "coding": coding_id, "protected": coding_id, "npu_projected": float(state.get("npu_used", -1))}
		var reserve := float(config.get("npu_reserve", 5))
		var disk_reserve := float(config.get("disk_reserve_gib", 2)) * 1073741824.0
		if reserve < 0 or reserve > 50: errors.append("NPU reserve must be between 0 and 50 units.")
		if disk_reserve < 0: errors.append("SSD reserve cannot be negative.")
		var total := float(state.get("npu_total", -1))
		var npu_used := float(state.get("npu_used", -1))
		if total <= 0 or npu_used < 0: errors.append("NPU capacity is unavailable.")
		var known_used := 0.0
		for id in loaded:
			if float(loaded[id]) < 0: errors.append("Unknown running NPU allocation for " + str(id))
			else: known_used += float(loaded[id])
		var overhead := maxf(0, npu_used - known_used)
		var model: Dictionary = models[requested]
		var allocation := float(model.get("npu", -1))
		if allocation < 0: errors.append("Unknown NPU allocation for " + requested)
		var coding_units := 0.0
		if loaded.has(coding_id) and float(loaded[coding_id]) >= 0: coding_units += float(loaded[coding_id])
		if active_coding != coding_id and loaded.has(active_coding) and float(loaded[active_coding]) >= 0: coding_units += float(loaded[active_coding])
		if total > 0 and allocation >= 0 and npu_used >= 0 and overhead + coding_units + allocation + reserve > total:
			errors.append("%s needs %.0f NPU units while retaining the scripting model (%.0f protected, %.0f reserved); only %.0f exist. No model will be unloaded." % [requested, overhead + coding_units + allocation + reserve, coding_units, reserve, total])
		var added_bytes := 0.0
		var scratch_bytes := 0.0
		if not model.get("installed", false):
			if model.bytes <= 0: errors.append("Unknown download size for " + requested)
			else:
				added_bytes += model.bytes
				scratch_bytes = model.bytes
		if int(state.get("disk_free", -1)) < 0: errors.append("SSD free space is unavailable.")
		elif added_bytes + scratch_bytes + disk_reserve > float(state.get("disk_free", 0)): errors.append("SSD headroom is insufficient for " + requested + ".")
		if not errors.is_empty():
			return {"ok": false, "errors": errors, "warnings": warnings, "temporary": [], "restore": [], "restore_ok": false, "restore_errors": PackedStringArray(), "requested": requested, "role": role, "coding": coding_id}
		for id in loaded:
			if id != requested and id != coding_id and id != active_coding:
				temporary.append({"verb": "unload", "id": id})
		if not model.get("installed", false): temporary.append({"verb": "download", "id": requested})
		if not loaded.has(requested): temporary.append({"verb": "load", "id": requested})
		# Simulate the temporary set, then let the normal planner derive the
		# exact actions that restore the configured warm set.
		var post := state.duplicate(true)
		var post_loaded := {}
		for id in loaded:
			var removed := false
			for action in temporary:
				if action.verb == "unload" and action.id == id:
					removed = true
					break
			if not removed: post_loaded[id] = loaded[id]
		post_loaded[requested] = allocation
		post["loaded"] = post_loaded
		var post_used := overhead
		for id in post_loaded: post_used += float(post_loaded[id])
		post["npu_used"] = post_used
		var restore := check(post, config, active_coding)
		if not restore.ok:
			errors.append_array(restore.errors)
			warnings.append_array(restore.warnings)
			return {"ok": false, "errors": errors, "warnings": warnings, "temporary": [], "restore": [], "restore_ok": false, "restore_errors": restore.errors, "requested": requested, "role": role, "coding": coding_id}
		warnings.append_array(restore.warnings)
		return {"ok": true, "errors": errors, "warnings": warnings, "temporary": temporary, "restore": restore.actions, "restore_ok": true, "restore_errors": PackedStringArray(), "requested": requested, "role": role, "coding": coding_id, "protected": coding_id, "npu_projected": overhead + coding_units + allocation + reserve}

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
		if _valid_saved_draft(saved):
			draft = saved.duplicate(true)
			draft_initialized = true
		else:
			_report("Saved model configuration is invalid. Review Models and Check Config; no device changes were made.")
	_verify_coding_model_stability(settings)
	# A previously applied configuration authorizes restoring its coding model.
	# The first check runs after the Jobs service has entered the tree.
	next_restore_check_msec = Time.get_ticks_msec() + 1000

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() < next_restore_check_msec or busy or applying or not model_job_id.is_empty(): return
	next_restore_check_msec = Time.get_ticks_msec() + 30000
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting("_tiiny_ai/applied_configuration") or not _valid_saved_draft(settings.get_setting("_tiiny_ai/applied_configuration")): return
	var connection := _connection()
	if connection.has("error"): return
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	if service == null or not service.get("available") or service.get("queue") == null: return
	for job in service.queue.snapshot().jobs:
		if job.state in ["queued", "running"]: return
		if job.state == "interrupted" and not job.attempts.is_empty() and job.attempts.back().get("device_started", false): return
	_refresh_snapshot(true, true)

static func _valid_saved_draft(saved: Variant) -> bool:
	if not saved is Dictionary or not saved.get("roles") is Dictionary or not saved.get("extra_warm") is Array: return false
	for role in ROLES:
		var choice: Variant = saved.roles.get(role)
		if not choice is Dictionary or not choice.get("model") is String or not choice.get("warm") is bool: return false
		var context: Variant = choice.get("context")
		if not (context is int or context is float) or not is_finite(float(context)) or float(context) != floorf(float(context)): return false
	for id in saved.extra_warm:
		if not id is String: return false
	return (saved.get("npu_reserve") is int or saved.get("npu_reserve") is float) and (saved.get("disk_reserve_gib") is int or saved.get("disk_reserve_gib") is float)

static func _valid_approved_configuration(value: Variant) -> bool:
	if not value is Dictionary or not _valid_saved_draft(value.get("draft")) or not value.get("actions") is Array or value.actions.size() > 128:
		return false
	if not value.get("active_coding") is String or not value.get("connection") is String or value.connection.length() != 64 or not value.connection.is_valid_hex_number(false):
		return false
	for action in value.actions:
		if not action is Dictionary or action.size() != 2 or action.get("verb") not in ["download", "load", "unload"] or not action.get("id") is String or action.id.is_empty() or action.id.length() > 512:
			return false
	return true

# Verify the saved coding model catalog stability without triggering device mutations.
# If the coding model is no longer in the catalog or incompatible, warn without unloading.
# This preserves user configuration while preventing silent degradation.
static func _coding_model_status(coding_id: String, catalog: Dictionary, saved_draft: Variant) -> String:
	if coding_id.is_empty(): return "No coding model configured."
	if catalog.is_empty(): return "Refresh device data to verify the saved coding model."
	if not catalog.has(coding_id): return "Saved coding model is not in the current catalog. Apply will restore it when available."
	var entry: Variant = catalog[coding_id]
	if not entry is Dictionary or str(entry.get("type", "")).is_empty():
		return "Coding model catalog entry is invalid. Apply will verify capabilities."
	if not ROLE_TYPES.coding_model.has(str(entry.get("type", ""))):
		return "Saved coding model is no longer compatible with scripting. Choose a compatible model in Models."
	if not entry.get("supported", []) is Array or not entry.get("supported", []).has("Tool Use"):
		return "Saved coding model does not declare Tool Use. Choose a scripting model with Tool Use in Models."
	if _valid_saved_draft(saved_draft) and saved_draft.roles.get("coding_model", {}).get("model", "") != coding_id:
		return "Coding model changed since last Apply. Re-check and re-apply to verify capabilities."
	return "Coding model stable; apply to verify on-device state."

static func _verify_coding_model_stability(settings) -> void:
	var coding_id := str(settings.get_setting("tiiny_ai/models/coding_model"))
	var cached: Variant = settings.get_setting("_tiiny_ai/catalog_cache")
	var catalog: Dictionary = cached if cached is Dictionary else {}
	var saved_draft: Variant = settings.get_setting("_tiiny_ai/applied_configuration")
	settings.set_setting("_tiiny_ai/coding_model_status", _coding_model_status(coding_id, catalog, saved_draft))

# Keep the last observed capability shape so startup can explain when a saved
# coding model disappeared or lost Tool Use without contacting the device.
static func _catalog_cache(models: Dictionary) -> Dictionary:
	var cache := {}
	for id in models:
		var model: Dictionary = models[id] if models[id] is Dictionary else {}
		cache[str(id)] = {"name": str(model.get("name", id)), "type": str(model.get("type", "")), "supported": model.get("supported", []) if model.get("supported", []) is Array else []}
	return cache

func create_configuration_panel() -> Control:
	var panel := ConfigurationPanel.new()
	panel.manager = self
	return panel

func is_ready() -> bool:
	var coding_id := str(EditorInterface.get_editor_settings().get_setting("tiiny_ai/models/coding_model"))
	return is_model_loaded(coding_id) and Planner.suitable("coding_model", snapshot.get("models", {}).get(coding_id, {}))

func is_model_loaded(id: String) -> bool:
	if not connected or busy or applying or id.is_empty() or connection_identity.is_empty(): return false
	if not model_job_id.is_empty(): return false
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	if service != null and service.get("queue") != null:
		if service.has_method("device_uncertainty_blocks_readiness") and service.device_uncertainty_blocks_readiness(): return false
		for job in service.queue.snapshot().jobs:
			if job.state == "interrupted" and not job.attempts.is_empty() and job.attempts.back().get("device_started", false):
				return false
	if Time.get_ticks_msec() - int(snapshot.get("time", -100000)) > SNAPSHOT_LIFETIME * 1000: return false
	var current := _connection()
	return not current.has("error") and current.identity == connection_identity and snapshot.get("connection", "") == connection_identity and snapshot.get("loaded", {}).has(id)

# Read-only state for the Models panel. The UI must not parse status messages.
func operation_state() -> Dictionary:
	var age := -1
	if not snapshot.is_empty(): age = maxi(0, int((Time.get_ticks_msec() - int(snapshot.get("time", 0))) / 1000))
	var tail: Array = []
	for index in range(maxi(0, operation_log.size() - 8), operation_log.size()): tail.append(operation_log[index])
	return {"busy": busy, "applying": applying, "connected": connected, "error_type": last_error_type, "snapshot_age": age, "fresh": connected and age >= 0 and age * 1000 <= SNAPSHOT_LIFETIME * 1000, "verb": str(current_operation.get("verb", "")), "model": str(current_operation.get("id", "")), "progress": current_progress, "elapsed": 0 if operation_started == 0 else maxi(0, int((Time.get_ticks_msec() - operation_started) / 1000)), "log_tail": tail, "failed": last_operation_failed, "status": message}

func has_unapplied_changes() -> bool:
	if not Engine.is_editor_hint(): return false
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting("_tiiny_ai/applied_configuration"): return false
	var saved: Variant = settings.get_setting("_tiiny_ai/applied_configuration")
	return _valid_saved_draft(saved) and saved != draft

func _set_operation(verb: String, id: String) -> void:
	current_operation = {"verb": verb, "id": id}
	current_progress = 0.0

static func _classify_error(text: String) -> String:
	var lower := text.to_lower()
	if "auth" in lower or "http 401" in lower or "http 403" in lower: return "auth"
	if "capacity" in lower or "insufficient" in lower or "npu" in lower or "ssd" in lower: return "capacity"
	if "could not start" in lower or "device request failed" in lower or "connection" in lower: return "disconnect"
	return "unknown"

func _error_description(error: String) -> String:
	match _classify_error(error):
		"auth": return "Tiiny authentication failed. Check the API key and refresh."
		"disconnect": return "Tiiny is unavailable. Check the device connection and refresh."
		"capacity": return "Tiiny capacity is unavailable or insufficient. " + error
		_: return error

func _accept_snapshot(value: Dictionary) -> bool:
	var current := _connection()
	if current.has("error") or value.get("connection", "") != current.get("identity", ""):
		connected = false
		connection_identity = ""
		last_error_type = "changed"
		return false
	snapshot = value
	connection_identity = str(value.connection)
	snapshot["connection_identity"] = connection_identity
	connected = true
	last_error_type = ""
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("_tiiny_ai/catalog_cache", _catalog_cache(value.get("models", {})))
	_verify_coding_model_stability(settings)
	return true

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

func _report_busy() -> void:
	var now := Time.get_ticks_msec()
	if now - last_busy_report_msec < 5000:
		return
	last_busy_report_msec = now
	_report("Tiiny is busy with another request; try again when it finishes.")

func _acquire_device(purpose: String) -> bool:
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	if service == null or not service.has_method("acquire_device"):
		return false
	var token: String = service.acquire_device(self, purpose)
	if token.is_empty():
		return false
	device_lease_owner = service
	device_lease = token
	return true

func _release_device() -> void:
	if not device_lease.is_empty() and is_instance_valid(device_lease_owner):
		if not device_lease_owner.release_device(self, device_lease): return
	device_lease = ""
	device_lease_owner = null

func _connection() -> Dictionary:
	var settings := EditorInterface.get_editor_settings()
	var config_path := OS.get_environment("HOME").path_join(".local/tiiny/config.json")
	var config: Dictionary = {}
	if FileAccess.file_exists(config_path):
		var parser := JSON.new()
		var parsed: Variant = parser.data if parser.parse(FileAccess.get_file_as_string(config_path)) == OK else null
		if parsed is Dictionary: config = parsed
	var address := str(settings.get_setting("tiiny_ai/advanced/device_address")).strip_edges()
	if address.is_empty(): address = str(config.get("deviceAddress", "")).strip_edges()
	var key := str(settings.get_setting("tiiny_ai/advanced/api_key")).strip_edges()
	if key.is_empty(): key = OS.get_environment("TIINY_API_KEY").strip_edges()
	if key.is_empty(): key = str(config.get("account", {}).get("authKey", ""))
	if address.is_empty(): return {"error": "Set Advanced / Device Address or connect the Tiiny SDK first."}
	if key.is_empty(): return {"error": "Set the Tiiny API key or authenticate the SDK first."}
	if address.contains("/") or address.contains(" "):
		return {"error": "Advanced / Device Address must be a hostname or IP address, without a URL scheme or path."}
	if address.count(":") > 1 and not address.begins_with("["): address = "[" + address + "]"
	return {"base": "http://" + address.trim_suffix("/"), "key": key, "identity": (address + "|" + key).sha256_text()}

func inference_connection() -> Dictionary:
	var connection := _connection()
	if connection.has("error"): return connection
	var url := str(EditorInterface.get_editor_settings().get_setting("tiiny_ai/advanced/api_url")).strip_edges().trim_suffix("/")
	if url == "http://openai.api.tiiny/v1":
		return {"url": connection.base + "/v1", "key": connection.key, "host": "openai.api.tiiny"}
	if not (url.begins_with("http://") or url.begins_with("https://")) or url.get_slice("/", 2) != connection.base.get_slice("/", 2):
		return {"error": "API URL must address the configured Tiiny device, or use http://openai.api.tiiny/v1."}
	return {"url": url, "key": connection.key, "host": ""}

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
	var parser := JSON.new()
	var parsed: Variant = parser.data if parser.parse(result[3].get_string_from_utf8()) == OK else null
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
	for record in raw.data:
		if not record is Dictionary or not record.get("model_id", record.get("fullname")) is String or not record.get("supported", []) is Array:
			return {"error": "Malformed Tiiny catalog record."}
	if not npu.data.get("models") is Array: return {"error": "Malformed loaded-model inventory."}
	for record in npu.data.models:
		if not record is Dictionary or not record.get("model_id") is String or not (record.get("npu_usage") is int or record.get("npu_usage") is float): return {"error": "Malformed loaded-model record."}
	for pair in [[npu.data, "npu_total"], [npu.data, "npu_used"], [storage.data, "total_bytes"], [storage.data, "remaining_bytes"]]:
		var value: Variant = pair[0].get(pair[1])
		if not (value is int or value is float) or not is_finite(float(value)) or value < 0: return {"error": "Missing or invalid device capacity."}
	if npu.data.npu_total <= 0 or npu.data.npu_used > npu.data.npu_total or storage.data.remaining_bytes > storage.data.total_bytes: return {"error": "Inconsistent device capacity."}
	var result := Planner.normalize(raw.data, npu.data, storage.data)
	result["connection"] = connection.identity
	result["time"] = Time.get_ticks_msec()
	return result

func refresh_device(keep_plan := false) -> void:
	await _refresh_snapshot(keep_plan)

# A job preflight refreshes observed state before considering restoration. It
# must not enqueue another restore behind the job currently occupying FIFO.
func refresh_for_preflight() -> void:
	await _refresh_snapshot(true, true, false)

# Inference needs a recent device snapshot. Revalidate automatically rather than
# requiring a manual Refresh, while leaving a pending Check Config plan intact.
func ensure_ready() -> bool:
	if is_ready():
		return true
	if busy or applying:
		return false
	await _refresh_snapshot(true)
	return is_ready()

func _refresh_snapshot(keep_plan: bool, quiet := false, schedule_restore := true) -> void:
	if busy: return
	if not _acquire_device("refresh models"):
		if not quiet:
			_report_busy()
		return
	busy = true
	if not keep_plan: plan = {}
	_report("Reading catalog, loaded models, and SSD capacity…")
	var result := await _fetch_snapshot()
	busy = false
	_release_device()
	if result.has("error"):
		connected = false
		connection_identity = ""
		last_error_type = _classify_error(str(result.error))
		snapshot = {}
		_report(_error_description(str(result.error)) + " No device changes were made.")
		return
	if not _accept_snapshot(result):
		_report("Device connection changed during refresh. Refresh again.")
		return
	_initialize_draft_from_snapshot()
	_report("Device data refreshed. Choose changes, then Check Config.")
	if schedule_restore:
		_schedule_coding_restore()

func _saved_coding_model() -> String:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting("_tiiny_ai/applied_configuration"): return ""
	var saved: Variant = settings.get_setting("_tiiny_ai/applied_configuration")
	if not _valid_saved_draft(saved): return ""
	var id := str(saved.roles.coding_model.model)
	return id if not id.is_empty() and id == str(settings.get_setting("tiiny_ai/models/coding_model")) else ""

func _loaded_coding_model() -> String:
	var ids: Array = snapshot.get("loaded", {}).keys()
	ids.sort()
	for id in ids:
		if Planner.suitable("coding_model", snapshot.get("models", {}).get(id, {})):
			return str(id)
	return ""

# The device may already run a different compatible coding model (for example
# after another application or a manual load). Adopt it instead of evicting it
# to restore an older saved selection.
func _adopt_loaded_coding_model(id: String) -> void:
	var settings := EditorInterface.get_editor_settings()
	var previous := str(settings.get_setting("tiiny_ai/models/coding_model"))
	if id.is_empty() or id == previous or not snapshot.get("loaded", {}).has(id): return
	var model: Dictionary = snapshot.get("models", {}).get(id, {})
	if not Planner.suitable("coding_model", model): return
	settings.set_setting("tiiny_ai/models/coding_model", id)
	settings.set_setting("tiiny_ai/models/coding_model_type", str(model.get("type", "")))
	settings.set_setting("tiiny_ai/models/coding_model_vision", bool(model.get("supports_vision", false)))
	var context := int(draft.roles.coding_model.get("context", 8192))
	var max_context := int(model.get("max_context", 0))
	if max_context > 0: context = mini(context, max_context)
	draft.roles.coding_model = {"model": id, "context": maxi(context, 2048), "warm": true}
	draft_initialized = true
	if settings.has_setting("_tiiny_ai/applied_configuration"):
		var saved: Variant = settings.get_setting("_tiiny_ai/applied_configuration")
		if _valid_saved_draft(saved):
			saved.roles.coding_model = draft.roles.coding_model.duplicate(true)
			settings.set_setting("_tiiny_ai/applied_configuration", saved)
	_verify_coding_model_stability(settings)
	_report("Adopted already-loaded coding model %s (previously %s). No model was unloaded or switched." % [str(model.get("name", id)), previous if not previous.is_empty() else "unselected"])
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	if service != null and service.get("available"):
		var changed := false
		for job in service.queue.snapshot().jobs:
			if job.state == "queued" and job.operation == "model_restore" and str(job.parameters.get("model", "")) != id:
				if service.queue.cancel_queued(job.id): changed = true
		if changed and service.has_method("refresh_board"): service.refresh_board()

func _schedule_coding_restore() -> void:
	var settings := EditorInterface.get_editor_settings()
	var configured := str(settings.get_setting("tiiny_ai/models/coding_model"))
	if not connected: return
	var loaded_coding := _loaded_coding_model()
	if not configured.is_empty() and snapshot.get("loaded", {}).has(configured): return
	if not loaded_coding.is_empty():
		_adopt_loaded_coding_model(loaded_coding)
		return
	var id := _saved_coding_model()
	if id.is_empty(): return
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	if service == null or not service.get("available"): return
	for job in service.queue.snapshot().jobs:
		if job.operation == "model_restore" and job.state in ["queued", "running", "failed", "cancelled", "interrupted"] and job.parameters.get("model") == id and job.parameters.get("connection") == connection_identity:
			return
	var result: Dictionary = service.append_job("model-restore-" + Crypto.new().generate_random_bytes(16).hex_encode(), "model_restore", {"model": id, "connection": connection_identity, "timeout_ms": 7200000})
	if result.has("error"):
		_report("Could not queue coding-model restoration: " + str(result.error))
	else:
		_report("Coding-model restoration queued at position %d." % result.sequence)

func check_config() -> void:
	if busy: return
	if not _acquire_device("check models"):
		_report_busy()
		return
	busy = true
	plan = {}
	_report("Checking configuration against fresh device state…")
	var result := await _fetch_snapshot()
	busy = false
	_release_device()
	if result.has("error"):
		connected = false
		connection_identity = ""
		last_error_type = _classify_error(str(result.error))
		snapshot = {}
		_report(_error_description(str(result.error)) + " Apply is disabled.")
		return
	if not _accept_snapshot(result):
		_report("Device connection changed during Check Config. Check again.")
		return
	_initialize_draft_from_snapshot()
	plan = Planner.check(snapshot, draft, str(EditorInterface.get_editor_settings().get_setting("tiiny_ai/models/coding_model")))
	plan["draft"] = draft.duplicate(true)
	plan["checked_at"] = Time.get_ticks_msec()
	plan["connection"] = snapshot.connection
	plan["active_coding"] = str(EditorInterface.get_editor_settings().get_setting("tiiny_ai/models/coding_model"))
	_report("Check passed — review pending operations before Apply." if plan.ok else "Check failed — resolve the listed issues. No device changes were made.")

func apply_config() -> void:
	if busy or not plan.get("ok", false): return
	if draft != plan.get("draft", {}) or Time.get_ticks_msec() - int(plan.get("checked_at", 0)) > PLAN_LIFETIME * 1000:
		plan = {}
		_report("Configuration check expired or changed. Check Config again.")
		return
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	if service == null or not service.has_method("append_job"):
		_report("Jobs service is unavailable; no model changes were made.")
		return
	# Persist only the approved inputs and actions; planner diagnostics use
	# PackedStringArray and are neither needed for dispatch nor JSON-safe.
	var approved := {"draft": plan.draft.duplicate(true), "actions": plan.actions.duplicate(true), "connection": plan.connection, "active_coding": plan.active_coding}
	var submitted: Dictionary = service.append_job("model-apply-" + Crypto.new().generate_random_bytes(16).hex_encode(), "model_apply", {"approved": approved, "timeout_ms": 7200000})
	if submitted.has("error"):
		_report("Could not queue model configuration: " + str(submitted.error))
		return
	plan = {}
	_report("Model configuration queued at position %d." % submitted.sequence)

# Called by the FIFO worker. A queued plan is revalidated against the current
# device and configured coding model before any command is allowed to start.
func poll_model_job(job: Dictionary) -> Dictionary:
	if model_job_id.is_empty():
		if busy or applying:
			return {"state": "running", "stage": "Waiting for Tiiny"}
		if not _acquire_device("apply models"):
			return {"state": "running", "stage": "Waiting for Tiiny"}
		model_job_id = str(job.id)
		model_job_result = {"state": "running", "stage": "Checking model configuration"}
		model_job_cancelled = false
		model_job_checkpoint_failed = false
		if job.operation == "model_restore":
			_execute_model_restoration(job.parameters)
		elif job.operation == "model_schedule":
			_execute_model_schedule(job.parameters)
		else:
			_execute_model_configuration(job.parameters.approved)
	if model_job_id != job.id:
		return {"state": "running", "stage": "Waiting for model manager"}
	if model_job_result.get("state") == "running":
		return {"state": "running", "stage": message}
	if model_job_result.get("state") == "completed":
		var service := get_tree().get_first_node_in_group("tiiny_job_manager")
		if service == null or not service.confirm_model_operations(self, device_lease, model_job_id):
			model_job_result = {"state": "failed", "result": {"error": "Could not clear the shared device recovery record."}}
	return model_job_result

func cancel_model_job(id: String) -> bool:
	if not id.is_empty() and (model_job_id == id or external_model_job_id == id):
		model_job_cancelled = true
		stop_cli()
		return true
	return false

func finalize_model_job(id: String, _state: String) -> void:
	if model_job_id != id: return
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	var persisted: Dictionary = service.get_job_status(id) if service != null else {}
	# An unknown remote outcome keeps the lease until the user acknowledges it.
	if persisted.get("state") != "interrupted":
		_release_device()
		model_job_id = ""
		model_job_result = {}

func release_uncertain_model_job(id: String) -> void:
	if model_job_id == id:
		_release_device()
		model_job_id = ""
		model_job_result = {}

# A read-only inventory check helps the user review an interrupted command. It
# cannot prove that the remote operation has stopped, so it never retries or
# resolves the job automatically.
func inspect_interrupted_model_job(id: String) -> Dictionary:
	if busy or applying: return {"error": "Tiiny is busy; try the device check again."}
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	if service == null or not service.has_method("acquire_device_for_inspection"):
		return {"error": "Jobs service is unavailable."}
	var job: Dictionary = service.get_job_status(id)
	if job.get("state") != "interrupted" or job.get("attempts", []).is_empty():
		return {"error": "This job no longer needs device review."}
	var operations: Array = job.attempts.back().get("device_operations", [])
	if operations.is_empty(): return {"error": "No model operation was recorded for this job."}
	var operation: Dictionary = operations.back()
	var connection := _connection()
	if connection.has("error") or connection.get("identity", "") != operation.connection:
		return {"error": "Reconnect to the device and account used for this operation before checking it."}
	var already_held := not device_lease.is_empty() and model_job_id == id
	if not already_held:
		var token: String = service.acquire_device_for_inspection(self, id)
		if token.is_empty(): return {"error": "The device is busy or this job does not own the recovery record."}
		device_lease_owner = service
		device_lease = token
	busy = true
	var observed := await _fetch_snapshot()
	busy = false
	if not already_held: _release_device()
	if observed.has("error"):
		return {"error": _error_description(str(observed.error))}
	connection = _connection()
	if connection.has("error") or observed.get("connection", "") != operation.connection or connection.get("identity", "") != operation.connection:
		return {"error": "The configured device changed during the check; no observation was recorded."}
	var models: Dictionary = observed.get("models", {})
	var model: Dictionary = models.get(operation.model, {})
	var loaded: Dictionary = observed.get("loaded", {})
	var observation := {"connection": operation.connection, "model": operation.model, "verb": operation.verb, "catalog_present": models.has(operation.model), "installed": bool(model.get("installed", false)), "loaded": loaded.has(operation.model), "model_state": str(model.get("state", "unknown")).left(100), "npu": float(loaded.get(operation.model, -1)), "checked_at": Time.get_unix_time_from_system()}
	if not service.queue.observe_device_operation(id, observation):
		return {"error": "Could not save the device observation; the job remains stopped."}
	var description := "%s: catalog %s, installed %s, loaded %s (device state: %s)." % [operation.model, "present" if observation.catalog_present else "missing", "yes" if observation.installed else "no", "yes" if observation.loaded else "no", observation.model_state]
	return {"message": description + " The remote operation may still be changing. The job remains stopped; after reviewing the device, use Skip to acknowledge the uncertain outcome and check the configuration again."}

# A running inference job cannot wait for a restore appended behind itself.
# Restore as a recorded preflight of that same job, then let it continue.
func poll_model_preflight(job: Dictionary) -> Dictionary:
	if model_job_id.is_empty():
		if is_ready(): return {"state": "completed"}
		if busy or applying: return {"state": "running", "stage": "Waiting for Tiiny"}
		var id := _saved_coding_model()
		if id.is_empty() or id != str(job.parameters.get("model", "")):
			return {"state": "failed", "result": {"error": "Apply a compatible coding model before running this job."}}
		var connection := _connection()
		if connection.has("error"): return {"state": "failed", "result": {"error": str(connection.error)}}
		if not _acquire_device("restore coding model"):
			return {"state": "running", "stage": "Waiting for Tiiny"}
		model_job_id = str(job.id)
		model_job_result = {"state": "running", "stage": "Checking coding model"}
		model_job_cancelled = false
		model_job_checkpoint_failed = false
		_execute_model_restoration({"model": id, "connection": connection.identity, "preflight": true})
	if model_job_id != job.id: return {"state": "running", "stage": "Waiting for model manager"}
	if model_job_result.get("state") == "running": return {"state": "running", "stage": message}
	var result := model_job_result.duplicate(true)
	if result.get("state") == "completed":
		var service := get_tree().get_first_node_in_group("tiiny_job_manager")
		if service == null or not service.confirm_model_operations(self, device_lease, model_job_id):
			model_job_result = {"state": "failed", "result": {"error": "Could not clear the shared device recovery record."}}
			return model_job_result
		_release_device()
		model_job_id = ""
		model_job_result = {}
	return result

func _execute_model_restoration(parameters: Dictionary) -> void:
	busy = true
	applying = true
	last_operation_failed = false
	operation_log.clear()
	var id := str(parameters.get("model", ""))
	var identity := str(parameters.get("connection", ""))
	var current := _connection()
	if _saved_coding_model() != id or current.get("identity", "") != identity:
		if parameters.get("preflight", false):
			await _apply_failed("The saved coding model or device changed before restoration.")
		else:
			busy = false
			applying = false
			_report("Queued coding-model restoration is no longer needed.")
			model_job_result = {"state": "completed", "result": {"message": message}}
		return
	_report("Checking the saved coding model…")
	var fresh := await _fetch_snapshot()
	if model_job_cancelled:
		await _apply_failed("Coding-model restoration cancelled.")
		return
	if fresh.has("error") or fresh.get("connection", "") != identity or _saved_coding_model() != id:
		await _apply_failed("The saved coding model or device is unavailable or changed.")
		return
	var model: Dictionary = fresh.get("models", {}).get(id, {})
	if not Planner.suitable("coding_model", model):
		await _apply_failed("The saved coding model is unavailable or no longer supports tool use. Choose a compatible model in Models.")
		return
	if not fresh.loaded.has(id):
		# A queued restore from an older selection must not evict a coding model
		# that is already running. Adopt the loaded model and finish this job
		# without any device operation.
		if not _accept_snapshot(fresh):
			await _apply_failed("The device changed while checking coding-model restoration.")
			return
		var loaded_coding := _loaded_coding_model()
		if not loaded_coding.is_empty() and loaded_coding != id:
			_adopt_loaded_coding_model(loaded_coding)
			busy = false
			applying = false
			current_operation = {}
			current_progress = 0.0
			plan = {}
			_report("Coding-model restoration skipped: adopted already-loaded %s instead. No model was switched." % loaded_coding)
			model_job_result = {"state": "completed", "result": {"message": message}}
			return
		var settings := EditorInterface.get_editor_settings()
		var saved: Dictionary = settings.get_setting("_tiiny_ai/applied_configuration")
		var allocation := float(model.get("npu", -1))
		var reserve := float(saved.get("npu_reserve", 5))
		if allocation < 0 or float(fresh.npu_used) + allocation + reserve > float(fresh.npu_total):
			await _apply_failed("Cannot restore the coding model: NPU capacity is insufficient or unknown. No models were unloaded.")
			return
		if not model.get("installed", false):
			var bytes := float(model.get("bytes", -1))
			var disk_reserve := float(saved.get("disk_reserve_gib", 2)) * 1073741824.0
			if bytes <= 0 or bytes * 2 + disk_reserve > float(fresh.disk_free):
				await _apply_failed("Cannot restore the coding model: SSD capacity or download size is insufficient or unknown.")
				return
			var downloaded := await _restore_model_command("download", id, identity)
			if downloaded.has("error"):
				await _apply_failed(str(downloaded.error))
				return
			fresh = downloaded.snapshot
			if float(fresh.npu_used) + allocation + reserve > float(fresh.npu_total):
				await _apply_failed("Cannot load the coding model: NPU capacity changed after download. No models were unloaded.")
				return
		var loaded := await _restore_model_command("load", id, identity)
		if loaded.has("error"):
			await _apply_failed(str(loaded.error))
			return
		fresh = loaded.snapshot
	if not _accept_snapshot(fresh):
		await _apply_failed("The device changed while restoring the coding model.")
		return
	busy = false
	applying = false
	current_operation = {}
	current_progress = 0.0
	last_operation_failed = false
	plan = {}
	_report("Coding model restored and verified.")
	model_job_result = {"state": "completed", "result": {"message": message, "operations": Array(operation_log)}}
func job_connection_identity() -> String:
	var connection := _connection()
	return "" if connection.has("error") else str(connection.get("identity", ""))

func _execute_model_schedule(parameters: Dictionary) -> void:
	busy = true
	applying = true
	last_operation_failed = false
	operation_log.clear()
	var role := str(parameters.get("role", ""))
	var requested := str(parameters.get("model", ""))
	var identity := str(parameters.get("connection", ""))
	var restore := bool(parameters.get("restore", true))
	var connection := _connection()
	if connection.has("error") or connection.get("identity", "") != identity:
		await _apply_failed("The device connection changed before scheduling " + requested + ".")
		return
	_report("Checking capacity for " + requested + "…")
	var fresh := await _fetch_snapshot()
	if model_job_cancelled:
		await _fail_schedule("Scheduling cancelled before device changes.", {"changed": false, "uncertain": false}, identity, {}, "")
		return
	if fresh.has("error") or fresh.get("connection", "") != identity:
		await _apply_failed("The device is unavailable or changed before scheduling " + requested + ".")
		return
	var settings := EditorInterface.get_editor_settings()
	var saved: Dictionary = settings.get_setting("_tiiny_ai/applied_configuration")
	if not _valid_saved_draft(saved):
		await _apply_failed("Apply a model configuration before scheduling specialized work.")
		return
	var active := str(settings.get_setting("tiiny_ai/models/coding_model"))
	var plan := Planner.schedule(fresh, saved, role, requested, active)
	if not plan.get("ok", false):
		await _apply_failed("Cannot schedule %s: %s" % [requested, " ".join(plan.errors)])
		return
	var protected_coding := str(plan.get("coding", ""))
	var executed := await _run_scheduled_actions(plan.temporary, identity, "Loading " + requested)
	if not executed.get("ok", false):
		await _fail_schedule(str(executed.get("error", "Scheduled model operation failed.")), executed, identity, saved, active)
		return
	if fresh.loaded.has(protected_coding) and not executed.get("snapshot", {}).get("loaded", {}).has(protected_coding):
		await _fail_schedule("The scripting model was lost while scheduling " + requested + ".", executed, identity, saved, active)
		return
	if not restore:
		if not _accept_snapshot(executed.snapshot):
			await _apply_failed("The device changed while scheduling " + requested + ".")
			return
		busy = false
		applying = false
		current_operation = {}
		current_progress = 0.0
		plan = {}
		_report("%s is loaded. The configured warm set was not restored because restoration was skipped by request." % requested)
		model_job_result = {"state": "completed", "result": {"message": message, "operations": Array(operation_log), "requested": requested, "restored": false}}
		return
	var restored := await _restore_scheduled_set(identity, saved, active, false)
	if not restored.get("ok", false):
		await _fail_schedule("Scheduled work finished, but restoring the configured warm set failed.", restored, identity, saved, active)
		return
	var final := await _fetch_snapshot()
	if final.has("error") or final.get("connection", "") != identity:
		await _apply_failed("Could not verify the restored warm set on the original device.")
		return
	if not _accept_snapshot(final):
		await _apply_failed("The device changed after restoring the configured warm set.")
		return
	busy = false
	applying = false
	current_operation = {}
	current_progress = 0.0
	last_operation_failed = false
	plan = {}
	_report("%s scheduled and verified; the configured warm set was restored." % requested)
	model_job_result = {"state": "completed", "result": {"message": message, "operations": Array(operation_log), "requested": requested, "restored": true}}

func _run_scheduled_actions(actions: Array, identity: String, label: String, ignore_cancel := false, journal_job_id := "", journal_token := "", journal_owner: Object = null) -> Dictionary:
	var changed := false
	for action in actions:
		if not ignore_cancel and model_job_cancelled:
			return {"ok": false, "cancelled": true, "changed": changed, "uncertain": false, "error": "Scheduled model operation cancelled."}
		var connection := _connection()
		if connection.has("error") or connection.get("identity", "") != identity:
			return {"ok": false, "changed": changed, "uncertain": false, "error": "The device connection changed during scheduling."}
		_report("%s: %s %s…" % [label, str(action.verb).capitalize(), str(action.id)])
		operation_log.append("%s %s" % [action.verb, action.id])
		_set_operation(str(action.verb), str(action.id))
		var service := get_tree().get_first_node_in_group("tiiny_job_manager")
		var active_job := journal_job_id if not journal_job_id.is_empty() else model_job_id
		var active_token := journal_token if not journal_token.is_empty() else device_lease
		var active_owner: Object = journal_owner if journal_owner != null else self
		if not active_job.is_empty() and (service == null or not service.begin_model_operation(active_owner, active_token, active_job, action.verb, action.id, identity)):
			return {"ok": false, "changed": changed, "uncertain": false, "error": "Could not record the scheduled model operation. Stopped before starting it."}
		changed = true
		var exit_code := await _run_cli([action.verb, action.id])
		if exit_code != 0 or (not ignore_cancel and model_job_cancelled) or model_job_checkpoint_failed:
			return {"ok": false, "cancelled": model_job_cancelled, "changed": changed, "uncertain": true, "error": "Scheduled %s did not finish; the device state is unknown, so no further model commands were sent." % str(action.verb)}
		var observed := await _fetch_snapshot()
		if observed.has("error") or observed.get("connection", "") != identity:
			return {"ok": false, "changed": changed, "uncertain": true, "error": "Could not verify the scheduled model on the original device."}
		var verified := false
		if action.verb == "load": verified = observed.loaded.has(action.id)
		elif action.verb == "unload": verified = not observed.loaded.has(action.id)
		elif action.verb == "download": verified = observed.models.has(action.id) and observed.models[action.id].installed
		if not verified:
			return {"ok": false, "changed": changed, "uncertain": true, "error": "Tiiny did not confirm the scheduled %s." % str(action.verb)}
		if action.verb == "load" and observed.loaded.has(action.id):
			var expected_npu := float(observed.models.get(action.id, {}).get("npu", -1))
			if expected_npu > 0 and float(observed.loaded[action.id]) != expected_npu:
				return {"ok": false, "changed": changed, "uncertain": true, "error": "Tiiny loaded %s but its NPU allocation does not match the catalog." % str(action.id)}
		if not active_job.is_empty() and not service.queue.verify_device_operation(active_job):
			return {"ok": false, "changed": changed, "uncertain": true, "error": "Could not record scheduled-model verification."}
		snapshot = observed
	return {"ok": true, "changed": changed, "uncertain": false, "snapshot": snapshot}

func ensure_model_loaded_for_job(role: String, model: String, job_id: String, owner: Object, token: String) -> Dictionary:
	if is_model_loaded(model):
		return {"ok": true, "already_loaded": true}
	var connection := _connection()
	if connection.has("error"):
		return {"ok": false, "error": str(connection.error)}
	var identity := str(connection.get("identity", ""))
	var settings := EditorInterface.get_editor_settings()
	var saved: Dictionary = settings.get_setting("_tiiny_ai/applied_configuration")
	if not _valid_saved_draft(saved):
		return {"ok": false, "error": "Apply a model configuration before loading a specialized model on demand."}
	var active := str(settings.get_setting("tiiny_ai/models/coding_model"))
	var fresh := await _fetch_snapshot()
	if fresh.has("error") or fresh.get("connection", "") != identity:
		return {"ok": false, "error": "The device is unavailable or changed before loading " + model + "."}
	var plan := Planner.schedule(fresh, saved, role, model, active)
	if not plan.get("ok", false):
		return {"ok": false, "error": "Cannot load %s alongside the coding model: %s" % [model, " ".join(plan.errors)]}
	var executed := await _run_scheduled_actions(plan.temporary, identity, "Loading " + model, false, job_id, token, owner)
	if not executed.get("ok", false):
		return {"ok": false, "error": str(executed.get("error", "Could not load " + model)), "uncertain": bool(executed.get("uncertain", false)), "changed": bool(executed.get("changed", false)), "identity": identity}
	return {"ok": true, "already_loaded": false, "identity": identity, "saved": saved, "active": active}

func restore_configured_set_for_job(identity: String, job_id: String, owner: Object, token: String) -> Dictionary:
	var settings := EditorInterface.get_editor_settings()
	var saved: Dictionary = settings.get_setting("_tiiny_ai/applied_configuration")
	if not _valid_saved_draft(saved):
		return {"ok": false, "error": "The configured warm set is unavailable."}
	var active := str(settings.get_setting("tiiny_ai/models/coding_model"))
	var observed := await _fetch_snapshot()
	if observed.has("error") or observed.get("connection", "") != identity:
		return {"ok": false, "error": "Could not read the device before restoring the configured warm set.", "uncertain": true}
	var plan := Planner.check(observed, saved, active)
	if not plan.get("ok", false):
		return {"ok": false, "error": "Warm-set restoration is not possible: " + " ".join(plan.errors)}
	return await _run_scheduled_actions(plan.actions, identity, "Restoring configured warm set", true, job_id, token, owner)

func _restore_scheduled_set(identity: String, saved: Dictionary, active: String, ignore_cancel: bool) -> Dictionary:
	var connection := _connection()
	if connection.has("error") or connection.get("identity", "") != identity:
		return {"ok": false, "changed": false, "uncertain": false, "error": "The device connection changed before warm-set restoration."}
	var observed := await _fetch_snapshot()
	if observed.has("error") or observed.get("connection", "") != identity:
		return {"ok": false, "changed": false, "uncertain": true, "error": "Could not read the device before warm-set restoration."}
	var plan := Planner.check(observed, saved, active)
	if not plan.get("ok", false):
		return {"ok": false, "changed": false, "uncertain": false, "error": "Warm-set restoration is not possible with the current capacity: " + " ".join(plan.errors)}
	return await _run_scheduled_actions(plan.actions, identity, "Restoring configured warm set", ignore_cancel)

func _fail_schedule(reason: String, executed: Dictionary, identity: String, saved: Dictionary, active: String) -> void:
	var note := ""
	if bool(executed.get("uncertain", false)):
		note = " A device operation has an unknown outcome; no further model commands were sent. Review the device before retrying."
	elif bool(executed.get("changed", false)) and not saved.is_empty():
		var restored := await _restore_scheduled_set(identity, saved, active, true)
		if restored.get("ok", false):
			note = " The configured warm set was restored."
		elif bool(restored.get("uncertain", false)):
			note = " Warm-set restoration could not be verified; review the device before retrying."
		else:
			note = " Warm-set restoration failed: " + str(restored.get("error", "unknown error"))
	await _apply_failed(reason + note)

func _restore_model_command(verb: String, id: String, identity: String) -> Dictionary:
	if model_job_cancelled: return {"error": "Coding-model restoration cancelled."}
	var connection := _connection()
	if connection.has("error") or connection.get("identity", "") != identity or _saved_coding_model() != id:
		return {"error": "The saved coding model or device changed before restoration."}
	var service := get_tree().get_first_node_in_group("tiiny_job_manager")
	if service == null or not service.begin_model_operation(self, device_lease, model_job_id, verb, id, identity):
		return {"error": "Could not record coding-model restoration before starting it."}
	_report("%s coding model %s…" % [verb.capitalize(), id])
	operation_log.append("%s %s" % [verb, id])
	_set_operation(verb, id)
	var code := await _run_cli([verb, id])
	if code != 0 or model_job_cancelled or model_job_checkpoint_failed:
		return {"error": "Coding-model %s did not finish; check device state before retrying." % verb}
	var observed := await _fetch_snapshot()
	if observed.has("error") or observed.get("connection", "") != identity:
		return {"error": "Could not verify coding-model %s on the original device." % verb}
	var model: Dictionary = observed.get("models", {}).get(id, {})
	var verified: bool = bool(model.get("installed", false)) if verb == "download" else observed.get("loaded", {}).has(id)
	if verb == "load" and verified and float(model.get("npu", -1)) > 0:
		verified = float(observed.loaded[id]) == float(model.npu)
	if not verified or not Planner.suitable("coding_model", model):
		return {"error": "Tiiny did not confirm the coding-model %s." % verb}
	if not service.queue.verify_device_operation(model_job_id):
		return {"error": "Could not record coding-model verification."}
	return {"snapshot": observed}

func _execute_model_configuration(approved: Dictionary) -> void:
	busy = true
	applying = true
	last_operation_failed = false
	if not _valid_approved_configuration(approved):
		await _apply_failed("The queued model configuration is invalid. Check Config again.")
		return
	_report("Revalidating the approved plan…")
	var fresh := await _fetch_snapshot()
	if model_job_cancelled:
		await _apply_failed("Model configuration cancelled before device changes.")
		return
	if fresh.has("error") or fresh.get("connection") != approved.get("connection"):
		var error_type := "unavailable" if fresh.has("error") else "changed"
		connected = false
		connection_identity = ""
		last_error_type = error_type
		await _apply_failed("Device changed or became unavailable. Check Config again.")
		return
	var settings := EditorInterface.get_editor_settings()
	var old_coding := str(settings.get_setting("tiiny_ai/models/coding_model"))
	if old_coding != str(approved.get("active_coding", "")) or not _valid_saved_draft(approved.get("draft")):
		await _apply_failed("The saved coding model or configuration changed. Check Config again.")
		return
	var restored_verbs := PackedStringArray()
	if _saved_coding_model() == old_coding and not fresh.loaded.has(old_coding):
		# Restore the currently selected coordinator inside this same FIFO job,
		# before changing any other model. Never wait for a later restore job.
		await _execute_model_restoration({"model": old_coding, "connection": approved.connection, "preflight": true})
		if model_job_result.get("state") != "completed": return
		var service := get_tree().get_first_node_in_group("tiiny_job_manager")
		if service == null:
			await _apply_failed("Jobs service became unavailable after restoring the coding model.")
			return
		var current_job: Dictionary = service.get_job_status(model_job_id)
		for operation in current_job.get("attempts", []).back().get("device_operations", []):
			if operation.model == old_coding and operation.state == "verified":
				restored_verbs.append(str(operation.verb))
		fresh = snapshot
		busy = true
		applying = true
		model_job_result = {"state": "running", "stage": "Rechecking model configuration"}
	var rechecked := Planner.check(fresh, approved.draft, old_coding)
	var remaining_actions: Array = []
	for action in approved.actions:
		if action.id == old_coding and restored_verbs.has(action.verb):
			continue
		remaining_actions.append(action)
	if not rechecked.ok or rechecked.actions != remaining_actions:
		await _apply_failed("The plan changed since Check Config. Review a new check before applying.")
		return
	if restored_verbs.is_empty(): operation_log.clear()
	for action in rechecked.actions:
		if model_job_cancelled:
			await _apply_failed("Model configuration cancelled. Check the device before retrying.")
			return
		var current_connection := _connection()
		if current_connection.has("error") or current_connection.get("identity", "") != approved.connection:
			await _apply_failed("Device connection changed during Apply. Stopped before the next operation.")
			return
		_report("%s %s…" % [str(action.verb).capitalize(), action.id])
		operation_log.append("%s %s" % [action.verb, action.id])
		_set_operation(str(action.verb), str(action.id))
		var service := get_tree().get_first_node_in_group("tiiny_job_manager")
		if not model_job_id.is_empty() and (service == null or not service.begin_model_operation(self, device_lease, model_job_id, action.verb, action.id, approved.connection)):
			await _apply_failed("Could not record the model operation. Stopped before starting it.")
			return
		var exit_code := await _run_cli([action.verb, action.id])
		if exit_code != 0 or model_job_cancelled or model_job_checkpoint_failed:
			await _apply_failed("Operation failed (%d). Earlier operations may have completed; refresh and check again." % exit_code)
			return
		var observed := await _fetch_snapshot()
		if observed.has("error") or observed.get("connection", "") != approved.connection:
			await _apply_failed("Could not verify the original device after an operation. Stopped; refresh before retrying.")
			return
		var verified := false
		if action.verb == "load": verified = observed.loaded.has(action.id)
		elif action.verb == "unload": verified = not observed.loaded.has(action.id)
		elif action.verb == "download": verified = observed.models.has(action.id) and observed.models[action.id].installed
		if not verified:
			await _apply_failed("Tiiny did not confirm the requested %s. Stopped before the next operation." % action.verb)
			return
		# Verify NPU allocation matches the model's expected value.
		if action.verb == "load" and observed.loaded.has(action.id):
			var expected_npu := 0.0
			if observed.models.has(action.id) and observed.models[action.id].npu >= 0:
				expected_npu = observed.models[action.id].npu
			if expected_npu > 0 and observed.loaded[action.id] != expected_npu:
				await _apply_failed("Tiiny loaded %s but NPU allocation (%.0f) does not match the expected value (%.0f). The model may be partially loaded." % [action.id, observed.loaded[action.id], expected_npu])
				return
		var protected_id: String = approved.draft.roles.coding_model.model if observed.loaded.has(approved.draft.roles.coding_model.model) else old_coding
		if fresh.loaded.has(old_coding) and not observed.loaded.has(protected_id):
			await _apply_failed("The scripting model became unavailable. Stopped; check and restore the configuration before continuing.")
			return
		if not model_job_id.is_empty() and not service.queue.verify_device_operation(model_job_id):
			await _apply_failed("Could not record device verification. Stopped before the next operation.")
			return
		snapshot = observed
	var final := await _fetch_snapshot()
	if final.has("error") or final.get("connection", "") != approved.connection:
		await _apply_failed("Could not verify the completed configuration on the original device.")
		return
	for id in rechecked.warm:
		if not final.loaded.has(id):
			await _apply_failed("Required model is not loaded: " + id)
			return
	if not _accept_snapshot(final):
		await _apply_failed("Device connection changed during Apply. Refresh before retrying.")
		return
	for role in ROLES: settings.set_setting("tiiny_ai/models/" + role, approved.draft.roles[role].model)
	var coding_id: String = approved.draft.roles.coding_model.model
	settings.set_setting("tiiny_ai/models/coding_model_type", final.models[coding_id].type)
	settings.set_setting("tiiny_ai/models/coding_model_vision", bool(final.models[coding_id].get("supports_vision", false)))
	settings.set_setting("tiiny_ai/models/context_tokens", approved.draft.roles.coding_model.context)
	settings.set_setting("_tiiny_ai/applied_configuration", approved.draft)
	busy = false
	applying = false
	if model_job_id.is_empty(): _release_device()
	current_operation = {}
	current_progress = 0.0
	last_operation_failed = false
	plan = {}
	_report("Configuration applied and verified. Chat uses the selected scripting model and request context budget.")
	if not model_job_id.is_empty():
		model_job_result = {"state": "completed", "result": {"message": message, "operations": Array(operation_log)}}

func _apply_failed(reason: String) -> void:
	var current := await _fetch_snapshot()
	if not current.has("error") and _accept_snapshot(current):
		last_error_type = _classify_error(reason)
	else:
		connected = false
		connection_identity = ""
		last_error_type = _classify_error(str(current.get("error", reason)))
		snapshot = {}
		if current.has("error"):
			reason += " " + _error_description(str(current.error))
	busy = false
	applying = false
	if model_job_id.is_empty(): _release_device()
	current_operation = {}
	current_progress = 0.0
	last_operation_failed = true
	plan = {}
	_report(reason)
	if not model_job_id.is_empty():
		model_job_result = {"state": "cancelled" if model_job_cancelled else "failed", "result": {"error": reason, "operations": Array(operation_log)}}

static func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\"'\"'") + "'"

func _record_progress(arguments: Array, percent: float, source: String) -> void:
	if arguments.size() < 2 or percent < 0 or percent > 100: return
	var now := Time.get_ticks_msec()
	var previous: Dictionary = progress_reports.get(source, {})
	if not previous.is_empty() and int(previous.percent) == int(percent) and now - int(previous.time) < 10000: return
	progress_reports[source] = {"percent": percent, "time": now}
	if source == "device" and not current_operation.is_empty(): current_progress = percent
	if source == "device" and not model_job_id.is_empty():
		var service := get_tree().get_first_node_in_group("tiiny_job_manager")
		if service == null or not service.queue.device_operation_progress(model_job_id, percent):
			model_job_checkpoint_failed = true
			stop_cli()
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
	var command := ["--signal=TERM", "--kill-after=5s", "86400s", "script", "-q", "-e", "-c", " ".join(parts), "/dev/null"]
	var process := OS.execute_with_pipe("timeout", PackedStringArray(command), false)
	if process.is_empty(): return ERR_CANT_FORK
	process_id = int(process.pid)
	var running_id := process_id
	progress_reports.clear()
	operation_started = Time.get_ticks_msec()
	var reader := ProgressReader.new()
	var next_poll := operation_started
	var last_percent := -1.0
	var stall_threshold := 900.0
	var stall_start := 0.0
	var stalled := false
	while process_id == running_id and OS.is_process_running(running_id):
		_drain_progress(process, reader, arguments)
		if arguments[0] == "download" and Time.get_ticks_msec() >= next_poll:
			await _poll_download_progress(connection, arguments)
			var latest: float = 0.0
			if "device" in progress_reports: latest = progress_reports["device"].get("percent", 0.0)
			if latest > 0 and last_percent >= 0 and latest == last_percent:
				if stall_start == 0: stall_start = Time.get_ticks_msec()
				if Time.get_ticks_msec() - stall_start > stall_threshold * 1000 and not stalled:
					stalled = true
					var stall_msg := "Progress stalled at %.1f%% for more than %.0fs. The device may be slow or unresponsive; the operation will continue but may not complete." % [latest, stall_threshold]
					_report(stall_msg)
			else:
				if stalled: _report("Progress resumed after stall.")
				stalled = false
				stall_start = 0
				last_percent = latest
			next_poll = Time.get_ticks_msec() + 3000
		await get_tree().create_timer(0.1).timeout
	_drain_progress(process, reader, arguments)
	for value in reader.feed(PackedByteArray(), true):
		if arguments[0] != "download": _record_progress(arguments, value, "SDK")
	var code := OS.get_process_exit_code(running_id) if process_id == running_id else ERR_SKIP
	process_id = -1
	if arguments[0] == "download": await _poll_download_progress(connection, arguments)
	process.stdio.close()
	process.stderr.close()
	return code

func _cli_descendants(pid: int) -> PackedStringArray:
	var result := PackedStringArray()
	var path := "/proc/%d/task/%d/children" % [pid, pid]
	var children_file := FileAccess.open(path, FileAccess.READ)
	if children_file != null:
		for child in children_file.get_line().split(" ", false):
			if child.strip_edges().is_valid_int():
				result.append_array(_cli_descendants(int(child)))
				result.append(child.strip_edges())
	return result

func stop_cli() -> void:
	if process_id <= 0: return
	var pid := process_id
	process_id = -1
	if OS.is_process_running(pid):
		var children := _cli_descendants(pid)
		# PTY workers may create their own session. Kill their PIDs as well as
		# the owned root process group; never wait for a stubborn SDK at shutdown.
		var arguments := PackedStringArray(["-KILL", "--"])
		arguments.append_array(children)
		arguments.append("-" + str(pid))
		OS.execute("kill", arguments)
		if OS.is_process_running(pid): OS.kill(pid) # Reap or finish the owned child.

func _exit_tree() -> void:
	stop_cli()
	if not busy:
		_release_device()

class ConfigurationPanel extends VBoxContainer:
	var manager: Node
	var content: VBoxContainer
	var advanced_open := false
	var status_label: Label
	var rebuilding := false
	var age_label: Label
	var apply_button: Button
	var check_button: Button
	var capacity_row: HBoxContainer
	var operation_label: Label
	var operation_bar: ProgressBar
	var plan_expiry_label: Label
	var failure_label: Label
	var role_hints: Dictionary = {}

	# Testable rendered semantics; avoids parsing control text in fixtures.
	func panel_state() -> Dictionary:
		var age := -1
		var fresh := false
		if not manager.snapshot.is_empty():
			age = maxi(0, int((Time.get_ticks_msec() - int(manager.snapshot.time)) / 1000))
			fresh = manager.connected and age * 1000 <= manager.SNAPSHOT_LIFETIME * 1000
		var rows: Array = []
		var models: Dictionary = manager.snapshot.get("models", {})
		var assigned: Array[String] = []
		for role in ROLES:
			var selection: Dictionary = manager.draft.roles.get(role, {})
			var id := str(selection.get("model", ""))
			assigned.append(id)
			var model: Dictionary = models.get(id, {})
			rows.append({"task": ROLES[role], "role": role, "id": id, "installed": bool(model.get("installed", false)), "loaded": bool(model.get("loaded", false)), "warm": role == "coding_model" or bool(selection.get("warm", false)), "state": "Unavailable" if not id.is_empty() and model.is_empty() else "Loaded" if bool(model.get("loaded", false)) else "Downloaded" if bool(model.get("installed", false)) else "Not downloaded" if not id.is_empty() else "—", "hint": ""})
		for id in models:
			if models[id].get("installed", false) and not assigned.has(id):
				rows.append({"task": "Other installed", "role": "", "id": id, "installed": true, "loaded": bool(models[id].get("loaded", false)), "warm": manager.draft.extra_warm.has(id), "state": "Loaded" if bool(models[id].get("loaded", false)) else "Downloaded", "hint": ""})
		var capacity := {}
		if not manager.snapshot.is_empty():
			var snapshot: Dictionary = manager.snapshot
			capacity = {"npu_used": float(snapshot.get("npu_used", -1)), "npu_total": float(snapshot.get("npu_total", -1)), "npu_free": float(snapshot.get("npu_total", -1)) - float(snapshot.get("npu_used", -1)), "disk_free": float(snapshot.get("disk_free", -1)), "disk_total": float(snapshot.get("disk_total", -1))}
		var plan_state := {}
		if not manager.plan.is_empty():
			var plan: Dictionary = manager.plan
			plan_state = {"ok": bool(plan.get("ok", false)), "actions": plan.get("actions", []), "errors": Array(plan.get("errors", [])), "warnings": Array(plan.get("warnings", [])), "expired": Time.get_ticks_msec() - int(plan.get("checked_at", 0)) > int(manager.PLAN_LIFETIME * 1000), "npu_projected": float(plan.get("npu_projected", -1)), "npu_remaining": float(plan.get("npu_remaining", -1)), "disk_projected_free": float(plan.get("disk_projected_free", -1)), "download_bytes": float(plan.get("download_bytes", -1))}
		return {"connected": manager.connected, "fresh": fresh, "age": age, "error_type": manager.last_error_type, "unapplied": manager.has_unapplied_changes(), "rows": rows, "role_hints": role_hints.duplicate(true), "capacity": capacity, "plan": plan_state, "operation": manager.operation_state(), "controls": {"refresh_disabled": manager.busy, "check_disabled": check_button.disabled if is_instance_valid(check_button) else true, "apply_disabled": apply_button.disabled if is_instance_valid(apply_button) else true}, "status": manager.message}

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
		var age := -1
		var fresh := false
		if not manager.snapshot.is_empty():
			age = maxi(0, int((Time.get_ticks_msec() - int(manager.snapshot.time)) / 1000))
			fresh = manager.connected and age * 1000 <= SNAPSHOT_LIFETIME * 1000
		if is_instance_valid(age_label):
			if manager.snapshot.is_empty():
				age_label.text = "Device unavailable · Refresh to load capacity"
			elif not manager.connected:
				age_label.text = "Device unavailable · showing last data from %ds ago" % age
			elif not fresh:
				age_label.text = "Stale · %ds old · Refresh to continue" % age
			else:
				age_label.text = "Updated %ds ago · stale after %ds" % [age, int(SNAPSHOT_LIFETIME)]
		if is_instance_valid(capacity_row): capacity_row.modulate.a = 1.0 if fresh else 0.5
		if is_instance_valid(status_label): status_label.text = manager.message
		var expired := Time.get_ticks_msec() - int(manager.plan.get("checked_at", 0)) > PLAN_LIFETIME * 1000
		if is_instance_valid(check_button): check_button.disabled = manager.busy or not fresh
		if is_instance_valid(apply_button):
			apply_button.disabled = manager.busy or not fresh or not manager.plan.get("ok", false) or expired
			apply_button.text = "Check expired" if manager.plan.get("ok", false) and expired else "Apply"
		if is_instance_valid(plan_expiry_label) and not manager.plan.is_empty():
			var remaining := int(ceil((int(manager.plan.get("checked_at", 0)) + PLAN_LIFETIME * 1000 - Time.get_ticks_msec()) / 1000.0))
			plan_expiry_label.text = "expired · Check Config again" if remaining <= 0 else "expires in %ds" % remaining
			plan_expiry_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45) if remaining <= 0 else Color(0.7, 0.75, 0.83))
		if is_instance_valid(failure_label):
			var state: Dictionary = manager.operation_state()
			failure_label.visible = bool(state.failed) and not bool(state.applying)
			if failure_label.visible:
				var tail: Array = state.log_tail
				failure_label.text = "Apply stopped. Attempted operations:\n" + "\n".join(tail.slice(maxi(0, tail.size() - 6))) + "\nNo preferences were saved. Fix the issue, then Check Config again."
		if is_instance_valid(operation_label):
			var operation: Dictionary = manager.operation_state()
			var active := bool(operation.applying) and not str(operation.verb).is_empty()
			operation_label.visible = bool(operation.applying)
			operation_bar.visible = bool(operation.applying)
			if operation_label.visible:
				operation_label.text = ("%s %s · %.1f%% · %ds elapsed" % [str(operation.verb).capitalize(), operation.model, operation.progress, operation.elapsed]) if active else "Starting model operation…"
				operation_bar.value = operation.progress if active else 0.0

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
		var label := _label(("NPU capacity unknown" if "NPU" in text else "SSD capacity unknown") if total < 0 else text, parent)
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.name = "CapacityLabel"
		var bar := ProgressBar.new()
		bar.name = "CapacityBar"
		bar.show_percentage = false
		bar.custom_minimum_size.y = 12
		bar.max_value = maxf(total, 1)
		bar.value = maxf(used, 0) if total >= 0 else 0
		parent.add_child(bar)

	static func _size(bytes: float) -> String:
		return "Unknown" if bytes < 0 else "%.1f GiB" % (bytes / 1073741824.0)

	func _render() -> void:
		if not is_inside_tree() or rebuilding: return
		rebuilding = true
		role_hints.clear()
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
		var connection_text := "Connected" if manager.connected else "Not connected"
		if not manager.connected:
			match manager.last_error_type:
				"auth": connection_text = "Authentication failed"
				"capacity": connection_text = "Capacity unavailable"
				"disconnect": connection_text = "Device unavailable"
		var connection := _label(connection_text, header)
		connection.name = "ConnectionState"
		connection.autowrap_mode = TextServer.AUTOWRAP_OFF
		connection.add_theme_color_override("font_color", Color(0.65, 0.85, 0.7) if manager.connected else Color(0.9, 0.7, 0.5))
		_button("Refresh", manager.refresh_device, header)
		if manager.has_unapplied_changes():
			var unsaved := _label("Unapplied changes · Check Config and Apply to save", content)
			unsaved.name = "UnappliedChanges"
			unsaved.add_theme_color_override("font_color", Color(0.95, 0.8, 0.45))
		if not snapshot.is_empty():
			var capacity_row := HBoxContainer.new()
			capacity_row.name = "CapacityRow"
			capacity_row.add_theme_constant_override("separation", 24)
			content.add_child(capacity_row)
			self.capacity_row = capacity_row
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
				var projected := float(forecast.get("npu_projected", -1))
				var remaining := float(forecast.get("npu_remaining", -1))
				var reserved := float(forecast.get("npu_reserve", 0))
				var projected_disk := float(forecast.get("disk_projected_free", -1))
				var free_text := ("%.0f free" % remaining) if remaining >= 0 else ("insufficient by %.0f" % absf(remaining))
				var prefix := "After Apply" if bool(forecast.get("ok", false)) else "Projected"
				_capacity("%s · %s / %.0f reserved" % [prefix, free_text, reserved], projected, total, npu_box)
				_capacity("After downloads · %s free" % _size(projected_disk), float(snapshot.disk_total) - projected_disk, snapshot.disk_total, ssd_box)
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
			var task_cell := _cell(ROLES[role], 0, grid)
			var required: Array = ROLE_TYPES[role]
			var required_text := " or ".join(required) + (" with Tool Use" if role == "coding_model" else "")
			task_cell.tooltip_text = "Requires " + required_text + "."
			var picker := OptionButton.new()
			picker.name = "RolePicker_" + role
			picker.custom_minimum_size.x = 240
			picker.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			picker.clip_text = true
			picker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			picker.fit_to_longest_item = false
			picker.add_item("Choose model" if role == "coding_model" else "None")
			picker.set_item_metadata(0, "")
			var candidates: Array = models.keys()
			candidates.sort()
			var matching := 0
			for candidate in candidates:
				if not Planner.suitable(role, models[candidate]): continue
				matching += 1
				picker.add_item(models[candidate].name + (" · installed" if models[candidate].installed else " · download"))
				picker.set_item_metadata(picker.item_count - 1, candidate)
				picker.set_item_tooltip(picker.item_count - 1, candidate + "\n" + str(models[candidate].description).left(1200))
				if candidate == id: picker.select(picker.item_count - 1)
			var hint := ""
			if models.is_empty():
				hint = "No catalog models loaded. Refresh the device."
			elif matching == 0:
				hint = "No %s model available in the current catalog." % required_text
			if not hint.is_empty():
				picker.add_item("No compatible model")
				picker.set_item_disabled(picker.item_count - 1, true)
				picker.select(0)
				role_hints[role] = {"required": required_text, "message": hint}
			else:
				role_hints.erase(role)
			picker.tooltip_text = required_text + ("" if hint.is_empty() else "\n" + hint)
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
			_cell("Unavailable" if not id.is_empty() and model.is_empty() else "Loaded" if model.get("loaded", false) else "Downloaded" if model.get("installed", false) else "Not downloaded" if not id.is_empty() else "—", 7, grid)
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
			_cell("Loaded" if models[id].loaded else "Downloaded", 7, grid)
			var info_button := _button("Info", _show_model_info.bind(id), grid)
			info_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if not role_hints.is_empty():
			var hints := VBoxContainer.new()
			hints.name = "RoleUnavailableHints"
			content.add_child(hints)
			for role in ROLES:
				if role_hints.has(role):
					var hint_label := _label("%s: %s" % [ROLES[role], str(role_hints[role].message)], hints)
					hint_label.add_theme_color_override("font_color", Color(0.9, 0.75, 0.5))
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
			var heading := _label("Change plan · %d operations" % Array(plan.get("actions", [])).size(), plan_header)
			heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			plan_expiry_label = _label("", plan_header)
			plan_expiry_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			_button("Details", _show_plan_details, plan_header)
			for error in plan.get("errors", []):
				_label(error, plan_box).add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
			if Array(plan.get("actions", [])).is_empty():
				_label("No model operations. Apply saves the checked configuration.", plan_box)
			else:
				var operations := Tree.new()
				operations.name = "PendingOperations"
				operations.columns = 2
				operations.hide_root = true
				operations.custom_minimum_size.y = clampi(Array(plan.get("actions", [])).size() * 28 + 8, 64, 160)
				operations.set_column_custom_minimum_width(0, 100)
				operations.set_column_expand(0, false)
				var root := operations.create_item()
				for action in plan.get("actions", []):
					var item := operations.create_item(root)
					item.set_text(0, str(action.verb).capitalize())
					item.set_text(1, str(action.id))
				plan_box.add_child(operations)
		operation_label = _label("")
		operation_label.name = "OperationStatus"
		operation_label.visible = false
		operation_bar = ProgressBar.new()
		operation_bar.name = "OperationProgress"
		operation_bar.max_value = 100
		operation_bar.show_percentage = false
		operation_bar.visible = false
		content.add_child(operation_bar)
		failure_label = _label("")
		failure_label.name = "PartialResult"
		failure_label.visible = false
		status_label = _label(manager.message)
		status_label.name = "ConfigurationStatus"
		var actions := HBoxContainer.new()
		content.add_child(actions)
		actions.add_spacer(false)
		var check := _button("Check Config", manager.check_config, actions)
		check_button = check
		var apply := _button("Apply", manager.apply_config, actions)
		apply_button = apply
		apply.disabled = manager.busy or manager.snapshot.is_empty() or not manager.connected or not manager.plan.get("ok", false)
		apply.tooltip_text = "Apply rechecks the device before executing the reviewed plan. Any draft edit invalidates the check."
		rebuilding = false

	func _show_information(title: String, text: String) -> void:
		var dialog := AcceptDialog.new()
		dialog.name = "ModelInformation"
		dialog.title = title
		dialog.ok_button_text = "Close"
		dialog.min_size = Vector2i(620, 420)
		dialog.unresizable = false
		var body := TextEdit.new()
		body.name = "ModelInformationText"
		body.editable = false
		body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		body.text = text
		dialog.add_child(body)
		add_child(dialog)
		dialog.visibility_changed.connect(func():
			if not dialog.visible: dialog.queue_free())
		dialog.popup_centered_clamped(Vector2i(660, 440), 0.8)

	func _show_model_info(id: String) -> void:
		var model: Dictionary = manager.snapshot.get("models", {}).get(id, {})
		if model.is_empty(): return
		var state := "Loaded" if model.get("loaded", false) else "Downloaded" if model.get("installed", false) else "Not downloaded"
		_show_information(str(model.name), "%s\nType: %s\nCapabilities: %s\nState: %s\nMaximum context: %s\nDownload size: %s\nNPU units: %s\n\n%s\n\nContext in this screen limits chat requests; it does not reconfigure Tiiny memory. Token/s is shown only when measured." % [id, model.type, ", ".join(model.supported), state, model.max_context, _size(float(model.get("bytes", -1))), str(model.get("npu", -1)), model.description])

	func _show_plan_details() -> void:
		var plan: Dictionary = manager.plan
		if plan.is_empty(): return
		_show_information("Plan details", "NPU after Apply: %.0f units used / %.0f free (%.0f left unused)\nDownloads: %s\nSSD after downloads: %s free\nSSD at peak staging: %s free\nSSD reserve: %s\n\n%s" % [float(plan.get("npu_projected", -1)), float(plan.get("npu_remaining", -1)), float(plan.get("npu_reserve", 0)), _size(float(plan.get("download_bytes", -1))), _size(float(plan.get("disk_projected_free", -1))), _size(float(plan.get("disk_peak_free", -1))), _size(float(plan.get("disk_reserve", -1))), "\n\n".join(plan.get("warnings", []))])

	func _choose_model(role: String, id: String) -> void:
		var config: Dictionary = manager.draft.duplicate(true)
		config.roles[role].model = id
		if role == "coding_model":
			var max_context := int(manager.snapshot.models.get(id, {}).get("max_context", 0))
			# Default to the model's full context rather than a small 8192 cap;
			# the user can lower it explicitly if they need a smaller request.
			config.roles[role].context = maxi(2048, max_context) if max_context > 0 else 8192
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
