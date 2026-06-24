## ADDED Requirements

### Requirement: Coordinator mode surface
The system SHALL provide a non-default Coordinator mode peer surface inside the existing `.main` app experience.

#### Scenario: Agent Mode remains default
- **WHEN** a user opens the app into the `.main` route
- **THEN** the system SHALL show the existing Agent Mode surface by default in v1
- **AND** this landing surface SHALL be represented as a configurable/default main-surface decision rather than a hard-coded permanent product constraint.

#### Scenario: Workspace entry remains unchanged
- **WHEN** the app is in workspace-entry routing
- **THEN** the Coordinator view SHALL NOT bypass existing workspace-entry gating
- **AND** the Agent Mode ↔ Coordinator mode surface switcher SHALL NOT appear until a real workspace is active.

#### Scenario: Coordinator mode entry point is a peer surface switcher
- **WHEN** a real workspace is active and the app is in `.main`
- **THEN** the system SHALL provide a persistent top-level affordance for switching between Agent Mode and the Coordinator mode
- **AND** the affordance SHALL use a macOS-native peer-surface control, such as a toolbar segmented control or equivalent adaptive surface switcher
- **AND** the visible affordance SHALL occupy a single window-toolbar location across Agent Mode and Coordinator mode rather than living inside either surface's sidebar or rail
- **AND** it SHALL NOT use an iOS-style tab bar
- **AND** the same surface choices SHALL be reachable from the View menu with live checked state and keyboard shortcuts
- **AND** Coordinator SHALL be the left segment and use `Command-1`; Agent Mode SHALL be the right segment and use `Command-2`
- **AND** the affordance SHALL model those views as peer `.main` surfaces rather than a one-way Coordinator mode button or workspace-entry page.

#### Scenario: Main surface selection is window-sticky
- **WHEN** a user switches between Agent Mode and the Coordinator mode in a window
- **THEN** that window SHALL retain the selected main surface while it remains alive
- **AND** Coordinator selection state SHALL remain scoped separately by active workspace.

#### Scenario: Forced main launch remains stable
- **WHEN** UI tests or launch configuration force `.main`
- **THEN** the system SHALL land on Agent Mode unless a Coordinator-view-specific forced-surface option is explicitly added.

### Requirement: Coordinator view snapshot projection
The system SHALL render Coordinator mode from a single Coordinator-view-facing `CoordinatorModeSnapshot` projection.

#### Scenario: Coordinator Mode renders from one projection
- **WHEN** the Coordinator view renders top counts, groups, rows, pending prompts, Coordinator rail, compact MCP awareness, and deep-link affordances
- **THEN** those UI regions SHALL derive their displayed state from the same `CoordinatorModeSnapshot`.

#### Scenario: Projection composes independent upstreams
- **WHEN** the snapshot is produced after `add-mcp-coordinator-mode-consumer` is available
- **THEN** it SHALL compose active window Agent Mode session state/metadata and MCP Coordinator mode state
- **AND** it SHALL NOT route MCP Coordinator mode data through Agent Mode as a synthetic agent state.

#### Scenario: Snapshot avoids streaming churn
- **WHEN** assistant text, transcript tokens, or token counts stream without changing coarse Coordinator view state
- **THEN** the Coordinator view snapshot SHALL NOT republish changed rows solely because of those streaming deltas.

### Requirement: Active workspace rows and current-window live enrichment
The system SHALL scope v1 Coordinator view rows to the active workspace and live run-state enrichment to the current window.

#### Scenario: Coordinator view opens in a workspace
- **WHEN** the Coordinator view opens
- **THEN** it SHALL consider sessions from the active workspace.

#### Scenario: Active workspace has no sessions
- **WHEN** the active workspace has no sessions to project
- **THEN** the Coordinator view SHALL show an empty state instead of empty groups or stale placeholder rows.

#### Scenario: Session live state belongs to another window
- **WHEN** a session is known from active-workspace persisted metadata but has no current-window live state
- **THEN** the Coordinator view SHALL render the card or row as stale/persisted-only in v1
- **AND** it SHALL NOT present stale persisted data as live status.

### Requirement: Coordinator selection
The system SHALL identify the Coordinator session using explicit precedence.

#### Scenario: User-selected Coordinator exists
- **WHEN** the user has selected a valid Coordinator session for the active workspace in the current window
- **THEN** the Coordinator view SHALL use that session as Coordinator ahead of auto-detected candidates
- **AND** a future row/card selection affordance SHALL add explicit liveness and eligibility fall-through coverage before changing this precedence.

#### Scenario: Multiple Coordinator parents can be selected in Coordinator mode
- **WHEN** multiple valid Coordinator parent runtimes exist for the active workspace
- **THEN** the Coordinator view SHALL expose a visible in-Coordinator selection affordance for returning to an existing parent
- **AND** selecting a parent SHALL retarget the Coordinator rail to that parent without creating a new Coordinator runtime
- **AND** selected-runtime board/list projection SHALL update to that selected parent's eligible delegated descendants.

#### Scenario: Orchestrate workflow candidate exists
- **WHEN** no user-selected Coordinator exists and a parent session has launch or first-request workflow metadata of `Orchestrate`
- **THEN** the Coordinator view SHALL treat that parent session as a Coordinator candidate.

#### Scenario: MCP-originated lineage candidate exists
- **WHEN** no user-selected Coordinator or Orchestrate workflow candidate exists and a parent session is both a lineage root with child sessions and MCP-originated
- **THEN** the Coordinator view SHALL treat that parent session as a Coordinator candidate.

#### Scenario: Detection uses off-window lineage metadata without rendering it
- **WHEN** Coordinator detection has persisted or off-window lineage metadata for sessions that are not active-workspace rows in the current window
- **THEN** the Coordinator view MAY use that metadata only to determine whether a visible parent is an Orchestrate or MCP-originated lineage Coordinator candidate
- **AND** it SHALL NOT render those off-window or detection-only child sessions as Coordinator view rows solely because detection inspected them.

