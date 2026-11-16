# Story 11 implementation plan — animation and physics workflows

Status: Accepted. Native torch-flicker and slippery-surface recipes plus their transaction ops are implemented and tested.

Parent: [11 — Animation and physics workflows](../work-items/11-workspace-macros.md).

## Execution contract

Both workflows are editor-owned recipes in the story 06 transaction executor. They inspect the edited scene before choosing a target, produce typed operations, validate properties against Godot types, and commit exactly one undo action. If no native target exists, they return a useful error; they never fall back to generated GDScript.

## Torch flicker

Recipe: `add_torch_flicker(parent_path?, light_path?, player_name?, duration?, min_energy?, max_energy?, steps?)`.

Inspection and validation:

- Resolve `light_path` when given; otherwise resolve `parent_path` and use it when it is a light, or find the first scene-owned `Light2D`/`Light3D` descendant.
- Require a light owned by the edited scene and an owned parent for the AnimationPlayer.
- Reject unknown paths, non-light targets, unowned instances, and a missing light with `target_missing`.
- Pick a unique AnimationPlayer name (`AnimationPlayer`, `AnimationPlayer2`, …) so existing players and animations are preserved.
- Validate duration (0–60 s), `0 <= min_energy < max_energy <= 100`, and 2–64 steps.

Construction:

- Create an `Animation` value track for `Light2D.energy` or `Light3D.light_energy`, relative to the AnimationPlayer root.
- Insert deterministic sine-based keys over the duration; loop linearly.
- Put the animation in an `AnimationLibrary` named `tiiny` under `flicker`, add the library to a new `AnimationPlayer`, set `autoplay` to `tiiny/flicker`.
- Commit one undo action. Undo removes the library/player; redo restores them. Existing AnimationPlayers and libraries are untouched.

The executor gains a recipe-owned resource-literal op (`create_resource_value`) and a bounded method-call op with do/undo/verify hooks. These let recipes attach a prebuilt AnimationLibrary without arbitrary model-supplied calls.

## Slippery surface

Recipe: `assign_slippery_surface(target_path, friction?, bounce?, rough?, absorbent?)`.

- Resolve a `CollisionObject2D` directly, or the parent body of a `CollisionShape2D`.
- Reject non-physics targets, unowned instances, and out-of-range values.
- Create an owned `PhysicsMaterial` with the requested friction/bounce/rough/absorbent values and assign it to `physics_material_override`.
- If a previous material reference exists, leave that resource unchanged, mention the replacement in the summary, and restore the reference on undo.
- Commit one undo action; redo reassigns the new material.

## Tests

Editor fixture additions:

- Torch: existing AnimationPlayer/library is preserved; new player autoplays `tiiny/flicker`; track path and key count match the light; undo/redo remove and restore the player; a target without a light is rejected without a script.
- Slippery: material values match; undo restores the previous (null or shared) reference; redo reassigns; an existing shared material is not modified and is reported; a non-physics target is rejected.
- Registry payload advertises both recipes.

## Gates

- Native animation only in the supported case; no generated GDScript.
- Existing user animations/resources are preserved or explicitly reported.
- Both workflows have one-action undo/redo and typed validation.
- Unsupported targets explain why and mutate nothing.

All gates verified; see [acceptance evidence](../evidence/11-acceptance.md).

## Handoff

Accepted. Boundaries: Light2D/Light3D energy only; new AnimationPlayer rather than merging; 2D physics bodies only; structural rather than displayed playback verification.
