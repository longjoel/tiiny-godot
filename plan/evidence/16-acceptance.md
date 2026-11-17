# Story 16 — acceptance evidence

Story 16 is accepted. The 100-task catalog is now classified by solution path rather than “has a dedicated macro,” and coverage is remeasured against actual tests.

Executable: `bin/godot.linuxbsd.editor.x86_64`. No build or test remains running.

## Catalog v2

- `native_macro`: 15
- `composed_primitives`: 56
- `script_behavior`: 14
- `specialized_missing`: 15

Status at story 16 close: **25 supported / 60 partial / 15 missing**, 25/25 supported tasks with a test reference. Story 17 later completed all specialized families, giving **40 / 60 / 0**.

By dimension:

| Dimension | Supported | Partial | Missing |
|---|---:|---:|---:|
| 2D | 9 | 35 | 6 |
| 3D | 6 | 25 | 9 |
| Project/debug/assets | 10 | 0 | 0 |

The 15 specialized-missing tasks are TileMapLayer, GPUParticles2D, AnimatedSprite2D, theme/font, music loop, audio bus, GridMap, NavigationRegion3D, imported-mesh collision, AnimationTree state, skeleton animation, 3D particles, 3D trail, 3D weather, and PBR/topology validation. These are story 17 candidates or documented limitations, not hidden native gaps.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Catalog v2 classifies all 100 tasks | `plan/task-catalog.json` version 2 adds `solution` to every task; `plan/TASK_CATALOG.md` displays solution/status/tools. |
| Validator checks class/tool/test consistency and reports coverage | `check_task_catalog.py` validates unique IDs/prompts, solution classes, status consistency, tool existence against 33 native tools, and test-file existence for supported tasks. Report: `/tmp/tiiny-task-coverage-v2.json`. |
| Deterministic tests cover composed primitive families and representative tasks | `check_workspace_transactions.py` covers create, set property, resource create/assign, remove, reparent, duplicate, instantiate scene, signal connect, attach script, stale/dirty/rollback/cap, and undo/redo. Native recipe fixtures cover collision, torch, slippery, sprite, GLB/WAV import. |
| Script behavior tested through script tools, not counted as missing | Script tasks use `read_project_file`/`replace_in_gdscript`/`create_gdscript`; live velocity and spin traces edited `bounce_script.gd`, and attachment/save are covered deterministically. |
| Bounded live batch with model success separated from tool coverage | Live traces: velocity, spin, generated soccer sprite, Camera2D+Label, PBR material, torch flicker, slippery platform, 32×48 collision, TTS asset, image-to-3D asset. Logs: `/tmp/chat-spin-final3.log`, `/tmp/chat-soccer-live5.log`, `/tmp/primitives-live7.log`, `/tmp/authoring-batch-live.log`, `/tmp/asset-live3.log`. |
| Coverage report identifies only specialized gaps | Specialized list above; partial composed/script tasks remain explicitly partial with focused tests still to add. |

## Runs

| Check | Result | Report/log |
| --- | --- | --- |
| Catalog validator | Passed: 100 tasks, 33 tools, 25 supported, 25/25 tested | `/tmp/tiiny-task-coverage-v2.json` |
| Transaction/registry fixture | Passed generic + attach/save + prior recipe coverage | `/tmp/transactions-15b.log` |
| Jobs suite | Passed all 31 modes | `/tmp/jobs-15.log` |
| Editor smoke | Passed 11/11 | `/tmp/tiiny-story15-smoke.json` |
| Debugger fixture | Passed | `/tmp/debugger-15.log` |
| Live authoring batch | Torch, slippery, and 32×48 collision passed | `/tmp/authoring-batch-live.log`, `/tmp/tiiny-live-authoring-batch.txt` |
| Live primitives | Camera2D/Label + PBR material passed | `/tmp/primitives-live7.log`, `/tmp/tiiny-live-primitives.txt` |

## Remaining boundaries

- 60 partial tasks are composable or scriptable but lack a focused per-task test/availability refinement.
- 15 specialized tasks require story 17 or an explicit limitation.
- The live batch is representative, not a success-rate study; individual traces are recorded.
- The catalog measures native/composed/script support, not model correctness on every paraphrase.

## Story 19 reconciliation

Story 19 audited every supported task against its actual assertion rather than a test-file reference. The catalog now requires a `test_assertion` present in the referenced test, and the validator enforces it. The audited count is **32 supported / 68 partial / 0 missing**, with 32/32 supported tasks carrying a present assertion. Four tasks were reclassified to partial because their assertions did not cover the prompt: 2D-006 (active camera unproven), 2D-044 (low volume and OGG music not covered), 3D-082 (sparks not attached to an anvil), and 3D-083 (trail not attached to a projectile). The fixture also gained assertions for 2D-008 (HUD position), 2D-016 (particles parented to `Player`), and 3D-051 (1×1×1 `BoxMesh` size). See [story 19 progress](19-review-progress.md).
