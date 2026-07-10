## ADDED Requirements

### Requirement: Delegated child starts are Mission-gated
The system SHALL gate Coordinator-owned `agent_run` and `agent_explore` starts on the approved concrete Mission Plan contract.

#### Scenario: Non-Coordinator starts are unaffected
- **WHEN** a non-Coordinator parent starts an Agent Mode child
- **THEN** Coordinator Mission Plan policy SHALL allow the start without requiring a Mission Plan.

#### Scenario: Coordinator start has no approved concrete plan
- **WHEN** a Coordinator parent attempts a normal delegated start without a non-empty approved Mission Plan
- **THEN** the system SHALL deny the start
- **AND** the denial SHALL instruct the Coordinator to use `coordinator_chat op=mission_plan`, record real deliverable nodes, request approval, and retry only after the concrete Mission Plan is approved.

#### Scenario: Approved Mission Plan allows normal delegation
- **WHEN** a Coordinator parent has a Mission Plan with at least one node
- **AND** its `approval_state` is `approved`
- **THEN** normal delegated starts MAY proceed subject to the remaining policy checks.

#### Scenario: Pre-approval read-only explore exception
- **WHEN** an awaiting-approval Mission Plan has a workflow-less `fresh_readonly_child` node
- **AND** `agent_explore.start` includes that node's `mission_node_id`
- **THEN** the start MAY proceed as a pre-approval planning exception.

#### Scenario: Pre-approval workflow planning exception
- **WHEN** an awaiting-approval Mission Plan has a `fresh_readonly_child` node with Investigate or Deep Plan workflow hint
- **AND** `agent_run.start` includes matching built-in workflow ID/name, that node's `mission_node_id`, and `worktree_create:true`
- **THEN** the start MAY proceed as a pre-approval planning exception.

#### Scenario: Pre-approval design critique exception
- **WHEN** an awaiting-approval Mission Plan has a workflow-less `plan_critique` node
- **AND** `agent_run.start` includes `model_id:"design"`, that node's `mission_node_id`, no workflow, and `worktree_create:true`
- **THEN** the start MAY proceed as a pre-approval planning exception.

#### Scenario: Flight cap is reached
- **WHEN** the Mission has running node count greater than or equal to policy `maxConcurrent`
- **THEN** `agent_run.start` and `agent_explore.start` SHALL be denied
- **AND** the denial SHALL instruct the caller to wait for capacity with `coordinator_chat op=wait_for_update`.

#### Scenario: Delegation-gate traceability is discoverable
- **WHEN** maintainers verify delegation gating
- **THEN** enforcement SHOULD be discoverable in `AgentRunCoordinatorMissionPlanPolicy.swift`, `MCPAgentControlToolProvider.swift`, and `CoordinatorChatMCPToolService.swift`
- **AND** tests SHOULD include `AgentRunCoordinatorMissionPlanPolicyTests.testCoordinatorBlocksNilPlan`, `testCoordinatorBlocksAwaitingApprovalPlan`, `testCoordinatorAllowsApprovedPlanWithNodes`, `testCoordinatorAllowsPreApprovalLightweightDiscoveryExploreNode`, `testCoordinatorAllowsPreApprovalDeepPlanNodeWithFreshWorktree`, `testCoordinatorAllowsPreApprovalDesignCritiqueNodeWithFreshWorktree`, `testCoordinatorDeniesStartAtExactFlightCapForRunAndExplore`, and `testCoordinatorFlightCapCountsRunningNodesNotBoundSessions`.

### Requirement: Mutable Coordinator delegation requires explicit sandboxing
The system SHALL require explicit child execution isolation before mutable Coordinator work starts.

#### Scenario: Read-only delegation omits worktree
- **WHEN** Coordinator-delegated work is read-only investigation, summarization, or status work
- **THEN** the child MAY be started without an explicit worktree sandbox.

#### Scenario: Mutable delegation includes sandbox
- **WHEN** Coordinator-delegated work may edit files, run validation that writes outputs, generate merge previews, commit, or prepare a PR
- **THEN** the child start SHALL include an explicit sandbox such as `worktree_create:true` or `worktree_id`
- **AND** inherited worktree binding alone SHALL NOT satisfy this requirement.

