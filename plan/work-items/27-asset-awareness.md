# 27 — Existing-asset awareness and reuse

Status: Complete. The asset inventory, image metadata, reference tracking, editor-context summary, and reuse guidance pass in the pure and editor workspace fixtures. See [implementation plan](../implementation/27-asset-awareness.md).

Feature: Let the assistant see the project's existing images, models, audio, scenes, scripts, and resources, including image dimensions/color and referencing files, so it reuses assets instead of regenerating them

Sequence: 27

Stream: `workspace`

Dependencies: 05, 18, 26. Uses the shared workspace provider and the read-only inspector. It does not call a model, network, or process.

Implementation: [plan](../implementation/27-asset-awareness.md).

## Why

The model repeatedly generated new textures because it had no inventory of existing assets. In editor mode there was no file listing at all, and the editor context described the scene but not the project's images, models, or audio. A request to build a platformer could therefore create a second player texture, a third background, and so on.

Classifying textures with the configured image model is not available: the image role is `Text-to-Image`, which generates images and cannot inspect one. The coding-model role accepts `Image-Text-to-Text`, so a vision-capable coding model could classify an image in principle, but the chat transport currently sends string content only and the Tiiny endpoint's image content format is unverified. A vision path would need capability detection, a downscaled image payload, context-cost handling, and a metadata fallback. That is a separate item.

Deterministic metadata already answers the practical question: what exists, what does it look like, and where is it used? Image dimensions, average color, alpha, file size, import state, and referencing scenes/scripts are enough to choose an existing texture or detect a duplicate. Scene structure is already available through `get_scene_tree` and `inspect_node`; a rendered-scene caption is a vision feature, not an inventory feature.

## Scope

Add one shared, read-only tool, `find_assets`, available in editor and hybrid/workspace mode:

```json
{"kind": "image", "query": "player", "path": "res://generated", "max": 20, "used": true}
```

- Scans `res://` recursively, skipping hidden/editor/repository directories, credential files, and symlinks. The scan is bounded to 5,000 candidate files.
- Supports `kind` of `all`, `image`, `model`, `audio`, `scene`, `script`, or `resource`.
- Filters by case-insensitive path substring and optional `used` state.
- Returns path, kind, byte size, modification time, import state, and up to five referencing files. Referencing files come from a bounded scan of up to 300 scenes/scripts/resources and 3 MB of text.
- For images, returns dimensions, average color as `#rrggbb`, and whether alpha is present. Metadata is limited to files up to 8 MB and 16 megapixels; invalid image headers are skipped without decoding.
- Sorts referenced assets first, then newest, then path; returns at most 100 rows.
- A result with no matches says to generate only if none fits. A non-empty result says to reuse an existing path instead of creating a duplicate.

Image header validation avoids decoding corrupt or fake files and avoids engine error noise for files that are not real images.

### Editor context

The request context now includes a compact line before the scene description:

```
Assets: 6 images, 2 scenes, 1 script; images include generated/player.png, ...
```

The overview is cached for five seconds and counts only; it does not load image pixels. This makes the model aware of existing assets before it chooses a tool.

## Acceptance criteria

- [x] `find_assets` is advertised in editor, workspace, and hybrid modes with no shell or approval gate.
- [x] A real image returns its path, 2×2 dimensions, an average color, and the scene that references it.
- [x] `used: true` keeps referenced assets; `used: false` excludes them.
- [x] `kind` and `query` filter the inventory; `max` bounds rows and reports truncation.
- [x] The editor context includes an `Assets:` summary when the project has assets.
- [x] Invalid image headers are skipped without decode errors.
- [x] The base policy tells the model to call `find_assets` before generating or importing an asset and to reuse existing paths.
- [x] Pure and editor workspace suites, the transaction fixture, the 20-case selection corpus, runtime verification, Jobs, and smoke are rerun.

## Evidence

- `test_workspace_tools.gd`: image metadata/reference lookup, used/unused filtering, kind+query filtering, truncation, asset overview, and definition checks passed; no image decode errors.
- `editor_workspace_tools.gd`: the editor context contains `Assets:`; the auto-save regression guard and docs checks still pass.
- `check_tool_selection.py`: 20 cases passed, including “Find the existing generated image asset”.
- `check_workspace_transactions.py`, `check_runtime_verification.py`, and the pure/editor workspace suites passed.
- Full Jobs suite passed 66 modes; editor smoke passed 13.
- Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:36.34`, `bin/godot.linuxbsd.editor.x86_64`. No build remains running.
