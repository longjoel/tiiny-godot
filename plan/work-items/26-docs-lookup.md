# 26 — Offline Godot reference lookup with search

Status: Complete. Class summaries, exact member documentation, partial member search, and class-name search pass in the editor workspace fixture. See [implementation plan](../implementation/26-docs-lookup.md).

Feature: Let the assistant query the compiled Godot class reference offline, including class summaries, method/property/signal/constant documentation, and class or member search, without a network client or approval

Sequence: 26

Stream: `integration`

Dependencies: 05 and 18. Extends the read-only workspace tools. It does not add a network client, execute project code, or change the scene.

Implementation: [plan](../implementation/26-docs-lookup.md).

## Why

The model is expected to work against real Godot APIs, but it can invent method names, argument lists, and property types. Reading the whole class reference would not fit in a small context, and fetching documentation from the network is not available in the offline device workflow.

The editor already contains the compiled class reference. The GDScript language-server workspace indexes it from `EditorHelp::get_doc_data()` into native symbols with signatures, documentation, constants, properties, signals, enums, and deprecation flags. That is exactly the reference the editor's own help uses.

Calling the language service over TCP would require an LSP client, framing, document lifecycle, and a running port. The same index is reachable in-process with one accessor. That keeps the capability offline, deterministic, and free of approvals.

## Scope

Add one shared tool, `lookup_docs`, available in editor and hybrid/workspace mode:

```json
{"class_name": "CharacterBody2D", "member": "move_and_slide"}
{"class_name": "CharacterBody2D"}
{"query": "body2d"}
{"class_name": "CharacterBody2D", "member": "move"}
```

- `class_name` returns a class summary: class signature, documentation, and up to 80 members with signatures, kinds, and deprecation flags.
- `member` with an exact name returns the exact signature and documentation.
- `member` with a partial name returns up to 20 matching members with signatures.
- `query` searches `ClassDB` class names, ranks exact and prefix matches first, and returns up to 20. A single match returns its class summary.
- `Class.member` in `query` is accepted as shorthand.
- An unknown class suggests matching class names; an unknown member suggests using a partial name.

The result is bounded: 4,000 characters of class documentation, 6,000 characters of member documentation, 80 members, and 20 search results. The tool is read-only, needs no shell setting, and starts no process.

### Language-service accessor

Add `GDScriptLanguageProtocol::get_native_docs(native_class, symbol_name)` and bind it. It resolves through the workspace's existing native-symbol index.

The workspace init is split so documentation does not require an LSP client:

- `initialize_native_symbols()` builds native symbols and, when smart resolve is enabled, native members. It is idempotent through `native_symbols_ready`.
- `initialize()` calls that, then loads workspace scripts, connects the editor signal, and marks itself initialized.

The previous all-in-one `initialize()` called `reload_all_workspace_scripts()`, which requires a connected client and logged client errors during a docs lookup. Calling only `initialize_native_symbols()` avoids that.

## Acceptance criteria

- [x] `lookup_docs` is advertised in every mode, with no shell, approval, scene, or process dependency.
- [x] A class lookup returns the class signature, documentation, and member list including `move_and_slide`.
- [x] An exact member lookup returns the `CharacterBody2D.move_and_slide` signature and non-empty documentation.
- [x] A partial member lookup returns matching members.
- [x] A class-name query finds `CharacterBody2D`; a single match returns the class summary.
- [x] Unknown classes and members fail with `not_found`; an empty request fails with `invalid_arguments`.
- [x] Docs lookup does not parse workspace scripts or require an LSP client.
- [x] The base policy directs the model to use `lookup_docs` before inventing APIs.
- [x] Focused suites, the wider Jobs suite, and smoke checks are rerun.

## Evidence

- `editor_workspace_tools.gd` (through `check_workspace_tools.py`): class summary, exact method docs, class search, partial member search, unknown member, and empty request passed; editor integration passed without LSP client errors.
- `check_workspace_transactions.py`, `test_workspace_tools.gd`, the 19-case selection corpus, and the runtime fixture passed.
- Full Jobs suite passed 66 modes; editor smoke passed 13.
- The transaction fixture's context setting was raised from 32k to 64k because the tool list grew; the dedicated 8k conservative-budget smoke test is unchanged.
- Build: `scons platform=linuxbsd target=editor use_static_cpp=no -j8`, exit 0, `00:00:19.04`, `bin/godot.linuxbsd.editor.x86_64`. No build remains running.
