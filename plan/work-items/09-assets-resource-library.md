# 09 — Typed resource recipes and image generation

Status: Accepted. Registry recipe metadata, dock/dialog eligibility, imported-image path reporting, artifact linking, and failure-stage checks are implemented and tested. See [acceptance evidence](../evidence/09-acceptance.md).

Feature: Typed resource recipes and image generation

Sequence: 09

Stream: `assets`

Dependencies: 02, 04, 07, 08

Implementation: [plan](../implementation/09-assets-resource-library.md).

## Scope

Use the shared job manager from item 02 for long-running work, dependencies, state, and logs. Extend its worker interfaces rather than introducing another queue.

Define recipes with typed inputs, model roles, intermediate artifacts, validation, import/conversion, and final Godot outputs. Integrate supported recipes with resource creation.

## Acceptance criteria

- [x] The registry distinguishes available recipes from planned ones and exposes their input/output resource types.
- [x] Create New Resource enables the prompt only for supported types; blank prompts keep ordinary creation.
- [x] Image generation validates the response, saves a new asset, imports it, and reports its actual project path.
- [x] Supported resource construction validates properties and assignments against Godot types.
- [x] Failures preserve useful artifacts and identify the failed stage without claiming complete success.
- [x] Test a supported recipe, incompatible resource request, malformed model output, and import failure.

## Concrete scenarios

Use WS-06, WS-07, WS-09 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Accepted. Implementation: recipe metadata/accessors in `editor/tiiny/tools/registry.gd`, dock eligibility in `editor/tiiny_ai_dock_source.h`, and dialog integration in `editor/gui/create_dialog.cpp`. Image generation now waits for a loadable import and reports the project path; chat action cards link the generated texture. Deterministic evidence: transaction/registry fixture, loopback resource HTTP fixture, 11-stage editor smoke including failed-import rejection, and all 27 Jobs modes. Live warm-image-model generation remains unverified. See [acceptance evidence](../evidence/09-acceptance.md).
