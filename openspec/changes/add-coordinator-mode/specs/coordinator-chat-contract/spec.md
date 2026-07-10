## ADDED Requirements

### Requirement: External `coordinator_chat` control surface
The system SHALL expose the core Coordinator Mission runtime through the `coordinator_chat` MCP tool.

#### Scenario: Supported operations are advertised
- **WHEN** a caller invokes `coordinator_chat op="doctor"`
- **THEN** the response SHALL list supported operations including `list`, `list_missions`, `doctor`, `select`, `new`, `ensure_mission`, `start_mission`, `stop_mission`, `archive_mission`, `submit`, `mission_plan`, `mission_status`, `mission_events`, `receipt`, `set_pace`, `set_autonomy`, and `wait_for_update`.

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

### Requirement: Mission start publishes an approval checkpoint
The system SHALL ensure external Mission starts produce a visible, revision-bound plan approval boundary before ordinary delegation.

#### Scenario: Runtime publishes an initial plan
- **WHEN** `start_mission` or `ensure_mission` accepts an initial directive
- **THEN** the tool SHALL wait briefly for a Mission Plan whose approval state is `awaiting_approval` and which has at least one node
- **AND** it SHALL return that plan when visible.

#### Scenario: Runtime does not publish an initial plan in time
- **WHEN** the initial awaiting-approval plan does not become visible before the configured timeout
- **THEN** the app SHALL publish a fallback scoped intake Mission Plan
- **AND** that fallback SHALL keep delegation blocked until plan approval.

#### Scenario: Plan approval checkpoint identifies the revision
- **WHEN** compact Mission status reports an awaiting-approval plan
- **THEN** it SHALL expose a `checkpoint_instance_id` derived from Coordinator session ID and Mission Plan revision
- **AND** approval-granting checkpoint submit actions SHALL include the expected instance ID.

#### Scenario: Missing expected checkpoint ID is rejected
- **WHEN** a caller submits an approval-granting checkpoint action without `expected_checkpoint_instance_id`
- **THEN** the system SHALL reject it and record no user decision
- **AND** it SHALL return guidance to refresh compact `mission_status` and resubmit with the current checkpoint instance.

#### Scenario: Stale checkpoint grant is rejected
- **WHEN** a caller submits an approval-granting checkpoint action with an old `expected_checkpoint_instance_id`
- **THEN** the system SHALL reject it and record no user decision
- **AND** it SHALL return the current checkpoint instance guidance.

#### Scenario: Stale stop remains accepted
- **WHEN** a caller submits a stale `stop` checkpoint action
- **THEN** the system MAY accept it because stop withdraws approval rather than granting it.

#### Scenario: Runtime caller cannot perform checkpoint action
- **WHEN** a Coordinator runtime caller submits a checkpoint action such as `proceed`, revision approval, or `stop` through `submit`
- **THEN** the system SHALL reject approval-granting actions as user impersonation
- **AND** Stop authority SHALL remain on the app/external user lifecycle path rather than runtime self-stop.

#### Scenario: Approved continuation is durable and status-visible
- **WHEN** a user approves a Mission Plan with the current checkpoint instance and `proceed`
- **THEN** the approval transaction SHALL durably record the user decision, approved plan state, and a post-approval continuation record before any runtime resume is attempted
- **AND** `mission_status` SHALL expose the continuation lifecycle status as `pending`, `deferred`, `dispatching`, `delivered`, `failed`, or `invalidated` through the Mission Plan summary
- **AND** compact status fingerprints SHALL change when that lifecycle status, attempt count, or last error changes.

#### Scenario: Deferred continuation drains once without external resubmit
- **WHEN** the approved continuation is blocked because the Coordinator runtime is busy
- **THEN** the continuation SHALL become `deferred` without counting another attempt on repeated busy observations
- **AND** the runtime SHALL evaluate the deferred continuation at ordinary turn boundaries independently from visible Coordinator UI refresh
- **AND** one later accepted dispatch SHALL transition through `dispatching` to `delivered`
- **AND** the app SHALL NOT require or emit a second external user `submit` for that accepted continuation.

#### Scenario: Continuation dispatch failures are terminally visible
- **WHEN** an actual continuation dispatch is attempted and delivery is rejected for a non-busy reason
- **THEN** the continuation SHALL transition to `failed` with `last_error`
- **AND** it SHALL NOT be reported as `delivered` unless the directive delivery was accepted.

### Requirement: Mission Plan updates are state-only MCP operations
The system SHALL allow external clients and Coordinator runtimes to mutate Mission Plan state without submitting an ordinary Coordinator chat turn.

#### Scenario: Mission Plan update is accepted
- **WHEN** a caller invokes `coordinator_chat op="mission_plan"` with objective, workstreams, nodes, routing, policy, autonomy, decisions, evidence, status, approval state, or events
- **THEN** the system SHALL merge that payload through Mission Plan update semantics
- **AND** it SHALL NOT submit a Coordinator chat turn or create child sessions merely because state changed.

