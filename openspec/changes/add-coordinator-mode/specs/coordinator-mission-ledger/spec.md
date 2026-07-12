## ADDED Requirements

### Requirement: Coordinator Mission runtime state
The system SHALL persist Coordinator Mission runtime state on Coordinator-backed Agent Mode sessions.

#### Scenario: Fresh Mission objective is remembered
- **WHEN** a fresh Coordinator Mission objective is accepted
- **THEN** the system SHALL store a bounded objective summary
- **AND** it SHALL store selected Mission Template metadata when present
- **AND** it SHALL reset previous Mission Plan, observed child phases, pending events, handled events, last resume result, and child interaction response records unless the turn is explicitly preserving same-Mission state.

#### Scenario: Same-Mission follow-up preserves the plan
- **WHEN** a follow-up belongs to the existing Mission
- **THEN** the system MAY update the visible objective summary without clearing the current Mission Plan.

#### Scenario: Older persisted state decodes
- **WHEN** persisted Coordinator follow-through state lacks Mission Plan, routing, decision, evidence, autonomy, or post-approval continuation fields
- **THEN** the system SHALL decode it successfully with safe defaults.

#### Scenario: Post-approval continuation has a canonical owner and mirror
- **WHEN** a post-approval continuation exists
- **THEN** `CoordinatorFollowThroughState.postApprovalContinuation` SHALL be the canonical persisted owner for reset and decode semantics
- **AND** `CoordinatorMissionPlan.postApprovalContinuation` SHALL mirror the same record for status, wait fingerprint, and projection serialization
- **AND** decode SHALL reconcile older payloads by preserving a continuation found in either location.

#### Scenario: Fresh Mission reset clears continuation
- **WHEN** a fresh Coordinator Mission objective resets follow-through state
- **THEN** the system SHALL clear pending/deferred/dispatching/delivered/failed/invalidated post-approval continuation records along with prior Mission Plan and follow-through bookkeeping.

### Requirement: Mission Plan is the durable source of intent and audit state
The system SHALL store Mission intent, execution state, routing, ledgers, and receipt inputs in `CoordinatorMissionPlan`.

#### Scenario: Mission Plan records core fields
- **WHEN** a Mission Plan exists
- **THEN** it SHALL include stable ID, monotonic revision, optional mission key, objective, predecessor context, status, approval state, template summary, shape summary, policy snapshot, autonomy map, workstreams, nodes, routing decisions, decisions, evidence, events, and updated timestamp.

#### Scenario: Partial update preserves omitted fields
- **WHEN** `coordinator_chat op="mission_plan"` omits an existing Mission Plan field
- **THEN** the omitted field SHALL retain its previous value.

#### Scenario: Workstreams and nodes are upserted
- **WHEN** a Mission Plan update includes workstreams or nodes
- **THEN** entries SHALL be upserted by ID when provided
- **AND** otherwise by normalized title when a matching existing entry exists
- **AND** omitted existing entries SHALL be preserved unless the corresponding replace flag is true.

#### Scenario: Routing decisions upsert by ID
- **WHEN** a Mission Plan update includes routing decisions
- **THEN** routing decisions SHALL be inserted or replaced by decision ID
- **AND** returned routing decisions SHALL be ordered chronologically with deterministic tie-breaking.

#### Scenario: Worktree strategy carries stable base metadata
- **WHEN** a Mission Plan workstream declares a worktree strategy
- **THEN** it SHALL preserve the lane's read-only/no-worktree, create-isolated, reuse-existing, reuse-workstream, or ask-user intent
- **AND** partial strategy updates SHALL preserve existing base/worktree metadata unless explicitly replaced.

### Requirement: Mission-owned policy and autonomy snapshot
The system SHALL snapshot Mission Policy and effective autonomy onto each Mission without making Mission Templates a policy store.

#### Scenario: Built-in policies exist
- **WHEN** the policy library is available for the runtime baseline
- **THEN** it SHALL include Default, Hands-off, Careful writes, and Read-only built-ins.

#### Scenario: Policy snapshot fields are stored
- **WHEN** a Mission stores a policy snapshot
- **THEN** the snapshot SHALL include stable ID, name, default pace, autonomy map, `maxConcurrent`, optional Definition of Done, optional standing guidance, pinned skill IDs, and pinned context IDs.

