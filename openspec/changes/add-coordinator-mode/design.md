## Context

The current demo branch implements Coordinator Mode as a Mission runtime layered over existing Agent Mode sessions. User-facing product copy may say **Director**, but the technical contract remains **Coordinator** for Swift symbols, MCP tool names, Codable keys, persisted payloads, and fixtures.

The runtime is intentionally not a separate non-tab agent runtime yet. A Coordinator Mission is backed by a marked Agent Mode session, persists lightweight Mission state on that session, and delegates work through the existing `agent_run` / `agent_explore` MCP control plane.

## Goals / Non-Goals

### Goals

- Define the current core Mission runtime as the source of truth for reimplementation.
- Make `coordinator_chat` the normative external/demo control API.
- Preserve Mission-owned state as the receipt, status, scheduling, and audit source of truth.
- Keep actor boundaries explicit: user-action parity operations record user decisions; Coordinator runtime operations record Director decisions/evidence.
- Gate delegated child work on approved Mission Plans, explicit node identity, workflow/worktree policy, and flight-cap constraints.
- Make childAsk routing deterministic and auditable for both user-answered and Director-answered child interactions.
- Provide deterministic debug/E2E hooks without weakening the real Agent Mode session lifecycle.

### Non-Goals

- Renaming Coordinator technical contracts to Director.
- Extracting a first-class Coordinator role/runtime outside Agent Mode.
- Reopening old mock-only UI behavior that did not ship; shipped surface/UI behavior is captured in the `coordinator-mode` capability.
- Implementing restart durability, recovery chaos, UI render-to-click race hardening, toggle dedup beyond current idempotent ledgers, worktree garbage collection, backend fallback, spend enforcement, custom policy CRUD, or hierarchical Coordinator delegation.
- Modifying Swift code in this artifact-alignment pass.

## Runtime Model

### Mission root and persisted state

A Coordinator Mission is represented by a Coordinator backing session. Its persisted runtime state lives in `CoordinatorFollowThroughState` and includes:

- `originalObjectiveSummary`
- optional `missionTemplate`
- optional `missionPlan`
- observed child phases
- pending and handled follow-through event IDs
- last resume result
- child interaction response records

Starting a fresh objective normally resets the Mission Plan and follow-through bookkeeping. Follow-up turns may preserve the existing Mission Plan when they are part of the same Mission.

### Mission Plan

`CoordinatorMissionPlan` is the durable Mission-owned plan and ledger. It carries:

- stable `id`, monotonic `revision`, optional `missionKey`, objective, predecessor context, status, approval state, template summary, shape summary, and updated timestamp;
- optional Mission Policy snapshot and effective autonomy map;
- workstream summaries and DAG-lite nodes;
- routing decisions;
- append-only decision and evidence ledgers;
- execution events.

Partial `mission_plan` updates preserve omitted fields. Workstreams and nodes are upserts by ID/title unless explicit replacement is requested. Routing decisions upsert by ID. Decision and evidence records append and dedupe by record ID only.

### Mission Policy and autonomy

Mission Policy is a Mission-owned snapshot, not a Mission Template. Built-ins are Default, Hands-off, Careful writes, and Read-only. A policy snapshot includes stable ID/name, default pace, autonomy map, `maxConcurrent` (default 3), optional Definition of Done, optional standing guidance, and pinned skill/context IDs.

Known autonomy/decision classes are `plan`, `advance`, `writes`, `childAsk`, `recover`, and `irreversible`. Unknown autonomy classes round-trip but resolve to Ask. `irreversible` always resolves to Ask. Current user-facing dial parity exposes pace and `childAsk`; general per-class editing is out of scope.

### Workstreams and nodes

Workstreams describe execution lanes: title, purpose, optional role, default execution policy, explicit worktree strategy, optional primary child session, and related child sessions. Worktree strategies are `noneReadOnly`, `createIsolated`, `reuseExisting`, `reuseWorkstream`, and `askUser`.

