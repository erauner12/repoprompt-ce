## Context

RepoPrompt CE already has the raw data needed for Coordinator mode, but the data is split across Agent Mode and MCP status surfaces:

Naming convention for this change: **Coordinator mode** is the peer `.main` surface, and **Coordinator view** is that surface's UI. **Coordinator** / **Coordinator session** is the resolved Agent Mode session shown in the rail and targeted by the composer.

- `AgentSession` persists session identity, provider/model metadata, `parentSessionID`, MCP origin, run state, worktree bindings, and active merge summaries.
- `AgentModeSidebarSessionBuilder` already demonstrates lineage-aware session grouping, status vocabulary, attention state, and calm row presentation.
- `AgentRunMCPSnapshot.Interaction` provides the existing MCP-facing normalized pending interaction shape for live MCP-controlled sessions.
- `MCPServerViewModel.dashboard` exposes MCP connection/tool-call state through an existing MCP subscription lifecycle; the `add-mcp-coordinator-mode-consumer` prerequisite adds the named Coordinator view consumer for this lifecycle.
- `AgentSessionDeepLinkRoute` and `WindowState.routeToAgentSession` already provide the basis for opening existing supervised Agent Mode sessions.
- `openspec/changes/add-coordinator-role/reference/coordinator-runtime-separability.md` shows that the current public run path can support a marked/background `TabSession`-backed Coordinator bridge, but not a fully non-enrolled Coordinator runtime without larger extraction.

The Coordinator view should therefore be a sourced projection over existing state plus one deliberately scoped v1 write path: sending an ordinary user message to a current-window live Coordinator session. It is not a new runtime, protocol, or Agent UI replacement.

For the production-feeling demo, the selected/detected Coordinator may still be backed by existing Agent Mode runtime machinery, but the user-facing surface should treat that backing runtime as a Coordinator actor, not as another supervised fleet session. Delegate/session cards can still deep-link to Agent Mode; the Coordinator rail should feel like the place where the user talks to the Coordinator, not a proxy panel for opening the Coordinator as an ordinary Agent chat.

## Goals / Non-Goals

**Goals:**

- Add a non-default Coordinator mode peer surface inside `.main` while preserving Agent Mode as the configured v1 landing surface.
- Render all Coordinator view regions from one `CoordinatorModeSnapshot` projection.
- Compose that projection from two independent upstream categories: Agent Mode state, including current-window live state plus active-workspace session metadata; and `MCPServerViewModel.dashboard`.
- Scope v1 to active-workspace rows with current-window live-state enrichment.
- Show Coordinator context when selected or detected, keep the board/list workspace useful without a Coordinator, group session cards/rows by total run-state-aware rules, render read-only pending interaction prompts, compact MCP awareness, and deep links from supervised rows/pending summaries to Agent Mode.
- Provide a Coordinator composer only when the selected/detected Coordinator is live in the current window; deliver each directive as an ordinary user message to that Coordinator session.
- Keep Coordinator backing-runtime navigation and enumeration visually separate from supervised Agent Mode session navigation so the demo does not teach users that the Coordinator is one more child card/thread.
- Use coarse observation and diff-before-publish behavior so streaming transcript/token deltas do not churn the Coordinator view.

**Non-Goals:**

- Replacing Agent Mode as the canonical deep-work surface.
- Rendering full transcripts, file viewers, diffs, or full logs in the Coordinator view v1.
- Adding Coordinator-view-side approval/decline/retry actions, card drag/write interactions, cross-window directive routing, structured directive envelopes, or interrupt/steer semantics.
- Inventing a universal `PendingDecision` protocol.
- Parsing assistant prose or session titles to infer meaning.
- Cross-workspace or cross-window aggregation.
- A separate Coordinator-rail agent roster or "agents in Coordinator context" surface in v1; the board/list is the human-facing active-workspace fleet view.
- Objective labels, title-derived workstream chips, PR/check metadata, external MCP error triage, or detailed active-scope visualization in v1.

## Decisions

### 1. Coordinator mode lives inside `.main`

`ContentViewModel.AppRootRoute` remains the binary workspace-entry gate (`.workspaceEntry` vs `.main`). The Coordinator view needs new window-scoped main-surface selection inside `.main`, and `ContentRootShellView.routedContent` should switch between existing Agent Mode and Coordinator mode within the `.main` branch. Once a real workspace is active, the user reaches Coordinator mode through a persistent peer surface switcher for Agent Mode ↔ Coordinator mode; the switcher does not appear in or bypass workspace-entry/onboarding. Because the canonical source-list slot is already occupied by the Agent sidebar or Coordinator chat rail, the switcher should live as a single window-toolbar affordance backed by View-menu commands, not inside either surface's sidebar or rail. It should be a macOS-native peer-surface control, such as a toolbar segmented control or equivalent adaptive switcher, never an iOS-style tab bar. When rendered as the toolbar segment, Coordinator should appear on the left and map to `Command-1`; Agent should appear on the right and map to `Command-2`.

