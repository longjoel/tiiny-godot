# Story 06 implementation plan — typed scene edits with grouped undo/redo

Status: Planning. Implementation depends on story 05 (saved-scene identity, path/ownership inspection). No code changes in this planning task.

Parent: [06 — Typed scene edits with grouped undo/redo](../work-items/06-workspace-transactions.md). Visuals: [transaction diagrams](../mockups/06-workspace-transactions-diagrams.md). Contract: [story 07 tool orchestration](../implementation/07-orchestrator.md).

## Execution contract

Story 06 implements exactly one native workspace macro:

> Add one `CollisionShape2D` under a compatible physics body, create an owned `RectangleShape2D`, assign it, and set its dimensions.

The macro is a typed tool call. It validates the entire change before touching the scene, commits one editor undo action, and reports the affected node and resource. Invalid input, a stale target, an unsupported parent, or a resource/name conflict produces no partial node, resource, or undo entry.

The edited scene must be saved (story 05's `scene_not_saved` rule). The macro never saves the scene automatically; it marks the scene dirty and the user saves normally. Consequence: after a successful macro, further workspace tool calls return `scene_not_saved` until the user saves. The macro verifies its own postcondition, so WS-01 does not need a follow-up inspection to establish success.

No generic property writes, node deletion, reparenting, script generation, or asset import are part of 06. Those belong to later stories.

## Baseline

Story 05 provides the read-only inspector: scene identity/revision, scene-relative paths, selection, ownership, `scene_file_path`, editor-visible properties, and structured results. The macro reuses those helpers and revalidates every fact before executing.

The editor already provides the undo API:

- `EditorInterface.get_editor_undo_redo()` and `get_object_history_id(root)`.
- `create_action(name, MERGE_DISABLE, root)`, `add_do_method`, `add_undo_method`, `add_do_property`, `add_undo_property`, `add_do_reference`, `commit_action`.
- `get_history_undo_redo(history_id).undo()/redo()` and `get_history_count()` for tests.
- `Node.add_child(node, true)`, `set_owner(root)`, `remove_child(node)`.
- `RectangleShape2D.size` and `CollisionShape2D.shape`.

The standard editor pattern is `add_child` + `set_owner` + `add_do_reference(new_node)` with an undo `remove_child`. Follow it rather than inventing a custom history.

## Macro contract

### Tool

`add_rectangular_collision_shape`

| Argument | Type | Rules |
| --- | --- | --- |
| `parent_path` | string | Scene-relative path; `"."` for the root; required |
| `width` | number | Finite, > 0, ≤ 100000; required |
| `height` | number | Finite, > 0, ≤ 100000; required |
| `node_name` | string | Optional; valid node name, ≤ 64 chars, unique under the parent |

The schema uses `additionalProperties: false`. Domain validation repeats every rule at execution time; the schema is not the safety boundary.

### Validation (all before creating anything)

1. **Scene:** edited scene exists, is saved, has a file hash revision, and matches the turn's expected scene path/revision/root ID. Otherwise `no_scene`, `scene_not_saved`, or `stale_scene`.
2. **Parent:** `parent_path` resolves to a node under the edited root. Missing → `target_missing`; outside the scene → `outside_scene`.
3. **Class:** the parent is a `CollisionObject2D` (`CharacterBody2D`, `StaticBody2D`, `RigidBody2D`, `Area2D`). Anything else → `invalid_parent`.
4. **Ownership:** the parent is the edited root or is owned by the edited root. A parent inside a non-editable instance → `read_only_instance`. V1 does not edit instanced children even with editable-children enabled; that is a later scope.
5. **Conflict:** the parent has no existing direct `CollisionShape2D` child. If one exists → `target_conflict` ("A collision shape already exists; select it or remove it first"). This keeps "exactly one" for the acceptance case and avoids accidental compound shapes.
6. **Dimensions:** finite width/height within bounds → otherwise `invalid_dimensions`.
7. **Name:** optional name is valid and unique; otherwise auto-generate `CollisionShape2D`, `CollisionShape2D2`, … → `invalid_node_name` / `name_conflict` if an explicit name cannot be used.
8. **Scene revision:** re-read the scene identity immediately before committing; if it changed, abort with `stale_scene` and no mutation.

All checks happen before `CollisionShape2D.new()`, `RectangleShape2D.new()`, or `create_action()`.

### Execution

```gdscript
var root := EditorInterface.get_edited_scene_root()
var undo := EditorInterface.get_editor_undo_redo()
var node := CollisionShape2D.new()
var shape := RectangleShape2D.new()
shape.size = Vector2(width, height)
node.name = unique_name
node.shape = shape

undo.create_action("Add CollisionShape2D (%sx%s)" % [width, height], UndoRedo.MERGE_DISABLE, root)
undo.add_do_method(parent, "add_child", node, true)
undo.add_do_method(node, "set_owner", root)
undo.add_do_property(node, "shape", shape)
undo.add_do_reference(node)
undo.add_undo_method(parent, "remove_child", node)
undo.add_undo_property(node, "shape", null)
undo.commit_action()
```

Notes:

- `add_do_reference(node)` keeps the node alive across undo/redo; do not `queue_free` after commit.
- The `do_property`/`undo_property` pair restores the shape on redo and clears it on undo. The action keeps the resource reference.
- The action is assigned to the edited scene's history via the `root` context, so the normal editor undo (Ctrl+Z) affects it.
- No selection change in v1. The chat reports the path; selecting the new node would require preserving/restoring the previous selection in the action and is not part of the acceptance.
- Do not save the scene. `EditorUndoRedoManager` marks it unsaved by default.
- If the game is running, the macro still edits the edited scene, not the running remote scene; the result includes `playing: true`. No live-edit sync.

### Postcondition and rollback

After `commit_action()` verify:

- the node is inside the tree under the parent;
- `node.owner == root`;
- `node.shape is RectangleShape2D` with the requested size;
- exactly one new history entry exists.

If a postcondition fails, undo the action through the scene history. If the undo also fails, report `outcome_unknown` with the visible state; do not claim success. Never leave a half-created node without reporting it.

### Result

```json
{
  "call_id": "call_1",
  "tool": "add_rectangular_collision_shape",
  "ok": true,
  "summary": "Added CollisionShape2D under Player with an owned 32x48 RectangleShape2D.",
  "data": {
    "scene": {"path": "res://player.tscn", "revision": "sha256:...", "playing": false},
    "node_path": "Player/CollisionShape2D",
    "owner": ".",
    "shape": {"class": "RectangleShape2D", "size": [32, 48]},
    "dirty": true
  },
  "affected": [
    {"kind": "node", "scene_path": "res://player.tscn", "path": "Player/CollisionShape2D"},
    {"kind": "resource", "owner": "Player/CollisionShape2D", "class": "RectangleShape2D"}
  ],
  "undo_group": "tiiny:turn-3:call-1",
  "scene_revision": "sha256:...",
  "duration_ms": 12
}
```

`undo_group` is the ledger token. The editor history entry uses a readable action name. Story 07 records the token; story 08 can surface undo/redo history.

### Error codes

| Code | Condition |
| --- | --- |
| `no_scene` | No edited scene |
| `scene_not_saved` | Scene has no path or is unsaved |
| `stale_scene` | Scene path/revision/root changed since inspection |
| `target_missing` | Parent path no longer exists |
| `outside_scene` | Parent is outside the edited scene |
| `invalid_parent` | Parent is not a `CollisionObject2D` |
| `read_only_instance` | Parent is inside a non-editable instance |
| `target_conflict` | A direct `CollisionShape2D` already exists |
| `invalid_dimensions` | Non-finite, non-positive, or out-of-range size |
| `invalid_node_name` | Invalid explicit name |
| `name_conflict` | Explicit name already used and not auto-resolvable |
| `undo_failed` | The action could not be committed or undone |
| `outcome_unknown` | Postcondition failed and rollback could not be verified |

All errors return no scene change and no undo entry, except `outcome_unknown`, which explicitly reports that the visible state may have changed.

## Undo and redo behavior

- One action creates the node, sets ownership, assigns the shape, and sets its size. One undo removes the node; one redo restores it with the same resource.
- The resource is embedded in the scene on save; no separate `.tres` is written.
- The action must belong to the edited scene's history, not the global history, so the correct scene undoes it.
- Undo/redo does not require reselecting the node. Tests use the scene history and normal editor controls.
- Saving the scene does not break undo/redo within the session. Reopening loads the saved result but starts a new history; this is expected.

## Slices

### Slice A — macro schema and validation

Define the tool schema and the pre-commit validation pipeline using story 05's scene identity, path resolution, and ownership helpers. Include parent class, ownership, conflict, dimension, name, and revision checks.

Gate: deterministic validation fixtures cover every error code; no node, resource, or undo entry is created for any failure.

Deliverables: macro provider definition, validation helpers, error results.

### Slice B — undoable commit

Implement node/resource creation, the `EditorUndoRedoManager` action, do/undo methods and properties, object reference lifetime, commit, and postcondition verification. Add rollback for postcondition failure.

Gate: one node and one owned `RectangleShape2D` are created; exactly one history entry exists; undo removes and redo restores node, owner, shape, and size. No leaked node after undo/redo cycles.

Deliverables: commit implementation, undo/redo tests.

### Slice C — ownership, instancing, and conflicts

Implement root-owned parent enforcement, instanced-parent rejection, existing-shape conflict handling, explicit/auto node names, and scene revision recheck immediately before commit. Include running-scene reporting.

Gate: instanced/read-only parents and existing shapes are rejected with no mutation; auto names are unique; a scene switch between inspection and execution returns `stale_scene`.

Deliverables: ownership/conflict handlers and fixtures.

### Slice D — no-partial-change and persistence

Add before/after snapshots (node count, child count, resource count, property values, undo history count) for every failure path. Verify the successful macro persists through save/reopen and appears correctly in the editor scene tree.

Gate: every failure leaves no partial node/resource/undo entry; a saved and reopened scene contains exactly one correct CollisionShape2D; the scene is marked dirty until saved.

Deliverables: no-partial tests, save/reopen fixture, displayed scene-tree check.

### Slice E — integration and handoff

Expose the macro through the same provider interface as 05 (`definitions()`/`execute()`), with `risk: "mutating"`, availability (saved scene), and the structured result/undo group. Story 07 composes it into the registry and sends one macro call. Do not add generic scene-edit tools.

Gate: 07's registry can consume the definition unchanged; fixed tool calls pass without a model; WS-01/02/13 are satisfied at the executor level.

Deliverables: provider interface, integration notes, work-item/STATUS handoff.

## Scenario mapping

| Scenario | Slice | Check |
| --- | --- | --- |
| WS-01 rectangular collision shape | B, D, E | One node + owned RectangleShape2D; size 32×48; save/reopen; one undo/redo; no script |
| WS-02 incompatible parent or deleted target | A, C, D | Explicit error; no node/resource/undo entry; no selection substitution |
| WS-13 scene switch between planning and execution | C | `stale_scene`; no mutation in the wrong scene |
| Instanced/inherited ownership | C | Root-owned parent accepted; non-editable instance rejected |
| Read-only inspection unaffected | D | 05 hash/node/undo assertions still pass |

## Open questions and recommended decisions

1. **Existing CollisionShape2D.** Recommend rejecting with `target_conflict` for v1; the user can select or remove the existing shape. Adding a second shape is valid in Godot but is a different request.
2. **Instanced parents.** Recommend allowing only the edited root or root-owned nodes. Editable-children support is a later scope; silently editing an instance is a risk.
3. **Auto-save.** Recommend never saving automatically. The macro marks the scene dirty; the user saves, matching normal editor behavior.
4. **Selection.** Recommend not changing the selection in v1. The chat reports the new node path; selecting would require saving/restoring the previous selection inside the action.
5. **Undo token vs action name.** Recommend a Tiiny ledger token plus a readable editor action name (for example "Add CollisionShape2D (32×48)").
6. **Node name.** Recommend an optional explicit name with an auto-generated unique fallback; invalid explicit names are errors, not silently rewritten.
7. **Editing while playing.** Recommend allowing edits to the edited scene and reporting `playing: true`; do not sync to the running scene. Runtime editing is a later debugger feature.
8. **Unsupported shapes.** Recommend `RectangleShape2D` only in 06. Capsule/circle/polygon recipes belong to later resource stories.

## Dependencies and risks

- **Story 05:** saved-scene identity, path/ownership helpers, and structured results. The macro reuses them and repeats all domain checks at execution.
- **Undo API:** verify `create_action` history assignment, `add_do_reference` lifetime, and postcondition behavior in this build; tests must cover undo/redo cycles without leaks.
- **Instanced/inherited scenes:** the main correctness risk. Root-owned parents only in v1.
- **Resource lifetime:** the do/undo property pair must keep the `RectangleShape2D` alive for redo; do not free it manually.
- **Scene dirty state:** the macro changes the scene but not the file. Reports must distinguish "applied" from "saved".
- **Model orchestration:** 07 owns tool availability, prompt, ledger, and macro-first selection. 06 does not send tools to the model.
- **Scope control:** no generic property writes, deletion, reparenting, scripts, or asset imports. Those are later stories.

## Handoff

Planning only. No build, test, or device operation was performed. Implementation starts after 05's provider foundation, with slice A (validation) and slice B (undoable commit). Record the tool contract, error matrix, no-partial evidence, undo/redo cycles, save/reopen result, and any API limitations in the work item and STATUS.
