# Story 18 implementation plan — workspace coding tools and hybrid mode

Status: Accepted. Slices A–E are implemented and verified by the pure, editor, displayed, and fixed-solution bake-off fixtures; live-model coding-mode evaluation remains separate. See [acceptance evidence](../evidence/18-acceptance.md).

Parent: [18 — Workspace coding tools and hybrid mode](../work-items/18-workspace-coding-tools.md).

## Goal

Stop competing with a coding agent on editor macros. Give the assistant real workspace tools, while retaining the editor-native layer for live/atomic scene work, debugger state, and Tiiny assets.

## Architecture

Add a workspace tool provider alongside the inspector/transaction/debugger providers:

- `editor/tiiny/tools/workspace.gd` (or an embedded equivalent) owns schemas and handlers.
- It receives the project root and an editor bridge object for scene save/reload/scan.
- File operations use `FileAccess`, `DirAccess`, `Marshalls`, and SHA-256; no project file is imported by the provider itself.
- Command execution uses an owned child process (`OS.execute_with_pipe` or the existing CLI process pattern), polled with timers rather than blocking.
- The registry gets a `tool_mode` setting: `editor`, `workspace`, or `hybrid`. Only the selected tool families are advertised.

The existing typed transactions remain unchanged; file tools do not reuse scene undo.

## Tool schemas

### `list_files`
```json
{"path":"res://scripts","recursive":true,"max_entries":500}
```
Returns `{path, entries:[{path,type,size}], truncated}`. Directories and files; no binary contents.

### `read_file`
```json
{"path":"res://player.gd","offset":1,"limit":400}
```
Returns `{path,sha256,size,content,truncated,binary:false}`. Binary files return metadata and `binary:true`, no bytes. Max 256 KiB or 1000 lines per call.

### `search_text`
```json
{"query":"func _ready","glob":"**/*.gd","max_matches":200}
```
Literal search by default; optional regex only if explicitly requested. Bounded context lines, no binary matches.

### `file_info`
Returns path, type, size, SHA-256 for regular files, modified time, and whether it is a symlink.

### `write_file`
```json
{"path":"res://player.gd","content":"...","expected_sha256":"...", "create":false}
```
- Existing file: require the current SHA-256; reject mismatch.
- New file: require `create:true`; reject if it exists.
- Write to a sibling temp file, flush, verify content/hash, rename atomically.
- Preserve text content exactly; reject writes over 1 MiB.
- For `.gd`, optionally parse-check with `GDScript.reload()` before commit.
- `scan_filesystem()` after success; do not auto-reload an open scene unless requested.

### `apply_patch`
```json
{"path":"res://player.gd","expected_sha256":"...","patch":"@@"}
```
Prefer a unified-diff subset or an exact old/new block. Require a unique match; reject ambiguous or stale patches. Never partially apply. Preserve line endings. Return before/after hashes and a bounded diff.

### `run_godot_headless`
```json
{"args":["--headless","--path",".","-s","res://tests/fixture.gd"],"timeout_ms":60000}
```
- Use `OS.get_executable_path()` and the project root.
- Allow only non-interactive args; no arbitrary executable.
- Capture stdout/stderr with per-stream caps; report exit code, truncation, and timeout.
- Kill the owned process group on timeout/cancel.

### `run_command` (gated)
```json
{"command":"godot --headless --path . -s res://tests/check.gd","cwd":".","timeout_ms":60000}
```
- Off unless `tiiny_ai/advanced/allow_shell_commands` is true.
- Require an explicit user approval flow before execution (setting alone is not enough for destructive-looking commands).
- Root-confined `cwd`; sanitized environment; no credential directories; no interactive/TTY.
- Output caps and process cleanup identical to headless runner.
- Document that this is host code execution.

### Git
- `git_status`, `git_diff`, `git_log` use the same process runner with an argv allowlist and no shell interpolation.
- Root is the project; output bounded; no `push`, `reset`, `checkout`, `clean`, or config writes.
- Return diff text for review; file edits are not scene-undoable.

### Editor bridge
- `save_edited_scene` (existing story 15).
- `reload_scene(path)`: refuse if the edited scene is dirty unless explicitly saved/discarded.
- `scan_filesystem`: after external writes.
- Before editing an open `.tscn`/`.tres`: compare its SHA with the editor's saved state; if the scene is dirty, return `scene_dirty` and require save/reload.

## Path and security policy

- Accept `res://` and project-relative paths; canonicalize with `simplify_path`.
- Reject `..`, absolute paths outside the project, `.git` internals, editor data, SSH/config, and credential files.
- Reject symlinks or resolve and verify the real target stays inside the project (test `DirAccess.is_link`/equivalent).
- Never follow binary/asset content into context; return metadata.
- Redact environment values, tokens, and auth headers from command output.
- Bound every read/list/search/write/patch and command.
- No arbitrary Godot method calls, no editor internals, no script execution through the file tools (except a user-approved command/headless check).

## Tool mode

- Settings: `tiiny_ai/advanced/tool_mode` with `editor` (default), `workspace`, `hybrid`.
- Registry filtering is explicit and testable; `tools_payload()` returns only the selected families.
- The chat dock shows the active mode and warns that workspace mode uses file edits without scene undo.
- Hybrid is recommended for the bake-off; editor mode remains conservative.

## Action history

- File edits use `affected: [{kind:"file", path}]` and `File change · not scene-undoable`.
- Return a bounded diff summary; a `Review diff` action may call `git_diff` or show the patch.
- Scene transactions keep their one undo action and node/resource navigation.
- Failed patches/writes leave files unchanged and report the stage.

## Slices

### Slice A — provider, paths, read/list/search

Implement the provider, project-root confinement, file metadata, binary handling, bounds, and mode filtering. Tests cover traversal/symlink/binary/large files.

### Slice B — hash-guarded writes and patches

Implement atomic writes, stale-hash rejection, new-file semantics, deterministic patch application, GDScript parse checks, scan, and file action cards. Tests cover conflicts and rollback.

### Slice C — git and execution

Implement read-only git inspection, headless Godot runner, gated shell command with approval, timeout/output caps, process cleanup, and redaction. Tests use a fixture script/command.

### Slice D — editor bridge and modes

Implement dirty-scene refusal, save/reload/scan, tool-mode filtering, and UI status. Tests open a dirty scene and verify no silent loss.

### Slice E — bake-off and handoff

Run 10 representative tasks with workspace coding tools and with editor tools. Record:
- correctness and time
- editor corruption or recovery events
- undo/diff review effort
- model failures and tool-choice issues

Update the task catalog and README; keep editor tools only where they demonstrably add value.

## Gates

- Root confinement and symlink/credential protections pass before enabling writes.
- No blind overwrite; no partial file on failure.
- Shell is opt-in and approved; headless is bounded and cleaned up.
- Dirty editor state is never silently discarded.
- Tool modes are separate and bounded.
- The bake-off decides which tool families earn continued investment.
