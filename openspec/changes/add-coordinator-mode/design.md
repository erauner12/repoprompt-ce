## Context

RepoPrompt CE already has the raw data needed for Coordinator mode, but the data is split across Agent Mode and MCP status surfaces:

Naming convention for this change: **Director** is the user-facing supervisory actor and Command Center surface vocabulary. **Coordinator mode** remains the peer `.main` surface name in technical docs/code for this change, and **Coordinator view** is that surface's UI. **Coordinator** / **Coordinator session** is the resolved Agent Mode session shown in the rail and targeted by the composer. Swift symbols, MCP operation names, Codable keys, and existing debug payloads stay Coordinator-named until a separate no-behavior rename pass.

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
- Keep Coordinator backing-runtime navigation and enumeration visually separate from supervised Agent Mode session navigation so the demo does not teach users that the Coordinator is one more child card/thread. In Coordinator mode, user-facing Coordinator-specific parent sessions are called `Missions` even though they remain backed by persisted `AgentSession` records.
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

### 0A. Director is the user-facing actor; Coordinator remains the technical contract

The Command Center cutline uses Director for visible product copy: rail/conversation labels, Mission Policy, decision/evidence summaries, and receipt surfaces should read as the user talking to and auditing a Director. Coordinator remains the technical contract name in this change because Swift symbols, MCP operation names such as `coordinator_chat`, persisted Codable keys, and existing fixtures are already shipped through multiple seams. A full symbol/API/key rename is intentionally deferred to a separate no-behavior migration so product vocabulary can move without destabilizing runtime and persistence contracts.

This also means the shortcut flip is deferred. User-facing Director wording should not silently change current main-surface ordering or keyboard behavior; if the product decides Director should become `Command-1`, that requires an explicit follow-up OpenSpec/UI pass.

### 0B. Mission Policy and autonomy are Mission-owned trust guidance

Mission Policy is separate from Mission Templates. Templates remain prompt wrappers and topology instructions for fresh Mission starts. Policies are trust/settings/guidance snapshots attached to a Mission: stable policy ID/name, default pace, a string-keyed autonomy map, optional Definition of Done, optional standing guidance, and pinned skills/context IDs. Built-ins for the first pass are Default, Hands-off, Careful writes, and Read-only.

The autonomy map shares its string key space with decision classes. Known v1 classes are `plan`, `advance`, `writes`, `childAsk`, `recover`, and `irreversible`; unknown classes round-trip but resolve to Ask. This keeps the ledger foundation open to future classes without accidentally granting autonomy.

### 0C. Decision/evidence ledgers are append-only Mission state

The Mission Plan becomes the durable home for shape summary, policy snapshot, autonomy, decision ledger, evidence ledger, and receipt inputs. All fields are additive/defaulted so old Missions decode. The receipt is a projection from Mission-owned contract, decision, evidence, and close data; rendered receipt markdown is not a persisted source of truth.

Decision ledger records use one record type for user and director decisions. Each record carries a stable ID, string decision class, actor, label, optional reason, timestamp, and references such as node/session/interaction/checkpoint ID. Evidence records are also Mission-owned and distinguish at least meeting evidence from short verdicts, with node/session refs when available.

Ledger merge semantics are deliberately conservative: decision and evidence arrays are append-only; omitted `mission_plan` fields preserve prior values; and dedupe is by record `id` only. There is no replace flag for v1 ledger arrays. This allows app/MCP-submit and runtime writers to operate concurrently without one replacing the other's records.

User-actor decision IDs are deterministic UUIDs derived from `(checkpointInstanceID, label)` using the existing stable-fingerprint style. The checkpoint instance must be instance-specific: plan approval includes `plan.revision`, while follow-through and child-answer checkpoints use their existing unique event/interaction IDs. Retried submits for the same checkpoint instance and label dedupe; revise-then-approve at the same checkpoint instance produces two labels and therefore two records.

### 0D. Actor-split writers keep responsibility clear

Each actor records its own decisions. The app records user-actor decisions at checkpoint choke points through the existing Mission Plan update seam: plan approval, requested plan revision, step continuation/follow-through, child-answer submit, and Mission stop. External MCP `op=submit` is also a user action when it resolves the same checkpoint, so the MCP submit path records the same user-actor decision with the same deterministic ID scheme before or alongside forwarding the submit.

The runtime records director-actor decisions and all evidence through `coordinator_chat op="mission_plan"`. Continuation directives and mirrored compact checkpoint action payloads must explicitly tell the runtime to append director decisions and evidence only. They must not instruct the runtime to re-record user decisions already written by app/MCP submit.

### 0E. MCP ledger serialization and waiting extend existing coordinator_chat

