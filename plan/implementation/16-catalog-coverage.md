# Story 16 implementation plan — catalog-driven composition and coverage tests

Status: Queued. Depends on stories 13–15.

Parent: [16 — Catalog-driven composition and coverage tests](../work-items/16-catalog-coverage.md).

## Catalog v2

Add `solution` to each task:

- `native_macro` — dedicated recipe is the primary path.
- `composed_primitives` — story 14 transaction composes the result.
- `script_behavior` — story 15 script path is the correct solution.
- `specialized_missing` — requires story 17 or a documented limitation.

Each supported task also has `test` and expected tools. `partial` becomes a temporary state only when a real fallback exists; otherwise classify as specialized/missing.

## Validator

Extend `check_task_catalog.py` to:

- Validate 100 unique tasks/prompts and solution classes.
- Check expected tools against the registry/transaction/inspector/debugger definitions.
- Require an existing test reference for every supported/composed/script task.
- Report coverage by dimension and solution class.
- Fail if a behavior task is marked missing native when the script path exists.
- Emit `/tmp/tiiny-task-coverage.json`.

## Test matrix

- One deterministic fixture group per primitive family: create, set property, resource, assign, structure, instantiate, signal.
- Representative composed tasks: Camera2D, Label HUD, OmniLight3D, PBR crate, collision layers, one-way platform, standalone player.
- Script-behavior tasks: spin, bounce, jump, camera follow, door, input.
- Existing macro tests: collision, torch, slippery, sprite, 3D/audio import.
- Every supported/composed/script task maps to a passing test; specialized tasks map to story 17/IDEAS.

## Live batch

Run at least 10 representative prompts across categories, with real Ornith/device traces. Record:

- Model/tool success separately from native coverage.
- Failed tool selection, invalid calls, and retries.
- Context/tool-count effects.
- Artifacts/screenshots where applicable.

Do not treat a single success as a rate.

## Gates

- Catalog v2 is internally consistent and validated.
- Supported/composed/script tasks have actual tests, not just tool names.
- Remaining `specialized_missing` entries are truly specialized.
- Live results are recorded honestly, including failures.
