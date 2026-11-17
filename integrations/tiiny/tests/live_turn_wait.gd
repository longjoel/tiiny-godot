extends RefCounted

var reason := ""

# Follow the persisted chain, rather than UI state, until the turn is terminal.
func wait_for_turn(tree: SceneTree, jobs: Node, first_id: String, timeout_ms: int) -> bool:
	reason = ""
	var deadline := Time.get_ticks_msec() + timeout_ms
	var id := first_id
	var visited := {}
	while Time.get_ticks_msec() < deadline:
		var job: Dictionary = jobs.get_job_status(id)
		match str(job.get("state", "")):
			"completed":
				var result: Dictionary = job.get("result", {})
				if not bool(result.get("continued", false)):
					if result.get("response") is String and not str(result.response).strip_edges().is_empty():
						return true
					reason = "Final step completed without a response: " + id
					return false
				var next_id := str(result.get("next_job", ""))
				if next_id.is_empty() or visited.has(next_id):
					reason = "Missing or cyclic continuation after " + id
					return false
				visited[id] = true
				id = next_id
			"failed", "cancelled", "interrupted", "skipped":
				reason = "Step %s %s: %s" % [id, str(job.state), str(job.get("result", {}).get("error", ""))]
				return false
			"queued", "running":
				pass
			_:
				reason = "Step %s is unavailable: %s" % [id, str(job.get("error", "unknown state"))]
				return false
		await tree.create_timer(0.5).timeout
	reason = "Turn exceeded %d ms while waiting for %s" % [timeout_ms, id]
	return false
