# 06 — Typed scene edits with grouped undo/redo

Status: Planning complete; implementation is gated on story 05 (saved-scene identity, path/ownership inspection).

Feature: Typed scene edits with grouped undo/redo

Sequence: 06

Stream: `workspace`

Dependencies: 05

Implementation: [plan](../implementation/06-workspace-transactions.md). Visuals: [transaction diagrams](../mockups/06-workspace-transactions-diagrams.md). Tool contract: [story 07 orchestration plan](../implementation/07-orchestrator.md).

## Scope

Implement the first native workspace macro: create a CollisionShape2D under a compatible parent, create and assign a RectangleShape2D, and set dimensions.

Design constraint: the collision shape is the first **recipe** of a class-agnostic transaction executor, not a special case in the executor or undo code. Class-specific validation and operation construction live in the recipe. A second test-only recipe must run through the same executor without changes.

## Acceptance criteria

- [ ] Validate target scene, parent, classes, ownership, writable properties, and value/resource compatibility before committing.
- [ ] An invalid parent, incompatible resource, stale target, or invalid property produces no partial scene mutation.
- [ ] The successful macro appears correctly in the editor and persists correctly when the scene is saved/reopened.
- [ ] One normal editor undo removes the operation; redo restores nodes, properties, and resource assignments.
- [ ] Group scene changes through Godot undo/redo; document separate recovery for filesystem or imported-asset operations.
- [ ] Focused executor tests and a running-editor test pass independently of model inference.

## Concrete scenarios

Use WS-01, WS-02, WS-13 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Pending. Record changed files, validation commands and results, editor/device observations, remaining limitations, and the next action. Update [STATUS.md](../STATUS.md) when handing off.
