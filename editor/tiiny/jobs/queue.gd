@tool
extends RefCounted

# The native store owns an OS lock until close or process exit. Its lock file
# is permanent and must never be deleted while an editor may be using it.
const SCHEMA := 1
var _mutex := Mutex.new()
var _path := ""
var _project := ""
var _data: Dictionary = {}
var _storage: RefCounted
var error := ""

func open(path: String, project: String) -> bool:
	if _storage != null:
		error = "Queue is already open"
		return false
	_path = path
	_project = project
	_data = {}
	error = ""
	if path.is_empty() or project.is_empty() or not path.is_absolute_path():
		error = "Queue path and project identity are required"
		return false
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		error = "Cannot create queue directory"
		return false
	if not ClassDB.class_exists("TiinyJobStorage"):
		error = "Native queue storage is unavailable"
		return false
	_storage = ClassDB.instantiate("TiinyJobStorage")
	if _storage == null or not _storage.acquire(path):
		_storage = null
		error = "Queue is owned by another editor or storage is unavailable"
		return false
	if not FileAccess.file_exists(path):
		_data = {"schema": SCHEMA, "project": project, "paused": false, "stop_reason": "", "jobs": []}
		if not _save():
			close()
			return false
		return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		error = "Cannot read queue"
		close()
		return false
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		error = "Invalid or incompatible queue; dispatch disabled"
		close()
		return false
	var parsed: Variant = json.data
	if not _valid_store(parsed):
		error = "Invalid or incompatible queue; dispatch disabled"
		close()
		return false
	_data = parsed
	# An unknown running outcome requires an explicit recovery decision.
	for job in _data.jobs:
		if job.state == "running":
			job.state = "interrupted"
			job.attempts.back().state = "interrupted"
			_data.stop_reason = "Interrupted job requires reconciliation"
	if not _save():
		close()
		return false
	return true

func close() -> void:
	_mutex.lock()
	_data = {}
	if _storage != null:
		_storage.release()
		_storage = null
	_mutex.unlock()

func _valid_store(value: Variant) -> bool:
	if not value is Dictionary or value.get("schema") != SCHEMA or value.get("project") != _project:
		return false
	if not value.get("jobs") is Array or not value.get("paused") is bool or not value.get("stop_reason") is String:
		return false
	var ids := {}
	var keys := {}
	var running := 0
	var stopped := 0
	var pending_seen := false
	var position := 0
	for job in value.jobs:
		position += 1
		if not job is Dictionary or job.get("sequence") != position or not job.get("id") is String or job.id.is_empty() or ids.has(job.id):
			return false
		if not job.get("submission_key") is String or job.submission_key.is_empty() or keys.has(job.submission_key):
			return false
		if not job.get("operation") is String or job.operation.is_empty() or not job.get("parameters") is Dictionary or not job.get("attempts") is Array or not job.get("result") is Dictionary:
			return false
		if job.get("state") not in ["queued", "running", "completed", "failed", "cancelled", "interrupted", "skipped"]:
			return false
		if job.has("hidden") and job.hidden != true:
			return false
		if not _json_safe(job.parameters) or not _json_safe(job.result):
			return false
		var attempt_number := 0
		for attempt in job.attempts:
			attempt_number += 1
			if not attempt is Dictionary or attempt.get("number") != attempt_number or attempt.get("state") not in ["running", "completed", "failed", "cancelled", "interrupted"] or not _json_safe(attempt):
				return false
			if attempt.has("publication") and not _valid_publication(attempt.publication):
				return false
			if attempt.has("publication") and attempt.state in ["failed", "cancelled"] and attempt.publication.phase != "aborted":
				return false
			if attempt.has("publication") and attempt.state == "completed" and attempt.publication.phase != "imported":
				return false
			if attempt.has("mutation"):
				if not _valid_mutation(attempt.mutation):
					return false
				if (attempt.state in ["failed", "cancelled"] and attempt.mutation.phase != "aborted") or (attempt.state == "completed" and attempt.mutation.phase != "saved"):
					return false
			if attempt.has("device_started") and (attempt.device_started != true or (attempt.state in ["failed", "cancelled"] and not attempt.get("device_confirmed", false))):
				return false
			if attempt.has("device_confirmed") and (attempt.device_confirmed != true or not attempt.get("device_started", false)):
				return false
			if attempt.has("device_operations"):
				if not attempt.get("device_started", false) or not _valid_device_operations(attempt.device_operations):
					return false
				if attempt.state == "completed" and not attempt.device_operations.is_empty() and attempt.device_operations.back().state != "verified":
					return false
		var prestart_cancelled: bool = job.state == "cancelled" and job.attempts.is_empty()
		if job.state in ["running", "completed", "failed", "cancelled", "interrupted"] and not prestart_cancelled:
			if job.attempts.is_empty() or job.attempts.back().state != job.state:
				return false
		if pending_seen and job.state != "queued" and not prestart_cancelled:
			return false
		if job.state in ["queued", "running", "failed", "cancelled", "interrupted"] and not prestart_cancelled:
			pending_seen = true
		if job.state == "running":
			running += 1
		if job.state in ["failed", "interrupted"] or (job.state == "cancelled" and not prestart_cancelled):
			stopped += 1
		ids[job.id] = true
		keys[job.submission_key] = true
	return running <= 1 and stopped <= 1 and not (running > 0 and stopped > 0) and ((stopped > 0) == not value.stop_reason.is_empty())

