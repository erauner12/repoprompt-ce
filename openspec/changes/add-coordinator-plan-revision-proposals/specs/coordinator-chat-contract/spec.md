## MODIFIED Requirements

### Requirement: External `coordinator_chat` control surface
The system SHALL expose the core Coordinator Mission runtime through the `coordinator_chat` MCP tool.

#### Scenario: Supported operations are advertised
- **WHEN** a caller invokes `coordinator_chat op="doctor"`
- **THEN** `supported_ops` SHALL include `list`, `list_missions`, `doctor`, `select`, `new`, `ensure_mission`, `start_mission`, `stop_mission`, `archive_mission`, `submit`, `mission_plan`, `propose_revision`, `mission_status`, `mission_events`, `receipt`, `set_pace`, `set_autonomy`, and `wait_for_update`
- **AND** doctor SHALL expose `features.revision_proposals` exactly as `{ "version": 1, "representation": "summary_only", "actions": ["revise_plan", "keep_current_plan", "stop_mission"] }` for harness preflight.

#### Scenario: Tool input schema advertises revision proposal support
- **WHEN** a caller inspects the public `coordinator_chat` input schema or operation guidance
- **THEN** `propose_revision` SHALL appear in the supported op values with its summary-only input fields, including base contract identity, summary/rationale, affected fields, remedy category, supporting evidence IDs, and raw `requested_change`
- **AND** the input schema SHALL advertise only op values and accepted fields, without duplicating the doctor feature object or requiring extra wrapper plumbing.

#### Scenario: Mission creation can pin the Coordinator model
- **WHEN** an external caller starts a fresh Mission through `start_mission`, `ensure_mission`, `new`, or `submit new_parent=true`
- **AND** it passes `coordinator_model_id`
- **THEN** the app SHALL pass that value to the fresh Coordinator runtime creation path
- **AND** the override SHALL NOT change Coordinator identity, prompt contract, tool policy, child answer attribution, or Mission Policy semantics.

#### Scenario: Runtime callers cannot create parent Missions
- **WHEN** a Coordinator runtime caller invokes `new`, `start_mission`, `ensure_mission`, or `submit new_parent=true`
- **THEN** the tool SHALL reject the request
- **AND** it SHALL instruct the runtime to record a follow-up recommendation instead of creating a parent Mission.

#### Scenario: Runtime callers resolve to their own Mission
- **WHEN** a Coordinator runtime caller invokes a Mission-scoped operation without `coordinator_session_id`
- **THEN** the system SHALL resolve the caller's own Coordinator Mission from request metadata
- **AND** it SHALL fail closed when that Mission cannot be resolved
- **AND** it SHALL NOT fall back to whichever Mission the user has selected in the UI.

#### Scenario: Runtime caller explicit Mission scope must match ownership
- **WHEN** a Coordinator runtime caller invokes a Mission-scoped operation with an explicit `coordinator_session_id`
- **THEN** the system SHALL verify that the requested Mission is the caller's owning Mission
- **AND** cross-Mission IDs, selected-Mission fallback, and unresolved caller metadata SHALL fail closed before any write or status-changing action is applied.

#### Scenario: Runtime callers cannot invoke user-action parity ops
- **WHEN** a Coordinator runtime caller invokes `set_pace`, `set_autonomy`, checkpoint submit as user, or `archive_mission`
- **THEN** the tool SHALL reject the request because those paths represent external user action or lifecycle authority.

### Requirement: Coordinator prompt and tool schemas describe the runtime contract
The system SHALL guide Coordinator runtimes toward the Mission control-plane contract.

#### Scenario: Agent control tools are advertised
- **WHEN** MCP schemas describe `agent_run` and `agent_explore`
- **THEN** they SHALL include `mission_node_id` where relevant
- **AND** `agent_run` SHALL include workflow metadata and Coordinator-internal marker fields needed by Mission Plan nodes.

#### Scenario: Coordinator runtime prompt is assembled
- **WHEN** a Coordinator runtime receives system guidance
- **THEN** it SHALL be told to use `coordinator_chat op=mission_plan` and `mission_status` for concrete user-specific deliverables before delegation
- **AND** it SHALL be told not to call `coordinator_chat op=start_mission` for follow-up Missions
- **AND** it SHALL use raw Coordinator keys only inside structured payloads/debug contracts.