#### Scenario: Plain lineage parent exists
- **WHEN** a parent session has child sessions but is neither user-selected, Orchestrate-detected, nor MCP-originated
- **THEN** the Coordinator view SHALL NOT silently treat that parent as the Coordinator.

#### Scenario: No Coordinator is found
- **WHEN** no Coordinator can be selected or detected
- **THEN** the Coordinator view SHALL still render the grouped active-workspace board or list
- **AND** the Coordinator rail SHALL show an empty or choose-Coordinator state rather than blocking Coordinator mode
- **AND** the rail SHALL NOT render a separate by-agent roster of workspace sessions in v1.

#### Scenario: Multiple Coordinator candidates exist
- **WHEN** multiple auto-detected Coordinator candidates match
- **THEN** the Coordinator view SHALL use the most recent candidate within the highest-ranked matching precedence tier in v1
- **AND** a valid user-selected Coordinator SHALL override that automatic choice.

### Requirement: Coordinator fleet scope
The production-demo Coordinator mode SHALL separate the selected Coordinator conversation from the workspace-scoped supervised fleet.

#### Scenario: Multiple demo Coordinator runtimes exist
- **WHEN** more than one Coordinator backing runtime is marked for the active workspace demo fleet
- **THEN** the Coordinator view SHALL retain all marked runtimes as Coordinator fleet roots
- **AND** it SHALL select one runtime for the rail and composer without treating the selected runtime as the only fleet root.

#### Scenario: New Coordinator is started
- **WHEN** the user starts a new Coordinator chat or run in the production-demo bridge
- **THEN** the system SHALL create or select an additional Coordinator backing runtime for the active workspace
- **AND** it SHALL make that runtime the selected rail conversation
- **AND** it SHALL NOT unmark previous Coordinator backing runtimes or remove their supervised delegated descendants from the board/list.

#### Scenario: Coordinator rail chat is cleared
- **WHEN** the user clears the Coordinator rail chat display
- **THEN** the Coordinator view SHALL clear only the rail display state for the selected Coordinator conversation
- **AND** it SHALL NOT reset the workspace-scoped Coordinator fleet, unmark Coordinator runtimes, or remove delegated rows from the board/list.

#### Scenario: Fleet reset is requested
- **WHEN** the user explicitly resets or retires Coordinator fleet state
- **THEN** the operation SHALL communicate whether it retires only the selected Coordinator runtime or clears the whole workspace-scoped fleet
- **AND** destructive fleet reset semantics SHALL NOT be hidden behind `New Coordinator` or ordinary rail `Clear Chat`.

#### Scenario: Selected-runtime board checkpoint is active
- **WHEN** multiple demo Coordinator runtimes exist before aggregate fleet board projection is enabled
- **THEN** the board and list SHALL project eligible delegated descendants from the selected Coordinator runtime only
- **AND** changing the selected Coordinator runtime SHALL swap the board/list to that runtime's eligible delegated descendants
- **AND** this checkpoint SHALL preserve the same exclusion rules for Coordinator backing runtimes and explicitly marked Coordinator-internal housekeeping sessions.

#### Scenario: Selected Mission projection stays coherent
- **WHEN** the selected Mission has projected delegated descendants
- **THEN** the selected-Mission board and list SHALL render the same delegated rows counted by the selected Mission history entry
- **AND** Coordinator chat delegated event cards SHALL resolve workflow badges and lifecycle status from those same projected rows
- **AND** Coordinator chat delegated event cards SHOULD render sourced worktree identity when the delegated row has a bound worktree
- **AND** MCP-submitted Coordinator starts SHALL produce the same selected-Mission projection behavior as starts submitted through the visible Coordinator UI.

#### Scenario: Board projects aggregate supervised fleet
- **WHEN** the active workspace demo fleet has multiple Coordinator runtime roots with supervised delegated descendants
- **THEN** the board and list SHALL project eligible delegated descendants from all active fleet roots
- **AND** they SHALL exclude Coordinator backing runtimes and explicitly marked Coordinator-internal housekeeping sessions
- **AND** delegated descendants MAY include read-only probe descendants that are not immediate children of a Coordinator root
- **AND** they SHALL preserve existing status grouping, sorting, stale-row, workflow-label, and Agent Mode deep-link behavior.

#### Scenario: User opens the all-agents Coordinator board
- **WHEN** the user chooses the all-agents board destination from Coordinator mode navigation
- **THEN** the board and list SHALL include live delegated rows owned by all active Coordinator runtime roots in the workspace
- **AND** historical persisted-only rows SHALL NOT be included solely because they are still known to Agent Mode
- **AND** they SHALL continue to exclude Coordinator backing runtimes and explicitly marked Coordinator-internal housekeeping sessions
- **AND** direct Agent Mode sessions that are not owned by an active Coordinator root SHALL NOT appear solely because they are live in Agent Mode
- **AND** the destination SHALL hide the Coordinator chat/composer column so the board and inspector can use the available workspace width
- **AND** this navigation change SHALL NOT mutate Agent Mode session ownership, archive state, Coordinator fleet membership, Manual/Auto mode, or the selected Coordinator rail conversation.

#### Scenario: Delegate belongs to a parent Coordinator runtime
- **WHEN** a delegated row is projected from an aggregate fleet that contains multiple Coordinator runtime roots
- **THEN** the row projection SHALL retain sourced immediate parent metadata and resolved owner Coordinator metadata sufficient for future grouping, filtering, action-chip attribution, inspector context, and selected-parent emphasis
- **AND** owner Coordinator metadata SHALL be resolved by walking structured `parentSessionID` lineage upward until an active fleet-root Coordinator runtime is reached
- **AND** a row's owner Coordinator SHALL NOT be assumed to be the same value as its immediate `parentSessionID`
- **AND** the implementation SHALL NOT infer parent ownership from row titles or assistant prose.

#### Scenario: Aggregate row shows parent ownership
- **WHEN** a delegated row is projected in aggregate fleet mode
- **THEN** the card, list row, or inspector SHALL provide a compact sourced parent indicator
- **AND** the indicator SHALL identify the resolved owner Coordinator runtime root rather than a non-Coordinator immediate parent session
- **AND** the parent indicator SHALL use a reserved neutral treatment distinct from lifecycle state color and workflow badge styling
- **AND** it SHALL NOT assign parent identity by parsing row titles or assistant prose.

