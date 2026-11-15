# 11 — Animation and physics workflows

Status: Queued

Feature: Animation and physics workflows

Sequence: 11

Stream: `workspace`

Dependencies: 06, 07, 08

## Scope

Extend the native macro library with useful operations such as torch flicker through animation and slippery surfaces through physics materials.

## Acceptance criteria

- [ ] Inspect existing scene structure before choosing nodes/resources to create or reuse.
- [ ] Torch flicker uses a suitable native animation setup without generated GDScript in the supported case.
- [ ] A slippery-surface request assigns a compatible configured physics material to an appropriate target.
- [ ] Existing user animations and shared resources are preserved or explicitly accounted for.
- [ ] Both workflows have validation, visible results, and reliable undo/redo.
- [ ] Unsupported targets produce a useful explanation instead of an improvised script fallback.

## Concrete scenarios

Use WS-03, WS-04, WS-05 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Pending. Record changed files, validation commands and results, editor/device observations, remaining limitations, and the next action. Update [STATUS.md](../STATUS.md) when handing off.
