## ADDED Requirements

### Requirement: User-facing Director and technical Coordinator split
The system SHALL use Director as the user-facing supervisory actor while keeping the current technical Coordinator contracts stable.

#### Scenario: User-facing copy names the Director
- **WHEN** the app presents Mission supervision, policy, decisions, evidence, receipts, the rail, or other user-facing Coordinator-mode surfaces
- **THEN** product copy SHOULD use Director vocabulary
- **AND** it SHOULD avoid presenting Coordinator as the product actor except in technical/debug contexts.

#### Scenario: Technical contracts remain Coordinator-named
- **WHEN** Swift symbols, MCP operation names, Codable keys, persisted records, fixtures, or debug payloads represent this runtime
- **THEN** they SHALL keep Coordinator naming for this change
- **AND** a full Coordinator-to-Director technical rename SHALL be a separate no-behavior migration.

#### Scenario: Shortcut and surface order remain explicit product decisions
- **WHEN** Director user-facing copy is introduced
- **THEN** it SHALL NOT silently flip main-surface shortcut order or routing behavior
- **AND** any shortcut/order change SHALL be recorded as a separate OpenSpec-backed product decision.

### Requirement: Coordinator mode surface entry
The system SHALL provide a non-default Coordinator mode peer surface inside the existing `.main` app experience.

#### Scenario: Agent Mode remains default
- **WHEN** a user opens the app into the `.main` route
- **THEN** the system SHALL show the existing Agent Mode surface by default in v1
- **AND** the default SHALL remain a configurable product decision rather than a hard-coded permanent constraint.

#### Scenario: Workspace entry remains unchanged
- **WHEN** the app is in workspace-entry routing
- **THEN** Coordinator mode SHALL NOT bypass existing workspace-entry gating
- **AND** the Agent Mode / Coordinator mode switcher SHALL NOT appear until a real workspace is active.

#### Scenario: Coordinator mode entry point is a peer surface switcher
- **WHEN** a real workspace is active and the app is in `.main`
- **THEN** the system SHALL provide a persistent top-level affordance for switching between Agent Mode and Coordinator mode
- **AND** the affordance SHALL use a macOS-native peer-surface control, such as a toolbar segmented control or equivalent adaptive surface switcher
- **AND** the visible affordance SHALL occupy one shared toolbar location across both surfaces rather than living inside either surface's sidebar or rail
- **AND** the same surface choices SHALL be reachable from the View menu with live checked state and keyboard shortcuts.

#### Scenario: Main surface selection is window-sticky
- **WHEN** a user switches between Agent Mode and Coordinator mode in a window
- **THEN** that window SHALL retain the selected main surface while it remains alive
- **AND** Coordinator selection state SHALL remain scoped separately by active workspace.

### Requirement: Coordinator view snapshot projection
The system SHALL render Coordinator mode from a single Coordinator-view-facing snapshot projection.

#### Scenario: Coordinator view renders from one projection
- **WHEN** Coordinator mode renders top counts, groups, rows, pending prompts, Coordinator rail, compact MCP awareness, deep-link affordances, board columns, list rows, or inspector detail
- **THEN** those regions SHALL derive displayed state from the same `CoordinatorModeSnapshot` projection.

#### Scenario: Projection composes independent upstreams
- **WHEN** MCP Coordinator mode state and Agent Mode session state are both available
- **THEN** the snapshot SHALL compose both sources without routing MCP Coordinator mode data through Agent Mode as synthetic agent state.

#### Scenario: Snapshot avoids streaming churn
- **WHEN** assistant text, transcript tokens, or token counts stream without changing coarse Coordinator view state
- **THEN** the Coordinator view snapshot SHALL NOT republish changed rows solely because of those streaming deltas.

#### Scenario: Active workspace scope is honored
- **WHEN** Coordinator mode opens in a workspace
- **THEN** rows SHALL be considered from the active workspace
- **AND** sessions with only off-window or persisted metadata SHALL be rendered as stale/persisted-only rather than live actionable rows.

