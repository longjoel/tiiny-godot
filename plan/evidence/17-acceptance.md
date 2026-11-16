# Story 17 — acceptance evidence

Story 17 is accepted. All 12 remaining specialized catalog tasks now have native recipes/tools with deterministic tests, and the catalog has **zero specialized-missing tasks**.

Executable: `bin/godot.linuxbsd.editor.x86_64`. No build or test remains running.

## Implemented specialized families

- 2D: `add_tilemap_layer`, `add_animated_sprite`, `apply_theme`, `configure_audio_loop`, `configure_audio_bus`, `add_particles_2d`.
- 3D: `add_gridmap`, `add_navigation_region`, `add_animation_tree`, `play_animation`, `add_trail_3d`, `add_particles_3d`, `add_weather_3d`, `add_mesh_collision`.
- Validation: `validate_mesh_quality` reports surfaces, vertex/index counts, materials, PBR-map presence, bounds, and explicit `quality: unverified`.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Typed inputs, target/availability validation, one undo where supported | Recipes validate parent/target ownership, names, ranges, texture/mesh/script/resource inputs, and commit one scene undo action. Audio bus configuration is global runtime state and is explicitly not scene-undoable. |
| Preserve existing animations/resources | Theme, loop, and animation recipes create/duplicate owned resources rather than mutating shared ones. AnimationTree/play-animation do not delete existing clips. |
| Unsupported combinations fail before mutation | Missing textures/fonts/audio streams, non-Control theme targets, non-MeshInstance3D targets, non-AnimationPlayer targets, invalid ranges, and name/ownership conflicts return typed errors. |
| Complex workflows record validation/quality | Navigation reports `bake: not_requested`; mesh quality reports metrics with `quality: unverified`; audio loop reports duplicated-stream behavior; skeleton playback requires an existing clip. |
| Catalog tasks move only with a passing test | All 12 remaining specialized IDs moved to native/supported with the transaction fixture as the test. Catalog: **40 supported / 60 partial / 0 specialized-missing**, 40/40 supported tested. |
| Live/device checks where model/generator involved | These recipes do not call a model or generator; deterministic editor coverage is used. Existing live asset/model traces remain separate. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Transaction/registry fixture | Passed TileMap, GridMap, AnimatedSprite, theme, audio loop/bus, navigation, AnimationTree, animation playback, Trail3D, weather, particles, mesh collision, mesh quality, and all prior generic/native tests | `/tmp/transactions-17-final4.log` |
| Catalog validator | Passed: 100 tasks, 48 tools, 40 supported / 60 partial / 0 missing, 40/40 tests | `/tmp/tiiny-task-coverage-final.json` |
| Jobs suite | Passed all 31 modes | `/tmp/jobs-17-all.log` |
| Editor smoke | Passed 11/11 | `/tmp/tiiny-story17-all-smoke.json` |
| Debugger fixture | Passed | `/tmp/debugger-17-all.log` |
| Build | Exit 0, `00:00:35.45` | `/tmp/tiiny-story17c-build.log` |
| Resource HTTP fixture | Passed | `/tmp/resource-17-all.log` |

## Remaining boundaries

- NavigationRegion3D creation configures a NavigationMesh but does not bake; baking remains an unverified follow-up.
- Skeleton animation playback requires an existing imported AnimationPlayer clip; no skeleton creation/retargeting.
- Audio bus configuration is global runtime state and has no scene undo entry.
- Mesh-quality validation reports measurable metrics and explicitly unverified quality; it does not certify topology or PBR correctness.
- Particle/weather/trail appearance was not visually reviewed; structure/properties were tested.
- Audio loop supports streams exposing `loop_mode`/`loop`; unsupported stream types fail clearly.
- 60 catalog tasks remain partial because their composed/script workflows lack focused per-task tests, not because they are missing specialized tools.
