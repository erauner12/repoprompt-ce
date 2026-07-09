## Why

The current Coordinator/Director Mission runtime consumes RepoPrompt through MCP from inside a Coordinator-marked Agent Mode session. That makes the Coordinator runtime an MCP consumer with special responsibilities: it must use `coordinator_chat` for Mission state, use `agent_run`/`agent_explore` only through Mission-gated delegation, and avoid generic child-response or parent-Mission creation paths that would bypass the core runtime contract.

The core Mission semantics live in `add-coordinator-mode`. This supporting change owns the consumer contract: what prompts/tool schemas must tell the Coordinator runtime, which MCP surfaces it should use, and which child interaction boundaries it must respect as an MCP caller.

## What Changes

- Define Coordinator runtime as an MCP consumer, distinct from external CLI/test consumers and ordinary child Agent Mode consumers.
- Require Coordinator runtime prompts/tool schemas to advertise `coordinator_chat` as the Mission control plane and `agent_run`/`agent_explore` as delegated-child surfaces.
- Require runtime calls to use `coordinator_chat mission_plan`, `mission_status`, `wait_for_update`, `mission_events`, and `receipt` for Mission state instead of inventing state from prose.
- Require runtime delegation to use Mission node metadata and the matching `agent_run` / `agent_explore` surfaces as specified by `add-coordinator-mode`.
- State consumer-side childAsk boundaries: Mission-bound child questions are answered through `coordinator_chat submit` only when routed to Director; generic `agent_run.respond` must not bypass the ledger.

## Capabilities

### New Capabilities
- `mcp-coordinator-mode-consumers`: Defines how Coordinator runtimes consume MCP prompts/tools/control surfaces without duplicating the core Mission runtime spec.

### Modified Capabilities

None. The older dashboard-update named consumer is an implementation detail of Coordinator mode UI and is not the focus of this reconciled change.

## Impact

- Coordinator prompt/tool schema: must guide runtime callers toward the Mission control-plane contract.
- `coordinator_chat`: remains the authoritative Mission state and childAsk response surface for Coordinator runtimes.
- `agent_run` / `agent_explore`: remain child delegation surfaces and must be used with Mission node/workflow metadata where required.
- `agent_run.respond`: remains blocked for active Mission-bound child interactions unless a later accepted spec changes the ledger-preserving route.