#### Scenario: Runtime prompt explains contract-changing drift
- **WHEN** the owning Coordinator runtime receives system guidance for an approved Mission
- **THEN** it SHALL be taught to use `coordinator_chat op=propose_revision` only when the requested remedy changes the approved material contract
- **AND** it SHALL be taught that ordinary evidence, failures, tool errors, and changed assumptions remain evidence/failure bookkeeping or explanatory prose unless the requested remedy changes contract fields
- **AND** it SHALL be forbidden from directly revising the approved contract, resolving its own proposal, authoring a user decision, or treating proposal filing as approval.

#### Scenario: Workflow-bearing node is delegated
- **WHEN** the Coordinator delegates a workflow-bearing Mission node
- **THEN** the delegated `agent_run` operation SHOULD carry the same workflow name or ID recorded in the Mission Plan.

#### Scenario: Traceability remains discoverable
- **WHEN** maintainers need to verify the MCP contract
- **THEN** primary enforcement SHOULD be discoverable in `CoordinatorChatMCPToolService.swift`, `MCPAgentControlToolProvider.swift`, `AgentModePrompts.swift`, and `CoordinatorMissionEventJournal.swift`
- **AND** relevant tests SHOULD include `CoordinatorChatMCPToolServiceTests.testDoctorReportsCoordinatorCapabilities`, proposal-operation schema/feature-signal coverage, `testStartMissionWaitsForInitialAwaitingApprovalPlan`, `testStartMissionPublishesFallbackInitialPlanWhenRuntimePlanDoesNotAppear`, `testMissionPlanRuntimeCallerDefaultsToCallerMissionNotSelectedMission`, `testMissionStatusReturnsCompactDagStatus`, `testWaitForUpdateAdvancesAfterDecisionAndEvidenceAppendWithoutRevisionChange`, and `SystemPromptServiceCoordinatorModeTests` coverage for `propose_revision`, ordinary evidence/failure distinction, and self-revision/self-resolution prohibitions.

## ADDED Requirements

### Requirement: Owning runtime can propose a summary-only contract revision
The system SHALL expose `coordinator_chat op="propose_revision"` only to the verified Coordinator runtime that owns the target approved, nonterminal Mission.

#### Scenario: Owning Director files a proposal
- **WHEN** the owning Coordinator runtime supplies a summary, rationale, advisory affected-field categories, remedy category, supporting evidence IDs, raw `requested_change`, and matching base contract identity
- **THEN** the server SHALL derive `canonicalRequestIdentity` from the base/structured fields and the versioned conservative canonical form of raw `requested_change`
- **AND** the operation SHALL append a summary-only revision proposal through the dedicated proposal mutation path
- **AND** it SHALL append only a non-decision proposal event attributed to the Director/runtime actor
- **AND** it SHALL persist the proposal pause before returning success.

#### Scenario: Caller does not own the Mission
- **WHEN** an external caller, internal non-owner worker, caller with missing runtime identity, or runtime for another Mission invokes `propose_revision`
- **THEN** the system SHALL reject the request
- **AND** it SHALL NOT fall back to the Mission selected in the UI.

#### Scenario: Mission cannot accept a proposal
- **WHEN** the target Mission is unapproved, terminal, absent, or its current material contract does not match the supplied base identity
- **THEN** the system SHALL reject the proposal without mutating Mission state.

#### Scenario: Caller supplies a canonical identity field
- **WHEN** proposal ingress supplies caller-authored `canonicalRequestIdentity` or a caller-owned canonical requested-change value
- **THEN** the server SHALL reject that authority field
- **AND** exact pending-retry identity SHALL always use the server-derived `canonicalRequestIdentity`.

#### Scenario: Exact replacement is supplied in v1
- **WHEN** a `propose_revision` request includes a complete replacement plan, exact replacement diff, or request for immediate revised-plan approval
- **THEN** the system SHALL reject the unsupported payload
- **AND** it SHALL direct the caller to the summary-only proposal contract.

### Requirement: Proposal ingress cannot exercise user or contract authority
A successful `propose_revision` operation SHALL append proposal state plus a non-decision Director/runtime-attributed proposal event only and SHALL NOT append to any decision ledger or change the approved contract, approval state, user decision ledger, node starts, runtime bindings, or proposal resolution state.