#### Scenario: Mutable delegation lacks sandbox
- **WHEN** a Coordinator-owned mutable child start lacks explicit sandboxing
- **THEN** the app SHALL reject the start before creating the child session
- **AND** it SHALL tell the Coordinator how to retry with `worktree_create:true` or an existing `worktree_id`.

#### Scenario: Sandbox-gate traceability is discoverable
- **WHEN** maintainers verify mutable delegation sandboxing
- **THEN** enforcement SHOULD be discoverable in `AgentRunCoordinatorMissionPlanPolicy.swift` and `AgentRunCoordinatorWorktreePolicy.swift`
- **AND** tests SHOULD include `AgentRunCoordinatorMissionPlanPolicyTests.testCoordinatorBlocksPreApprovalInvestigateWithoutFreshWorktree`, `testCoordinatorBlocksPreApprovalCritiqueWithoutCreatedWorktree`, and `AgentRunCoordinatorWorktreePolicyTests` coverage for mutable Coordinator worktree requirements.

### Requirement: Node state validators preserve trustworthy plans
The system SHALL validate node state transitions and bindings at the Mission Plan update boundary.

#### Scenario: Running delegated node lacks session binding
- **WHEN** a node with execution policy `fresh_readonly_child`, `fresh_worktree`, `steer_primary`, `fresh_sibling_on_same_worktree`, or `plan_critique` is updated to `running`
- **THEN** it SHALL include `bound_session_id`.

#### Scenario: Running ask-user node lacks interaction binding
- **WHEN** a node with execution policy `ask_user` is updated to `running`
- **THEN** it SHALL include `bound_interaction_id`.

#### Scenario: Completed node lacks evidence
- **WHEN** a node is updated to `completed`
- **THEN** it SHALL include non-empty completion evidence
- **AND** the evidence SHALL describe result evidence rather than stale waiting/bound state.

#### Scenario: Mission completion requires terminal nodes
- **WHEN** a Mission Plan update requests `status:"completed"`
- **THEN** every node SHALL be terminal
- **AND** otherwise the update SHALL be rejected at the MCP boundary or coerced by shared merge logic so the Mission remains non-completed.

#### Scenario: Terminal node status is monotonic
- **WHEN** an existing node is terminal
- **AND** a later update tries to regress it to a non-terminal status
- **THEN** the system SHALL preserve the terminal status and its terminal evidence.

#### Scenario: Pre-approval runtime progress is attempted
- **WHEN** Mission approval state is not `approved`
- **AND** an update advances Mission status or node status into runtime progress
- **THEN** the update SHALL be rejected except for the explicit pre-approval delegated start policy above.

#### Scenario: Validator traceability is discoverable
- **WHEN** maintainers verify node-state validators
- **THEN** enforcement SHOULD be discoverable in `CoordinatorFollowThroughState.swift` and `CoordinatorChatMCPToolService.swift`
- **AND** tests SHOULD include `CoordinatorChatMCPToolServiceTests.testMissionPlanRejectsRunningDelegatedNodeWithoutBinding`, `testMissionPlanRejectsRuntimeProgressBeforeInitialApproval`, `testMissionPlanRejectsCompletedNodeWithStaleWaitingEvidence`, `testMissionPlanRejectsCompletedStatusWithPendingNodes`, `CoordinatorFollowThroughStateTests.testMissionPlanUpdateCannotCompleteWithMergedPendingNodes`, and `testMissionPlanUpdateCannotRegressTerminalNodeStatus`.

### Requirement: Plan approval has exactly one door
The system SHALL allow `approval_state` to advance to `approved` only through the user checkpoint/continuation approval path.

#### Scenario: User checkpoint approval advances approval_state
- **WHEN** the app or external user submit path accepts the current revision-bound plan approval checkpoint
- **THEN** it MAY advance the Mission Plan to `approval_state:"approved"`
- **AND** it SHALL record the corresponding user-actor approval decision before ordinary runtime progress or delegation can proceed.

