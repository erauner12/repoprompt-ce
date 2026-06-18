## ADDED Requirements

### Requirement: Dashboard surface
The system SHALL provide a non-default Orchestrator Dashboard peer surface inside the existing `.main` app experience.

#### Scenario: Agent Mode remains default
- **WHEN** a user opens the app into the `.main` route
- **THEN** the system SHALL show the existing Agent Mode surface by default in v1
- **AND** this landing surface SHALL be represented as a configurable/default main-surface decision rather than a hard-coded permanent product constraint.

#### Scenario: Workspace entry remains unchanged
- **WHEN** the app is in workspace-entry routing
- **THEN** the dashboard SHALL NOT bypass existing workspace-entry gating
- **AND** the Agent Mode ↔ Orchestrator Dashboard surface switcher SHALL NOT appear until a real workspace is active.

#### Scenario: Dashboard entry point is a peer surface switcher
- **WHEN** a real workspace is active and the app is in `.main`
- **THEN** the system SHALL provide a persistent top-level affordance for switching between Agent Mode and the Orchestrator Dashboard
- **AND** the affordance SHALL use a macOS-native peer-surface control, such as a toolbar segmented control or equivalent adaptive surface switcher
- **AND** it SHALL NOT use an iOS-style tab bar
- **AND** the same surface choices SHALL be reachable from the View menu
- **AND** the affordance SHALL model those views as peer `.main` surfaces rather than a one-way dashboard button or workspace-entry page.

#### Scenario: Main surface selection is window-sticky
- **WHEN** a user switches between Agent Mode and the Orchestrator Dashboard in a window
- **THEN** that window SHALL retain the selected main surface while it remains alive
- **AND** Coordinator selection state SHALL remain scoped separately by active workspace.

#### Scenario: Forced main launch remains stable
- **WHEN** UI tests or launch configuration force `.main`
- **THEN** the system SHALL land on Agent Mode unless a dashboard-specific forced-surface option is explicitly added.

### Requirement: Dashboard snapshot projection
The system SHALL render the Orchestrator Dashboard from a single dashboard-facing `OrchestratorDashboardSnapshot` projection.

#### Scenario: Dashboard renders from one projection
- **WHEN** the dashboard renders top counts, groups, rows, pending prompts, Coordinator rail, MCP footer, and deep-link affordances
- **THEN** those UI regions SHALL derive their displayed state from the same `OrchestratorDashboardSnapshot`.

#### Scenario: Projection composes independent upstreams
- **WHEN** the snapshot is produced after `add-mcp-dashboard-consumer` is available
- **THEN** it SHALL compose active window Agent Mode session state/metadata and MCP dashboard state
- **AND** it SHALL NOT route MCP dashboard data through Agent Mode as a synthetic agent state.

#### Scenario: Snapshot avoids streaming churn
- **WHEN** assistant text, transcript tokens, or token counts stream without changing coarse dashboard state
- **THEN** the dashboard snapshot SHALL NOT republish changed rows solely because of those streaming deltas.

### Requirement: Active workspace rows and current-window live enrichment
The system SHALL scope v1 dashboard rows to the active workspace and live run-state enrichment to the current window.

#### Scenario: Dashboard opens in a workspace
- **WHEN** the dashboard opens
- **THEN** it SHALL consider sessions from the active workspace.

#### Scenario: Active workspace has no sessions
- **WHEN** the active workspace has no sessions to project
- **THEN** the dashboard SHALL show an empty state instead of empty groups or stale placeholder rows.

#### Scenario: Session live state belongs to another window
- **WHEN** a session is known from active-workspace persisted metadata but has no current-window live state
- **THEN** the dashboard SHALL render the card or row as stale/persisted-only in v1
- **AND** it SHALL NOT present stale persisted data as live status.

### Requirement: Coordinator selection
The system SHALL identify the dashboard Coordinator using explicit precedence.

#### Scenario: User-selected Coordinator exists
- **WHEN** the user has selected a valid Coordinator session for the active workspace in the current window
- **THEN** the dashboard SHALL use that session as Coordinator ahead of auto-detected candidates.

#### Scenario: Orchestrate workflow candidate exists
- **WHEN** no user-selected Coordinator exists and a parent session has launch or first-request workflow metadata of `Orchestrate`
- **THEN** the dashboard SHALL treat that parent session as a Coordinator candidate.

#### Scenario: MCP-originated lineage candidate exists
- **WHEN** no user-selected Coordinator or Orchestrate workflow candidate exists and a parent session is both a lineage root with child sessions and MCP-originated
- **THEN** the dashboard SHALL treat that parent session as a Coordinator candidate.

