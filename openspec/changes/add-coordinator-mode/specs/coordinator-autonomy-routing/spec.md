## ADDED Requirements

### Requirement: Mission Policy dials are user-action parity state
The system SHALL expose current user-visible autonomy controls as Mission-owned overrides rather than ad hoc runtime instructions.

#### Scenario: Pace and childAsk are the visible dials
- **WHEN** a Mission has current user-visible autonomy controls
- **THEN** the visible dials SHALL be pace (`step|auto`) and `childAsk` (`ask|auto`)
- **AND** general per-class editing and custom policy CRUD SHALL remain deferred unless specified by another change.

#### Scenario: Draft dials are captured into the Mission policy snapshot
- **WHEN** a fresh Mission is submitted with selected pace or `childAsk` values
- **THEN** provider-only policy guidance and the Mission policy snapshot SHALL reflect those effective values
- **AND** raw policy preset fields SHALL NOT silently override the user's selected dials.

#### Scenario: Mid-mission dial change mutates the Mission snapshot
- **WHEN** an external user changes pace or `childAsk` on a Mission with a recorded plan
- **THEN** the system SHALL mutate the Mission-owned policy/autonomy snapshot, bump visible Mission state, and record a user-actor decision
- **AND** it SHALL NOT mutate the policy library, resend the original directive, or consume unrelated pending checkpoints.

#### Scenario: Generic runtime updates cannot change user-owned routing
- **WHEN** a Coordinator runtime or generic `mission_plan` update attempts to change user-owned pace or `childAsk` routing
- **THEN** the system SHALL reject the change or preserve the previous user-owned value
- **AND** it SHALL require the app/external `set_pace`, `set_autonomy`, or equivalent UI dial path so the user decision is recorded.

#### Scenario: Edited policy label is honest
- **WHEN** Mission-owned pace or `childAsk` values differ from the library policy with the same snapshot ID
- **THEN** visible policy copy SHOULD mark the Mission policy as edited
- **AND** the marker SHOULD be computed from current values rather than stored as a separate source of truth.

### Requirement: childAsk route changes affect pending interactions deterministically
The system SHALL treat `childAsk` as a standing route for child questions, including interactions already pending.

#### Scenario: User reroutes childAsk
- **WHEN** an external user changes `childAsk` with `set_autonomy` or the equivalent app dial
- **THEN** the system SHALL record a user-actor route decision
- **AND** pending child questions SHALL respect the newly resolved route at submit time.

#### Scenario: Ask to Auto reroutes immediately after user consent
- **WHEN** a child question is already pending under Ask and the user flips `childAsk` to Auto
- **THEN** the route-change decision SHALL be recorded before any Director answer
- **AND** the Director MAY answer the same interaction as Director with required decision/evidence ledger records
- **AND** user-facing pending presentation MAY be suppressed while the Director route is active.

#### Scenario: Auto to Ask escalates to the user
- **WHEN** a child question is pending or racing under Auto and the user flips `childAsk` to Ask before a Director answer is committed
- **THEN** the pending question SHALL become visible for user response
- **AND** a stale Director/runtime answer SHALL be rejected by re-resolving current autonomy at submit time.

#### Scenario: One answer wins the race
- **WHEN** user and Director answer attempts race for the same child interaction
- **THEN** exactly one answer SHALL land
- **AND** losing race attempts SHALL reject loudly rather than silently adding conflicting ledger records.

### Requirement: Follow-through events wake only safe Coordinator continuations
The system SHALL use app-owned follow-through events as narrow wakeups for existing Coordinator parents.

#### Scenario: Follow-through event is observed
- **WHEN** the app observes child terminal state, child question, cleared gate, or eligible work
- **THEN** it MAY enqueue a follow-through event with a stable ID, owning Coordinator session ID, optional child/session/gate/phase context, and detail text.

#### Scenario: Duplicate event is observed
- **WHEN** the same follow-through event is observed again
- **THEN** the system SHALL NOT enqueue or submit it again after it is pending or handled.

#### Scenario: Resume directive is submitted
- **WHEN** Auto mode and safety classification allow follow-through
- **THEN** the app MAY submit an internal resume directive to the existing owning Coordinator runtime
- **AND** it SHALL NOT create a new Coordinator parent
- **AND** it SHALL frame the event as observed context for the original objective.

