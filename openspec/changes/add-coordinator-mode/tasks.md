## 1. Main surface and entry point

- [x] 1.1 Add window-scoped main-surface selection state inside `.main`.
- [x] 1.2 Preserve Agent Mode as the configured default `.main` landing surface in v1.
- [x] 1.3 Add a persistent macOS-native peer surface switcher for Agent Mode ↔ Coordinator mode that is available only after a real workspace is active; reject iOS-style tab bars.
- [x] 1.4 Mirror Agent Mode and Coordinator mode choices in the View menu so navigation remains available when toolbar chrome is hidden or customized.
- [x] 1.5 Preserve surface selection as sticky per live window while keeping Coordinator selection keyed by active workspace; prefer `@SceneStorage` or equivalent scene-level state.
- [x] 1.6 Preserve `AppLaunchConfiguration.forcedRootRoute == .main` behavior so deterministic UI tests still land on Agent Mode unless a forced-surface knob is added.

## 2. Coordinator view snapshot projection

- [x] 2.1 Define `CoordinatorModeSnapshot` as the single render contract for counts, groups, rows, Coordinator rail, pending summaries, MCP footer, and deep-link payloads.
- [x] 2.2 Implement a lazy, window-scoped `@MainActor` Coordinator view model.
- [x] 2.3 Compose the snapshot from current-window Agent Mode live state, active-workspace session metadata, and `MCPServerViewModel.dashboard`, assuming the named MCP Coordinator mode consumer from `add-mcp-coordinator-mode-consumer`.
- [x] 2.4 Add diff-before-publish/fingerprint behavior so streaming transcript or token deltas do not republish unchanged Coordinator view rows.
- [x] 2.5 Represent stale/persisted-only rows for active-workspace sessions without current-window live state.

## 3. Coordinator identity

- [x] 3.1 Implement user-selected Coordinator state as per-window ephemeral state keyed by active workspace ID.
- [x] 3.2 Implement Orchestrate workflow candidate detection only when launch/first-request workflow metadata is already available without per-row transcript churn.
- [x] 3.3 Implement MCP-originated lineage-root-with-children candidate detection.
- [x] 3.4 Implement zero-candidate board/list behavior with empty/choose-Coordinator rail state.
- [x] 3.5 Implement multiple-candidate behavior by selecting the most recent candidate within the highest-ranked matching precedence tier unless a user-selected Coordinator exists.
- [x] 3.6 Add tests for Coordinator identity precedence and ambiguity handling.

Deferred selection affordance note: no v1 UI currently sets user selection from row/card visibility alone. When that UI is added, pair it with liveness and eligibility fall-through tests before changing selection precedence.

## 4. Session row projection

- [x] 4.1 Project session identity, lineage, provider/model, run state, MCP origin, worktree bindings, and merge attention from structured metadata/live state.
- [x] 4.2 Omit workflow labels in v1; leave workflow index/transcript lookup as follow-up unless needed for Coordinator detection without churn.
- [x] 4.3 Omit objective labels in v1.
- [x] 4.4 Optionally project workstream labels/chips from worktree/logical-root metadata when available and useful for the UI.
- [x] 4.5 Ensure session titles or assistant prose are not parsed to infer labels.

## 5. Status grouping and sorting

- [x] 5.1 Implement Coordinator view status groups: Needs you, Blocked, Working, Review, Done, Idle.
- [x] 5.2 Evaluate groups top-down: Needs you, Blocked, Working, Review, Done, Idle.
- [x] 5.3 Map Needs you from current-window live `.waitingForUser`, `.waitingForQuestion`, and `.waitingForApproval`; use MCP pending interactions only as prompt/detail enrichment.
- [x] 5.4 Ensure persisted-only cards/rows never contribute to live `Needs you` or `Working` counts in v1 and render with stale/persisted-only treatment.
- [x] 5.5 Map Blocked from `.failed` run state or conflicted worktree/merge attention.
- [x] 5.6 Map Working from current-window live `.running`, Done from `.completed`/`.cancelled`, and Idle from `.idle` when no higher-priority group applies.
- [x] 5.7 Implement read-only sort controls for `Last updated` (default), `Name`, and `Priority` across board cards and list rows.
- [x] 5.8 Ensure sorting only reorders cards/rows within existing status groups and never changes group membership, run state, pending state, Coordinator relationship, or persisted session state.
- [x] 5.9 Ensure v1 does not expose drag-to-reorder, drag-to-dispatch, or drag-to-change-status interactions.
- [x] 5.10 Keep completed/cancelled rows with review material observable without treating Done as human acceptance.
- [x] 5.11 Add snapshot adapter tests for grouping, counts, stale-row count exclusion, review observability, and sort-mode behavior.
- [x] 5.12 Keep review-bearing completed rows eligible for Done or Review based on observable row state rather than an inspector-owned approval gate.

