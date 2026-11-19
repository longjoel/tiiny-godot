@tool
extends "res://chat.gd"

# Counts approval prompts without creating native dialogs. `allow` simulates
# Cancel; `scope_choice` simulates pressing the plan/turn scope button.
var dialog_calls := 0
var allow := true
var scope_choice := true

func _approval_dialog(_title: String, _text: String, _ok_text: String, _scope_text := "") -> bool:
	dialog_calls += 1
	approval_scope_granted = allow and scope_choice and not _scope_text.is_empty()
	return allow