Alternatives considered:

- **New `AppRootRoute` peer:** rejected because it would bypass existing workspace-entry gating and disturb current default behavior.
- **MCP status sheet expansion:** rejected because Coordinator mode supervises Agent sessions and uses MCP as one input, not the other way around.

### 2. Agent Mode remains default

The default `.main` surface remains Agent Mode in v1. Treat this as the configured landing surface, not a permanent hard-coded product truth, so a future control-plane release can choose Coordinator mode as the landing surface without replacing the routing seam. `AppLaunchConfiguration.forcedRootRoute == .main` should continue to land on Agent Mode unless a future forced-surface test knob is added. User surface selection is sticky per window while the window is alive; `@SceneStorage` or equivalent scene-level state is the likely implementation mechanism. Coordinator selection remains keyed by active workspace.

### 3. One render projection, two upstreams

This change depends on `add-mcp-coordinator-mode-consumer` for the named MCP Coordinator mode consumer identity. Coordinator mode SHALL render from `CoordinatorModeSnapshot`. That snapshot is one UI consistency boundary, but it is composed from independent upstreams:

1. current-window Agent Mode live state overlaid on active-workspace session metadata;
2. `MCPServerViewModel.dashboard` with its existing MCP consumer lifecycle.

This avoids each UI component re-deriving counts, groups, pending decisions, and deep links from different sources while preserving the existing MCP data path.

### 4. Snapshot owner is reactive but coarse

A lazily-created `@MainActor` Coordinator view model should observe coarse signals only: run-state transitions, pending-interaction presence, lineage/session metadata changes, worktree/merge attention, and MCP state changes. It should not republish on streaming assistant deltas, token deltas, or raw transcript churn. Existing sidebar/content-fingerprint patterns are the precedent.

### 5. Coordinator identity uses precedence

Coordinator identity is not a flat set of OR predicates. Selection precedence is:

1. user-selected Coordinator session, if present and valid;
2. auto-detected parent whose launch/first request workflow is `Orchestrate`;
3. auto-detected parent that is both a lineage root with children and `isMCPOriginated == true`;
4. no Coordinator selected/found.

Plain lineage-root-with-children is never enough to auto-detect a Coordinator. User-selected Coordinator state lives in the window-scoped Coordinator view model, keyed by active workspace ID, and does not persist across app launches in v1.

### 6. Active workspace rows, current-window live enrichment

V1 projects active-workspace sessions. Live run-state enrichment is current-window scoped. Sessions without current-window live state render from persisted metadata only and are marked stale/persisted-only. Persisted-only rows never count toward live `Needs you` or `Working` groups in v1. Rows without a resolvable route hide or disable Agent UI navigation.

### 7. Labels are structured and conservative

Workflow labels are read-only display metadata in the production-demo path. The projector accepts a flat `WorkflowDisplaySummary` derived from real `AgentWorkflowDefinition` metadata (`id`, display name, SF Symbol, optional accent), not a Coordinator-only toy enum. Live rows derive the summary from the latest user-turn workflow already held in the Agent Mode transcript model, so a workflow chip can appear, change, or clear between turns without scanning transcripts per row. The label does not change grouping, sorting, filtering, action creation, or model/tool/policy selection.

Action-chip workflow labels are render-time lookups from the current target row. The chip stores the delegated target session ID and verb/phase; the view rereads the row's current workflow/status metadata, so a later follow-up without a workflow clears the workflow affordance instead of leaving stale context on the chip.

Objective labels are deferred. Workstream chips may optionally render from worktree binding/logical-root metadata when present and useful for the UI; otherwise omit them. Session-title parsing is out of scope.

### 8. Pending interactions are read-only and MCP-scoped in v1

V1 `Needs you` grouping is driven primarily by structured run state: `.waitingForUser`, `.waitingForQuestion`, and `.waitingForApproval`. The pending-scope decision for v1 is MCP-only prompt/detail enrichment: live MCP-controlled sessions may additionally provide normalized `AgentRunMCPSnapshot.Interaction` content, but MCP interaction presence is not the only attention gate. A broader non-MCP pending projection is a follow-up Agent Mode contract change, not part of this Coordinator view core. Coordinator Mode pending summaries carry render data plus an optional route, not executable actions:

