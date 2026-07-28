## Why

An approved Coordinator Mission contract can become unsuitable when the Director discovers contract-changing drift, but the current contract has no first-class way for the Director to request reconsideration without either continuing under stale authority or risking self-approval. The runtime needs a durable, user-ratified proposal path that pauses autonomous advancement while preserving the single trusted approval door.

## What Changes

- Add `coordinator_chat op="propose_revision"` for the owning Director runtime to append a summary-only proposal anchored to the current approved material-contract snapshot and fingerprint.
- Add append-only proposal and resolution records with deterministic canonical request identity for exact pending-retry idempotency, one-pending-proposal enforcement, restart-safe persistence, and dedicated mutators outside generic `mission_plan` updates.
- Pause autonomous advancement while a proposal is pending while still accepting terminal output, evidence/failure bookkeeping, permitted terminal transitions, Stop, and observation; persist child questions as disabled with reason `held pending revision proposal` and reject answer submits without recording an answer.
- Project a pending proposal as the highest-priority active Needs You checkpoint with **Revise plan**, **Keep current plan**, and **Stop Mission** actions; hold all child questions behind it.
- Route Revise plan into the existing trusted `revisionRequested` flow; Keep current plan rejects the proposal and resumes eligible authority only after durable persistence; Stop terminalizes the Mission and resolves the proposal.
- Expose proposal lifecycle state through Mission status, compact fingerprints, waits, and the event journal; advertise `propose_revision` through public input schema fields and through doctor `supported_ops`, with `features.revision_proposals` for harness preflight.
- Require structural CAS against a versioned canonical material-contract snapshot; use its deterministic SHA-256 fingerprint for proposal/checkpoint/status identity rather than `plan.revision`.
- Defer exact one-click replacement or an **Approve revised plan** action to a later change requiring a complete structured replacement/diff, acceptance-time rebasing, and separate validation.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `coordinator-chat-contract`: Add runtime-owned summary proposal ingress, external proposal-resolution submit actions, caller gates, status/wait schema, and exact-payload rejection.
- `coordinator-mission-ledger`: Add canonical material-contract identity plus append-only proposal/resolution state, deterministic `canonicalRequestIdentity` for exact logical retries, dedicated mutators, persistence, reset, and terminal behavior.
- `mission-trust-invariants`: Require trusted user resolution, structural CAS, durable ordering, first-resolution-wins behavior, and prevention of runtime self-resolution or generic-update injection.
- `coordinator-autonomy-routing`: Define the pending-proposal advancement pause, allowed bookkeeping transitions, continuation deferral/restoration/invalidation, and Stop race precedence.
- `coordinator-mode`: Project proposal-specific Needs You state, checkpoint precedence, stable action identity, UI labels, and observable lifecycle summaries.

## Impact

- Runtime state and persistence: `CoordinatorFollowThroughState`, Mission Plan Codable state, canonical contract comparison/fingerprinting, persistence barriers, continuation authority, and Mission event journal.
- MCP/API surfaces: `CoordinatorChatMCPToolService`, `MCPAgentControlToolProvider`, Coordinator prompts, `propose_revision`, proposal-aware `submit`, status/doctor/wait responses, and strict caller scoping.
- Autonomy enforcement: delegated start policy, Auto-mode boundary classification, follow-through evaluation, node/runtime progress validation, and post-approval continuation delivery.
- User experience: Coordinator snapshot projection, decision queue, proposal-specific checkpoint card, Revise/Keep/Stop transactions, stale-action handling, and restart reprojection.
- Validation: reducer, MCP, policy, classifier, view-model, projection, persistence, status/fingerprint/wait/journal, and one live narrative scenario.
- Implementation sequencing is a partial order: audit first; contract model, ledger, and most proposal parsing/validation may proceed independently; prompt/schema/discovery follows task 13.6; pause/resolution/Stop/continuation/projection integration waits for tasks 13.7 and 13.8; task 13.3 remains soft/independent unless shared paths are discovered.
