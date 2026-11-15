# 06 — Typed scene edits with grouped undo/redo

Status: Queued

Feature: Typed scene edits with grouped undo/redo

Sequence: 06

Stream: `workspace`

Dependencies: 05

## Scope

Implement the first native workspace macro: create a CollisionShape2D under a compatible parent, create and assign a RectangleShape2D, and set dimensions.

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
