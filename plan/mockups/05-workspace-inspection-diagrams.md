# Story 05 — workspace inspection diagrams

Design artifacts only. See the [implementation plan](../implementation/05-workspace-inspection.md) and the [story 07 tool contract](../implementation/07-orchestrator.md).

## Inspection call

```mermaid
sequenceDiagram
    participant C as Caller (07 registry / fixture)
    participant I as Workspace inspector
    participant E as Editor
    participant S as Edited scene

    C->>I: execute(tool, arguments, turn_context)
    I->>I: Validate schema and arguments
    I->>E: Read edited scene root and revision
    alt No scene
        I-->>C: no_scene
    else Scene unsaved or missing scene_file_path
        I-->>C: scene_not_saved
    else Scene changed since turn_context
        I-->>C: stale_scene
    else Scene matches
        I->>S: Resolve scene-relative path
        alt Missing or outside scene
            I-->>C: target_missing / outside_scene
        else Valid target
            S-->>I: Class, owner, properties, resources, signals
            I->>I: Filter, bound, JSON-encode
            I-->>C: Structured result + revision + truncation
        end
    end
```

## Scene identity and revision

```mermaid
flowchart LR
    A[Edited scene root] --> B{scene_file_path set?}
    B -- No --> D[scene_not_saved]
    B -- Yes --> C{path in get_unsaved_scenes?}
    C -- Yes --> D
    C -- No --> E[revision = SHA-256 of file]
    A --> F[root_instance_id]
    A --> G[selection]
    A --> H[playing = is_playing_scene]
    E --> I[Turn context binds path + revision + root id]
    I --> J{Later call matches?}
    J -- No --> K[stale_scene]
    J -- Yes --> L[Resolve paths]
```

The running remote scene is never used. `edited_scene_only` is always true; runtime/debugger values belong to story 12. Saved scenes are required: unsaved scenes cannot be inspected or planned against.

## Node identity and ownership

```mermaid
flowchart TD
    R[Edited scene root .] --> A[Authored node]
    R --> B[Instanced scene root]
    B --> C[Node inside instance]
    A --> D[owner = .]
    B --> E[owner = . / scene_file_path = res://child.tscn]
    C --> F[owner = instanced root path]
    C --> G[scene_file_path = res://child.tscn]
    R --> H[Inherited root: scene_file_path = inherited scene]
```

`owner` and `scene_file_path` are separate. Paths are scene-relative and stable within the scene; instance IDs are session diagnostics only.

## Path resolution and errors

```mermaid
flowchart TD
    A[path argument] --> B{Absolute, empty, or contains ..?}
    B -- Yes --> X[invalid_path]
    B -- No --> C[Resolve from edited scene root]
    C --> D{Node exists?}
    D -- No --> Y[target_missing]
    D -- Yes --> E{Under edited root?}
    E -- No --> Z[outside_scene]
    E -- Yes --> F[Inspect]
    A2[No edited scene] --> W[no_scene]
    A3[Scene changed since turn] --> V[stale_scene]
```

No selection is an empty state, not an error. A deleted target is never replaced by the current selection.

## Property filtering and encoding

```mermaid
flowchart LR
    A[get_property_list] --> B{EDITOR or STORAGE?}
    B -- No --> X[Skip]
    B -- Yes --> C{INTERNAL / CATEGORY / GROUP / SUBGROUP / SECRET?}
    C -- Yes --> X
    C -- No --> D[Read type, hint, usage, class_name]
    D --> E[Read bounded value]
    E --> F{Value kind}
    F -- Primitive --> G[JSON value]
    F -- Vector/Color/Rect --> H[String summary]
    F -- Node --> I[Class + path]
    F -- Resource --> J[Class + path + name]
    F -- Unsupported --> K[Class marker]
    G --> L[Property entry]
    H --> L
    I --> L
    J --> L
    K --> L
```

Writability is a hint: not `READ_ONLY`, not a category/group, and a setter exists where known. Story 06 revalidates before writing.

## Bounds

| Surface | Default | Maximum | On limit |
| --- | --- | --- | --- |
| Scene tree depth | 4 | 8 | `truncated.depth` |
| Scene tree nodes | 200 | 500 | `truncated.nodes` |
| Node properties | 80 | 200 | `truncated.properties` |
| Resource properties | 60 | 120 | `truncated.properties` |
| Signal connections | 50 | 100 | `truncated.connections` |
| String value | 512 chars | — | Suffix marker |
| Array/dictionary | 64 entries | — | Suffix marker |
| Result JSON | — | 16 KiB (07 cap) | Truncate and flag |

## Read-only boundary

```mermaid
flowchart LR
    A[Inspector] --> B[Getters only]
    B --> C[Scene tree, properties, resources, signals]
    A -. forbidden .-> D[set / add_child / remove_child]
    A -. forbidden .-> E[ResourceSaver / FileAccess write]
    A -. forbidden .-> F[UndoRedo commit]
    A -. forbidden .-> G[EditorInterface play/stop or debugger]
    C --> H[Verify hash, node count, values, undo history unchanged]
```

Story 05 reports the edited scene. It does not inspect the running remote scene, set breakpoints, or change editor state.
