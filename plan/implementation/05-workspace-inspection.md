# Story 05 implementation plan — read-only Godot workspace tools

Status: Accepted. Slices A–F are implemented and verified. The provider uses the scene-specific undo `get_version()` for session revisions and is injected into the dock without being advertised to the model. See [acceptance evidence](../evidence/05-acceptance.md).

Parent: [05 — Read-only Godot workspace tools](../work-items/05-workspace-inspection.md). Visuals: [inspection diagrams](../mockups/05-workspace-inspection-diagrams.md). Contract: [story 07 tool orchestration](../implementation/07-orchestrator.md).

## Execution contract

The workspace inspector is a read-only tool provider. It exposes the edited scene, selection, tree, node properties, resources, ownership, and signals as structured data. It never mutates the scene, resources, undo history, project files, or editor state.

The edited scene must have been saved at least once. A scene with no `scene_file_path` returns `scene_not_saved` ("Save the scene once before using workspace tools"). Dirty scenes are allowed for read-only inspection: results include `dirty: true` and a session revision derived from the scene's undo history. Revision identity is the saved file hash plus that session revision, not a guess.

Every result is bound to a scene identity and revision captured at call time. A path is resolved against the edited scene root, not the running remote scene and not an arbitrary open scene. Stale, missing, or out-of-scene targets produce explicit errors or empty states.

Results are bounded and JSON-safe. Large trees, property lists, values, resources, and connection lists are truncated with a flag, never silently dropped.

The inspector is a tool provider for story 07, not the model orchestrator. Story 05 defines `definitions()` and `execute(name, arguments, turn_context)`; story 07 composes them into the registry, availability snapshot, prompt, and ledger. The chat does not advertise these tools until 07 wires them.

## Baseline

Today the chat builds a text context in `_editor_context()` (scene path/name, selected node paths/classes, a few node properties) and has one workspace-adjacent tool, `get_scene_revision`, used for attachment jobs. There is no structured scene tree, property/resource inspection, ownership, or signal tool.

The editor already provides the APIs needed:

- `EditorInterface.get_edited_scene_root()`, `get_selection().get_selected_nodes()`, `get_unsaved_scenes()`, `is_playing_scene()`.
- `Node.get_path_to()`, `get_class()`, `get_property_list()`, `get()`, `get_owner()`, `get_scene_file_path()`, `get_scene_instance_load_placeholder()`, `is_editable_instance()`. `is_editable_instance()` errors when passed the root or a non-descendant, so call it only after `root.is_ancestor_of(node)`.
- `Object.get_signal_list()`, `get_signal_connection_list()`.
- `PROPERTY_USAGE_EDITOR`, `STORAGE`, `READ_ONLY`, `INTERNAL`, `CATEGORY`, `GROUP`, `SUBGROUP`, `SECRET` for filtering.
- Scene history and revision: `EditorInterface.get_editor_undo_redo().get_object_history_id(root)`, then `get_history_undo_redo(id).get_version()`; use `get_unsaved_scenes()` for dirty state. Do not use history 0 or `get_history_count()` for revision identity.

### Runtime API verification

A disposable editor probe on this checkout verified:

```text
history_id=1 version=1 count=0
after_commit version=2 count=1 unsaved=["res://test.tscn"]
after_undo   version=1 count=1 unsaved=[]
after_redo   version=2 count=1 unsaved=["res://test.tscn"]
editable_self=false (is_editable_instance(root) emitted an ancestor error)
signal_connections=[]
```

Consequences for the provider:

