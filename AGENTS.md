# Tiiny Godot development guidance

## Overall goal

Build a Godot-native workspace assistant powered exclusively by the user's Tiiny device. Treat the assistant as a powerful, context-aware editor macro: inspect the workspace and operate on scenes, nodes, resources, signals, animations, imports, and debugger state using typed Godot tools. Prefer native editor capabilities; create or edit GDScript as a last resort. A separate coding agent may edit files in parallel. Disposable internal Godot scripts for asset construction are allowed; keep them in isolated job working storage rather than adding them to the game as behavior scripts.

The coding model coordinates specialized model workflows. Keep it warm; let users choose other warm models. Godot may manage the Tiiny exclusively, including downloads and unloading models, while preserving the required coding model whenever the device is available.

## Stay focused on work in progress

Read `plan/README.md`, `plan/STATUS.md`, and the active work item before changing code. Follow the listed sequence and dependencies. Finish and verify the active item's acceptance criteria before moving to a new feature. Keep changes scoped to that item; unrelated discoveries belong in `plan/IDEAS.md`.

The user describes a tendency to be distracted by shiny things. Help maintain momentum: record attractive new ideas, briefly explain their place in the roadmap, and return to the active item. A speculative suggestion or exploratory question does not automatically replace the active milestone. Explicit user instructions always take precedence; if the user redirects the work, update the plan and record what remains unfinished.

Keep `plan/STATUS.md` current with the active item, blockers, verification evidence, and next action. Mark work done only when all acceptance criteria pass; distinguish implemented, compiled, runtime-tested, and device-tested. Do not expand scope to hide unfinished work. Do not delegate unless the user or other applicable instructions authorize delegation.

## Long-running work

The persistent job manager (plan item 02) is the first foundational feature after prototype stabilization. Use it for append-only user/AI/script work, strict FIFO execution with one current job, progress, artifacts, and recovery. Failures stop dispatch; do not add graph scheduling, priorities, or parallel lanes to the first version. Specialized model and generator integrations must extend its interfaces rather than introduce competing queues. Generated asset workers and editor scene mutations have distinct lifecycles; validate outputs before promotion and revalidate workspace targets before applying changes.

## Implementation and verification

- Inspect existing Godot APIs and project code before inventing abstractions. Keep scene mutations typed, validated, and undoable where supported.
- Keep model capability, tool availability, and workflow completion distinct. A model selector does not mean its generator is implemented.
- Return real tool results to the model. Never claim an edit, import, debugger operation, or model transition succeeded without evidence.
- Preserve user changes and coordinate any parallel file editing through current workspace state and explicit scope.
- Run focused checks appropriate to the change. Document limitations and partial failures honestly.
- Update the integration README when user-visible behavior changes. Keep proposed behavior in the design and plan documents.

## Builds

Announce every build before starting it, including its scope and command. Check for an existing build; never run concurrent SCons builds against this checkout's shared artifacts. Track the process/session, report completion or failure, and explicitly state when a build remains running. Use consistent build options and sensible parallelism for available CPU and memory. Do not interrupt a build casually: previous interruptions left incomplete artifacts. A documentation-only task does not require a build.

## Product organization

Configuration belongs under Editor Settings > Tiiny AI: Models and Advanced. Advanced combines connection, device, prompt, and request settings. The working conversation belongs in the Tiiny Chat side dock. Do not reintroduce standalone Tiiny Assistant or Tiiny Models tabs in Editor Settings. Expose meaningful progress in chat and Output. Avoid embedding implementation details in ordinary user flows.
