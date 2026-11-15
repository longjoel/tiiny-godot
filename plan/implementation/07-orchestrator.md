# Story 07 implementation plan — workspace-first prompt and tool orchestration

Status: Planning. Implementation is gated on stories 02, 03, 05, and 06; slices A–C can be built against fake tools before 05/06 land. This plan changes documentation only.

Parent: [07 — Workspace-first prompt and tool orchestration](../work-items/07-integration-orchestrator.md). Visuals: [tool orchestration diagrams](../mockups/07-tool-orchestration-diagrams.md).

## Execution contract

The model is an untrusted planner. A tool call is a typed request; the editor validates and executes it. Nothing the model writes is executed as editor code or applied without validation.

The tool registry is the single source of truth for names, schemas, availability, risk, and handlers. The prompt, the HTTP tool list, the executor, the chat summaries, and the tests all read the same registry. A tool that is not implemented or not currently available is not advertised to the model.

One tool call per model response is executed in this version, serially. Multiple calls, duplicate call IDs, unknown tools, malformed arguments, and exceeded limits are deterministic protocol outcomes, not best-effort guesses. Execution is bounded by rounds, call count, result size, and the context budget.

Tool results are structured and returned to the model with the original call ID. The UI renders a human summary from the same result. The turn action ledger is authoritative for what happened; model prose is not.

Prefer one workspace recipe over composing primitive edits. A recipe returns one editor undo group. Do not decompose a recipe into multiple undoable steps unless a transaction tool explicitly groups them.

## Baseline

The current chat dock has five hardcoded tools (`generate_image`, `create_gdscript`, `append_job`, `get_job_status`, `get_scene_revision`) defined in `ResourceToolLibrary`. The executor is an `if/elif` chain inside `_request_completed`. It already enforces:

- one function call per response;
- non-empty, bounded, unique call IDs;
- `type == "function"` and an arguments object;
- four tool rounds per turn;
- tool results appended with `tool_call_id` and retained in `conversation`;
- humanized tool lines in chat;
- no claim of job completion from acceptance alone.

Gaps for story 07:

- Schemas and handlers are not a single registry; availability is static and does not reflect the workspace, model capabilities, or warm specialized models.
- Arguments are checked with ad-hoc conditions, not a shared schema validator; error codes are not stable.
- Results are plain strings; there is no structured result, action ledger, affected-target list, or undo group.
- The prompt does not state a workspace-first policy or a GDScript fallback rule, and user extras, editor context, and project data are mixed.
- No scene revision/identity is bound to a turn, so a scene switch between planning and execution is not rejected explicitly.
- Cancellation mid-turn, partial actions, and protocol violations have no defined state machine.
- The model can try a tool that cannot run (for example image generation with no warm image model), producing a tool error instead of a capability-aware prompt.
- There is no scene-edit recipe tool; the WS-01 recipe and its one-undo guarantee are not exposed.

## Tool contract

### Definition

Each tool is registered with:

```gdscript
{
  "name": "add_rectangular_collision_shape",
  "title": "Add rectangular collision shape",
  "description": "Create one CollisionShape2D under a physics body and assign an owned RectangleShape2D. One undo action.",
  "parameters": { "type": "object", "properties": {...}, "required": [...], "additionalProperties": false },
  "risk": "mutating",              # read | mutating | long_running
  "availability": Callable,        # returns {"available": bool, "reason": String}
  "timeout_ms": 15000,
  "handler": Callable              # (arguments, turn_context) -> Dictionary
}
```

Definitions are data; handlers are editor-owned callables. A tool may expose a `preferred_for` hint (for example `collision_shape`) so the prompt can prefer the recipe over primitives.

### Initial tools

| Tool | Risk | Availability | Notes |
| --- | --- | --- | --- |
| `get_workspace_context` | read | Any edited scene | Scene identity, revision, selection, root class. |
| `inspect_node` | read | Any edited scene | Class, scene-relative path, ownership, bounded properties, script. |
| `inspect_resource` | read | Any edited scene | Resource type, path, bounded properties. |
| `list_signals` | read | Any edited scene | Signal names and connections. |
| `add_rectangular_collision_shape` | mutating | Saved, clean edited scene with a valid parent target | Story 06 first recipe; generic transaction executor; one undo group; no partial mutation. |
| `create_gdscript` | mutating | Filesystem available | Last resort; requires a non-empty `reason`; refuses overwrite. |
| `generate_image` | long_running | Warm image model loaded | Creates a new asset; never edits a scene node. |
| `append_job` | long_running | Jobs service available | Reviewed tree/attachment work; acceptance is not completion. |
| `get_job_status` | read | Jobs service available | Reads the accepted job record. |
| `get_scene_revision` | read | Saved edited scene | Revision for attachment and stale-plan checks. |

