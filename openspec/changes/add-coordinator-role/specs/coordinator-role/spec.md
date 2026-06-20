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

#### Scenario: Coordinator rail addresses the Coordinator directly
- **WHEN** the user is interacting with a real or production-demo Coordinator runtime from Coordinator mode
- **THEN** the Coordinator rail SHALL be the user-facing conversation endpoint for that runtime
- **AND** the UI SHALL NOT frame the Coordinator backing runtime as an ordinary Agent Mode chat to open from the rail.

#### Scenario: Demo selected session remains distinct
- **WHEN** the current manual selected-session composer is used before the real Coordinator role is available
- **THEN** the system SHALL treat that selected session as Layer 1 demo behavior
- **AND** it SHALL NOT treat that selected workspace session as the real Coordinator role identity.

#### Scenario: Coordinator role is exposed
- **WHEN** the implementation exposes the Coordinator as a selectable or launchable role
- **THEN** it SHALL NOT rely solely on adding `coordinator` to ordinary `pair`, `explore`, `engineer`, and `design` task-label resolution
- **AND** the real Coordinator runtime SHALL remain distinguishable by launch path, identity marker, scope, policy, and projection metadata.

#### Scenario: Ordinary role-label path would create the wrong runtime
- **WHEN** a role catalog, model-selection, or MCP `model_id` path would spawn an ordinary tab-backed Agent Mode session
- **THEN** that path SHALL NOT by itself be treated as the real Coordinator runtime
- **AND** the implementation SHALL use a dedicated launch path or additional runtime marker before granting Coordinator scope and policy.

#### Scenario: Marked tab-session runtime is justified for v1
- **WHEN** Coordinator v1 is implemented using the existing Agent Mode run path
- **THEN** the design SHALL record that the non-enrolled provider-runtime alternative was considered and rejected for v1
- **AND** the recorded rationale SHALL cite evidence that provider start, transcript persistence, file/worktree context assembly, terminal-commit publication, and loopback `agent_run` routing currently key off compose-tab-to-Agent-session binding.

#### Scenario: Runtime extraction is requested during v1
- **WHEN** implementation starts requiring `AgentModeRunService.startRun`-level extraction or a new non-enrolled runtime registry to make Coordinator v1 work
- **THEN** that extraction SHALL be treated as out of scope for this v1 change
- **AND** the work SHALL be re-scoped rather than silently expanding the Coordinator implementation.

### Requirement: Existing Agent run/session lifecycle surfaces
The first Coordinator role SHALL use the existing `agent_run` and `agent_manage` lifecycle/control surfaces for v1 delegation rather than requiring a new native lifecycle subsystem.

#### Scenario: Privilege context prerequisite is available
- **WHEN** Coordinator privilege state is threaded through the run-lease and connection-policy path
- **THEN** the prerequisite `refactor-agent-mcp-policy-context` behavior SHALL be available so Coordinator privilege state is carried through a named policy context or equivalent typed structure
- **AND** ordinary agents SHALL NOT receive Coordinator scope or tools because of positional argument miswiring.

#### Scenario: Lifecycle state is queried
- **WHEN** a Coordinator runtime observes an Agent run/session
- **THEN** it SHALL use stable run/session handles, deterministic status, and active/actionable/terminal classification exposed by existing lifecycle snapshots
- **AND** it SHALL NOT infer completion, failure, or blockers from assistant prose.

#### Scenario: Lifecycle status is represented
- **WHEN** lifecycle status is reported to the Coordinator
- **THEN** active/actionable/terminal categories SHALL map to existing Agent Mode and MCP-facing state vocabulary, including running, waiting-for-input/actionable, completed, failed, cancelled, and expired where present
- **AND** expired handles SHALL be treated as terminal/untrackable lifecycle outcomes rather than silently ignored.

