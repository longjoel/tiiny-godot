# 14 — Typed editor transaction primitives

Status: Ready to start

Feature: Model-composable typed editor transactions

Sequence: 14

Stream: `workspace`

Dependencies: 05, 06, 07, 08, 11, 12

Implementation: [plan](../implementation/14-editor-primitives.md).

## Scope

Expose the existing transaction machinery to the model as a bounded, validated editor transaction language. This is the general authoring path behind the macro recipes, not a replacement for them.

The model supplies a list of typed operations. The editor validates the whole transaction before mutating, then commits exactly one undo action. Recipes remain the preferred path for complex/risky workflows (torch flicker, generated 3D/audio import, collision-shape macro).

Authoring operations are distinct from gameplay behavior. Movement, spin, jumping, camera follow, door logic, and input remain first-class script tasks (story 15).

## Operation set

- `create_node` — instantiable Node class, owned parent, unique name, validated initial properties.
- `set_property` — existing target, writable/type-compatible property; resource references only to resources created in the transaction.
- `create_resource` — bounded Resource class and validated properties.
- `assign_resource` — attach a transaction-created resource to an existing property.
- `add_child` / `set_owner` — explicit hierarchy/ownership when not covered by create.
- `remove_node`, `reparent_node`, `duplicate_node` — owned, non-instanced scene nodes.
- `instantiate_scene` — a `res://` PackedScene under an owned parent.
- `connect_signal` — existing signal, existing target method, undoable disconnect.

`call_method`, prebuilt resource literals, scripts, filesystem access, and editor-internal classes remain recipe-only.

## Acceptance criteria

- [ ] The model can create an allowed node under an owned parent with validated initial properties in one undo action.
- [ ] Property/resource assignment rejects missing, read-only, internal, type-incompatible, or out-of-transaction references before mutation.
- [ ] Remove, reparent, duplicate, scene instantiation, and signal connection are validated and undoable.
- [ ] A compound transaction is atomic: any invalid operation leaves the scene, history, and dirty state unchanged.
- [ ] Ownership, instanced-scene boundaries, stale scene/session revisions, unsaved scenes, and running-scene state are handled explicitly.
- [ ] Operations are bounded, reject editor/internal classes and arbitrary methods, and return structured affected nodes/resources plus an action name.
- [ ] Chat action cards and the ledger show the transaction once, with target navigation for affected nodes/resources.
- [ ] Deterministic fixtures cover each operation, invalid inputs, rollback, undo/redo, and composed examples (Camera2D, Label HUD, OmniLight3D, PBR material, collision layers, one-way platform).
- [ ] A live sample of composed editor requests succeeds and records model/tool evidence.

## Concrete scenarios

Add WS-16: “Compose a small scene feature from primitives” to [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md).

## Evidence and handoff

Pending. Record operation schema, changed files, deterministic/live results, rejected cases, and remaining specialized gaps. Update [STATUS.md](../STATUS.md) and reclassify catalog entries in story 16.