## 6. Pending interaction summaries

- [x] 6.1 Define Coordinator view pending summaries with `AgentRunMCPSnapshot.Interaction.Kind`, `AgentRunMCPSnapshot.Interaction.Detail`, and nullable `AgentSessionDeepLinkRoute`.
- [x] 6.2 Project prompt/detail summaries from live MCP-controlled `AgentRunMCPSnapshot.Interaction` values; leave broader non-MCP pending projection as a follow-up Agent Mode contract change.
- [ ] 6.3 Hide or disable decision navigation when `openAgentChatRoute` cannot be resolved.
- [ ] 6.4 Route users to Agent Mode for pending-interaction responses instead of executing Coordinator-view-side approval/retry actions.
- [x] 6.5 Add tests for pending interaction rendering, missing routes, and non-prose inference.

## 7. Deep-link behavior

- [x] 7.1 Build row and pending-summary route payloads from active workspace, resolvable tab, and optional session ID.
- [ ] 7.2 Use direct `WindowState.routeToAgentSession` for same-window navigation when possible.
- [ ] 7.3 Use existing `AgentSessionDeepLinkRoute` / router behavior for cross-window or URL-style navigation as needed.
- [x] 7.4 Ensure persisted-only rows without route data do not create or restore sessions during rendering.
- [x] 7.5 Add tests for resolvable, unresolvable, and persisted-only no-restore route states.

## 8. MCP compact projection

- [x] 8.1 Consume the Coordinator view MCP consumer provided by `add-mcp-coordinator-mode-consumer`.
- [x] 8.2 Subscribe to MCP updates while Coordinator mode is visible and unsubscribe when hidden.
- [x] 8.3 Project connected/idle/off client count, recent tool calls, active/in-flight count, and recent-call history without connected clients as server/window-scoped MCP awareness that may not map one-to-one to visible rows.
- [x] 8.4 Add tests for MCP compact projection, MCP-off/empty states, and history-only recent-call state without retesting the shared consumer lifecycle owned by `add-mcp-coordinator-mode-consumer`.

## 9. Coordinator composer

- [x] 9.1 Enable the Coordinator composer only when the selected/detected Coordinator has current-window live state.
- [x] 9.2 Disable the composer or show `Open agent chat` when no Coordinator exists, the Coordinator is persisted-only, or the Coordinator is owned by another window.
- [x] 9.3 Deliver submitted directives as ordinary user messages through the existing Agent Mode message path.
- [x] 9.4 Do not define structured directive envelopes, cross-window directive routing, Coordinator-view-side interrupt/steer semantics, or direct child-session mutation in v1.
- [x] 9.5 Echo accepted user directives into the Coordinator rail transcript when appropriate, while surfacing Coordinator responses and child-session effects through normal coarse snapshot refresh.
- [x] 9.6 Add tests for composer enablement, unreachable Coordinator fallback, ordinary-message dispatch, and no direct board/session mutation.
- [x] 9.7 Suppress `Open in Agent Mode` / `Open agent chat` for the Coordinator backing actor in the production-demo rail while preserving Agent Mode deep links for supervised delegate rows and pending summaries.
- [x] 9.8 Add a persisted chat-level manual/follow-through Coordinator runtime policy toggle that defaults to manual.
- [x] 9.9 Inject follow-through guidance into Coordinator runtime prompts without changing submitted directive text or adding a structured directive envelope.
- [x] 9.10 Add focused tests for follow-through persistence and prompt-gating behavior.
- [x] 9.11 Persist lightweight Coordinator follow-through state with objective summary, observed child phases, pending/handled events, and last resume result.
- [x] 9.12 Add a pure follow-through boundary classifier for safe resume versus hold decisions.
- [x] 9.13 Add an AgentMode-owned follow-through supervisor that wakes the existing Coordinator runtime on child lifecycle events without creating a new parent.
- [x] 9.14 Document and test that chat-level `Proceed` is a visible Coordinator message and does not approve merge/apply/commit/push work.
- [x] 9.15 Keep app-generated resume events observational; human continuation remains chat-owned rather than inspector-owned.
- [x] 9.16 Add a direct external MCP Coordinator chat control surface for fast live validation that reuses the Coordinator composer path and is hidden from in-agent role catalogs.
- [x] 9.17 Enforce Coordinator mutable-delegation worktree policy so read-only child runs may omit worktrees, but edits, tests, merge previews, commit/PR prep, and inherited-binding-only mutable starts require an explicit child worktree.
- [x] 9.18 Feed projected workstream summaries into follow-through classification so resume/hold decisions use the same phase, owner Coordinator, and next action shown on the board.
- [x] 9.19 Add chat-level `Proceed`, `Revise`, and `Stop here` continuation controls that submit ordinary messages to the owning Coordinator parent.
- [x] 9.20 Keep inspector continuation-free; Done remains a terminal observed state rather than human acceptance.
- [x] 9.21 Render chat-level continuation controls only from explicit Coordinator checkpoint metadata, not from ordinary Coordinator prose.
- [x] 9.22 Reuse Agent Mode slash-skill/file-mention input affordances and compact provider MCP/tool preference controls in the Coordinator composer for demo-ready Coordinator directives.

