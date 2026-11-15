@tool
extends Node

var callbacks: Array[Callable] = []

func generate_shape_for_dialog(_description: String, callback: Callable) -> void:
	callbacks.append(callback)
