# Story 07 — tool orchestration diagrams

Design artifacts only. See the [implementation plan](../implementation/07-orchestrator.md).

## One turn

```mermaid
sequenceDiagram
    participant U as User
    participant D as Chat dock
    participant R as Tool registry
    participant M as Coding model
    participant T as Tool executor
    participant E as Editor

    U->>D: Request
    D->>R: Build turn snapshot
    R-->>D: Available definitions + capability summary
    D->>M: System policy + context + tools
    M-->>D: Assistant text or one tool call
    alt Final text
        D-->>U: Text + action ledger
    else Tool call
        D->>D: Envelope and schema validation
        D->>T: Execute(tool, arguments, turn context)
        T->>E: Revalidate scene identity and domain facts
        alt Valid
            E-->>T: Apply / inspect
            T-->>D: Structured result + affected + undo group
        else Invalid or failed
            T-->>D: Error result (no mutation)
        end
        D->>D: Append ledger entry and tool message
        D->>M: Continue with tool result
    end
```

## Turn state

```mermaid
stateDiagram-v2
    [*] --> Assembling
    Assembling --> WaitingModel: payload accepted
    WaitingModel --> Executing: one valid tool call
    WaitingModel --> Complete: final assistant text
    WaitingModel --> ProtocolStop: multiple calls / duplicate ID / limit
    WaitingModel --> RecoverableError: unknown tool / bad arguments / tool error
    RecoverableError --> WaitingModel: budget remains
    Executing --> WaitingModel: structured result
    Executing --> RecoverableError: validation or execution failure
    Executing --> Cancelled: user stop
    WaitingModel --> Cancelled: user stop before next call
    Complete --> [*]
    ProtocolStop --> [*]
    Cancelled --> [*]
```

Every terminal path keeps the action ledger and a matching tool result for every executed call. The next turn starts from `Assembling` with no in-flight state.

## Registry and availability

```mermaid
flowchart TD
    A[Turn starts] --> B{Edited scene open?}
    B -- No --> C[Omit workspace tools]
    B -- Yes --> D[Add read tools: saved or dirty]
    D --> E{Saved, clean scene + resolvable target?}
    E -- Yes --> F[Add scene recipe]
    E -- No --> G[Recipe unavailable: explain save/dirty/target]
    A --> H{Coding model has Tool Use?}
    H -- No --> I[Send no tools; text-only reply]
    H -- Yes --> J[Attach capability summary]
    A --> K{Warm image model loaded?}
    K -- Yes --> L[Add generate_image]
    K -- No --> M[Omit and explain]
    A --> N{Jobs service available?}
    N -- Yes --> O[Add job tools]
    N -- No --> P[Omit and explain]
```

Unavailable tools never appear in the HTTP `tools` array. The capability summary is the only place they are named.

## Validation pipeline

```mermaid
flowchart LR
    A[Model response] --> B[Envelope]
    B --> C[Registry lookup]
    C --> D[Schema]
    D --> E[Domain revalidation]
    E --> F[Execute]
    F --> G[Postcondition]
    G --> H[Structured result]
    B --> X[Protocol stop]
    C --> Y[Tool error]
    D --> Y
    E --> Y
    F --> Y
    G --> Y
```

Envelope failures (multiple calls, duplicate ID, limit) stop the turn. Recoverable failures return a tool error and let the model correct within the budget. Domain validation always runs, even when the schema passes.

## Recipe-first

```mermaid
flowchart TD
    A[Request: add rectangular collision shape] --> B{Recipe tool available?}
    B -- Yes --> C[Call recipe once]
    C --> D[Validate target, class, ownership, resource]
    D --> E[Commit one undo action]
    E --> F[Return undo group + affected nodes]
    B -- No --> G[Explain missing capability]
    F --> H[Final text + ledger]
```

The recipe is one tool call and one undo action. Story 06 turns it into typed operations through a generic transaction executor; the orchestrator does not decompose it into primitive edits in 07.

## Ledger

| Field | Purpose |
| --- | --- |
| `turn` | Groups calls for the current request |
| `call` | Model call ID, echoed in the tool message |
| `tool` | Registry name |
| `ok` | Executor outcome, not model prose |
| `summary` | Human-readable result for chat |
| `affected` | Scene paths, node paths, resources |
| `undo_group` | Editor undo identity when applicable |
| `error` | Stable code and field, when failed |

The ledger is displayed with the final answer and retained for story 08's action history. Acceptance checks read the ledger and editor state, not the assistant's wording.
