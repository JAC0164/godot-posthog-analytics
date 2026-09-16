extends Node

## OTLP log severity levels (https://opentelemetry.io/docs/specs/otel/logs/data-model/).
enum LogLevel { TRACE = 1, DEBUG = 5, INFO = 9, WARN = 13, ERROR = 17, FATAL = 21 }

const USER_FILE_PATH = "user://posthog_user.json"
const CONFIG_PATH = "res://addons/PostHog/config.cfg"
const CONFIG_SECTION = "posthog/config"

var api_key = ""
var capture_url = ""
var log_url = ""
var distinct_id = ""
## https://posthog.com/docs/data/anonymous-vs-identified-events
var anonymous_events = true:
	set = _update_anonymous_events
var enabled = true

signal error_occurred(e: Error)
signal api_response(response: Variant)

## Properties included in every event.
var auto_include_properties = {}

## Whether the platform should be included in every event.
@export var include_platform = true

## Service name sent with log records (used as OTLP `service.name` resource attribute).
@export var app_name = "godot"

## Log records below this level are discarded.
@export var min_log_level: int = LogLevel.DEBUG

func _ready() -> void:
	_update_anonymous_events(anonymous_events)
	load_config()
	_load_post_hog_user_json()
	if include_platform:
		auto_include_properties["platform"] = get_os_platform()
	if app_name.is_empty():
		app_name = ProjectSettings.get_setting("application/config/name", "godot")

func capture(event_name: String, properties: Dictionary = {}) -> void:
	if not enabled:
		return
	var merged := properties.duplicate()
	merged.merge(auto_include_properties)
	var data := {
		"api_key": api_key,
		"distinct_id": distinct_id,
		"event": event_name,
		"properties": merged,
	}
	_send_json(capture_url, _json_headers(), data)

## Sends an exception to PostHog Error Tracking (as a `$exception` capture event).
## `stacktrace` is a multi-line string; simple lines "filename:lineno[:in function])"
## are parsed into stack frames. `extra` is merged into the event properties.
func capture_exception(type: String, message: String, stacktrace: String = "", extra: Dictionary = {}) -> void:
	if not enabled:
		return
	var properties := extra.duplicate()
	properties.merge(auto_include_properties)
	properties["distinct_id"] = distinct_id
	properties["$exception_list"] = [{
		"type": type,
		"value": message,
		"mechanism": {"handled": true, "synthetic": false},
		"stacktrace": _parse_stacktrace(stacktrace),
	}]
	properties["$exception_fingerprint"] = (type + ":" + message).sha256_text()
	properties["$exception_level"] = "error"
	var data := {
		"api_key": api_key,
		"distinct_id": distinct_id,
		"event": "$exception",
		"properties": properties,
	}
	_send_json(capture_url, _json_headers(), data)

## Sends a log record to PostHog Logs (OTLP JSON via /i/v1/logs).
## `level` must be a LogLevel value. `attributes` are extra OTLP attributes.
func log(message: String, level: int = LogLevel.INFO, attributes: Dictionary = {}) -> void:
	if not enabled or OS.has_feature("web"):
		return
	if log_url.is_empty() or level < min_log_level:
		return
	var log_record := _make_log_record(message, level, attributes)
	var payload := {
		"resourceLogs": [{
			"resource": {
				"attributes": [
					{"key": "service.name", "value": {"stringValue": app_name}},
					{"key": "service.version", "value": {"stringValue": ProjectSettings.get_setting("application/config/version", "")}},
				]
			},
			"scopeLogs": [{
				"scope": {},
				"logRecords": [log_record]
			}]
		}]
	}
	var headers := _json_headers()
	headers.append("Authorization: Bearer " + api_key)
	_send_json(log_url, headers, payload)

func _make_log_record(message: String, level: int, attributes: Dictionary) -> Dictionary:
	var time_nano := int(Time.get_unix_time_from_system()) * 1000000000
	var values := LogLevel.values()
	var idx := values.find(level)
	var severity_text: String = LogLevel.keys()[idx] if idx != -1 else "INFO"
	var otlp_attrs: Array = []
	for key in attributes:
		otlp_attrs.append({"key": str(key), "value": _otlp_value(attributes[key])})
	return {
		"timeUnixNano": str(time_nano),
		"severityNumber": level,
		"severityText": severity_text,
		"body": {"stringValue": message},
		"attributes": otlp_attrs,
	}

