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

#### Scenario: Coordinator task label is added
- **WHEN** the implementation adds or reserves a `coordinator` role label alongside `pair`, `explore`, `engineer`, and `design`
- **THEN** that label alone SHALL NOT create an ordinary tab-backed Agent Mode session that is treated as the real Coordinator runtime
- **AND** the real Coordinator runtime SHALL remain distinguishable by launch, scope, policy, and projection metadata.

### Requirement: Native Agent run/session lifecycle contract
The system SHALL define a native RepoPrompt Agent run/session lifecycle contract as the durable control-plane boundary underneath MCP tool schemas.

#### Scenario: Lifecycle state is queried
- **WHEN** a Coordinator runtime or external caller observes an Agent run/session
- **THEN** the system SHALL expose a stable run or session handle, deterministic status, and active/actionable/terminal classification
- **AND** it SHALL NOT require the caller to infer completion, failure, or blockers from assistant prose.

#### Scenario: Lifecycle status is represented
- **WHEN** lifecycle status is reported through the native contract
- **THEN** the status model SHALL distinguish active work, actionable input-required work, and terminal work
- **AND** terminal work SHALL include a structured outcome such as completed, failed, or cancelled
- **AND** additional outcomes such as expired MAY be added when supported by the runtime.

#### Scenario: Pending interaction is exposed
- **WHEN** an Agent run/session requires user input, a question response, or an approval-like decision
- **THEN** the lifecycle contract SHALL expose a structured pending interaction shape with a stable interaction identifier
- **AND** responses SHALL target that interaction identifier instead of relying on assistant prose.

#### Scenario: Artifacts are exposed
- **WHEN** summaries, logs, exported context, worktree metadata, or related outputs are available for a run/session
- **THEN** the lifecycle contract SHALL expose durable artifact references
- **AND** callers SHALL be able to consume those references without loading full transcripts as part of the first-version supervision loop.

### Requirement: MCP adapter over lifecycle contract
The system SHALL treat MCP `agent_run` and `agent_manage` as adapters over the native Agent run/session lifecycle contract, not as the only durable source-of-truth boundary.

#### Scenario: Existing MCP lifecycle tools are used
- **WHEN** an external caller uses `agent_run start`, `poll`, `wait`, `steer`, `respond`, or `cancel`
- **THEN** those operations SHALL map to native lifecycle start, observe, wait, steer, respond, and cancel semantics.

#### Scenario: Existing MCP management tools are used
- **WHEN** an external caller uses `agent_manage list_sessions`, `get_log`, or export-like behavior
- **THEN** those operations SHALL expose native lifecycle listing and durable artifact references where possible
- **AND** implementation SHALL avoid creating a parallel control contract that only exists in MCP result prose.

#### Scenario: Public contract is tested
- **WHEN** lifecycle adapter behavior is implemented or changed
- **THEN** public contract tests SHALL cover caller-visible start, poll/status, wait, steer with wait semantics, respond, cancel, lifecycle category/outcome, and artifact/export shapes.

### Requirement: Coordinator runtime scope
The Coordinator role SHALL use an explicit layer-above listing and control scope rather than ordinary child-only Agent Mode scoping.

#### Scenario: First listing scope is selected
- **WHEN** implementation begins for the Coordinator role
- **THEN** the accepted design SHALL identify the first listing/control scope as active-workspace top-level, explicitly attached sessions, or app-global
- **AND** app-global visibility SHALL remain unavailable unless cross-window ownership and visibility semantics are accepted.

#### Scenario: Active-workspace top-level scope is selected
- **WHEN** the accepted design chooses active-workspace top-level Coordinator visibility
- **THEN** the Coordinator SHALL be able to list top-level visible Agent run/session state for the active workspace
- **AND** ordinary child-only scoping for agent sub-agents SHALL NOT hide sibling or top-level sessions from the Coordinator.

#### Scenario: Existing MCP scope is insufficient
- **WHEN** current MCP agent-control tools are window, workspace, tab, or child scoped in a way that cannot satisfy the accepted Coordinator scope
- **THEN** the implementation SHALL add an explicit Coordinator binding, adapter scope, or native lifecycle surface before exposing Coordinator supervision
- **AND** it SHALL NOT rely on tab focus as the source of Coordinator scope.

#### Scenario: Cross-window control is requested
- **WHEN** a Coordinator behavior would observe or act beyond the current window
- **THEN** the design SHALL record whether the implementation is current-window-only, routes to owning windows, or uses a shared session-control service
- **AND** it SHALL not silently create app-global cross-window control.

### Requirement: Delegate-only first tool contract
The first Coordinator role implementation SHALL use a delegate-only tool contract.

#### Scenario: Coordinator observes session state
- **WHEN** the Coordinator needs to understand workspace work in progress
- **THEN** it SHALL use explicit session/model listing, lifecycle status, compact metadata, and artifact reference APIs
- **AND** it SHALL NOT load full transcripts, files, diffs, or logs as part of the first-version board supervision loop.

#### Scenario: Coordinator directs agents
- **WHEN** the Coordinator needs work performed by an agent
- **THEN** it SHALL start, message, steer, poll, wait for, or request summaries from Agent runs/sessions through explicit lifecycle/control APIs
- **AND** it SHALL leave tab focus, file reads/searches, file selection, and worktree context to the target agent session.

