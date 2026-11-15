# Story 05 implementation plan — read-only Godot workspace tools

Status: Planning. Implementation can start immediately; it depends only on story 01. No code changes in this planning task.

Parent: [05 — Read-only Godot workspace tools](../work-items/05-workspace-inspection.md). Visuals: [inspection diagrams](../mockups/05-workspace-inspection-diagrams.md). Contract: [story 07 tool orchestration](../implementation/07-orchestrator.md).

## Execution contract

The workspace inspector is a read-only tool provider. It exposes the edited scene, selection, tree, node properties, resources, ownership, and signals as structured data. It never mutates the scene, resources, undo history, project files, or editor state.

The edited scene must be saved. A scene with no `scene_file_path` or a path in `EditorInterface.get_unsaved_scenes()` returns `scene_not_saved` with "Save the scene before using workspace tools." Revision identity is a file hash, not a session guess.

Every result is bound to a scene identity and revision captured at call time. A path is resolved against the edited scene root, not the running remote scene and not an arbitrary open scene. Stale, missing, or out-of-scene targets produce explicit errors or empty states.

Results are bounded and JSON-safe. Large trees, property lists, values, resources, and connection lists are truncated with a flag, never silently dropped.

The inspector is a tool provider for story 07, not the model orchestrator. Story 05 defines `definitions()` and `execute(name, arguments, turn_context)`; story 07 composes them into the registry, availability snapshot, prompt, and ledger. The chat does not advertise these tools until 07 wires them.

## Baseline

Today the chat builds a text context in `_editor_context()` (scene path/name, selected node paths/classes, a few node properties) and has one workspace-adjacent tool, `get_scene_revision`, used for attachment jobs. There is no structured scene tree, property/resource inspection, ownership, or signal tool.

The editor already provides the APIs needed:

- `EditorInterface.get_edited_scene_root()`, `get_selection().get_selected_nodes()`, `get_unsaved_scenes()`, `is_playing_scene()`.
- `Node.get_path_to()`, `get_class()`, `get_property_list()`, `get()`, `get_owner()`, `get_scene_file_path()`, `get_scene_instance_load_placeholder()`, `is_editable_instance()`.
- `Object.get_signal_list()`, `get_signal_connection_list()`.
- `PROPERTY_USAGE_EDITOR`, `STORAGE`, `READ_ONLY`, `INTERNAL`, `CATEGORY`, `GROUP`, `SUBGROUP`, `SECRET` for filtering.
- `EditorInterface.get_editor_undo_redo().get_history_undo_redo(0).get_history_count()` for read-only verification.

## Tool contract

### Definition

Each tool follows the story 07 definition shape:

```gdscript
{
  "name": "inspect_node",
  "title": "Inspect node",
  "description": "Return class, ownership, script, and bounded editor-visible properties for a scene-relative node path.",
  "parameters": {
    "type": "object",
    "properties": {
      "path": {"type": "string", "minLength": 1, "maxLength": 512},
      "max_properties": {"type": "integer", "minimum": 1, "maximum": 200}
    },
    "required": ["path"],
    "additionalProperties": false
  },
  "risk": "read",
  "availability": Callable,
  "timeout_ms": 5000,
  "handler": Callable
}
```

### Result

```json
{
  "call_id": "call_1",
  "tool": "inspect_node",
  "ok": true,
  "summary": "Inspected Player [CharacterBody2D] with 34 editor properties.",
  "data": {
    "scene": {"path": "res://player.tscn", "revision": "sha256:...", "root": "."},
    "node": {"path": "Player", "class": "CharacterBody2D", "owner": ".", "scene_file_path": "", "instance_placeholder": false, "script": "res://player.gd", "child_count": 2, "groups": ["player"]},
    "properties": [{"name": "position", "type": "Vector2", "value": "(0, 0)", "usage": ["storage", "editor"], "writable": true}],
    "truncated": {"properties": false}
  },
  "affected": [{"kind": "node", "scene_path": "res://player.tscn", "path": "Player"}],
  "scene_revision": "sha256:...",
  "duration_ms": 3
}
```

