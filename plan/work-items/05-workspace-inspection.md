# 05 — Read-only Godot workspace tools

Status: Planning complete; implementation can start immediately (depends only on story 01).

Feature: Read-only Godot workspace tools

Sequence: 05

Stream: `workspace`

Dependencies: 01

Implementation: [plan](../implementation/05-workspace-inspection.md). Visuals: [inspection diagrams](../mockups/05-workspace-inspection-diagrams.md). Tool contract: [story 07 orchestration plan](../implementation/07-orchestrator.md).

## Scope

Expose the actual edited scene, selection, classes, properties, resources, ownership, and signals as structured context.

Scenes must be saved at least once. Dirty scenes are inspectable and report a dirty flag plus a session revision from the editor undo history; never-saved scenes return `scene_not_saved`. Mutations require a clean scene.

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