#### Scenario: Selected parent changes in aggregate mode
- **WHEN** aggregate fleet mode is showing rows from multiple Coordinator runtime roots
- **AND** the selected Coordinator runtime changes
- **THEN** the rail and composer SHALL switch to the newly selected Coordinator runtime
- **AND** the board/list SHALL remain scoped to the aggregate fleet instead of swapping to only the selected runtime
- **AND** rows owned by the selected Coordinator runtime SHOULD receive subtle visual emphasis so the rail selection and board remain connected.

#### Scenario: Delegated worker has read-only probe descendants
- **WHEN** a delegated worker session has a read-only `agent_explore` descendant
- **AND** that descendant is projected as part of the aggregate fleet
- **THEN** the descendant SHALL be attributed to the same resolved owner Coordinator runtime root as the worker
- **AND** the descendant SHALL NOT be presented as a separate Coordinator parent solely because it has lineage depth below a delegated worker.

#### Scenario: Hierarchical Coordinator delegation is requested
- **WHEN** a future design needs a delegated session to become a supervising Coordinator runtime with its own fleet
- **THEN** that behavior SHALL be treated as a separate hierarchical Coordinator design
- **AND** it SHALL require durable containment metadata and path-style attribution rather than reusing the v1 single owner Coordinator badge.

### Requirement: Board-first Coordinator view layout
The system SHALL present v1 as a read-only status board by default, with a list view as an alternate and responsive fallback.

#### Scenario: Coordinator view first opens
- **WHEN** the user opens the Coordinator mode in v1
- **THEN** the Coordinator view SHALL show a board view by default
- **AND** status groups SHALL render as board columns containing session cards
- **AND** the board SHALL derive columns and cards from the same `CoordinatorModeSnapshot` grouping and row projection used by other Coordinator view regions
- **AND** the selected-Mission board SHALL keep `Working`, `Review`, and `Done` visible as stable default lanes even when empty
- **AND** the selected-Mission board SHOULD omit empty `Needs you` and `Blocked` lanes until those statuses contain rows
- **AND** the selected-Mission board SHOULD size the stable default lanes so all three fit without horizontal scrolling at ordinary Coordinator panel widths
- **AND** Kanban cards SHOULD avoid redundant status or persistence chips when the same information is already communicated by the lane, inspector, or list view
- **AND** the All Agents Board SHALL continue to show every status lane for the fleet overview.

#### Scenario: User switches to list view
- **WHEN** the user chooses List view
- **THEN** the Coordinator view SHALL render the same sourced rows and status groups in a list presentation
- **AND** the list SHALL preserve the same grouping, sorting, stale-row, deep-link, and read-only action constraints as the board.

#### Scenario: Board cannot fit available width
- **WHEN** the Coordinator view viewport cannot fit at least two usable board columns
- **THEN** the Coordinator view SHALL fall back to the List view rather than rendering a cramped board.

#### Scenario: Board side panes compete for width
- **WHEN** the board, Coordinator rail/chat, and inspector compete for horizontal space
- **THEN** the inspector / trailing detail column SHALL yield before the board
- **AND** Coordinator chat MAY collapse to a rail before board columns are reduced below their usable minimum
- **AND** the board MAY scroll horizontally to preserve usable column width.

#### Scenario: Inspector is vertically stacked below the board
- **WHEN** the inspector is rendered as a bottom panel below the Kanban board
- **THEN** its collapse and restore affordance SHALL behave like a vertical sheet handle that slides the inspector down and back up
- **AND** it SHALL NOT use a left-side sidebar toggle as the primary hide/show control in that stacked layout
- **AND** the expanded stacked inspector SHOULD prefer a quiet handle treatment instead of redundant visible hide/show text.

#### Scenario: Board remains read-only in v1
- **WHEN** the v1 board renders session cards
- **THEN** it SHALL NOT provide drag-to-reorder, drag-to-dispatch, drag-to-change-status, inline child-session approval, inline retry, or direct child-session mutation
- **AND** Coordinator continuation approval SHALL be surfaced through the Coordinator chat as an ordinary visible message, not as a board or inspector row mutation.

#### Scenario: Worktree identity is visually consistent
- **WHEN** a Coordinator board card, list row, or inspector summary represents a session with a bound worktree
- **THEN** it SHOULD render the worktree's persisted visual color using the same identity source as Agent Mode
- **AND** sessions sharing the same worktree SHOULD show the same worktree color indicator across Coordinator and Agent Mode surfaces.

#### Scenario: Session filtering is All Agents board-bottom chrome
- **WHEN** the All Agents Board renders board or list presentation controls
- **THEN** view and sort controls SHALL remain in the top board control lane
- **AND** the session filter field SHALL render along the bottom of the board/list workspace rather than inline to the right of the top board controls
- **AND** selected-Mission boards SHOULD omit the session filter field and ignore stale All Agents filter text while scoped to the selected Mission.

### Requirement: Coordinator composer
The system SHALL provide a scoped Coordinator composer as the only v1 Coordinator-mode write path.

#### Scenario: Coordinator is live in the current window
- **WHEN** a Coordinator is selected or detected
- **AND** the Coordinator session has current-window live state
- **THEN** the Coordinator view SHALL enable a Coordinator composer in the Coordinator rail.

#### Scenario: Coordinator is not reachable from the current window
- **WHEN** no Coordinator is selected or detected
- **OR** the resolved Coordinator is persisted-only or owned by another window
- **THEN** the Coordinator view SHALL disable the Coordinator composer or replace it with an `Open agent chat` affordance when route data is available
- **AND** it SHALL NOT restore, steal, or create a session solely to enable the composer.

#### Scenario: Coordinator backing runtime is the addressed actor
- **WHEN** the Coordinator rail is addressing a real, marked, or production-demo Coordinator backing runtime
- **THEN** the rail SHALL treat the composer as the user-facing path for talking to that Coordinator
- **AND** it SHALL NOT expose `Open in Agent Mode` / `Open agent chat` for the Coordinator backing runtime itself
- **AND** this restriction SHALL NOT remove Agent Mode deep links from supervised delegate rows or pending summaries.