#### Scenario: Autonomy classes resolve safely
- **WHEN** autonomy is queried for a known decision class
- **THEN** the system SHALL resolve from the Mission autonomy map, policy/default autonomy, or Ask fallback
- **AND** known classes SHALL include `plan`, `advance`, `writes`, `childAsk`, `recover`, and `irreversible`
- **AND** `irreversible` SHALL resolve to Ask even if a payload asks for Auto.

#### Scenario: Unknown autonomy classes round-trip
- **WHEN** a Mission Plan contains an unknown autonomy class
- **THEN** the system SHALL preserve the class and raw mode during Codable and MCP round-trips
- **AND** it SHALL resolve the unknown class to Ask for runtime decisions.

### Requirement: Mission ledgers are append-only and receipt-ready
The system SHALL keep decisions and evidence as bounded Mission ledger records rather than hidden transcript imports or replaceable arrays.

#### Scenario: Decisions and evidence append by ID
- **WHEN** Mission decision or evidence records are merged
- **THEN** new record IDs SHALL append
- **AND** duplicate record IDs SHALL be ignored rather than replacing existing records
- **AND** v1 SHALL NOT provide a replace flag for decision or evidence arrays.

#### Scenario: Evidence record is appended
- **WHEN** evidence is appended to a Mission
- **THEN** it SHALL include verdict `meets` or `short`, summary, timestamp, and optional node/workstream/session/interaction/decision references.

#### Scenario: Evidence source is present
- **WHEN** evidence came from a tool or probe result
- **THEN** it MAY include source kind, operation, routing decision ID, node/session/interaction ID, answer ID, and source summary.

#### Scenario: Judgment bundle is present
- **WHEN** evidence is used for Director judgment or receipt disclosure
- **THEN** it MAY include done criteria, structured evidence, diff stats, probe answer summary, and transcript framing
- **AND** transcript framing SHALL default to `not_transcript_summary`.

#### Scenario: Read-only probe is used as evidence
- **WHEN** the Director escalates thin evidence to a read-only probe
- **THEN** only the probe answer, concise summary, and optional export/artifact reference SHALL be appended as evidence
- **AND** the probe transcript, selection, and raw session context SHALL NOT be imported into Director context by default.

### Requirement: Mission state feeds projection and receipts
The system SHALL refresh projected Coordinator/Director surfaces from Mission-owned state.

#### Scenario: Ledger-visible state affects projection refresh
- **WHEN** decision, evidence, policy, autonomy, shape, or receipt-input state changes in a way the Director surface projects
- **THEN** the projected Mission Plan fingerprint SHALL move
- **AND** the visible Director surface SHALL refresh from Mission-owned data rather than local SwiftUI-only state.

#### Scenario: Mission shape remains bounded
- **WHEN** Mission shape is stored for the current baseline
- **THEN** it SHALL be a summary used for plan/receipt/status context
- **AND** larger shape systems, PRD-slice-specific orchestration, and hierarchical Mission decomposition SHALL remain later changes unless already captured as explicit Mission Plan nodes.

#### Scenario: Traceability remains discoverable
- **WHEN** maintainers need to verify Mission ledger behavior
- **THEN** primary enforcement SHOULD be discoverable in `CoordinatorFollowThroughState.swift`, `CoordinatorChatMCPToolService.swift`, and `CoordinatorModeSnapshotProjector.swift`
- **AND** relevant tests SHOULD include `CoordinatorFollowThroughStateTests.testMissionPlanCurrentPersistedFixtureRoundTripsMissionOwnedFields`, `testDecisionAndEvidenceUpdatesAppendOnlyAndDedupeByRecordIDOnly`, `testMissionPlanDirectorDoctrineFieldsRoundTripLosslessly`, `CoordinatorChatMCPToolServiceTests.testMissionPlanAcceptsMissionContractAndAppendOnlyLedgers`, and `CoordinatorModeSnapshotProjectorTests.testMissionSummaryProjectsShapePolicyLedgerCountsAndMovesFingerprint`.
