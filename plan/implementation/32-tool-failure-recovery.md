# Story 32 implementation plan — recoverable tool failures

Status: Complete; covered by the pure and editor workspace fixtures.

Parent: [32 — Recoverable tool failures and actionable validation errors](../work-items/32-tool-failure-recovery.md).

## Trace

After a plan join, job `72c8722b02a5-00000014`:

```text
get_scene_tree {"max_depth":6} -> stale_scene
get_scene_tree {"max_depth":6} -> repeated_call
```

The stale branch refreshed `turn_scene_context`, but the repeat guard ran before the retry, so the fresh context was never used.

Job `72c8722b02a5-00000035`:

```text
replace_in_gdscript ... -> The edited script failed validation; the file was not changed.
```

No line or parser message, so the model had to infer the fault.

## Changes

### Stale-scene retry

In `_execute_turn_calls`, after a tool result is recorded:

```gdscript
elif str(tool_result.get("error", {}).get("code", "")) == "stale_scene":
    turn_signature_counts.erase(call_signature)
    if turn_last_signature == call_signature:
        turn_last_signature = ""
```

The existing stale branch already refreshes `turn_scene_context` from `workspace_registry.current_scene_context({})`. The same call may therefore run once more against the fresh revision. This does not clear unrelated counts, and it does not override the task work budget or the task read-only guard.

### Script validation detail

The workspace `_validate_script` now returns:

```gdscript
_error("script_invalid",
    "The updated GDScript failed to parse at line %d: %s; the file was not changed." % [line, message],
    {"line": line, "kind": kind})
```

The dock adds a shared helper:

```gdscript
func _script_error_detail(script: GDScript) -> String:
    # " at line N: parser message" or ": parser message"
```

and uses it in:

- `_replace_script_tool`
- `_create_script_tool`
- `_registry_create_and_attach_gdscript` (which keeps its compiled script for the base-class check)

`create_gdscript` already delegates to the workspace `create_file`, so it inherits the same detail.

The engine's `SCRIPT ERROR` diagnostics cannot be suppressed for an in-memory `GDScript.reload()`; the structured tool result is the actionable copy.

## Tests

- Editor fixture: open `dirty.tscn`, capture its context, force a stale revision, call `get_scene_tree` twice with identical arguments. The first result must be `stale_scene`; the second must succeed and must not be `repeated_call`.
- Pure fixture: invalid `write_file` and `apply_patch` candidates must return `script_invalid` with `"at line"` in the summary, `data.line > 0`, and an unchanged file.
- Editor fixture: write a valid script, replace a line with an invalid call, and assert the `replace_in_gdscript` result contains the line and parser message and leaves the file unchanged.