The existing `coordinator_chat` surface remains the demo/control API. `mission_plan` partial updates grow additive fields for shape, policy snapshot, autonomy map, appended decisions, and appended evidence while preserving compatibility with old objective/workstream/node/routing/event payloads. `mission_status` becomes receipt-ready: shape, policy, autonomy summary, decision counts by actor, evidence counts, recent ledger entries, and a compact receipt summary are serialized without mutating state.

`wait_for_update` depends on the compact Mission status fingerprint, so the hand-rolled fingerprint must include every ledger/status field that can unblock a waiter. A decision or evidence append must advance the compact fingerprint; otherwise external clients can hang even though Mission state changed.

Ledger-visible fields also need to move the Coordinator/Director snapshot when projected. The preferred implementation path is to keep Mission Plan equality/fingerprinting ledger-aware and call refresh after app-local ledger writes, rather than creating a separate SwiftUI source of truth.

### 0F. V1 Command Center deferrals

The v1 cutline deliberately defers broader Command Center reshaping: full symbol/API/key rename, shared Agent Board/direct-Agent expansion, a dedicated Decisions rail, Plan-is-board layout, and shortcut flip. The current selected-Mission board plus read-only Plan presentation remains the layout boundary until a later OpenSpec changes it. Direct Agent sessions stay in Agent Mode unless structurally owned by a Coordinator/Director Mission; preserving `CoordinatorModeRowOrigin.directAgent` is for a later shared-board/filter relaxation, not this pass.

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

Workflow labels are read-only display metadata in the production-demo path. The projector accepts a flat `WorkflowDisplaySummary` derived from real `AgentWorkflowDefinition` metadata (`id`, display name, SF Symbol, optional accent), not a Coordinator-only toy enum. Live rows derive the summary from the latest user-turn workflow already held in the Agent Mode transcript model, so a workflow chip can appear, change, or clear between turns without scanning transcripts per row. Persisted/off-window rows use the same summary stored in the Agent session metadata index; index reconciliation must preserve or recover that summary instead of downgrading it when rebuilding from lightweight stubs. The label does not change grouping, sorting, filtering, action creation, or model/tool/policy selection.

Action-chip workflow labels are render-time lookups from the current target row when available and fall back to stored action metadata captured from the projected row when the target is temporarily unavailable. The chip stores the delegated target session ID and verb/phase; the view rereads the row's current workflow/status metadata, so a later follow-up without a workflow clears the workflow affordance instead of leaving stale context on the chip. Restoring or opening a delegated Agent chat must not be required to bring workflow chips back after app restart.

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

If `openAgentChatRoute` is nil, the Coordinator view hides or disables `Open agent chat` / `Decide`. General pending responses still route to Agent Mode, but a selected-Mission child pending interaction can be bridged into the Coordinator composer as a visible child checkpoint. In that case, the next user message is forwarded to the existing pending-interaction response path for that child and recorded in the Coordinator rail as "user answered the child," not as a normal Coordinator-authored directive.

### 9. Deep links use existing Agent UI routing

When route data is resolvable, Coordinator view rows and pending summaries use `AgentSessionDeepLinkRoute` or direct same-window `WindowState.routeToAgentSession`. A route requires active workspace context, a resolvable tab, and an optional session ID when available. `AgentSessionMeta` is not a self-contained route payload because it does not carry `workspaceID`; v1 route construction uses the active workspace context for `workspaceID` and metadata for tab/session identifiers when present.

### 10. MCP awareness is compact

Consume the `MCPServerViewModel.DashboardConsumer.coordinatorMode` case added by `add-mcp-coordinator-mode-consumer`. The Coordinator view subscribes while visible and shows compact connected/idle/off client count, recent tool calls, and active/in-flight call count in stable board chrome. Agent rows are active-workspace scoped, but MCP awareness is server/window scoped; it may include clients or calls not tied to the visible row list. External error triage, detailed attribution, and active-scope visualization are follow-ups.

### 11. Status grouping is total and precedence-based

Status groups are evaluated top-down: `Needs you` > `Blocked` > `Working` > `Done` > `Idle`.

- `Needs you`: current-window live run state is `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`; MCP pending interaction data enriches prompt/details when available.
- `Blocked`: current-window live run state is `.failed` or current-window live metadata reports conflicted worktree/merge attention.
- `Working`: current-window live run state is `.running`.
- `Done`: run state is `.completed` or `.cancelled`.
- `Idle`: run state is `.idle` or no higher-priority group applies.

