## Device identity: a per-device distinct_id stored in `user://`.
class_name PostHogIdentity
extends RefCounted

const USER_FILE_PATH := "user://posthog_user.json"

var distinct_id := ""

## Loads the stored distinct_id, or generates and persists a new one.
func load() -> void:
	var data := {}
	if FileAccess.file_exists(USER_FILE_PATH):
		var user_file := FileAccess.open(USER_FILE_PATH, FileAccess.READ)
		var content := user_file.get_as_text()
		user_file.close()
		data = JSON.parse_string(content)
	else:
		data = {"id": uuid()}
		var user_file := FileAccess.open(USER_FILE_PATH, FileAccess.WRITE)
		user_file.store_string(JSON.stringify(data))
		user_file.close()
	distinct_id = data.id

## Create a 128-bit hex UUID string (128 bits of entropy, negligible collisions).
static func uuid() -> String:
	var hex_chars := "0123456789abcdef"
	var out := ""
	for i in 32:
		out += hex_chars[randi() % 16]
	return out