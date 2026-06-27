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

- [x] 5.1 Implement Coordinator view status groups: Needs you, Blocked, Working, Done, Idle.
- [x] 5.2 Evaluate groups top-down: Needs you, Blocked, Working, Done, Idle.
- [x] 5.3 Map Needs you from current-window live `.waitingForUser`, `.waitingForQuestion`, and `.waitingForApproval`; use MCP pending interactions only as prompt/detail enrichment.
- [x] 5.4 Ensure persisted-only cards/rows never contribute to live `Needs you` or `Working` counts in v1 and render with stale/persisted-only treatment.
- [x] 5.5 Map Blocked from `.failed` run state or conflicted worktree/merge attention.
- [x] 5.6 Map Working from current-window live `.running`, Done from `.completed`/`.cancelled`, and Idle from `.idle` when no higher-priority group applies.
- [x] 5.7 Implement read-only sort controls for `Last updated` (default), `Name`, and `Priority` across board cards and list rows.
- [x] 5.8 Ensure sorting only reorders cards/rows within existing status groups and never changes group membership, run state, pending state, Coordinator relationship, or persisted session state.
- [x] 5.9 Ensure v1 does not expose drag-to-reorder, drag-to-dispatch, or drag-to-change-status interactions.
- [x] 5.10 Add snapshot adapter tests for grouping, counts, stale-row count exclusion, and sort-mode behavior.

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
- [x] 9.3 Deliver submitted demo/manual directives as ordinary user turns through the existing Agent Mode message path.
- [x] 9.4 Do not define structured directive envelopes, cross-window directive routing, Coordinator-view-side interrupt/steer semantics, direct child-session mutation, or the future real Coordinator runtime instruction delivery path in v1.
- [x] 9.5 Echo accepted user directives into the Coordinator rail transcript when appropriate, while surfacing Coordinator responses and child-session effects through normal coarse snapshot refresh.
- [x] 9.6 Add tests for composer enablement, unreachable Coordinator demo/manual fallback, ordinary-user-turn dispatch, and no direct board/session mutation.

## 10. Coordinator view UI shell

- [x] 10.1 Build the Coordinator view shell with top counts, optional Coordinator rail, board-first status columns/cards, List view alternate/fallback, optional inspector / trailing detail column, MCP footer, and filter affordance.
- [x] 10.2 Keep the main board/list content calm by default: no full transcripts, full logs, diffs, file viewers, streaming tool feeds, or card/row write controls.
- [x] 10.3 Add Board/List view switching where Board is the v1 default and List renders the same snapshot as an alternate.
- [x] 10.4 Add responsive behavior: inspector yields before the board, Coordinator chat may collapse to a rail, high-priority columns remain visible when possible, lower-priority columns may de-emphasize/collapse with visible counts, board columns preserve usable width or scroll horizontally, and widths below two usable board columns fall back to List.
- [x] 10.5 Add progressive disclosure from count to card/row, optional sourced inspector summaries, and Agent Mode; keep full raw logs, transcripts, files, and diffs in Agent Mode for v1.
- [x] 10.6 Keep the Coordinator rail focused on Coordinator identity/selection, optional context, and scoped current-window composer; do not add a separate by-agent roster or `Agents` tab in v1.
- [ ] 10.7 Add UI previews or smoke states for board-default, board-card-selected, inspector-collapsed, list view, sort menu, Coordinator-composer enabled/disabled, empty workspace, active, needs-user, blocked, MCP-off, MCP-empty, MCP-active, filtered, zero-Coordinator, stale/persisted-only card/row, lower-priority column collapsed/de-emphasized, and multiple-Coordinator most-recent states.
- [x] 10.8 Bind the PR3 Coordinator shell to Agent Mode font-scale, search-field, chip, card, and subtle selection/hover chrome without changing snapshot or write-control behavior.

## 11. Validation

- [x] 11.1 Run the focused unit tests added for snapshot projection, Coordinator identity, Coordinator composer, pending interactions, MCP projection, and deep links.
- [x] 11.2 Run the smallest relevant coordinated Swift validation lane for touched app/UI files.
- [x] 11.3 Run `openspec validate add-coordinator-mode`.
