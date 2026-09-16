@tool
extends EditorPlugin


func _enter_tree() -> void:
	add_autoload_singleton("PostHog", "res://addons/PostHog/post_hog.gd")


func _exit_tree() -> void:
	remove_autoload_singleton("PostHog")