Nodes describe DAG-lite work: title/detail, workflow hint, done criteria, completion evidence, workstream ID, dependencies, role, execution policy, status, bound session ID, and bound interaction ID. Execution policies are `coordinator_only`, `fresh_readonly_child`, `steer_primary`, `fresh_sibling_on_same_worktree`, `fresh_worktree`, `plan_critique`, and `ask_user`.

Node dependency satisfaction means every dependency is completed. Ready nodes are pending nodes with satisfied dependencies. Terminal node statuses are completed, skipped, and cancelled.

## MCP Control Surface

`coordinator_chat` is the external/demo API. Supported operations are:

- `list`: current Coordinator selection, available parents, and board counts.
- `list_missions`: compact mission lifecycle inventory, including archived missions by default for external callers; runtime callers are scoped to their own Mission.
- `doctor`: side-effect-free capability pulse for supported ops, features, structured child input, scripted child availability, and runtime gates.
- `select`: select an available Coordinator parent by `coordinator_session_id`.
- `new`: prepare a fresh Coordinator parent context; optional `coordinator_model_id` selects the underlying Coordinator model.
- `ensure_mission` / `start_mission`: start or reuse a Mission with an initial directive, optional `mission_key`, optional predecessor context, optional `coordinator_model_id`, and initial awaiting-approval plan publication/fallback.
- `submit`: submit an ordinary Coordinator directive, start a new parent when explicitly requested, submit a checkpoint action, or answer an active selected-Mission child interaction.
- `mission_plan`: create/update the Mission Plan without submitting a chat turn.
- `mission_status`: read full or compact Mission status.
- `mission_events`: read a sequenced in-memory journal of compact Mission transitions.
- `receipt`: project terminal Mission receipt Markdown.
- `set_pace`: external user-action parity for Step/Auto.
- `set_autonomy`: external user-action parity for `childAsk` ask/auto.
- `wait_for_update`: long-poll until compact Mission status fingerprint changes.
- `stop_mission`: stop a Mission and cancel linked live sessions.
- `archive_mission`: external-only terminal lifecycle cleanup; hides from ordinary live rail surfaces but preserves receipt/state.

Coordinator runtime callers must not create follow-up Missions, archive Missions, or call user-action parity operations. Runtime calls without an explicit `coordinator_session_id` resolve to the caller Mission and fail closed if the caller Mission cannot be resolved.

## Lifecycle and Approval Flow

`start_mission` / `ensure_mission` create or select a Coordinator parent and submit the initial directive. The runtime is expected to publish an awaiting-approval Mission Plan promptly. If it does not, the app publishes a fallback scoped intake plan so delegation remains blocked behind a visible plan approval checkpoint.

Before normal delegated child starts, Coordinator parents must have a recorded Mission Plan with nodes and `approval_state: approved`. Pre-approval exceptions are intentionally narrow:

- `agent_explore.start` may launch a workflow-less `fresh_readonly_child` node bound by `mission_node_id`.
- `agent_run.start` may launch approved pre-approval Investigate or Deep Plan read-only planning nodes when the real workflow ID/name matches the node and `worktree_create:true` is used.
- `agent_run.start` may launch a `plan_critique` node with `model_id:"design"`, no workflow, `mission_node_id`, and `worktree_create:true`.

Plan approval checkpoints expose a revision-bound `checkpoint_instance_id`. Approval-granting stale checkpoint submits are rejected; `stop` remains stale-tolerant so users can always stop the Mission.

## Delegation Guardrails

Delegated starts from Coordinator parents are subject to these invariants:

- Mission Plan approval is required except for the pre-approval planning exceptions above.
- `maxConcurrent` counts running Mission nodes, not bound sessions, and denies new `agent_run.start` / `agent_explore.start` when the cap is reached.
- Mutable delegated work requires explicit child execution isolation (`worktree_create:true` or explicit `worktree_id`) before child session creation; inherited binding alone is not enough.
- Workflow-bearing nodes must use `agent_run` with matching workflow metadata; workflow-less narrow probes may use `agent_explore`.
- Running delegated nodes require bound session IDs; `ask_user` nodes require bound interaction IDs.
- Completed nodes require fresh completion evidence, not stale waiting/bound-state text.
- A Mission cannot become completed while any node is non-terminal.
- Terminal node statuses cannot regress to pending/running through later updates.

