# 05 — Read-only Godot workspace tools

Status: Accepted. The embedded read-only inspector exposes the seven planned tools through `definitions()` and `execute()`, is injected into the dock as a script, and is not advertised to the model. Pure and editor fixtures cover scene identity, ownership, properties, resources, signals, bounds, errors, dirty/undo revisions, scene switching, inherited/instanced scenes, read-only guarantees, and edited-vs-running isolation. See [acceptance evidence](../evidence/05-acceptance.md).

Feature: Read-only Godot workspace tools

Sequence: 05

Stream: `workspace`

Dependencies: 01

Implementation: [plan](../implementation/05-workspace-inspection.md). Visuals: [inspection diagrams](../mockups/05-workspace-inspection-diagrams.md). Tool contract: [story 07 orchestration plan](../implementation/07-orchestrator.md).

## Scope

Expose the actual edited scene, selection, classes, properties, resources, ownership, and signals as structured context.

Scenes must be saved at least once. Dirty scenes are inspectable and report a dirty flag plus a session revision from the editor undo history; never-saved scenes return `scene_not_saved`. Mutations require a clean scene.

## Acceptance criteria

- [x] Tools return scene identity, scene-relative node identifiers, classes, and relevant ownership for a test scene.
- [x] Property/resource inspection returns Godot types and supported writable properties, with bounded results.
- [x] No scene, missing selection, deleted target, and scene switching return explicit errors or empty states.
- [x] Inspection does not mutate the scene or project files.
- [x] Tests cover inherited/instanced nodes and avoid confusing the edited scene with the running remote scene.

## Concrete scenarios

Use WS-01, WS-02, WS-11 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Accepted. Implementation: `editor/tiiny/tools/inspector.gd`, generated-source/build injection through `editor/SCsub` and `editor_node.cpp`, a dock `workspace_inspector_script` property, pure fixture `test_workspace_inspector.gd`, and editor fixture `editor_workspace_inspector.gd`/`check_workspace_inspector.py`. Final build `da3b7c67a` (PID 756396) passed the pure suite, editor integration fixture, existing 11-stage editor smoke, and all 25 Jobs modes. See [acceptance evidence](../evidence/05-acceptance.md). Story 06 consumes the inspector; story 07 owns model exposure and the registry.