Blocked's conflicted-merge signal should come from cheap metadata such as active worktree merge summaries, but only for current-window live rows. V1 sorting is read-only display order within existing groups: `Last updated` is the default, with `Name` and `Priority` as additional sort modes. Sorting applies to both board cards and list rows, should use cheap metadata, e.g. attention age, structured priority/attention data, display name, or activity/last-modified dates, and must not require transcript loads. Sorting must not change group membership, card/row state, Coordinator relationship, or persisted session state. Persisted-only cards/rows may still appear as `Done` or `Idle` from persisted metadata, but persisted-only failed/conflicted metadata renders as stale/persisted-only instead of contributing to live Blocked counts or the `Blocked` group. Persisted-only rows must not contribute to live `Needs you`, `Blocked`, or `Working` counts and should render with a stale/persisted-only visual treatment instead of live actionable styling.

### 12. Coordinator rail is optional; board/list workspace stands alone

The v1 Coordinator view is board-first, with List as an alternate and narrow-width fallback. If no Coordinator is selected or detected, the Coordinator view still renders the grouped active-workspace board or list and shows an empty/choose-Coordinator state in the rail area. If multiple auto-detected Coordinator candidates exist, v1 picks the most recent candidate within the highest-ranked matching precedence tier until the user selects a different per-window, workspace-keyed Coordinator. The Coordinator/session rail is in-surface Coordinator view navigation for Coordinator identity/selection, optional context, the scoped Coordinator composer, and mode-local destinations such as the all-agents Coordinator board; it is not the app-level Agent Mode ↔ Coordinator mode surface switcher. It should not contain Agent Mode as a rail item, and it should not host a separate by-agent roster of workspace sessions in v1.

The Coordinator rail collapse state is independent from the board and inspector. When the rail is hidden, the view should keep a slim left-edge restore affordance so users can expand it again without relying on Kanban toolbar controls or inspector chrome.

Coordinator Mission selection should use an always-visible sidebar list pattern rather than a click-to-open picker. The rail has enough room to show the new-Mission row, active/pinned Missions, and a collapsed archived Mission section inline, similar to Agent Mode's session sidebar. Selecting an existing Mission should be a direct row action; the list should not require opening a Mission popover just to switch conversations. When the archived section is expanded, it should participate in the rail's main scroll area and use the available sidebar height rather than being capped to a tiny fixed row count. Persisted-only Mission rows should not show a redundant `Persisted` badge next to every row.

The leading rail and right work/inspector panel should use rounded floating material chrome, closer to Agent Mode's sidebar treatment, so sidebars read as softly layered over the workspace rather than hard split panes.

### 13. Coordinator composer is the only v1 Coordinator view write path

The v1 Coordinator composer is enabled only when the selected/detected Coordinator is live in the current window, using the same current-window liveness predicate as Coordinator view live enrichment. If no Coordinator is selected/detected, or if the Coordinator is persisted-only or owned by another window, the composer is disabled and the rail should provide an `Open agent chat` affordance when route data is available.

A v1 directive is an ordinary user message delivered to the Coordinator session through the existing Agent Mode message path. V1 does not define a structured directive envelope, cross-window directive routing, Coordinator-view-side interrupt/steer semantics, or direct mutation of child sessions. The composer may echo the user's sent directive into the rail transcript; Coordinator responses and child-session effects surface through normal coarse Coordinator view snapshot refresh rather than a live token stream in the rail. Clear Chat is a rail display reset only: it must not delete, truncate, or rewrite the underlying Coordinator session transcript, which persists and archives through the existing Agent Mode session lifecycle. If the Coordinator is mid-run, v1 may queue the directive as the next turn or disable send; it must not implement Coordinator-view-side interrupt or steering.

Manual/Auto mode is a Coordinator chat-level setting. It belongs with the Coordinator composer/conversation controls and must not be coupled to Kanban presentation, sorting, filtering, or all-agents board navigation.

The Coordinator composer may reuse Agent Mode input conveniences when they feed the same ordinary-message path: slash-skill insertion, workspace file mentions, and provider MCP/tool preference controls. These are Coordinator-run launch/preferences and directive-composition affordances, not a second Agent Mode session control strip; model selection, attachments, broad permission editing, and child-session mutation remain out of scope unless a specific Coordinator-view behavior is defined.

### 13A. Production demo bridge hides Coordinator backing-session chrome

The production-feeling demo may still deliver directives through a selected, auto-detected, or marked/background Agent `TabSession` while the real Coordinator role work lands. That runtime is an implementation bridge. The Coordinator rail should not expose `Open in Agent Mode` for the Coordinator itself once the rail is acting as the primary Coordinator conversation surface.