# A model command is journaled before it is launched. Only the last entry may
# be unverified; older entries have already been confirmed from device state.
func _valid_device_operations(operations: Variant) -> bool:
	if not operations is Array or operations.is_empty() or operations.size() > 128:
		return false
	for index in operations.size():
		var operation: Variant = operations[index]
		if not operation is Dictionary or operation.get("verb") not in ["download", "load", "unload"]:
			return false
		if not operation.get("model") is String or operation.model.is_empty() or operation.model.length() > 512:
			return false
		if not operation.get("connection") is String or operation.connection.length() != 64 or not operation.connection.is_valid_hex_number(false):
			return false
		if operation.get("state") not in ["started", "verified"] or (index < operations.size() - 1 and operation.state != "verified"):
			return false
		var progress: Variant = operation.get("progress")
		if not (progress is int or progress is float) or not is_finite(float(progress)) or progress < -1 or progress > 100:
			return false
	return true

func _valid_publication(journal: Variant) -> bool:
	if not journal is Dictionary or not journal.get("artifact") is Dictionary or not journal.get("source") is String or journal.source.is_empty() or not journal.get("destination") is String or journal.destination.is_empty() or not journal.get("events") is Array or journal.events.is_empty():
		return false
	var previous := ""
	for event in journal.events:
		if not event is Dictionary or not event.get("details") is Dictionary:
			return false
		var phase: Variant = event.get("phase")
		if not ((previous == "" and phase == "prepared") or (previous == "prepared" and phase in ["published", "aborted"]) or (previous == "published" and phase == "imported")):
			return false
		if phase == "prepared" and (not _json_equal(event.details.get("artifact"), journal.artifact) or event.details.get("source") != journal.source or event.details.get("destination") != journal.destination):
			return false
		previous = phase
	return journal.get("phase") == previous

func _valid_mutation(journal: Variant) -> bool:
	if not journal is Dictionary or not journal.get("target") is Dictionary or not journal.get("events") is Array or journal.events.is_empty():
		return false
	var previous := ""
	for event in journal.events:
		if not event is Dictionary or not event.get("details") is Dictionary:
			return false
		var phase: Variant = event.get("phase")
		if not ((previous == "" and phase == "prepared") or (previous == "prepared" and phase in ["applied", "aborted"]) or (previous == "applied" and phase in ["saved", "aborted"])):
			return false
		if phase == "prepared" and not _json_equal(event.details, journal.target):
			return false
		previous = phase
	return journal.get("phase") == previous

