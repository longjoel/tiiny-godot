# Story 17 implementation plan — specialized authoring recipes

Status: Accepted. All catalog specialized families have native recipes/tools and deterministic coverage.

Parent: [17 — Specialized authoring recipes](../work-items/17-specialized-authoring.md).

## Selection rule

Implement a specialized recipe only when composed primitives cannot express the workflow safely or when the editor operation needs domain validation/baking (tile data, navigation, animation tracks, skeletons, themes).

## Candidate recipe families

1. **TileMap/TileSet** — create/assign tilesets, paint bounded tile regions, collision layers.
2. **GridMap** — mesh library assignment and bounded cell painting.
3. **Navigation** — NavigationRegion3D creation and explicit bake with completion/error reporting.
4. **CSG** — blockout operations and boolean combinations with validation.
5. **Animation** — AnimationPlayer/AnimationTree tracks, sprite-frame animations, reusable tweens; keep behavior logic in scripts.
6. **Skeleton/imported animation** — validate clip names, playback, and retargeting limits.
7. **Theme/UI composition** — menus/inventory/dialogue structures that exceed simple node/property creation.
8. **Effects** — particle process materials, 3D trails/weather, decals.
9. **Audio routing** — buses/effects/positional AudioStreamPlayer3D wiring.

Each family gets:

- typed inputs and target availability,
- validation before mutation,
- one undo action where supported,
- preservation of existing user resources/animations,
- deterministic fixtures and one live/device check where a generator/model is involved.

## Slices

1. Pick the highest-value specialized tasks from catalog v2.
2. Implement one family at a time with tests and remeasure coverage.
3. Record unsupported combinations and quality flags honestly.
4. Move catalog tasks only after tests pass.

## Gates

- No generic-script improvisation presented as native support.
- Complex workflows validate/bake before claiming completion.
- Unsupported targets fail before mutation with a specialized explanation.

First family verified; see [acceptance evidence](../evidence/17-acceptance.md).

## Handoff

Implemented TileMapLayer, GridMap, AnimatedSprite2D, theme/font, audio loop/bus, NavigationRegion3D, AnimationTree, animation playback, Trail3D, 3D weather, particles 2D/3D, imported-mesh collision, and mesh-quality validation. See acceptance evidence for boundaries (navigation bake, skeleton clip requirement, global audio bus, unverified visual/quality claims).
