## PostHog Analytics facade.
## Public API: PostHog.capture(), PostHog.capture_exception(), PostHog.log(),
## PostHog.identify(), PostHog.enabled, PostHog.anonymous_events,
## PostHog.auto_include_properties, PostHog.session_id(), PostHog.distinct_id(),
## PostHog.is_identified(),
## feature flags & experiments: PostHog.is_feature_enabled(), PostHog.get_feature_flag(),
## PostHog.get_feature_flag_payload(), PostHog.get_experiment_variant(),
## PostHog.reload_feature_flags(), PostHog.override_feature_flag(),
## signals error_occurred / api_response / feature_flags_loaded, enum PostHog.LogLevel.
extends Node

const HOGQL_LOG := preload("res://addons/PostHog/logs/otlp_log.gd")

## Re-exposed so callers can use PostHog.LogLevel.ERROR.
const LogLevel := HOGQL_LOG.LogLevel

## Identifies this SDK in PostHog (`$lib` / `$lib_version`).
const LIB_NAME := "godot-posthog"
const LIB_VERSION := "1.2"

signal error_occurred(e: Error)
signal api_response(response: Variant)
## Emitted after flags were (re)loaded from PostHog or restored from the cache.
signal feature_flags_loaded

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

## Whether the reserved device/viewport/app properties (OS, device type,
## screen/viewport size, `$lib`, channel attribution) are included in every
## event. These are what PostHog's dashboards read for the OS / Device Type /
## Viewport / Source columns; without them those columns stay empty/Unknown.
@export var include_device_properties := true

## Service name sent with log records (used as OTLP `service.name` resource attribute).
@export var app_name := "godot"

## Log records below this level are discarded.
@export var min_log_level: int = LogLevel.DEBUG

var _config: PostHogConfig
var _identity: PostHogIdentity
var _transport: PostHogTransport
var _session: PostHogSession
var _flags := PostHogFlags.new()
var _flags_loading := false

## Current foreground state. Guards against platforms (Android) that emit both
## `NOTIFICATION_APPLICATION_*` and `NOTIFICATION_WM_WINDOW_FOCUS_*` for the
## same transition, which would otherwise emit duplicate lifecycle events.
## Starts false so the cold-start foreground transition still emits.
var _app_is_foreground := false

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
	_session = PostHogSession.new()
	_session.name = "PostHogSession"
	_session.enabled = _config.session_enabled
	_session.heartbeat_interval_seconds = _config.heartbeat_interval
	_session.idle_timeout_seconds = _config.session_idle_timeout
	_session.max_session_seconds = _config.session_max_duration
	add_child(_session)
	if _session.enabled:
		_session.heartbeat_tick.connect(_on_heartbeat_tick)
	if app_name.is_empty():
		app_name = ProjectSettings.get_setting("application/config/name", "godot")
	if include_platform:
		auto_include_properties["platform"] = get_os_platform()
	if include_device_properties:
		_populate_auto_properties()
	auto_include_properties["is_dev_build"] = OS.has_feature("editor") or OS.is_debug_build()
	if enabled and _config.flags_enabled:
		if _flags.load_cache(distinct_id()):
			feature_flags_loaded.emit.call_deferred()
		if _config.flags_auto_load:
			reload_feature_flags()

func capture(event_name: String, properties: Dictionary = {}) -> void:
	if not enabled:
		return
	var props := properties.duplicate()
	_inject_session_id(props)
	_inject_feature_flags(props)
	var data := PostHogCapture.build(event_name, props, auto_include_properties, distinct_id(), _config.api_key)
	data["timestamp"] = _now_iso()
	_transport.send_json(_config.capture_url, _json_headers(), data)