#### Scenario: Pending interaction is visible
- **WHEN** an Agent run/session requires user input, a question response, or an approval-like decision
- **THEN** the Coordinator SHALL be able to surface structured pending-interaction metadata from existing lifecycle snapshot state
- **AND** Coordinator access to `respond` SHALL remain gated until authorization and stale-interaction failure semantics are accepted.

#### Scenario: Status and failure diagnostics are exposed
- **WHEN** terminal output, status text, failure reason, or compact failure diagnostics are available for a run/session
- **THEN** the Coordinator SHALL be able to use those existing snapshot fields to explain status and failure
- **AND** full logs, full transcripts, exported context, worktree metadata, compact-summary artifacts, and other broad artifact types SHALL remain gated or optional unless later Coordinator permissions grant them.

#### Scenario: Native facade extraction is considered
- **WHEN** implementation discovers duplicated MCP-specific lifecycle parsing or `Value`-level coupling
- **THEN** extracting a typed native facade MAY be proposed as follow-up cleanup
- **AND** that facade extraction SHALL NOT be required for the first Coordinator role unless the existing lifecycle/control surfaces cannot support the accepted v1 behavior.

### Requirement: Coordinator runtime lifecycle and ownership
The system SHALL define how the real Coordinator runtime is created, owned, persisted, restored, and addressed before integrating it with Coordinator mode.

#### Scenario: Runtime ownership is selected
- **WHEN** the Coordinator runtime is first made available
- **THEN** the implementation SHALL define whether there is one Coordinator per window, per workspace, or another explicit ownership unit
- **AND** the leading first implementation SHOULD use per-window ownership with lazy creation on first real Coordinator instruction unless a concrete reason for another policy is accepted
- **AND** that ownership unit SHALL determine restore, history, and active-workspace visibility semantics.

#### Scenario: Runtime is created
- **WHEN** a user first interacts with the real Coordinator or opens a workspace/window with an available Coordinator
- **THEN** the implementation SHALL define whether the runtime is created lazily on first instruction or eagerly when the surface appears
- **AND** the created runtime SHALL receive the Coordinator identity marker and Coordinator-specific prompt/tool policy before it can supervise other sessions.

#### Scenario: Background creation path is reused
- **WHEN** Coordinator creation reuses an MCP background compose-tab or background-Agent creation path
- **THEN** the implementation SHALL attach the Coordinator marker during creation
- **AND** it SHALL define whether the Coordinator inherits or overrides background-Agent capacity, eviction, and cleanup behavior.

#### Scenario: Coordinator runtime is protected from disposable-worker lifecycle
- **WHEN** background-Agent lifecycle management would evict, reclaim, or clean up MCP-originated background sessions automatically or incidentally
- **THEN** the Coordinator marker SHALL prevent the Coordinator runtime from being treated as a disposable worker unless explicit Coordinator lifecycle semantics allow it
- **AND** re-creation on next instruction SHALL be acceptable only when persisted Coordinator history and action state are restored
- **AND** silent loss of Coordinator context SHALL NOT be the default behavior.

#### Scenario: Coordinator runtime is targeted by destructive session management
- **WHEN** any caller invokes session cleanup, stop, or other destructive session-management behavior against MCP-originated or background Agent sessions
- **THEN** Coordinator-marked runtimes SHALL be excluded from incidental destructive targeting unless a later accepted spec defines explicit authorization and recovery semantics
- **AND** the Coordinator runtime SHALL NOT be removed merely because it was created through an MCP-originated background path
- **AND** this Coordinator-as-target protection SHALL be implemented separately from Coordinator-as-actor op/arg guards that block the Coordinator runtime from invoking cleanup or stop operations itself.

#### Scenario: User intentionally resets the Coordinator
- **WHEN** the Coordinator runtime is wedged or the user intentionally wants to tear it down
- **THEN** the implementation SHALL provide or specify at least one intentional reset, teardown, or recreate path
- **AND** that path SHALL define whether Coordinator history is restored or intentionally discarded.