Agent Mode deep links remain available for supervised delegate rows, pending summaries, and detail that belongs in Agent Mode. They should not be used to invite the user to inspect or drive the Coordinator backing runtime as if it were part of the supervised fleet. When a first-class Coordinator marker exists, the backing runtime should be excluded at the shared enumeration boundary used by Coordinator mode groups, Agent Mode sidebar/session lists, and MCP session-list surfaces. Before that marker exists, local Coordinator-rail suppression is an acceptable demo bridge, but it must be treated as temporary presentation behavior rather than final architecture.

Coordinator housekeeping children are also distinct from supervised work. The automatic loopback proof has been retired from the default production-demo prompt because real delegated sessions now exercise the same `agent_run.start` path directly. If future Coordinator housekeeping sessions are needed, they should be stamped with an explicit internal Coordinator marker at creation time and excluded from both board/list fleet rows and Coordinator action chips. The implementation must not infer internal housekeeping from session titles. In the demo this marker can remain in-memory like the demo Coordinator runtime marker; the production architecture should replace it with durable containment/activity metadata.

Coordinator action chips are currently board/result-derived, not true tool-call-event-derived. They provide a readable "delegated" cue when a new supervised child row appears, but they do not yet model pending dispatch, collect/review/cancel actions, multi-action batches, or a general action/event stream. That future stream should feed chips and board rows from the same sourced activity model.

Window-level chrome should follow the same rule. When Coordinator mode is the active main surface, the window title should remain workspace-scoped rather than borrowing the active Agent session tab title; the toolbar peer surface switcher identifies the active Coordinator surface. Parent/delegate session titles belong in board/list rows, inspector detail, or explicit Agent Mode deep links, not in the top-level Coordinator window title.

The rail conversation should also be wide and rich enough to read as a first-class command log. Coordinator responses may contain bullets, links, code fences, and inline code, so production-demo rows should reuse the same Markdown rendering substrate used by Agent Mode assistant messages instead of presenting raw Markdown as plain wrapped text.

The Coordinator composer should share Agent Mode's composer visual vocabulary without exposing Agent Mode's normal agent-session controls. It may use a rounded command surface, separated text area, compact status/identity strip, send affordance, slash-skill/file-mention input overlays, and compact MCP/tool controls that write to the same provider preferences used by Coordinator runs. It should not add model, workflow, broad permission, attachment, or child-session controls until those controls represent real Coordinator-view behavior.

Coordinator Mission Templates are the one Coordinator-specific prompt-wrapper affordance in this composer. They apply only when starting a fresh parent Mission, not to existing Mission follow-ups. The template store deliberately mirrors Agent Mode workflow markdown/frontmatter ergonomics while remaining a separate store and model because Agent workflows describe delegated child-agent behavior, whereas Mission Templates shape the parent Coordinator's initial objective. The submit path therefore carries both visible raw Mission text and provider-wrapped runtime text: the Coordinator runtime receives the wrapped prompt, while rail transcript and follow-through state remember the raw objective plus lightweight selected-template metadata.

Built-in Mission Templates may demonstrate staged Coordinator control-plane patterns. For example, a Deep Plan -> Orchestrate -> Review template still wraps the parent Coordinator Mission, but its instructions tell that parent to delegate child sessions using real Agent Mode workflows, pause when Deep Plan reaches a user checkpoint, and only continue into mutable Orchestrate/Review work after the user proceeds.

The staged Deep Plan checkpoint should stay conversational while preserving the child interaction shape. When the Deep Plan child enters `Needs you`, the board/card state remains observability, while the Coordinator chat shows the sourced child question with the same structured options, custom answer affordance, skip controls, and validation used by Agent Mode `ask_user`. The app forwards that structured answer to the child session that asked; it does not let the Coordinator invent the answer or ask the user to jump into Agent Mode for the happy-path demo. Auto follow-through remains held while any selected-Mission child is in `Needs you`, and resumes only after the child advances or completes. Plain text remains a fallback for non-structured pending interaction kinds.

### 13B. Demo fleet scope must become one-to-many

The remaining demo constraint is the singleton Coordinator runtime. Today the bridge treats `isCoordinatorRuntimeDemo` as "the current Coordinator," projects the board from that one runtime's descendants, and lets the "new Coordinator" path clear the marker so a later directive starts from an empty board. That behavior is useful for reproducibility, but it undercuts the Coordinator story because a control-plane surface should be able to supervise multiple parent tasks without pretending each fresh conversation invalidates the previous fleet.

The production-demo path should split three concepts that are currently bundled together:

1. **Coordinator runtime set**: all marked Coordinator backing runtimes that belong to the current workspace-scoped demo fleet.
2. **Selected Coordinator runtime**: the single runtime whose conversation is shown in the left rail and addressed by the composer.
3. **Fleet reset/retirement**: an explicit operation that removes one runtime or clears the whole fleet, separate from starting another Coordinator conversation.

