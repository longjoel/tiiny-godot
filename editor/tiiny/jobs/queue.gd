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
				if attempt.state in ["failed", "cancelled"] or (attempt.state == "completed" and attempt.mutation.phase != "saved"):
					return false
		if job.state in ["running", "completed", "failed", "cancelled", "interrupted"]:
			if job.attempts.is_empty() or job.attempts.back().state != job.state:
				return false
		if pending_seen and job.state != "queued":
			return false
		if job.state in ["queued", "running", "failed", "cancelled", "interrupted"]:
			pending_seen = true
		if job.state == "running":
			running += 1
		if job.state in ["failed", "cancelled", "interrupted"]:
			stopped += 1
		ids[job.id] = true
		keys[job.submission_key] = true
	return running <= 1 and stopped <= 1 and not (running > 0 and stopped > 0) and ((stopped > 0) == not value.stop_reason.is_empty())

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
		if not ((previous == "" and phase == "prepared") or (previous == "prepared" and phase == "applied") or (previous == "applied" and phase == "saved")):
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
			if job.state in ["running", "failed", "cancelled", "interrupted"]:
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

func finish(id: String, state: String, result: Dictionary) -> bool:
	_mutex.lock()
	var ok := false
	if error.is_empty() and state in ["completed", "failed", "cancelled", "interrupted"] and _json_safe(result):
		for job in _data.jobs:
			if job.id == id and job.state == "running":
				var journal: Dictionary = job.attempts.back().get("publication", {})
				var phase: String = journal.get("phase", "")
				var mutation_phase: String = job.attempts.back().get("mutation", {}).get("phase", "")
				if phase in ["prepared", "published"] or (phase == "imported" and state != "completed") or (not mutation_phase.is_empty() and (mutation_phase != "saved" or state != "completed")):
					# A failure after a publication boundary cannot safely be retried
					# until a reconciler establishes what was installed.
					state = "interrupted"
					result = result.duplicate(true)
					result["error"] = "Recorded effect requires reconciliation"
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
				job.attempts.back()["resolution"] = job.resolution.duplicate(true)
				_data.stop_reason = ""
				# Resolving the stopped position and resuming dispatch are separate
				# explicit user actions.
				_data.paused = true
				ok = _save()
				break
	_mutex.unlock()
	return ok

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
				if job.attempts.back().has("mutation"):
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
