# Story 01 — accepted prototype baseline

Accepted November 14, 2026 (America/Chicago). All parent story 01 criteria pass. This accepts stabilization of the existing prototype, not the later workspace tools, job queue, complete device lifecycle, or model-quality roadmap.

## Build and identities

Final build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, session `7620`, exit 0, 36.41 seconds; binary `bin/godot.linuxbsd.editor.x86_64`, version `4.8.beta.custom_build.f4905e024`. HEAD remains `f4905e0242852415cf22e8daeed18e4fd960eb85`; this worktree contains the stabilization changes. No build remains running.

| Artifact | SHA-256 |
| --- | --- |
| Accepted editor | `44ba0d73bb8d005ecbae5fc83bafccfe014d65a6dedae9be61e5950e9470fc7d` |
| Manager header | `dbc846f61fcb833c3a308174eb87b716463302793230c9cb3a50ed99500e85f2` |
| Chat header | `6598af0aef47ef7aa9a4ea9b908f58bb35aa8b0b3fdb0a43e9fd540e156a33c1` |
| Local Tiiny CLI executable | `b66c035de935b7ea0ed4f0e3b2f18fc4d372952e10de6cc1b94175eee474cc1d` |

The SDK CLI does not expose `--version` or a `version` command in this installation. Its executable hash is recorded instead. The device service version was not independently reported; the model catalog's build identity is recorded below.

## Acceptance matrix

| Parent criterion | Evidence | Outcome |
| --- | --- | --- |
| Reproducible linked editor | Final build above, matching binary hashes in UI and live reports | Passed |
| Both embedded scripts parse/load | Exact-source parser, real embedded startup, invalid-call guard in built-in dock | Passed |
| Settings and chat placement | Models/Advanced both visible with global advanced toggle off; one side chat dock; only normal General/Shortcuts settings tabs | Passed; rendered captures inspected |
| Offline startup and inventory failure | Missing/empty/invalid catalogs, malformed capacity/loaded tables, guarded Apply, no real SDK mutation | Passed |
| Unsupported/failed/malformed tools and recovery | Matched results, argument/ID limits, traversal, no overwrite, invalid script rejection, retained artifacts after continuation failure, context reset | Passed |
| Real chat and supported polygon | Connected Tiiny text, real polygon generation, saved/reopened resource with four hull vertices; final warm-state comparison | Passed |
| README matches observed behavior | Integration/test READMEs rewritten around verified modes, boundaries, and explicit remaining limitations | Reviewed and passed |

## Executed verification

```sh
python3 integrations/tiiny/tests/check_model_configuration.py --http-smoke --displayed --display-driver wayland --report /tmp/tiiny-story01-accepted-ui.json
python3 integrations/tiiny/tests/check_model_configuration.py --live-inference --report /tmp/tiiny-story01-accepted-live.json
```

Final runs: UI session `44846` and hardware session `18652`, both exit 0 on the accepted binary. Supplemental loopback/headless session `65088` also exited 0 with an explicit assertion that the generated PNG imports and loads as Texture2D; see [HTTP/import report](01-accepted-http.json). Sanitized reports are retained as [UI report](01-accepted-ui.json) and [live report](01-accepted-live.json). The preceding X11 displayed/HTTP run also passed (report `/tmp/tiiny-story01-final-x11.json`); final Wayland verification includes the last settings-visibility correction.

The UI run passes missing/slow CLI, cancellation, owned child cleanup and manager exit; stale/busy readiness and bound-device checks; ordinary native Image/material/blank polygon and node creation; wrong type, selection-away-and-back, cancellation/reopen and late callbacks; malformed/degenerate/oversized/nonfinite polygon validation; save/reopen; real loopback HTTP timeouts/errors/malformed responses; PNG generation decoding/import; polygon HTTP adapter; and Tiiny Output messages while a fixture scene runs.

Snapshots from the accepted displayed run contain fixture data only: [Models and Advanced settings](01-models.png), [Tiiny Chat and Output](01-chat.png). These were captured from actual rendered Godot viewports and visually inspected, not generated mockups.

## Hardware observations

Coding model: `Qwen/Qwen3.6-35B-A3B`. Catalog build: `sha256:2cbbbd42400dec2282fb390189a254e8205f971ad5830034d184808da587a564`. Real chat returned final text. A real requested rectangle produced a valid four-vertex ConvexPolygonShape2D, saved and reopened successfully.

Initial and final warm set: `Qwen/Qwen3.6-35B-A3B`, `Qwen/Qwen3.8-27B`. The sets matched after inference; no restoration was needed. No real model download, load, unload, or Apply ran. Tests used temporary project/editor settings, and inference used the same bound SDK device and credential fallback as management.

No image model was already warm. The live image smoke was explicitly skipped; the adapter remains experimental/unverified on real Tiiny hardware, although production HTTP/PNG/import paths pass loopback fixtures. This follows implementation-plan step 6's requirement to report unavailable image coverage rather than imply success.

## Repairs and practical limits

- Protocol validation now precedes mutations; completed tool effects remain visible/in context after continuation failure. New conversation recovers from exhausted context without deleting displayed results.
- Inference resolves through the bound device with the correct Host header and shared credential fallback. Stale/busy inventory cannot claim readiness. Malformed inventory/saved configuration is rejected explicitly.
- Manager exit stops its owned SDK descendants, including PTY child sessions that ignore TERM. `/proc` files are read as streams because their reported length is zero; disappearing children are tolerated. Cancelling local processes cannot undo remote effects already completed.
- Resource selection changes invalidate pending generations even if the same type is reselected. Wrong resource types and cancelled/reopened targets cannot receive old results. A newly created empty Image no longer requests an invalid texture preview.
- The original displayed run crashed after invalid empty-Image preview diagnostics. After the guard and subsequent fixes, both X11 and Wayland runs passed; this records the observed resolution without claiming an independently proven root cause for that stripped backtrace.
- Parser/response handling avoids logging raw malformed bodies. PNG signatures and size limits reject bad image responses before decoding where possible. Settings remain accessible without the global advanced filter.

The invalid-script rejection stage deliberately requires one parse diagnostic; every other final stage has zero GDScript diagnostics. Three unrelated upstream initialization errors remain for MultiplayerPeerExtension/WebRTCDataChannelExtension required virtual methods. Wayland/Mesa emits nonconformant-driver warnings, and the deliberate nonfinite-number fixture emits a numeric-overflow warning. Headless runs can additionally report dummy-window position and dummy-texture diagnostics; restricted runs can report debug-server socket errors. Passing this baseline does not claim an otherwise diagnostic-free engine build.

Story 02 is now eligible and remains queued. Real mutating Apply/progress, automatic warm restoration/reconnect, comprehensive model quality, and future workspace operations retain their later-story acceptance gates.
