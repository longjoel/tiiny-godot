# Work in progress

Active item by explicit user redirection: **04 — Models configuration screen**. Story 01 remains unfinished; do not mark its broader runtime/device acceptance complete.

Status: implementation exists, but end-to-end validation is incomplete. No work item is accepted as complete yet. Existing chat, settings, model manager, resource dialog, and tool-loop experiments must be verified before adding more features.

Last known build: incremental SCons session `23308` completed successfully, exit code 0, linked `bin/godot.linuxbsd.editor.x86_64`. Command: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`; duration `00:00:30.90`. No build remains running from this task.

Next action: review the simplified Models screen visually and verify percentage updates during a deliberate real model download. The headless settings smoke, pure planner/panel suite, fake Apply contract, context expiry/budget checks, and local CLI-runner progress stub pass. A prior read-only live refresh and Check Config passed against the Tiiny; real mutating Apply remains unverified. Story 01's broader stabilization acceptance remains unfinished.

Known gaps: typed scene tools and undo/redo are not implemented; full model scheduling and reconnect recovery are not implemented; latest tool-loop changes have not been validated end to end. See the integration README and design draft for prototype behavior.

## Evidence log

- Build review: session `45249` finished successfully; recorded during story 01 planning. No script or runtime checks were executed by that review.
- Plan created: repository contains prototype changes and a workspace-assistant design draft; acceptance remains pending.

Planning update: acceptance examples and a layered automation strategy are now documented in `ACCEPTANCE_SCENARIOS.md` and `TESTING.md`. Deeper integration ideas are parked in `IDEAS.md`. Item 01 remains the active work item; no tests or builds were started by this documentation update.

## Handoff rules

Update this file when starting, finishing, or redirecting work. Include changed files, checks and results, relevant process/session identifiers, blockers, and the next concrete action. Do not store API keys or credentials here.

Priority update: item 02 (persistent job manager) is the first foundational feature after item 01 stabilization. The remaining sequence was renumbered to 03–13. Queued Tiiny inference and internal asset generators share this manager. No implementation item has been completed by this planning update.

Story 02 planning update: five implementation slices, a Jobs bottom-panel mockup, and architecture/state/recovery diagrams are drafted. Story 01 remains active. No job-manager implementation, editor build, or Tiiny mutation was performed by this planning task.

Story 02 simplification: user selected an append-only, one-job-at-a-time FIFO queue. Example: create tree, then attach its explicit artifact to a scene. Failure stops later dispatch; scripts may append only at the tail. Graph scheduling, priorities and parallel lanes are removed from the initial scope. Story 01 remains active.

User-directed priority change: improve story 04 Models settings now, using a staged configuration planner and explicit Apply. Story 01 stabilization remains unfinished; this UI work is an explicit user redirection, not completion of earlier gates. No device mutation is authorized implicitly by opening settings or checking a plan.

Models UI evidence: pure planner tests cover allocation/SSD headroom, incompatible roles, duplicates, unknown metadata, context limits, protected coding replacement, and unload ordering. Headless panel/editor smoke and fake Apply tests cover stale checks and false-positive command success. Live read-only inventory and Check Config passed with no device mutation. Incremental `-j8` editor builds succeeded; final build status is reported in the conversation. Real mutating Apply and displayed visual review remain unverified.

Final UI implementation checks: session 90078 build passed; `python3 integrations/tiiny/tests/check_model_configuration.py --editor-smoke` passed against that binary. Known unrelated headless startup diagnostics are documented in `integrations/tiiny/tests/README.md`; no GDScript errors occurred. No real models were loaded, unloaded, downloaded, or deleted by this task.

Models layout correction: user screenshot exposed letter-by-letter wrapping and oversized rows. The task table now uses non-wrapping minimum-width cells, compact vertical alignment, and horizontal overflow; capacity meters are side by side. Layout regression checks pass at 600 and 1400 pixels. Build session 89946 passed and linked the editor in 38.84 seconds. The final parser/planner/panel geometry suite and real-settings headless smoke test passed. No build remains running; displayed visual review remains separate from measured geometry checks.

Models simplification: removed About selection and the duplicate installed inventory; unassigned installed models now share the task table and model descriptions open with per-row Info. Advanced headroom starts collapsed; detailed forecasts and caveats are in plan Details. Output receives device-reported download percentages and elapsed time, plus sanitized SDK percentages for other operations. Build 93044 and offline parser/planner/layout/popup/progress tests pass. Final headless editor smoke session 52180 passed with fake Apply, device-progress fixtures, and a local CLI progress stub. Initial smoke timeout was a test assertion calling Array.any on a PackedStringArray; corrected to convert to Array. No GDScript errors remain in the final run; known unrelated headless initialization diagnostics persist. No real device model mutation was performed. Actual download progress and displayed visual quality remain unverified.

Settings consolidation: Connection and Device now live in Tiiny AI > Advanced alongside prompt and request limits; Models remains the primary model screen. Existing saved values migrate once without replacing newer Advanced values. Chat, resource requests, manager connection, CLI invocation, documentation, and fixture settings use the new keys. Migration/offline checks and rebuilt editor smoke (session 75558) pass; build 23308 completed successfully in 30.90 seconds. Known headless startup diagnostics remain as documented; no GDScript errors or real device mutations. No build remains running. Next action remains displayed UI review and deliberate real download-progress verification.
