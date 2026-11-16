# Story 11 — acceptance evidence

Story 11 is accepted. Two native workflows are now editor-owned transaction recipes: `add_torch_flicker` builds a looping light-energy AnimationPlayer/Animation, and `assign_slippery_surface` assigns an owned low-friction PhysicsMaterial. Both inspect the scene, validate targets/types, commit one undo action, and never generate GDScript.

Executable: `bin/godot.linuxbsd.editor.x86_64`, built from the story 11 working tree; reported version `4.8.beta.custom_build.261805ad8` because the build preceded this commit. No build or test remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Inspect existing structure before choosing nodes/resources | `add_torch_flicker` resolves an explicit light path or searches an owned light under the requested parent; it reuses no existing AnimationPlayer, instead creating a uniquely named one so existing animations stay intact. `assign_slippery_surface` resolves a CollisionObject2D or a CollisionShape2D's parent body and reports an existing material. The transaction fixture seeds an existing AnimationPlayer/library and verifies it survives. |
| Torch flicker uses a native setup without generated GDScript | The recipe creates a value track for `Light2D.energy` or `Light3D.light_energy`, inserts deterministic sine-based keys, stores it in an `AnimationLibrary` (`tiiny/flicker`), adds the library to a new AnimationPlayer, and sets `autoplay` to `tiiny/flicker`. The fixture verifies the track path, key count, library/animation, and autoplay. No `.gd` file is created. |
| Slippery surface assigns a compatible configured physics material | `assign_slippery_surface` creates an owned `PhysicsMaterial` with finite 0–1 friction/bounce and assigns it through the typed `physics_material_override` property. The fixture verifies the material values and one-action undo/redo. |
| Existing animations/shared resources preserved or explicitly accounted for | The fixture's pre-existing `Torch/Existing` AnimationPlayer and `user/idle` library remain after the torch recipe. For an existing shared PhysicsMaterial, the recipe assigns a new owned material, leaves the old resource's friction unchanged, reports “previous PhysicsMaterial” in the summary, and Undo restores the previous reference. |
| Validation, visible results, reliable undo/redo | Invalid paths, unowned nodes, missing lights, non-physics targets, bad energy ranges, and out-of-range friction/bounce return typed errors with no mutation. Both recipes commit exactly one undo action; the fixture verifies undo and redo for the AnimationPlayer/library, the new material, and the shared-material reference. |
| Unsupported targets explain instead of improvising a script | A parent without a light returns `target_missing` and creates no AnimationPlayer; a non-physics target returns `invalid_target`. Both messages state that no script fallback was created. |

## Executor extension

To attach an AnimationLibrary without exposing arbitrary calls to the model, the transaction executor gained:

- `create_resource_value`: a recipe-owned prebuilt Resource literal, kept alive with `add_do_reference`.
- `call_method`: bounded do/undo/verify method calls on a resolved target, used here for `add_animation_library`/`remove_animation_library`/`has_animation_library`. Operations come only from trusted recipes, never raw model input.
- Approximate float/Vector/Color comparison for postconditions, because Godot stores `PhysicsMaterial.friction` as a 32-bit real.

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Transaction/registry/chat/action-card fixture | Passed torch track/library/autoplay, preserved existing animation, undo/redo, missing-light rejection, slippery values, shared-material preservation, undo/redo, non-physics rejection, and registry payload | `/tmp/transactions-11e.log` |
| Editor smoke + restart stages | Passed 11/11 stages | `/tmp/tiiny-story11-smoke.json` |
| Jobs suite | Passed all 31 modes | `/tmp/jobs-11.log` |
| Build | Exit 0, `00:00:34.59`, same binary path | `/tmp/tiiny-story11-build3.log` |

## Remaining boundaries

- Torch flicker supports `Light2D` and `Light3D` energy only. It does not add textures, particles, shadows, or shaders.
- The recipe creates a new AnimationPlayer rather than merging into an existing one; preserving existing animations is deliberate.
- Slippery surfaces target 2D physics bodies. 3D `PhysicsMaterial` assignment, tilemaps, and per-shape materials are not covered.
- Visual playback was checked structurally in the editor fixture, not with a displayed frame capture or audio/physics simulation.