- `session_revision` is `"undo:<version>"` from the scene-specific history; it changes on commit, undo, and redo.
- `get_unsaved_scenes()` returns `res://` paths, so `root.scene_file_path in get_unsaved_scenes()` is a valid dirty check.
- `editable` is false for the root; for other nodes it is true only when `root.is_ancestor_of(node)` and `root.is_editable_instance(node)`.

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
  "timeout_ms": 5000
}
```

Story 07 attaches its registry handler; the provider exposes the canonical `execute(name, arguments, turn_context)` entry point.

### Result

```json
{
  "call_id": "call_1",
  "tool": "inspect_node",
  "ok": true,
  "summary": "Inspected Player [CharacterBody2D] with 34 editor properties.",
  "data": {
    "scene": {"path": "res://player.tscn", "revision": "sha256:...", "session_revision": "undo:2", "dirty": false, "root": "."},
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
| `scene_not_saved` | No `scene_file_path` (never saved) | Error; save the scene once first |
| `scene_dirty` | Compatibility `get_scene_revision` on a dirty scene | Error; save before requesting an attachment revision |
| `scene_unreadable` | Saved scene hash cannot be read | Error; do not substitute an empty revision |
| `history_unavailable` | Scene has no positive editor history ID | Error; do not invent a session revision |
| `stale_scene` | Root identity, file revision, session revision, or scene path changed since the turn context | Error; caller must re-inspect |
| `no_selection` | Selection tool with nothing selected | `ok: true`, empty `nodes`, summary "No nodes selected" |
| `target_missing` | Node path no longer exists | Error; no substitution |
| `outside_scene` | Node is not under the edited scene root | Error |
| `invalid_path` | Absolute path, `..`, empty, or traversal | Error |
| `invalid_arguments` | Schema failure | Error with field |
| `not_found` | Resource path missing | Error |
| `not_a_resource` | Node property is not a Resource | Error |
| `unsupported_value` | Value cannot be encoded safely | Error or a value summary with `truncated` |

Empty selection is not an error. A missing scene is not an empty scene. A deleted target is never replaced by a new selection.

### Scene identity and revision

`get_workspace_context` and every result include:

- `scene_path`: `root.scene_file_path` (required; a never-saved scene is rejected).
- `revision`: `"sha256:<hex>"` for the saved scene file (the base revision). The compatibility `get_scene_revision` keeps its older bare `scene_sha256` field and rejects dirty scenes.
- `session_revision`: the edited scene's scene-specific undo-history version, for example `"undo:2"`. It changes after commit, undo, and redo, including Tiiny recipes. Resolve it with `get_object_history_id(root)` and `get_history_undo_redo(id).get_version()`; do not use history 0 or `get_history_count()`. If the scene has no positive history ID, return `history_unavailable` rather than inventing a revision.
- `dirty`: whether `root.scene_file_path` is in `EditorInterface.get_unsaved_scenes()`; the probe confirmed this returns `res://` paths.
- `root_instance_id`: session-local identity.
- `playing`: `EditorInterface.is_playing_scene()`.
- `edited_scene_only`: always true, with a note that runtime/debugger values require story 12.

Every tool accepts an optional `turn_context` with this shape:

```json
{"scene_path": "res://player.tscn", "revision": "sha256:...", "session_revision": "undo:2", "root_instance_id": 1234}
```

Validate in this order: edited root instance identity, scene path, saved file hash, then scene history ID plus version. If an expected field is present and differs, return `stale_scene` before resolving any node path. Omitted fields skip only their own check; malformed fields return `invalid_arguments`. After a Tiiny mutation, the caller adopts the result's `session_revision` so a follow-up inspection is not rejected; story 07 owns that turn-context update.

The file hash catches on-disk changes; the session revision catches in-memory edits, undo, and redo. Manual changes that bypass the undo history are the residual gap; file saves still update the base revision.

### Node identity and ownership

- Scene-relative paths come from `root.get_path_to(node)`; the root is `"."`.
- `owner` is the scene-relative path of `node.get_owner()`, or `null` for the root.
- `scene_file_path` is the source scene path for an instanced node; empty for nodes authored in the edited scene. `get_scene_instance_state()` and `get_scene_inherited_state()` are not exposed to GDScript in this build, so do not rely on them for extra scene-state fields.
- `instance_placeholder` is `node.get_scene_instance_load_placeholder()`.
- `internal` is not exposed to GDScript; `get_children(false)` and `get_child_count(false)` exclude internal children by default. `include_internal: true` uses the corresponding true-argument forms.
- `editable`: false for the root; for other nodes, true only when `root.is_ancestor_of(node)` and `root.is_editable_instance(node)`. Never call `is_editable_instance()` with the root itself.
- Instance IDs are included only as session diagnostics; paths are the stable identifiers.

For inherited scenes, the edited root's `scene_file_path` is the inherited scene path; the base source path is not exposed through scripting, so do not invent one. For instanced children, the instance root's `scene_file_path` identifies the source and its `owner` identifies the edited scene owner. Tests must cover both.

### Property inspection

Include properties with `PROPERTY_USAGE_EDITOR` or `PROPERTY_USAGE_STORAGE`, excluding `INTERNAL`, `CATEGORY`, `GROUP`, `SUBGROUP`, `SECRET`, names beginning `metadata/`, and editor-only metadata. For each property return:

- `name`, `type` (Variant type name via `type_string`), `hint`, `hint_string`, `class_name`;
- `usage` as a short list;
- `writable`: not `READ_ONLY`, not a category/group, and a `set_<name>` method is present where discoverable. This is a hint; story 06 revalidates before writing;
- `value`: a bounded, JSON-safe summary read best-effort; a getter failure must not abort the whole result, and any observable failure is reported alongside the value.

Values encode primitives and strings, vectors/colors/rects/transforms as strings, arrays/dictionaries with element caps, `StringName`/`NodePath` as strings, `Packed*Array` as bounded arrays, `Node` as `{class, path}`, `Resource` as `{class, path, name, embedded}`, `Callable`/`RID` as class markers, and unsupported objects as `{class, "<unserializable>"}`. Dictionary keys are stringified; cycles and depth are capped.

`inspect_node` also returns the attached script path, groups, child count, and a bounded property list. `inspect_resource` returns the resource class, path, name, embedded flag, bounded properties, and shallow sub-resources. An embedded resource with an empty path is valid when reached through a node property; a direct `res://` path must exist.

### Signals

`list_signals` returns signal names, argument names/types, and bounded connections. Each connection includes the target scene-relative path, class, method, and flags. Connections to freed or external objects are summarized without serializing the Callable. No signal is emitted or connected.

### Bounds

- `get_scene_tree`: `max_depth` 0–8 (default 4), `max_nodes` 1–500 (default 200), `include_internal?` false; breadth-first, child order preserved; `truncated` object with per-list flags.
- `inspect_node`: `max_properties` 1–200 (default 80).
- `inspect_resource`: `max_properties` 1–120 (default 60), depth 1–2.
- `list_signals`: `max_connections` 1–100 (default 50).
- Strings 512 chars; arrays/dictionaries 64 entries; encoded result target under the story 07 16 KiB cap.
- Truncation is reported, never silent; stop appending before the encoded budget is exceeded rather than dropping nested values without a flag.

## Tool set

| Tool | Arguments | Returns |
| --- | --- | --- |
| `get_workspace_context` | none | Scene identity/revision, root, selection summary, playing/edited-only note |
| `get_scene_tree` | `max_depth?`, `max_nodes?`, `include_internal?` | Bounded nodes with path, class, owner, scene_file_path, instance_placeholder, child_count |
| `get_selection` | none | Selected nodes with path/class/owner/editable, or an empty state |
| `inspect_node` | `path`, `max_properties?` | Class, ownership, script, groups, bounded properties |
| `inspect_resource` | `path` or `node_path` + `property`, `max_properties?` | Resource class/path/name/embedded, bounded properties, shallow sub-resources |
| `list_signals` | `path`, `max_connections?` | Signals, arguments, bounded connections |
| `get_scene_revision` | none | Clean saved scene path and bare SHA-256; compatibility with the existing attachment tool; `scene_dirty` if dirty |

No search-by-class/name, no write tools, and no debugger tools in 05. Those belong to later stories.

## Slices

### Slice A — tool provider foundation

Create `editor/tiiny/tools/inspector.gd` with the definition list, `execute()`, the structured result envelope, scene identity/revision, JSON-safe value encoding, bounds, and error codes. Define `definitions()` so story 07 can compose the registry without duplicating schemas.

Use two layers so fixtures are deterministic:

- `Inspector` (provider logic) consumes a small `EditorApi` adapter exposing the current root, selected nodes, unsaved scene paths, playing state, and `history_version(root)`.
- The production adapter wraps `EditorInterface` and the editor undo manager; fixture adapters supply a controlled root/selection/version without requiring a full editor session.

Wire the script into the build: add it to the generated source list in `editor/SCsub`, load the generated constant in `editor_node.cpp`, and inject the script into the chat dock through a new property. The dock stores the script; the provider is instantiated on demand by story 07 or fixtures and is not added to the model tool list in story 05.

Gate: unit fixtures call every definition with valid and invalid arguments; the result envelope, error codes, bounds, scene identity, undo/redo revision behavior, and read-only guarantees are stable. No model or device.

Deliverables: inspector script, editor adapter, fixture adapter, generated-source build wiring, result/error helpers, and a focused runner/fixture scaffold.

### Slice B — scene, selection, and tree

Implement `get_workspace_context`, `get_selection`, and `get_scene_tree`, including edited-scene-only labeling, base/session revision checks, dirty state, selection filtering, ownership, instanced-node metadata, and truncation.

Gate: a fixture scene returns correct paths/classes/owners; depth/node limits truncate; internal children are skipped unless requested; no scene and no selection produce distinct states; a scene switch, file change, or undo/redo revision change produces `stale_scene`.

Deliverables: scene/tree/selection handlers and fixtures.

### Slice C — node and property inspection

Implement `inspect_node` with editor-visible property filtering, type/hint/usage, writability hints, value summaries, script/groups, and bounds. Include inherited and instanced nodes.

Gate: property types and writability hints match the fixture; internal/category/secret/metadata properties are excluded; a getter failure does not fail the whole result; large lists truncate; deleted targets return `target_missing`; root `editable` is false without an ancestor error.

Deliverables: node/property handlers and fixtures.

### Slice D — resources and signals

Implement `inspect_resource` for `res://` paths and resource-valued node properties, plus `list_signals` with argument and connection summaries. Bound sub-resources and connections; never serialize Callables.

Gate: a `RectangleShape2D` and a saved `.tres` inspect correctly, including an embedded resource reached through a node property; missing/wrong-type resources error; connections to scene nodes are reported; freed/external targets are summarized safely.

Deliverables: resource/signal handlers and fixtures.

### Slice E — read-only, running-scene, and regression behavior

Add the explicit running-scene note and test that inspection never touches the running remote scene. Add read-only assertions: scene file hash, node count, property values, `session_revision`, selected paths, and the project file list/hashes are unchanged; no tool saves the scene or writes files. Add the compatibility `get_scene_revision` with its clean-scene behavior.

Gate: before/after read-only assertions pass for every tool; commit/undo/redo changes `session_revision` while inspection itself does not; a running fixture scene still returns edited-scene values; `get_scene_revision` matches the existing attachment behavior and returns `scene_dirty` for a dirty scene.

Deliverables: read-only tests, running-scene test, compatibility tool.

### Slice F — integration and handoff

Expose the provider to story 07 through `definitions()`/`execute()`, complete the embedded-source build wiring, add the focused editor fixture/runner, and record evidence. Do not advertise the tools to the model yet; 07 owns the registry snapshot and prompt.

The focused harness should live at `integrations/tiiny/tests/editor_workspace_inspector.gd` with a `check_workspace_inspector.py` runner. Build disposable scenes covering authored nodes, an instanced child scene, an inherited scene, a dirty saved scene, a never-saved scene, signals, an embedded resource, and a running scene. Keep pure provider checks separate from the editor integration run.

Gate: story 07's registry can consume the definitions without changes; direct fixture calls and the focused editor run pass; no chat behavior changes in 05.

Deliverables: provider interface, build wiring, focused runner/fixtures, work-item/STATUS handoff.

## Scenario mapping

| Scenario | Slice | Check |
| --- | --- | --- |
| WS-01 inspection half | B, C | Inspect CharacterBody2D, selection, and tree before the recipe |
| WS-02 incompatible/deleted target | B, C | `target_missing`, `outside_scene`, no substitution |
| WS-11 runtime vs edited scene | E | Running scene is labeled; edited-scene values are not replaced by runtime values |
| WS-13 scene switch | A, B | `stale_scene` on identity/revision change |
| Instanced/inherited ownership | C | Owner paths and source scene paths match the fixture |
| Read-only guarantee | E | Hash, node count, values, and `session_revision` unchanged; no file writes |

## Review decisions

1. **Bounded results.** Use explicit truncation flags; no pagination in v1.
2. **Writability is a hint.** Report usage and a setter hint where available; story 06 revalidates before writing.
3. **Saved at least once; dirty inspection allowed.** A never-saved scene returns `scene_not_saved`. A dirty scene is inspectable and reports `dirty: true` plus a `session_revision` from the undo history. Mutations still require a clean scene (story 06).
4. **Provider location (explained).** This only concerns where the code lives: a separate embedded GDScript file (`editor/tiiny/tools/inspector.gd`) injected into the dock like the Jobs scripts, or functions inside the large chat-dock script. The separate file is easier to test and keeps the dock as UI only; it adds a small build-generation step. Recommendation: separate file. This is an implementation detail and does not affect the tool contract.
5. **Search tools.** Defer `find_nodes`; the scene tree and inspection tools cover the first recipe.

## Remaining recommendations

6. **Value encoding.** Use JSON-safe summaries, not raw `Variant` serialization. Resources and nodes become references; unsupported objects become a class marker.
7. **Instanced ownership.** Keep `owner` and `scene_file_path` as separate fields; do not infer editability from ownership alone.
8. **Running scene.** Use an explicit `edited_scene_only` note and no debugger APIs in 05. Runtime values are story 12.
9. **Selection empty state.** Return `ok: true` with an empty list for `get_selection`; tools that require a target return `no_selection`/`target_missing`.

## Dependencies and risks

- **Story 01 only:** 05 can start now. 06 consumes the inspector; 07 composes the registry.
- **Saved-at-least-once scenes:** 05/06/07 assume a `scene_file_path` and a base file hash. Tests must cover `scene_not_saved` for never-saved scenes, dirty inspection, and `scene_dirty` for mutations.
- **Editor API stability (verified):** the disposable probe confirmed `get_object_history_id(root)`, `UndoRedo.get_version()`, `get_unsaved_scenes()` path format, and that `is_editable_instance(root)` errors. A separate check showed `get_scene_instance_state()`/`get_scene_inherited_state()` are not exposed to GDScript, so the provider relies on `scene_file_path` and `owner`. Re-run the probe if the engine API changes.
- **Revision mistake guarded:** do not use `get_history_undo_redo(0)` or `get_history_count()` for session revisions; history 0 is global and the count is unchanged by undo/redo.
- **Property getters:** editor-visible getters are generally safe, but expensive or side-effectful properties must be bounded and filtered. GDScript cannot reliably catch every native getter error; read best-effort, do not abort the whole result, and record any observable exception.
- **Large scenes:** depth/node/property/connection caps and result-size caps are mandatory.
- **Instanced/inherited scenes:** ownership semantics are the main correctness risk; test both explicitly.
- **Running scene confusion:** never use `get_tree().current_scene` or debugger APIs for edited-scene inspection.
- **Dirty-session revisions:** the undo version is editor-session-local. File hashes catch on-disk changes; manual edits that bypass undo are the residual gap. Mutations require a clean scene, so recipes never mix with untracked dirty changes.
- **Model exposure:** 05 does not change chat behavior. 07 owns availability, prompt, and ledger.

## Handoff

Accepted. No device operation was performed. The pure and editor fixtures prove the provider contract, real scene/undo behavior, read-only guarantees, and running-scene isolation. Story 07 can compose the definitions and attach model exposure; story 06 can consume node/resource inspection.
