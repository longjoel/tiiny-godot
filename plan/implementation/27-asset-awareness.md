# Story 27 implementation plan — existing-asset awareness

Status: Implemented and verified by the pure and editor workspace fixtures.

Parent: [27 — Existing-asset awareness and reuse](../work-items/27-asset-awareness.md).

## Execution contract

- `find_assets` is read-only and works in every tool mode.
- It never calls a model, starts a process, or changes the scene or project.
- The scan is bounded: 5,000 candidate files, 300 reference-text files, 3 MB of reference text, 100 returned rows, 8 MB and 16 megapixels per image.
- Hidden directories, `.godot`, `.git`, `.tiiny`, denied credential files, and symlinks are skipped.
- Image metadata is best-effort. A corrupt or fake image is skipped without a decode error.

## Inventory

`workspace.gd` classifies files by extension:

- image: png, jpg, jpeg, webp, svg, bmp, tga, exr, hdr, dds, ktx;
- model: glb, gltf, obj, fbx, blend, dae, stl, ply;
- audio: wav, ogg, mp3;
- scene: tscn, scn;
- script: gd, cs;
- resource: tres, res.

`_scan_asset_files` walks `res://` with `DirAccess`, skips hidden/denied entries and links, and records the absolute path, `res://` path, kind, bytes, modified time, and whether a `.import` file exists.

`_asset_references` builds a path list for the candidates and scans up to 300 scenes/scripts/resources (each up to 1 MB) for those paths. It records at most five referencing files per asset. A candidate list larger than 500 is capped for the reference pass.

`_find_assets` filters by kind, query, and `used`, sorts referenced first then newest then path, and returns up to `max` (1–100) rows. The summary distinguishes “generate only if none fits” from “reuse an existing path”.

## Image metadata

`_image_metadata`:

1. rejects files over 8 MB;
2. validates the header for PNG/JPEG/WebP/BMP before decoding (for PNG, signature and `IHDR`);
3. loads with `Image.load_from_file`;
4. returns `size` and, for images up to 16 megapixels, resizes a copy to at most 8×8 and computes the average color and whether any sampled alpha is below 0.99.

`_image_header_ok` prevents the inspector from calling the decoder on `binary.png`-style fixtures and avoids noisy engine errors.

## Editor context and prompt

`asset_overview()` scans the project for counts and up to four image paths, caches the text for five seconds, and returns a compact string. `_editor_context` appends `Assets: ...` before the scene description, including when no scene is open.

The base policy now says: before generating or importing a texture, model, or audio asset, call `find_assets` and reuse a suitable existing path; never create a duplicate.

## Vision status

The image role is `Text-to-Image`; it cannot classify. The coding role allows `Image-Text-to-Text`, but the chat transport sends string content only. A future vision path would need:

- capability detection from the model type;
- an image content part (likely an OpenAI-style `image_url` data URI) verified against the Tiiny endpoint;
- a downscaled PNG and context-cost limit;
- a fallback to this metadata when the model or endpoint cannot accept images.

This item deliberately ships the deterministic path first, because it stops duplicate asset creation without model calls or extra latency.

## Tests

- `test_workspace_tools.gd` adds a real 2×2 PNG and a scene that references it:
  - image lookup returns path, size `[2, 2]`, `#rrggbb`, and `used_in`;
  - `used: true` keeps it, `used: false` excludes it;
  - `kind: scene, query: assets_used` returns the scene;
  - `max: 1` reports truncation;
  - `asset_overview()` mentions images;
  - the editor/workspace payload advertises `find_assets`.
- `editor_workspace_tools.gd` asserts `_editor_context()` contains `Assets:` after the fixture creates `reference.png`.
- `editor_tool_selection.gd` adds a 20th case: “Find the existing generated image asset”.
