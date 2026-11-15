# 05 — Read-only Godot workspace tools

Status: Queued

Feature: Read-only Godot workspace tools

Sequence: 05

Stream: `workspace`

Dependencies: 01

## Scope

Expose the actual edited scene, selection, classes, properties, resources, ownership, and signals as structured context.

## Acceptance criteria

- [ ] Tools return scene identity, scene-relative node identifiers, classes, and relevant ownership for a test scene.
- [ ] Property/resource inspection returns Godot types and supported writable properties, with bounded results.
- [ ] No scene, missing selection, deleted target, and scene switching return explicit errors or empty states.
- [ ] Inspection does not mutate the scene or project files.
- [ ] Tests cover inherited/instanced nodes and avoid confusing the edited scene with the running remote scene.

## Concrete scenarios

Use WS-01, WS-02, WS-11 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Pending. Record changed files, validation commands and results, editor/device observations, remaining limitations, and the next action. Update [STATUS.md](../STATUS.md) when handing off.
