## ADDED Requirements

### Requirement: Lifecycle operations preserve audit state
The system SHALL support stopping and archiving Missions without deleting Mission evidence.

#### Scenario: Mission is stopped
- **WHEN** `stop_mission` is accepted
- **THEN** the Mission Plan SHALL move to `stopped`
- **AND** active or blocked nodes and cancelled bound sessions SHALL be marked cancelled
- **AND** routing decisions SHALL include `agent_run.cancel` entries for cancelled sessions
- **AND** pending follow-through events SHALL be cleared
- **AND** a user stop decision SHALL be recorded.

#### Scenario: Non-terminal Mission is archived
- **WHEN** `archive_mission` targets a Mission whose plan status is not terminal
- **THEN** the system SHALL reject the archive request and instruct the caller to stop the Mission first.

#### Scenario: Runtime caller archives
- **WHEN** a Coordinator runtime caller invokes `archive_mission`
- **THEN** the system SHALL reject it because archive is an external lifecycle action.

#### Scenario: Terminal Mission is archived
- **WHEN** an external caller archives a completed or stopped Mission
- **THEN** the operation SHALL hide it from ordinary live rail surfaces
- **AND** it SHALL preserve receipt, status, events, decisions, evidence, lineage, and mission inventory access
- **AND** already archived Missions MAY return idempotent success.

#### Scenario: Mission inventory is visible to external callers
- **WHEN** an external caller invokes `list_missions`
- **THEN** the response SHALL provide compact lifecycle inventory including live and archived Missions as appropriate for the external lifecycle view.

#### Scenario: Runtime inventory is scoped
- **WHEN** a Coordinator runtime caller invokes `list_missions`
- **THEN** the response SHALL be scoped to the caller's own Mission
- **AND** it SHALL NOT expose arbitrary external fleet inventory.

### Requirement: Receipt projection is terminal and Mission-owned
The system SHALL produce receipts from Mission-owned state only after terminal completion or stop.

#### Scenario: Receipt requested before terminal state
- **WHEN** `coordinator_chat op="receipt"` targets a non-terminal Mission
- **THEN** the response SHALL report `receipt_ready:false`
- **AND** it SHALL NOT return terminal Markdown.

#### Scenario: Receipt requested for completed Mission
- **WHEN** `receipt format="markdown"` targets a completed Mission
- **THEN** the response SHALL report `receipt_ready:true`
- **AND** it SHALL include Markdown with title, objective/summary, policy, decision counts, evidence, and Spend section.

#### Scenario: Receipt requested for stopped Mission
- **WHEN** `receipt format="markdown"` targets a stopped Mission
- **THEN** the response SHALL report `receipt_ready:true`
- **AND** it SHALL include stop/user-decision and evidence summaries without styling the stopped Mission as failure.

#### Scenario: Rendered receipt exists
- **WHEN** receipt Markdown is generated
- **THEN** it SHALL be a deterministic projection from Mission Plan state
- **AND** it SHALL NOT become a separate persisted source of truth.

#### Scenario: Spend is reserved, not enforced
- **WHEN** receipt Markdown includes a Spend section
- **THEN** that section SHALL be a reserved projection slot for the current baseline
- **AND** spend capture, budgeting, and enforcement SHALL remain deferred.

### Requirement: Doctor and E2E tooling define the current demo baseline
The system SHALL keep side-effect-free capability discovery and validation boundaries for the core runtime baseline.

#### Scenario: Doctor reports capability facts
- **WHEN** `coordinator_chat op="doctor"` runs
- **THEN** it SHALL report supported operations/features, runtime gates, structured child input support, scripted child availability, and related capability facts without mutating Mission state.

#### Scenario: Focused Swift coverage is run
- **WHEN** the runtime baseline is validated
- **THEN** tests SHALL cover Mission Plan persistence/merge behavior, terminal honesty, policy/autonomy, childAsk routing, `coordinator_chat` serialization/gates, delegated-run policy, prompt contract, receipt projection, and scripted child behavior.

#### Scenario: Live E2E plateau is run
- **WHEN** live Coordinator E2E validation is required
- **THEN** the plateau SHALL include read-only, fan-out/convergence, checkpoint revision identity, childAsk Me/Director parity, pace and childAsk dial semantics, stop honesty, doctor capability preflight, mission events, receipts, and archive cleanup.

#### Scenario: Run bundles preserve evidence discipline
- **WHEN** pass-rate or live demo batches are recorded
- **THEN** every counted attempt SHALL remain in the denominator
- **AND** run bundles SHOULD record Coordinator model/tier, child backend, doctor/features, events/status history, receipt, archive cleanup result, timings, and invariant failures.

### Requirement: Deferred scope remains explicit
The system SHALL keep known deferrals outside the current core runtime contract unless a later OpenSpec change promotes them.

#### Scenario: Restart durability is deferred
- **WHEN** S8 restart durability for pending checkpoints and pending child questions is needed
- **THEN** it SHALL remain deferred to a later change or scenario rather than being silently included in this baseline.

#### Scenario: UI render-to-click race is deferred
- **WHEN** render-to-click timing/race hardening for Coordinator UI affordances is needed
- **THEN** it SHALL remain a deferred UI robustness item outside this spec split.

#### Scenario: Toggle dedup is deferred
- **WHEN** repeated pace/childAsk toggle deduplication beyond current idempotent ledger behavior is needed
- **THEN** it SHALL remain deferred unless a focused regression promotes it.

#### Scenario: Worktree GC is deferred
- **WHEN** cleanup or garbage collection of Coordinator-created child worktrees is needed
- **THEN** it SHALL remain deferred to lifecycle/worktree management work outside this current baseline.

#### Scenario: Backend fallback is deferred
- **WHEN** automatic fallback between live child backends/providers is needed
- **THEN** it SHALL remain deferred and SHALL NOT be implied by the DEBUG scripted child backend.

### Requirement: Lifecycle traceability remains discoverable
The system SHALL keep enforcement and regression coverage for lifecycle tooling discoverable.

#### Scenario: Lifecycle traceability is requested
- **WHEN** maintainers verify stop, archive, inventory, receipt, and doctor behavior
- **THEN** enforcement SHOULD be discoverable in `CoordinatorChatMCPToolService.swift`, `CoordinatorFollowThroughState.swift`, `CoordinatorMissionReceiptProjection`, and `CoordinatorMissionEventJournal.swift`
- **AND** tests SHOULD include `CoordinatorChatMCPToolServiceTests.testDoctorReportsCoordinatorCapabilities`, `testListMissionsReturnsLifecycleInventory`, `testListMissionsRuntimeCallerIsScopedToCallerMission`, `testArchiveMissionRequiresTerminalMission`, `testArchiveMissionRejectsCoordinatorRuntimeCaller`, `testArchiveMissionReturnsLifecycleResultAndInventory`, `testStopMissionSelectsRequestedCoordinatorAndStopsIt`, `testReceiptReturnsCompletedMissionMarkdown`, `testReceiptReturnsStoppedMissionMarkdown`, `testReceiptReportsNotReadyBeforeMissionCompletes`, and `CoordinatorMissionReceiptProjectionTests.testMarkdownOutputIsDeterministic`.
