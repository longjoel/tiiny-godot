# Tiiny Godot implementation plan

Build the workspace assistant described in [the design draft](../integrations/tiiny/WORKSPACE_ASSISTANT.md). The primary interaction is a request that becomes validated Godot editor operations, with gameplay GDScript as a fallback. Internal asset generators run through the early job-manager foundation.

Read [STATUS.md](STATUS.md) first. Each work item records its feature, sequence, stream, dependencies, scope, and acceptance criteria. Sequence is the default execution order; dependencies are required gates. Streams describe the kind of work, not permission to start parallel work. Maintain one active item unless the user explicitly authorizes independent parallel work.

| Sequence | Feature | Stream | Item |
| --- | --- | --- | --- |
| 01 | Stabilize the existing prototype | integration | [01](work-items/01-integration-stabilize.md) |
| 02 | Persistent FIFO jobs and execution visibility | integration | [02](work-items/02-integration-job-manager.md) |
| 03 | Device binding and protected coding-model lifecycle | device | [03](work-items/03-device-lifecycle.md) |
| 04 | Model roles, installed inventory, and warm selections | ui | [04](work-items/04-ui-model-settings.md) |
| 05 | Read-only Godot workspace tools | workspace | [05](work-items/05-workspace-inspection.md) |
| 06 | Typed scene edits with grouped undo/redo | workspace | [06](work-items/06-workspace-transactions.md) |
| 07 | Workspace-first prompt and tool orchestration | integration | [07](work-items/07-integration-orchestrator.md) |
| 08 | Chat action history, previews, and recovery | ui | [08](work-items/08-ui-chat-actions.md) |
| 09 | Typed resource recipes and image generation | assets | [09](work-items/09-assets-resource-library.md) |
| 10 | On-demand specialized-model scheduling | device | [10](work-items/10-device-scheduling.md) |
| 11 | Animation and physics workflows | workspace | [11](work-items/11-workspace-macros.md) |
| 12 | Paused execution, live scene inspection, and breakpoints | debugger | [12](work-items/12-debugger-tools.md) |
| 13 | Multi-model 3D and audio recipes | assets | [13](work-items/13-assets-composition.md) |

Completion requires recorded evidence for every acceptance criterion. If a criterion proves too broad, split the item and record the changed scope before proceeding. Keep proposed extras in [IDEAS.md](IDEAS.md); do not silently add them to active work.

Use [ACCEPTANCE_SCENARIOS.md](ACCEPTANCE_SCENARIOS.md) for concrete workspace outcomes and [TESTING.md](TESTING.md) for deterministic, editor, device, and model-evaluation layers. These supplement the criteria on each work item.

Story 01 is accepted. Its [implementation plan](implementation/01-stabilize-prototype.md) and [completion evidence](evidence/01-completion.md) record the verified prototype, displayed editor checks, and real Tiiny chat/polygon results. Story 04 is now accepted separately; see its [acceptance evidence](evidence/04-acceptance.md).

Story 02 has an [implementation plan](implementation/02-job-manager.md), [interactive Jobs mockup](mockups/02-jobs-panel.html), and [diagrams](mockups/02-job-manager-diagrams.md). Story 01's gate is satisfied; story 02 has 9 of 10 criteria verified (displayed editor and Tiiny device coordination deferred). Story 03 has an [implementation plan](implementation/03-device-lifecycle.md) and is accepted. Real coding inference and a download-only device mutation were verified; real mutating restoration and a warm-set-changing load/unload were explicitly skipped because the device's kept set leaves no NPU headroom. See [acceptance evidence](evidence/03-acceptance.md). Story 04 depends on story 03 and is accepted: state accessors, freshness gating, role explanations, operation progress, plan expiry, bounded partial results, copyable Info, displayed 1400/600 px captures, applied-vs-unapplied restart persistence, and one real download-only Apply with an unchanged warm set. See its [implementation plan](implementation/04-model-settings.md), [interactive Models mockup](mockups/04-model-settings.html), [state diagrams](mockups/04-model-settings-diagrams.md), and [acceptance evidence](evidence/04-acceptance.md). Story 05 is accepted: its reviewed [implementation plan](implementation/05-workspace-inspection.md) and [inspection diagrams](mockups/05-workspace-inspection-diagrams.md) are implemented by an embedded read-only provider, with pure and editor fixtures and an acceptance report. Story 06 is accepted: its [implementation plan](implementation/06-workspace-transactions.md) and [transaction diagrams](mockups/06-workspace-transactions-diagrams.md) implement a class-agnostic transaction executor plus recipes, with the collision shape as the first product recipe and Marker/Capsule genericity fixtures. Story 07 is accepted: its [implementation plan](implementation/07-orchestrator.md) and [tool orchestration diagrams](mockups/07-tool-orchestration-diagrams.md) implement the unified registry, schema/availability validation, structured results, turn ledger, workspace-first prompt, structured chat dispatch, and recipe-first execution. A live Ornith run added and undid the collision shape; see [story 06 acceptance](evidence/06-acceptance.md) and [story 07 acceptance](evidence/07-acceptance.md).
