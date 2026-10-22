## Feature flags & experiments state: values returned by PostHog's `/flags`
## endpoint, their payloads, a disk cache and local overrides. Experiments are
## multivariate feature flags, so the same store serves both.
class_name PostHogFlags
extends RefCounted

const CACHE_PATH := "user://posthog_flags.json"

## key -> true / false (boolean flag) or String (multivariate variant).
var flags: Dictionary = {}
## key -> payload (parsed JSON when possible).
var payloads: Dictionary = {}
## True once a response (or a cache for the current distinct_id) was applied.
var loaded := false
## Local overrides for testing; they win over remote values.
var overrides: Dictionary = {}
## Person properties sent with the `/flags` request (targeting by version, platform...).
var person_properties: Dictionary = {}

var _reported: Dictionary = {}


## Value of a flag: bool, variant String, or null when the flag is unknown.
func get_value(key: String) -> Variant:
	if overrides.has(key):
		return overrides[key]
	return flags.get(key)


func get_payload(key: String) -> Variant:
	return payloads.get(key)


func is_overridden(key: String) -> bool:
	return overrides.has(key)


## Active flags (enabled, with overrides applied), used for `$active_feature_flags`
## and the `$feature/<key>` event properties.
func effective() -> Dictionary:
	var merged := flags.duplicate()
	merged.merge(overrides, true)
	var active := {}
	for key: String in merged:
		if merged[key] is String or merged[key] == true:
			active[key] = merged[key]
	return active


## True the first time (key, value) is reported for `$feature_flag_called`.
func should_report(key: String, value: Variant) -> bool:
	var token := "%s=%s" % [key, str(value)]
	if _reported.has(token):
		return false
	_reported[token] = true
	return true


func forget_reported() -> void:
	_reported.clear()


## Applies a `/flags` response (v2 `flags` map, or v1 `featureFlags` map).
## Returns false when the response carries no usable flags.
func apply_response(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	var new_flags := {}
	var new_payloads := {}
	if data.get("flags") is Dictionary:
		for key: String in data["flags"]:
			var entry: Variant = data["flags"][key]
			if not entry is Dictionary:
				continue
			var variant: Variant = entry.get("variant")
			if variant is String and not (variant as String).is_empty():
				new_flags[key] = variant
			else:
				new_flags[key] = bool(entry.get("enabled", false))
			var metadata: Variant = entry.get("metadata")
			if metadata is Dictionary and metadata.get("payload") != null:
				new_payloads[key] = _decode_payload(metadata["payload"])
	elif data.get("featureFlags") is Dictionary:
		for key: String in data["featureFlags"]:
			new_flags[key] = data["featureFlags"][key]
		if data.get("featureFlagPayloads") is Dictionary:
			for key: String in data["featureFlagPayloads"]:
				new_payloads[key] = _decode_payload(data["featureFlagPayloads"][key])
	else:
		return false
	# Partial results (server could not compute everything): keep what we know.
	if bool(data.get("errorsWhileComputingFlags", false)):
		flags.merge(new_flags, true)
		payloads.merge(new_payloads, true)
	else:
		flags = new_flags
		payloads = new_payloads
	loaded = true
	return true


func save_cache(distinct_id: String) -> void:
	var file := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"id": distinct_id, "flags": flags, "payloads": payloads}))
	file.close()


## Restores the last flags saved for this distinct_id so they are available offline
## and before the first response. Returns true when something was restored.
func load_cache(distinct_id: String) -> bool:
	if not FileAccess.file_exists(CACHE_PATH):
		return false
	var file := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if file == null:
		return false
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not data is Dictionary or data.get("id") != distinct_id:
		return false
	if not data.get("flags") is Dictionary:
		return false
	flags = data["flags"]
	payloads = data.get("payloads", {}) if data.get("payloads") is Dictionary else {}
	loaded = true
	return true


func clear() -> void:
	flags = {}
	payloads = {}
	loaded = false
	_reported.clear()


static func _decode_payload(raw: Variant) -> Variant:
	if raw is String:
		var parsed: Variant = JSON.parse_string(raw)
		return parsed if parsed != null else raw
	return raw
