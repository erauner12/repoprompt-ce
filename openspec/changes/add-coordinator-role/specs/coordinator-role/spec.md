## ADDED Requirements

### Requirement: Coordinator role identity
The system SHALL define a Coordinator role as a layer-above meta-agent identity separate from workspace Agent Mode session rows.

#### Scenario: Coordinator runtime is not a workspace row
- **WHEN** a Coordinator runtime exists for a workspace or window
- **THEN** the system SHALL NOT project that Coordinator runtime as a normal workspace session card or row in the Coordinator mode board/list
- **AND** the Coordinator runtime SHALL NOT be counted as part of the supervised workspace fleet.

#### Scenario: Coordinator view remains the control plane
- **WHEN** the Coordinator view renders workspace sessions
- **THEN** it SHALL continue to render supervised workspace Agent Mode sessions from sourced projection state
- **AND** it SHALL treat the Coordinator role as the supervising actor rather than one of the projected supervised sessions.

#### Scenario: Demo selected session remains distinct
- **WHEN** the current manual selected-session composer is used before the real Coordinator role is available
- **THEN** the system SHALL treat that selected session as Layer 1 demo behavior
- **AND** it SHALL NOT treat that selected workspace session as the real Coordinator role identity.

### Requirement: Coordinator runtime scope
The system SHALL resolve the Coordinator role runtime as either an MCP-bound top-level/global role entry or a true in-app non-tab-scoped Agent Mode role before implementation.

#### Scenario: Runtime home is selected
- **WHEN** implementation begins for the Coordinator role
- **THEN** the accepted design SHALL identify whether the role is MCP-bound or in-app non-tab-scoped
- **AND** it SHALL document how the role is launched, identified, scoped, and surfaced to users and tools.

#### Scenario: MCP-bound runtime is selected
- **WHEN** the accepted design chooses an MCP-bound Coordinator runtime
- **THEN** the system SHALL provide top-level or global session visibility through an explicit Coordinator binding
- **AND** it SHALL NOT require the Coordinator runtime to focus a tab to obtain its first-version supervision scope.

#### Scenario: In-app runtime is selected
- **WHEN** the accepted design chooses an in-app Coordinator runtime
- **THEN** the design SHALL define a non-tab-scoped permission and state model for the Coordinator
- **AND** it SHALL NOT reuse ordinary tab-scoped Agent Mode permissions as the Coordinator's global supervision model.

### Requirement: Delegate-only first tool contract
The first Coordinator role implementation SHALL use a delegate-only tool contract.

#### Scenario: Coordinator observes session state
- **WHEN** the Coordinator needs to understand workspace work in progress
- **THEN** it SHALL use explicit session/model listing and compact metadata APIs
- **AND** it SHALL NOT load full transcripts, files, diffs, or logs as part of the first-version board supervision loop.

#### Scenario: Coordinator directs agents
- **WHEN** the Coordinator needs work performed by an agent
- **THEN** it SHALL spawn, message, steer, or request summaries from Agent Mode sessions through explicit control APIs
- **AND** it SHALL leave tab focus, file reads/searches, file selection, and worktree context to the target agent session.

#### Scenario: Direct tab and workspace mutation is requested
- **WHEN** a Coordinator behavior would require direct tab focus, file-selection mutation, file read/search scoped to a focused tab, worktree mutation, approval/decline, cancel, or stop behavior
- **THEN** the first Coordinator role SHALL reject or defer that behavior unless a later accepted spec grants the capability with authorization and audit semantics.

### Requirement: Coordinator context and history ownership
The system SHALL keep Coordinator context, conversation history, and directive logs outside the supervised workspace row projection.

#### Scenario: Coordinator stores history
- **WHEN** the Coordinator records conversation or directive history
- **THEN** the system SHALL store that history in a control-plane location chosen by the accepted runtime design
- **AND** it SHALL NOT require creating a supervised workspace row solely to persist Coordinator history.

#### Scenario: Coordinator state is restored
- **WHEN** Coordinator state is restored after app or runtime restart
- **THEN** restored Coordinator state SHALL remain separate from workspace session rows
- **AND** restoring it SHALL NOT create, restore, or promote a workspace Agent Mode session into the supervised fleet.

### Requirement: Structured Coordinator directives
The system SHALL represent Coordinator role actions as structured, auditable directives before adding autonomous behavior.

#### Scenario: Directive is issued
- **WHEN** a user or Coordinator runtime issues a directive
- **THEN** the system SHALL record the directive source, target, action type, status, and failure information
- **AND** it SHALL avoid relying on assistant prose parsing as the source of directive state.

#### Scenario: First directive set is used
- **WHEN** the first Coordinator role implementation dispatches work
- **THEN** it SHALL limit directive actions to the accepted initial set, expected to include list, spawn, message or steer, and summarize
- **AND** higher-risk actions SHALL remain unavailable until explicitly specified.

#### Scenario: Directive fails
- **WHEN** a Coordinator directive cannot be delivered or completed
- **THEN** the system SHALL surface a structured failure state to the Coordinator runtime or view
- **AND** it SHALL NOT silently infer success from absence of an error message in agent prose.

### Requirement: Stakeholder design checkpoint
The system SHALL require a focused design checkpoint before implementing the Coordinator role.

#### Scenario: Runtime wording is clarified
- **WHEN** the OpenSpec change is ready for implementation planning
- **THEN** the team SHALL clarify whether “new agent role in code” means an MCP-bound role entry or a true in-app non-tab-scoped Agent Mode role
- **AND** that clarification SHALL be recorded in the design before implementation begins.

#### Scenario: Wren review occurs
- **WHEN** the runtime-home clarification has been recorded
- **THEN** the Coordinator role design SHALL be reviewed with wren around the delegate-vs-focus and MCP-bound-vs-in-app forks
- **AND** pvncher SHALL be able to review the resulting artifact without requiring the design discussion to happen in the group DM.
