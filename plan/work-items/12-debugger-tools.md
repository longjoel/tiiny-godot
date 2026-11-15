# 12 — Paused execution, live scene inspection, and breakpoints

Status: Queued

Feature: Paused execution, live scene inspection, and breakpoints

Sequence: 12

Stream: `debugger`

Dependencies: 05, 07, 08

## Scope

Expose debugger state and controls with explicit session, thread/frame, and pause context.

## Acceptance criteria

- [ ] At a real breakpoint, tools inspect the correct session, stack frame, locals, and available live-node state.
- [ ] The assistant distinguishes edited-scene data from runtime data and stale snapshots.
- [ ] Set/remove breakpoint tools validate script paths and line numbers and keep editor UI synchronized.
- [ ] Resume/step controls and any state-changing debug operation are visible in the action history.
- [ ] Disconnects, continued execution, unsupported languages, and stale object identifiers are handled safely.
- [ ] An end-to-end diagnosis is grounded in observed runtime values; missing data is reported explicitly.

## Concrete scenarios

Use WS-11, WS-12 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Pending. Record changed files, validation commands and results, editor/device observations, remaining limitations, and the next action. Update [STATUS.md](../STATUS.md) when handing off.
