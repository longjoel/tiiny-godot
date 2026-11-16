# Story 07 — acceptance evidence

Story 07 is accepted on deterministic registry/chat fixtures plus one real-model end-to-end recipe run. The model-facing registry owns tool definitions, availability, schema validation, handlers, structured results, prompt assembly, and ledger entries. One successful live run used Ornith to add a 32×48 rectangular collision shape and the edit was undone.

Executable: `bin/godot.linuxbsd.editor.x86_64`, version `4.8.beta.custom_build.da3b7c67a`. Final build PID 797629 exited 0 in 38.71s with `scons platform=linuxbsd target=editor use_static_cpp=no -j8`. No build remains running.

## Implementation

- `editor/tiiny/tools/registry.gd` composes the story 05 inspector, story 06 transaction provider, and legacy image/script/job tools into one definition table.
- `tools_payload()` sends only available tools. The recipe is omitted while the scene is unsaved/dirty or the model is unavailable.
- Compact schema validation covers object/required/additionalProperties, strings and lengths, enums, numbers/integers, ranges, booleans, arrays, and items.
- `execute()` performs registry/schema checks, delegates to the right provider or handler, normalizes structured errors, echoes `call_id`, and returns `duration_ms`.
- The dock builds the registry lazily, refreshes availability per turn, binds scene identity/revision/root ID, sends structured tool results back with the original call ID, appends a turn ledger entry, and adopts the post-mutation session revision.
- Prompt assembly separates base workspace-first policy, capability summary, user preferences, and data-labeled editor context. The script fallback schema requires a non-empty reason and the summary shows it.
- Limits are one call per response, six rounds, eight calls, and bounded results. Protocol violations stop the turn; completed ledger entries are retained.
- The registry and provider scripts are injected into the dock as separate embedded sources and are not instantiated at startup; story 08 owns richer chat action UI.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Workspace-first prompt and GDScript fallback | Registry prompt fixture asserts `workspace-first`, Tools, user-preference, and editor-context sections. Schema requires a script fallback reason and the handler summary includes it. |
| Tool schemas and availability | Registry fixture checks schema rejection, unavailable-tool filtering, and payload content. Live run printed the advertised tool list including `add_rectangular_collision_shape`. |
| Malformed/unknown/duplicate/multiple/limits | Existing editor chat protocol suite covers malformed envelopes, invalid arguments, unknown tools, repeated IDs, multiple calls, round limits, continuation recovery, and unlocked controls. |
| Structured results and call IDs | Registry/chat fixture checks structured recipe result, `call_id`, `undo_group`, ledger entry, and tool-message round trip. |
| Real model macro + undo | Live run with `ornith-ai/Ornith-1.5-35B-A3B-Turbo`: advertised the recipe, called it, created `Player/CollisionShape2D` with a 32×48 `RectangleShape2D`, recorded the ledger/undo group, and undid it successfully. |
| Errors/cancellation preserve completed work | Existing chat protocol/Jobs suites cover error recovery, cancellation, completed-effect retention, and subsequent turns. |

## Runs

| Check | Result | Report/log |
| --- | --- | --- |
| Workspace transaction + registry + chat fixture | Passed, including schema, availability, prompt, ledger, fake-HTTP recipe, unknown tool, and undo | `/tmp/transactions-final2.log` |
| Existing editor smoke + restart stages | Passed, 11/11 stages | `/tmp/tiiny-story07-final2.json` |
| Built-in Jobs regression | Passed, all 25 modes | `/tmp/jobs-final2.log` |
| Workspace inspector regression | Passed | `/tmp/inspector-final07.log` |
| Live workspace recipe | Passed on Ornith; recipe ledger/undo; warm set unchanged | `/tmp/workspace-live-final2.log` |
| Build | Exit 0, 38.71s | `/tmp/tiiny-story07-build8.log` |

Live evaluation note: two earlier attempts did not reach the recipe (one chose `append_job`; one exceeded an intentionally small 8K context budget). A 32K context and an explicit single-recipe instruction produced the successful run. This is one trace, not a statistical success rate.

## Remaining boundaries

- Only one product mutation recipe is exposed; generic mutation, delete/reparent, script attachment, animation, debugger, and composition tools remain later stories.
- The live evaluation is a single successful trace; broader paraphrases and failure rates remain future evaluation work.
- Displayed success/failure/cancellation chat review is not part of this deterministic run; story 08 owns richer action history, previews, and recovery UI.
- Live image generation remains unverified.