Read-only results never include `undo_group`. The provider echoes `call_id` when the orchestrator supplies one; direct fixture calls may omit it. Errors keep the same envelope with `ok: false` and `error: {code, message, field?}`.

### Error and empty states

| Code | Condition | Result |
| --- | --- | --- |
| `no_scene` | No edited scene | Error with a clear message |
| `scene_not_saved` | No `scene_file_path` or the scene is unsaved | Error; save the scene first |
| `no_selection` | Selection tool with nothing selected | `ok: true`, empty `nodes`, summary "No nodes selected" |
| `target_missing` | Node path no longer exists | Error; no substitution |
| `outside_scene` | Node is not under the edited scene root | Error |
| `invalid_path` | Absolute path, `..`, empty, or traversal | Error |
| `stale_scene` | Scene identity/revision changed since the turn context | Error; caller must re-inspect |
| `invalid_arguments` | Schema failure | Error with field |
| `not_found` | Resource path missing | Error |
| `not_a_resource` | Node property is not a Resource | Error |
| `unsupported_value` | Value cannot be encoded safely | Error or a value summary with `truncated` |

Empty selection is not an error. A missing scene is not an empty scene. A deleted target is never replaced by a new selection.

### Scene identity and revision

`get_workspace_context` and every result include:

- `scene_path`: `root.scene_file_path` (required; unsaved scenes are rejected).
- `revision`: SHA-256 of the saved scene file.
- `root_instance_id`: session-local identity.
- `playing`: `EditorInterface.is_playing_scene()`.
- `edited_scene_only`: always true, with a note that runtime/debugger values require story 12.

Tools accept an optional `turn_context` containing the expected scene path, revision, and root instance ID. If the current edited root differs, or the saved file hash changed, the tool returns `stale_scene` before resolving paths. This is what lets 06/07 reject a plan after a scene switch or external edit (WS-13).

An unsaved scene returns `scene_not_saved`. Once the scene is saved, a changed on-disk revision returns `stale_scene` when it differs from the turn context.

### Node identity and ownership

- Scene-relative paths come from `root.get_path_to(node)`; the root is `"."`.
- `owner` is the scene-relative path of `node.get_owner()`, or `null` for the root.
- `scene_file_path` is the source scene path for an instanced node; empty for nodes authored in the edited scene.
- `instance_placeholder` is `node.get_scene_instance_load_placeholder()`.
- `editable` reflects `root.is_editable_instance()` for an instance root, where applicable.
- Instance IDs are included only as session diagnostics; paths are the stable identifiers.

For inherited scenes, the edited root's `scene_file_path` is the inherited scene path; ownership follows the inherited root. For instanced children, the instance root's `scene_file_path` identifies the source and its `owner` identifies the edited scene owner. Tests must cover both.

### Property inspection

Include properties with `PROPERTY_USAGE_EDITOR` or `PROPERTY_USAGE_STORAGE`, excluding `INTERNAL`, `CATEGORY`, `GROUP`, `SUBGROUP`, `SECRET`, and editor-only metadata. For each property return:

- `name`, `type` (Variant type name), `hint`, `hint_string`, `class_name`;
- `usage` as a short list;
- `writable`: not `READ_ONLY`, not a category/group, and a setter exists where the class or script exposes one. This is a hint; story 06 revalidates before writing;
- `value`: a bounded, JSON-safe summary.

Values encode as primitives, strings, vectors/colors/rects as strings, arrays/dictionaries with element caps, `Node` as `{class, path}`, `Resource` as `{class, path, name}`, and unsupported objects as `{class, "<unserializable>"}`. Cycles and depth are capped.

`inspect_node` also returns the attached script path, groups, child count, and a bounded property list. `inspect_resource` returns the resource class, path, name, bounded properties, and shallow sub-resources.

