# Story 14 implementation plan — typed editor transaction primitives

Status: Accepted. Implemented and verified; see acceptance evidence.

Parent: [14 — Typed editor transaction primitives](../work-items/14-editor-primitives.md).

## Goal

Expose a safe, model-composable editor transaction language. Recipes remain macros for complex workflows; generic primitives handle ordinary authoring that should not need a bespoke recipe per task.

## Model-facing tool

Name: `apply_editor_transaction`.

Input:

```json
{
  "expected_scene_revision": "sha256:...",
  "expected_session_revision": "undo:1",
  "operations": [
    {"op": "create_node", "id": "camera", "class": "Camera2D", "parent": ".", "name": "Camera2D", "properties": {"enabled": true}},
    {"op": "create_resource", "id": "metal", "class": "StandardMaterial3D", "properties": {"metallic": 1.0, "roughness": 0.35}},
    {"op": "assign_resource", "target": "Crate", "property": "material_override", "resource": "metal"}
  ]
}
```

Limits: at most 16 operations; IDs/names/paths bounded; values JSON-safe plus transaction resource references.

## Operations

| Op | Required fields | Rules |
| --- | --- | --- |
| `create_node` | class, parent, name | Instantiable Node; parent owned; unique name; initial properties validated; owner set to scene root. |
| `set_property` | target, property, value | Target exists; property exists/writable; type-compatible; no internal/editor-only storage. |
| `create_resource` | class, id, properties | Instantiable Resource; reject scripts, PackedScene, editor-only classes; properties validated. |
| `assign_resource` | target, property, resource | Resource created in the same transaction; property type-compatible. |
| `add_child` | parent, node | Both exist; no cycle; unique sibling name. |
| `set_owner` | node, owner | Owner is an ancestor of the planned parent and belongs to the edited scene. |
| `remove_node` | target | Owned, non-root, non-instanced node; undo restores subtree/owner. |
| `reparent_node` | target, parent | Owned nodes only; no cycle; preserve ownership and local intent explicitly. |
| `duplicate_node` | target, new_name | Owned subtree; unique name; undo removes the duplicate. |
| `instantiate_scene` | path, parent, name | `res://` PackedScene; owned parent; unique name; reports instance identity. |
| `connect_signal` | source, signal, target, method | Signal exists; target method exists; optional flags; undo disconnects. |

Not exposed: `call_method`, prebuilt resource literals, raw `set()`/`call()`, scripts, files, editor internals, OS/Engine classes.

## Validation pipeline

1. Validate envelope and scene identity against the inspector context (path, base revision, session revision, root ID).
2. Reject dirty/unsaved/read-only/playing combinations using story 06 rules.
3. Parse all operations and IDs.
4. Prepare nodes/resources without attaching them.
5. Validate classes, names, owners, references, property metadata, and type compatibility.
6. Build all undo operations.
7. Commit once with a readable action name; no automatic save.
8. Verify postconditions; undo the transaction on failure and report `undo_failed`/`outcome_unknown`.
9. Return summary, affected nodes/resources, action name, undo group, and scene revision.

## Class/property policy

- Nodes: `Node` subclasses that are instantiable; reject `Editor*`, `OS`, `Engine`, and editor-only classes.
- Resources: `Resource` subclasses; reject `Script`, `GDScript`, `PackedScene`, and editor internals. Prefer shape/material/curve/theme/animation resources.
- Properties: use `get_property_list()`; reject `PROPERTY_USAGE_INTERNAL` and read-only; reject editor-only unless explicitly allowlisted (`theme_override_*` handled as a special case).
- Values: primitives, `Vector*`, `Rect*`, `Transform*`, `Color`, `NodePath`, and `{"ref": id}` to transaction resources only.
- No arbitrary Object references, no node references across the scene, no script execution.

## Transaction/executor work

Extend `editor/tiiny/tools/transactions.gd`:

- Add `apply_editor_transaction` as a product recipe with a schema and dedicated validator/builder.
- Add missing operations: remove, reparent, duplicate, instantiate scene, connect signal.
- Reuse `create_node`, `create_resource`, `add_child`, `set_owner`, `set_property`, and undo verification.
- Ensure atomic preparation/rollback and one undo action.
- Keep recipe-specific `call_method`/resource-literal paths out of the model-facing schema.

## Availability and UX

- Available only for a saved/clean edited scene, valid scene identity, and a model tool-capable session.
- Return actionable errors for unsaved/dirty/stale/read-only/instanced targets.
- Render one action card and one ledger entry per transaction; affected nodes/resources navigate through existing story 08 controls.
- Report that the scene is dirty and not saved.

## Slices

### Slice A — schema, create/set/resource

Add the tool, class/property validation, create node, set property, create/assign resource, one undo, tests.

### Slice B — structure and references

Add remove/reparent/duplicate, instantiate scene, signal connection, reference validation, rollback tests.

### Slice C — composition examples

Deterministic composed tasks: Camera2D with smoothing, Label HUD, OmniLight3D, PBR crate, collision layers, one-way platform. Verify one undo per transaction and save/reopen behavior.

### Slice D — live sample and catalog handoff

Run representative live prompts. Record failures, model traces, and reclassification candidates for story 16. Update README/evidence/STATUS.

## Gates

- No partial mutation from an invalid compound transaction.
- No arbitrary methods, scripts, files, or editor internals.
- One undo action; no automatic save.
- Composed primitives solve ordinary authoring tasks without a recipe per task.
- Recipes remain for complex/risky workflows and all existing tests still pass.

All gates verified; see [acceptance evidence](../evidence/14-acceptance.md).

## Handoff

Accepted. Live evidence: Camera2D at (100,200) with smoothing, Label `Score: 0`, and StandardMaterial3D on `World/Crate` via `apply_editor_transaction`. Remaining specialized/behavior work moves to stories 15–17.
