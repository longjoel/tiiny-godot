# Story 06 implementation plan — typed scene edits with grouped undo/redo

Status: Planning. Implementation depends on story 05 (saved-scene identity, path/ownership inspection). No code changes in this planning task.

Parent: [06 — Typed scene edits with grouped undo/redo](../work-items/06-workspace-transactions.md). Visuals: [transaction diagrams](../mockups/06-workspace-transactions-diagrams.md). Contract: [story 07 tool orchestration](../implementation/07-orchestrator.md).

## Execution contract

Story 06 builds a **class-agnostic transaction executor** plus a **recipe layer**. A recipe is an editor-owned, typed definition that turns validated model parameters into a small list of scene operations. The executor validates those operations generically, commits them as one editor undo action, and verifies the result.

`CollisionShape2D` + `RectangleShape2D` is the **first recipe**, not a special case in the executor. There must be no `if class == "CollisionShape2D"` branch in the transaction or undo code. A second test recipe must run through the same executor without changes.

The model supplies recipe parameters only. It never supplies operation types, class names, property names, or raw values for arbitrary properties. Recipes are reviewed editor code; this is what keeps generic property assignment safe in 06.

The edited scene must have been saved at least once and must be clean for a mutation. Story 05 allows dirty inspection; story 06 rejects a dirty scene for recipes with `scene_dirty` ("Save the scene before applying an edit"). The executor never saves the scene automatically; it marks it dirty. After a successful recipe, read-only inspection remains available against the dirty session revision, but further mutations require saving. The recipe's postcondition is the verification for the turn.

No delete, reparent, generic property-write, script, or asset-import recipe is part of 06.

## Baseline

Story 05 provides scene identity/revision, scene-relative paths, selection, ownership, `scene_file_path`, and editor-visible properties. The executor reuses those helpers and revalidates every fact at execution.

The editor provides the undo API:

- `EditorInterface.get_editor_undo_redo()`, `get_object_history_id(root)`.
- `create_action(name, MERGE_DISABLE, root)`, `add_do_method`, `add_undo_method`, `add_do_property`, `add_undo_property`, `add_do_reference`, `commit_action`.
- `get_history_undo_redo(history_id).undo()/redo()`, `get_history_count()`.
- `Node.add_child(node, true)`, `set_owner(root)`, `remove_child(node)`.
- `ClassDB.class_exists`, `ClassDB.can_instantiate`, `ClassDB.is_parent_class`, `ClassDB.instantiate`.
- `Object.get_property_list`, property usage flags, `PropertyInfo.type`/`class_name`.

## Architecture

```text
Model / fixture
   │  recipe name + parameters
   ▼
Recipe registry ──► Recipe.validate(params, context) ──► normalized request
   │                                            │
   │                                            ▼
   │                                     Recipe.build(normalized) ──► typed operations
   ▼
Transaction executor ──► generic operation validation ──► one UndoRedo action
   │
   ├─ create_node(class, name, parent)
   ├─ create_resource(class, properties)
   ├─ add_child(parent, node)
   ├─ set_owner(node, owner)
   └─ set_property(target, property, value)
```

### Recipe

```gdscript
{
  "name": "add_rectangular_collision_shape",
  "title": "Add rectangular collision shape",
  "description": "...",
  "parameters": { /* JSON schema for model parameters */ },
  "risk": "mutating",
  "validate": Callable,   # (params, scene_context) -> {ok, error, request}
  "build": Callable       # (request) -> {ops: Array, summary, affected_hint}
}
```

Recipes own domain knowledge: which parent classes are compatible, which properties are set, which conflicts matter, and which resource class to create. They return **data**, not executable model input. They cannot perform arbitrary editor calls.

### Operations

| Operation | Fields | Undo |
| --- | --- | --- |
| `create_node` | `id`, `class`, `name` | `add_do_reference(node)`; node is added by `add_child` |
| `create_resource` | `id`, `class`, `properties` | action keeps the resource reference |
| `add_child` | `parent`, `node` | do `add_child(node, true)`; undo `remove_child(node)` |
| `set_owner` | `node`, `owner` | do `set_owner(owner)`; undo `set_owner(old)` |
| `set_property` | `target`, `property`, `value` | do/undo property pair with the old value |

Targets are scene paths or operation IDs. Values are literals or operation IDs. No property name or class is accepted from the model unless a recipe declared it.

### Generic validation

Before any object is created:

- `create_node`: class exists, can instantiate, inherits `Node`, name is valid and unique under the target parent.
- `create_resource`: class exists, can instantiate, inherits `Resource`; each declared property exists and accepts the value type.
- `add_child`: parent exists, no cycles, node not already parented, parent is not the node.
- `set_owner`: owner is an ancestor of the node in the resulting scene.
- `set_property`: target exists (scene or operation), property exists, is writable (not `READ_ONLY`), and accepts the value; resource-valued properties require a compatible `Resource` class; category/group/internal properties are rejected.
- All operations are declared by a registered recipe; the executor does not accept arbitrary plans from the model.
- Scene path/revision/root match the turn context; the saved-scene rule applies.

## First recipe — rectangular collision shape

`add_rectangular_collision_shape(parent_path, width, height, node_name?)`

Recipe validation:

- parent exists under the edited root;
- parent is a `CollisionObject2D` (CharacterBody2D, StaticBody2D, RigidBody2D, Area2D);
- parent is the edited root or owned by it (instanced children deferred);
- no existing direct `CollisionShape2D` (`target_conflict`);
- finite width/height > 0, ≤ 100000;
- optional node name valid/unique; otherwise auto-generate `CollisionShape2D`, `CollisionShape2D2`, …;
- scene revision matches the turn.

Recipe operations:

```text
create_node(CollisionShape2D, name)
create_resource(RectangleShape2D, {size: Vector2(width, height)})
add_child(parent, node)
set_owner(node, root)
set_property(node, "shape", resource)
```

The executor turns these into one undo action with a readable name such as "Add CollisionShape2D (32×48)". The recipe remains the only place that knows those classes and properties.

## Undo and lifetime

- One recipe expands to one action on the edited scene's history (root context).
- `create_node` + `add_child`: do `add_child`, undo `remove_child`, `add_do_reference(node)` to keep the orphaned node alive for redo and free it when the redo stack is discarded.
- `create_resource`: the action's property operation holds the resource reference; do not free it manually.
- `set_property`: capture the old value; do/undo property pair; redo restores the new value and resource.
- `set_owner`: undo restores the previous owner (root for new nodes; null when removed).
- Postcondition: every created node is in the tree with the expected owner/class; every property equals the planned value; exactly one history entry was added.
- If a postcondition fails, undo the action. If the undo cannot be verified, report `outcome_unknown` with the visible state.

## Result and errors