#### Scenario: Plain lineage parent exists
- **WHEN** a parent session has child sessions but is neither user-selected, Orchestrate-detected, nor MCP-originated
- **THEN** the dashboard SHALL NOT silently treat that parent as the Coordinator.

#### Scenario: No Coordinator is found
- **WHEN** no Coordinator can be selected or detected
- **THEN** the dashboard SHALL still render the grouped active-workspace board or list
- **AND** the Coordinator rail SHALL show an empty or choose-Coordinator state rather than blocking the dashboard
- **AND** the rail SHALL NOT render a separate by-agent roster of workspace sessions in v1.

#### Scenario: Multiple Coordinator candidates exist
- **WHEN** multiple auto-detected Coordinator candidates match
- **THEN** the dashboard SHALL use the most recent candidate within the highest-ranked matching precedence tier in v1
- **AND** a valid user-selected Coordinator SHALL override that automatic choice.

### Requirement: Board-first dashboard layout
The system SHALL present v1 as a read-only status board by default, with a list view as an alternate and responsive fallback.

#### Scenario: Dashboard first opens
- **WHEN** the user opens the Orchestrator Dashboard in v1
- **THEN** the dashboard SHALL show a board view by default
- **AND** status groups SHALL render as board columns containing session cards
- **AND** the board SHALL derive columns and cards from the same `OrchestratorDashboardSnapshot` grouping and row projection used by other dashboard regions.

#### Scenario: User switches to list view
- **WHEN** the user chooses List view
- **THEN** the dashboard SHALL render the same sourced rows and status groups in a list presentation
- **AND** the list SHALL preserve the same grouping, sorting, stale-row, deep-link, and read-only action constraints as the board.

#### Scenario: Board cannot fit available width
- **WHEN** the dashboard viewport cannot fit at least two usable board columns
- **THEN** the dashboard SHALL fall back to the List view rather than rendering a cramped board.

#### Scenario: Board side panes compete for width
- **WHEN** the board, Coordinator rail/chat, and inspector compete for horizontal space
- **THEN** the inspector / trailing detail column SHALL yield before the board
- **AND** Coordinator chat MAY collapse to a rail before board columns are reduced below their usable minimum
- **AND** the board MAY scroll horizontally to preserve usable column width.

#### Scenario: Board remains read-only in v1
- **WHEN** the v1 board renders session cards
- **THEN** it SHALL NOT provide drag-to-reorder, drag-to-dispatch, drag-to-change-status, inline approval, inline retry, or direct child-session mutation.

### Requirement: Coordinator composer
The system SHALL provide a scoped Coordinator composer as the only v1 dashboard write path.

#### Scenario: Coordinator is live in the current window
- **WHEN** a Coordinator is selected or detected
- **AND** the Coordinator session has current-window live state
- **THEN** the dashboard SHALL enable a Coordinator composer in the Coordinator rail.

#### Scenario: Coordinator is not reachable from the current window
- **WHEN** no Coordinator is selected or detected
- **OR** the resolved Coordinator is persisted-only or owned by another window
- **THEN** the dashboard SHALL disable the Coordinator composer or replace it with an `Open agent chat` affordance when route data is available
- **AND** it SHALL NOT restore, steal, or create a session solely to enable the composer.

#### Scenario: User sends a Coordinator directive
- **WHEN** the user submits text through the enabled Coordinator composer
- **THEN** the dashboard SHALL deliver that text as an ordinary user message to the Coordinator session through the existing Agent Mode message path
- **AND** it SHALL NOT wrap the directive in a new structured command envelope in v1.

#### Scenario: Directive is displayed after send
- **WHEN** a Coordinator directive is accepted by the dashboard
- **THEN** the dashboard MAY echo the user's sent directive into the Coordinator rail transcript
- **AND** Coordinator responses and child-session effects SHALL surface through the normal coarse dashboard snapshot refresh rather than a live token stream in the rail.

#### Scenario: Coordinator is mid-run
- **WHEN** the user attempts to send a directive while the Coordinator is mid-run
- **THEN** the dashboard MAY queue the directive as the next ordinary user turn or disable send
- **AND** it SHALL NOT implement dashboard-side interrupt or steering semantics in v1.

#### Scenario: Board state remains protected
- **WHEN** the Coordinator composer sends a directive
- **THEN** the composer SHALL NOT directly mutate child session state, dispatch cards, approve pending interactions, retry sessions, or change board/list status groups.

### Requirement: Session row projection
The system SHALL project dashboard session rows/cards from structured session and live-state data.