func _json_safe(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return true
		TYPE_INT:
			# JSON is read back as doubles; larger integers would lose identity.
			return value >= -9007199254740991 and value <= 9007199254740991
		TYPE_FLOAT:
			return is_finite(value)
		TYPE_ARRAY:
			for item in value:
				if not _json_safe(item):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if not key is String or not _json_safe(value[key]):
					return false
			return true
	return false

func _json_equal(left: Variant, right: Variant) -> bool:
	if (left is int or left is float) and (right is int or right is float):
		return float(left) == float(right)
	if typeof(left) != typeof(right):
		return false
	if left is Dictionary:
		if left.size() != right.size():
			return false
		for key in left:
			if not right.has(key) or not _json_equal(left[key], right[key]):
				return false
		return true
	if left is Array:
		if left.size() != right.size():
			return false
		for i in left.size():
			if not _json_equal(left[i], right[i]):
				return false
		return true
	return left == right

func _save() -> bool:
	if _storage == null or not _storage.commit(JSON.stringify(_data)):
		error = "Cannot commit queue"
		return false
	return true

# The caller's validator must reject unsupported operations and invalid inputs.
# It runs under the same mutex as acceptance and must not call back into the queue.
func append(key: String, operation: String, parameters: Dictionary, validator: Callable) -> Dictionary:
	_mutex.lock()
	var result := _append_locked(key, operation, parameters, validator)
	_mutex.unlock()
	return result

func _append_locked(key: String, operation: String, parameters: Dictionary, validator: Callable) -> Dictionary:
	if not error.is_empty() or _data.is_empty():
		return {"error": "Queue unavailable"}
	if key.is_empty() or operation.is_empty() or not validator.is_valid() or not _json_safe(parameters):
		return {"error": "Invalid submission"}
	for job in _data.jobs:
		if job.submission_key == key:
			if job.operation != operation or not _json_equal(job.parameters, parameters):
				return {"error": "Submission key already used for different work"}
			return {"id": job.id, "sequence": job.sequence, "duplicate": true}
	var validation: Variant = validator.call(operation, parameters.duplicate(true))
	if not validation is String or not validation.is_empty():
		return {"error": str(validation)}
	var sequence: int = _data.jobs.size() + 1
	var id := "%s-%08d" % [_project.sha256_text().substr(0, 12), sequence]
	var job := {"id": id, "sequence": sequence, "submission_key": key, "operation": operation, "parameters": parameters.duplicate(true), "state": "queued", "attempts": [], "result": {}, "created_at": Time.get_unix_time_from_system()}
	_data.jobs.append(job)
	if not _save():
		_data.jobs.pop_back()
		return {"error": error}
	return {"id": id, "sequence": sequence, "duplicate": false}

func snapshot() -> Dictionary:
	_mutex.lock()
	var copy := _data.duplicate(true)
	_mutex.unlock()
	return copy

func set_paused(paused: bool) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and not _data.is_empty():
		_data.paused = paused
		ok = _save()
	_mutex.unlock()
	return ok

# Dispatch and finish are called by the one owner of the worker slot.
func start_next() -> Dictionary:
	_mutex.lock()
	var result := {}
	if error.is_empty() and not _data.is_empty() and not _data.paused and _data.stop_reason.is_empty():
		var can_start := true
		for job in _data.jobs:
			if job.state in ["running", "failed", "interrupted"]:
				can_start = false
				break
		if can_start:
			for job in _data.jobs:
				if job.state == "queued":
					job.state = "running"
					job.attempts.append({"number": job.attempts.size() + 1, "state": "running", "started_at": Time.get_unix_time_from_system()})
					if _save():
						result = job.duplicate(true)
					break
	_mutex.unlock()
	return result

# Publication records are committed before the publisher crosses each
# irreversible boundary. A prepared/published record is ambiguous until the
# publisher proves either that no effect was installed or that import passed.
func publication(id: String, phase: String, details: Dictionary = {}) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and _json_safe(details):
		for job in _data.jobs:
			if job.id != id or job.state != "running":
				continue
			var attempt: Dictionary = job.attempts.back()
			var journal: Dictionary = attempt.get("publication", {})
			var previous: String = journal.get("phase", "")
			var allowed := (previous == "" and phase == "prepared") or (previous == "prepared" and phase in ["published", "aborted"]) or (previous == "published" and phase == "imported")
			if not allowed:
				break
			if phase == "prepared":
				if not details.get("artifact") is Dictionary or not details.get("source") is String or details.source.is_empty() or not details.get("destination") is String or details.destination.is_empty():
					break
				journal = {"artifact": details.artifact.duplicate(true), "source": details.source, "destination": details.destination, "events": []}
			journal.phase = phase
			journal.events.append({"phase": phase, "at": Time.get_unix_time_from_system(), "details": details.duplicate(true)})
			attempt["publication"] = journal
			ok = _save()
			break
	_mutex.unlock()
	return ok

# The journal must already contain validated, project-relative paths and an
# artifact hash. This primitive never replaces a destination. An ambiguous
# outcome remains prepared and forces reconciliation on finish/restart.
func publish_link(id: String, project_root: String) -> String:
	_mutex.lock()
	var result := "unavailable"
	if error.is_empty() and _storage != null:
		for job in _data.jobs:
			if job.id != id or job.state != "running":
				continue
			var journal: Dictionary = job.attempts.back().get("publication", {})
			if journal.get("phase", "") != "prepared":
				break
			result = _storage.link_exclusive(project_root, journal.source, journal.destination)
			if result == "published":
				journal.phase = "published"
			elif result in ["conflict", "invalid_path", "invalid_source", "not_published", "unavailable"]:
				journal.phase = "aborted"
			else:
				break
			journal.events.append({"phase": journal.phase, "at": Time.get_unix_time_from_system(), "details": {"link_result": result}})
			if not _save():
				result = "uncertain"
			break
	_mutex.unlock()
	return result

func publication_same_file(id: String, project_root: String) -> bool:
	_mutex.lock()
	var same := false
	if error.is_empty() and _storage != null:
		for job in _data.jobs:
			if job.id == id and job.state in ["running", "interrupted"] and not job.attempts.is_empty():
				var journal: Dictionary = job.attempts.back().get("publication", {})
				if journal.get("phase", "") in ["prepared", "published", "imported"]:
					same = _storage.same_file(project_root, journal.source, journal.destination)
				break
	_mutex.unlock()
	return same

# Scene changes have their own journal: a crash after preparation must not
# replay the edit, even if the editor did not get as far as saving the scene.
func mutation(id: String, phase: String, details: Dictionary = {}) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and _json_safe(details):
		for job in _data.jobs:
			if job.id != id or job.state != "running":
				continue
			var attempt: Dictionary = job.attempts.back()
			var journal: Dictionary = attempt.get("mutation", {})
			var previous: String = journal.get("phase", "")
			if not ((previous == "" and phase == "prepared") or (previous == "prepared" and phase == "applied") or (previous == "applied" and phase == "saved")):
				break
			if phase == "prepared":
				if details.is_empty():
					break
				journal = {"target": details.duplicate(true), "events": []}
			journal.phase = phase
			journal.events.append({"phase": phase, "at": Time.get_unix_time_from_system(), "details": details.duplicate(true)})
			attempt["mutation"] = journal
			ok = _save()
			break
	_mutex.unlock()
	return ok

# Persist before making any device request. A failed or cancelled request may
# still be running remotely, so only a verified completion can finish it.
func device_started(id: String) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty():
		for job in _data.jobs:
			if job.id == id and job.state == "running":
				if job.attempts.back().get("device_started", false):
					ok = true
				else:
					job.attempts.back()["device_started"] = true
					ok = _save()
				break
	_mutex.unlock()
	return ok

# A completed device request has a known remote outcome even when the local
# response is rejected by protocol or validation checks. This distinction keeps
# a deterministic tool/protocol error from being reported as device uncertainty.
func confirm_device_request(id: String) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty():
		for job in _data.jobs:
			if job.id == id and job.state == "running" and not job.attempts.is_empty():
				var attempt: Dictionary = job.attempts.back()
				if not attempt.get("device_started", false):
					break
				attempt["device_confirmed"] = true
				ok = _save()
				break
	_mutex.unlock()
	return ok

# Record the precise model command and its device binding before starting the
# CLI. The same attempt can contain several commands, but only after the prior
# one was confirmed from device state. No credentials are stored in the queue.
func begin_device_operation(id: String, verb: String, model: String, connection: String) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and verb in ["download", "load", "unload"] and not model.is_empty() and model.length() <= 512 and connection.length() == 64 and connection.is_valid_hex_number(false):
		for job in _data.jobs:
			if job.id != id or job.state != "running":
				continue
			var attempt: Dictionary = job.attempts.back()
			var operations: Array = attempt.get("device_operations", [])
			if operations.size() >= 128 or (not operations.is_empty() and operations.back().state != "verified"):
				break
			attempt["device_started"] = true
			operations.append({"verb": verb, "model": model, "connection": connection, "state": "started", "progress": -1.0})
			attempt["device_operations"] = operations
			ok = _save()
			break
	_mutex.unlock()
	return ok

# Progress is advisory device-reported information, never evidence of success.
func device_operation_progress(id: String, percent: float) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and is_finite(percent) and percent >= 0 and percent <= 100:
		for job in _data.jobs:
			if job.id != id or job.state != "running":
				continue
			var operations: Array = job.attempts.back().get("device_operations", [])
			if operations.is_empty() or operations.back().state != "started":
				break
			operations.back().progress = percent
			ok = _save()
			break
	_mutex.unlock()
	return ok

# The caller must first confirm the effect from fresh bound-device inventory.
func verify_device_operation(id: String) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty():
		for job in _data.jobs:
			if job.id != id or job.state != "running":
				continue
			var operations: Array = job.attempts.back().get("device_operations", [])
			if operations.is_empty() or operations.back().state != "started":
				break
			operations.back().state = "verified"
			ok = _save()
			break
	_mutex.unlock()
	return ok

# An inventory observation is evidence for the user, not proof that a remote
# process has stopped. It never changes the interrupted state or enables retry.
func observe_device_operation(id: String, observation: Dictionary) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and _json_safe(observation) and observation.size() <= 10 and JSON.stringify(observation).length() <= 4096:
		for job in _data.jobs:
			if job.id != id or job.state != "interrupted" or job.attempts.is_empty():
				continue
			var attempt: Dictionary = job.attempts.back()
			var operations: Array = attempt.get("device_operations", [])
			if operations.is_empty(): break
			var last: Dictionary = operations.back()
			if observation.get("connection") != last.connection or observation.get("model") != last.model or observation.get("verb") != last.verb:
				break
			attempt["device_observation"] = observation.duplicate(true)
			ok = _save()
			break
	_mutex.unlock()
	return ok

# Called only by the scene verifier after it has inspected both the saved
# scene and the current clean editor scene. The decision is durably recorded.
func reconcile_scene(id: String, outcome: String, evidence: Dictionary) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and outcome in ["not_applied", "completed"] and _json_safe(evidence):
		for job in _data.jobs:
			if job.id != id or job.state != "interrupted" or job.operation != "attach_tree_to_scene":
				continue
			var attempt: Dictionary = job.attempts.back()
			var journal: Dictionary = attempt.get("mutation", {})
			var phase: String = journal.get("phase", "")
			if phase not in ["prepared", "applied", "saved"]:
				break
			if outcome == "not_applied":
				if phase == "saved" or evidence.get("scene_sha256") != journal.target.get("scene_sha256"):
					break
				journal.phase = "aborted"
				journal.events.append({"phase": "aborted", "at": Time.get_unix_time_from_system(), "details": evidence.duplicate(true)})
				job.state = "failed"
				job.result = {"error": "Verified scene unchanged; choose retry or skip", "evidence": evidence.duplicate(true)}
				_data.stop_reason = "Verified scene unchanged; choose retry or skip"
			else:
				if evidence.get("mutation_token") != journal.target.get("mutation_token") or not evidence.get("scene_sha256") is String or evidence.scene_sha256.length() != 64:
					break
				if phase == "prepared":
					journal.events.append({"phase": "applied", "at": Time.get_unix_time_from_system(), "details": {"reconciled": true}})
					phase = "applied"
				if phase == "applied":
					journal.events.append({"phase": "saved", "at": Time.get_unix_time_from_system(), "details": evidence.duplicate(true)})
				journal.phase = "saved"
				job.state = "completed"
				job.result = evidence.duplicate(true)
				_data.stop_reason = ""
				_data.paused = true
			attempt.state = job.state
			attempt["result"] = job.result.duplicate(true)
			attempt["reconciled_at"] = Time.get_unix_time_from_system()
			ok = _save()
			break
	_mutex.unlock()
	return ok

func finish(id: String, state: String, result: Dictionary) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and state in ["completed", "failed", "cancelled", "interrupted"] and _json_safe(result):
		for job in _data.jobs:
			if job.id == id and job.state == "running":
				var journal: Dictionary = job.attempts.back().get("publication", {})
				var phase: String = journal.get("phase", "")
				var mutation_phase: String = job.attempts.back().get("mutation", {}).get("phase", "")
				var device_operations: Array = job.attempts.back().get("device_operations", [])
				if state == "completed" and not device_operations.is_empty() and device_operations.back().state != "verified":
					break
				if phase in ["prepared", "published"] or (phase == "imported" and state != "completed") or (not mutation_phase.is_empty() and (mutation_phase != "saved" or state != "completed")) or (job.attempts.back().get("device_started", false) and state != "completed" and not job.attempts.back().get("device_confirmed", false)):
					# A failure after a publication boundary or an unconfirmed
					# device request cannot safely be retried until a reconciler
					# establishes what was installed or stopped.
					state = "interrupted"
					result = result.duplicate(true)
					var reason := str(result.get("error", "")).strip_edges()
					result["error"] = "Recorded effect requires reconciliation" if reason.is_empty() else "Recorded effect requires reconciliation: " + reason
				elif state == "completed" and phase == "aborted":
					break
				job.state = state
				job.result = result.duplicate(true)
				job.attempts.back().state = state
				job.attempts.back()["result"] = result.duplicate(true)
				job.attempts.back().finished_at = Time.get_unix_time_from_system()
				if state != "completed":
					_data.stop_reason = str(result.get("error", state))
					if _data.stop_reason.is_empty():
						_data.stop_reason = state
				ok = _save()
				break
	_mutex.unlock()
	return ok

func resolve(id: String, decision: String) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and decision in ["retry", "skip"]:
		for job in _data.jobs:
			# An interrupted worker may still have published an effect. Only a
			# reconciler can classify it before retry or skip becomes available.
			if job.id == id and job.state in ["failed", "cancelled"]:
				job.state = "queued" if decision == "retry" else "skipped"
				job["resolution"] = {"decision": decision, "at": Time.get_unix_time_from_system()}
				if not job.attempts.is_empty():
					job.attempts.back()["resolution"] = job.resolution.duplicate(true)
				_data.stop_reason = ""
				# Resolving the stopped position and resuming dispatch are separate
				# explicit user actions.
				_data.paused = true
				ok = _save()
				break
	_mutex.unlock()
	return ok

# Cancelling a job that has not started is terminal and does not stop later
# queued work: no worker or remote effect exists yet.
func cancel_queued(id: String) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty():
		for job in _data.jobs:
			if job.id == id and job.state == "queued" and job.attempts.is_empty():
				job.state = "cancelled"
				job.result = {"error": "Cancelled before start"}
				job["cancelled_at"] = Time.get_unix_time_from_system()
				ok = _save()
				break
	_mutex.unlock()
	return ok

# The user explicitly abandons a device-uncertain job after confirming its
# remote outcome. Only device work without a recorded workspace effect
# qualifies; publication and scene mutations still need their verifier.
func abandon(id: String) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty():
		for job in _data.jobs:
			if job.id == id and job.state == "interrupted" and not job.attempts.is_empty():
				var attempt: Dictionary = job.attempts.back()
				if not attempt.get("device_started", false) or attempt.has("mutation") or attempt.has("publication"):
					break
				job.state = "skipped"
				job["resolution"] = {"decision": "abandon", "at": Time.get_unix_time_from_system()}
				attempt["resolution"] = job.resolution.duplicate(true)
				_data.stop_reason = ""
				# Resolving the stopped position and resuming dispatch are separate
				# explicit user actions.
				_data.paused = true
				ok = _save()
				break
	_mutex.unlock()
	return ok

# Clearing is a UI concern: keep the history record but hide terminal jobs so
# sequence numbers and result references stay stable across restarts.
func hide(id: String) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty():
		for job in _data.jobs:
			if job.id == id and (job.state in ["completed", "skipped"] or (job.state == "cancelled" and job.attempts.is_empty())) and not job.get("hidden", false):
				job["hidden"] = true
				ok = _save()
				break
	_mutex.unlock()
	return ok

func hide_state(state: String) -> int:
	_mutex.lock()
	var count := 0
	if error.is_empty() and state in ["completed", "skipped"]:
		for job in _data.jobs:
			if job.state == state and not job.get("hidden", false):
				job["hidden"] = true
				count += 1
		if count > 0 and not _save():
			count = 0
	_mutex.unlock()
	return count

# Call only after a worker-specific reconciler has established the outcome.
# "failed" means it proved no effect was published; ambiguous outcomes remain
# interrupted. A completed result must already have passed output validation.
func reconcile(id: String, outcome: String, result: Dictionary) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and outcome in ["completed", "failed"] and _json_safe(result):
		for job in _data.jobs:
			if job.id == id and job.state == "interrupted":
				# Scene-effect reconciliation requires a scene-specific verifier.
				if job.attempts.back().has("mutation") or job.attempts.back().has("device_started"):
					break
				var journal: Dictionary = job.attempts.back().get("publication", {})
				var phase: String = journal.get("phase", "")
				if outcome == "failed" and phase in ["published", "imported"]:
					break
				if phase == "prepared":
					var reconciled_phase := "published" if outcome == "completed" else "aborted"
					journal.events.append({"phase": reconciled_phase, "at": Time.get_unix_time_from_system(), "details": {"reconciled": true}})
					journal.phase = reconciled_phase
				if outcome == "completed" and journal.get("phase", "") == "published":
					journal.events.append({"phase": "imported", "at": Time.get_unix_time_from_system(), "details": {"reconciled": true}})
					journal.phase = "imported"
				job.state = outcome
				job.result = result.duplicate(true)
				job.attempts.back().state = outcome
				job.attempts.back()["result"] = result.duplicate(true)
				job.attempts.back().reconciled_at = Time.get_unix_time_from_system()
				_data.stop_reason = "" if outcome == "completed" else "Reconciled failure requires a decision"
				if outcome == "completed":
					_data.paused = true
				ok = _save()
				break
	_mutex.unlock()
	return ok
