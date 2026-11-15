# Story 04 implementation plan — model roles, installed inventory, and warm selections

Status: Planning complete. Implementation starts only after story 03's device binding, coding-model protection, and error-state gates pass. This plan changes documentation only.

Parent: [04 — Model roles, installed inventory, and warm selections](../work-items/04-ui-model-settings.md). Visuals: [interactive Models mockup](../mockups/04-model-settings.html), [state diagrams](../mockups/04-model-settings-diagrams.md).

## Execution contract

Extend the existing `ConfigurationPanel` in `editor/tiiny_ai_manager_source.h`; do not introduce a second settings window, a standalone Models/Assistant tab, or another device queue. All device mutation stays behind `check_config` → `apply_config`, using the job manager's device lease. Opening settings, refreshing, and checking remain read-only.

Story 03 owns device binding, protected coding-model switching, download/load verification, and disconnect/auth/capacity error states. Story 04 renders those states, gates controls on them, and never re-implements device policy in the UI.

The screen is a staged configuration: draft → Check Config → Apply. A draft edit invalidates the checked plan. Apply revalidates the device and refuses a stale or changed plan. The coding model is always kept loaded and is never unloaded to make another selection fit.

Every state must be renderable from fixtures without a device, and reviewable at both narrow (~600 px) and wide (~1400 px) editor widths.

## Baseline inventory

Already present and working in the current panel:

- Header with connection status, Refresh, snapshot age.
- NPU/SSD current and projected capacity bars.
- One nine-column model grid: Task, Model, Context, Tok/s, SSD size, NPU units, Keep loaded, On device, Info.
- Capability-filtered role pickers for scripting, image, image-to-3D, music, and speech; scripting requires `Tool Use`.
- Coding-model context choices, keep-loaded checkboxes, and an `Other installed` section that avoids duplicating assigned models.
- Collapsed Advanced headroom (NPU reserve, SSD reserve).
- Checked plan with operations, errors, warnings, Details, and Apply; draft edits clear the plan; checks expire after 60 seconds.
- Models/Advanced settings organization and connection/device migration.

Verified by story 01/02 fixtures: offline planner/panel checks, fake Apply contract, headless opening of the real Models section, live read-only refresh and Check Config.

Not yet accepted or missing:

- Displayed layout at target widths, including horizontal overflow, clipped text, and dialogs.
- Stale/unavailable capacity presentation; the age label changes but bars and controls do not.
- Role-unavailable explanations; incompatible models simply disappear from pickers.
- In-panel download progress and partial-failure results; both currently exist only in Output/status text.
- Copyable model Info and plan Details dialogs.
- A deterministic incompatible-catalog fixture for DEV-03.
- Real mutating download/load/unload Apply (gated by story 03).

## Slice A — fixtures and UI state harness

Build the review and regression base before polishing the panel.

### Implementation

1. Extend `fake_model_manager.gd` and the planner fixtures with catalog variants: full catalog; image-only catalog (no compatible scripting model); missing size/NPU fields; empty catalog; stale snapshot; disconnected device; auth failure; capacity failure; download stall; partial Apply failure.
2. Add a small read-only manager surface for the panel instead of parsing messages: current operation (`verb`, `id`), operation log tail, elapsed, per-model download percentage, last refresh time, connection state, and error type.
3. Add a panel-state accessor for tests (headings, row states, plan operations, disabled controls, status text) so a headless fixture can assert rendered semantics without screen scraping.
4. Extend `check_model_configuration.py` with a displayed capture mode at 600×900 and 1400×900 for the fixture states, plus a narrow-width horizontal-scroll check.

### Gate

- Every catalog variant produces a deterministic panel state with no device access.
- The headless panel state accessor reports the same roles, states, and plan actions as the fixture.
- Displayed captures exist for fresh, stale, incompatible, applying, and failed states at both widths.

### Deliverables

- Expanded fake manager/catalog fixtures.
- Manager operation-state accessor and panel-state accessor.
- Displayed capture runner and baseline images.

## Slice B — capacity and freshness

### Implementation

1. Show current and projected NPU/SSD as two clearly labeled groups. Current: used/free/total. Projected: after Apply, including reserve and staging allowance. Keep model allocation units distinct from physical RAM in labels and tooltips.
2. Render three freshness states: fresh (`Updated 12s ago`), stale (`Stale · 78s old`), and unavailable (`Device unavailable`). Stale/unavailable dims the bars, shows the last known values as historical, and disables Check Config and Apply until Refresh succeeds.
3. Show the refresh timestamp and a stale countdown. Do not auto-refresh silently while the user is editing; auto-refresh only on first open, as today, and let Refresh preserve the draft.
4. Keep Advanced headroom collapsed by default; show reserve values in the projected line and in plan Details, not as permanent controls.
5. Unknown capacity renders as `—`, never as zero.

### Gate

