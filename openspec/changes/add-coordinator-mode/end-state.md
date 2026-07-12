# Coordinator Mode End State: Mission Runtime Baseline

Status: planning baseline
Scope owner: Erauner team
Related changes: `add-coordinator-mode`, `add-coordinator-role`, `refactor-agent-mcp-policy-context`, `add-mcp-coordinator-mode-consumer`, `add-coordinator-list-sessions-visibility`

## Goal

Define the durable end state implied by the current Swift demo branch for the **core Coordinator/Director Mission runtime**. This document is intentionally narrower than the earlier Command Center/UI plan: the authoritative v1 baseline is shipped surface behavior, Mission state, MCP control, trust invariants, follow-through, lifecycle tooling, deterministic scripted validation, and receipt projection.

## End-state shape for this change

A Coordinator Mission runtime should let an external user/CLI driver or visible app surface:

- start or reuse a Coordinator Mission;
- require a concrete Mission Plan before ordinary delegation;
- approve, revise, continue, stop, or reroute Mission policy through auditable user decisions;
- let the Director delegate child Agent Mode work through existing `agent_run` / `agent_explore` primitives;
- enforce plan, workflow, worktree, flight-cap, childAsk, and terminal-state invariants;
- observe Mission state through compact/full `mission_status`, `mission_events`, and `wait_for_update`;
- stop/archive Missions without losing decisions, evidence, events, receipts, or lineage;
- generate a terminal receipt from Mission-owned state.

## Core runtime layers

### Layer 1 — Mission state

Mission state is persisted with the Coordinator backing session. It includes objective summary, Mission Template summary, Mission Plan, observed child phases, follow-through event bookkeeping, last resume state, and child interaction response records.

The Mission Plan is the durable source of truth for objective, shape, policy, autonomy, workstreams, nodes, routing decisions, decisions, evidence, events, and receipt inputs.

### Layer 2 — External control surface

`coordinator_chat` is the control and observation API for the demo/runtime baseline. It covers:

- mission inventory and selection;
- mission creation/reuse;
- directive and checkpoint submission;
- Mission Plan mutation;
- status, event, wait, and receipt reads;
- pace/autonomy user-action parity;
- stop/archive lifecycle operations;
- doctor/capability discovery.

Runtime callers are constrained by actor-integrity gates: they can update Mission Plan/Director ledgers for their own Mission, but cannot forge user actions, create parent Missions, archive Missions, or inspect arbitrary fleet inventory.

### Layer 3 — Delegation policy

Coordinator-owned child starts are allowed only when Mission policy permits:

- normal delegation requires an approved non-empty Mission Plan;
- pre-approval exceptions are narrow and node-bound;
- workflow-bearing nodes must use matching workflow metadata;
- mutable work requires explicit child sandboxing;
- running node count must remain under `maxConcurrent`.

Child Agent Mode sessions remain ordinary sessions with their own transcript, worktree, pending interactions, permissions, and routeability.

### Layer 4 — Follow-through

Follow-through is an app-owned wakeup layer, not a workflow engine. It observes child terminal, child question, gate-cleared, and eligible-work events, deduplicates by stable event ID, and submits internal resume directives only when the next safe boundary is clear.

The Director must still inspect compact Mission status, respect dependencies and `maxConcurrent`, and record routing decisions/evidence. Follow-through does not approve irreversible work or create new Coordinator parents.

### Layer 5 — Audit and receipts

Decision and evidence ledgers are append-only Mission state. Receipts are deterministic projections from terminal Mission state and include policy, decisions, evidence, and reserved spend reporting. Rendered receipt Markdown is not a separate source of truth.

## Future layers outside this change

The current baseline deliberately leaves these for later OpenSpec changes:

- first-class Coordinator role/runtime and durable role/session visibility (`add-coordinator-role`);
- MCP policy-context refactors and caller metadata hardening (`refactor-agent-mcp-policy-context`);
- consumer/session list visibility refinements (`add-mcp-coordinator-mode-consumer`, `add-coordinator-list-sessions-visibility`);
- restart durability for pending checkpoints/questions;
- recovery/chaos flows for stuck or killed children;
- toggle dedup beyond current idempotent ledger behavior;
- worktree garbage collection for Coordinator-created child worktrees;
- backend fallback between live child providers/backends;
- spend capture and spend autonomy;
- custom policy CRUD;
- hierarchical Coordinator-of-Coordinators;
- broader Command Center layout, shared boards, or rich activity/provenance UI.

## Acceptance for this end state

The core runtime end state is satisfied when:

1. Focused Swift tests cover Mission Plan persistence/merge behavior, policy/autonomy, actor integrity, childAsk routing, follow-through, MCP serialization, delegated-run policy, receipt projection, prompts, and scripted child lifecycle.
2. Live E2E scenarios S1, S2, S4, S5, S6, and S7 can validate through `coordinator_chat` using doctor, compact status, mission events, receipts, and lifecycle cleanup.
3. The OpenSpec proposal, design, tasks, decision record, E2E plan, and split capability specs describe the same runtime baseline without requiring the old mock/UI reference documents.