```swift
struct CoordinatorModePendingInteractionSummary {
    let id: UUID
    let kind: AgentRunMCPSnapshot.Interaction.Kind
    let title: String?
    let prompt: String?
    let details: [AgentRunMCPSnapshot.Interaction.Detail]
    let openAgentChatRoute: AgentSessionDeepLinkRoute?
}
```

If `openAgentChatRoute` is nil, the Coordinator view hides or disables `Open agent chat` / `Decide`. Coordinator-view-side responses remain follow-ups. Coordinator directives are limited to the current-window composer defined below.

### 9. Deep links use existing Agent UI routing

When route data is resolvable, Coordinator view rows and pending summaries use `AgentSessionDeepLinkRoute` or direct same-window `WindowState.routeToAgentSession`. A route requires active workspace context, a resolvable tab, and an optional session ID when available. `AgentSessionMeta` is not a self-contained route payload because it does not carry `workspaceID`; v1 route construction uses the active workspace context for `workspaceID` and metadata for tab/session identifiers when present.

### 10. MCP awareness is compact

Consume the `MCPServerViewModel.DashboardConsumer.coordinatorMode` case added by `add-mcp-coordinator-mode-consumer`. The Coordinator view subscribes while visible and shows compact connected/idle/off client count, recent tool calls, and active/in-flight call count. Agent rows are active-workspace scoped, but the MCP footer is server/window scoped; it may include clients or calls not tied to the visible row list. External error triage, detailed attribution, and active-scope visualization are follow-ups.

### 11. Status grouping is total and precedence-based

Status groups are evaluated top-down: `Needs you` > `Blocked` > `Working` > `Done` > `Idle`.

- `Needs you`: current-window live run state is `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`; MCP pending interaction data enriches prompt/details when available.
- `Blocked`: current-window live run state is `.failed` or current-window live metadata reports conflicted worktree/merge attention.
- `Working`: current-window live run state is `.running`.
- `Done`: run state is `.completed` or `.cancelled`.
- `Idle`: run state is `.idle` or no higher-priority group applies.

Blocked's conflicted-merge signal should come from cheap metadata such as active worktree merge summaries, but only for current-window live rows. V1 sorting is read-only display order within existing groups: `Last updated` is the default, with `Name` and `Priority` as additional sort modes. Sorting applies to both board cards and list rows, should use cheap metadata, e.g. attention age, structured priority/attention data, display name, or activity/last-modified dates, and must not require transcript loads. Sorting must not change group membership, card/row state, Coordinator relationship, or persisted session state. Persisted-only cards/rows may still appear as `Done` or `Idle` from persisted metadata, but persisted-only failed/conflicted metadata renders as stale/persisted-only instead of contributing to live Blocked counts or the `Blocked` group. Persisted-only rows must not contribute to live `Needs you`, `Blocked`, or `Working` counts and should render with a stale/persisted-only visual treatment instead of live actionable styling.

### 12. Coordinator rail is optional; board/list workspace stands alone

The v1 Coordinator view is board-first, with List as an alternate and narrow-width fallback. If no Coordinator is selected or detected, the Coordinator view still renders the grouped active-workspace board or list and shows an empty/choose-Coordinator state in the rail area. If multiple auto-detected Coordinator candidates exist, v1 picks the most recent candidate within the highest-ranked matching precedence tier until the user selects a different per-window, workspace-keyed Coordinator. The Coordinator/session rail is in-surface Coordinator view navigation for Coordinator identity/selection, optional context, and the scoped Coordinator composer, not the app-level Agent Mode ↔ Coordinator mode surface switcher; it should not contain Agent Mode as a rail item, and it should not host a separate by-agent roster of workspace sessions in v1.

### 13. Coordinator composer is the only v1 Coordinator view write path

The v1 Coordinator composer is enabled only when the selected/detected Coordinator is live in the current window, using the same current-window liveness predicate as Coordinator view live enrichment. If no Coordinator is selected/detected, or if the Coordinator is persisted-only or owned by another window, the composer is disabled and the rail should provide an `Open agent chat` affordance when route data is available.

A v1 directive is an ordinary user message delivered to the Coordinator session through the existing Agent Mode message path. V1 does not define a structured directive envelope, cross-window directive routing, Coordinator-view-side interrupt/steer semantics, or direct mutation of child sessions. The composer may echo the user's sent directive into the rail transcript; Coordinator responses and child-session effects surface through normal coarse Coordinator view snapshot refresh rather than a live token stream in the rail. Clear Chat is a rail display reset only: it must not delete, truncate, or rewrite the underlying Coordinator session transcript, which persists and archives through the existing Agent Mode session lifecycle. If the Coordinator is mid-run, v1 may queue the directive as the next turn or disable send; it must not implement Coordinator-view-side interrupt or steering.