#### Scenario: Runtime self-approval is rejected
- **WHEN** a Coordinator runtime or generic `mission_plan` state update attempts to advance `approval_state` to `approved` without the user checkpoint/continuation path
- **THEN** the system SHALL reject the update or preserve the prior non-approved state
- **AND** it SHALL NOT treat Director/runtime self-approval as a second approval-granting door.

#### Scenario: Runtime approval waiver is rejected
- **WHEN** a Coordinator runtime or generic `mission_plan` state update attempts to create or transition a Mission Plan to `approval_state:"not_required"`
- **THEN** the system SHALL reject the update or preserve the prior approval-gated state
- **AND** legacy persisted `not_required` payloads, if decoded for compatibility, SHALL NOT authorize ordinary runtime progress or delegated starts.

#### Scenario: Approval downgrade after approval is rejected
- **WHEN** a later runtime update attempts to downgrade an already approved plan to a weaker approval state
- **THEN** the system SHALL reject that downgrade or preserve the approved state unless a user-authored revision/stop path explicitly changes the Mission boundary.

#### Scenario: Approval traceability is discoverable
- **WHEN** maintainers verify approval-state transitions
- **THEN** enforcement SHOULD be discoverable in `CoordinatorModeViewModel` checkpoint handling and `CoordinatorChatMCPToolService` Mission Plan update gates
- **AND** tests SHOULD include `CoordinatorChatMCPToolServiceTests.testSubmitWithCheckpointActionAcceptsCurrentExpectedCheckpointInstance`, `testSubmitWithCheckpointActionRejectsStaleExpectedCheckpointInstance`, `testMissionPlanRejectsRuntimeProgressBeforeInitialApproval`, `testMissionPlanRejectsApprovalDowngradeAfterApproval`, and regression tests for runtime self-approval and approval-waiver attempts if they are not already present.

### Requirement: Mission decisions preserve actor integrity
The system SHALL record user and Director decisions through separate trusted paths.

#### Scenario: User checkpoint decision is recorded
- **WHEN** the app or external submit path records plan approval, plan revision, step continuation, child-answer submit, stop, pace, or childAsk route changes
- **THEN** it SHALL record a user-actor decision using a deterministic checkpoint-instance-derived ID.

#### Scenario: Runtime appends Director decision
- **WHEN** the Coordinator runtime records its own routing, childAsk, evidence acceptance, or recovery decision
- **THEN** it SHALL append a Director-actor decision through `coordinator_chat op="mission_plan"`.

#### Scenario: Runtime tries to append user decision
- **WHEN** `mission_plan` payload attempts to append a user-actor decision
- **THEN** the system SHALL reject it
- **AND** it SHALL state that user decisions are recorded by app/MCP submit paths.

#### Scenario: Decision IDs dedupe retries
- **WHEN** the same checkpoint instance and label are submitted repeatedly
- **THEN** they SHALL produce the same user decision ID and dedupe in the decision ledger.

#### Scenario: Plan revision changes checkpoint identity
- **WHEN** a plan is revised and then approved
- **THEN** the approval decision SHALL use a different checkpoint instance from the pre-revision approval checkpoint.

#### Scenario: Actor-integrity traceability is discoverable
- **WHEN** maintainers verify actor integrity
- **THEN** enforcement SHOULD be discoverable in `CoordinatorMissionDecisionRecord`, `CoordinatorModeViewModel`, and `CoordinatorChatMCPToolService.swift`
- **AND** tests SHOULD include `CoordinatorChatMCPToolServiceTests.testMissionPlanRejectsUserDecisionActorAndMissingLedgerIDs`, `testSetPaceRoutesThroughExternalUserActionPath`, `testSetAutonomyRoutesThroughExternalUserActionPath`, `testSetPaceRejectsCoordinatorRuntimeCaller`, `testSetAutonomyRejectsCoordinatorRuntimeCaller`, `CoordinatorFollowThroughStateTests.testPlanUserDecisionIDsAreDeterministicAcrossRetriesAndRevisionAware`, and `CoordinatorModeComposerViewModelTests.testPlanCheckpointUserDecisionsAppendThroughMissionUpdaterAndRefresh`.

