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
	capture_url = base_url.path_join("i/v0/e/")
	log_url = base_url.path_join("i/v1/logs")
	return enabled