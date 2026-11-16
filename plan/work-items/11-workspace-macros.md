# 11 — Animation and physics workflows

Status: Accepted. Native `add_torch_flicker` and `assign_slippery_surface` recipes inspect the scene, validate targets/types, preserve existing animations/shared resources, and commit one undo action without generated GDScript. See [acceptance evidence](../evidence/11-acceptance.md).

Feature: Animation and physics workflows

Sequence: 11

Stream: `workspace`

Dependencies: 06, 07, 08

Implementation: [plan](../implementation/11-workspace-macros.md).

## Scope

Extend the native macro library with useful operations such as torch flicker through animation and slippery surfaces through physics materials.

## Acceptance criteria

- [x] Inspect existing scene structure before choosing nodes/resources to create or reuse.
- [x] Torch flicker uses a suitable native animation setup without generated GDScript in the supported case.
- [x] A slippery-surface request assigns a compatible configured physics material to an appropriate target.
- [x] Existing user animations and shared resources are preserved or explicitly accounted for.
- [x] Both workflows have validation, visible results, and reliable undo/redo.
- [x] Unsupported targets produce a useful explanation instead of an improvised script fallback.

## Concrete scenarios

Use WS-03, WS-04, WS-05 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Accepted. Implementation: `add_torch_flicker` and `assign_slippery_surface` in `editor/tiiny/tools/transactions.gd`, plus the recipe-owned resource-literal and bounded method-call transaction ops. Deterministic evidence: transaction fixture checks preserved animations, track/key/library/autoplay, slippery values, shared-material preservation, undo/redo, missing-light/non-physics rejection, and registry payload; 11-stage editor smoke and all 31 Jobs modes pass. Boundaries: Light2D/Light3D energy only; new AnimationPlayer rather than merging; 2D physics bodies only; structural playback rather than a displayed frame capture. See [acceptance evidence](../evidence/11-acceptance.md).