#### Scenario: Session row renders
- **WHEN** a session appears as a dashboard card or list row
- **THEN** the card or row SHALL derive identity, lineage, provider/model, worktree state, MCP origin, and run status from structured session metadata or live state.

#### Scenario: Workflow labels are deferred
- **WHEN** dashboard rows render in v1
- **THEN** the row SHALL omit workflow labels
- **AND** workflow index or transcript lookup policy SHALL remain a follow-up decision.

#### Scenario: Objective label has no source
- **WHEN** no structured objective source exists
- **THEN** the row SHALL omit objective labels.

#### Scenario: Workstream source exists
- **WHEN** bound worktree or logical-root metadata exists for a session and is useful for the UI
- **THEN** the dashboard MAY project that structural metadata as a workstream grouping label.

#### Scenario: Workstream source is absent
- **WHEN** no structured workstream source exists
- **THEN** the dashboard SHALL omit workstream chips
- **AND** it SHALL NOT parse session titles to invent workstream labels.

### Requirement: Status grouping and sorting
The system SHALL group dashboard rows by testable, structured status rules.

#### Scenario: Group precedence is evaluated
- **WHEN** a row has signals matching more than one group
- **THEN** the dashboard SHALL evaluate groups in this order: `Needs you`, `Blocked`, `Working`, `Done`, `Idle`.

#### Scenario: Session needs user attention
- **WHEN** a session has current-window live run state `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`
- **THEN** the dashboard SHALL group that row under `Needs you`
- **AND** live MCP-controlled pending interaction data MAY enrich the row prompt/details when available.

#### Scenario: Persisted-only card has active-looking stale run state
- **WHEN** a card or row is known only from persisted metadata and has no current-window live state
- **AND** its persisted run state is `.running`, `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`
- **THEN** the dashboard SHALL NOT count that card or row as live `Working` or `Needs you` in v1.

#### Scenario: Persisted-only card renders in board view
- **WHEN** a persisted-only session appears in board view
- **THEN** the dashboard SHALL visually mark the card as stale/persisted-only
- **AND** it SHALL not present the card as a live actionable card
- **AND** it SHALL preserve the same route/no-restore constraints used by list rows.

#### Scenario: Session is blocked
- **WHEN** a session has `.failed` run state or conflicted worktree/merge attention
- **THEN** the dashboard SHALL group that row under `Blocked`.

#### Scenario: Session is working
- **WHEN** a session has current-window live run state `.running`
- **THEN** the dashboard SHALL group that row under `Working`.

#### Scenario: Session is done
- **WHEN** a session run state is `.completed` or `.cancelled`
- **THEN** the dashboard SHALL group that row under `Done`.

#### Scenario: Session is idle
- **WHEN** a session run state is `.idle` and no higher-priority group applies
- **THEN** the dashboard SHALL group that row under `Idle`.

#### Scenario: Rows use default read-only sort
- **WHEN** cards or rows are displayed within a status group
- **THEN** the dashboard SHALL sort cards or rows within that group by `Last updated` by default
- **AND** it SHALL use cheap metadata such as attention age, activity date, last modified date, or completion date
- **AND** it SHALL NOT require per-row transcript loads solely to sort rows.

#### Scenario: User changes read-only sort
- **WHEN** the user selects `Last updated`, `Name`, or `Priority` sorting
- **THEN** the dashboard SHALL reorder cards or rows only within their existing status groups
- **AND** it SHALL NOT change a card's or row's group, run state, pending state, Coordinator relationship, or persisted session state.

#### Scenario: Priority sort has limited source data
- **WHEN** `Priority` sorting is selected
- **THEN** the dashboard SHALL use structured priority or attention metadata already present in the dashboard projection when available
- **AND** cards or rows without structured priority data SHALL remain ordered by a deterministic fallback
- **AND** the dashboard SHALL NOT infer priority from assistant prose or session titles.

#### Scenario: Drag ordering is unavailable in v1
- **WHEN** the v1 dashboard renders grouped cards or rows
- **THEN** it SHALL NOT provide drag-to-reorder, drag-to-dispatch, or drag-to-change-status interactions.

#### Scenario: High-priority board columns are non-empty
- **WHEN** `Needs you`, `Blocked`, or `Working` groups contain cards
- **THEN** the dashboard SHALL show those board columns by default when the board view is active.

#### Scenario: Lower-priority board columns are non-empty
- **WHEN** `Done` or `Idle` groups contain cards
- **THEN** the dashboard SHALL keep those columns available in board view
- **AND** it MAY de-emphasize, horizontally scroll, or collapse lower-priority columns when space is constrained
- **AND** it SHALL keep counts visible when a column is collapsed.

