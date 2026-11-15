@tool
extends "res://fake_queued_chat.gd"

func _manager_ready() -> bool:
	var manager := get_tree().get_first_node_in_group("tiiny_setup_manager")
	return manager != null and manager.is_ready()

func _coding_model() -> String:
	return "code"