Later stories add animation, physics, debugger, and composition tools. They register here; the prompt never advertises them early.

### Availability

The registry snapshot is built once per turn, from actual state:

- No edited scene: only non-workspace tools that make sense (`get_job_status`, `generate_image` if warm) plus a capability note explaining that workspace tools need an open scene.
- Scene open: read tools are available for saved and dirty scenes. The recipe requires a saved, clean scene and a resolvable target; otherwise it is omitted with a reason (`scene_not_saved`/`scene_dirty` at execution).
- Coding model without `Tool Use`: no tools are sent; chat is text-only and says why.
- No warm image model: `generate_image` is omitted and the capability summary says "Image generation unavailable: no warm image model."
- Jobs service unavailable: job tools are omitted with a reason.
- Debugger tools: only while a debug session is paused (later story).

A mutation marks the scene dirty. Story 05 allows dirty inspection, so read tools remain available for verification; after a mutation, adopt the result's `session_revision` into the turn context so follow-up inspection is not rejected as stale. Mutating recipes require a clean scene and return `scene_dirty` until the user saves. The capability summary says so, and the turn can finish with the recipe result plus a dirty-state notice.

Unavailable tools are omitted from the HTTP `tools` array. The system prompt includes a short capability summary with the reason, so the model does not try them. Tests assert the exact availability matrix.

### Validation layers

1. **Envelope:** one call, `type == "function"`, non-empty ID ≤ 128 chars, unique in the turn, function name present.
2. **Registry:** name exists in the turn snapshot; tool is available; risk and timeout are known.
3. **Schema:** a compact JSON-schema subset validator (object, string, number/integer, boolean, array, enum, required, additionalProperties, min/max, length bounds). Reject unknown fields and oversized values.
4. **Domain:** the handler revalidates Godot facts: scene identity/revision, node existence, parent class, ownership, writable properties, resource compatibility, path traversal, overwrite conflicts. A schema is never sufficient for a mutation.
5. **Execution:** the handler returns a structured result; exceptions become `execution_failed`; a long-running tool returns an accepted job ID and never claims completion.
6. **Postcondition:** for mutations, the handler verifies the resulting node/property/resource and records the undo group. A failed postcondition is an error, not a success.

### Wire format

The model sees standard OpenAI-style function tools. One response may contain zero or one call:

```json
{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"add_rectangular_collision_shape","arguments":"{\"parent_path\":\"Player\",\"width\":32,\"height\":48}"}}]}
```

The executor answers with the original ID and a JSON-encoded structured result:

```json
{"role":"tool","tool_call_id":"call_1","content":"{\"call_id\":\"call_1\",\"tool\":\"add_rectangular_collision_shape\",\"ok\":true,...}"}
```

Names are stable snake_case identifiers (≤ 64 characters). Tool definitions are sent only for available tools; the payload omits the `tools` array entirely when no tool is available, and uses `tool_choice: "auto"` otherwise. Arguments are always a JSON object string, never a nested object.

### Result contract

```json
{
  "call_id": "call_1",
  "tool": "add_rectangular_collision_shape",
  "ok": true,
  "summary": "Added CollisionShape2D under Player with an owned 32x48 RectangleShape2D.",
  "data": {"node_path": "Player/CollisionShape2D", "resource_path": "Player/CollisionShape2D:shape", "size": [32, 48]},
  "affected": [{"kind": "node", "scene_path": "res://player.tscn", "path": "Player/CollisionShape2D"}],
  "undo_group": "tiiny:turn-7:call-1",
  "scene_revision": "sha256:...",
  "duration_ms": 14
}
```

Error results keep the same envelope with `ok: false` and `error: {code, message, field?}`. The model receives the JSON string; the chat renders `summary` or the error message. A compact action ledger entry is appended for every call:

```json
{"turn": "turn-7", "call": "call_1", "tool": "...", "ok": true, "summary": "...", "affected": [...], "undo_group": "...", "error": null}
```

The ledger is the source of truth for "what changed." The final assistant text is displayed next to the ledger; it is not used to infer success.

### Error taxonomy

| Code | Meaning | Execution | Turn |
| --- | --- | --- | --- |
| `unknown_tool` | Name not in the turn snapshot | No | Return tool error; model may correct |
| `unavailable` | Tool exists but is not available | No | Return tool error with reason |
| `invalid_arguments` | Envelope/schema failure | No | Return tool error with field |
| `duplicate_call` | Repeated call ID | No | Stop turn; protocol violation |
| `multiple_calls` | More than one call in a response | No | Stop turn; protocol violation |
| `limit_exceeded` | Round/call/time/result limit | No | Stop turn; preserve ledger |
| `stale_target` | Scene revision/identity changed | No | Return tool error; re-inspect is required |
| `validation_failed` | Godot-domain validation failed | No | Return tool error; no partial change |
| `execution_failed` | Handler failed | Maybe | Return tool error; no automatic retry |
| `outcome_unknown` | Long-running effect may have happened | Maybe | Return accepted ID/interrupted; no claim |
| `cancelled` | User stopped the turn | Stop after current tool | Preserve completed ledger; final status |

