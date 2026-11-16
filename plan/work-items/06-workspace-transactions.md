# 06 — Typed scene edits with grouped undo/redo

Status: Accepted. The class-agnostic executor and recipe registry are implemented; the product rectangular collision-shape recipe and test-only Marker2D/Capsule recipes pass through the same undo path. See [acceptance evidence](../evidence/06-acceptance.md).

Feature: Typed scene edits with grouped undo/redo

Sequence: 06

Stream: `workspace`

Dependencies: 05

Implementation: [plan](../implementation/06-workspace-transactions.md). Visuals: [transaction diagrams](../mockups/06-workspace-transactions-diagrams.md). Tool contract: [story 07 orchestration plan](../implementation/07-orchestrator.md).

## Scope

Implement the first native workspace macro: create a CollisionShape2D under a compatible parent, create and assign a RectangleShape2D, and set dimensions.

Design constraint: the collision shape is the first **recipe** of a class-agnostic transaction executor, not a special case in the executor or undo code. Class-specific validation and operation construction live in the recipe. A second test-only recipe must run through the same executor without changes.

## Acceptance criteria

- [x] Validate target scene, parent, classes, ownership, writable properties, and value/resource compatibility before committing.
- [x] An invalid parent, incompatible resource, stale target, or invalid property produces no partial scene mutation.
- [x] The successful macro appears correctly in the editor and persists correctly when the scene is saved/reopened.
- [x] One normal editor undo removes the operation; redo restores nodes, properties, and resource assignments.
- [x] Group scene changes through Godot undo/redo; document separate recovery for filesystem or imported-asset operations.
- [x] Focused executor tests and a running-editor test pass independently of model inference.

## Concrete scenarios

Use WS-01, WS-02, WS-13 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Accepted. Implementation: `editor/tiiny/tools/transactions.gd`, build/dock injection as `workspace_transactions_script`, product rectangular-collision recipe, and test-only Marker2D/Capsule recipes in `editor_workspace_transactions.gd`. Final build `da3b7c67a` (PID 797629) passed the transaction editor fixture and the existing 11-stage editor smoke. See [acceptance evidence](../evidence/06-acceptance.md). Story 07 consumes the recipe provider and remains the model-facing registry.
