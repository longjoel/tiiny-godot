# 01 — Stabilize the existing prototype

Status: Active; validation pending

Feature: Stabilize the existing prototype

Sequence: 01

Stream: `integration`

Dependencies: None

## Scope

Establish a trustworthy baseline for the existing chat, settings, resource dialog, embedded scripts, and SDK adapter. Repair defects before expanding features.

## Implementation plan

Follow [the story 01 implementation plan](../implementation/01-stabilize-prototype.md): capture baseline, add narrow offline test seams, repair startup/manager failures, validate the existing tool protocol and resource dialog, run real-device smoke checks, then close with evidence. Keep story 02 implementation out of scope.

## Acceptance criteria

- [x] Record the outstanding build outcome; the editor executable links successfully with a reproducible command.
- [ ] Both embedded scripts pass Godot parsing and load without errors in a small project.
- [ ] Editor Settings exposes Tiiny configuration and the side dock exposes chat; removed custom settings tabs stay absent.
- [ ] Exercise a real chat request, unsupported tool response, tool failure, and supported shape creation; record actual outcomes and any blocked checks.
- [ ] The README accurately describes verified prototype behavior and remaining limitations.

## Concrete scenarios

Use WS-07, WS-15 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

Build session `45249` exited 0 and linked the editor; duration `00:35:11.72`. Script/runtime/device validation remains pending. Record further changed files, commands/results, observations, limitations, and the next action. Update [STATUS.md](../STATUS.md) when handing off.