### Requirement: Coordinator rail and Mission selection
The system SHALL keep the selected Coordinator conversation distinct from the supervised fleet projection.

#### Scenario: User-selected Coordinator exists
- **WHEN** the user has selected a valid Coordinator session for the active workspace in the current window
- **THEN** Coordinator mode SHALL use that session ahead of auto-detected candidates.

#### Scenario: Multiple Coordinator parents can be selected
- **WHEN** multiple valid Coordinator parent runtimes exist for the active workspace
- **THEN** Coordinator mode SHALL expose visible in-rail Mission selection for returning to an existing parent
- **AND** selecting a parent SHALL retarget the Coordinator rail conversation without creating a new Coordinator runtime
- **AND** selected-Mission board/list projection SHALL update to that selected parent's eligible delegated descendants.

#### Scenario: Coordinator rail avoids duplicate fleet views
- **WHEN** the Coordinator rail renders in v1
- **THEN** it SHALL focus on Coordinator identity, Mission selection/history, optional context, and the scoped Coordinator composer
- **AND** it SHALL NOT provide a separate agent roster or duplicate fleet view that competes with the board/list.

#### Scenario: Rail transcript is display state
- **WHEN** the user clears the Coordinator rail chat display
- **THEN** only the rail display state SHALL be cleared
- **AND** the underlying Coordinator session transcript, Mission state, delegated descendants, and fleet membership SHALL NOT be deleted, truncated, or rewritten.

#### Scenario: Coordinator rail is not an Agent session proxy
- **WHEN** the rail renders the current Coordinator conversation
- **THEN** it SHALL present that conversation as the place where the user talks to the Director/Coordinator
- **AND** it SHALL avoid Coordinator-self `Open in Agent Mode` affordances in the production-demo path while preserving deep links for delegated rows.

### Requirement: Coordinator fleet and row projection
The system SHALL project supervised delegated work from structured lineage, Mission, session, workflow, and worktree state.

#### Scenario: Selected Mission projection stays coherent
- **WHEN** the selected Mission has projected delegated descendants
- **THEN** the selected-Mission board and list SHALL render the same delegated rows counted by the selected Mission history entry
- **AND** delegated event cards SHALL resolve workflow badges and lifecycle status from those same rows.

#### Scenario: Board projects aggregate supervised fleet
- **WHEN** the active workspace demo fleet has multiple Coordinator runtime roots with supervised delegated descendants
- **THEN** board and list projections MAY include eligible delegated descendants from all active fleet roots
- **AND** they SHALL exclude Coordinator backing runtimes and explicitly marked Coordinator-internal housekeeping sessions
- **AND** delegated descendants MAY include read-only probe descendants that are not immediate children of a Coordinator root.

#### Scenario: Delegated row keeps owner attribution
- **WHEN** a delegated row is projected from an aggregate fleet
- **THEN** row projection SHALL retain sourced immediate parent metadata and resolved owner Coordinator metadata
- **AND** owner Coordinator metadata SHALL be resolved from structured lineage rather than row titles or assistant prose.

#### Scenario: Session row renders from structured data
- **WHEN** a session appears as a Coordinator view card or list row
- **THEN** the card or row SHALL derive identity, lineage, provider/model, workflow metadata, worktree state, MCP origin, run status, and routeability from structured session metadata or live state
- **AND** workflow and workstream labels SHALL be read-only projection metadata that do not affect runtime behavior.

#### Scenario: Declared Mission workstream supplements row state
- **WHEN** a Coordinator Mission Plan declares a workstream that references a projected row's child session ID
- **THEN** the row MAY retain the declared Mission workstream as supplemental metadata
- **AND** sourced lifecycle state, workflow metadata, routeability, and worktree identity from the actual child session SHALL remain authoritative for row grouping and actions.

### Requirement: Board, list, status grouping, and sorting
The system SHALL present the v1 Coordinator work surface as a read-only status board with a list fallback.

#### Scenario: Coordinator view first opens
- **WHEN** the user opens Coordinator mode in v1
- **THEN** the view SHALL show a board by default
- **AND** status groups SHALL render as board columns containing session cards
- **AND** the board SHALL derive columns and cards from the same snapshot grouping and row projection used by the list, rail, and inspector.