#### Scenario: User sends a Coordinator directive
- **WHEN** the user submits text through the enabled Coordinator composer
- **THEN** the Coordinator view SHALL deliver that text as an ordinary user message to the Coordinator session through the existing Agent Mode message path
- **AND** it SHALL NOT wrap the directive in a new structured command envelope in v1.

#### Scenario: Delegation events appear progressively
- **WHEN** a Coordinator starts or selects a Mission with delegated child sessions
- **THEN** the Coordinator chat SHOULD render delegated-session event cards as soon as those child sessions are projected
- **AND** those event cards SHOULD update from the live board row state rather than waiting for the child to reach a terminal state.

#### Scenario: Delegated event selects its board row
- **WHEN** the user clicks a delegated-session event card in the Coordinator conversation
- **AND** the delegated target still has a projected board or list row in the selected Mission scope
- **THEN** the Coordinator view SHOULD select that row and reveal the inspector for it
- **AND** the interaction MAY clear a local session filter that is hiding the selected row
- **AND** the interaction SHALL NOT mutate the delegated session, Coordinator Mission ownership, Manual/Auto mode, or Agent Mode state.

#### Scenario: Coordinator composer uses Agent Mode input affordances
- **WHEN** the Coordinator composer is editable
- **THEN** it MAY expose Agent Mode-compatible slash-skill insertion and workspace file-mention affordances that write into the ordinary directive text
- **AND** it MAY expose compact provider MCP/tool preference controls for settings that affect Coordinator runtime launches or follow-up turns
- **AND** those affordances SHALL NOT create child-session mutations, attachments, permission changes, or model switches unless a specific Coordinator-view behavior is defined.

#### Scenario: External test client submits a Coordinator directive
- **WHEN** a direct external MCP client uses the Coordinator chat control surface to list, select, create, or submit to Coordinator parents in the current window
- **THEN** the app SHALL route accepted submissions through the same Coordinator view submission path as the visible Coordinator composer
- **AND** the app SHALL target the existing selected or explicitly addressed Coordinator parent unless the request explicitly asks for a fresh parent
- **AND** it SHALL return structured Coordinator, composer, and board state suitable for live smoke validation
- **AND** the control surface SHALL NOT be advertised to in-agent role tool catalogs or used as a recursive Coordinator self-control tool.

#### Scenario: Coordinator mode is manual by default
- **WHEN** the Coordinator view is created for a workspace
- **THEN** the Manual/Auto mode SHALL default to Manual unless the user has previously changed the persisted setting
- **AND** the mode control SHALL be presented as Coordinator chat/composer-level state rather than as a Kanban board setting
- **AND** Manual mode SHALL leave the Coordinator runtime to report current results/status and wait for the user's next directive at ordinary turn boundaries.

#### Scenario: User enables Coordinator Auto mode
- **WHEN** the user enables the persisted Coordinator Auto mode
- **THEN** the Coordinator runtime MAY proactively continue supervising delegated work through existing Agent Mode control-plane/message paths until the user's original objective is satisfied
- **AND** it MAY wait, poll, or steer delegated Agent sessions when the safe next step is clear
- **AND** it SHALL NOT change the user-submitted directive text, create a new structured Coordinator command envelope, directly mutate board/list rows, change Kanban navigation/presentation state, or bypass normal Agent Mode session state.

#### Scenario: Coordinator-owned checks stay recoverable
- **WHEN** the Coordinator runtime performs its own follow-through, final inspection, or child recovery steps
- **THEN** it SHOULD prefer app-owned structured MCP tools such as Agent session wait/poll/log and Git status/diff over raw shell commands for routine status, diff, and validation checks
- **AND** it SHOULD use bounded waits plus poll, log, steer, or cancel to recover a delegated child or workflow that appears stuck
- **AND** it SHALL NOT rely on a raw shell loop in the Coordinator turn for routine child recovery or final confirmation when a structured MCP tool can answer the question.

#### Scenario: Coordinator chains workflow-bearing delegated sessions
- **WHEN** Coordinator Auto mode is enabled
- **AND** the user asks for a multi-stage workflow such as Orchestrate followed by Review
- **THEN** the Coordinator runtime MAY start separate workflow-bearing delegated Agent sessions through `agent_run.start` with `workflow_name` or `workflow_id`
- **AND** later workflow stages MAY bind to the same explicit child worktree created or returned by an earlier delegated stage
- **AND** the Coordinator SHALL continue to treat those workflow sessions as normal delegated children whose lifecycle state, review output, and worktree diff are observed through Agent Mode control-plane and MCP projection paths.

#### Scenario: Coordinator Auto mode reaches a boundary
- **WHEN** Coordinator Auto mode is enabled
- **AND** a delegated session requires user input, permission, human continuation, or is blocked or ambiguous
- **THEN** the Coordinator runtime SHALL stop at that boundary and surface the required user decision/status
- **AND** it SHALL NOT bypass or auto-acknowledge the user's continuation, approval, permission, or Needs-you gate.

#### Scenario: App-generated follow-through event resumes Coordinator
- **WHEN** Coordinator Auto mode is enabled
- **AND** the owning Coordinator runtime is idle
- **AND** a supervised delegated child reaches a terminal state or reviewable child output becomes available
- **THEN** the Coordinator view MAY submit a structured internal resume directive to the existing owning Coordinator runtime
- **AND** it SHALL NOT create a new Coordinator parent runtime
- **AND** the resume directive SHALL describe the observed event as app-generated context for the original objective rather than a new user request.

#### Scenario: Auto mode classifies projected workstreams
- **WHEN** the Coordinator view has projected a workstream summary for a supervised row
- **THEN** auto-mode resume/hold decisions SHALL prefer the projected owner Coordinator, phase, and next action over parallel ad hoc inference from row titles, assistant prose, or lower-level fallback status
- **AND** lower-level row fields MAY be used only when the structured workstream summary is unavailable.