#### Scenario: Director files a valid proposal
- **WHEN** proposal append succeeds
- **THEN** the approved contract SHALL remain unchanged
- **AND** the proposal SHALL remain unresolved until a trusted external user action occurs
- **AND** the filing history SHALL be a non-decision proposal event attributed to the Director/runtime actor
- **AND** it SHALL NOT use a decision-record shape or any user-decision metadata.

#### Scenario: Runtime attempts proposal resolution
- **WHEN** a runtime or internal non-owner caller submits Revise plan or Keep current plan
- **THEN** the system SHALL reject the action as user-owned
- **AND** it SHALL NOT append a user decision or proposal resolution.

### Requirement: External submit resolves a rendered proposal checkpoint
The external Mission-aware `coordinator_chat submit` path SHALL support proposal actions `revise_plan` and `keep_current_plan` with proposal ID, expected contract identity, and expected checkpoint instance ID.

#### Scenario: External user submits Revise plan
- **WHEN** an external user submits `checkpoint_action="revise_plan"` with matching proposal, contract, and checkpoint identities
- **THEN** the app SHALL execute the trusted proposal-resolution transaction
- **AND** the response SHALL NOT imply that an exact revised contract was approved.

#### Scenario: External user submits Keep current plan
- **WHEN** an external user submits `checkpoint_action="keep_current_plan"` with matching proposal, contract, and checkpoint identities
- **THEN** the app SHALL execute the trusted rejection transaction while preserving the approved contract.

#### Scenario: Proposal action is stale
- **WHEN** Revise plan or Keep current plan names a resolved proposal, wrong proposal ID, changed contract identity, or obsolete checkpoint instance
- **THEN** the action SHALL fail closed as stale
- **AND** it SHALL NOT append a conflicting decision.

#### Scenario: External drafting guidance is bound to the accepted resolution
- **WHEN** an external caller submits message-only revised-plan drafting guidance after Revise plan
- **THEN** the public schema and Mission status SHALL expose `accepted_revision_resolution_id` as an identity copied from `revision_proposal.accepted_drafting.submit_hints`
- **AND** the submit SHALL require an explicit target Mission and an exact authoritative accepted resolution identity
- **AND** generic directives, runtime callers, child answers, stale identities, Stop, and revised-plan approval SHALL NOT acquire drafting authority from selection or projected UI state
- **AND** retrying the same identity after its concrete revised plan is already awaiting approval SHALL return an idempotent success without sending another directive or bypassing exact revised-plan approval.

#### Scenario: External user submits Stop
- **WHEN** an external user submits target-bound Stop while a proposal is pending
- **THEN** Stop SHALL remain stale-tolerant because it withdraws consent
- **AND** it SHALL terminalize the Mission through the app-owned Stop path.

### Requirement: Proposal lifecycle is visible to machine consumers
Mission status, compact status, wait fingerprints, doctor feature discovery, public input schema, and event responses SHALL expose stable proposal lifecycle information without duplicating a replacement payload.

#### Scenario: Proposal is pending
- **WHEN** Mission status is requested
- **THEN** it SHALL report the pending proposal ID, base contract identity, summary representation kind, summary, material fields, lifecycle, checkpoint instance, and Revise/Keep submit hints.

#### Scenario: Proposal is resolved
- **WHEN** Mission status or recent events are requested after resolution
- **THEN** they SHALL expose recent resolution identity and outcome
- **AND** compact fingerprints and event candidates SHALL distinguish append from resolution.

#### Scenario: Caller waits for an update
- **WHEN** a proposal is appended or resolved while `wait_for_update` is observing the Mission
- **THEN** the proposal lifecycle change SHALL wake the waiter even if no generic Mission Plan merge revision changes.

### Requirement: Revise plan accepts optional durable guidance
External `submit` with `checkpoint_action: "revise_plan"` MAY include optional `guidance`. Non-empty guidance SHALL be normalized, persisted with the accepted resolution for audit, and included in the trusted revision-drafting directive only after the resolution is durable. Empty guidance SHALL preserve existing directive behavior.

#### Scenario: External user revises with guidance
- **WHEN** an external caller submits valid proposal/checkpoint/contract identity plus `guidance`
- **THEN** identity and CAS authority SHALL remain unchanged
- **AND** the guidance SHALL be delivered only after durable resolution
- **AND** runtime callers and non-Revise actions SHALL reject guidance.