#### Scenario: Selected-Mission board keeps stable lanes
- **WHEN** the selected-Mission board renders
- **THEN** it SHALL keep `Needs you`, `Working`, and `Done` visible as stable default lanes even when empty
- **AND** it SHOULD omit empty `Blocked` and `Review` lanes until those statuses contain rows.

#### Scenario: User switches to list view or board cannot fit
- **WHEN** the user chooses List view or the viewport cannot fit at least two usable board columns
- **THEN** Coordinator mode SHALL render the same sourced rows and status groups in a list presentation
- **AND** the list SHALL preserve grouping, sorting, stale-row, deep-link, and read-only action constraints.

#### Scenario: Board remains read-only in v1
- **WHEN** the v1 board renders session cards
- **THEN** it SHALL NOT provide drag-to-reorder, drag-to-dispatch, drag-to-change-status, inline child-session approval, inline retry, or direct child-session mutation
- **AND** Coordinator continuation approval SHALL be surfaced through the Coordinator chat as a visible message.

#### Scenario: Group precedence is evaluated
- **WHEN** a row has signals matching more than one group
- **THEN** Coordinator mode SHALL evaluate groups in this order: `Needs you`, `Blocked`, `Working`, `Review`, `Done`, `Idle`.

#### Scenario: Needs-you grouping uses live user-attention state
- **WHEN** a current-window live session has `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`
- **THEN** the row SHALL group under `Needs you`
- **AND** live MCP-controlled pending interaction data MAY enrich the row prompt/details when available.

#### Scenario: childAsk auto suppresses user-facing pending child rows
- **WHEN** a selected-Mission child interaction is pending and effective `childAsk` resolves to Auto
- **THEN** that pending child interaction SHALL be presentation-suppressed from the user Needs-you queue/lane
- **AND** the bound row SHALL remain in Working or another non-user-attention presentation state while the Director route is active
- **AND** runtime completion still SHALL satisfy the ledger requirements defined by the trust-invariants capability.

#### Scenario: Stale persisted rows are not live attention
- **WHEN** a card or row is known only from persisted metadata and has no current-window live state
- **THEN** Coordinator mode SHALL visually mark it stale/persisted-only
- **AND** it SHALL NOT count active-looking stale run state as live `Working`, `Needs you`, or `Blocked` contribution.

#### Scenario: Sort controls are read-only
- **WHEN** a user selects `Last updated`, `Name`, or `Priority` sorting
- **THEN** Coordinator mode SHALL reorder cards or rows only within their existing status groups
- **AND** it SHALL NOT change a row's group, run state, pending state, Coordinator relationship, or persisted session state.

### Requirement: Coordinator composer and Mission template surface
The system SHALL provide a scoped Coordinator composer as the only v1 Coordinator-mode write path.

#### Scenario: Coordinator is live in the current window
- **WHEN** a Coordinator is selected or detected and has current-window live state
- **THEN** the Coordinator view SHALL enable a Coordinator composer in the Coordinator rail.

#### Scenario: Coordinator is not reachable from the current window
- **WHEN** no Coordinator is selected or detected, or the resolved Coordinator is persisted-only or owned by another window
- **THEN** Coordinator mode SHALL disable the composer or replace it with a route affordance when route data is available
- **AND** it SHALL NOT restore, steal, or create a session solely to enable the composer.

#### Scenario: User sends a Coordinator directive
- **WHEN** the user submits text through the enabled Coordinator composer
- **THEN** Coordinator mode SHALL deliver that text as an ordinary user message to the Coordinator session or as the equivalent external `coordinator_chat` submit path
- **AND** it SHALL NOT directly mutate child session state, dispatch cards, approve pending interactions, retry sessions, or change board/list status groups.

#### Scenario: Mission Template starts a new Mission
- **WHEN** the user selects a Coordinator Mission Template while composing a fresh Mission
- **THEN** the Coordinator view SHALL send template-wrapped guidance to the Coordinator runtime while preserving the user's raw visible Mission text in the rail and objective summary
- **AND** selected-template metadata SHALL remain distinct from Mission Policy and Agent workflow metadata.

