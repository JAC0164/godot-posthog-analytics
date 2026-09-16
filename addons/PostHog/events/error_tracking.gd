## Builds PostHog Error Tracking (`$exception`) capture payloads.
class_name PostHogErrorTracking
extends RefCounted

## Builds the `data` object for a `$exception` event.
## `stacktrace` is a multi-line string; simple lines "filename:lineno[:in function]"
## are parsed into stack frames. `extra` is merged into the event properties.
static func build(event_type: String, message: String, stacktrace: String, extra: Dictionary, auto_props: Dictionary, distinct_id: String, api_key: String) -> Dictionary:
	var properties := extra.duplicate()
	properties.merge(auto_props)
	properties["distinct_id"] = distinct_id
	properties["$exception_list"] = [{
		"type": event_type,
		"value": message,
		"mechanism": {"handled": true, "synthetic": false},
		"stacktrace": parse_stacktrace(stacktrace),
	}]
	properties["$exception_fingerprint"] = (event_type + ":" + message).sha256_text()
	properties["$exception_level"] = "error"
	return {
		"api_key": api_key,
		"distinct_id": distinct_id,
		"event": "$exception",
		"properties": properties,
	}

## Parses "filename:lineno[:in function]" lines into PostHog stack frames.
static func parse_stacktrace(stacktrace: String) -> Dictionary:
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