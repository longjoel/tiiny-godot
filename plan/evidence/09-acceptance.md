# Story 09 — acceptance evidence

Story 09 is accepted. The registry now owns typed resource-recipe metadata, Create New Resource asks the dock/registry which types are supported, image generation waits for a real import before reporting success, and generated images link to their project artifact in chat. Planned 3D, music, and speech recipes are metadata only and are never advertised as executable tools.

Executable: `bin/godot.linuxbsd.editor.x86_64`, built from the story 09 working tree. The reported version string was `4.8.beta.custom_build.b31ac43a0` because the build preceded the story 09 commit. No build or test remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Registry distinguishes available/planned recipes and exposes typed input/output | `RESOURCE_RECIPES` in `editor/tiiny/tools/registry.gd` lists `convex_polygon_shape` → `ConvexPolygonShape2D`, `image_generation` → `Texture2D` as available, and `image_to_3d` → `Mesh`, `music_generation`/`speech_generation` → `AudioStream` as planned, each with role and input description. `resource_recipes()` and `supports_resource_type()` expose them. The transaction fixture asserts statuses, outputs, exact type support, and that planned recipes are absent from `tools_payload()`. |
| Only supported types enable the prompt; blank prompts stay ordinary | `CreateDialog::select_type` calls the dock’s `supports_ai_resource_type()`, falling back to `ConvexPolygonShape2D` when the dock/registry is unavailable. The editor smoke checks Image and StandardMaterial3D reject AI input, ConvexPolygonShape2D enables it, and blank prompts still create ordinary resources. |
| Image generation validates, saves, imports, reports the actual path | `_generate_image_tool` validates HTTP status, `b64_json`, size, PNG signature, and decode; writes a new timestamped file under `res://tiiny_generated/`; never overwrites; scans and waits (bounded 10 s) for a real `.import` with a loadable resource; reports `Generated image: <res:// path>`. The loopback HTTP fixture verifies the returned path decodes as a 1×1 image and loads as `Texture2D`, and that invalid PNG/HTTP/malformed responses are rejected. |
| Resource construction validates Godot types | Story 06’s typed recipes validate before mutation. The transaction fixture asserts an incompatible shape request returns `type_mismatch` with no partial node and no extra undo action. |
| Failures preserve artifacts and identify the stage | Image failures distinguish connection/HTTP, unsupported response, invalid PNG, folder/save failure, and saved-but-not-imported (including the saved path). Polygon failures reject malformed/degenerate/oversized/nonfinite output before assignment. |
| Test supported recipe, incompatible request, malformed output, import failure | Transaction fixture: recipe execution and undo, plus `type_mismatch`. Editor smoke: polygon validation and malformed responses. `_image_import_ready()` is asserted true for the generated texture and false for a deliberately invalid `failed_import_fixture.png`. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Transaction/registry/chat/action-card fixture | Passed recipe metadata, exact type support, planned-tool exclusion, dock eligibility, and generated-image artifact card | `/tmp/transactions-09b.log` |
| Loopback resource HTTP fixture | Passed real HTTPRequest polygon/image paths, image decode/import, and error responses | `/tmp/resource-http-09b.log` |
| Editor smoke + restart stages | Passed 11/11 stages, including resource-dialog eligibility, polygon validation, blank ordinary creation, and failed-import rejection | `/tmp/tiiny-story09-smoke2.json` |
| Built-in Jobs suite | Passed all 27 modes | `/tmp/jobs-09.log` |
| Build | Exit 0, `00:00:29.86`, same binary path | `/tmp/tiiny-story09-build3.log` |

## Remaining boundaries

- Live image generation against a warm on-device image model was not run in this slice. The recipe is implemented and deterministic HTTP/import coverage passes; live model quality remains unverified.
- `image_generation` is marked available as an implemented recipe. Execution still requires a configured, warm image model; otherwise the tool returns a clear configuration error.
- `image_to_3d`, `music_generation`, and `speech_generation` are planned metadata only. No sound-effects recipe is listed.
- The import wait is bounded at 10 seconds. A slow import reports the saved path as an error instead of claiming success.
- Create New Resource currently routes only `ConvexPolygonShape2D` generation through the dock; the registry contract is ready for additional dialog-integrated recipes.