### Requirement: Pending interaction display
The system SHALL display pending interactions as read-only prompts that deep-link to Agent Mode.

#### Scenario: Pending interaction is available
- **WHEN** a live MCP-controlled session has an `AgentRunMCPSnapshot.Interaction` that can be projected into the dashboard snapshot
- **THEN** the dashboard SHALL render a read-only pending interaction summary with kind, title, prompt, details, and optional Agent UI route
- **AND** non-MCP pending prompt/detail projection SHALL remain a follow-up Agent Mode contract change.

#### Scenario: Pending interaction has no route
- **WHEN** a pending interaction summary cannot resolve an Agent UI route
- **THEN** the dashboard SHALL hide or disable `Open agent chat` and decision navigation affordances for that summary.

#### Scenario: User needs to respond
- **WHEN** a user chooses to respond to a pending interaction from the dashboard
- **THEN** the dashboard SHALL route the user to the existing Agent Mode session
- **AND** the dashboard SHALL NOT execute approval, decline, retry, reassign, or directive actions in v1.

#### Scenario: Assistant prose mentions a decision
- **WHEN** assistant text contains words that appear to request a user decision
- **THEN** the dashboard SHALL NOT classify it as a pending interaction unless structured pending state exists.

### Requirement: Agent chat deep link
The system SHALL deep-link dashboard rows to the existing Agent Mode session when route data is resolvable.

#### Scenario: Route is resolvable
- **WHEN** a dashboard row has active workspace context, a resolvable tab, and optional session ID
- **THEN** the dashboard SHALL provide an `Open agent chat` affordance that opens the existing Agent Mode session.

#### Scenario: Route is not resolvable
- **WHEN** a dashboard row lacks required route data
- **THEN** the dashboard SHALL hide or disable `Open agent chat` for that row.

#### Scenario: Persisted-only row lacks a resolvable tab
- **WHEN** a persisted-only row has no active workspace/tab/session route
- **THEN** the dashboard SHALL show the row without `Open agent chat`
- **AND** it SHALL NOT attempt to create or restore a session as part of dashboard rendering.

### Requirement: Compact MCP awareness
The system SHALL provide compact MCP client/tool-call awareness without replacing existing MCP status surfaces.

#### Scenario: Dashboard is visible
- **WHEN** the Orchestrator Dashboard is visible
- **THEN** the system SHALL subscribe to MCP dashboard updates through the Orchestrator Dashboard consumer provided by `add-mcp-dashboard-consumer`.

#### Scenario: Dashboard is hidden
- **WHEN** the Orchestrator Dashboard is not visible
- **THEN** the system SHALL stop dashboard-specific MCP update consumption.

#### Scenario: MCP clients exist
- **WHEN** MCP clients are connected, idle, or active
- **THEN** the dashboard SHALL show compact client and in-flight/recent tool-call awareness
- **AND** it SHALL allow MCP footer totals to include server/window-scoped clients or calls not represented by the active-workspace row list.

#### Scenario: MCP is off or empty
- **WHEN** the MCP server is off or has no connected clients
- **THEN** the dashboard SHALL show a compact empty/off state rather than a full status dashboard.

### Requirement: Progressive disclosure
The system SHALL keep the dashboard calm by default and expose detail only through deliberate user action.

#### Scenario: Coordinator rail avoids duplicate fleet views
- **WHEN** the dashboard renders the Coordinator rail in v1
- **THEN** the rail SHALL focus on Coordinator identity, selection, optional context, and the scoped Coordinator composer
- **AND** it SHALL NOT provide a separate `Agents` tab, agent roster, or "agents in current Coordinator context" surface that duplicates the board/list fleet view.

#### Scenario: Dashboard first renders
- **WHEN** the dashboard first renders
- **THEN** it SHALL show summarized counts, status board columns/cards, Coordinator context when available, and compact MCP awareness
- **AND** it SHALL NOT show full transcripts, full logs, diffs, file viewers, or continuously streaming tool feeds in the main board/list content.

#### Scenario: User selects a row
- **WHEN** the user selects a dashboard row
- **THEN** the dashboard MAY show a read-only inspector / trailing detail column with sourced status, pending interaction, blocker, worktree/merge, route, MCP, and session metadata summaries
- **AND** it SHALL NOT expose a dashboard-native full raw log, transcript, file viewer, or diff viewer in v1.

#### Scenario: User needs deep detail
- **WHEN** the user needs full transcript, raw log, detailed runtime state, file context, diff context, or action handling
- **THEN** the dashboard SHALL route the user to the existing Agent Mode surface.