### Requirement: childAsk routing is ledger-enforced
The system SHALL route Mission-bound child questions according to effective `childAsk` autonomy and require matching ledger evidence.

#### Scenario: childAsk resolves to Ask
- **WHEN** a Mission-bound child question is pending and `childAsk` resolves to Ask
- **THEN** the question SHALL be visible for user response
- **AND** Coordinator runtime child-answer attempts SHALL be rejected.

#### Scenario: childAsk resolves to Auto
- **WHEN** a Mission-bound child question is pending and `childAsk` resolves to Auto
- **THEN** the Coordinator runtime MAY answer as Director through `coordinator_chat submit`
- **AND** it SHALL record a Director `childAsk` decision and evidence for the same interaction.

#### Scenario: Generic child response would bypass ledger
- **WHEN** a caller tries to answer an active Mission-bound child question through generic `agent_run.respond`
- **THEN** the system SHALL reject that path
- **AND** it SHALL direct the caller to `coordinator_chat op=submit` for the owning Coordinator Mission.

#### Scenario: childAsk:auto node completes
- **WHEN** a node bound to a child interaction completes while `childAsk` resolves to Auto
- **THEN** completion SHALL require a childAsk decision and evidence record for that same interaction.

#### Scenario: ChildAsk traceability is discoverable
- **WHEN** maintainers verify childAsk ledger enforcement
- **THEN** enforcement SHOULD be discoverable in `CoordinatorChatMCPToolService.swift`, `CoordinatorFollowThroughState.swift`, `CoordinatorModeViewModel`, and `CoordinatorModeSnapshotProjector.swift`
- **AND** tests SHOULD include `CoordinatorChatMCPToolServiceTests.testSubmitRuntimePendingChildInteractionRecordsDirectorActor`, `testSubmitRuntimePendingChildInteractionRejectsWhenChildAskRoutesToMe`, `testMissionPlanRejectsChildAskAutoCompletionWithoutDirectorLedger`, `testMissionPlanAcceptsChildAskAutoCompletionWithDirectorLedger`, `CoordinatorFollowThroughStateTests.testDoesNotAutoCompleteChildAskAutoBoundNodeWithoutDirectorLedger`, `testAutoCompletesChildAskAutoBoundNodeAfterDirectorLedger`, `CoordinatorModeSnapshotProjectorTests.testChildAskAutoSuppressesUserFacingPendingInteraction`, and `CoordinatorModeComposerViewModelTests.testDirectorRoutedChildInteractionRecoversSuppressedRowAndRecordsLedger`.

### Requirement: Liveness warnings remain telemetry, not queue items
The system SHALL surface scheduler and ledger honesty warnings without treating them as user Decisions rows.

#### Scenario: Liveness warning is present
- **WHEN** eligible nodes are idle, bound rows are missing, workflow bindings mismatch, or childAsk:auto ledger entries are missing
- **THEN** compact Mission status MAY include liveness warnings for drivers and harnesses
- **AND** those warnings SHALL NOT be hidden from automation surfaces.

#### Scenario: Liveness warning is not a user ask
- **WHEN** a liveness warning exists without a pending checkpoint or child interaction
- **THEN** Coordinator mode SHALL NOT put that warning in the user Decisions/Needs-you queue as if it were waiting on human input.

#### Scenario: Liveness traceability is discoverable
- **WHEN** maintainers verify liveness warning semantics
- **THEN** enforcement SHOULD be discoverable in `CoordinatorChatMCPToolService.swift` and `CoordinatorModeSnapshotProjector.swift`
- **AND** tests SHOULD include `CoordinatorChatMCPToolServiceTests.testMissionStatusCompactReturnsPollingSummaryAndLivenessWarnings`, `testMissionStatusCompactEligibleNodesIdleWarningMatrix`, `testMissionStatusFlagsBoundWorkflowMismatch`, `CoordinatorModeSnapshotProjectorTests.testDecisionQueueExcludesTelemetryBlockedNodes`, and `testDecisionQueueExcludesPersistedOnlyStoppedMissionInteractions`.
