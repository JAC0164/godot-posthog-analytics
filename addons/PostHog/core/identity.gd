## Identity: a per-device distinct_id stored in `user://`. Once `identify()` is
## used, `distinct_id` is the real user id (merged with the anonymous history via
## the `$identify` event sent by PostHog.identify()).
class_name PostHogIdentity
extends RefCounted

const USER_FILE_PATH := "user://posthog_user.json"

var distinct_id := ""
## True once the user has been identified (PostHog.identify()) on this install.
var has_identified := false

## Loads the stored distinct_id, or generates and persists a new one.
func load() -> void:
	var data := {}
	if FileAccess.file_exists(USER_FILE_PATH):
		var user_file := FileAccess.open(USER_FILE_PATH, FileAccess.READ)
		var content := user_file.get_as_text()
		user_file.close()
		data = JSON.parse_string(content)
		if not data is Dictionary:
			data = {}
	distinct_id = data.get("id", "")
	has_identified = bool(data.get("identified", false))
	if distinct_id.is_empty():
		distinct_id = uuid()
		_save({"id": distinct_id})

## Switches the identity to the identified user id and persists it. Returns false
## when the id is unchanged or empty (avoids re-sending `$identify` on every login).
func set_identified(new_id: String) -> bool:
	if new_id.is_empty() or new_id == distinct_id:
		return false
	distinct_id = new_id
	has_identified = true
	_save({"id": distinct_id, "identified": true})
	return true

## Drops the identified identity and generates a fresh anonymous distinct_id.
## Used on logout so the next user on this device starts anonymous again
## (their events are not merged into the previous person's profile).
func reset() -> void:
	distinct_id = uuid()
	has_identified = false
	_save({"id": distinct_id})

func _save(data: Dictionary) -> void:
	var user_file := FileAccess.open(USER_FILE_PATH, FileAccess.WRITE)
	if user_file == null:
		return
	user_file.store_string(JSON.stringify(data))
	user_file.close()

## Create a 128-bit hex UUID string (128 bits of entropy, negligible collisions).
static func uuid() -> String:
	var hex_chars := "0123456789abcdef"
	var out := ""
	for i in 32:
		out += hex_chars[randi() % 16]
	return out