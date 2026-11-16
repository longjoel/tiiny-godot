# 17 — Specialized authoring recipes

Status: Queued

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

- [ ] Each accepted recipe has typed inputs, target/availability validation, one undo action where the editor supports it, and a deterministic fixture.
- [ ] Recipes preserve existing user animations/resources and explain when an operation cannot be represented safely.
- [ ] Unsupported combinations fail before mutation with a useful specialized explanation; no generic-script improvisation is presented as native support.
- [ ] Complex workflows record intermediates, validation, and any unverified quality (topology, PBR, looping, navigation bake).
- [ ] Catalog tasks move from `specialized_missing` to supported only with a passing test reference.
- [ ] At least one live/device check per recipe family where a model or asset generator is involved.

## Concrete scenarios

Use the remaining specialized catalog tasks and WS-08/WS-10 where asset generation is involved. Follow [TESTING.md](../TESTING.md).

## Evidence and handoff

Pending. Record recipe APIs, tests, preserved-resource behavior, unsupported cases, and remeasured catalog coverage. Update [STATUS.md](../STATUS.md).
