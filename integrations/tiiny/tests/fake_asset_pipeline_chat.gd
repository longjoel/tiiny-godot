@tool
extends "res://chat.gd"

var image_responses := 0
var model_submissions := 0
var reference_png := PackedByteArray()
var fixture_glb := PackedByteArray()
var submitted_image_matches := false
var fail_image := false
var timeout_image := false

func _inference_connection() -> Dictionary:
	return {"url": "http://fixture/v1", "host": "fixture", "key": "fixture-key"}

func _asset_http(_url: String, _headers: PackedStringArray, _method: int, body: PackedByteArray, phase: String) -> void:
	var response := PackedByteArray()
	var status := 200
	match phase:
		"submit_image":
			image_responses += 1
			if fail_image:
				status = 500
			else:
				response = JSON.stringify({"data": [{"b64_json": Marshalls.raw_to_base64(reference_png)}]}).to_utf8_buffer()
		"submit_3d":
			model_submissions += 1
			submitted_image_matches = body.find(reference_png[0]) >= 0 and _contains_bytes(body, reference_png)
			if model_submissions == 1:
				status = 500
			else:
				response = JSON.stringify({"data": {"task_id": "fixture-task"}}).to_utf8_buffer()
		"poll_3d":
			response = JSON.stringify({"data": {"status": "completed", "result": {"output": {"glb": Marshalls.raw_to_base64(fixture_glb)}}}}).to_utf8_buffer()
	var result := HTTPRequest.RESULT_TIMEOUT if phase == "submit_image" and timeout_image else HTTPRequest.RESULT_SUCCESS
	_on_asset_response(result, status, PackedStringArray(), response, null, phase)

func _contains_bytes(haystack: PackedByteArray, needle: PackedByteArray) -> bool:
	if needle.is_empty() or haystack.size() < needle.size(): return false
	for index in range(haystack.size() - needle.size() + 1):
		if haystack.slice(index, index + needle.size()) == needle: return true
	return false