## Identifies the user: sends the PostHog `$identify` event so the anonymous
## device history is merged into the real user's profile, then switches the
## local distinct_id to `new_distinct_id` (persisted, used for every event after).
## `user_properties` become person properties (`$set`).
## Returns false when disabled, the id is empty, or the user is already
## identified with this id (no duplicate `$identify` on repeated logins).
func identify(new_distinct_id: String, user_properties: Dictionary = {}) -> bool:
	if not enabled or _identity == null or new_distinct_id.is_empty():
		return false
	var anon_id := _identity.distinct_id
	if not _identity.set_identified(new_distinct_id):
		return false
	# From now on events belong to a real person (profiles processed server-side).
	auto_include_properties["$process_person_profile"] = true
	var props := {
		"distinct_id": new_distinct_id,
		"$set": user_properties.duplicate(),
	}
	if anon_id != new_distinct_id and not anon_id.is_empty():
		props["$anon_distinct_id"] = anon_id
	_inject_session_id(props)
	var data := PostHogCapture.build("$identify", props, auto_include_properties, distinct_id(), _config.api_key)
	data["timestamp"] = _now_iso()
	_transport.send_json(_config.capture_url, _json_headers(), data)
	_flags.forget_reported()
	if _config.flags_enabled and _config.flags_auto_load:
		reload_feature_flags()
	return true

## True once identify() has been called and persisted on this install.
func is_identified() -> bool:
	return _identity != null and _identity.has_identified

## Resets identity to a fresh anonymous distinct_id and restores anonymous-event
## person-processing. To be called on logout: the next session on this device
## starts anonymous again instead of merging into the previous person.
func reset() -> void:
	if _identity == null:
		return
	_identity.reset()
	auto_include_properties["$process_person_profile"] = !anonymous_events
	_flags.clear()
	if enabled and _config.flags_enabled and _config.flags_auto_load:
		reload_feature_flags()

#region Feature flags & experiments
## https://posthog.com/docs/feature-flags  https://posthog.com/docs/experiments
## An experiment is a multivariate feature flag: read its variant with
## get_experiment_variant(), then capture your goal metric as a normal event.
## Events carry `$feature/<key>` automatically so PostHog attributes them to a variant.

## Fetches the flags of the current user from PostHog. Emits `feature_flags_loaded`
## on success; on failure the last known flags (cache) stay in place.
## Safe to call often: a request already in flight is not duplicated.
func reload_feature_flags() -> void:
	if not enabled or _config == null or not _config.flags_enabled or _flags_loading:
		return
	_flags_loading = true
	var body := {
		"api_key": _config.api_key,
		"distinct_id": distinct_id(),
		"person_properties": _flag_person_properties(),
	}
	var asked_id := body["distinct_id"] as String
	var result: Dictionary = await _transport.request_json(_config.flags_url, _json_headers(), body)
	_flags_loading = false
	if not result["ok"] or asked_id != distinct_id():
		return
	if _flags.apply_response(result["data"]):
		_flags.save_cache(asked_id)
		feature_flags_loaded.emit()

## True once flags were loaded (or restored from cache) at least once.
func has_feature_flags() -> bool:
	return _flags.loaded or not _flags.overrides.is_empty()

## Value of a flag: `true` / `false` for a boolean flag, the variant `String` for a
## multivariate flag, `null` when the flag is unknown (not loaded yet or not existing).
## Sends `$feature_flag_called` once per flag and value (needed by experiments).
func get_feature_flag(key: String) -> Variant:
	var value: Variant = _flags.get_value(key)
	if value != null and enabled and not _flags.is_overridden(key) and _flags.should_report(key, value):
		capture("$feature_flag_called", {
			"$feature_flag": key,
			"$feature_flag_response": value,
			"$feature/" + key: value,
		})
	return value

## True when the flag is on (boolean true, or any variant). `default` when unknown.
func is_feature_enabled(key: String, default: bool = false) -> bool:
	var value: Variant = get_feature_flag(key)
	if value == null:
		return default
	return value is String or value == true

