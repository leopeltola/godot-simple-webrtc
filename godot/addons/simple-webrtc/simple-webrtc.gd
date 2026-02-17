@tool
extends EditorPlugin

const AUTOLOAD_NAME: String = "SimpleWebRTC"
const AUTOLOAD_PATH: String = "res://addons/simple-webrtc/simple_webrtc_singleton.gd"


func _enable_plugin() -> void:
	if not ProjectSettings.has_setting("autoload/%s" % AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _disable_plugin() -> void:
	if ProjectSettings.has_setting("autoload/%s" % AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)


func _enter_tree() -> void:
	pass


func _exit_tree() -> void:
	pass
