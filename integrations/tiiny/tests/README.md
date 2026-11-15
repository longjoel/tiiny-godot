# Model configuration verification

Run from the repository root after building the editor:

```sh
python3 integrations/tiiny/tests/check_model_configuration.py
python3 integrations/tiiny/tests/check_model_configuration.py --editor-smoke
```

The runner extracts the exact embedded scripts into a temporary project and isolates Godot user data and settings via XDG directories. The first command checks parsing, the pure configuration planner, draft invalidation, context expiry, and panel construction. Layout checks exercise 600- and 1,400-pixel panel widths, require compact single-line table cells, and verify narrow-view horizontal scrolling. The editor smoke test opens the real Models section and exercises Apply with a fake transport, plus the nonblocking process runner with a harmless local executable. It also checks chat context bounds. These tests do not execute the real Tiiny CLI or change real device models.

The offline suite also checks that installed models assigned to tasks are not repeated, model information opens in a popup, headroom defaults to collapsed, and changing reserves affects admission checks. Progress fixtures cover split terminal escapes, UTF-8 progress bars, percentage forwarding from a local CLI stub, device-reported download percentages, and suppression of duplicate updates.

Settings migration fixtures verify that connection and device values move into Advanced, existing Advanced values take precedence, and repeated migration preserves the result.

For an explicitly selected hardware read-only check:

```sh
python3 integrations/tiiny/tests/check_model_configuration.py --live-readonly
```

This uses the configured SDK device/key fallback to refresh inventory and Check Config in the rebuilt editor. It does not invoke Apply. Real downloads/loads/unloads require separate integration validation and should not run as an incidental unit test. The suite does not establish the displayed visual quality of the panel.

Observed environment limitations: headless editor initialization in this checkout emits required-virtual diagnostics for MultiplayerPeerExtension/WebRTCDataChannelExtension. Under the restricted execution environment it also emits local debug-server socket diagnostics. The runner reports stderr, requires the test's success marker and exit code, and rejects GDScript errors; these unrelated initialization diagnostics are not treated as proof of a clean editor startup.
