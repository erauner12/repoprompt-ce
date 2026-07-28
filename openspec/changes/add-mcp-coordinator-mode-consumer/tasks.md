## 1. Prompt and schema guidance

- [x] 1.1 State that the Coordinator runtime is a Mission-owning MCP consumer.
- [x] 1.2 Require prompt guidance to describe `coordinator_chat` as the Mission control plane.
- [x] 1.3 Require prompt/schema guidance to describe `agent_run` and `agent_explore` as delegated-child surfaces subject to Mission Plan gates.

## 2. Runtime use of MCP surfaces

- [x] 2.1 Require runtime callers to use `coordinator_chat mission_status` / `wait_for_update` for current Mission state and polling.
- [x] 2.2 Require runtime callers to use `coordinator_chat mission_plan` for Director decisions/evidence and plan updates.
- [x] 2.3 Require child starts to use Mission node IDs/workflow metadata where the core runtime requires them.
- [x] 2.4 Require multi-child waits to keep tracking remaining active child handles.

## 3. Operation boundaries

- [x] 3.1 State that runtime callers must not create peer/follow-up parent Missions through external creation operations.
- [x] 3.2 State that runtime callers must not invoke user-action parity operations as the user.
- [x] 3.3 State that childAsk Director answers use `coordinator_chat submit` and generic `agent_run.respond` must not bypass the ledger.
- [x] 3.4 Cross-reference `add-coordinator-mode` for core Mission gates, actor ledger rules, and childAsk enforcement.

## 4. Validation

- [x] 4.1 Run `openspec validate add-mcp-coordinator-mode-consumer` after reconciliation.
