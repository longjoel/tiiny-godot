# Story 17 — acceptance evidence

Story 17 is accepted for the first specialized family. 2D/3D particle effects and imported-mesh collision are implemented and moved in the catalog; the remaining specialized tasks stay explicit gaps.

Executable: `bin/godot.linuxbsd.editor.x86_64`. No build or test remains running.

## Implemented recipes

- `add_particles_2d` — GPUParticles2D + ParticleProcessMaterial with amount, lifetime, gravity, initial velocity, spread, scale, and color; one undo.
- `add_particles_3d` — GPUParticles3D + ParticleProcessMaterial with the same typed controls; one undo.
- `add_mesh_collision` — StaticBody3D + CollisionShape3D with a trimesh `ConcavePolygonShape3D` generated from an existing MeshInstance3D mesh; one undo.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Typed inputs, target/availability validation, one undo | Recipes validate parent/target ownership, names, numeric ranges, mesh presence, and create only new nodes/resources. Each commits one undo action. The transaction fixture verifies 2D/3D particles and mesh collision, plus undo/redo. |
| Preserve existing animations/resources | New particles/materials and collision bodies are owned additions; no existing animation or shared resource is mutated. Object references are transaction-created. |
| Unsupported combinations fail before mutation | Missing/owned-parent/name conflicts, invalid ranges, non-MeshInstance3D targets, and meshes without a trimesh shape return typed errors before mutation. |
| Complex workflows record validation/quality | Particle creation is structural; no particle appearance/quality claim. Trimesh collision is generated from the actual mesh and reported; no topology optimization claim. |
| Catalog tasks move only with a passing test | `2D-016` (GPUParticles2D), `3D-082` (3D particles), and `3D-065` (imported-mesh collision) moved from specialized-missing to native/supported with the transaction fixture as their test. |
| Live/device checks where model/generator involved | These recipes do not call a model or generator; deterministic editor coverage is used. |

## Catalog remeasure

- Supported: **28** (was 25)
- Partial: 60
- Specialized-missing: **12** (was 15)
- Solution classes: native_macro 18, composed_primitives 56, script_behavior 14, specialized_missing 12
- Supported tasks with tests: 28/28

Remaining specialized-missing tasks: TileMapLayer, AnimatedSprite2D, theme/font, music loop, audio bus, GridMap, NavigationRegion3D, AnimationTree state, skeleton animation, 3D trail, 3D weather, PBR/topology validation. These remain story 17 follow-ups or documented limitations.

## Runs

| Check | Result | Report/log |
| --- | --- | --- |
| Transaction/registry fixture | Passed particles 2D/3D, mesh collision, undo/redo, and all prior generic/native tests | `/tmp/transactions-17f.log` |
| Catalog validator | Passed: 100 tasks, 36 tools, 28 supported / 60 partial / 12 missing, 28/28 tested | `/tmp/tiiny-task-coverage-v2.json` |
| Jobs suite | Passed all 31 modes | `/tmp/jobs-17.log` |
| Editor smoke | Passed 11/11 | `/tmp/tiiny-story17-smoke.json` |
| Build | Exit 0, `00:00:34.96` | `/tmp/tiiny-story17-build.log` |

## Remaining boundaries

- Particle appearance (color/trail/shader quality) was not visually reviewed; only structure/properties were tested.
- Trimesh collision is a literal mesh shape; no convex decomposition, simplification, or performance validation.
- 12 specialized tasks remain unimplemented; they are explicitly missing rather than hidden as supported.
- No live model turn was run for particles/mesh collision; no model/generator was involved.