## 10. Coordinator view UI shell

- [x] 10.1 Build the Coordinator view shell with top counts, optional Coordinator rail, board-first status columns/cards, List view alternate/fallback, optional inspector / trailing detail column, MCP footer, and filter affordance.
- [x] 10.2 Keep the main board/list content calm by default: no full transcripts, full logs, diffs, file viewers, streaming tool feeds, or card/row write controls.
- [x] 10.3 Add Board/List view switching where Board is the v1 default and List renders the same snapshot as an alternate.
- [x] 10.4 Add responsive behavior: inspector yields before the board, Coordinator chat may collapse to a rail, high-priority columns remain visible when possible, lower-priority columns may de-emphasize/collapse with visible counts, board columns preserve usable width or scroll horizontally, and widths below two usable board columns fall back to List.
- [x] 10.5 Add progressive disclosure from count to card/row, optional sourced inspector summaries, and Agent Mode; keep full raw logs, transcripts, files, and diffs in Agent Mode for v1.
- [x] 10.6 Keep the Coordinator rail focused on Coordinator identity/selection, optional context, and scoped current-window composer; do not add a separate by-agent roster or `Agents` tab in v1.
- [ ] 10.7 Add UI previews or smoke states for board-default, board-card-selected, inspector-collapsed, list view, sort menu, Coordinator-composer enabled/disabled, empty workspace, active, needs-user, blocked, MCP-off, MCP-empty, MCP-active, filtered, zero-Coordinator, stale/persisted-only card/row, lower-priority column collapsed/de-emphasized, and multiple-Coordinator most-recent states.
- [x] 10.8 Bind the PR3 Coordinator shell to Agent Mode font-scale, search-field, chip, card, and subtle selection/hover chrome without changing snapshot or write-control behavior.
- [x] 10.9 Keep the production-demo rail visually framed as an agentic Coordinator conversation rather than an ordinary Agent Mode session proxy.
- [x] 10.10 Widen the production-demo Coordinator rail and render Coordinator/event messages through the shared Agent Mode Markdown renderer.
- [x] 10.11 Restyle the Coordinator composer as a compact Agent Mode-like command surface without adding ordinary Agent Mode controls.
- [x] 10.12 Keep the Coordinator composer text area editable and focused while send is gated by an active Coordinator run.
- [x] 10.13 Keep Coordinator mode window titles workspace-scoped instead of using the active Agent session tab.
- [x] 10.14 Move the Agent/Coordinator switcher to one window-toolbar location, remove sidebar/rail copies, and back it with live checked View-menu commands.
- [x] 10.15 Project read-only workflow display metadata from real Agent Mode workflow definitions, render it on Coordinator rows/inspectors/action chips, and clear/update it between live turns.
- [x] 10.16 Exclude explicitly marked Coordinator-internal housekeeping children from board/list and Coordinator action-chip surfaces without title matching.
- [x] 10.17 Document that current Coordinator action chips are board/result-derived delegate cues, not a complete tool-call action/event stream.
- [x] 10.18 Retire the automatic loopback proof from the default Coordinator demo prompt while preserving the fan-out wait guidance and internal-housekeeping marker.
- [x] 10.19 Split demo Coordinator state into a workspace-scoped runtime set plus selected rail runtime so multiple Coordinator parents can coexist.
- [x] 10.20 Change `New Coordinator` from destroy/replace behavior into create-additional-and-select behavior while preserving existing delegated descendants.
- [x] 10.21 Remove or narrow name-based Coordinator runtime fallback so multiple demo runtimes with similar titles cannot be confused.
- [x] 10.22 Checkpoint selected-runtime board behavior first: project board/list rows from the selected Coordinator runtime's eligible descendants while multiple runtime roots coexist.
- [x] 10.23 Add focused tests proving two Coordinator runtime roots can coexist, selection changes the rail target and selected-runtime board, `New Coordinator` preserves previous fleet membership, and explicit fleet reset is the only board-clearing operation.
- [x] 10.24 Project aggregate board/list rows from all eligible Coordinator fleet roots in the active workspace, excluding Coordinator backing runtimes and explicitly internal housekeeping sessions.
- [x] 10.25 Preserve parent/owner metadata on projected rows for grouping/filtering, action-chip attribution, inspector context, and aggregate-mode selected-parent emphasis without parsing titles.
- [x] 10.26 Render a compact sourced parent indicator on aggregate board/list rows using a reserved neutral treatment that does not compete with lifecycle state color or workflow badges.
- [x] 10.27 Add focused aggregate-mode tests proving all eligible roots appear, parent indicators are sourced, selected-parent row emphasis updates with rail selection, and aggregate mode does not swap board scope when selection changes.
- [x] 10.28 Add a demo use-case taxonomy with gesture sequence, prompt text, expected result, and required checkpoint for single delegation, one-parent fan-out, sequential multi-parent work, simultaneous multi-parent work, and switch-back supervision.
- [x] 10.29 Confirm or add a visible parent-selection affordance so users can return to an earlier Coordinator runtime after `New Coordinator` creates another parent.
- [x] 10.30 Verify workflow-bearing demo prompts by proving `agent_run workflow_name` reaches delegated starts and returns workflow display metadata.
- [x] 10.31 Add left-side Coordinator mode navigation so the default Coordinator chat board remains selected-parent focused while an All Agents Board shows live delegated rows across active Coordinator roots.
- [x] 10.32 Project structured workstream summaries for board/list rows with objective, phase, child session, owner Coordinator, worktree, workflow, merge/inspection state, and derived next action.
- [x] 10.33 Promote structured workstream projection to a first-class `CoordinatorWorkstream` read model with stable child-session identity without introducing DAG/source-of-truth state.
- [x] 10.34 Replace the vertically stacked inspector's side toggle with a bottom-sheet handle that slides the inspector down/up.
- [x] 10.35 Move `New Mission` into the leading rail titlebar as an icon-only action and remove redundant titlebar text.
- [x] 10.36 Hide Coordinator chat/composer in All Agents Board so the board and inspector can use the available workspace width.
- [x] 10.37 Add an independent left-edge restore affordance when the Coordinator rail is collapsed.
- [x] 10.38 Replace the Mission popover with inline rail history rows plus an archived-style persisted section.
- [x] 10.39 Move the session filter field from the top board controls to a bottom board/list filter bar.
- [x] 10.40 Let expanded archived Coordinator history use the left rail's flexible scroll area instead of a fixed three-row cap.
- [x] 10.41 Restyle the Coordinator rail and work/inspector surfaces with rounded floating material chrome.
- [x] 10.42 Rename Coordinator-specific parent-session rail copy to Missions and remove redundant per-row `Persisted` badges.

## 11. Validation

- [x] 11.1 Run the focused unit tests added for snapshot projection, Coordinator identity, Coordinator composer, pending interactions, MCP projection, and deep links.
- [x] 11.2 Run the smallest relevant coordinated Swift validation lane for touched app/UI files.
- [x] 11.3 Run `openspec validate add-coordinator-mode`.
- [x] 11.4 Re-run focused Coordinator projector/composer tests, coordinated Swift build/style checks, and OpenSpec validation after the workflow/internal-action refinement.
- [x] 11.5 Re-run focused Coordinator projector/composer tests, coordinated Swift build/style checks, and OpenSpec validation after the multi-runtime fleet-scope refinement.
- [x] 11.6 Run focused Coordinator mutable-delegation worktree policy tests.