## Converts a GDScript value into an OTLP AnyValue JSON object.
func _otlp_value(value) -> Dictionary:
	match typeof(value):
		TYPE_BOOL:
			return {"boolValue": value}
		TYPE_INT:
			return {"intValue": str(value)}
		TYPE_FLOAT:
			return {"doubleValue": value}
		_:
			return {"stringValue": str(value)}

func _parse_stacktrace(stacktrace: String) -> Dictionary:
	var frames: Array = []
	if not stacktrace.is_empty():
		var re := RegEx.new()
		re.compile(r"(.+?):([0-9]+)(?::in (.+))?")
		for raw_line in stacktrace.split("\n", false):
			var line := raw_line.strip_edges()
			if line.is_empty():
				continue
			var frame := {"platform": "custom", "lang": "gdscript", "resolved": true, "in_app": true}
			var result := re.search(line)
			if result:
				frame["filename"] = result.get_string(1)
				frame["lineno"] = int(result.get_string(2))
				if not result.get_string(3).is_empty():
					frame["function"] = result.get_string(3)
			else:
				frame["function"] = line
			frames.append(frame)
	return {"type": "raw", "frames": frames}

func _json_headers() -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/json"])

## Shared fire-and-forget POST. The HTTPRequest node is always freed (no leak).
func _send_json(url: String, headers: PackedStringArray, payload: Dictionary) -> void:
	if url.is_empty():
		return
	var request = HTTPRequest.new()
	add_child(request)
	request.request_completed.connect(func(_result, _response_code, _headers, body) -> void:
		_emit_response(body)
		request.queue_free()
	)
	var error := request.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		request.queue_free()
		error_occurred.emit(error)

func _emit_response(body: PackedByteArray) -> void:
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) == OK:
		api_response.emit(json.data)

func load_config():
	var config = ConfigFile.new()
	var err := config.load(CONFIG_PATH)
	if err != OK:
		print(CONFIG_PATH, ' not found')
		print('Analytics disabled')
		enabled = false
		return
	api_key = config.get_value(CONFIG_SECTION, "apiKey", "")
	var base_url: String = config.get_value(CONFIG_SECTION, "baseUrl", "")
	if api_key.is_empty() or base_url.is_empty():
		print('posthog/config incomplete in ', CONFIG_PATH)
		print('Analytics disabled')
		enabled = false
		return
	capture_url = base_url.path_join('i/v0/e/')
	log_url = base_url.path_join('i/v1/logs')

## Gets specfic user data for this device, or creates it.
func _load_post_hog_user_json():
	var data = {}
	if FileAccess.file_exists(USER_FILE_PATH):
		var user_post_hog_file = FileAccess.open(USER_FILE_PATH, FileAccess.READ)
		var data_content = user_post_hog_file.get_as_text()
		user_post_hog_file.close()
		data = JSON.parse_string(data_content)
	else:
		data = {
			"id": uuid()
		}
		var user_post_hog_file = FileAccess.open(USER_FILE_PATH, FileAccess.WRITE)
		user_post_hog_file.store_string(JSON.stringify(data))
		user_post_hog_file.close()
	distinct_id = data.id

## Updates the auto_include_properties for anonymous events.
func _update_anonymous_events(val: bool):
	anonymous_events = val
	auto_include_properties["$process_person_profile"] = !anonymous_events
	

## Create an 8 letter UUID.
static func uuid() -> String:
	var start = "A".to_ascii_buffer()[0]
	var letters = [];
	for i in 8:
		var j = randi() % 26
		var letter = char(start + j)
		letters.append(letter)
	return "".join(letters)

## Grabs the host OS platform.
static func get_os_platform() -> String:
	# First platform found in list is returned.
	var platforms = [
		"windows",
		"linux",
		"macos",
		"android",
		"ios",
		"web_android",
		"web_ios",
		"web_linuxbsd",
		"web_macos",
		"web_windows",
		"web",
		"pc",
		"mobile"
	]
	for platform in platforms:
		if OS.has_feature(platform):
			return platform
	return "unknown"