#### Scenario: Coordinator continuation checkpoint is chat-owned
- **WHEN** the Coordinator pauses at a meaningful continuation boundary
- **AND** the selected Coordinator parent can receive another message
- **AND** the Coordinator response carries explicit continuation checkpoint metadata
- **THEN** the Coordinator rail MAY surface chat-level actions such as `Proceed`, `Revise`, and `Stop here`
- **AND** selecting `Proceed` SHALL submit an ordinary visible user message to the same Coordinator parent
- **AND** it SHALL NOT create a new Coordinator parent runtime
- **AND** it SHALL NOT grant permission to apply, merge, approve, commit, push, create a PR, or perform irreversible actions unless the message explicitly grants that action.
- **AND** the checkpoint metadata SHALL be stripped from Coordinator rail display text.

#### Scenario: Ordinary Coordinator replies do not create checkpoints
- **WHEN** the Coordinator publishes a normal status update, conversational answer, or final summary without explicit checkpoint metadata
- **THEN** the Coordinator rail SHALL NOT surface `Proceed`, `Revise`, or `Stop here` actions for that message.

#### Scenario: Inspector remains inspection-only
- **WHEN** a selected delegated row has review, merge, worktree, status, or session details
- **THEN** the inspector MAY expose those details and an `Open agent chat` affordance
- **AND** routeable but non-live reply affordances MAY open Agent Mode so the user can reply in the existing Agent session
- **AND** it SHALL NOT own mission continuation approval semantics.

#### Scenario: Done does not imply human acceptance
- **WHEN** a delegated row reaches the `Done` group
- **THEN** `Done` SHALL mean the child/workstream reached a terminal session outcome
- **AND** it SHALL NOT imply the human accepted, merged, committed, pushed, or otherwise approved the produced work.

#### Scenario: Follow-through resume events are deduplicated
- **WHEN** repeated lifecycle refreshes observe the same child terminal state or reviewable child output
- **THEN** the Coordinator view SHALL use stable event identifiers to avoid submitting duplicate resume directives for the same event
- **AND** if the Coordinator runtime is active, the event MAY remain pending until the runtime reaches a turn boundary.

#### Scenario: Production-demo Coordinator bridge dispatches children
- **WHEN** the production-demo Coordinator runtime delegates work
- **THEN** delegation SHALL use the existing Agent Mode MCP control-plane primitive, such as `agent_run.start`, to create normal tab-scoped Agent sessions
- **AND** the demo Coordinator runtime root SHALL be modeled as a marked Coordinator backing runtime rather than as a separate non-tab runtime
- **AND** delegated child sessions SHALL retain their normal tab-coupled selection, worktree, transcript, permission, and routing state.

#### Scenario: Read-only Coordinator delegation may omit a worktree
- **WHEN** the production-demo Coordinator runtime delegates read-only investigation, summarization, or status work
- **THEN** the delegated child MAY be started without an explicit worktree sandbox
- **AND** the delegated child SHALL still retain normal tab-coupled transcript, permission, and routing state.

#### Scenario: Mutable Coordinator delegation requires an explicit child worktree
- **WHEN** the production-demo Coordinator runtime delegates work that may edit files, run validation that writes outputs, generate a merge preview, commit, or prepare a PR
- **THEN** the delegated child start SHALL include an explicit isolated execution sandbox such as `worktree_create:true` or a specific `worktree_id`
- **AND** inherited worktree binding alone SHALL NOT satisfy this requirement
- **AND** the worktree identity SHALL be available before the child session is created so follow-through, review, and merge state can be attributed to a stable child execution context.

#### Scenario: Mutable Coordinator delegation without a worktree is rejected
- **WHEN** a Coordinator-owned `agent_run.start` attempts mutable delegated work without an explicit child worktree sandbox
- **THEN** the app SHALL reject the start before creating a delegated child session
- **AND** the rejection SHALL tell the Coordinator how to retry with `worktree_create:true` or an existing `worktree_id`
- **AND** ordinary non-Coordinator Agent Mode starts SHALL preserve their existing worktree behavior.

#### Scenario: Coordinator actor bridge remains distinct from the target role
- **WHEN** v1 uses the production-demo Coordinator bridge
- **THEN** the Coordinator actor itself SHALL NOT be specified as requiring `workflow_name="orchestrate"`
- **AND** delegated child sessions MAY still carry real `workflow_id` or `workflow_name` metadata
- **AND** the production-demo bridge SHALL be treated as a scaffold toward the first-class Coordinator role specified by `add-coordinator-role`
- **AND** the bridge SHALL NOT be treated as the durable Coordinator role identity, policy, or session-visibility mechanism.

#### Scenario: Directive is displayed after send
- **WHEN** a Coordinator directive is accepted by the Coordinator view
- **THEN** the Coordinator view MAY echo the user's sent directive into the Coordinator rail transcript
- **AND** Coordinator responses and child-session effects SHALL surface through the normal coarse Coordinator view snapshot refresh rather than a live token stream in the rail.

#### Scenario: Coordinator rail transcript is cleared
- **WHEN** the user clears the Coordinator rail chat display
- **THEN** the Coordinator view SHALL reset only the rail's displayed transcript state
- **AND** it SHALL NOT delete, truncate, or rewrite the underlying Coordinator session transcript
- **AND** the Coordinator session SHALL continue to persist and archive through the existing Agent Mode session lifecycle.

#### Scenario: Coordinator is mid-run
- **WHEN** the user attempts to send a directive while the Coordinator is mid-run
- **THEN** the Coordinator view MAY queue the directive as the next ordinary user turn or disable send
- **AND** it SHALL NOT implement Coordinator-view-side interrupt or steering semantics in v1.

#### Scenario: Board state remains protected
- **WHEN** the Coordinator composer sends a directive
- **THEN** the composer SHALL NOT directly mutate child session state, dispatch cards, approve pending interactions, retry sessions, or change board/list status groups.

### Requirement: Session row projection
The system SHALL project Coordinator mode session rows/cards from structured session and live-state data.

#### Scenario: Session row renders
- **WHEN** a session appears as a Coordinator view card or list row
- **THEN** the card or row SHALL derive identity, lineage, provider/model, worktree state, MCP origin, and run status from structured session metadata or live state.

