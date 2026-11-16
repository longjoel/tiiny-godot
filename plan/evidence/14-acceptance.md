# Story 14 — acceptance evidence

Story 14 is accepted. The model can compose bounded typed editor transactions for ordinary authoring: nodes, properties, resources, hierarchy, scene instancing, and signal connections, committed as one undo action. Specialized recipes remain available.

Executable: `bin/godot.linuxbsd.editor.x86_64`. No build or test remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Create an allowed node with validated initial properties in one undo action | `apply_editor_transaction` creates Camera2D, Label, OmniLight3D, MeshInstance3D, Button, and other allowed Node classes. `create_node` accepts validated initial properties and auto-adds/owns the node. The fixture verifies Camera2D position/smoothing, Label text, and one undo/redo action. |
| Reject missing/read-only/internal/type-incompatible/out-of-transaction property references before mutation | Generic validation checks class policy, IDs, targets, property metadata, internal usage, `PROPERTY_USAGE_READ_ONLY`, value types, and transaction-local `{"ref": id}` references. The fixture rejects an invalid class, a missing property, a missing resource reference, and a stale revision without changing the scene or history. |
| Remove, reparent, duplicate, instantiate, and connect signals safely | Executor ops implement all five. The fixture duplicates `Player`, reparents `HudLabel` under `MainCamera`, instantiates `res://prop.tscn` under `World`, removes `StartButton`, and connects `pressed` to `hide`; undo restores all structural state. Targets are captured by node identity, so path changes during reparent do not break verification. |
| Compound transaction atomicity | A transaction containing a valid `create_node` followed by an invalid property fails with `property_missing` and leaves no node and no undo entry. Prepared nodes/resources/copies are freed; creation only commits after full validation. |
| Ownership/instanced/stale/dirty/running handling | Scene context, save state, ownership, and revision/session checks follow story 06. Generic availability requires a saved clean scene. Structural ops reject root/unowned targets. The fixture rejects a stale expected revision. |
| Bounded, safe operations and structured results | Input is capped at 16 operations. `call_method`, scripts, files, editor internals, and `PackedScene`/`Script`/`OS`/`Engine` classes are excluded from the model-facing op set. Results include action name, operation count, affected nodes/resources, undo group, and scene revision. |
| Action cards/ledger show one transaction | The transaction returns one structured result and one `undo_group`; the existing action-card/ledger path renders it once. Structural targets are included in `affected`. |
| Deterministic composed examples | Fixture composes Camera2D + Label + OmniLight3D + MeshInstance3D + StandardMaterial3D + Button/signal, plus duplicate/reparent/instantiate/remove. Invalid class/property/reference/stale/cap cases are covered. |
| Live sample | Live Ornith turn created `MainCamera` at (100,200) with smoothing, `ScoreLabel` with `Score: 0` at the top-left, and assigned a StandardMaterial3D (metallic 1.0) to `World/Crate`. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Transaction/registry/action-card fixture | Passed generic create/property/resource/structure/signal/rollback/stale/cap/undo/redo | `/tmp/transactions-14-final2.log` |
| Editor smoke + restart stages | Passed 11/11 on rerun; one known flaky headless native-dialog crash occurred on two earlier attempts | `/tmp/tiiny-story14-smoke3.json` |
| Jobs suite | Passed all 31 modes | `/tmp/jobs-14.log` |
| Debugger fixture | Passed | `/tmp/debugger-14.log` |
| Resource HTTP fixture | Passed | `/tmp/resource-14.log` |
| Live composed authoring | Passed Camera2D, Label, PBR Crate; scene capture `/tmp/tiiny-live-primitives.txt` | `/tmp/primitives-live7.log` |
| Build | Exit 0, `00:00:30.72` final | `/tmp/tiiny-story14-build10.log` |

## Remaining boundaries

- Generic transactions require a saved/clean scene and do not auto-save.
- Dynamic/editor-only properties may not appear in `get_property_list()`; use a specialized recipe or script when a property is not exposed.
- `duplicate_node` rebinds duplicate descendants to the copied root; specialized duplication semantics (signals, exported overrides) are not exhaustively modeled.
- `connect_signal` supports existing methods without binds/flags.
- Complex workflows (TileMap, navigation bake, animation trees, themes, CSG booleans) remain story 17.
- Gameplay behavior remains script work (story 15), not generic editor transactions.