#### Scenario: Runtime is restored
- **WHEN** the app or runtime restarts
- **THEN** restored Coordinator runtime state SHALL retain its ownership unit and Coordinator identity marker
- **AND** restore behavior SHALL NOT promote the Coordinator into the supervised workspace fleet.

### Requirement: Coordinator runtime scope
The first Coordinator role SHALL supervise its own launched delegated fleet through lifecycle handles returned by existing `agent_run` / `agent_manage` control surfaces.

#### Scenario: Delegated fleet is tracked by handles
- **WHEN** the Coordinator starts delegated Agent runs in v1
- **THEN** it SHALL retain the returned stable session handles for each delegated run
- **AND** it SHALL use those handles with `poll`, `wait`, `steer`, and status reporting to supervise its launched fleet.

#### Scenario: Broad workspace visibility is deferred
- **WHEN** the Coordinator needs visibility into sessions it did not spawn, sibling sessions, or the full active-workspace supervised-session set
- **THEN** that broader `list_sessions` visibility SHALL be treated as a separate visibility-boundary capability specified by `add-coordinator-list-sessions-visibility`
- **AND** it SHALL NOT be required for the first Coordinator role's core delegation loop.

#### Scenario: Cross-window control is requested
- **WHEN** a Coordinator behavior would observe or act beyond the current window's active workspace
- **THEN** the first implementation SHALL reject or defer that behavior unless a later accepted spec defines owning-window routing or a shared session-control service
- **AND** it SHALL not silently create app-global cross-window control.

### Requirement: Coordinator role behavior contract
The system SHALL define a Coordinator-specific role behavior contract for the runtime prompt/instructions before exposing the Coordinator role.

#### Scenario: User input is classified
- **WHEN** the Coordinator receives user input
- **THEN** its role behavior SHALL distinguish conversational or advisory input, coordination instructions, and workspace/code work requests
- **AND** it SHALL NOT treat every user message as requiring a delegated Agent run.

#### Scenario: Direct answer is sufficient
- **WHEN** user input is conversational, advisory, or answerable from Coordinator-visible lifecycle state, action records, terminal output, status text, or failure diagnostics
- **THEN** the Coordinator MAY answer directly without starting or steering another Agent run
- **AND** it SHALL avoid inventing unavailable workspace details.

#### Scenario: Coordination action is needed
- **WHEN** user input requires supervising or redirecting Agent work
- **THEN** the Coordinator SHALL use the accepted lifecycle/control APIs and structured action records
- **AND** it SHALL track delegated run handles and statuses rather than relying on assistant prose.

#### Scenario: Workspace work is needed
- **WHEN** user input requires codebase investigation, file reads/searches, edits, test runs, worktree operations, or tab-scoped context
- **THEN** the Coordinator SHALL delegate that work to an appropriately scoped Agent Mode session
- **AND** it SHALL NOT attempt to perform the workspace work directly through Coordinator tools.

#### Scenario: Role behavior is installed
- **WHEN** the Coordinator role is launched or resumed
- **THEN** the runtime SHALL receive Coordinator-specific instructions matching this behavior contract
- **AND** ordinary `pair`, `engineer`, `explore`, and `design` prompts SHALL NOT be reused without Coordinator-specific behavior and tool-boundary instructions.

### Requirement: Coordinator instruction delivery
The system SHALL define how user instructions reach the real Coordinator runtime without relying on the demo selected-session composer path as the final architecture.

#### Scenario: User sends instruction to real Coordinator
- **WHEN** the real Coordinator runtime is available and the user sends a Coordinator instruction
- **THEN** the instruction SHALL be delivered to the real Coordinator runtime through an explicit addressing path
- **AND** delivery SHALL NOT depend on treating a supervised workspace session as the Coordinator.

