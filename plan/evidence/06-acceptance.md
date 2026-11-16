# Story 06 — acceptance evidence

Story 06 is accepted. The editor-owned transaction provider implements a class-agnostic operation executor and a recipe layer. The product recipe creates one `CollisionShape2D` with an owned `RectangleShape2D`; test-only Marker2D and CapsuleShape2D recipes run through the same executor without changes.

Executable: `bin/godot.linuxbsd.editor.x86_64`, version `4.8.beta.custom_build.da3b7c67a`. Final build PID 808644 exited 0 in 38.21s with `scons platform=linuxbsd target=editor use_static_cpp=no -j8`. No build remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Validate target scene, parent, classes, ownership, properties, resource compatibility | The editor fixture calls the recipe with a non-collision parent, missing parent, zero width, existing shape, incompatible resource class, dirty scene, and stale turn context. Each returns an explicit error before scene mutation. The executor validates class instantiation, node/resource inheritance, names, parent cycles, owner ancestry, property existence/writability, and resource class lists. |
| No partial mutation on invalid input | Before/after checks cover root child count and undo history count for invalid parent, missing parent, invalid dimensions, existing-shape conflict, and an incompatible `Gradient` assigned to `shape`. The incompatible-resource recipe creates no node and no undo entry. |
| Successful macro visible and persists | The fixture inspects `Player/CollisionShape2D`, verifies `RectangleShape2D` and `Vector2(32, 48)`, saves `main.tscn`, reloads it, and rechecks the owned shape. |
| One undo/redo restores node, owner, shape, size | One recipe produces exactly one history entry. `undo()` removes the shape; `redo()` restores the node, owner, resource assignment, and size. |
| Group scene changes through editor undo | The executor uses one `EditorUndoRedoManager` action with scene-root context and do/undo methods/properties. Filesystem/import recovery remains outside this story. |
| Focused executor and running-editor tests | `editor_workspace_transactions.gd` runs in a real headless editor and exercises all of the above without model inference. |
| Class-agnostic genericity | Test-only `add_marker_2d` (Marker2D) and `add_capsule_collision_shape` (CapsuleShape2D) recipes register from the fixture and run through the same executor and undo path. |

## Runs

| Check | Result | Report/log |
| --- | --- | --- |
| Transaction editor integration | Passed | `/tmp/transactions-protocol-final.log` |
| Existing editor smoke + restart stages | Passed, 11/11 stages | `/tmp/tiiny-protocol-final.json` |
| Build | Exit 0, 38.21s | `/tmp/tiiny-story07-build9.log` |

## Implementation notes

- `editor/tiiny/tools/transactions.gd` holds the executor, default rectangular-collision recipe, and recipe registration API.
- The provider is embedded through the generated source list and injected into the dock as `workspace_transactions_script`; it is not advertised to the model in 06.
- Operations are `create_node`, `create_resource`, `add_child`, `set_owner`, and `set_property`. The executor accepts only recipe-built operation lists.
- One action uses the edited scene root as context; the scene is marked dirty, never saved automatically.
- Postcondition failure attempts undo. A visible effect that cannot be undone is reported as `outcome_unknown`.
- `PropertyInfo.class_name` is a comma-separated resource class list; compatibility checks each declared class.

## Remaining boundaries

- Only the rectangular collision-shape recipe is a product recipe in 06; Marker2D/Capsule recipes are test-only.
- Editable instanced parents, delete/reparent, arbitrary property writes, script attachment, and asset imports are later work.
- Story 07 owns model exposure, registry composition, schemas, availability, and the action ledger.
