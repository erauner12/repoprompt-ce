## Why

The current Swift demo branch already has a Coordinator-marked Mission runtime backing the user-facing Director experience. The remaining role slice is to keep the role semantics explicit: Director is the product actor, Coordinator is the technical contract/runtime marker, and the runtime must stay separate from ordinary child Agent Mode roles even though it reuses Agent Mode machinery.

This change reconciles the earlier first-class-role proposal with the implemented baseline in `openspec/changes/add-coordinator-mode`: Missions, plans, ledgers, childAsk, receipts, and lifecycle operations are core runtime behavior there. This change owns only the role identity, naming boundary, model-selection/launch semantics, and separation from ordinary delegated roles.

## What Changes

- Define the user-facing Director vs technical Coordinator vocabulary boundary for the supporting role capability, cross-referencing `add-coordinator-mode` for core Mission runtime behavior.
- Treat Coordinator as a dedicated runtime identity backed by a durable `isCoordinatorRuntime` marker, not as a normal `pair`, `engineer`, `explore`, or `design` child role.
- Record that a `coordinator` role label may exist for discovery/model binding but requires a dedicated Coordinator runtime creation path; ordinary `agent_run`/`agent_manage` starts must not create a Coordinator by label alone.
- Document fresh Coordinator runtime model override behavior: external Mission creation may choose the underlying provider/model with `coordinator_model_id`, but that override does not change Coordinator/Director identity, prompt, tools, or Mission Policy semantics.
- Preserve the marked/background Agent `TabSession` implementation stance for the current demo branch while keeping the non-enrolled runtime extraction deferred.

## Capabilities

### New Capabilities
- `coordinator-role`: Defines Director/Coordinator role identity, model binding, dedicated launch/marker requirements, and separation from ordinary Agent Mode roles.

### Modified Capabilities

None. Core Mission runtime behavior remains specified by `add-coordinator-mode`; MCP policy-context plumbing is specified by `refactor-agent-mcp-policy-context`; broader session/mission visibility is specified by `add-coordinator-list-sessions-visibility`.

## Impact

- Agent role/catalog model: `coordinator` is a dedicated-launch role label, not an ordinary child role label.
- Coordinator runtime creation: may reuse marked/background Agent Mode machinery, but must install `isCoordinatorRuntime` and Coordinator policy context before granting Coordinator behavior.
- Coordinator model selection: `coordinator_model_id` selects the underlying fresh runtime model only.
- UI/product language: user-facing supervision copy should say Director; technical symbols, MCP ops, persisted keys, fixtures, and debug payloads keep Coordinator naming for this change.
