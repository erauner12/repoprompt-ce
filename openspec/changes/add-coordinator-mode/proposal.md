## Why

The `add-coordinator-mode` OpenSpec change must describe the current Coordinator/Director runtime, not the earlier mock/UI projection cutline. The Swift demo branch now contains a Coordinator Mission runtime with durable Mission Plan state, policy/autonomy routing, decision/evidence ledgers, follow-through events, `coordinator_chat` control operations, lifecycle tooling, validator invariants, deterministic scripted child support, and receipt projection.

This change makes the core runtime artifacts authoritative enough that another implementer could recreate the current demo baseline across PRs without relying on commit history or the large mock-era reference notes.

## What Changes

- Reframe `coordinator-mode` around the core Coordinator Mission runtime and its external MCP control surface.
- Specify the Mission-owned state model: objective, template summary, Mission Plan, workstreams, DAG-lite nodes, policy snapshot, autonomy map, routing decisions, user/director decision ledger, evidence ledger, events, follow-through state, and child interaction response records.
- Specify `coordinator_chat` operations for mission creation, selection, submit, Mission Plan updates, status, event journal, wait-for-update, receipt, pace/autonomy dials, doctor, list/archive lifecycle operations, and stop semantics.
- Specify autonomy routing and actor-integrity rules, especially `childAsk` ask/auto behavior, user-action parity gates, Director-authored decisions/evidence, and Mission-bound child response routing.
- Specify delegated-run guardrails: approved concrete Mission Plan requirement, pre-approval planning exceptions, `maxConcurrent` flight cap, explicit worktree isolation for mutable Coordinator work, terminal-state honesty, node-status monotonicity, and childAsk:auto ledger requirements.
- Specify deterministic validation support: scripted child backend, compact status fingerprints, sequenced mission events, receipt Markdown projection, and live E2E scenario boundaries.
- Retain Director as user-facing vocabulary while keeping technical Swift symbols, MCP operation names, Codable keys, and fixtures Coordinator-named for this change.

## Capabilities

### New Capabilities

- `coordinator-mode`: Shipped Director/Coordinator surface behavior, including peer surface switcher, rail/Mission selection, board/list lanes, fleet projection, pending interaction presentation, deep links, composer affordances, and terminal/receipt copy.
- `coordinator-mission-ledger`: Mission-owned state, Mission Plan merge semantics, policy/autonomy snapshots, append-only decision/evidence ledgers, and receipt-ready evidence.
- `coordinator-chat-contract`: External `coordinator_chat` operations, runtime caller gates, Mission start approval checkpoint publication, status/wait/event contracts, and prompt/tool-schema guidance.
- `mission-trust-invariants`: Delegation gates, explicit sandboxing, node validators, actor integrity, self-approval prevention, childAsk ledger enforcement, and liveness warning semantics.
- `coordinator-autonomy-routing`: Pace/childAsk dial behavior, childAsk pending-interaction rerouting, app-owned follow-through wakeups, and Auto-mode boundaries.
- `coordinator-lifecycle-tooling`: Stop/archive/list/doctor/receipt behavior, E2E validation boundaries, and deferred-scope markers.
- `scripted-agent-backend`: DEBUG-only deterministic scripted child backend for childAsk validation.

### Modified Capabilities

None in this pass. Supporting changes under `add-coordinator-role`, `refactor-agent-mcp-policy-context`, `add-mcp-coordinator-mode-consumer`, and `add-coordinator-list-sessions-visibility` remain separate unless explicitly referenced for integration context.

## Impact

- Runtime state: `CoordinatorFollowThroughState` persists the Mission runtime foundation on Coordinator-backed Agent sessions.
- MCP surface: `CoordinatorChatMCPToolService` exposes the external/demo control contract and runtime/user caller gates.
- Agent control: `MCPAgentControlToolProvider` and `AgentRunCoordinatorMissionPlanPolicy` enforce Mission Plan, node, workflow, worktree, and cap guardrails around delegated starts.
- Prompts: `AgentModePrompts` instructs Coordinator runtimes to use Mission Plan/ledger/status operations instead of ad hoc transcript or shell-loop control.
- Validation: focused Swift tests cover Mission Plan persistence/merge behavior, MCP serialization, lifecycle operations, receipt projection, scripted child behavior, and delegated-run policy checks.

## Out of Scope

- Full Coordinator-to-Director symbol/API/key rename.
- First-class non-tab Coordinator role/runtime extraction.
- Restart durability (S8), recovery chaos, UI render-to-click race hardening, toggle dedup beyond current idempotent ledgers, worktree garbage collection, backend fallback, custom policy CRUD, spend enforcement, hierarchical Coordinator-of-Coordinators, broader Command Center layout redesign, and future bounded preauthorization for unattended Mission starts (`initialPlanReview: required | preauthorized(policyGrantID)`) with versioned user grants, generated-plan validation, scoped tools/budget/writes/evidence/stops, receipt provenance, and irreversible actions still Ask.
- Reworking the supporting OpenSpec changes named above; those are intentionally left for later agents.