## Decisions, Evidence, and Actor Integrity

The decision ledger records both user and Director decisions. User decision IDs are deterministic from `(checkpointInstanceID, label)`; plan approval checkpoint instances include Mission Plan revision. Retried submits for the same checkpoint instance and label dedupe; revision changes mint a new checkpoint instance.

The app and external `coordinator_chat submit`, `set_pace`, `set_autonomy`, and stop paths record user-actor decisions. Runtime `mission_plan` updates record Director-actor decisions and evidence only. Runtime `mission_plan` must not forge user decisions.

Evidence records distinguish `meets` and `short`, may reference node/workstream/session/interaction/decision IDs, and may include a source and judgment bundle. Judgment bundles are bounded and receipt-ready: done criteria, structured evidence, optional diff stats, optional probe answer, and explicit `not_transcript_summary` framing. Probe evidence records the answer/summary/export reference, not the probe transcript or selection.

## childAsk Routing

`childAsk` autonomy determines who answers Mission-bound child questions:

- `ask`: the child question remains visible to the user and must be answered through the Mission-aware `coordinator_chat submit` child-interaction path.
- `auto`: the Coordinator runtime may answer the child question as Director, but must record a Director `childAsk` decision and evidence for the same interaction before completing the bound node.

Generic `agent_run.respond` is blocked for active Mission-bound child questions so actor decisions/evidence cannot be bypassed. Runtime attempts to answer while `childAsk` resolves to Ask are rejected. External `set_autonomy` can reroute pending child questions and records a user decision; stale Director answers after escalation back to Ask are rejected by re-resolving the current route at submit time.

## Follow-Through Runtime

App-owned follow-through observes child phases and Mission state and enqueues stable events for `childTerminal`, `childQuestion`, `gateCleared`, and `eligibleWork`. Events are deduplicated through stable IDs and handled-event tracking. Resume directives are internal structured messages to the existing owning Coordinator parent; they do not create new parents and do not mutate board rows directly.

Follow-through may wake an idle Coordinator when Auto mode and policy allow it, but must hold when the Coordinator is active, a child is in Needs-you/Blocked, a human permission or irreversible boundary exists, or the next step is ambiguous. Eligible-work resume directives instruct the Coordinator to inspect compact `mission_status`, respect dependency satisfaction, honor `maxConcurrent`, and never start nodes already running or bound.

## Status, Events, Waits, and Receipts

Full `mission_status` includes the full Mission Plan, shape, policy, autonomy summary, decision/evidence counts, recent ledger entries, receipt-ready summary, node counts, workstreams, nodes, recent events, and recent routing decisions.

Compact `mission_status` includes a fingerprint plus the status fields needed for automation: plan revision/status/approval, shape/policy/autonomy summaries, decision/evidence counts, recent ledger entries, node counts, workstream summaries, ready nodes, active nodes, missing bindings, liveness warnings, approval checkpoint metadata, events, and routing decisions.

The compact fingerprint must move when any wait-unblocking field changes, including plan revision/status/approval, node/workstream state, ready/dependency state, policy/autonomy, decisions, evidence, descendant child rows, and liveness warnings. `wait_for_update` returns when this fingerprint changes or when its timeout elapses.

`mission_events` exposes a sequenced transition journal for harnesses. It is observational only and does not replace Mission Plan state.

`receipt` returns Markdown only for terminal completed or stopped Missions. The receipt is a projection from Mission-owned state and includes objective/summary, policy, decisions, evidence, and a reserved Spend section. Rendered Markdown is not persisted as source of truth.

## Scripted Child Backend

In DEBUG builds, `model_id:"scripted"` maps to a hidden deterministic child runner. It accepts only the exact line:

```text
SCRIPTED_CHILD_V1 ask_marker token=<TOKEN> options=Alpha,Beta
```

It creates a real `AgentAskUserInteraction` and completes with:

```text
SCRIPTED_CHILD_V1 answer=<Alpha|Beta> token=<TOKEN>
```

This backend is test infrastructure only. It must reuse the real Agent Mode run lifecycle, must not appear in normal model lists, must not become a general interpreter, and must not replace live child/backend negotiation samples.

## Traceability

| Contract area                                                                               | Primary implementation                                                                   | Primary tests                                                                    |
| ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Mission state, merge semantics, policy/autonomy, childAsk completion, follow-through events | `Sources/RepoPrompt/Features/AgentMode/Runtime/CoordinatorFollowThroughState.swift`      | `Tests/RepoPromptTests/AgentMode/CoordinatorFollowThroughStateTests.swift`       |
| External `coordinator_chat` operations, status/events/receipt serialization, caller gates   | `Sources/RepoPrompt/Infrastructure/MCP/Agent/CoordinatorChatMCPToolService.swift`        | `Tests/RepoPromptTests/MCP/CoordinatorChatMCPToolServiceTests.swift`             |
| Delegated start plan/cap/pre-approval policy                                                | `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunCoordinatorMissionPlanPolicy.swift` | `Tests/RepoPromptTests/MCP/AgentRunCoordinatorMissionPlanPolicyTests.swift`      |
| Tool schemas and Coordinator Mission node hooks on `agent_run`/`agent_explore`              | `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAgentControlToolProvider.swift`    | MCP policy/service tests above                                                   |
| Prompt contract for Coordinator runtimes                                                    | `Sources/RepoPrompt/Infrastructure/AI/Prompts/AgentModePrompts.swift`                    | `Tests/RepoPromptTests/AgentMode/SystemPromptServiceCoordinatorModeTests.swift`  |
| Scripted child backend                                                                      | `Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/ScriptedAgentModeRunner.swift`    | `Tests/RepoPromptTests/AgentMode/AgentModeRunServiceLifecycleTests.swift`        |
| Receipt Markdown projection                                                                 | `CoordinatorMissionReceiptProjection` in runtime sources                                 | `Tests/RepoPromptTests/AgentMode/CoordinatorMissionReceiptProjectionTests.swift` |

## Deferred Scope

The current baseline explicitly defers S8 restart durability for pending checkpoints/questions, UI render-to-click race hardening, toggle dedup beyond current idempotent ledger behavior, worktree garbage collection for Coordinator-created child worktrees, backend fallback between live providers, recovery chaos, spend enforcement, custom policy CRUD, and hierarchical Coordinators.

## Risks / Trade-offs

- The runtime is backed by Agent Mode sessions, so role/scope isolation is a bridge until `add-coordinator-role` lands.
- `mission_events` is an in-memory observation journal; Mission Plan remains authoritative after restart.
- Runtime/user actor gates depend on request metadata propagation; callers without resolvable runtime identity fail closed.
- UI surfaces may display Director vocabulary, but technical payloads remain Coordinator-named, so docs must be explicit about the split.

## Migration Plan

This artifact update does not require Swift migration. The capability specs are split by surface, Mission ledger, MCP contract, trust invariants, autonomy routing, lifecycle tooling, and scripted backend so future work can validate one contract area without treating the old reference archive as normative. For future implementation or reimplementation work:

1. Implement Mission state and merge/validation invariants first.
2. Add `coordinator_chat mission_plan`, `mission_status`, compact fingerprint, and `wait_for_update` before live delegation.
3. Gate `agent_run` / `agent_explore` delegated starts on Mission Plan approval, node identity, workflow/worktree policy, and flight cap.
4. Add childAsk routing through Mission-aware submit paths and ledger requirements.
5. Add follow-through events, lifecycle ops, receipt projection, doctor, and scripted child support.
6. Validate with focused Swift tests before live E2E scenarios.