### Signals

`list_signals` returns signal names, argument names/types, and bounded connections. Each connection includes the target scene-relative path, class, method, and flags. Connections to freed or external objects are summarized without serializing the Callable. No signal is emitted or connected.

### Bounds

- `get_scene_tree`: `max_depth` 0–8 (default 4), `max_nodes` 1–500 (default 200); breadth-first; `truncated` flag.
- `inspect_node`: `max_properties` 1–200 (default 80).
- `inspect_resource`: `max_properties` 1–120 (default 60), depth 1–2.
- `list_signals`: `max_connections` 1–100 (default 50).
- String values 512 chars; arrays/dictionaries 64 entries; overall result under the story 07 cap (16 KiB).
- Truncation is reported, never silent.

## Tool set

| Tool | Arguments | Returns |
| --- | --- | --- |
| `get_workspace_context` | none | Scene identity/revision, root, selection summary, playing/edited-only note |
| `get_scene_tree` | `max_depth?`, `max_nodes?` | Bounded nodes with path, class, owner, scene_file_path, instance_placeholder, child_count |
| `get_selection` | none | Selected nodes with path/class/owner/editable, or an empty state |
| `inspect_node` | `path`, `max_properties?` | Class, ownership, script, groups, bounded properties |
| `inspect_resource` | `path` or `node_path` + `property`, `max_properties?` | Resource class/path/name, bounded properties, shallow sub-resources |
| `list_signals` | `path`, `max_connections?` | Signals, arguments, bounded connections |
| `get_scene_revision` | none | Saved scene path and SHA-256; compatibility with the existing attachment tool |

No search-by-class/name, no write tools, and no debugger tools in 05. Those belong to later stories.

## Slices

### Slice A — tool provider foundation

Create `editor/tiiny/tools/inspector.gd` (embedded through a generated source header, injected into the dock like the jobs scripts) with the definition list, `execute()`, the structured result envelope, scene identity/revision, JSON-safe value encoding, bounds, and error codes. Define `definitions()` so story 07 can compose the registry without duplicating schemas.

Gate: unit fixtures call every definition with valid and invalid arguments; the result envelope, error codes, bounds, and scene identity are stable. No model or device.

Deliverables: inspector script, embedded source wiring, result/error helpers.

### Slice B — scene, selection, and tree

Implement `get_workspace_context`, `get_selection`, and `get_scene_tree`, including edited-scene-only labeling, saved-scene revision checks, selection filtering, ownership, instanced-node metadata, and truncation.

Gate: a fixture scene returns correct paths/classes/owners; depth/node limits truncate; no scene and no selection produce distinct states; a scene switch produces `stale_scene`.

Deliverables: scene/tree/selection handlers and fixtures.

### Slice C — node and property inspection

Implement `inspect_node` with editor-visible property filtering, type/hint/usage, writability hints, value summaries, script/groups, and bounds. Include inherited and instanced nodes.

Gate: property types and writability match the fixture; internal/category/secret properties are excluded; large lists truncate; deleted targets return `target_missing`.

Deliverables: node/property handlers and fixtures.

### Slice D — resources and signals

Implement `inspect_resource` for `res://` paths and resource-valued node properties, plus `list_signals` with argument and connection summaries. Bound sub-resources and connections; never serialize Callables.

Gate: a `RectangleShape2D` and a saved `.tres` inspect correctly; missing/wrong-type resources error; connections to scene nodes are reported; freed/external targets are summarized safely.

Deliverables: resource/signal handlers and fixtures.

### Slice E — read-only, running-scene, and regression behavior

Add the explicit running-scene note and test that inspection never touches the running remote scene. Add read-only assertions: scene file hash, node count, property values, and undo history count are unchanged; no project files are written. Add the compatibility `get_scene_revision`.

Gate: before/after read-only assertions pass for every tool; a running fixture scene still returns edited-scene values; `get_scene_revision` matches the existing attachment behavior.