#### Scenario: Workflow metadata is absent
- **WHEN** a Coordinator view row has no sourced workflow metadata
- **THEN** the row SHALL omit workflow labels.

#### Scenario: Workflow metadata is present
- **WHEN** a Coordinator view row has a sourced workflow display summary derived from real Agent Mode workflow metadata
- **THEN** the card, list row, inspector, or related Coordinator action chip MAY render a compact read-only workflow label with display name, icon, and accent
- **AND** the label SHALL NOT affect grouping, sorting, filtering, action creation, model/tool selection, permissions, or runtime behavior.

#### Scenario: Persisted workflow summary survives restart
- **WHEN** a workflow-bearing delegated Agent session is restored from persisted session metadata after app restart
- **THEN** Coordinator rows, inspectors, and delegated conversation cards SHOULD retain the workflow label without requiring the user to open the Agent chat first
- **AND** Agent session metadata index reconciliation SHALL preserve an existing workflow summary or recover it from the persisted session file when rebuilding from lightweight stubs.

#### Scenario: Workflow metadata changes
- **WHEN** the latest sourced user-turn workflow for a live row changes
- **THEN** the Coordinator view SHALL update the workflow label from the new display summary.

#### Scenario: Workflow metadata clears
- **WHEN** a later live user turn for the same row has no workflow metadata
- **THEN** the Coordinator view SHALL clear the workflow label rather than preserving the previous workflow as stale context.

#### Scenario: Objective label has no source
- **WHEN** no structured objective source exists
- **THEN** the row SHALL omit objective labels.

#### Scenario: Workstream source exists
- **WHEN** bound worktree or logical-root metadata exists for a session and is useful for the UI
- **THEN** the Coordinator view MAY project that structural metadata as a workstream grouping label
- **AND** delegated conversation cards SHOULD use the same worktree visual identity source as board cards and inspector fields.

#### Scenario: Workstream source is absent
- **WHEN** no structured workstream source exists
- **THEN** the Coordinator view SHALL omit workstream chips
- **AND** it SHALL NOT parse session titles to invent workstream labels.

#### Scenario: Workstream summary is projected
- **WHEN** a Coordinator view row represents delegated Agent work
- **THEN** the Coordinator view SHALL project a read-only `CoordinatorWorkstream` summary from structured session/live-state data
- **AND** the summary SHALL include the session objective/title, current phase, child session ID, owner Coordinator root when available, worktree binding when available, workflow label when available, available merge/inspection state, and a derived next action when the row is actionable
- **AND** the summary ID SHALL be stable for the child session it describes
- **AND** the summary SHALL remain a flat read model that can later receive dependency edges without requiring a DAG in v1
- **AND** the summary SHALL NOT mutate runtime state, approve actions, apply/merge/commit changes, or parse assistant prose as authoritative state.

### Requirement: Status grouping and sorting
The system SHALL group Coordinator view rows by testable, structured status rules.

#### Scenario: Group precedence is evaluated
- **WHEN** a row has signals matching more than one group
- **THEN** the Coordinator view SHALL evaluate groups in this order: `Needs you`, `Blocked`, `Working`, `Review`, `Done`, `Idle`.

#### Scenario: Session needs user attention
- **WHEN** a session has current-window live run state `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`
- **THEN** the Coordinator view SHALL group that row under `Needs you`
- **AND** live MCP-controlled pending interaction data MAY enrich the row prompt/details when available.

#### Scenario: Persisted-only card has active-looking stale run state
- **WHEN** a card or row is known only from persisted metadata and has no current-window live state
- **AND** its persisted run state is `.running`, `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`
- **THEN** the Coordinator view SHALL NOT count that card or row as live `Working` or `Needs you` in v1.

#### Scenario: Persisted-only card has blocked-looking stale metadata
- **WHEN** a card or row is known only from persisted metadata and has no current-window live state
- **AND** its persisted run state is `.failed` or its persisted merge/worktree metadata reports conflicted attention
- **THEN** the Coordinator view SHALL render that card or row as stale/persisted-only rather than a live `Blocked` contributor
- **AND** it SHALL NOT increment live Blocked top counts or place the stale row in the `Blocked` group solely from persisted-only blocked-looking metadata.

#### Scenario: Persisted-only card renders in board view
- **WHEN** a persisted-only session appears in board view
- **THEN** the Coordinator view SHALL visually mark the card as stale/persisted-only
- **AND** it SHALL not present the card as a live actionable card
- **AND** it SHALL preserve the same route/no-restore constraints used by list rows.

#### Scenario: Session is blocked
- **WHEN** a current-window live session has `.failed` run state or conflicted worktree/merge attention
- **THEN** the Coordinator view SHALL group that row under `Blocked`.

#### Scenario: Session is working
- **WHEN** a session has current-window live run state `.running`
- **THEN** the Coordinator view SHALL group that row under `Working`.

#### Scenario: Completed session has review material
- **WHEN** a session run state is `.completed` or `.cancelled`
- **AND** structured review material such as a worktree merge preview remains available for human review
- **THEN** the Coordinator view MAY group that row under `Review` when the material is the next actionable thing to inspect
- **AND** the row and inspector MAY expose merge/inspection context for inspection
- **AND** the inspector SHALL NOT own continuation approval for the Coordinator objective.

#### Scenario: Terminal session is eligible for Done
- **WHEN** a completed or cancelled row has no higher-priority Needs-you, Blocked, Working, or Review signal
- **THEN** the Coordinator view SHALL keep that row eligible for `Done`
- **AND** `Done` SHALL remain an observational terminal state, not a human acceptance state.

#### Scenario: Coordinator asks for human continuation after inspection
- **WHEN** the Coordinator determines the next step should wait for human confirmation after reviewing completed work
- **THEN** the confirmation SHALL be requested in the Coordinator conversation
- **AND** any continuation response SHALL be represented as a visible message in that conversation.

#### Scenario: Session is done
- **WHEN** a session run state is `.completed` or `.cancelled`
- **AND** no unacknowledged structured review material remains
- **THEN** the Coordinator view SHALL group that row under `Done`.