```json
{
  "call_id": "call_1",
  "tool": "add_rectangular_collision_shape",
  "ok": true,
  "summary": "Added CollisionShape2D under Player with an owned 32x48 RectangleShape2D.",
  "data": {
    "recipe": "add_rectangular_collision_shape",
    "scene": {"path": "res://player.tscn", "revision": "sha256:...", "session_revision": "history:43", "dirty": true, "playing": false},
    "created": {"nodes": ["Player/CollisionShape2D"], "resources": ["Player/CollisionShape2D:shape"]},
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

`undo_group` is the ledger token. The editor history entry uses a readable action name. The result's `session_revision` is read after commit, so a follow-up read-only inspection matches the new dirty version. Story 07 records the token; story 08 can surface undo/redo history.

Generic codes: `unknown_recipe`, `invalid_arguments`, `no_scene`, `scene_not_saved`, `scene_dirty`, `stale_scene`, `class_not_found`, `class_not_instantiable`, `invalid_operation`, `invalid_parent`, `target_missing`, `outside_scene`, `read_only_instance`, `target_conflict`, `invalid_name`, `name_conflict`, `property_missing`, `property_not_writable`, `type_mismatch`, `resource_incompatible`, `undo_failed`, `outcome_unknown`.

Recipe-specific validation returns its own codes (for example `invalid_parent`, `target_conflict`, `invalid_dimensions`) through the same error envelope. A failure before commit creates no node, resource, or undo entry. `outcome_unknown` is the only code that may leave a visible partial state.

## Genericity test

Register two **test-only** recipes in the fixture, not exposed to the model:

1. `add_marker_2d(parent_path)` — create a `Marker2D` under a `Node2D`; one node, no resource, one undo action.
2. `add_capsule_collision_shape(parent_path, radius, height)` — create a `CollisionShape2D` with a `CapsuleShape2D`; same executor, different recipe data.

Both must run without editing the transaction executor or undo code. This proves the framework is recipe-driven and that the collision-shape acceptance case is not special-cased. Test recipes live only in test fixtures; product scope remains the first recipe.

## Slices

### Slice A — transaction model and generic executor

Define the operation types, object/target resolution, generic validation, undo action construction, reference lifetimes, commit, postcondition checks, and rollback. No recipes yet; test with synthetic operation lists.

Gate: synthetic transactions create nodes/resources, validate class/property/ownership rules, commit one undo action, undo/redo cleanly, and reject invalid operations without partial state.

Deliverables: transaction executor, operation validators, undo tests.

### Slice B — recipe interface and first recipe

Add the recipe definition/registry and implement `add_rectangular_collision_shape` as a recipe. The recipe owns parent compatibility, conflict, dimensions, name, and operation construction.

Gate: the recipe produces the expected operation list; model-facing parameters are validated; no class-specific logic appears in the executor.

Deliverables: recipe registry, first recipe, recipe fixtures.

### Slice C — no-partial, undo/redo, and persistence

Add before/after snapshots for every failure path, save/reopen checks, and the displayed scene-tree check. Verify one undo removes and one redo restores the node, owner, shape, and size.

Gate: WS-01/02/13 pass through fixed recipe calls; every failure leaves node count, child count, resource count, selection, and history unchanged; the saved/reopened scene is correct.

Deliverables: no-partial tests, undo/redo cycles, save/reopen fixture.

### Slice D — genericity fixture and integration

Add the test-only Marker2D and CapsuleShape2D recipes and run them through the same executor. Expose recipe definitions/handlers to story 07 (`definitions()`/`execute()`) with `risk: "mutating"` and the structured result/undo group. Story 07 remains the only model-facing registry.

Gate: the second and third recipes require no executor changes; 07 can consume the provider unchanged; fixed calls pass without a model.

Deliverables: genericity fixtures, provider interface, integration notes.

### Slice E — handoff

Record the operation contract, recipe examples, error matrix, undo/redo evidence, save/reopen result, and remaining recipe gaps. Update the work item and STATUS.

## Scenario mapping

| Scenario | Slice | Check |
| --- | --- | --- |
| WS-01 rectangular collision shape | B, C | One node + owned RectangleShape2D; 32×48; save/reopen; one undo/redo; no script |
| WS-02 incompatible parent or deleted target | B, C | Explicit error; no node/resource/undo entry; no selection substitution |
| WS-13 scene switch between planning and execution | B, C | `stale_scene`; no mutation in the wrong scene |
| Generic executor (new recipe) | D | Test-only Marker2D/Capsule recipes run without executor edits |
| Read-only inspection unaffected | C | 05 hash/node/undo assertions still pass |

## Open questions and recommended decisions

1. **Generic transaction tool for the model.** Recommend no in 06. The model calls named recipes; arbitrary operation lists are a later, separately validated capability.
2. **Product recipe count.** Recommend only the collision-shape recipe in 06; use test-only recipes to prove genericity. New product recipes belong to later stories (animation, physics, resources).
3. **Existing CollisionShape2D.** Recipe-level conflict: reject and ask the user to select or remove the existing shape. Not an executor rule.
4. **Root-owned parents only.** Recommended for v1; editable instanced children are a later recipe/validation extension.
5. **Auto-save and selection.** No automatic save; no selection change. Dirty scenes are inspectable, but recipes require a clean scene (`scene_dirty`). The result reports the new node path.
6. **Editing while playing.** Allow edits to the edited scene, report `playing`, never sync to the running scene.
7. **Recipe location.** Editor-owned scripts under `editor/tiiny/tools/recipes/`, registered by a recipe registry. Test recipes live in fixtures.
8. **Future operations.** Delete, reparent, and generic property writes need their own validation and undo semantics; do not add them by widening `set_property` casually.

## Dependencies and risks

- **Story 05:** saved-scene identity, path/ownership helpers. The executor repeats all domain checks at execution.
- **Undo API:** verify history assignment, reference lifetimes, and postcondition behavior; test undo/redo cycles.
- **Generic property safety:** only recipes declare properties. If a generic transaction tool is added later, it needs an explicit allowlist/type system; do not expose raw `set_property` to the model.
- **Resource compatibility:** check `PropertyInfo.class_name` and actual value classes; do not trust the recipe alone.
- **Instanced/inherited scenes:** root-owned parents only in v1.
- **Scene dirty state:** the executor changes the scene but not the file. Dirty inspection is allowed after the edit; further mutations require saving (`scene_dirty`). Reports distinguish applied from saved.
- **Scope:** one product recipe in 06; the transaction executor is the reusable part.

## Handoff

Planning only. No build, test, or device operation was performed. Implementation starts with the generic executor (slice A), then the recipe interface and first recipe (B), followed by no-partial/undo/persistence (C) and the genericity fixture/integration (D). Record the operation contract, recipe examples, error matrix, undo/redo cycles, save/reopen result, and remaining recipe gaps in the work item and STATUS.
