## PostHog session tracking. Generates a UUIDv7 `$session_id` and keeps it alive
## while the app is in the foreground, rotating after an idle gap or a maximum
## duration. Mirrors the behaviour of the official SDKs behind PostHog's session
## insights (average engagement duration, retention, stickiness, ...).
## https://posthog.com/docs/product-analytics/sessions/overview
class_name PostHogSession
extends Node

## Emitted on each heartbeat tick while the app is active and the session lives.
## The facade forwards this to a `capture()` so PostHog has a fresh event and can
## keep advancing the session end timestamp.
signal heartbeat_tick(session_id: String)

## Seconds between heartbeats while the app is active. 0 disables heartbeats.
var heartbeat_interval_seconds := 60
## Seconds without any event before a new session is started. 0 disables.
var idle_timeout_seconds := 1800
## Maximum session duration in seconds before rotation. 0 disables.
var max_session_seconds := 86400

var enabled := true
## Horloge en millisecondes (tests). Par défaut l'heure réelle : `Time.get_ticks_msec()` s'arrête
## pendant la veille d'Android, une session restait alors ouverte toute la nuit.
var clock := Callable()

var _session_id := ""
var _session_start_ms := 0
var _last_activity_ms := 0
var _active := true
var _timer: Timer

func _ready() -> void:
	start()

## (Re)starts the session with a fresh session id.
func start() -> void:
	_session_id = _uuidv7()
	_session_start_ms = _now_ms()
	_last_activity_ms = _session_start_ms
	_restart_timer()

## Returns the current session id, starting a new one if the idle or maximum
## window has been exceeded. Call this once per captured event.
func touch() -> String:
	if enabled and _needs_rotate():
		_rotate()
	if enabled:
		_last_activity_ms = _now_ms()
	return _session_id

## Current session id ("" before start()).
func session_id() -> String:
	return _session_id

## Sets whether the app is in the foreground. While inactive the heartbeat timer
## is paused and idle time stops accumulating.
func set_active(active: bool) -> void:
	_active = active
	if _timer:
		_timer.paused = not active

func _needs_rotate() -> bool:
	if not enabled:
		return false
	var now := _now_ms()
	var idle := now - _last_activity_ms
	var total := now - _session_start_ms
	return (idle_timeout_seconds > 0 and idle > idle_timeout_seconds * 1000) \
		or (max_session_seconds > 0 and total > max_session_seconds * 1000)

func _rotate() -> void:
	_session_id = _uuidv7()
	_session_start_ms = _now_ms()
	_last_activity_ms = _session_start_ms

func _on_heartbeat_timeout() -> void:
	if not enabled or not _active:
		return
	if _needs_rotate():
		_rotate()
	_last_activity_ms = _now_ms()
	heartbeat_tick.emit(_session_id)

func _restart_timer() -> void:
	if _timer:
		_timer.stop()
		_timer.queue_free()
		_timer = null
	if enabled and heartbeat_interval_seconds > 0 and get_tree() != null:
		_timer = Timer.new()
		_timer.name = "Heartbeat"
		_timer.wait_time = float(heartbeat_interval_seconds)
		_timer.autostart = true
		add_child(_timer)
		_timer.timeout.connect(_on_heartbeat_timeout)

func _now_ms() -> int:
	if clock.is_valid():
		return int(clock.call())
	return int(Time.get_unix_time_from_system() * 1000.0)

## UUIDv7: 48-bit unix-ms timestamp, version 7, RFC 4122 variant.
## The timestamp is streamed most-significant first: group1 holds the high 32
## bits, group2 the low 16. PostHog requires `$session_id` to be a valid UUIDv7.
## https://www.ietf.org/archive/id/draft-peabody-dispatch-new-uuid-format-04.html
static func _uuidv7() -> String:
	var ms := int(Time.get_unix_time_from_system() * 1000.0)
	var t := "%012x" % ms
	return "%s-%s-7%s-8%s-%s" % [
		t.substr(0, 8),
		t.substr(8, 4),
		"%03x" % (randi() & 0xfff),
		"%03x" % (randi() & 0xfff),
		"%08x%04x" % [randi() & 0xffffffff, randi() & 0xffff],
	]