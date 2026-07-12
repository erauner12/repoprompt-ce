## Context

Coordinator runtimes are Agent Mode-backed MCP clients. They are not external drivers and not ordinary delegated children: they consume MCP while owning a Mission. The core runtime spec in `add-coordinator-mode` defines the authoritative state machine and gates. This change defines the MCP-consumer contract around that state machine so prompts, tool schemas, and runtime behavior steer the model toward the right surfaces.

Important current seams:

- `MCPAgentControlToolProvider.coordinatorChatTool()` tool description/schema.
- `AgentModePrompts` Coordinator/Director runtime guidance.
- `CoordinatorChatMCPToolService` runtime/external operation gates.
- `AgentRunMCPToolService` and `AgentExploreMCPToolService` Mission node delegation gates.
- `CoordinatorModeViewModel` child interaction response submitters and Director/Me routing.

## Goals / Non-Goals

**Goals:**

- Treat the Coordinator runtime as an MCP consumer with a Mission-owning context.
- Ensure prompt and schema guidance points the runtime to `coordinator_chat` for Mission state and to `agent_run`/`agent_explore` for child delegation.
- Require runtime consumers to inspect `mission_status`/`wait_for_update` rather than infer Mission state from prose.
- Preserve childAsk response boundaries from the consumer side: Director-routed child answers go through `coordinator_chat submit`; generic `agent_run.respond` must not bypass decisions/evidence.
- Keep external-driver operations separate from runtime operations.

**Non-Goals:**

- Re-defining Mission Plan, policy/autonomy, childAsk, receipt, stop/archive, or follow-through semantics owned by `add-coordinator-mode`.
- Defining broad `agent_manage.list_sessions` visibility or mission inventory retention; see `add-coordinator-list-sessions-visibility`.
- Reintroducing the older dashboard update subscription prerequisite as this change's primary purpose.

## Decisions

### 1. `coordinator_chat` is the runtime's Mission control plane

The Coordinator runtime should read and mutate Mission-owned state through `coordinator_chat` operations. Runtime prompts/tool schemas must tell the model to use `mission_plan` before normal delegation, `mission_status`/`wait_for_update` for current state and polling, `mission_events` for observation, and `receipt` only for terminal receipt projection.

### 2. `agent_run` and `agent_explore` are child delegation surfaces

The runtime may delegate work through `agent_run` and `agent_explore` only under the Mission gates specified in `add-coordinator-mode`. Prompts and schemas should teach use of `mission_node_id`, workflow metadata where relevant, and the wait/poll remaining-handles pattern so detached child work is not stranded.

### 3. Runtime callers are not external drivers

Runtime consumers must not call external Mission creation or user-action parity operations such as starting peer Missions, archiving Missions, setting pace/autonomy as a user action, or submitting follow-up parent creation. Those operations are reserved for user/UI/CLI paths in the core runtime spec.

### 4. Child interaction response boundary is ledger-preserving

When a Mission-bound child asks a question and `childAsk` resolves to Director, the Coordinator runtime may answer only through `coordinator_chat submit` so the childAsk decision and evidence requirements remain enforceable. When `childAsk` resolves to Me, or when the interaction is not the owning active Mission-bound child interaction, the runtime must not answer. Generic `agent_run.respond` is not the ledger-preserving route for active Mission-bound child interactions.

## Risks / Trade-offs

- **Prompt/tool mismatch** → keep schemas and runtime prompt language aligned with the same Mission control-plane contract.
- **Bypassing ledgers** → block or redirect generic child-response paths for Mission-bound child interactions.
- **Runtime/external confusion** → use request metadata/policy context gates from `refactor-agent-mcp-policy-context`.
- **Spec duplication** → reference `add-coordinator-mode` for the state machine and keep this change to MCP consumer behavior.