#### Scenario: Existing Mission follow-up ignores Mission Template selection
- **WHEN** the user sends an ordinary follow-up to an existing Coordinator Mission
- **THEN** the Coordinator view SHALL send the raw visible follow-up text without applying Mission Template wrapping
- **AND** Mission Templates SHALL NOT behave as general follow-up macros.

#### Scenario: Composer keeps Agent Mode visual language
- **WHEN** the Coordinator rail renders its scoped composer
- **THEN** it SHALL use a composer surface consistent with Agent Mode's message bar
- **AND** it SHALL NOT expose Agent Mode model, workflow, broad permission, attachment, child-session mutation, or unrelated context controls unless those controls map to real Coordinator-view behavior.

### Requirement: Pending interaction and deep-link affordances
The system SHALL route pending interactions and row detail through existing Agent Mode or selected-Mission child paths without inventing unsourced decisions.

#### Scenario: Pending interaction is available
- **WHEN** a live MCP-controlled session has an interaction that can be projected into the Coordinator view snapshot
- **THEN** Coordinator mode SHALL render a read-only pending interaction summary with kind, title, prompt, details, and optional Agent UI route.

#### Scenario: Selected-Mission child checkpoint is bridged into Coordinator chat
- **WHEN** a delegated child session owned by the selected Mission has a live pending interaction and `childAsk` resolves to Ask
- **THEN** the selected-Mission board SHALL classify that child under `Needs you`
- **AND** the Coordinator chat composer MAY show structured fields, option labels, option descriptions, custom-answer affordance, skip controls, and validation for that child interaction
- **AND** submitting the answer SHALL forward structured answers or text fallback to the child pending interaction path.

#### Scenario: User responds outside selected-Mission child checkpoint
- **WHEN** a user chooses to respond to a pending interaction that is not bridged into the selected Mission child path
- **THEN** Coordinator mode SHALL route the user to the existing Agent Mode session when route data is available
- **AND** it SHALL NOT execute approval, decline, retry, reassign, or unrelated directive actions in v1.

#### Scenario: Deep link is resolvable
- **WHEN** a Coordinator view row has active workspace context, a resolvable tab, and optional session ID
- **THEN** Coordinator mode SHALL provide an `Open agent chat` affordance that opens the existing Agent Mode session.

#### Scenario: Deep link is not resolvable
- **WHEN** a row lacks required route data or is persisted-only without a resolvable tab
- **THEN** Coordinator mode SHALL show the row without trying to create or restore a session as part of rendering.

#### Scenario: Assistant prose mentions a decision
- **WHEN** assistant text contains words that appear to request a user decision
- **THEN** Coordinator mode SHALL NOT classify it as a pending interaction unless structured pending state exists.

### Requirement: Compact MCP awareness and progressive disclosure
The system SHALL keep Coordinator mode calm by default while exposing sourced detail through deliberate actions.

#### Scenario: Coordinator view is visible
- **WHEN** Coordinator mode is visible
- **THEN** it SHALL subscribe to Coordinator-view-specific MCP update consumption and show compact client/in-flight/recent-call awareness in stable board chrome.

#### Scenario: Coordinator view is hidden
- **WHEN** Coordinator mode is not visible
- **THEN** it SHALL stop Coordinator-view-specific MCP update consumption.

#### Scenario: User needs deep detail
- **WHEN** the user needs full transcript, raw log, detailed runtime state, file context, diff context, or action handling
- **THEN** Coordinator mode SHALL route the user to the existing Agent Mode surface rather than embedding those full-detail surfaces in v1.

#### Scenario: Receipt and terminal copy use Mission projection
- **WHEN** a completed or stopped Mission is shown in Coordinator mode
- **THEN** terminal copy, status pills, receipt affordances, and summary cards SHALL render from Mission-owned state
- **AND** they SHALL avoid implying human acceptance, merge, commit, push, or deployment merely because delegated work is Done.
