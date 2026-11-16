# Story 09 implementation plan — typed resource recipes and image generation

Status: Accepted. Registry recipe metadata, dialog eligibility, imported-image reporting, artifact linking, and failure-stage checks are implemented.

Parent: [09 — Typed resource recipes and image generation](../work-items/09-assets-resource-library.md).

## Execution contract

A resource recipe is editor-owned metadata plus a typed handler. The registry lists available and planned recipes, their input shape, model role, and output Godot type. Planned recipes are never offered as executable tools or enabled in Create New Resource.

The existing paths remain authoritative:

- `ConvexPolygonShape2D` generation validates model JSON, builds a hull, and assigns it through the resource dialog.
- Image generation validates base64 PNG data, writes a new file under `res://tiiny_generated/`, waits for import, and reports the actual project path.
- Scene resource construction (for example the rectangular collision shape) stays in the story 06 transaction recipe layer, not in the resource dialog.

## Resource recipe metadata

Add a read-only recipe table to `registry.gd`:

| Recipe | Status | Role/input | Output |
| --- | --- | --- | --- |
| `convex_polygon_shape` | available | coding model, natural-language shape description | `ConvexPolygonShape2D` |
| `image_generation` | available when a warm image model exists | image model, text prompt | imported `Texture2D` / PNG path |
| `image_to_3d` | planned | image-to-3D model, reference image | mesh/material (not exposed) |
| `music_generation` | planned | music model, prompt | audio stream (not exposed) |
| `speech_generation` | planned | speech role, text/voice | audio stream (not exposed) |

`resource_recipes()` returns metadata; `supports_resource_type(type)` returns true only for an **available** recipe whose output exactly matches the requested Godot type. No sound-effects recipe is listed until a tested model/API exists.

## Dialog integration

The Create New Resource dialog asks the dock whether the selected type is supported. The dock asks the registry. The fallback remains the existing `ConvexPolygonShape2D` check if the dock/registry is unavailable. Unsupported types show the existing “AI generation is not available” placeholder and stay editable=false; a blank prompt performs ordinary creation.

## Failure behavior

- Malformed polygon output is rejected before assignment; no partial resource is accepted.
- Image decode/import failures report the failure stage and leave no false success; an existing file is never overwritten.
- Planned recipes are visible only as metadata/tests and never appear in the HTTP tool list or the dialog as supported.
- Resource construction validates class/property assignment through the transaction executor and one undo action.

## Slices

### Slice A — recipe metadata and tests

Add the registry table, accessors, and fixture assertions for available/planned recipes and exact type support. No UI or device.

### Slice B — dialog eligibility

Use `supports_ai_resource_type()` from `create_dialog.cpp` with a safe fallback. Re-run the existing eligibility test for Image, StandardMaterial3D, and ConvexPolygonShape2D.

### Slice C — image and failure verification

Reuse the existing image adapter tests for valid PNG, malformed base64, HTTP failure, import, and path reporting. Verify an unsupported resource type cannot generate through the dock. Record a gated live image run as skipped unless a warm image model is available.

### Slice D — handoff

Run the registry/transaction fixture, editor smoke, and Jobs regression; record recipe metadata, dialog eligibility, image/import evidence, and planned-recipe boundaries in the work item and STATUS.

## Gates

- Available recipes and planned recipes are distinguishable and typed.
- Unsupported types never enable AI input; blank prompt remains ordinary creation.
- Image generation reports only an imported project path on success.
- Incompatible/malformed/import failures identify the stage and claim no completion.
- No sound-effects support is advertised.

All gates verified; see [acceptance evidence](../evidence/09-acceptance.md).

## Handoff

Accepted. See [acceptance evidence](../evidence/09-acceptance.md). Boundaries: live on-device image generation was not run; planned recipes stay metadata-only; the import wait is bounded at 10 seconds.