Deliverables: read-only tests, running-scene test, compatibility tool.

### Slice F — integration and handoff

Expose the provider to story 07 through `definitions()`/`execute()`, add the embedded-source build wiring, and record evidence. Do not advertise the tools to the model yet; 07 owns the registry snapshot and prompt.

Gate: story 07's registry can consume the definitions without changes; direct fixture calls pass; no chat behavior changes in 05.

Deliverables: provider interface, build wiring, work-item/STATUS handoff.

## Scenario mapping

| Scenario | Slice | Check |
| --- | --- | --- |
| WS-01 inspection half | B, C | Inspect CharacterBody2D, selection, and tree before the macro |
| WS-02 incompatible/deleted target | B, C | `target_missing`, `outside_scene`, no substitution |
| WS-11 runtime vs edited scene | E | Running scene is labeled; edited-scene values are not replaced by runtime values |
| WS-13 scene switch | A, B | `stale_scene` on identity/revision change |
| Instanced/inherited ownership | C | Owner paths and source scene paths match the fixture |
| Read-only guarantee | E | Hash, node count, values, and undo history unchanged |

## Review decisions

1. **Bounded results.** Use explicit truncation flags; no pagination in v1.
2. **Writability is a hint.** Report usage and a setter hint where available; story 06 revalidates before writing.
3. **Saved scenes are required.** A scene with no `scene_file_path` or with unsaved changes returns `scene_not_saved`; there is no session-only revision.
4. **Provider location (explained).** This only concerns where the code lives: a separate embedded GDScript file (`editor/tiiny/tools/inspector.gd`) injected into the dock like the Jobs scripts, or functions inside the large chat-dock script. The separate file is easier to test and keeps the dock as UI only; it adds a small build-generation step. Recommendation: separate file. This is an implementation detail and does not affect the tool contract.
5. **Search tools.** Defer `find_nodes`; the scene tree and inspection tools cover the first macro.

## Remaining recommendations

6. **Value encoding.** Use JSON-safe summaries, not raw `Variant` serialization. Resources and nodes become references; unsupported objects become a class marker.
7. **Instanced ownership.** Keep `owner` and `scene_file_path` as separate fields; do not infer editability from ownership alone.
8. **Running scene.** Use an explicit `edited_scene_only` note and no debugger APIs in 05. Runtime values are story 12.
9. **Selection empty state.** Return `ok: true` with an empty list for `get_selection`; tools that require a target return `no_selection`/`target_missing`.

## Dependencies and risks

- **Story 01 only:** 05 can start now. 06 consumes the inspector; 07 composes the registry.
- **Saved scenes:** 05/06/07 all assume a saved scene with a file hash revision. Tests must cover the `scene_not_saved` path.
- **Editor API stability:** verify the exact signatures in this build (`get_property_list`, `get_signal_connection_list`, `is_editable_instance`, `get_scene_instance_load_placeholder`, `get_editor_undo_redo`).
- **Property getters:** editor-visible getters are generally safe, but expensive or side-effectful properties must be bounded and filtered. Record any exceptions.
- **Large scenes:** depth/node/property/connection caps and result-size caps are mandatory.
- **Instanced/inherited scenes:** ownership semantics are the main correctness risk; test both explicitly.
- **Running scene confusion:** never use `get_tree().current_scene` or debugger APIs for edited-scene inspection.
- **Saved-scene requirement:** unsaved scenes cannot be inspected or planned against. This removes session-only revisions but adds a save step before workspace work.
- **Model exposure:** 05 does not change chat behavior. 07 owns availability, prompt, and ledger.

## Handoff

Planning only. No build, test, or device operation was performed. Implementation starts with slice A (provider foundation), then B–D, with E/F for verification and wiring. Record the tool definitions, result contract, fixtures, read-only evidence, and any API exceptions in the work item and STATUS.
