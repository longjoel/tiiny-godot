# 17 — Specialized authoring recipes

Status: Accepted for the first specialized family. 2D/3D particles and imported-mesh collision are implemented and covered; remaining specialized tasks are explicit follow-ups. See [acceptance evidence](../evidence/17-acceptance.md).

Feature: Complex editor authoring beyond composed primitives

Sequence: 17

Stream: `workspace`

Dependencies: 14, 15, 16

Implementation: [plan](../implementation/17-specialized-authoring.md).

## Scope

Cover the genuinely specialized authoring workflows that should not be forced through generic property writes. Work from the catalog’s `specialized_missing` list; do not implement a recipe merely because a task is common if composed primitives already solve it safely.

## Candidate areas

- TileMapLayer/TileSet and tile collision authoring.
- GridMap and 3D tile layout.
- NavigationRegion3D/navigation mesh baking.
- CSG boolean/blockout operations.
- AnimationPlayer/AnimationTree tracks, sprite-frame animation, and reusable tween recipes.
- Skeleton/imported animation wiring and retargeting limits.
- Theme/font/UI composition that exceeds simple node/property creation.
- Particle process materials, 3D trails/weather, and decals.
- Audio buses/effects and positional-audio wiring.

## Acceptance criteria

- [x] Each accepted recipe has typed inputs, target/availability validation, one undo action where the editor supports it, and a deterministic fixture.
- [x] Recipes preserve existing user animations/resources and explain when an operation cannot be represented safely.
- [x] Unsupported combinations fail before mutation with a useful specialized explanation; no generic-script improvisation is presented as native support.
- [x] Complex workflows record intermediates, validation, and any unverified quality (topology, PBR, looping, navigation bake).
- [x] Catalog tasks move from `specialized_missing` to supported only with a passing test reference.
- [x] At least one live/device check per recipe family where a model or asset generator is involved.

## Concrete scenarios

Use the remaining specialized catalog tasks and WS-08/WS-10 where asset generation is involved. Follow [TESTING.md](../TESTING.md).

## Evidence and handoff

Accepted for the first family. Added `add_particles_2d`, `add_particles_3d`, and `add_mesh_collision`; transaction fixture covers structure/undo/redo and validation. Catalog moved 2D-016, 3D-082, and 3D-065 to supported, remeasuring 28 supported / 60 partial / 12 specialized-missing. Remaining specialized tasks are listed in the acceptance evidence. See [acceptance evidence](../evidence/17-acceptance.md).
