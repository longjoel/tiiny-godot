# Tiiny Godot workspace assistant — design draft

## Purpose

The assistant is a Godot workspace operator: a natural-language interface to editor operations, resources, and specialized models. Think of it as a powerful, context-aware macro that can inspect the project, plan a sequence of editor actions, execute them, and explain the results. It is not primarily a general coding agent. A separate coding agent can still work on project files in parallel.

Prefer native Godot features and editor operations. For scripts added to the user’s game, generate or change GDScript only when the requested behavior cannot reasonably be achieved with built-in nodes, resources, signals, animations, or other workspace tools. Explain when a gameplay script is necessary and why. Internal asset generators may freely use small, disposable Godot scripts executed outside the editor process; these are build machinery, not gameplay behavior.

## User experience

The user asks in the Tiiny Chat side dock, for example: “Make this torch flicker.” The assistant inspects the selected node and scene, identifies a suitable built-in solution, and reports the intended operations and their results as it works. If an AnimationPlayer and property tracks are appropriate, it creates and configures them through editor operations. If the target or desired behavior is ambiguous, it asks for the missing information.

The assistant should show meaningful actions such as “Inspected Torch/Light2D,” “Created AnimationPlayer,” or “Assigned PhysicsMaterial,” with the affected scene or resource. It should never claim an action succeeded unless the corresponding tool returned success. Generated assets and changed scenes should be easy to inspect in the normal Godot workspace.

## Persistent FIFO jobs and asset workers

Users, the assistant, and supported generator scripts append jobs to one durable queue. Run exactly one job at a time in accepted order. Example: append `create_tree`, then append `attach_tree_to_scene` with an explicit reference to the tree artifact. Validation and required import/application complete before the next job starts. Failure stops the queue; later jobs do not run on missing outputs.

Scripts may append at the tail but cannot wait for appended work, insert ahead, or reorder accepted jobs. Pause stops new dispatch; retry uses a new attempt at the stopped position; skipping is an explicit recorded decision. Cancel does not undo completed effects. Persist order, attempts and results; reconcile interrupted work before resuming after restart.

Temporary generators run in isolated working storage and a reviewed headless worker, with explicit outputs and budgets. Final assets enter the project after validation. Separate processes isolate crashes but are not filesystem sandboxes. This first version has no dependency graphs, priorities, parallel lanes, or nested scheduling. See [story 02](../../plan/work-items/02-integration-job-manager.md).

## Execution model

1. **Understand:** Identify the user's intent and relevant editor context. Ask for clarification when a required target or outcome is ambiguous.
2. **Inspect:** Use tools to read actual scene structure, node and resource types, properties, existing connections, and other relevant project state. Do not infer paths or properties from names alone.
3. **Plan:** Choose native Godot operations first. The model may combine multiple tools and specialized models, but each step must use an implemented capability.
4. **Execute:** The editor validates and executes typed operations. A model response is untrusted input to these tools, not executable editor code.
5. **Report and verify:** Show what changed, surface validation errors, and, when appropriate, run or inspect the scene. Report any partial work and limitations.

The system prompt should express these preferences. Tool schemas and runtime validation carry the precise rules; do not rely on prompt instructions as the only enforcement. The existing built-in prompt and optional extra instructions are in `editor/tiiny_ai_dock_source.h` and Editor Settings respectively. Project-specific conventions can be added later through an explicit project-instructions mechanism.

## Workspace tool library

Tools should expose Godot concepts and return structured results, including identifiers, affected objects, errors, and whether an operation was applied. Initial candidates:

| Area | Tools and intended behavior |
| --- | --- |
| Context | Get the edited scene, selected nodes, scene tree, node classes, paths, and relevant ownership. Inspect supported properties, values, resource types, and signal connections. |
| Scene edits | Create a node of a validated class, set a compatible property, assign a resource, and remove or reparent nodes when requested. Preserve scene ownership and editor conventions. |
| Resources | Discover a requested resource class, create a supported resource, validate its properties, save it when requested, and assign it to a compatible property. Resource generation may call specialized models when an adapter exists. |
| Animation | Inspect animations and tracks; create or modify an AnimationPlayer, animations, and property tracks through Godot APIs. |
| Import and assets | Generate an image, convert an image to 3D, import outputs, inspect import results, and assemble resources. Each stage reports its actual output; unsupported stages are not advertised as working. |
| Run and debug | Run or stop a scene; inspect errors, breakpoints, stack frames, variables, and the live scene when the debugger integration supports them. |
| Scripts | Inspect scripts as context. Create or edit GDScript when native features are insufficient, with validation and visible results. |

Operations that modify the edited scene should go through Godot's editor undo/redo mechanisms. The executor should group a coherent, validated set of scene edits into an undoable action, and clearly distinguish scene undo from filesystem operations and imported asset creation, which may need separate recovery. Avoid presenting an entire multi-step workflow as atomic unless all steps actually have transactional rollback.

## Resource workflows and model roles

A resource workflow is a typed recipe, not just a model name. It defines input requirements, model roles, intermediate artifacts, validation, Godot conversion/import, and final outputs. For example, a future image-to-3D workflow could generate or accept a reference image, call an image-to-3D model, import its GLB, and expose the resulting mesh and materials. Each stage must check the device and model capability, report errors, and preserve enough information to understand what was produced.

The coding model coordinates; the Tiiny model manager chooses and loads specialized models according to their configured roles. The required coding model should remain warm, while user-selected models stay warm when possible. On-demand swapping, downloads, recovery after reconnect, and memory checks require further implementation; the current manager does not provide the complete scheduling behavior yet.

## First workspace milestone after the job foundation: an undoable scene operation

Build an end-to-end path for one edited scene:

1. Inspect the edited scene and selected node, returning stable scene-relative paths, classes, and relevant property information.
2. Accept a typed request to create a node under a valid parent, set compatible properties, create a supported resource, and assign it to a compatible property.
3. Validate the entire proposed scene change against the current scene before committing: node and resource classes, paths, ownership, writable properties, value types, and resource compatibility.
4. Commit the scene changes as one editor undo/redo action. Report the affected nodes and properties. If validation fails, make no scene changes.
5. Allow the user to undo and redo the operation using Godot's normal editor controls, and verify both the visible scene and resource assignments.

A suitable test case is adding a `CollisionShape2D` under an appropriate selected physics node, creating a compatible `RectangleShape2D`, assigning it, and setting its dimensions. The executor must reject an invalid parent, non-existent property, incompatible resource, or stale target without making a partial scene edit.

The milestone does not need GDScript generation, model-generated meshes, or autonomous runtime debugging. Keep the existing chat and resource experiments clearly marked as prototypes until they use the validated workspace path.

## Verification

Use focused tests for type and path validation, scene ownership, no partial changes on failure, and undo/redo. Exercise the full flow in a running editor with a small test project and a real Tiiny model. Confirm that the model sees only tools that are implemented and available, that errors are returned to it, and that the chat describes actual outcomes. Test the core executor independently of model inference so model variability does not mask editor bugs.

## Current state

The repository contains an early Tiiny chat and model manager, a resource-dialog experiment for `ConvexPolygonShape2D`, and prototype image and new-script tools. The persistent job manager, isolated generator workers, typed scene-edit executor, grouped undo/redo, animation workflows, live debugger tools, and complete specialized-model scheduler described here are not implemented by this draft.
