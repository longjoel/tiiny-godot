# 16 — Catalog-driven composition and coverage tests

Status: Accepted. Catalog v2 classifies all 100 tasks by solution class with 25 supported / 60 partial / 15 specialized-missing; every supported task has a test reference and a 10+ prompt live sample is recorded. See [acceptance evidence](../evidence/16-acceptance.md).

Feature: Task catalog v2, composed-task tests, and live coverage

Sequence: 16

Stream: `integration`

Dependencies: 13, 14, 15

Implementation: [plan](../implementation/16-catalog-coverage.md).

## Scope

Reclassify the 100-task catalog by the actual solution path instead of “has a dedicated macro.” Build a test matrix for native macros, composed primitives, script behavior, and genuinely specialized work.

## Acceptance criteria

- [x] Catalog v2 classifies all 100 tasks as `native_macro`, `composed_primitives`, `script_behavior`, or `specialized_missing`, with expected tools and a test reference where supported.
- [x] The validator checks class/tool/test consistency and reports coverage by solution class and dimension.
- [x] Deterministic tests cover every composed primitive family and representative tasks across the catalog, including rollback and undo/redo.
- [x] Script-behavior tasks are tested through read/create/attach/save where they belong, not counted as missing editor features.
- [x] A bounded live batch (at least 10 representative prompts) records model success separately from tool coverage, including failures and traces.
- [x] The coverage report identifies only true specialized gaps and links them to story 17 or IDEAS.md.
- [x] No task is marked supported solely because a tool name exists; each supported task has a passing test reference.

## Concrete scenarios

Use WS-16/WS-17 plus existing WS-01, WS-06, WS-10, WS-11 scenarios. Follow [TESTING.md](../TESTING.md).

## Evidence and handoff

Accepted. Catalog v2 is in `plan/task-catalog.json` and `plan/TASK_CATALOG.md`; validator report `/tmp/tiiny-task-coverage-v2.json`; deterministic matrix reuses the transaction/registry, native recipe, debugger, and Jobs fixtures; live batch includes velocity, spin, generated sprite, Camera2D/Label, PBR, torch, slippery, collision, TTS, and image-to-3D. See [acceptance evidence](../evidence/16-acceptance.md).
