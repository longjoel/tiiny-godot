# Story 02 — FIFO queue diagrams

Design artifacts only. See the [plan](../implementation/02-job-manager.md) and [Jobs mockup](02-jobs-panel.html).

## Submission and execution

```mermaid
flowchart LR
    U[User / assistant / supported script] --> A[Validate and persist append]
    A --> Q[Ordered queue]
    Q --> W[One executing job]
    W --> V[Validate outputs and import/apply]
    V --> C[Record completion]
    C --> Q
    W --> F[Failure: stop queue]
    V --> F
```

## Tree example

```mermaid
sequenceDiagram
    participant S as Submitter
    participant Q as Durable queue
    participant G as Godot worker
    participant E as Editor
    S->>Q: Append create_tree
    Q-->>S: Job 101, position 1
    S->>Q: Append attach_tree_to_scene using job 101 artifact
    Q-->>S: Job 102, position 2
    Q->>G: Run 101
    G-->>Q: Staged tree artifact
    Q->>E: Validate and import tree
    E-->>Q: Verified asset
    Q->>Q: Persist 101 completed
    Q->>E: Run 102, validate scene and artifact, attach tree
    E-->>Q: Actual result
    Q->>Q: Persist 102 completed
```

If job 101 fails, job 102 stays queued. Retry happens at the stopped position; it is not appended behind the attachment. A script may append further work, but it goes behind every job already accepted. The current script must finish without waiting for that work.

## Editor presentation

Jobs is a bottom panel: queue controls, ordered job list, selected-job details/logs/artifacts. Chat links to job IDs. There are no priority controls, parallel lanes, or dependency graphs in the first version. Pause prevents the next start; cancel stops the queue after resolving the current worker; completion includes required import/application.
