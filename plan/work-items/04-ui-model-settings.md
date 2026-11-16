# 04 — Model roles, installed inventory, and warm selections

Status: Accepted. Slices A–G are implemented and verified: read-only operation/panel state accessors, freshness gating and stale/unavailable capacity, role-unavailable explanations with DEV-03, one-table state vocabulary, copyable model Info, operation progress, plan-expiry countdown, bounded partial results, displayed 600/1400 px captures, and a three-process applied-vs-unapplied restart fixture. One real Tiiny download-only Apply verified device-reported progress/completion and an unchanged warm set; no model was loaded or unloaded. See [implementation plan](../implementation/04-model-settings.md) and [acceptance evidence](../evidence/04-acceptance.md).

Feature: Model roles, installed inventory, and warm selections

Sequence: 04

Stream: `ui`

Dependencies: 03

Implementation: [plan](../implementation/04-model-settings.md). Visuals: [interactive Models mockup](../mockups/04-model-settings.html), [state diagrams](../mockups/04-model-settings-diagrams.md).

## Scope

Build the Models section under Tiiny AI using the user’s disk-manager analogy: visual capacity at the top, role-aware model table, descriptions, downloaded/loaded states, context budget, and keep-loaded checkboxes. Changes form a draft; Check Config produces a capacity-validated ordered plan; Apply revalidates before executing. No device writes on opening settings or checking.

## Acceptance criteria

- [x] Coding, image, image-to-3D, music, and speech choices are filtered by verified catalog capabilities, with unavailable roles explained.
- [x] Installed/downloaded and loaded states are distinguishable; warm checkboxes persist and the coding model is required.
- [x] NPU and SSD free capacity include refresh time and unavailable/stale states.
- [x] Users can initiate a selected model download and see progress, completion, or actionable failure.
- [x] Apply/refresh behavior is explicit; no separate Assistant or Models settings-window tabs are introduced.
- [x] Test with a real Tiiny and a catalog containing incompatible model types; sound effects are not presented as supported without evidence.

## Additional acceptance criteria from user review

- [x] Show current and projected NPU allocation/SSD headroom above the task table; do not confuse model allocation units with physical RAM or invent benchmark throughput.
- [x] Draft edits invalidate a checked plan. Apply requires a passing unexpired check and a fresh state check; stale/changed operations require a new review.
- [x] Forecast missing downloads, staging allowance, reserves, and protected coding-model replacement; never delete models automatically to make a plan fit.
- [x] Context selection has an explicit supported meaning and is enforced by chat; do not claim it reconfigures Tiiny runtime memory when unsupported.
- [x] A failed operation stops the plan, exposes partial results, and does not report success or save unverified preferences.
- [x] Use one model table: assigned models are not repeated in an installed inventory. Per-row Info opens model details; optional headroom controls start collapsed and forecasts/warnings appear in plan Details.
- [x] Output includes actual device-reported download percentages and elapsed time, with duplicate updates limited; terminal output is sanitized and progress alone never establishes completion.
- [x] Tiiny AI exposes Models and Advanced sections. Advanced combines connection, device, prompt, and request settings; existing saved connection/device values migrate without overriding newer Advanced values.

## Concrete scenarios

Use DEV-02, DEV-03 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Implementation: custom Models inspector panel, structured read-only Tiiny inventory/capacity, pure staged planner, guarded Apply, and context request budgeting. Story 03 is accepted. Slices A–G add `operation_state()`/`panel_state()` accessors, stale/unavailable dimming and Check/Apply gating, unknown-capacity labels, role-unavailable explanations with DEV-03, operation progress, plan-expiry countdown, a bounded partial-result view, and a resizable copyable Info dialog. Verification on build `d7494670c`: planner/panel suite, headless and displayed editor smoke, 24 Jobs modes, cross-process lease, three-process applied-vs-unapplied restart stages, real chat/polygon inference with unchanged residency, and one real download-only Apply (`Supertone/supertonic-3`, 225,936,268 bytes, seven device progress updates, warm set unchanged). Displayed captures at 1400/600 px cover fresh, stale, incompatible, applying, failed, and plan details, with a real-catalog capture; see the [capture table](../evidence/04-acceptance.md#captures). See [acceptance evidence](../evidence/04-acceptance.md) and [story 03 acceptance](../evidence/03-acceptance.md).