#### Scenario: Respond capability is considered
- **WHEN** the Coordinator needs to answer a pending interaction
- **THEN** Coordinator access to `respond` SHALL remain unavailable until the accepted lifecycle contract defines stable pending interaction identifiers, response shape, authorization, and failure semantics
- **AND** any accepted Coordinator respond behavior SHALL be audited as a structured action record.

#### Scenario: Direct tab and workspace mutation is requested
- **WHEN** a Coordinator behavior would require direct tab focus, file-selection mutation, file read/search scoped to a focused tab, worktree mutation, approval/decline, cancel, stop, or full log read behavior
- **THEN** the first Coordinator role SHALL reject or defer that behavior unless a later accepted spec grants the capability with authorization and audit semantics.

#### Scenario: Tools are advertised to Coordinator
- **WHEN** tools are advertised or installed for the Coordinator runtime
- **THEN** the system SHALL advertise only the accepted lifecycle/control-plane toolset
- **AND** it SHALL NOT advertise ordinary tab-scoped file, selection, worktree, focus, approval, cancel, or stop tools unless a later accepted spec grants Coordinator access.

#### Scenario: Workspace investigation or mutation is requested
- **WHEN** user intent requires direct codebase investigation, file reads/searches, file edits, selection changes, tab focus, or worktree mutation
- **THEN** the first Coordinator role SHALL spawn or steer an appropriately scoped Agent Mode session to perform that work
- **AND** the Coordinator SHALL observe the delegated session through lifecycle state, structured action status, and artifact references instead of using those workspace tools directly.

### Requirement: Coordinator context and history ownership
The system SHALL keep Coordinator context, conversation history, and action/instruction logs outside the supervised workspace row projection.

#### Scenario: Coordinator stores history
- **WHEN** the Coordinator records conversation, instruction, or action history
- **THEN** the system SHALL store that history in a control-plane location chosen by the accepted lifecycle/runtime design
- **AND** it SHALL NOT require creating a supervised workspace row solely to persist Coordinator history.

#### Scenario: Coordinator state is restored
- **WHEN** Coordinator state is restored after app or runtime restart
- **THEN** restored Coordinator state SHALL remain separate from workspace session rows
- **AND** restoring it SHALL NOT create, restore, or promote a workspace Agent Mode session into the supervised fleet.

### Requirement: Structured Coordinator action records
The system SHALL represent first-version Coordinator role actions as structured, auditable action records before adding autonomous directive behavior.

#### Scenario: User instruction is handled
- **WHEN** a user sends a Coordinator instruction or message
- **THEN** the system SHALL record the instruction source, target, action type, lifecycle handle, status, and failure information when it causes control-plane work
- **AND** it SHALL avoid relying on assistant prose parsing as the source of action state.

#### Scenario: First action set is used
- **WHEN** the first Coordinator role implementation dispatches work
- **THEN** it SHALL limit action types to the accepted initial set, expected to include list, start or spawn, poll or wait, message or steer, and summarize or export
- **AND** higher-risk actions SHALL remain unavailable until explicitly specified.

#### Scenario: Session state changes without a user instruction
- **WHEN** a supervised Agent run/session changes state after the user's last instruction
- **THEN** the first Coordinator role MAY update status, summaries, and action records from sourced lifecycle state
- **AND** it SHALL NOT issue new higher-level directives from observed session lifecycle changes unless a later accepted autonomy spec grants that behavior.

#### Scenario: Action fails
- **WHEN** a Coordinator action cannot be delivered or completed
- **THEN** the system SHALL surface a structured failure state to the Coordinator runtime or view
- **AND** it SHALL NOT silently infer success from absence of an error message in agent prose.

#### Scenario: Higher-level directive behavior is considered
- **WHEN** future work defines goal-like Coordinator directives that may span multiple sessions or continue from observed lifecycle changes
- **THEN** that behavior SHALL require a later accepted spec defining triggers, authorization, audit records, and failure handling.

### Requirement: Coordinator projection reconciliation
The system SHALL reconcile the real Coordinator runtime with existing Coordinator mode demo selection and projection behavior.

#### Scenario: Real Coordinator runtime is integrated with Coordinator mode
- **WHEN** the real Coordinator runtime becomes available to the Coordinator view
- **THEN** the system SHALL define an explicit identity or exclusion predicate for that runtime
- **AND** the runtime SHALL NOT appear in `CoordinatorModeSnapshot.groups` as a supervised row.

#### Scenario: Demo Coordinator detection remains available
- **WHEN** the manual selected-session composer or auto-detected demo Coordinator session remains available during migration
- **THEN** the system SHALL label or treat it as demo/manual fallback behavior
- **AND** it SHALL remain distinct from the real Coordinator role/runtime.

### Requirement: Stakeholder design checkpoint
The system SHALL require a focused design checkpoint before implementing the Coordinator role.

#### Scenario: Chosen direction is recorded
- **WHEN** the OpenSpec change is ready for implementation planning
- **THEN** the team SHALL record that the Coordinator role is backed by a native Agent run/session lifecycle contract, with MCP as adapter and delegate-only first scope
- **AND** any remaining listing-scope or cross-window decision SHALL be recorded before implementation begins.

#### Scenario: Wren review occurs
- **WHEN** the lifecycle-contract direction and first listing scope have been recorded
- **THEN** the Coordinator role design SHALL be reviewed with wren around the delegate-vs-focus, lifecycle-contract-vs-MCP-schema, and active-workspace-top-level-vs-global forks
- **AND** pvncher SHALL be able to review the resulting artifact without requiring the design discussion to happen in the group DM.
