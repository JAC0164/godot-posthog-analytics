## PostHog configuration loaded from `res://addons/PostHog/config.cfg`.
class_name PostHogConfig
extends RefCounted

const CONFIG_PATH := "res://addons/PostHog/config.cfg"
const CONFIG_SECTION := "posthog/config"

var api_key := ""
var capture_url := ""
var log_url := ""
var enabled := true
## Debug mode: when true, transport records payloads locally instead of sending.
var debug := false
## Session tracking (PostHog `$session_id` + foreground heartbeats).
var session_enabled := true
var heartbeat_interval := 60
var session_idle_timeout := 1800
var session_max_duration := 86400
## Feature flags & experiments (`/flags` endpoint).
var flags_enabled := true
## Fetch flags automatically at startup and after identify()/reset().
var flags_auto_load := true
## Add `$active_feature_flags` and `$feature/<key>` to every captured event
## (required to attribute experiment metrics to a variant).
var flags_attach_to_events := true
var flags_url := ""
var heartbeat_event_name := "heartbeat"
var app_background_event_name := "$app_background"
var app_foreground_event_name := "$app_foreground"

## Reads config.cfg (supabase-style). Disables analytics when the file is
## missing or apiKey/baseUrl are empty.
func load() -> bool:
	var config := ConfigFile.new()
	var err := config.load(CONFIG_PATH)
	if err != OK:
		print(CONFIG_PATH, " not found")
		print("Analytics disabled")
		enabled = false
		return false
	api_key = config.get_value(CONFIG_SECTION, "apiKey", "")
	var base_url: String = config.get_value(CONFIG_SECTION, "baseUrl", "")
	if api_key.is_empty() or base_url.is_empty():
		print("posthog/config incomplete in ", CONFIG_PATH)
		print("Analytics disabled")
		enabled = false
		return false
	debug = bool(config.get_value(CONFIG_SECTION, "debug", false))
	session_enabled = bool(config.get_value(CONFIG_SECTION, "sessionEnabled", session_enabled))
	heartbeat_interval = int(config.get_value(CONFIG_SECTION, "heartbeatInterval", heartbeat_interval))
	session_idle_timeout = int(config.get_value(CONFIG_SECTION, "sessionIdleTimeout", session_idle_timeout))
	session_max_duration = int(config.get_value(CONFIG_SECTION, "sessionMaxDuration", session_max_duration))
	heartbeat_event_name = String(config.get_value(CONFIG_SECTION, "heartbeatEventName", heartbeat_event_name))
	app_background_event_name = String(config.get_value(CONFIG_SECTION, "appBackgroundEvent", app_background_event_name))
	app_foreground_event_name = String(config.get_value(CONFIG_SECTION, "appForegroundEvent", app_foreground_event_name))
	flags_enabled = bool(config.get_value(CONFIG_SECTION, "flagsEnabled", flags_enabled))
	flags_auto_load = bool(config.get_value(CONFIG_SECTION, "flagsAutoLoad", flags_auto_load))
	flags_attach_to_events = bool(config.get_value(CONFIG_SECTION, "flagsAttachToEvents", flags_attach_to_events))
	flags_url = base_url.path_join("flags/?v=2")
	capture_url = base_url.path_join("i/v0/e/")
	log_url = base_url.path_join("i/v1/logs")
	return enabled