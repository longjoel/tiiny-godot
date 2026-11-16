# 18 — Workspace coding tools and hybrid mode

Status: Ready to start

Feature: Coding-agent tools with editor-aware safety

Sequence: 18

Stream: `integration`

Dependencies: 07, 08, 14, 15, 16, 17

Implementation: [plan](../implementation/18-workspace-coding-tools.md).

## Scope

Give the assistant the workspace tools a normal coding agent has, while keeping the editor-native tools for live/undoable scene work and Tiiny asset/device work.

This is a hybrid:

- **Workspace coding mode**: list/read/search files, hash-guarded writes and patches, git inspection, and bounded command/headless execution.
- **Editor mode**: the existing typed scene/resource transactions, action cards, undo, debugger, and asset/device tools.
- **Tool modes** keep the two payloads separate so ordinary editor requests are not buried in coding tools and vice versa.

Do not pretend file writes are scene-undoable. Use expected hashes, atomic writes, bounded output, and git diffs for review/recovery.

## Required tools

### Workspace files

- `list_files(path, recursive?, max_entries?)`
- `read_file(path, offset?, limit?)`
- `search_text(query, glob?, max_matches?)`
- `file_info(path)`
- binary detection and metadata-only handling for images/audio/models

### Editing

- `write_file(path, content, expected_sha256?, create?)`
- `apply_patch(path, patch, expected_sha256?)`
- `create_file`, `move_file`, `delete_file` gated by explicit approval
- atomic temp-write/rename; stale-file rejection; no blind overwrite

### Execution

- `run_godot_headless(args, timeout_ms?)` using the editor binary and project root
- `run_command(command, cwd?, timeout_ms?)` only when an explicit advanced setting is enabled
- bounded output, timeout, process-group cleanup, environment/credential redaction
- no interactive commands

### Git inspection

- `git_status`, `git_diff`, `git_log`
- read-only, root-confined, bounded output
- no network or history-rewriting commands

### Editor bridge

- `save_edited_scene`, `reload_scene`, `scan_filesystem`
- refuse or warn before editing an open dirty `.tscn`; never silently discard unsaved editor state

## Acceptance criteria

- [ ] File tools are confined to the project root; absolute escapes, `..`, symlinks, and editor-data/credential paths are rejected.
- [ ] Reads/searches/listings are bounded, binary-safe, and truncation is reported without injecting binary data into the model context.
- [ ] Writes/patches require the current SHA-256 when overwriting; atomic writes prevent partial files, and stale/concurrent edits fail without changing the file.
- [ ] Patch application is deterministic, rejects ambiguous context, and preserves unrelated content; invalid GDScript can be checked before commit.
- [ ] Git status/diff/log are read-only, root-confined, bounded, and do not expose credentials.
- [ ] Headless Godot/test commands run non-blockingly with timeouts, output caps, and owned-process cleanup.
- [ ] Arbitrary `run_command` is off by default, requires an explicit setting/approval, and is clearly described as host code execution.
- [ ] Scene save/reload is explicit; editing an open dirty scene is refused or requires a save decision. No unsaved editor state is silently lost.
- [ ] Editor mode and workspace coding mode expose separate, bounded tool payloads; switching modes is visible.
- [ ] File changes use file-change action cards and git diff for review; they never show scene Undo. Scene transactions keep one undo.
- [ ] Deterministic fixtures cover traversal, symlink escape, binary/large files, stale hashes, patch conflicts, dirty scenes, reload, command timeout/output limits, and mode filtering.
- [ ] A bake-off of ≥10 representative tasks compares workspace coding tools vs typed editor tools on correctness, time, corruption/recovery, and review effort. Results are recorded without claiming a general success rate.

## Concrete scenarios

Add WS-19 and WS-20 to [ACCEPTANCE_SCENARIOS.md](../ACCEPTANCE_SCENARIOS.md):

- WS-19: “Implement a script/scene feature using workspace files and run the relevant Godot check.”
- WS-20: “A concurrent edit changes a file after it was read; the assistant must reject, re-read, or merge rather than overwrite.”

Follow [TESTING.md](../TESTING.md).

## Evidence and handoff

Pending. Record tool schemas, path/security policy, changed files, deterministic results, bake-off results, and remaining limitations. Update [STATUS.md](../STATUS.md), [README.md](../README.md), and the task catalog if the coding mode changes task classification.