#### Scenario: Follow-through must hold
- **WHEN** the Coordinator runtime is active, an owned child is Needs-you or Blocked, a human permission/irreversible boundary exists, or the next safe step is ambiguous
- **THEN** follow-through SHALL remain pending or deferred rather than auto-submitting a continuation.

#### Scenario: Eligible work event resumes
- **WHEN** approved ready nodes exist, dependencies are satisfied, and no active Coordinator turn is handling them
- **THEN** the resume directive SHALL instruct the Coordinator to inspect compact `mission_status`, respect `maxConcurrent`, avoid already running/bound nodes, and record routing decisions or a hold reason.

#### Scenario: childAsk auto can resume a suppressed child question
- **WHEN** a selected-Mission child question is presentation-suppressed because `childAsk` resolves to Auto
- **THEN** follow-through MAY wake the Coordinator to answer it as Director
- **AND** it SHALL still require the ledger records enforced by the trust-invariants capability.

### Requirement: Auto mode boundaries remain explicit and safe
The system SHALL stop automation at human, permission, irreversible, ambiguous, or blocked boundaries.

#### Scenario: Coordinator auto reaches a boundary
- **WHEN** Auto mode is enabled and delegated work requires user input, permission, human continuation, or is blocked or ambiguous
- **THEN** the Coordinator runtime SHALL stop at that boundary and surface the required user decision/status
- **AND** it SHALL NOT bypass or auto-acknowledge the user's continuation, approval, permission, or Needs-you gate.

#### Scenario: Coordinator-owned checks stay recoverable
- **WHEN** the Coordinator runtime performs follow-through, final inspection, or child recovery steps
- **THEN** it SHOULD prefer app-owned structured MCP tools such as Agent session wait/poll/log and Git status/diff over raw shell loops for routine status, diff, and validation checks
- **AND** it SHOULD use bounded waits plus poll, log, steer, or cancel to recover a delegated child or workflow that appears stuck.

#### Scenario: Workflow-bearing sessions chain through explicit metadata
- **WHEN** Coordinator Auto mode starts separate workflow-bearing delegated Agent sessions
- **THEN** it SHALL use existing `agent_run.start` metadata such as `workflow_name` or `workflow_id`
- **AND** later workflow stages MAY bind to an explicit child worktree created or returned by an earlier stage.

### Requirement: Autonomy routing traceability remains discoverable
The system SHALL keep enforcement and regression coverage for autonomy routing discoverable.

#### Scenario: Pace and dial traceability is requested
- **WHEN** maintainers verify pace and childAsk dial behavior
- **THEN** enforcement SHOULD be discoverable in `CoordinatorModeViewModel`, `CoordinatorModeView`, `CoordinatorChatMCPToolService.swift`, and `CoordinatorFollowThroughState.swift`
- **AND** tests SHOULD include `CoordinatorModeComposerViewModelTests.testFreshMissionDialsAreCapturedInProviderTextAndPolicySnapshot`, `testMissionDialsMutatePlanSnapshotAndRecordLedgerWithoutClearingApprovalCheckpoint`, `CoordinatorChatMCPToolServiceTests.testSetPaceRoutesThroughExternalUserActionPath`, and `testSetAutonomyRoutesThroughExternalUserActionPath`.

#### Scenario: Follow-through traceability is requested
- **WHEN** maintainers verify follow-through routing
- **THEN** enforcement SHOULD be discoverable in `CoordinatorAutoModeBoundaryClassifier.swift`, `CoordinatorFollowThroughState.swift`, and `CoordinatorModeViewModel`
- **AND** tests SHOULD include `CoordinatorAutoModeBoundaryClassifierTests.testCompletedChildResumes`, `testNeedsUserAndBlockedHold`, `testChildAskAutoResumesPendingChildQuestion`, `testChildAskAutoResumesSuppressedUserFacingQuestionRow`, `testEligibleReadyMissionWorkResumesWhenIdle`, `testEligibleReadyMissionWorkDedupesAndRespectsCapacity`, `testDuplicateEventHolds`, `CoordinatorFollowThroughStateTests.testResumeDirectiveContainsMissionEligibilityCapAndIdempotencyClauses`, and `CoordinatorModeComposerViewModelTests.testStepPaceExposesPendingFollowThroughEventAndAutoHidesIt`.