#### Scenario: Real runtime and manual fallback both exist
- **WHEN** both the real Coordinator runtime and the manual selected-session demo composer are available during migration
- **THEN** the UI or view model SHALL define clear precedence and labeling for the real runtime versus manual fallback
- **AND** the user SHALL NOT be led to believe a supervised fallback session is the real Coordinator role.

#### Scenario: Coordinator starts child work during a turn
- **WHEN** the Coordinator receives a coordination instruction that requires delegated agents
- **THEN** the runtime SHALL be able to issue accepted lifecycle/control actions from that turn using its Coordinator-scoped tool policy
- **AND** delegated child runs SHALL remain ordinary scoped Agent Mode sessions, not Coordinators.

### Requirement: Delegate-only first tool contract
The first Coordinator role implementation SHALL use a delegate-only tool contract.

#### Scenario: Coordinator observes session state
- **WHEN** the Coordinator needs to understand workspace work in progress
- **THEN** it SHALL use explicit session/model listing, lifecycle status, compact metadata, terminal output, status text, and compact failure diagnostics
- **AND** it SHALL NOT load full transcripts, files, diffs, or unbounded full logs as part of the first-version board supervision loop.

#### Scenario: Coordinator directs agents
- **WHEN** the Coordinator needs work performed by an agent
- **THEN** it SHALL start, message, steer, poll, wait for, or report status/failure from Agent runs/sessions through explicit lifecycle/control APIs and snapshot fields
- **AND** it SHALL leave tab focus, file reads/searches, file selection, and worktree context to the target agent session.

#### Scenario: User instruction creates multiple delegated runs
- **WHEN** a user instruction requires multiple independent delegated workstreams
- **THEN** the Coordinator MAY start multiple delegated Agent runs through the accepted lifecycle/control APIs
- **AND** it SHALL record each delegated run handle and action status separately
- **AND** it SHALL observe each delegated run through deterministic lifecycle state rather than assistant prose
- **AND** it SHALL continue polling or waiting on remaining delegated run handles after the first delegated run becomes actionable or terminal
- **AND** it SHALL report combined outcomes from lifecycle state, action records, terminal output, status text, and compact failure diagnostics.

#### Scenario: Respond capability is considered
- **WHEN** the Coordinator needs to answer a pending interaction
- **THEN** Coordinator access to `respond` SHALL remain unavailable until authorization and stale-interaction failure semantics are accepted for Coordinator connections
- **AND** any accepted Coordinator respond behavior SHALL be audited as a structured action record.

#### Scenario: Direct tab and workspace mutation is requested
- **WHEN** a Coordinator behavior would require direct tab focus, file-selection mutation, file read/search scoped to a focused tab, worktree mutation, approval/decline, cancel, stop, or full log read behavior
- **THEN** the first Coordinator role SHALL reject or defer that behavior unless a later accepted spec grants the capability with authorization and audit semantics.

#### Scenario: Tools and operations are restricted for Coordinator
- **WHEN** tools are advertised or installed for the Coordinator runtime
- **THEN** the system SHALL advertise only the accepted lifecycle/control-plane toolset and hide ordinary tab-scoped file, selection, worktree, and focus tools from tool-list output
- **AND** execution policy SHALL reject Coordinator attempts to invoke blocked whole tools even if those tools are called by name
- **AND** op-level or argument-level guards SHALL reject disallowed operations on otherwise-allowed tools, including Coordinator use of `agent_run.respond`, `agent_run.cancel`, `agent_manage.stop_session`, `agent_manage.cleanup_sessions`, and worktree creation/binding arguments on `agent_run.start` unless a later accepted spec grants access.

#### Scenario: Workspace investigation or mutation is requested
- **WHEN** user intent requires direct codebase investigation, file reads/searches, file edits, selection changes, tab focus, or worktree mutation
- **THEN** the first Coordinator role SHALL spawn or steer an appropriately scoped Agent Mode session to perform that work
- **AND** the Coordinator SHALL observe the delegated session through lifecycle state, structured action status, terminal output, status text, and compact failure diagnostics instead of using those workspace tools directly.

