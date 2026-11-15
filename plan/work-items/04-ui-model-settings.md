# 04 — Model roles, installed inventory, and warm selections

Status: Queued for broader UI/device acceptance; existing prototype UI is included in the accepted story 01 baseline.

Feature: Model roles, installed inventory, and warm selections

Sequence: 04

Stream: `ui`

Dependencies: 03

## Scope

Build the Models section under Tiiny AI using the user’s disk-manager analogy: visual capacity at the top, role-aware model table, descriptions, downloaded/loaded states, context budget, and keep-loaded checkboxes. Changes form a draft; Check Config produces a capacity-validated ordered plan; Apply revalidates before executing. No device writes on opening settings or checking.

## Acceptance criteria

- [ ] Coding, image, image-to-3D, music, and speech choices are filtered by verified catalog capabilities, with unavailable roles explained.
- [ ] Installed/downloaded and loaded states are distinguishable; warm checkboxes persist and the coding model is required.
- [ ] NPU and SSD free capacity include refresh time and unavailable/stale states.
- [ ] Users can initiate a selected model download and see progress, completion, or actionable failure.
- [ ] Apply/refresh behavior is explicit; no separate Assistant or Models settings-window tabs are introduced.
- [ ] Test with a real Tiiny and a catalog containing incompatible model types; sound effects are not presented as supported without evidence.

## Additional acceptance criteria from user review

- [ ] Show current and projected NPU allocation/SSD headroom above the task table; do not confuse model allocation units with physical RAM or invent benchmark throughput.
- [ ] Draft edits invalidate a checked plan. Apply requires a passing unexpired check and a fresh state check; stale/changed operations require a new review.
- [ ] Forecast missing downloads, staging allowance, reserves, and protected coding-model replacement; never delete models automatically to make a plan fit.
- [ ] Context selection has an explicit supported meaning and is enforced by chat; do not claim it reconfigures Tiiny runtime memory when unsupported.
- [ ] A failed operation stops the plan, exposes partial results, and does not report success or save unverified preferences.
- [ ] Use one model table: assigned models are not repeated in an installed inventory. Per-row Info opens model details; optional headroom controls start collapsed and forecasts/warnings appear in plan Details.
- [ ] Output includes actual device-reported download percentages and elapsed time, with duplicate updates limited; terminal output is sanitized and progress alone never establishes completion.
- [ ] Tiiny AI exposes Models and Advanced sections. Advanced combines connection, device, prompt, and request settings; existing saved connection/device values migrate without overriding newer Advanced values.

## Concrete scenarios

Use DEV-02, DEV-03 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Implementation: custom Models inspector panel, structured read-only Tiiny inventory/capacity, pure staged planner, guarded Apply, and context request budgeting. Offline planner/panel and fake-Apply contract checks pass; a headless editor opens the actual custom Models section; live read-only refresh and Check Config pass. The editor links successfully. Displayed layout review and real mutating Apply are not yet accepted. Story 01 remains incomplete. Update [STATUS.md](../STATUS.md) when handing off.
