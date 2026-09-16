## Fire-and-forget HTTP transport. A child Node so HTTPRequest lives in the tree.
class_name PostHogTransport
extends Node

signal error_occurred(e: Error)
signal api_response(response: Variant)

## Shared fire-and-forget POST. The HTTPRequest node is always freed (no leak).
func send_json(url: String, headers: PackedStringArray, payload: Dictionary) -> void:
	if url.is_empty():
		return
	var request := HTTPRequest.new()
	add_child(request)
	request.request_completed.connect(func(_result, _response_code, _headers, body):
		_emit_response(body)
		request.queue_free()
	)
	var error := request.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		request.queue_free()
		error_occurred.emit(error)

func _emit_response(body: PackedByteArray) -> void:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) == OK:
		api_response.emit(json.data)