### Requirement: Coordinator context and history ownership
The system SHALL keep Coordinator context, conversation history, and action/instruction logs invisible to supervised-session enumeration surfaces.

#### Scenario: Coordinator stores history
- **WHEN** the Coordinator records conversation, instruction, or action history
- **THEN** the system MAY reuse existing Agent session persistence or another control-plane store
- **AND** storage choice SHALL NOT cause the Coordinator runtime to appear as a supervised workspace row in any workspace-session enumeration surface, including but not limited to Coordinator mode, Agent Mode sidebar/session lists, or MCP session lists.

#### Scenario: Coordinator state is restored
- **WHEN** Coordinator state is restored after app or runtime restart
- **THEN** restored Coordinator state SHALL retain its Coordinator identity marker
- **AND** restoring it SHALL NOT create, restore, or promote a workspace Agent Mode session into any supervised-session enumeration.

### Requirement: Structured Coordinator action records
The system SHALL represent first-version Coordinator role actions as structured, auditable action records before adding autonomous directive behavior.

#### Scenario: User instruction is handled
- **WHEN** a user sends a Coordinator instruction or message
- **THEN** the system SHALL record the instruction source, target, action type, lifecycle handle, status, and failure information when it causes control-plane work
- **AND** it SHALL avoid relying on assistant prose parsing as the source of action state.

#### Scenario: First action set is used
- **WHEN** the first Coordinator role implementation dispatches work
- **THEN** it SHALL limit action types to the accepted initial set, expected to include list, start or spawn, poll or wait, message or steer, and report status or failure
- **AND** higher-risk actions SHALL remain unavailable until explicitly specified.

#### Scenario: Session state changes without a user instruction
- **WHEN** a supervised Agent run/session changes state after the user's last instruction
- **THEN** the first Coordinator role MAY update status fields and action records from sourced lifecycle state
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

#### Scenario: Real Coordinator runtime is integrated with session enumeration
- **WHEN** the real Coordinator runtime becomes available
- **THEN** the system SHALL mark that runtime with a first-class Coordinator identity marker and exclude it from every workspace-session enumeration surface, preferably through a single shared enumeration-boundary predicate
- **AND** the runtime SHALL NOT appear in any `sessionIndex`-derived UI, service, or MCP session enumeration as a supervised row, including `CoordinatorModeSnapshot.groups`, Agent Mode sidebar/session lists, and MCP `list_sessions`.

#### Scenario: New session enumeration surface is added
- **WHEN** a new UI, service, or MCP surface enumerates workspace Agent sessions
- **THEN** it SHALL use the shared Coordinator-excluding enumeration path or apply the same identity predicate at its enumeration boundary
- **AND** it SHALL NOT require a leaf-view-only special case to hide the Coordinator runtime.

#### Scenario: Demo Coordinator detection remains available
- **WHEN** the manual selected-session composer or auto-detected demo Coordinator session remains available during migration
- **THEN** the system SHALL label or treat it as demo/manual fallback behavior
- **AND** it SHALL remain distinct from the real Coordinator role/runtime.

#### Scenario: Coordinator-self Agent Mode navigation is suppressed during migration
- **WHEN** the Coordinator view is using a real, marked, or production-demo Coordinator backing runtime
- **THEN** the Coordinator rail SHALL hide Coordinator-self `Open in Agent Mode` / `Open agent chat` affordances
- **AND** delegate session rows, child-session cards, and pending summaries SHALL keep their Agent Mode navigation when route data is available.

#### Scenario: Production-demo bridge lacks a marker
- **WHEN** the production-demo Coordinator still lacks a first-class runtime marker
- **THEN** the UI MAY locally suppress Coordinator-self navigation to preserve the intended product model
- **AND** the implementation SHALL still track the marker plus shared enumeration-exclusion work as the durable architecture.
