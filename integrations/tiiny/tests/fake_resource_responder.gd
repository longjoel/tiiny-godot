@tool
extends Node

var callbacks: Array[Callable] = []

func supports_ai_resource_type(type: String) -> bool:
	return type == "ConvexPolygonShape2D"

func generate_shape_for_dialog(_description: String, callback: Callable) -> void:
	callbacks.append(callback)