- Stale and unavailable fixtures never show a live/ready capacity or an enabled Apply.
- Refresh restores fresh state without changing the draft.
- Projected values match the planner's forecast fields for every fixture.

### Deliverables

- Freshness badge/timestamp, stale styling, and control gating.
- Updated capacity labels/tooltips and unknown-value handling.

## Slice C — role capabilities and availability

### Implementation

1. For each role, show a capability hint (`Text Generation · Tool Use`, `Text-to-Image`, `Image-to-3D`, `Music Generation`, `Text-to-Speech`) and the reason a picker is empty: no catalog models, no models of the required type, or no scripting model with `Tool Use`.
2. Keep picker candidates filtered by `Planner.suitable`; add an explicit disabled `No compatible model` entry and a short explanation under the row. Do not offer a model that would fail Check Config.
3. Show installed vs download state in picker items and row state chips. Explain that selecting a downloadable model and Apply performs the download.
4. Keep the context control scripting-only. State in the row tooltip and plan warnings that it is a client-side chat request budget and does not reconfigure Tiiny runtime allocation.
5. Add the DEV-03 fixture: an image-only catalog produces a clear "Choose a scripting model with Tool Use" state, no device mutation, and no false readiness. Do not add a sound-effects role.

### Gate

- Incompatible and unavailable roles are explained, not silently empty.
- DEV-03 passes with an image-only catalog and with an image model selected as scripting.
- No role claims support that the catalog does not declare.

### Deliverables

- Role hints and empty-state explanations.
- Picker/row state labels and tooltips.
- DEV-03 fixture coverage.

## Slice D — one-table inventory and warm state

### Implementation

1. Keep one table. Assigned roles appear once; unassigned installed models appear only as `Other installed` rows. Never repeat a model in a second inventory table.
2. Use a consistent state vocabulary: `Loaded`, `Downloaded`, `Not downloaded`, `Unavailable`, plus a `Keep loaded` checkbox that reflects desired state, not observed state. The scripting row is checked and disabled.
3. Persist applied warm selections and context through `_tiiny_ai/applied_configuration`. Unapplied draft edits remain session-only; show an `Unapplied changes` marker so restart behavior is not surprising.
4. Make Info open a resizable, copyable dialog with the model ID, type, capabilities, maximum context, size, NPU units, installed/loaded state, and description. Use the same dialog pattern as the Jobs details window.
5. Ensure long names and descriptions truncate with a tooltip and never crush columns.

### Gate

- No duplicated model rows in any fixture.
- Loaded, downloaded, and desired-warm states are visually distinct and testable.
- Applied selections survive restart; an unapplied draft is visibly marked and not presented as saved.

### Deliverables

- State chips/legend and `Unapplied changes` marker.
- Copyable Info dialog.
- Persistence checks for applied and draft state.

## Slice E — plan, download progress, and partial failure

### Implementation

1. Keep Check Config as the only planning step and Apply as the only mutation step. A downloadable selection produces an explicit `Download` action in the plan; label it as a download in the plan list and row state.
2. Show the plan with ordered actions, errors, warnings, expiry countdown, protected coding-model switch explanation, and a Details dialog. Disable Apply when the plan is missing, expired, changed, disconnected, or stale.
3. While applying, show the current operation, a per-model progress bar/percentage, elapsed time, and a bounded log tail in the panel. Keep full output in Output. Progress never marks completion; completion requires the manager's device-state verification.
4. On failure, keep the panel open and show partial results: completed operations, the failed operation, and a Refresh/Check again action. Do not save unverified preferences. Do not retry automatically.
5. Keep the stall warning visible for downloads, and distinguish `interrupted` from `failed` when the device state is unknown.

### Gate

- Selecting a not-downloaded model → Check → Apply shows download progress and completes only after the device reports it installed.
- A simulated download/load failure stops the plan, lists completed and failed operations, and leaves preferences unchanged.
- Expired/changed/stale plans cannot be applied.
- Protected coding-model switch errors explain why no unload will occur.

### Deliverables

- Plan/download labeling and progress panel.
- Partial-failure panel and recovery actions.
- Apply-state gating tests.

## Slice F — settings organization, dialogs, and polish

### Implementation

1. Keep Models and Advanced as sections of Tiiny AI. Advanced contains connection, device, prompt, and request settings. Do not add standalone Assistant/Models settings tabs.
2. Verify migration of legacy connection/device values without overriding newer Advanced values; keep obsolete keys removed.
3. Standardize dialogs: resizable, selectable/copyable text, keyboard focus, Close button, and clamped sizing.
4. Check narrow layout: table horizontal scroll, plan buttons reachable, headroom/plan details usable, no clipped controls.
5. Add short, plain-language status copy for disconnected, auth-failed, capacity-failed, stale, and partial states. Avoid implementation jargon.

### Gate

- Displayed review at 600 and 1400 px passes for fresh, stale, incompatible, applying, failed, and plan-details states.
- Models/Advanced organization and migration match story 01 acceptance.
- All dialogs allow copy and resize.