#### Scenario: Session is idle
- **WHEN** a session run state is `.idle` and no higher-priority group applies
- **THEN** the Coordinator view SHALL group that row under `Idle`.

#### Scenario: Rows use default read-only sort
- **WHEN** cards or rows are displayed within a status group
- **THEN** the Coordinator view SHALL sort cards or rows within that group by `Last updated` by default
- **AND** it SHALL use cheap metadata such as attention age, activity date, last modified date, or completion date
- **AND** it SHALL NOT require per-row transcript loads solely to sort rows.

#### Scenario: User changes read-only sort
- **WHEN** the user selects `Last updated`, `Name`, or `Priority` sorting
- **THEN** the Coordinator view SHALL reorder cards or rows only within their existing status groups
- **AND** it SHALL NOT change a card's or row's group, run state, pending state, Coordinator relationship, or persisted session state.

#### Scenario: Priority sort has limited source data
- **WHEN** `Priority` sorting is selected
- **THEN** the Coordinator view SHALL use structured priority or attention metadata already present in the Coordinator view projection when available
- **AND** cards or rows without structured priority data SHALL remain ordered by a deterministic fallback
- **AND** the Coordinator view SHALL NOT infer priority from assistant prose or session titles.

#### Scenario: Drag ordering is unavailable in v1
- **WHEN** the v1 Coordinator view renders grouped cards or rows
- **THEN** it SHALL NOT provide drag-to-reorder, drag-to-dispatch, or drag-to-change-status interactions.

#### Scenario: High-priority board columns are non-empty
- **WHEN** `Needs you`, `Blocked`, or `Working` groups contain cards
- **THEN** the Coordinator view SHALL show those board columns by default when the board view is active.

#### Scenario: Lower-priority board columns are non-empty
- **WHEN** `Done` or `Idle` groups contain cards
- **THEN** the Coordinator view SHALL keep those columns available in board view
- **AND** it MAY de-emphasize, horizontally scroll, or collapse lower-priority columns when space is constrained
- **AND** it SHALL keep counts visible when a column is collapsed.

### Requirement: Pending interaction display
The system SHALL display pending interactions as read-only prompts that deep-link to Agent Mode.

#### Scenario: Pending interaction is available
- **WHEN** a live MCP-controlled session has an `AgentRunMCPSnapshot.Interaction` that can be projected into the Coordinator view snapshot
- **THEN** the Coordinator view SHALL render a read-only pending interaction summary with kind, title, prompt, details, and optional Agent UI route
- **AND** non-MCP pending prompt/detail projection SHALL remain a follow-up Agent Mode contract change.

#### Scenario: Pending interaction has no route
- **WHEN** a pending interaction summary cannot resolve an Agent UI route
- **THEN** the Coordinator view SHALL hide or disable `Open agent chat` and decision navigation affordances for that summary.

#### Scenario: User needs to respond
- **WHEN** a user chooses to respond to a pending interaction from the Coordinator view
- **THEN** the Coordinator view SHALL route the user to the existing Agent Mode session
- **AND** the Coordinator view SHALL NOT execute approval, decline, retry, reassign, or directive actions in v1.

#### Scenario: Assistant prose mentions a decision
- **WHEN** assistant text contains words that appear to request a user decision
- **THEN** the Coordinator view SHALL NOT classify it as a pending interaction unless structured pending state exists.

### Requirement: Agent chat deep link
The system SHALL deep-link Coordinator view rows to the existing Agent Mode session when route data is resolvable.

#### Scenario: Route is resolvable
- **WHEN** a Coordinator view row has active workspace context, a resolvable tab, and optional session ID
- **THEN** the Coordinator view SHALL provide an `Open agent chat` affordance that opens the existing Agent Mode session.

#### Scenario: Inspector reply target is routeable but not live
- **WHEN** a selected delegated row is not live in the current Coordinator window
- **AND** the row has a resolvable Agent chat route
- **THEN** the inspector reply affordance SHOULD present an explicit `Open to reply` action
- **AND** activating it SHALL route to the existing Agent Mode session instead of requiring the user to first discover the separate `Open Agent` button.

#### Scenario: Route is not resolvable
- **WHEN** a Coordinator view row lacks required route data
- **THEN** the Coordinator view SHALL hide or disable `Open agent chat` for that row.

#### Scenario: Persisted-only row lacks a resolvable tab
- **WHEN** a persisted-only row has no active workspace/tab/session route
- **THEN** the Coordinator view SHALL show the row without `Open agent chat`
- **AND** it SHALL NOT attempt to create or restore a session as part of Coordinator view rendering.

#### Scenario: Row is the Coordinator backing runtime
- **WHEN** a session or runtime is identified as the Coordinator backing actor rather than a supervised delegate row
- **THEN** the Coordinator view SHALL NOT expose it as an Agent chat deep-link target from the Coordinator rail or board/list fleet
- **AND** the implementation SHALL prefer excluding it from supervised-session enumeration before leaf views need to hide it.

#### Scenario: Row is Coordinator-internal housekeeping
- **WHEN** a session is explicitly marked as Coordinator-internal housekeeping
- **THEN** the Coordinator view SHALL exclude it from board/list fleet rows and Coordinator action-chip rows
- **AND** the implementation SHALL NOT infer this internal state from session title text.

### Requirement: Compact MCP awareness
The system SHALL provide compact MCP client/tool-call awareness without replacing existing MCP status surfaces.

#### Scenario: Coordinator view is visible
- **WHEN** the Coordinator mode is visible
- **THEN** the system SHALL subscribe to MCP Coordinator mode updates through the Coordinator view consumer provided by `add-mcp-coordinator-mode-consumer`.

#### Scenario: Coordinator view is hidden
- **WHEN** the Coordinator mode is not visible
- **THEN** the system SHALL stop Coordinator-view-specific MCP update consumption.

