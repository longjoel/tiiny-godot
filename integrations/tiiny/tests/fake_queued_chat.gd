@tool
extends "res://chat.gd"

var submissions: Array[Dictionary] = []
var resource_submissions: Array[HTTPRequest] = []
var context_marker := "queued"
var image_timeout_fixture := false
var image_success_fixture := false
var image_failure_fixture := false
var image_asset_calls := 0

func _manager_ready() -> bool:
	return true

func _editor_context() -> String:
	return "\n\n--- Editor context ---\nMarker: " + context_marker

func _inference_connection() -> Dictionary:
	return {"url": "http://fixture/v1", "host": "fixture", "key": "fixture-queued-secret"}

func _coding_model() -> String:
	return "fixture-model"

func _submit_chat(payload: Dictionary) -> int:
	submissions.append(payload.duplicate(true))
	return OK

func _submit_resource_request(req: HTTPRequest, _connection: Dictionary, _body: String) -> int:
	resource_submissions.append(req)
	return OK

func _generate_image_http(description: String, image_model: String) -> String:
	if image_timeout_fixture:
		return "Error: Simulated image request timeout."
	return await super._generate_image_http(description, image_model)

func _asset_http(url: String, headers: PackedStringArray, method: int, body: PackedByteArray, phase: String) -> void:
	if phase == "submit_image" and (image_timeout_fixture or image_success_fixture or image_failure_fixture):
		image_asset_calls += 1
		if image_timeout_fixture:
			_on_asset_response(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray(), null, phase)
		elif image_failure_fixture:
			_on_asset_response(HTTPRequest.RESULT_SUCCESS, 500, PackedStringArray(), PackedByteArray(), null, phase)
		else:
			var png := Image.create(2, 2, false, Image.FORMAT_RGBA8)
			png.fill(Color.RED)
			var response := JSON.stringify({"data": [{"b64_json": Marshalls.raw_to_base64(png.save_png_to_buffer())}]}).to_utf8_buffer()
			_on_asset_response(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), response, null, phase)
		return
	super._asset_http(url, headers, method, body, phase)