### Deliverables

- Dialog and layout polish.
- Displayed review captures and checklist.

## Slice G — acceptance and device gates

### Implementation

1. Run the full offline suite: planner/panel fixtures, fake Apply contract, panel-state accessor, displayed captures, and DEV-03.
2. Run the story 03 device suite first; story 04 acceptance cannot precede binding, protection, and error-state verification.
3. Run a gated real-device Apply on an explicitly selected Tiiny: record the initial warm set, perform one download or load that the user approves, verify progress and completion from device state, then restore the original warm set and report success or failure.
4. Run DEV-02 fault injection (disconnect/auth/capacity) and record recoverable UI states without false readiness.
5. Record evidence per criterion, including skipped hardware checks as skipped rather than passing.

### Gate

- Every work-item criterion maps to a recorded check.
- Real mutating Apply and restoration are either verified or explicitly deferred with the reason.
- No credentials, prompts, or private project data are stored in reports.

### Deliverables

- Acceptance matrix with evidence links.
- Updated work item, STATUS, and test README.

## Acceptance mapping

| Criterion | Slice | Evidence |
| --- | --- | --- |
| Roles filtered by verified capabilities; unavailable roles explained | C | DEV-03 fixture, panel-state accessor, displayed capture |
| Installed/downloaded and loaded states distinct; warm persists; coding required | D | State fixtures, restart persistence check |
| NPU/SSD capacity includes refresh time and stale/unavailable states | B | Fresh/stale/unavailable fixtures, displayed captures |
| Initiate selected model download; see progress/completion/failure | E | Fake download fixture, gated real-device Apply |
| Apply/refresh explicit; no separate settings tabs | F | Displayed settings review, migration check |
| Real Tiiny with incompatible catalog; no unsupported sound effects | C, G | Gated catalog fixture/device run, review note |
| Current/projected NPU and SSD headroom; no RAM/throughput invention | B | Planner forecast comparison, label review |
| Draft edits invalidate plan; Apply requires fresh passing check | E | Invalidation/expiry fixtures |
| Forecast downloads, staging, reserves, protected replacement; no auto-delete | B, E | Plan Details fixtures, story 03 protected-switch check |
| Context has explicit meaning and is enforced by chat | C | Context tooltip/plan warning, chat budget test |
| Failed operation stops plan, exposes partial results, saves nothing | E | Partial-failure fixture, preferences check |
| One table; Info per row; headroom collapsed; details/warnings in plan | D, E | Panel-state accessor, displayed capture |
| Output has device percentages/elapsed, deduplicated, sanitized, not completion | E | Progress fixture, operation log test |
| Models/Advanced organization and migration | F | Displayed settings check, migration fixture |

## Open questions and recommended decisions

1. **Download initiation.** Recommend Apply-only mutation, with an explicit `Download` step in the plan and progress in the panel. A row-level `Download` shortcut may stage the selection and scroll to Check Config, but it must not mutate the device directly. This keeps one reviewed plan and one device lease.
2. **Draft persistence.** Recommend applied selections persist and unapplied drafts remain session-only with an `Unapplied changes` marker. Persisting an unchecked draft across restart risks applying a stale intent.
3. **Stale threshold.** Keep the existing 60-second snapshot lifetime. Show a countdown and stale banner; do not auto-refresh while editing. Chat continues to auto-revalidate on demand.
4. **Refresh time.** Interpret "include refresh time" as the snapshot age/timestamp and the last successful refresh, not a background polling interval.
5. **Progress data.** Add `operation_state()` on the manager rather than parsing `message` or `operation_log` in the panel. Key per-model progress by model ID while retaining the existing source-based log.
6. **Info/Details dialogs.** Reuse the Jobs details dialog pattern: native, resizable, read-only text that supports selection and copy.
7. **Sound effects.** No role and no claim. Treat as out of scope until a verified capability exists.

## Dependencies and risks

- **Story 03 gate:** binding, protected switching, download/load verification, and error states must pass before story 04 acceptance. UI slices can be built against fixtures earlier, but cannot be accepted.
- **Catalog cache gap:** `_verify_coding_model_stability` reads `_tiiny_ai/catalog_cache`, but nothing currently writes it. Story 03 should populate it or the status will always report "not in the current catalog". Confirm during 03 handoff.
- **Device variability:** real catalogs may omit sizes, NPU units, or capabilities. Every unknown value must render as unknown, not zero.
- **Capacity semantics:** NPU units are allocation units, not RAM; SSD forecasts include one staging allowance. Keep the wording consistent with the planner.
- **UI width:** the table is wide; horizontal scroll and clipped text must be reviewed at 600 px.
- **Mutation safety:** no automatic unload, no automatic retry, no preference save without device verification.

## Handoff

Planning only. No build or device operation was performed. Implementation starts after story 03's gates. Record changed files, checks, displayed captures, device runs, and remaining limitations in the work item and STATUS.