## Payload attached to the flag in PostHog (JSON parsed), `null` when none.
func get_feature_flag_payload(key: String) -> Variant:
	return _flags.get_payload(key)

## Variant of an experiment as a String. `default` when the flag is unknown or off
## (loading, offline, user outside the rollout): treat it as the control group.
func get_experiment_variant(key: String, default: String = "control") -> String:
	var value: Variant = get_feature_flag(key)
	return value if value is String else default

## Snapshot of the active flags: key -> true or variant String. Sends no event.
func get_feature_flags() -> Dictionary:
	return _flags.effective()

## Forces a flag locally (QA, previews). It wins over PostHog and sends no
## `$feature_flag_called`. Pass `true`/`false` or a variant String.
func override_feature_flag(key: String, value: Variant) -> void:
	_flags.overrides[key] = value
	feature_flags_loaded.emit()

func clear_feature_flag_overrides() -> void:
	_flags.overrides.clear()
	feature_flags_loaded.emit()

## Extra person properties used by PostHog to target flags (`/flags` request),
## e.g. {"plan": "pro"}. Applied on the next reload_feature_flags().
func set_feature_flag_person_properties(properties: Dictionary) -> void:
	_flags.person_properties.merge(properties, true)

func _flag_person_properties() -> Dictionary:
	var props := {}
	for key: String in ["$app_version", "$os", "$device_type", "platform"]:
		if auto_include_properties.has(key):
			props[key] = auto_include_properties[key]
	props.merge(_flags.person_properties, true)
	return props

## `$active_feature_flags` + `$feature/<key>` on every event, without overriding
## values the caller already set.
func _inject_feature_flags(properties: Dictionary) -> void:
	if _config == null or not _config.flags_enabled or not _config.flags_attach_to_events:
		return
	var active := _flags.effective()
	if active.is_empty():
		return
	if not properties.has("$active_feature_flags"):
		properties["$active_feature_flags"] = active.keys()
	for key: String in active:
		var property := "$feature/" + key
		if not properties.has(property):
			properties[property] = active[key]
#endregion

## Sends an exception to PostHog Error Tracking (as a `$exception` capture event).
func capture_exception(type: String, message: String, stacktrace: String = "", extra: Dictionary = {}) -> void:
	if not enabled:
		return
	var extra_copy := extra.duplicate()
	_inject_session_id(extra_copy)
	_inject_feature_flags(extra_copy)
	var data := PostHogErrorTracking.build(type, message, stacktrace, extra_copy, auto_include_properties, distinct_id(), _config.api_key)
	data["timestamp"] = _now_iso()
	_transport.send_json(_config.capture_url, _json_headers(), data)

## Sends a log record to PostHog Logs (OTLP JSON via /i/v1/logs).
## `level` must be a LogLevel value. `attributes` are extra OTLP attributes.
## Always adds `posthogDistinctId` / `sessionId` attributes so log lines are
## linked to the person and session in PostHog (recommended by the docs).
func log(message: String, level: int = LogLevel.INFO, attributes: Dictionary = {}) -> void:
	if not enabled or OS.has_feature("web"):
		return
	if _config.log_url.is_empty() or level < min_log_level:
		return
	var attrs := attributes.duplicate()
	var did := distinct_id()
	if not did.is_empty():
		attrs["posthogDistinctId"] = did
	var sid := session_id()
	if not sid.is_empty():
		attrs["sessionId"] = sid
	var payload := HOGQL_LOG.build(message, level, attrs, app_name, ProjectSettings.get_setting("application/config/version", ""))
	var headers := _json_headers()
	headers.append("Authorization: Bearer " + _config.api_key)
	_transport.send_json(_config.log_url, headers, payload)

func is_ready() -> bool:
	return _config != null and _config.enabled

func distinct_id() -> String:
	return _identity.distinct_id if _identity else ""

## Current PostHog `$session_id` (empty when sessions are disabled).
func session_id() -> String:
	return _session.session_id() if _session else ""

