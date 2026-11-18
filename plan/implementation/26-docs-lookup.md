# Story 26 implementation plan — offline Godot reference lookup

Status: Implemented and verified by the editor workspace fixture.

Parent: [26 — Offline Godot reference lookup with search](../work-items/26-docs-lookup.md).

## Execution contract

- The lookup is read-only: no file, process, scene, node, project setting, or approval.
- Documentation comes from the editor's compiled `DocData`, not the network.
- The tool works in every tool mode.
- Results are bounded: 4,000 characters of class docs, 6,000 characters of member docs, 80 members, 20 search results.
- Search ranks exact class names first, then prefix matches, then substring matches; ties sort alphabetically.
- An unknown class suggests matches instead of failing silently.

## Language-service accessor

The workspace already builds `native_symbols` from `EditorHelp::get_doc_data()`:

- class name, `<Native> class X extends Y`, brief and full documentation;
- constants with enum and value;
- properties and theme properties;
- methods, annotations, constructors, operators, and signals with full signatures;
- deprecation and kind metadata.

`GDScriptWorkspace::initialize()` also calls `reload_all_workspace_scripts()`, which expects a connected LSP client and emits client errors when none exists. Split it:

```cpp
void GDScriptWorkspace::initialize_native_symbols(); // docs only, idempotent
Error GDScriptWorkspace::initialize();               // docs + workspace scripts + editor signal
```

`native_symbols_ready` guards the docs phase. `initialize()` now marks `initialized = true` after the full setup.

Add and bind:

```cpp
Variant GDScriptLanguageProtocol::get_native_docs(const String &p_class, const String &p_member);
```

It calls `workspace->initialize_native_symbols()`, resolves with `workspace->resolve_native_symbol()`, and returns `symbol->to_json(true)`. It never sets the protocol's LSP `_initialized` flag, so a later real client still gets the full workspace initialization.

## Tool

`lookup_docs` in `editor/tiiny/tools/workspace.gd`:

- `class_name`: exact class; returns the summary when `member` is empty.
- `member`: exact name returns that symbol; a partial name returns up to 20 matches.
- `query`: exact class, `Class.member`, or a class-name search. A single search match returns the class summary.
- Unknown class returns `not_found` with class-name matches.
- Unknown member returns `not_found` with the class context.

Output shapes:

- class: `detail`, `documentation`, `members`, `member_count`, `truncated`;
- member: `detail`, `documentation`, `kind`, `deprecated`;
- partial: `matches` with member summaries;
- search: `matches` with class names.

Kind names map LSP symbol kinds (class, method, property, field, constructor, enum, signal/event, constant, operator, and so on) to readable strings.

## Budget note

Adding the docs tool grew the tool payload. The transaction fixture was only about 400 bytes under its 32k conservative chat budget after the story 25 trims, so it now uses 64k like the other editor fixtures. The dedicated budget test in `editor_model_settings_smoke.gd` still asserts the 8k behavior: a short request passes and a 10,000-character request fails. No budget semantics changed.

## Tests

- `editor_workspace_tools.gd`:
  - class summary has a non-empty detail and includes `move_and_slide`;
  - exact member returns the `CharacterBody2D.move_and_slide` signature and non-empty docs;
  - `query: "body2d"` finds `CharacterBody2D`;
  - partial member `"move"` returns matches;
  - unknown member returns `not_found`;
  - empty request returns `invalid_arguments`.
- The editor run must have no `latest_client_id == -1` or workspace-script parse errors; the fixture's existing error-count check enforces that.
- `check_workspace_transactions.py` verifies the payload still fits the raised fixture budget.