The term **parent** is intentionally narrow in Coordinator mode. A parent Coordinator means a Coordinator runtime root, not any Agent session with a `parentSessionID` child. A delegated session is still a normal tab-scoped Agent Mode session launched through the same `agent_run.start` MCP primitive used by external clients, including Codex-over-CLI. It carries real tab-coupled state such as selection, worktree bindings, permission profile, transcript, and routeability even when the Coordinator board renders it as an abstract card. Coordinator mode projects that state; it does not replace Agent Mode or detach sessions from their tabs.

The demo bridge currently uses a marked Codex Agent Mode runtime (`isCoordinatorRuntimeDemo`) with Coordinator-specific prompt behavior as the Coordinator runtime root. It is not itself launched as an `orchestrate` workflow run. Delegated children can still receive real `workflow_id` / `workflow_name` values, and `workflow_name="orchestrate"` remains the platform's intended workflow for planning/decomposition/sub-agent dispatch. The intended target mechanism is specified by `add-coordinator-role`: a first-class Coordinator meta-agent identity with delegate-only policy, no direct tab/file/worktree scope, and later Coordinator-scoped session visibility. This change remains the human-facing control-plane shell and production-demo bridge; it should not treat the bridge marker as the durable role/scope mechanism.

Mutable delegated work needs one extra boundary so follow-through and merge previews have stable identity. A Coordinator parent may delegate read-only investigation without a worktree, but any delegated child expected to edit files, run validation that writes outputs, generate a merge preview, commit, or prepare a PR must be launched with an explicit child execution sandbox. In practice the Coordinator uses `agent_run.start` with `worktree_create:true` or a specific `worktree_id`; `inherit_worktree` alone is not enough because it does not prove the child was isolated before the session was created. If mutable work is requested without an explicit sandbox, the app should reject the child start before creating the child session and surface an actionable boundary message to the Coordinator. This is not direct Coordinator worktree mutation: the Coordinator still lacks tab/file/worktree tools and only provisions the delegated child's execution context through the lifecycle/control-plane start call.

In the near-term demo, the runtime set can remain an in-memory workspace-scoped registry, just like the existing marker. `New Coordinator` should create an additional Coordinator runtime and select it for the rail; it should not unmark previous Coordinator runtimes or discard their delegated descendants from the board. `Clear Chat` should remain a rail display reset and must not clear the fleet. If a destructive reset is needed for demos, it should be explicit, e.g. `Retire Coordinator` for the selected runtime or `Reset Fleet` for the whole workspace-scoped demo fleet.

The board/list migration should be sequenced in two visible checkpoints so runtime identity and aggregate projection bugs do not blur together:

1. **Selected-runtime board checkpoint**: multiple Coordinator runtimes can coexist, the rail targets the selected runtime, the rail exposes a visible parent switcher, and the board/list shows that selected runtime's delegated descendants. Switching the selected Coordinator swaps the board. This proves runtime identity, selection, and name-fallback removal before aggregate projection changes.
2. **Aggregate fleet board checkpoint**: board/list rows come from all eligible active-workspace Coordinator fleet roots, excluding Coordinator backing runtimes and explicitly marked Coordinator-internal housekeeping sessions. Switching the selected Coordinator changes the rail target, while the board remains the aggregate fleet view.

The production UI separates these scopes by Coordinator-mode navigation rather than by a Kanban-local scope toggle. The primary Coordinator chat destination keeps the board focused on the selected Coordinator parent. A separate left-navigation destination, "All Agents Board," shows live delegated rows across active Coordinator roots in the workspace. It does not include direct Agent Mode sessions merely because they are live; those remain part of the normal Agent Mode surface unless they are structurally owned by a Coordinator root. Because this destination is board-first rather than chat-first, it hides the Coordinator chat/composer and lets the board plus inspector use the available workspace width.

Aggregate mode must make parent ownership visible, not merely retained in hidden metadata. Otherwise the board demonstrates "many cards" but not "multiple parents managed without confusion." Cards and rows should render a sourced parent indicator using a reserved neutral treatment distinct from lifecycle state color and workflow badges. The indicator can be a compact label or short parent identifier; it should avoid adding another competing status color. When a parent is selected in the rail while the aggregate board is shown, that selected parent's delegated rows should receive subtle emphasis so the user's active conversation and the board remain visually connected.

