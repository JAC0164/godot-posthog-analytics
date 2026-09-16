## Builds OTLP JSON log payloads for the /i/v1/logs endpoint.
class_name PostHogLogs
extends RefCounted

## OTLP log severity levels (https://opentelemetry.io/docs/specs/otel/logs/data-model/).
enum LogLevel { TRACE = 1, DEBUG = 5, INFO = 9, WARN = 13, ERROR = 17, FATAL = 21 }

## Builds a full OTLP resourceLogs payload for a single log record.
static func build(message: String, level: int, attributes: Dictionary, app_name: String, version: String) -> Dictionary:
	var log_record := make_record(message, level, attributes)
	return {
		"resourceLogs": [{
			"resource": {
				"attributes": [
					{"key": "service.name", "value": {"stringValue": app_name}},
					{"key": "service.version", "value": {"stringValue": version}},
				]
			},
			"scopeLogs": [{
				"scope": {},
				"logRecords": [log_record]
			}]
		}]
	}

static func make_record(message: String, level: int, attributes: Dictionary) -> Dictionary:
	var time_nano := int(Time.get_unix_time_from_system()) * 1000000000
	var values := LogLevel.values()
	var idx := values.find(level)
	var severity_text: String = LogLevel.keys()[idx] if idx != -1 else "INFO"
	var otlp_attrs: Array = []
	for key in attributes:
		otlp_attrs.append({"key": str(key), "value": otlp_value(attributes[key])})
	return {
		"timeUnixNano": str(time_nano),
		"severityNumber": level,
		"severityText": severity_text,
		"body": {"stringValue": message},
		"attributes": otlp_attrs,
	}

## Converts a GDScript value into an OTLP AnyValue JSON object.
static func otlp_value(value) -> Dictionary:
	match typeof(value):
		TYPE_BOOL:
			return {"boolValue": value}
		TYPE_INT:
			return {"intValue": str(value)}
		TYPE_FLOAT:
			return {"doubleValue": value}
		_:
			return {"stringValue": str(value)}