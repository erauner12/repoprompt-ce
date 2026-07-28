## Context

`add-coordinator-mode` now describes the current Coordinator/Director Mission runtime: Missions are the durable unit; `coordinator_chat` owns Mission creation/status/events/receipts; Mission Plan gating, childAsk routing, evidence, follow-through, stop/archive, and E2E doctrine live there.

This supporting change owns the role semantics around that runtime. In the product, the supervising actor is the **Director**. In Swift/MCP/persistence/debug contracts the runtime is still technically **Coordinator**. The current implementation backs the runtime with marked Agent Mode session machinery (`isCoordinatorRuntime`) and a dedicated Coordinator launch/control path, while ordinary child Agent Mode sessions remain normal `pair`, `engineer`, `explore`, or `design` sessions.

Relevant current seams:

- `AgentModelCatalog.TaskLabelKind.coordinator` and `requiresDedicatedLaunchPath`.
- `AgentModeMCPPolicyContext.isCoordinatorRuntime`.
- `AgentModeViewModel.mcpCreateCoordinatorRuntimeTab` / `mcpMarkCoordinatorRuntime`.
- `CoordinatorModeViewModel` fresh-runtime submission and `coordinator_model_id` handling.
- `CoordinatorChatMCPToolService` external Mission creation and runtime-call gates.
- `MCPAgentControlToolProvider` `coordinator_chat` schema text.

## Goals / Non-Goals

**Goals:**

- State the Director/Coordinator vocabulary boundary without renaming technical contracts.
- Keep Coordinator role identity separate from ordinary Agent Mode task labels and child roles.
- Require a durable runtime marker and typed policy context before Coordinator-scoped behavior is granted.
- Specify that `coordinator_model_id` chooses only the fresh runtime's underlying model/provider.
- Preserve the current marked/background Agent `TabSession` implementation stance while documenting non-enrolled runtime extraction as deferred.

**Non-Goals:**

- Re-specifying Mission Plan, Mission Policy, autonomy, childAsk, evidence, events, receipt, stop, archive, or follow-through behavior already owned by `add-coordinator-mode`.
- Granting additional tools, broader visibility, or direct workspace mutation.
- Renaming Swift symbols/MCP operations/persisted keys from Coordinator to Director.
- Designing hierarchical Coordinator-of-Coordinators or cross-window control.

## Decisions

### 1. Director is product vocabulary; Coordinator is technical contract vocabulary

User-facing supervision, policy, decisions, evidence, receipts, and runtime guidance should name the Director. Technical APIs remain Coordinator-named for this change: Swift types, MCP operation names such as `coordinator_chat`, Codable keys, fixtures, debug payloads, and persisted records. A full technical rename would be a separate no-behavior migration.

### 2. Coordinator is a dedicated runtime identity, not an ordinary child role

The role catalog may expose a `coordinator` label for discovery/model binding, but that label is not enough to create or authorize a Coordinator runtime. Ordinary `agent_run.start`, `agent_manage.create_session`, and `agent_manage.resume_session` paths that would create normal tab-backed Agent Mode sessions must reject the dedicated Coordinator launch role. The accepted path is a Coordinator runtime creation/control path that installs the runtime marker and policy context.

### 3. The current runtime is a marked Agent Mode session by design

The current demo branch reuses Agent Mode run/session machinery because provider start, transcript persistence, context assembly, terminal publication, and loopback MCP routing still depend on compose-tab-to-Agent-session binding. The runtime is therefore backed by a marked/background Agent `TabSession` with `isCoordinatorRuntime` durable state. A non-enrolled provider runtime remains deferred unless a later change extracts the necessary runtime registry/context-provider seams.

### 4. Runtime model selection is separable from role identity

Fresh external Mission creation may pass `coordinator_model_id` to choose the underlying provider/model for the new Coordinator runtime. That value may be a role label or explicit model selector accepted by the model-selection layer, but it does not change Coordinator identity, Director prompt semantics, Coordinator tool policy, Mission Policy, or the runtime marker. Existing Missions are not reconfigured by a later model override argument.

### 5. Child sessions remain ordinary scoped agents

Delegated child Agent Mode sessions launched by a Coordinator runtime are not Coordinators. They keep ordinary role labels, transcripts, worktree/sandbox state, pending interactions, and routeability. Core delegation gates and childAsk behavior are specified by `add-coordinator-mode`; this change only states that ordinary child role identity must not inherit Coordinator privileges.

## Risks / Trade-offs

- **Role-label spoofing** → require dedicated launch/marker/policy context before Coordinator behavior; reject ordinary starts using `model_id:"coordinator"`.
- **Vocabulary drift** → use Director in user-facing copy, Coordinator in technical contracts until an explicit rename migration exists.
- **Model override confusion** → constrain `coordinator_model_id` to fresh runtime model selection only.
- **Implementation coupling** → accept marked Agent Mode session reuse for this branch, but keep non-enrolled runtime extraction deferred rather than partially specified here.

## Migration Notes

This change should stay synchronized with `add-coordinator-mode` without duplicating it. If core Mission semantics change, update the core change first and adjust this role slice only where the role identity, naming, dedicated launch, model selection, or ordinary-role separation is affected.