Owner attribution is root-resolved, not immediate-parent display. A projected row's immediate `parentSessionID` may point to a worker session rather than to a Coordinator runtime root, for example when a normal delegated worker creates a read-only `agent_explore` probe. The aggregate board's parent indicator therefore means **owner Coordinator root**: walk structured `parentSessionID` lineage upward until a marked Coordinator runtime root is reached, then use that root for the badge, inspector context, and selected-parent emphasis. The immediate `parentSessionID` remains structured metadata for future grouping or tree detail, but it is not the visual parent badge unless it is also the owning Coordinator root. This keeps read-only probe descendants legible as part of the Coordinator mission without parsing titles, assistant prose, or workflow labels.

This change preserves the rail's "talk to one Coordinator" model while letting the center board demonstrate the actual control-plane value: multiple parent tasks, launched sequentially or in parallel, can remain visible, attributed to their owning parent, and independently progress across `Needs you`, `Working`, `Blocked`, `Review`, and `Done`.

Board/list rows should expose a small structured workstream projection so the UI is not forced to infer work from session titles. The projection is a flat `CoordinatorWorkstream` read model derived from existing session/live-state metadata: objective summary, phase, child session ID as stable identity, owner Coordinator root when present, worktree binding, workflow label, available merge/inspection state, and next action. It is not a separate source of truth and must not mutate runtime state; it makes the current session/worktree/review state legible enough for follow-through and human gates to reason about the same item the user sees. This flat identity is intentionally DAG-friendly for future dependency edges, but v1 does not require or invent a DAG. Follow-through classification should consume this projection first, falling back to lower-level row fields only when the projection is unavailable, so the board-visible work item and supervisor decision describe the same phase and next action.

Mission-level workstreams are the first durable layer of the DAG-lite plan, not a throwaway summary. A `CoordinatorMissionPlan` lives with the Coordinator parent follow-through state and records the user's objective, revision, status, approval state, template summary, workstreams, future plan nodes, and execution events. Workstreams define coarse execution lanes with title, purpose, role, default execution policy, explicit worktree strategy, optional primary child session ID, related session IDs, and optional worktree ID. The Coordinator updates this plan through the external `coordinator_chat` control surface using `op: "mission_plan"`; the operation accepts partial updates for objective, status, approval state, workstreams, DAG-lite nodes, and appended events while preserving omitted fields. It updates local Mission state and projection metadata only. It does not submit a new chat turn, create or mutate child sessions, change board status groups, or authorize work.

Worktree strategy is the prerequisite that makes later DAG-lite nodes clean. A workstream answers "where does this lane of work happen?" with modes for read-only work, new isolated worktree, existing worktree, same-workstream worktree, or ask-user. Later plan nodes can answer "how does this step run?" by inheriting the workstream lane, steering a primary child, starting a fresh sibling on the same worktree, starting a fresh worktree, responding to an interaction, or stopping for a human gate.

The Mission Plan is deliberately a plan/source-of-intent layer while Kanban remains sourced session evidence. It gives the demo a stable Mission plan card and lets the inspector explain "this row is the Review workstream for the Mission" without parsing titles. The right work panel exposes this layer through a read-only `Plan` presentation beside `Board`; the previous full `List` presentation remains only as the responsive fallback when Board columns cannot fit. The Plan presentation shows stored workstreams, DAG-lite nodes, revision/status/approval metadata, and node events without creating phantom board cards. Selecting a Plan node reuses the same bottom inspector surface as board rows, but shows plan-node/workstream details and only offers `Open Agent` when the node is bound to a routeable child session. When a declared workstream has a primary or related child session ID matching a projected row, the row's `CoordinatorWorkstream` includes that declared purpose/role/default-policy/worktree-strategy. If no child ID has been attached yet, the plan still appears in the Coordinator conversation and Plan tab as Mission context, but it does not create a phantom board card. Mission Templates should instruct the Coordinator to write and update the plan as it delegates, steers, or reviews children so the visible Mission plan, board, and inspector stay aligned. External Coordinator/debugging clients can also call read-only `coordinator_chat op="mission_status"` to retrieve the selected or requested Mission's plan revision, status, approval state, workstreams, nodes, dependency satisfaction, node counts, recent events, board/session bindings, and a short debug summary without mutating state.

Worktree identity should remain visually consistent with Agent Mode. Coordinator cards, rows, delegated conversation cards, and inspector worktree fields should use the persisted worktree visual color from the session worktree binding so sibling sessions that share an app-managed worktree read as related in both Coordinator and Agent Mode.

The demo should make the parent/child distinction explicit instead of relying on the prompt text to imply it. A parent Coordinator is a conversation/control loop. A delegated child is work launched by that parent, often in its own tab and worktree. Asking one Coordinator to launch three worktrees should therefore produce one Coordinator runtime root with three delegated sessions, not three parent Coordinators. Multiple Coordinator roots are appropriate when the work represents independent missions that deserve separate conversation history, decision flow, and supervision, e.g. unrelated investigations, separate PR/workstream reviews, or long-running work that should not pollute a quick side task.

