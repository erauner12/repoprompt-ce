## ADDED Requirements

### Requirement: Mission ledger stores append-only revision proposals and resolutions
The Mission Plan SHALL persist canonical revision proposal records and separate append-only resolution records, and proposal lifecycle SHALL be derived rather than mutated in place.

#### Scenario: Proposal is appended
- **WHEN** the dedicated proposal mutator accepts a proposal
- **THEN** the Mission Plan SHALL retain its app-owned stable proposal ID, deterministic `canonicalRequestIdentity`, base plan ID, versioned base contract snapshot, base contract fingerprint, summary representation, summary/rationale, advisory categories, remedy, evidence IDs, versioned canonical requested-change value, runtime actor metadata, and app-owned timestamp.

#### Scenario: Proposal is resolved
- **WHEN** a trusted resolution transaction succeeds
- **THEN** the ledger SHALL append a separate app-owned resolution with decision/checkpoint linkage, outcome, timestamp, and resulting contract identity where relevant
- **AND** it SHALL NOT rewrite the proposal record.

#### Scenario: Existing Mission is decoded
- **WHEN** persisted Mission data predates proposal fields
- **THEN** proposal and resolution collections SHALL decode as empty.

#### Scenario: Fresh Mission is established
- **WHEN** `rememberObjective` or equivalent fresh-Mission reset clears prior Mission Plan state
- **THEN** proposal and resolution collections SHALL also be cleared.

### Requirement: Material contract identity is canonical and versioned
The system SHALL define proposal authority using structural equality of a versioned canonical material-contract snapshot and SHALL derive a deterministic SHA-256 fingerprint from that same canonical snapshot.

#### Scenario: Snapshot is created
- **WHEN** the current approved Mission contract is canonicalized
- **THEN** it SHALL include objective/scope, predecessor lineage, workstreams, node membership/dependencies/workflow/execution policy/done criteria, planned write/worktree strategy, policy, autonomy, pace, concurrency, pinned context/skills, and guidance.

#### Scenario: Runtime state is canonicalized
- **WHEN** runtime-assigned worktree IDs, node status, session/interaction bindings, evidence, decisions, events, child observations, terminal provenance, or continuation bookkeeping change
- **THEN** those runtime fields SHALL be excluded from the material-contract snapshot
- **AND** evidence-only progress SHALL NOT invalidate a proposal base.

#### Scenario: Fingerprint is computed
- **WHEN** the snapshot is serialized for hashing
- **THEN** workstream IDs, node IDs, dependency lists, autonomy keys, pinned context/skills, and all map/set-like inputs SHALL be deterministically sorted
- **AND** the fingerprint SHALL identify the exact stored snapshot.

#### Scenario: Proposal authority is checked
- **WHEN** proposal creation or resolution validates its base
- **THEN** structural equality against the stored canonical base snapshot SHALL be authoritative
- **AND** `CoordinatorMissionPlan.revision` SHALL NOT be used as the contract CAS token.

### Requirement: Canonical request identity supports exact pending retries
The system SHALL derive deterministic `canonicalRequestIdentity` from an identity-format version, base contract identity, sorted affected contract-field categories, remedy category, sorted supporting evidence IDs, and a versioned conservative canonical requested-change value. It SHALL exclude summary, rationale, timestamps, and app-owned metadata.

#### Scenario: Requested change is conservatively canonicalized
- **WHEN** the server canonicalizes raw `requested_change`
- **THEN** it SHALL apply versioned Unicode NFC, trim surrounding whitespace, and collapse every internal whitespace run to one ASCII space
- **AND** it SHALL preserve case, punctuation, and all other characters.

#### Scenario: Exact logical request is retried while pending
- **WHEN** the owning runtime repeats a pending request with the same base/structured identity fields and a raw requested change differing only by Unicode normalization form or whitespace canonicalized above
- **THEN** the append SHALL be idempotent and return the existing proposal ID
- **AND** summary/rationale-only or timestamp differences SHALL NOT change the identity.

#### Scenario: Differently written request arrives while one is pending
- **WHEN** case, punctuation, non-whitespace text, structured identity fields, or base contract identity produces a different `canonicalRequestIdentity` while a proposal is pending
- **THEN** the request SHALL be rejected under the one-pending invariant
- **AND** the response SHALL identify the pending proposal.

#### Scenario: Request is submitted after prior resolution
- **WHEN** the same or a differently written request is submitted after the prior proposal resolves
- **THEN** v1 SHALL NOT consult or create a rejection-suppression key
- **AND** the system MAY create a new proposal occurrence with a new app-owned proposal ID against the applicable base contract.

### Requirement: Proposal filing emits a non-decision runtime event
Proposal filing SHALL append exactly one non-decision proposal event attributed to the Director/runtime actor and SHALL NOT append any user or Director decision-ledger record.

#### Scenario: Proposal filing is recorded
- **WHEN** a summary proposal is durably appended
- **THEN** its filing event SHALL reference the proposal ID and runtime actor so receipt history can explain the pause
- **AND** the event SHALL NOT use a decision-record shape, decision ID, checkpoint decision, or user-decision metadata.

#### Scenario: Runtime attempts decision-ledger filing
- **WHEN** proposal ingress supplies or implies Director decision-ledger or user-decision fields
- **THEN** the mutation SHALL reject those fields
- **AND** it SHALL preserve decision-ledger integrity.

### Requirement: Proposal mutation cannot use generic Mission Plan updates
Proposal append and resolution SHALL be available only through dedicated Mission ledger mutators and SHALL NOT be representable in `CoordinatorMissionPlanUpdate`.

#### Scenario: Generic update is applied
- **WHEN** `mission_plan` updates ordinary permitted state
- **THEN** existing proposal and resolution collections SHALL be preserved structurally
- **AND** the update payload SHALL NOT inject, replace, remove, or resolve proposal records.

#### Scenario: Generic update attempts proposal fields
- **WHEN** a generic update includes proposal, resolution, or user-decision impersonation fields
- **THEN** the request SHALL be rejected without changing canonical proposal state.

### Requirement: Resolution history is first-writer-wins and terminal-safe
The ledger SHALL accept only the first effective proposal resolution, SHALL make identical retries idempotent, and SHALL resolve pending proposals before terminal freezing.

#### Scenario: Identical resolution is retried
- **WHEN** the same trusted action is retried for an already identically resolved proposal
- **THEN** the transaction SHALL return idempotently without appending a duplicate effective resolution.

#### Scenario: Conflicting decision is retried
- **WHEN** Revise and Keep race or a conflicting action follows an existing resolution
- **THEN** the later conflicting action SHALL be rejected as stale.

#### Scenario: Mission completes or stops
- **WHEN** a Mission terminalizes with a pending proposal
- **THEN** the terminal transaction SHALL append `invalidatedMissionTerminal`, `stopped`, or the applicable terminal resolution before freezing state
- **AND** Stop SHALL win concurrent races.

### Requirement: Material contract delta is canonical and reusable
The system SHALL expose one model-level `materialContractDelta(from:to:proposalAffectedFields:)` over canonical material-contract snapshots. Its deterministic structural output SHALL classify added, removed, changed, and unchanged fields; retain canonical before/after values; distinguish planned worktree strategy from excluded runtime worktree/session bindings; and classify each change as within or outside the proposal's stated affected areas.

#### Scenario: Revised contract drifts beyond its promise
- **WHEN** a concrete revised plan changes material fields outside the accepted proposal's `affected_fields`
- **THEN** the canonical delta SHALL classify those fields as outside stated affected areas
- **AND** runtime-only bindings SHALL never appear as material changes.
