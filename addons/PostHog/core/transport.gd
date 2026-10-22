## Fire-and-forget HTTP transport (or local JSONL dump in debug mode).
## A child Node so HTTPRequest lives in the tree.
class_name PostHogTransport
extends Node

## Directory for debug dumps (user:// ... events_YYYY-MM-DD.jsonl).
const DEBUG_DIR := "user://posthog_debug"

signal error_occurred(e: Error)
signal api_response(response: Variant)

## When true, send_json() records payloads to DEBUG_DIR instead of the network.
var debug := false

## Shared fire-and-forget POST. The HTTPRequest node is always freed (no leak).
func send_json(url: String, headers: PackedStringArray, payload: Dictionary) -> void:
	if debug:
		_dump(url, payload)
		return
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

## POST that waits for the answer. Returns {"ok": bool, "code": int, "data": Variant};
## `ok` is false on network error, non-2xx status, unparsable body, debug mode or empty url.
func request_json(url: String, headers: PackedStringArray, payload: Dictionary) -> Dictionary:
	var result := {"ok": false, "code": 0, "data": null}
	if debug or url.is_empty():
		return result
	var request := HTTPRequest.new()
	request.timeout = 10.0
	add_child(request)
	var error := request.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		request.queue_free()
		error_occurred.emit(error)
		return result
	var response: Array = await request.request_completed
	request.queue_free()
	result["code"] = int(response[1])
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS or result["code"] < 200 or result["code"] >= 300:
		return result
	var json := JSON.new()
	if json.parse((response[3] as PackedByteArray).get_string_from_utf8()) == OK:
		result["ok"] = true
		result["data"] = json.data
	return result

## Appends the payload as a JSON line to today's debug file. Never sent anywhere.
func _dump(url: String, payload: Dictionary) -> void:
	var date := Time.get_date_string_from_system()
	var path := DEBUG_DIR.path_join("events_%s.jsonl" % date)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DEBUG_DIR))
	# READ_WRITE keeps existing lines; WRITE is only used to create the file.
	var file := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("PostHog: cannot write debug dump %s" % path)
		return
	file.seek_end()
	file.store_line(JSON.stringify({
		"url": url,
		"payload": payload,
	}))
	file.close()
	print("PostHog [DEBUG] → ", path)
	print("PostHog [DEBUG] ", JSON.stringify(payload))

func _emit_response(body: PackedByteArray) -> void:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) == OK:
		api_response.emit(json.data)