Ordinary delegated sub-agents cannot recursively start additional full `agent_run` sessions; the MCP control plane enforces that boundary. A limited read-only `agent_explore` descendant can exist under a worker, but it is a probe rather than a supervising control loop and should attribute to the owning Coordinator root. A future hierarchical Coordinator-of-Coordinators model would be a different feature: it would need durable containment metadata, promotion/spawn semantics for Coordinator children, hierarchical navigation, and path-style attribution such as `Coordinator A -> Sub-Coordinator B -> leaf` instead of the current single owner badge.

Demo examples should cover the common patterns as gesture sequences, not just prompts: single delegation, one-parent fan-out, sequential multi-parent work, simultaneous multi-parent work, and switching back to supervise an earlier parent. Those examples live in `reference/coordinator-demo-use-cases.md` and should identify which checkpoint each pattern requires. The multi-parent examples depend on a visible way to select an existing Coordinator parent after `New Coordinator` creates another one; the v1 production-demo affordance is a compact rail-header switcher backed by the workspace-scoped Coordinator runtime set. Workflow-bearing examples depend on the delegated `agent_run` path honoring `workflow_id` or `workflow_name` so row/card/inspector workflow metadata stays sourced from real Agent Mode workflow definitions.

### 13C. Follow-through uses observed events and visible chat checkpoints

Prompt-guided follow-through is useful while the Coordinator is already awake, but it is not enough for child-completion and safe continuation moments that happen after the Coordinator reaches a turn boundary. The production-demo bridge therefore adds a small app-owned supervisor layer. The supervisor remembers a lightweight per-Coordinator objective summary, observes sourced child phases, tracks pending/handled resume event IDs, and wakes the existing owning Coordinator runtime only when a pure boundary classifier says the next step is safe to consider.

This supervisor is intentionally narrower than a workflow engine. It does not mutate board rows directly, approve permissions, apply merge previews, commit, push, or create new Coordinator parents. It submits a structured internal resume directive to the same Coordinator parent runtime that owns the child. Stable event IDs, such as `child:<id>:terminal:<state>`, `review:<operationID>:advisory`, and `gate:<gateID>:cleared`, prevent repeated lifecycle refreshes from creating duplicate follow-up turns. If the Coordinator is active, the event can remain pending until the runtime reaches an ordinary turn boundary.

The classifier is the safety line. It holds when proactive follow-through is disabled, when the Coordinator is active, when any owned child is in `Needs you` or `Blocked`, or when the next step needs explicit human permission. It may resume for child terminal states and reviewable child output, but human continuation approval is deliberately visible and conversational rather than hidden in an inspector row action.

When the Coordinator chooses to pause for the human, the control belongs in the Coordinator chat. Chat-level actions such as `Proceed`, `Revise`, and `Stop here` submit ordinary visible messages to the owning Coordinator parent. Those actions are rendered from explicit Coordinator checkpoint metadata, not from ordinary assistant prose or final summaries, and the metadata is stripped from the visible rail transcript. `Proceed` means only "continue the next safe step you proposed"; it is not approval to apply, merge, commit, push, create a PR, or bypass any remaining permission prompt. Board rows and inspector cards remain observability surfaces, not workflow authority.

Delegated-session cards are part of that visible conversational timeline. They should be inserted when the child Mission/session first appears in Coordinator projection, even if the child is still running or queued, and then reflect the same live status metadata used by the board. Workflow badges such as Orchestrate or Review annotate the delegated work, but the progressive event behavior applies equally to ordinary delegated agent starts.

Selected-Mission board rows, Mission history child counts, and delegated-session chat cards must share the same owner-resolution projection. If those surfaces compute ownership independently, MCP-submitted starts can appear in chat while the selected board stays empty, or workflow badges/status can go stale after the child row updates. The selected-Mission projection should therefore filter the already root-resolved Coordinator owner map rather than rebuilding a separate selected-owner map.

Because delegated-session cards are the conversational record of concrete child work, clicking one should behave as navigation to that same projected object when it is still present: select the matching board/list row, reveal the inspector, and leave the Coordinator Mission conversation selected. This is a read-only observability jump, not a workflow command or a child-session mutation. If a local row filter hides the object, the jump can clear that filter so the visual target and inspector are brought back into view.

### 14. Inspector stays sourced; full logs stay in Agent Mode

The v1 inspector / trailing detail column shows sourced summaries only: status, pending interaction, blocker, worktree/merge, route, and MCP/session metadata. Full transcript, raw log, file, and diff inspection remain in Agent Mode via `Open agent chat`. A Coordinator-view-native full-log toggle is a follow-up unless backed by a sourced activity projection.