### 13A. Production demo bridge hides Coordinator backing-session chrome

The production-feeling demo may still deliver directives through a selected, auto-detected, or marked/background Agent `TabSession` while the real Coordinator role work lands. That runtime is an implementation bridge. The Coordinator rail should not expose `Open in Agent Mode` for the Coordinator itself once the rail is acting as the primary Coordinator conversation surface.

Agent Mode deep links remain available for supervised delegate rows, pending summaries, and detail that belongs in Agent Mode. They should not be used to invite the user to inspect or drive the Coordinator backing runtime as if it were part of the supervised fleet. When a first-class Coordinator marker exists, the backing runtime should be excluded at the shared enumeration boundary used by Coordinator mode groups, Agent Mode sidebar/session lists, and MCP session-list surfaces. Before that marker exists, local Coordinator-rail suppression is an acceptable demo bridge, but it must be treated as temporary presentation behavior rather than final architecture.

Coordinator housekeeping children are also distinct from supervised work. The automatic loopback proof has been retired from the default production-demo prompt because real delegated sessions now exercise the same `agent_run.start` path directly. If future Coordinator housekeeping sessions are needed, they should be stamped with an explicit internal Coordinator marker at creation time and excluded from both board/list fleet rows and Coordinator action chips. The implementation must not infer internal housekeeping from session titles. In the demo this marker can remain in-memory like the demo Coordinator runtime marker; the production architecture should replace it with durable containment/activity metadata.

Coordinator action chips are currently board/result-derived, not true tool-call-event-derived. They provide a readable "delegated" cue when a new supervised child row appears, but they do not yet model pending dispatch, collect/review/cancel actions, multi-action batches, or a general action/event stream. That future stream should feed chips and board rows from the same sourced activity model.

Window-level chrome should follow the same rule. When Coordinator mode is the active main surface, the window title should remain workspace-scoped rather than borrowing the active Agent session tab title; the toolbar peer surface switcher identifies the active Coordinator surface. Parent/delegate session titles belong in board/list rows, inspector detail, or explicit Agent Mode deep links, not in the top-level Coordinator window title.

The rail conversation should also be wide and rich enough to read as a first-class command log. Coordinator responses may contain bullets, links, code fences, and inline code, so production-demo rows should reuse the same Markdown rendering substrate used by Agent Mode assistant messages instead of presenting raw Markdown as plain wrapped text.

The Coordinator composer should share Agent Mode's composer visual vocabulary without exposing Agent Mode's normal agent-session controls. It may use a rounded command surface, separated text area, compact status/identity strip, and send affordance, but it should not add model, workflow, tool, permission, attachment, or context controls until those controls represent real Coordinator-view behavior.

### 13B. Demo fleet scope must become one-to-many

The remaining demo constraint is the singleton Coordinator runtime. Today the bridge treats `isCoordinatorRuntimeDemo` as "the current Coordinator," projects the board from that one runtime's descendants, and lets the "new Coordinator" path clear the marker so a later directive starts from an empty board. That behavior is useful for reproducibility, but it undercuts the Coordinator story because a control-plane surface should be able to supervise multiple parent tasks without pretending each fresh conversation invalidates the previous fleet.

The production-demo path should split three concepts that are currently bundled together:

1. **Coordinator runtime set**: all marked Coordinator backing runtimes that belong to the current workspace-scoped demo fleet.
2. **Selected Coordinator runtime**: the single runtime whose conversation is shown in the left rail and addressed by the composer.
3. **Fleet reset/retirement**: an explicit operation that removes one runtime or clears the whole fleet, separate from starting another Coordinator conversation.

In the near-term demo, the runtime set can remain an in-memory workspace-scoped registry, just like the existing marker. `New Coordinator` should create an additional Coordinator runtime and select it for the rail; it should not unmark previous Coordinator runtimes or discard their delegated descendants from the board. `Clear Chat` should remain a rail display reset and must not clear the fleet. If a destructive reset is needed for demos, it should be explicit, e.g. `Retire Coordinator` for the selected runtime or `Reset Fleet` for the whole workspace-scoped demo fleet.

The board/list migration should be sequenced in two visible checkpoints so runtime identity and aggregate projection bugs do not blur together:

1. **Selected-runtime board checkpoint**: multiple Coordinator runtimes can coexist, the rail targets the selected runtime, and the board/list shows that selected runtime's delegated descendants. Switching the selected Coordinator swaps the board. This proves runtime identity, selection, and name-fallback removal before aggregate projection changes.
2. **Aggregate fleet board checkpoint**: board/list rows come from all eligible active-workspace Coordinator fleet roots, excluding Coordinator backing runtimes and explicitly marked Coordinator-internal housekeeping sessions. Switching the selected Coordinator changes the rail target, while the board remains the aggregate fleet view.

Aggregate mode must make parent ownership visible, not merely retained in hidden metadata. Otherwise the board demonstrates "many cards" but not "multiple parents managed without confusion." Cards and rows should render a sourced parent indicator using a reserved neutral treatment distinct from lifecycle state color and workflow badges. The indicator can be a compact label or short parent identifier; it should avoid adding another competing status color. When a parent is selected in the rail while the aggregate board is shown, that selected parent's delegated rows should receive subtle emphasis so the user's active conversation and the board remain visually connected.

This change preserves the rail's "talk to one Coordinator" model while letting the center board demonstrate the actual control-plane value: multiple parent tasks, launched sequentially or in parallel, can remain visible, attributed to their owning parent, and independently progress across `Needs you`, `Working`, `Blocked`, `Review`, and `Done`.

### 14. Inspector stays sourced; full logs stay in Agent Mode

The v1 inspector / trailing detail column shows sourced summaries only: status, pending interaction, blocker, worktree/merge, route, and MCP/session metadata. Full transcript, raw log, file, and diff inspection remain in Agent Mode via `Open agent chat`. A Coordinator-view-native full-log toggle is a follow-up unless backed by a sourced activity projection.

### 15. Board-first v1 keeps List as alternate and fallback

The v1 surface defaults to a read-only status board. List remains a first-class alternate view and the responsive fallback when board columns cannot fit. Board and List render the same `CoordinatorModeSnapshot`, grouping, sorting, stale-row semantics, route availability, and read-only card/row action constraints. High-priority columns (`Needs you`, `Blocked`, `Working`) should be visible by default when non-empty; lower-priority columns (`Done`, `Idle`) remain available but may be de-emphasized, horizontally scrolled, or collapsed with visible counts when space is constrained. The board is the protected region: the inspector / trailing detail column should collapse first, then Coordinator chat may collapse to a rail, while board columns preserve a usable minimum width and may scroll horizontally. Below the width where two board columns can fit, the board falls back to List rather than rendering a cramped board. Drag ordering, dispatch, status changes, inline approvals/retries, structured directives, cross-window directives, and interrupt/steer semantics remain Layer 2/3 follow-ups.

## Risks / Trade-offs

- **Coordinator ambiguity** → Use precedence rules, most-recent auto-candidate fallback, and per-window user override instead of guessing from plain lineage.
- **Multi-window stale rows** → Render stale/persisted-only state explicitly; keep live `Needs you` / `Working` counts current-window-only.
- **Reactive firehose** → Observe coarse signals and diff snapshots before publishing.
- **Workflow lookup cost** → Keep workflow display on cheap live request-anchor metadata; if persisted/off-window workflow labels are needed later, add index metadata or a shared cached lookup rather than loading transcripts per UI region.
- **Pending decision asymmetry** → Run-state waiting values still enter `Needs you`; MCP-controlled live interactions only enrich the prompt/detail payload.
- **Route gaps** → Store nullable routes on rows/summaries and hide navigation when route prerequisites are missing.

## Migration Plan

1. Add Coordinator mode artifacts behind a non-default in-`.main` peer surface while Agent Mode remains the configured v1 landing surface.
2. Build snapshot projection and tests before wiring the Coordinator composer.
3. Add UI shell and deep links after snapshot behavior is stable.
4. Consume the MCP Coordinator mode consumer added by `add-mcp-coordinator-mode-consumer` after compact MCP projection tests are in place.
5. Defer Coordinator-view-side approval/retry actions, drag/dispatch/status mutations, structured directive transport, cross-window directives, objective labels, and cross-window/cross-workspace aggregation.

Rollback is simple for v1: remove or hide the Coordinator mode entry point; Agent Mode remains the default and canonical surface.

## Open Questions

- Should a future workflow label pass add workflow metadata to the session index, or load request-anchor/transcript metadata on demand?
- Should a future Coordinator view support cross-window live ownership or route-to-owning-window behavior instead of stale/persisted-only rows?
- Should PR/check metadata wait until a separate activity/event adapter exists?
