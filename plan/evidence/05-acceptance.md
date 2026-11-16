# Story 05 — acceptance evidence

Story 05 is accepted. The embedded read-only inspector exposes the seven planned tools through `definitions()` and `execute(name, arguments, turn_context)` and is injected into the chat dock as a script, but is not advertised to the model. No scene, resource, undo, project-file, or device mutation is performed.

Executable: `bin/godot.linuxbsd.editor.x86_64`, version `4.8.beta.custom_build.da3b7c67a`. Final build PID 756396 exited 0 in 35.97s with `scons platform=linuxbsd target=editor use_static_cpp=no -j8`. No build remains running.

## Criterion matrix

| Criterion | Evidence |
| --- | --- |
| Scene identity, scene-relative identifiers, classes, ownership | The editor fixture opens authored, instanced, and inherited scenes and checks paths, classes, `owner`, `scene_file_path`, and instance metadata. The pure fixture checks root `.` identity and ownership paths. |
| Godot types and supported writable properties, bounded | The pure fixture inspects `Vector2` position/type/writability, filters category/secret/metadata properties, truncates property lists, and inspects embedded and saved `RectangleShape2D` resources. A 500-node tree is trimmed under the 16 KiB result budget with a truncation flag. |
| No scene, empty selection, deleted target, scene switching | The pure fixture returns `no_scene`, `scene_not_saved`, `scene_unreadable`, `history_unavailable`, `invalid_path`, `target_missing`, and an empty successful selection. The editor fixture verifies `target_missing` after deletion and `stale_scene` after a scene switch and after a dirty/undo revision change. |
| Inspection does not mutate scene/project | The editor fixture compares the scene file hash, root child count, and undo version before and after every tool call. It also confirms inspection does not mark the scene dirty. |
| Inherited/instanced nodes and edited-vs-running scene | The editor fixture traverses an instanced child scene, opens an inherited scene, and starts a separate running scene; inspection still returns the edited scene and labels `playing: true` with `edited_scene_only: true`. |

## Runs

| Check | Result | Log/report |
| --- | --- | --- |
| Pure inspector suite | Passed, 0 failures | `/tmp/tiiny-story05-pure-final.log` |
| Editor integration fixture | Passed, including running-scene isolation | `/tmp/tiiny-story05-editor-final.log` |
| Existing editor smoke and restart stages | Passed, 11/11 stages | `/tmp/tiiny-story05-final3.json` |
| Built-in Jobs regression | Passed, all 25 modes | `/tmp/tiiny-story05-jobs-final.log` |
| Build | Exit 0, 35.97s | `/tmp/tiiny-story05-build5.log` |

## Runtime API decisions

A disposable editor probe established:

- Scene history is `get_object_history_id(root)` (history 1 in the probe), not history 0.
- `UndoRedo.get_version()` changes on commit/undo/redo (`1 → 2 → 1 → 2`) while `get_history_count()` stays 1. Session revisions use `undo:<version>`.
- `get_unsaved_scenes()` returns `res://` paths.
- `is_editable_instance(root)` errors because the root is not its own ancestor; the root is always `editable: false`.
- `get_scene_instance_state()` and `get_scene_inherited_state()` are not exposed to GDScript in this build; the provider uses `scene_file_path` and `owner` instead.
- `get_children(false)`/`get_child_count(false)` exclude internal children by default; `is_internal()` itself is not exposed.

## Remaining boundaries

- Story 07 owns registry composition, availability snapshots, prompt exposure, and the model tool ledger. Story 05 does not advertise the tools to the model.
- No generic search, mutation, debugger, or running-scene-value tools are included; those are later stories.
- Property getters are read best-effort; GDScript cannot reliably catch every native getter error.
- Inherited base-source paths and an explicit internal-node flag are unavailable through the scripting API in this build; `scene_file_path`, `owner`, and `include_internal` are used instead.