#### Scenario: MCP clients or recent calls exist
- **WHEN** MCP clients are connected, idle, or active, or the running MCP server has recent tool-call history
- **THEN** the Coordinator view SHALL show compact client and in-flight/recent tool-call awareness in stable board chrome
- **AND** it SHALL allow MCP awareness totals to include server/window-scoped clients or calls not represented by the active-workspace row list
- **AND** recent-call history without connected clients SHALL use a history-aware idle presentation rather than the empty/off state.

#### Scenario: MCP is off or empty
- **WHEN** the MCP server is off or has no connected clients and no recent tool-call history
- **THEN** the Coordinator view SHALL show a compact empty/off state rather than a full status surface.

### Requirement: Progressive disclosure
The system SHALL keep the Coordinator view calm by default and expose detail only through deliberate user action.

#### Scenario: Coordinator rail avoids duplicate fleet views
- **WHEN** the Coordinator view renders the Coordinator rail in v1
- **THEN** the rail SHALL focus on Coordinator identity, selection, optional context, and the scoped Coordinator composer
- **AND** it SHALL NOT provide a separate `Agents` tab, agent roster, or "agents in current Coordinator context" surface that duplicates the board/list fleet view.

#### Scenario: Coordinator Mission history is inline
- **WHEN** multiple Coordinator parent sessions are available in the active workspace
- **THEN** the leading Coordinator rail SHALL present those Coordinator-specific parent sessions as `Missions`
- **AND** it SHALL render the new-Mission row and selectable Mission rows inline rather than behind a Mission popover
- **AND** dormant persisted Missions MAY be grouped behind an archived Mission disclosure within the same rail
- **AND** persisted-only Mission rows SHALL NOT render a redundant per-row `Persisted` badge
- **AND** an expanded archived section SHALL use the rail's flexible scroll area rather than a fixed tiny row cap
- **AND** selecting an existing Mission row SHALL retarget the rail conversation and selected-Mission board scope without creating a new Coordinator runtime.

#### Scenario: Coordinator rail titlebar stays compact
- **WHEN** the leading Coordinator rail renders its top chrome
- **THEN** it SHALL provide an icon-only `New Mission` affordance near the window controls and rail collapse control
- **AND** it SHALL avoid low-value descriptive title text in that top chrome.

#### Scenario: Coordinator rail is collapsed
- **WHEN** the user hides the leading Coordinator rail
- **THEN** the Coordinator view SHALL preserve a slim left-edge affordance for showing the rail again
- **AND** that restore affordance SHALL be independent from Kanban toolbar controls and inspector hide/show controls.

#### Scenario: Sidebars use floating chrome
- **WHEN** the Coordinator rail, collapsed rail restore, right work panel, or inspector side surface renders
- **THEN** the surface SHALL use rounded floating material chrome with subtle border/shadow treatment rather than a hard full-height splitter seam.

#### Scenario: Coordinator rail is not a session proxy
- **WHEN** the Coordinator rail renders the current Coordinator conversation
- **THEN** it SHALL present the conversation as the place where the user talks to the Coordinator
- **AND** it SHALL avoid chrome that frames the Coordinator as an ordinary supervised Agent Mode session, including Coordinator-self `Open in Agent Mode` affordances in the production-demo path.

#### Scenario: Coordinator window title is workspace-scoped
- **WHEN** Coordinator mode is the active main surface
- **THEN** the top-level window title SHALL identify the workspace rather than the active Agent session tab
- **AND** the toolbar peer surface switcher SHALL identify Coordinator mode as the active surface
- **AND** parent/delegate session titles SHALL remain scoped to board/list rows, inspector detail, or explicit Agent Mode deep links.

#### Scenario: Coordinator messages contain Markdown
- **WHEN** Coordinator or event conversation rows contain Markdown structures such as lists, links, inline code, or code fences
- **THEN** the Coordinator rail SHALL render those rows through the shared Agent Mode Markdown rendering substrate where practical
- **AND** the rail SHALL provide enough width for command-log responses to remain readable without excessive wrapping.

#### Scenario: Coordinator action chip is result-derived
- **WHEN** a newly visible supervised delegated row appears for the current Coordinator runtime
- **THEN** the Coordinator rail MAY show a compact delegated action chip derived from that row/result
- **AND** the chip SHALL reread current target-row status and workflow metadata at render time
- **AND** the chip MAY fall back to stored row metadata captured when the delegated action was created if the target row is temporarily unavailable
- **AND** it SHALL NOT claim to represent pending dispatch, collect/review/cancel actions, multi-action batches, or a complete tool-call event stream until a sourced action/activity model exists.

#### Scenario: Coordinator composer matches Agent Mode visual language
- **WHEN** the Coordinator rail renders its scoped composer
- **THEN** it SHALL use a composer surface consistent with Agent Mode's message bar, including a clear text area, compact status/identity strip, and send affordance
- **AND** it SHALL NOT expose Agent Mode model, workflow, broad permission, attachment, child-session mutation, or unrelated context controls unless those controls map to real Coordinator-view behavior.

#### Scenario: Coordinator composer remains draftable while busy
- **WHEN** the Coordinator runtime is connecting, submitting, or rendering a response
- **THEN** the Coordinator composer SHALL keep the text area editable for drafting the next directive when the Coordinator is live in the current window
- **AND** it SHALL gate only the send action until the Coordinator reaches a supported turn boundary.

#### Scenario: Coordinator view first renders
- **WHEN** the Coordinator view first renders
- **THEN** it SHALL show summarized counts, status board columns/cards, Coordinator context when available, and compact MCP awareness
- **AND** it SHALL NOT show full transcripts, full logs, diffs, file viewers, or continuously streaming tool feeds in the main board/list content.

#### Scenario: User selects a row
- **WHEN** the user selects a Coordinator view row
- **THEN** the Coordinator view MAY show a read-only inspector / trailing detail column with sourced status, pending interaction, blocker, worktree/merge, route, MCP, and session metadata summaries
- **AND** it SHALL NOT expose a Coordinator-view-native full raw log, transcript, file viewer, or diff viewer in v1.

#### Scenario: User needs deep detail
- **WHEN** the user needs full transcript, raw log, detailed runtime state, file context, diff context, or action handling
- **THEN** the Coordinator view SHALL route the user to the existing Agent Mode surface.