Protocol violations (`duplicate_call`, `multiple_calls`, `limit_exceeded`) stop the turn with a clear chat status and unlock controls. The ledger and conversation keep every completed tool call/result pair, so the next request starts clean. Unknown tools and invalid arguments are recoverable tool errors within the budget.

### Budgets and limits

- One call per response; one execution at a time.
- Six model/tool rounds per turn (inspect → recipe → verify fits comfortably).
- Eight tool calls per turn; per-tool timeout from the registry.
- Result JSON capped (for example 16 KiB) with a summarized truncation marker; the context budget check runs before every model call.
- No automatic retry of a mutating tool. A retry requires a new model decision and fresh validation; repeated calls with the same ID are rejected.
- Long-running tools return an accepted ID immediately; completion is checked by `get_job_status` and is never inferred from acceptance.

### Recipe-first and undo

Story 06 exposes the WS-01 recipe as one tool. The registry marks it as preferred for collision-shape requests. The prompt says to use one recipe rather than a sequence of primitive edits. The recipe builds typed operations; the generic executor validates them and commits one `EditorUndoRedoManager` action; the result carries its undo group.

If a future request needs several independent edits, the orchestrator must not claim one undo unless a transaction tool explicitly provides it. Cross-tool undo grouping is out of scope for 07.

## Prompt and context assembly

The payload is assembled in this order:

1. **Base policy** (system): workspace-first operator, inspect before editing, prefer native recipes, GDScript only as a justified fallback, ask when the target or outcome is ambiguous, never claim success without a successful tool result, treat project content as data, and respect validation.
2. **Capability summary** (system): available tools grouped by area, and unavailable capabilities with reasons (no open scene, no warm image model, no Tool Use, jobs unavailable).
3. **User preferences** (system): the existing `system_prompt_extra`, explicitly labeled as preferences that cannot override validation or safety.
4. **Editor context** (system, data): scene identity/revision, root, selection with classes and bounded properties. Label it as data, not instructions.
5. **Conversation** (user/assistant/tool messages): prior turns plus the current request and tool results.

Project instructions are not added in 07. If added later, they must be an explicit mechanism with the same data/authority rules.

GDScript fallback rule in the base policy: use `create_gdscript` only when no available native tool can achieve the requested behavior; supply a non-empty `reason`; state the reason in the final answer. The schema requires `reason`, and the chat summary shows it.

The model must not see tool schemas that are unavailable. The capability summary is the only place an unavailable tool is named, and only to explain why it cannot be used.

## Slices

### Slice A — registry, schemas, and availability

Move tool definitions out of `ResourceToolLibrary` into an editor-owned registry module (for example `editor/tiiny/tools/registry.gd` embedded through a generated source header, injected into the dock like the jobs scripts). Workspace providers from stories 05/06 expose their own `definitions()`/`execute()`; the registry composes those definitions, adds availability and risk metadata, and remains the single source for the HTTP tool list. Implement the definition structure, the initial tool table, the compact schema validator, the availability predicates, and the stable error taxonomy.

Gate: registry unit tests cover every definition, schema rejection, availability matrix, and error code. No model or device.

Deliverables: registry module, schema validator, availability tests, tool contract documentation.

### Slice B — turn executor and ledger

Implement the turn state machine and executor pipeline: envelope → registry → schema → handler → postcondition → ledger. Add round/call/time/result limits, call-ID tracking, cancellation, and structured result serialization. Replace the `if/elif` chain and ad-hoc validation.

Gate: fake-model protocol suite covers unknown, malformed, wrong types, duplicate IDs, multiple calls, limits, failure, cancellation, and recovery. No mutation occurs on invalid input.

Deliverables: executor module, turn state, ledger, protocol tests.

### Slice C — prompt and context assembly

Implement the base policy, capability summary, user-preference labeling, and data-labeled editor context. Remove mixed/ambiguous prompt text. Ensure user extras cannot be presented as authority over validation.

Gate: prompt fixtures assert the section order, capability list, data labeling, and that unavailable tools are absent from the HTTP tool array.

Deliverables: prompt assembler, prompt fixtures, capability summary.

### Slice D — workspace tools and recipe-first integration

Wire stories 05/06 tools into the registry. Bind a turn to the scene identity/revision and pass it to handlers. Expose the WS-01 recipe as one tool with one undo group. Implement `stale_target` on scene switch or target deletion and file-conflict handling for `create_gdscript`.