## ISO-8601 UTC timestamp for capture events. PostHog uses it as the event time;
## without it, the server falls back to the ingestion time.
static func _now_iso() -> String:
	return Time.get_datetime_string_from_system(true, false) + "Z"

## Tracks app foreground state. While in the background the heartbeat is paused
## and an `$app_background` event marks the session end; on resume a fresh
## `$app_foreground` event re-opens activity.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_on_app_background()
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_on_app_foreground()

func _on_heartbeat_tick(_session_id: String) -> void:
	capture(_config.heartbeat_event_name)

func _on_app_background() -> void:
	if not _app_is_foreground:
		return
	_app_is_foreground = false
	if not enabled or not _session or not _session.enabled:
		return
	_session.set_active(false)
	capture(_config.app_background_event_name)

func _on_app_foreground() -> void:
	if _app_is_foreground:
		return
	_app_is_foreground = true
	if not enabled or not _session or not _session.enabled:
		return
	_session.set_active(true)
	capture(_config.app_foreground_event_name)

## Adds the current `$session_id` to the event properties when sessions are on.
func _inject_session_id(properties: Dictionary) -> void:
	if _session and _session.enabled:
		properties["$session_id"] = _session.touch()

## Updates the auto_include_properties for anonymous events.
func _update_anonymous_events(val: bool) -> void:
	anonymous_events = val
	auto_include_properties["$process_person_profile"] = !anonymous_events

func _json_headers() -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/json"])

## Fills the reserved PostHog properties the dashboards rely on: OS / OS version,
## device type, screen & viewport size, app name/version, SDK (`$lib`) and the
## session channel attribution. Without these PostHog shows empty / "Unknown"
## values (OS, Device Type, Viewport, Source channel type).
func _populate_auto_properties() -> void:
	auto_include_properties["$os"] = get_os_name()
	auto_include_properties["$os_version"] = OS.get_version()
	auto_include_properties["$device_type"] = get_device_type()
	auto_include_properties["$app_name"] = app_name
	auto_include_properties["$app_version"] = String(ProjectSettings.get_setting("application/config/version", ""))
	auto_include_properties["$lib"] = LIB_NAME
	auto_include_properties["$lib_version"] = LIB_VERSION

	var tz := Time.get_time_zone_from_system()
	var tz_name := String(tz.get("name", ""))
	if not tz_name.is_empty():
		auto_include_properties["$timezone"] = tz_name
		auto_include_properties["$timezone_offset"] = -int(tz.get("bias", 0))

	var viewport := get_viewport()
	if viewport != null:
		var viewport_size := viewport.get_visible_rect().size
		if viewport_size.x > 0 and viewport_size.y > 0:
			auto_include_properties["$viewport_width"] = int(viewport_size.x)
			auto_include_properties["$viewport_height"] = int(viewport_size.y)

	var screen_size := DisplayServer.screen_get_size()
	if screen_size.x > 0 and screen_size.y > 0:
		auto_include_properties["$screen_width"] = screen_size.x
		auto_include_properties["$screen_height"] = screen_size.y

	# App traffic has no web referrer: mark it as direct so PostHog computes the
	# "Direct" channel type instead of "Unknown" for app sessions.
	auto_include_properties["$referrer"] = "$direct"
	auto_include_properties["$referring_domain"] = "$direct"

## PostHog-friendly OS name (e.g. "Mac OS X" instead of Godot's "macOS").
static func get_os_name() -> String:
	match OS.get_name():
		"macOS":
			return "Mac OS X"
		_:
			return OS.get_name()

## PostHog device type: "Mobile" or "Desktop".
static func get_device_type() -> String:
	if OS.has_feature("android") or OS.has_feature("ios") \
			or OS.has_feature("web_android") or OS.has_feature("web_ios"):
		return "Mobile"
	return "Desktop"

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