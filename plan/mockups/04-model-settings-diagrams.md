# Story 04 — Models screen diagrams

Design artifacts only. See the [implementation plan](../implementation/04-model-settings.md) and the [interactive mockup](04-model-settings.html).

## Staged configuration

```mermaid
stateDiagram-v2
    [*] --> Unrefreshed
    Unrefreshed --> Fresh: Refresh succeeds
    Fresh --> Stale: 60s snapshot lifetime
    Stale --> Fresh: Refresh succeeds
    Fresh --> Draft: Change a role, context, warm, or reserve
    Draft --> Draft: More edits (plan stays invalid)
    Draft --> Checked: Check Config passes
    Checked --> Draft: Any draft edit
    Checked --> Expired: 60s plan lifetime
    Expired --> Draft: Check Config again
    Checked --> Applying: Apply
    Applying --> Applied: Every operation verified
    Applying --> Partial: Failure or unknown device state
    Partial --> Draft: Refresh, review, Check again
    Fresh --> Unavailable: Disconnect / auth / capacity failure
    Stale --> Unavailable: Disconnect / auth / capacity failure
    Unavailable --> Fresh: Explicit Refresh succeeds
```

A checked plan is never reused after a draft edit, expiry, connection change, or device-state change. Apply revalidates before the first operation.

## Apply sequence

```mermaid
sequenceDiagram
    participant U as User
    participant P as Models panel
    participant M as Manager
    participant J as Job device lease
    participant D as Tiiny device

    U->>P: Check Config
    P->>M: check_config()
    M->>J: acquire device lease
    M->>D: Read catalog, loaded models, NPU, SSD
    D-->>M: Snapshot
    M->>J: release lease
    M-->>P: Plan (actions, errors, warnings)
    U->>P: Apply
    P->>M: apply_config()
    M->>M: Verify draft unchanged and check unexpired
    M->>J: acquire device lease
    M->>D: Revalidate snapshot and plan
    loop Each ordered action
        M->>D: Download / load / unload
        D-->>M: Progress and terminal output
        M->>D: Re-read device state
        alt Verified
            M->>M: Record operation complete
        else Failed or unknown
            M->>M: Stop plan, keep partial results
            M->>J: release lease
            M-->>P: Failure with completed operations
        end
    end
    M->>D: Final warm-set verification
    M->>M: Persist applied configuration
    M->>J: release lease
    M-->>P: Applied and verified
```

## Capacity accounting

```mermaid
flowchart LR
    subgraph NPU["NPU allocation units"]
        L[Loaded models] --> K[Keep-loaded targets]
        K --> O[Unattributed overhead]
        O --> R[Reserve]
        R --> F[Free]
    end
    subgraph SSD["SSD bytes"]
        D[Downloaded bytes] --> N[Missing downloads]
        N --> S[Largest-download staging allowance]
        S --> Q[Reserve]
        Q --> G[Free]
    end
```

Projected values come from the pure planner. Unknown sizes or NPU units produce errors, never zero. NPU units are not physical RAM; SSD forecasts include one staging allowance.

## Role capability matrix

| Role | Accepted catalog type | Extra requirement | Empty-state explanation |
| --- | --- | --- | --- |
| Scripting | Text Generation, Image-Text-to-Text | `Tool Use` | "Choose a scripting model with Tool Use; none in this catalog." |
| Image generation | Text-to-Image | — | "No Text-to-Image model in this catalog." |
| Image to 3D | Image-to-3D | — | "No Image-to-3D model in this catalog." |
| Music | Music Generation | — | "No Music Generation model in this catalog." |
| Text to speech | Text-to-Speech | — | "No Text-to-Speech model in this catalog." |

No sound-effects role exists. A role never claims support the catalog does not declare.

## Freshness and error states

| State | Capacity display | Check Config | Apply | Primary action |
| --- | --- | --- | --- | --- |
| Fresh | Live values, age < 60s | Enabled | Per plan | Edit or Check |
| Stale | Dimmed historical values, `Stale · 78s` | Disabled | Disabled | Refresh |
| Unavailable | `—`, last known values marked historical | Disabled | Disabled | Refresh or fix Advanced |
| Auth failure | `—` | Disabled | Disabled | Fix API key, Refresh |
| Capacity failure | Live values with shortfall | Enabled, plan errors | Disabled | Adjust roles/reserves |
| Applying | Live, progress shown | Disabled | Disabled | Wait or Cancel current operation |
| Partial failure | Refreshed values | Enabled | Disabled until re-check | Review partial results, Refresh, Check |

## Download progress and completion

```mermaid
flowchart TD
    A[Select a not-downloaded model] --> B[Check Config]
    B --> C[Plan: Download, Load]
    C --> D[Apply]
    D --> E[Progress: device percentage + elapsed]
    E --> F{CLI exit 0?}
    F -- No --> X[Stop plan: partial results]
    F -- Yes --> G{Device reports installed?}
    G -- No --> X
    G -- Yes --> H{Load verified and NPU matches?}
    H -- No --> X
    H -- Yes --> I[Persist configuration]
```

Progress alone never establishes completion. A stall warning is informational; verification is the gate.