#### Scenario: Mission Plan accepts additive ledger fields
- **WHEN** a `mission_plan` update includes shape summary, policy snapshot, autonomy map, appended decisions, or appended evidence records
- **THEN** existing clients that send only objective, workstreams, nodes, routing, approval, status, or events SHALL continue to work
- **AND** ledger arrays SHALL be append-only and ID-deduped rather than replaceable.

#### Scenario: Mission Plan can replace DAG entries explicitly
- **WHEN** a `mission_plan` update sets the workstream or node replacement flag
- **THEN** the corresponding DAG entries MAY be replaced according to the documented merge semantics
- **AND** decision and evidence ledgers SHALL remain append-only.

#### Scenario: Approval states distinguish writable and output-only authority
- **WHEN** `mission_plan` receives an approval state from a runtime or generic state update
- **THEN** draft/revision states such as `awaiting_approval` MAY be accepted only as non-authorizing runtime output
- **AND** `approved` SHALL be writable only by the trusted user checkpoint transaction
- **AND** `not_required` SHALL NOT be writable in the current demo and, if decoded from legacy payloads, SHALL be output-only recovery information that does not authorize progress or delegation.

### Requirement: Mission status and waits expose automation-safe state
The system SHALL provide read-only status surfaces sufficient for external drivers and Coordinator runtimes.

#### Scenario: Full mission_status is requested
- **WHEN** a caller invokes `coordinator_chat op="mission_status"` without compact mode
- **THEN** the response SHALL include the full Mission Plan, shape, policy, autonomy summary, decision counts by actor, evidence counts, recent ledger entries, receipt-ready summary, node counts, workstream bindings, nodes, recent events, and recent routing decisions.

#### Scenario: Compact mission_status is requested
- **WHEN** a caller invokes `mission_status` with `compact:true`
- **THEN** the response SHALL include a fingerprint, plan summary, decision/evidence counts, recent ledger entries, receipt-ready summary, node counts, compact workstreams, ready node IDs, active nodes, missing bindings, liveness warnings, checkpoint metadata, recent events, and recent routing decisions.

#### Scenario: Fingerprint-moving state changes
- **WHEN** any field that can unblock waiters changes, including plan revision/status/approval, policy/autonomy, node/workstream state, dependency satisfaction, ready nodes, decisions, evidence, child rows, fleet motion, or liveness warnings
- **THEN** the compact Mission status fingerprint SHALL change.

#### Scenario: wait_for_update sees a new fingerprint
- **WHEN** `wait_for_update` receives `since_fingerprint` and the current compact fingerprint differs
- **THEN** it SHALL return `changed:true`, `timed_out:false`, and compact Mission status.

#### Scenario: wait_for_update times out
- **WHEN** the fingerprint does not change before timeout
- **THEN** it SHALL return `changed:false`, `timed_out:true`, and the latest compact Mission status.

### Requirement: Mission event journal is observational
The system SHALL expose sequenced Mission transition events for harness observation without making the journal authoritative state.

#### Scenario: mission_events is requested
- **WHEN** a caller invokes `coordinator_chat op="mission_events"` with `since_seq` and optional `limit`
- **THEN** the response SHALL include events, `next_seq`, optional oldest/latest sequence numbers, truncation flag, and `event_source:"mission_events"`.

#### Scenario: Event entry is serialized
- **WHEN** a Mission event journal entry is returned
- **THEN** it SHALL include sequence, observed timestamp, Coordinator session ID, fingerprint, title, selected/run-state flags, plan summary, node counts, ready/active node IDs, compact node summaries, recent event/routing/decision/evidence IDs, and liveness warnings.

#### Scenario: Journal is unavailable after restart
- **WHEN** in-memory Mission events are unavailable
- **THEN** Mission Plan and `mission_status` SHALL remain the authoritative source of Mission state.

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

#### Scenario: Workflow-bearing node is delegated
- **WHEN** the Coordinator delegates a workflow-bearing Mission node
- **THEN** the delegated `agent_run` operation SHOULD carry the same workflow name or ID recorded in the Mission Plan.

#### Scenario: Traceability remains discoverable
- **WHEN** maintainers need to verify the MCP contract
- **THEN** primary enforcement SHOULD be discoverable in `CoordinatorChatMCPToolService.swift`, `MCPAgentControlToolProvider.swift`, `AgentModePrompts.swift`, and `CoordinatorMissionEventJournal.swift`
- **AND** relevant tests SHOULD include `CoordinatorChatMCPToolServiceTests.testDoctorReportsCoordinatorCapabilities`, `testStartMissionWaitsForInitialAwaitingApprovalPlan`, `testStartMissionPublishesFallbackInitialPlanWhenRuntimePlanDoesNotAppear`, `testMissionPlanRuntimeCallerDefaultsToCallerMissionNotSelectedMission`, `testMissionStatusReturnsCompactDagStatus`, `testWaitForUpdateAdvancesAfterDecisionAndEvidenceAppendWithoutRevisionChange`, and `SystemPromptServiceCoordinatorModeTests` coverage for Coordinator runtime instructions.
