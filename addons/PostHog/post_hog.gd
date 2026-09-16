## PostHog Analytics facade.
## Public API: PostHog.capture(), PostHog.capture_exception(), PostHog.log(),
## PostHog.enabled, PostHog.anonymous_events, PostHog.auto_include_properties,
## signals error_occurred / api_response, enum PostHog.LogLevel.
extends Node

const HOGQL_LOG := preload("res://addons/PostHog/logs/otlp_log.gd")

## Re-exposed so callers can use PostHog.LogLevel.ERROR.
const LogLevel := HOGQL_LOG.LogLevel

signal error_occurred(e: Error)
signal api_response(response: Variant)

var enabled := true
## Debug mode: payloads are dumped locally (user://posthog_debug/*.jsonl) and
## never sent. Mirrors `debug` in config.cfg after _ready().
var debug := false
## https://posthog.com/docs/data/anonymous-vs-identified-events
var anonymous_events := true:
	set = _update_anonymous_events

## Properties included in every event.
var auto_include_properties := {}

## Whether the platform should be included in every event.
@export var include_platform := true

## Service name sent with log records (used as OTLP `service.name` resource attribute).
@export var app_name := "godot"

## Log records below this level are discarded.
@export var min_log_level: int = LogLevel.DEBUG

var _config: PostHogConfig
var _identity: PostHogIdentity
var _transport: PostHogTransport

func _ready() -> void:
	_update_anonymous_events(anonymous_events)
	_config = PostHogConfig.new()
	_config.load()
	enabled = _config.enabled
	debug = _config.debug
	_identity = PostHogIdentity.new()
	_identity.load()
	_transport = PostHogTransport.new()
	_transport.name = "PostHogTransport"
	_transport.debug = debug
	add_child(_transport)
	_transport.error_occurred.connect(error_occurred.emit)
	_transport.api_response.connect(api_response.emit)
	if include_platform:
		auto_include_properties["platform"] = get_os_platform()
	if app_name.is_empty():
		app_name = ProjectSettings.get_setting("application/config/name", "godot")

func capture(event_name: String, properties: Dictionary = {}) -> void:
	if not enabled:
		return
	var data := PostHogCapture.build(event_name, properties, auto_include_properties, distinct_id(), _config.api_key)
	_transport.send_json(_config.capture_url, _json_headers(), data)

## Sends an exception to PostHog Error Tracking (as a `$exception` capture event).
func capture_exception(type: String, message: String, stacktrace: String = "", extra: Dictionary = {}) -> void:
	if not enabled:
		return
	var data := PostHogErrorTracking.build(type, message, stacktrace, extra, auto_include_properties, distinct_id(), _config.api_key)
	_transport.send_json(_config.capture_url, _json_headers(), data)

## Sends a log record to PostHog Logs (OTLP JSON via /i/v1/logs).
## `level` must be a LogLevel value. `attributes` are extra OTLP attributes.
func log(message: String, level: int = LogLevel.INFO, attributes: Dictionary = {}) -> void:
	if not enabled or OS.has_feature("web"):
		return
	if _config.log_url.is_empty() or level < min_log_level:
		return
	var payload := HOGQL_LOG.build(message, level, attributes, app_name, ProjectSettings.get_setting("application/config/version", ""))
	var headers := _json_headers()
	headers.append("Authorization: Bearer " + _config.api_key)
	_transport.send_json(_config.log_url, headers, payload)

func is_ready() -> bool:
	return _config != null and _config.enabled

func distinct_id() -> String:
	return _identity.distinct_id if _identity else ""

## Updates the auto_include_properties for anonymous events.
func _update_anonymous_events(val: bool) -> void:
	anonymous_events = val
	auto_include_properties["$process_person_profile"] = !anonymous_events

func _json_headers() -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/json"])

## Grabs the host OS platform.
static func get_os_platform() -> String:
	# First platform found in list is returned.
	var platforms := [
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