Inspector reply controls follow the same routeability boundary. A delegated child that is live in the current window may expose the inline follow-up composer. A child that is routeable but not live should present an explicit `Open to reply` action that opens the existing Agent Mode session, rather than showing a dead disabled reply card until the user separately clicks `Open Agent`. If no route exists, the reply affordance stays disabled/unavailable.

When the inspector is rendered below the board rather than as a trailing side column, its collapse affordance should match that geometry: a sheet-like handle that slides the inspector down when hidden and back up when restored. It should not use a left-side sidebar toggle while the inspector is vertically stacked under the Kanban.

### 15. Board-first v1 keeps List as alternate and fallback

The v1 surface defaults to a read-only status board. List remains a first-class alternate view and the responsive fallback when board columns cannot fit. Board and List render the same `CoordinatorModeSnapshot`, grouping, sorting, stale-row semantics, route availability, and read-only card/row action constraints. The selected-Mission board keeps `Needs you`, `Working`, and `Done` visible as stable defaults so the primary loop of attention, active work, and completion is always available. Empty `Blocked` and `Review` columns are omitted until those statuses contain rows; `Review` still appears when completed work has sourced reviewable material, such as a merge preview. Those three selected-Mission default lanes should flex to fit the board area at ordinary Coordinator panel widths. Kanban cards should stay compact: the lane already communicates lifecycle state, and persisted/live source details can remain in List and Inspector instead of repeating as chips inside every card. The All Agents Board should keep all lanes visible so the fleet overview remains spatially stable. The board is the protected region: the inspector / trailing detail column should collapse first, then Coordinator chat may collapse to a rail, while board columns preserve a usable minimum width and may scroll horizontally. Below the width where two board columns can fit, the board falls back to List rather than rendering a cramped board. Drag ordering, dispatch, status changes, inline approvals/retries, structured directives, cross-window directives, and interrupt/steer semantics remain Layer 2/3 follow-ups.

The leading Coordinator rail titlebar should stay visually quiet. It may expose an icon-only `New Mission` action near the macOS window controls and the rail collapse affordance, but it should not repeat low-value descriptive title text that competes with the conversation and board.

The board header should remain a compact control lane for view, sorting, and compact MCP awareness. Session filtering belongs along the bottom of the All Agents board/list workspace so it does not crowd the board presentation controls or compete with the Coordinator chat; selected-Mission boards omit the filter to keep the scoped board and inspector visually calm.

## Risks / Trade-offs

- **Coordinator ambiguity** → Use precedence rules, most-recent auto-candidate fallback, and per-window user override instead of guessing from plain lineage.
- **Multi-window stale rows** → Render stale/persisted-only state explicitly; keep live `Needs you` / `Working` counts current-window-only.
- **Reactive firehose** → Observe coarse signals and diff snapshots before publishing.
- **Workflow lookup cost** → Keep workflow display on cheap live request-anchor metadata and persisted session-index summaries. Index rebuilds may do targeted full-session decodes to recover missing workflow summaries, but UI projection must not load transcripts per row or depend on opening Agent chats to hydrate labels.
- **Pending decision asymmetry** → Run-state waiting values still enter `Needs you`; MCP-controlled live interactions only enrich the prompt/detail payload.
- **Route gaps** → Store nullable routes on rows/summaries and hide navigation when route prerequisites are missing.
- **Command Center scope creep** → Keep the v1 deferrals in Decisions 0F explicit: no full symbol/API/key rename, shared Agent Board/direct-Agent expansion, Decisions rail, Plan-is-board layout, or shortcut flip in this pass.

## Migration Plan

1. Add Coordinator mode artifacts behind a non-default in-`.main` peer surface while Agent Mode remains the configured v1 landing surface.
2. Build snapshot projection and tests before wiring the Coordinator composer.
3. Add UI shell and deep links after snapshot behavior is stable.
4. Consume the MCP Coordinator mode consumer added by `add-mcp-coordinator-mode-consumer` after compact MCP projection tests are in place.
5. Defer Coordinator-view-side approval/retry actions, drag/dispatch/status mutations, structured directive transport, cross-window directives, objective labels, and cross-window/cross-workspace aggregation.

Rollback is simple for v1: remove or hide the Coordinator mode entry point; Agent Mode remains the default and canonical surface.

## Open Questions

- Should future workflow label history show only the latest workflow, or a compact sequence when a delegated session changes workflows over multiple turns?
- Should a future Coordinator view support cross-window live ownership or route-to-owning-window behavior instead of stale/persisted-only rows?
- Should PR/check metadata wait until a separate activity/event adapter exists?
