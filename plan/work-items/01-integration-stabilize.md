# 01 — Stabilize the existing prototype

Status: Complete — prototype baseline accepted; see completion evidence.

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
- [x] Both embedded scripts pass Godot parsing and load without Tiiny script errors in an isolated small project. Unrelated engine startup diagnostics are recorded separately.
- [x] Editor Settings exposes Tiiny configuration and the side dock exposes chat; removed custom settings tabs stay absent.
- [x] Offline startup and catalog/capacity failures finish without false readiness or SDK mutation, with a reproducible sanitized baseline report.
- [x] Exercise unsupported tools, tool failure, malformed responses, and recovery with offline fixtures.
- [x] Exercise a real chat request and supported shape creation; record actual outcomes and any blocked checks.
- [x] The README accurately describes verified prototype behavior and remaining limitations.

## Concrete scenarios

Use WS-07, WS-15 from [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md). Follow [TESTING.md](../TESTING.md) to distinguish deterministic checks, editor integration, hardware checks, and model-quality evaluations.

## Evidence and handoff

See [completion evidence](../evidence/01-completion.md) for the acceptance matrix, final binary/source hashes, reproduced defects and fixes, sanitized UI/live reports, displayed captures, and remaining later-story boundaries. Final build session `7620` exited 0 in 36.41 seconds with `scons platform=linuxbsd target=editor use_static_cpp=no -j8`. Native dialogs, process lifecycle, protocol recovery, actual loopback HTTP/image import, running-scene Output, displayed settings/chat, and real Tiiny chat/polygon generation pass. The original warm set was unchanged. Live image generation was explicitly skipped/unverified because no image model was warm, as allowed by implementation-plan step 6. Real model-management Apply remains later-story acceptance. Story 02 is eligible and queued; no build remains running.
