## Builds PostHog capture event payloads.
class_name PostHogCapture
extends RefCounted

## Builds the `data` object sent to /i/v0/e/. Merges caller properties with
## `auto_props` (auto-properties included in every event).
static func build(event_name: String, properties: Dictionary, auto_props: Dictionary, distinct_id: String, api_key: String) -> Dictionary:
	var merged := properties.duplicate()
	merged.merge(auto_props)
	return {
		"api_key": api_key,
		"distinct_id": distinct_id,
		"event": event_name,
		"properties": merged,
	}