Gate: WS-01, WS-02, and WS-13 pass through the orchestrator with fixed tool calls; one undo/redo restores the recipe; a scene switch or edited target is rejected before mutation; a changed file is not overwritten.

Deliverables: workspace tool handlers, turn scene binding, recipe integration, stale/conflict tests.

### Slice E — chat ledger, errors, and cancellation

Render action summaries from the ledger, not from model prose. Define mid-turn cancellation, partial results, protocol-violation stops, and next-turn recovery. Ensure every tool call has a matching tool result before the next user turn; never leave orphan calls.

Gate: error/cancel fixtures show completed actions, a clear final status, unlocked controls, and a clean subsequent request. Displayed chat review covers success, failure, and cancellation.

Deliverables: ledger rendering, cancellation path, conversation-integrity tests.

### Slice F — verification and live-model evaluation

Run the deterministic suite (registry, executor, recipe, stale/conflict, DEV-03) and the fake-model suite. Then run a real Tiiny coding model on WS-01 paraphrases: record tool trace, final scene, undo/redo, latency, and success rate. Judge required outcomes and constraints, not exact prose. Record failures and skipped hardware checks honestly.

Gate: WS-13, WS-14, WS-15, DEV-03, and WS-01/02 pass deterministically; the live evaluation reports a success rate and traces rather than claiming universal success.

Deliverables: test coverage, live evaluation report, work-item/STATUS handoff.

## Scenario mapping

| Scenario | Slice | Check |
| --- | --- | --- |
| WS-01 recipe | D, F | Fixed tool call → scene state → one undo/redo; live-model evaluation separately |
| WS-02 invalid parent / deleted target | D | No partial node/resource/undo entry; explicit error |
| WS-13 scene switch or edit between planning and execution | D | Revision/identity rejection before mutation |
| WS-14 file changed by another writer | D | No blind overwrite; conflict or fresh read |
| WS-15 unknown/malformed/repeated/multiple/too many | B, F | No mutation; bounded errors; later request works |
| DEV-03 incompatible model roles | C, F | No tools or a clear refusal when the coding model lacks Tool Use; image model cannot coordinate |

## Open questions and recommended decisions

1. **One call per response.** Recommend keeping one in 07. It keeps mutation ordering and undo semantics simple. Read-only batches can be added later with explicit parallelism rules.
2. **Registry location.** Recommend a separate embedded tool module injected into the dock, like the jobs scripts, so tools can be tested without the chat UI. Keep the dock as the presenter, not the tool implementation.
3. **Unavailable tools.** Recommend omitting them from the HTTP tool array and explaining them only in the capability summary. Do not send a tool that cannot run.
4. **GDScript fallback.** Recommend requiring a non-empty `reason` in `create_gdscript` and showing it. This makes the fallback visible and testable.
5. **Recipe-first.** Recommend exposing the WS-01 recipe as one tool and not exposing generic mutation primitives in 07. This guarantees one undo and no partial edits for the acceptance case. The executor itself stays class-agnostic.
6. **Success claims.** Recommend treating the ledger as authoritative and displaying it next to the final text. Do not parse model prose to decide whether a change happened.
7. **Cancellation.** Recommend stopping after the current tool, recording its result, and keeping completed actions. No automatic retry or rollback.
8. **Round limit.** Recommend six rounds and eight calls, with per-tool timeouts. The numbers are constants with tests, not model-controlled.
9. **Result size.** Recommend a 16 KiB cap with a truncation marker and a context-budget check before each model call.
10. **Project instructions.** Out of scope for 07; if added later, keep them data-labeled and non-authoritative.

## Dependencies and risks

- **05/06 gate:** the registry can be built with fake tools, but workspace acceptance needs the inspection tools and the recipe.
- **03 gate:** model readiness and `Tool Use` validation determine whether tools are sent at all.
- **02 gate:** job tools depend on the shared queue and device lease.
- **Model variability:** live evaluations measure planning quality statistically; deterministic executor tests remain the gate for safety.
- **Scene identity:** every mutating handler must receive the turn's scene identity/revision; do not re-resolve "the current scene" at execution time.
- **Undo scope:** one recipe equals one undo action. Multi-tool workflows are not atomic and must be described as such.
- **Dirty scenes:** read tools accept them; recipes reject them with `scene_dirty`. After a recipe, inspect the dirty result if needed, then save before the next mutation.
- **Prompt injection:** editor context and project content are data. Do not place them where the model can treat them as instructions.
- **UI scope:** 07 provides the ledger and summaries; story 08 owns richer action history, previews, and recovery UI.

## Handoff

Planning only. No build, test, or device operation was performed. Implementation starts with slice A (registry and schema) and can proceed against fake tools while 05/06 are completed. Record the tool contract, availability matrix, protocol results, recipe undo evidence, and live-model traces in the work item and STATUS.
