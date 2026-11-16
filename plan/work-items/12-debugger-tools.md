# 12 — Paused execution, live scene inspection, and breakpoints

Status: Accepted for the implemented debugger path. Real paused-scene state/stack/locals/runtime-tree inspection, validated breakpoints, and continue/step/pause controls are wired through the registry. Runtime property values remain unavailable without a selected remote node. See [acceptance evidence](../evidence/12-acceptance.md).

Feature: Paused execution, live scene inspection, and breakpoints

Sequence: 12

Stream: `debugger`

Dependencies: 05, 07, 08

Implementation: [plan](../implementation/12-debugger-tools.md).

## Scope

Expose debugger state and controls with explicit session, thread/frame, and pause context.

## Acceptance criteria

- [x] At a real breakpoint, tools inspect the correct session, stack frame, locals, and available live-node state.
- [x] The assistant distinguishes edited-scene data from runtime data and stale snapshots.
- [x] Set/remove breakpoint tools validate script paths and line numbers and keep editor UI synchronized.
- [x] Resume/step controls and any state-changing debug operation are visible in the action history.
- [x] Disconnects, continued execution, unsupported languages, and stale object identifiers are handled safely.
- [x] An end-to-end diagnosis is grounded in observed runtime values; missing data is reported explicitly.

## Concrete scenarios

Use WS-11, WS-12 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Accepted for the implemented path. A C++ `EditorDebuggerNode` bridge exposes session/stack/locals/runtime-tree snapshots plus validated breakpoint and continue/step/pause controls; `editor/tiiny/tools/debugger.gd` exposes 12 registry tools. `check_debugger.py` pauses a real fixture at a breakpoint and verifies `counter=7`, the `doubled` null local, the runtime tree, stale-frame rejection after continue, session-end errors, and breakpoint set/removal. Transaction/editor-smoke/Jobs/resource regressions pass. Boundaries: runtime property values need a selected remote node; only GDScript was exercised; breakpoint lines are not checked for executable code; step/pause are implemented but the fixture exercises continue and pause rejection. See [acceptance evidence](../evidence/12-acceptance.md).
