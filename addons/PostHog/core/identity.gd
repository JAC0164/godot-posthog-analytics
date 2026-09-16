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

## Create an 8 letter UUID.
static func uuid() -> String:
	var start := "A".to_ascii_buffer()[0]
	var letters: Array = []
	for i in 8:
		var j := randi() % 26
		var letter := char(start + j)
		letters.append(letter)
	return "".join(letters)