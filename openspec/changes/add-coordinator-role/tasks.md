## 1. Design confirmation

- [ ] 1.1 Record the accepted direction that Coordinator is a first-class role backed by a native RepoPrompt Agent task/session lifecycle contract, with MCP `agent_run` / `agent_manage` as adapters rather than the only durable boundary.
- [ ] 1.2 Decide the first Coordinator listing/control scope: active-workspace top-level, explicitly attached sessions, or app-global; keep app-global deferred unless cross-window ownership semantics are accepted.
- [ ] 1.3 Review the narrowed design with wren, using delegate-vs-focus, lifecycle-contract-vs-MCP-schema, active-workspace-top-level-vs-global, and current-window-vs-cross-window as the explicit discussion forks.
- [ ] 1.4 Update the spec/design with any accepted review changes before implementation begins.

## 2. Native Agent task/session lifecycle contract

- [ ] 2.1 Define the stable task/session handle model that Coordinator and external callers use for start, observe, steer, respond, cancel, and export behavior.
- [ ] 2.2 Define deterministic lifecycle status categories sufficient for Coordinator decisions: active work, actionable input-required work, and terminal work.
- [ ] 2.3 Define terminal outcome semantics for completed, failed, and cancelled; preserve or map existing expired semantics only if supported by the runtime.
- [ ] 2.4 Define the structured pending interaction shape, stable interaction ID, and response-by-interaction-ID semantics.
- [ ] 2.5 Define cancel semantics in the lifecycle contract, while keeping Coordinator access to cancel deferred unless explicitly accepted.
- [ ] 2.6 Define durable artifact refs for summaries, logs, handoff/export artifacts, worktree metadata, and related structured outputs.
- [ ] 2.7 Add public contract tests for caller-visible start, poll/status, wait, steer with wait semantics, respond, cancel, lifecycle category/outcome, and artifact/export shapes.

## 3. MCP adapter and role identity

- [ ] 3.1 Map existing MCP adapter operations to the native lifecycle contract: `agent_run.start`, `poll`, `wait`, `steer`, `respond`, `cancel`; `agent_manage.list_agents`, `list_sessions`, `get_log`, `handoff`/export.
- [ ] 3.2 Identify where current `agent_run` / `agent_manage` behavior is window, workspace, tab, or child scoped and cannot satisfy Coordinator scope.
- [ ] 3.3 Implement or specify the explicit Coordinator binding, adapter scope, or native lifecycle surface required for the accepted listing/control scope.
- [ ] 3.4 Add or reserve the `coordinator` role identity alongside existing role labels without changing default `pair`, `engineer`, `explore`, or `design` behavior.
- [ ] 3.5 Guard against the role-label trap: adding `coordinator` as a label must not by itself create an ordinary tab-backed session that is treated as the real Coordinator runtime.
- [ ] 3.6 Ensure Coordinator runtime identity is distinguishable from workspace Agent Mode sessions in state, logs, tool policy, and UI-facing metadata.

## 4. Coordinator scope and permissions

- [ ] 4.1 Implement the accepted first listing/control scope from section 1, with active-workspace top-level as the leading default unless review chooses a stricter or broader scope.
- [ ] 4.2 Restrict the first Coordinator role toolset to lifecycle/control-plane capabilities: session/model listing, start/spawn, poll/status/wait, message/steer, and summarize/export through artifact refs.
- [ ] 4.3 Keep Coordinator access to `respond` unavailable until pending-interaction shape, authorization, and failure semantics are accepted; if accepted, audit it as a structured directive.
- [ ] 4.4 Block direct tab focus, tab-scoped file read/search, file-selection mutation, worktree mutation, approval/decline, cancel, stop, and full-log read unless a later spec grants Coordinator access.
- [ ] 4.5 Enforce the boundary through MCP/Agent Mode tool policy and advertisement, not just prompts or model instructions.
- [ ] 4.6 Define and test the Coordinator v1 allow/deny matrix for CLI-adjacent tools: allow lifecycle listing/start/poll/wait/steer/summarize, gate respond/cancel, and block tab focus, file/search/edit, selection, and worktree mutation.
- [ ] 4.7 Ensure requests requiring direct workspace investigation or mutation are routed to delegated Agent Mode sessions rather than handled by Coordinator tools directly.
- [ ] 4.8 Record the cross-window stance for Coordinator actions: current-window-only, route to owning windows, or shared session-control service.
- [ ] 4.9 Add focused permission tests for allowed lifecycle tools and blocked tab/workspace mutation tools.

## 5. Coordinator context and history

- [ ] 5.1 Implement the accepted Coordinator history/directive-log storage location outside workspace row projection.
- [ ] 5.2 Restore Coordinator context without creating, restoring, or promoting a supervised workspace session.
- [ ] 5.3 Add tests for history persistence/restoration and board/list invisibility.

## 6. Directive contract

- [ ] 6.1 Define the structured Coordinator directive record with source, target, action type, lifecycle handle, status, and failure fields.
- [ ] 6.2 Implement the initial directive verbs: list, start/spawn, poll/wait, message/steer, and summarize/export.
- [ ] 6.3 Surface directive delivery/completion/failure states from native lifecycle state, pending interactions, and artifact refs without parsing assistant prose.
- [ ] 6.4 Add tests for successful directives, failed delivery, terminal/actionable transitions, and unsupported higher-risk actions.

## 7. Coordinator view integration

- [ ] 7.1 Reconcile the real Coordinator runtime with existing `CoordinatorModeSnapshotProjector` demo Coordinator detection.
- [ ] 7.2 Define the identity/exclusion predicate that keeps the real Coordinator runtime out of `CoordinatorModeSnapshot.groups`.
- [ ] 7.3 Wire Coordinator mode to show or address the real Coordinator runtime when available while preserving the existing manual selected-session composer as a demo/manual fallback until migration is decided.
- [ ] 7.4 Decide whether to retire, hide, or keep the manual selected-session composer after the real role is stable.
- [ ] 7.5 Add UI/snapshot coverage for no Coordinator runtime, real Coordinator runtime available, manual fallback states, and board/list invisibility.

## 8. Feature boundary and validation

- [ ] 8.1 Implement the lifecycle contract and Coordinator role behind a feature boundary or guarded availability path so rollback leaves existing Coordinator mode behavior intact.
- [ ] 8.2 Run `openspec validate add-coordinator-role` after each spec/design change.
- [ ] 8.3 Run focused role/scope/directive/lifecycle tests added by this implementation.
- [ ] 8.4 Run the smallest relevant coordinated Swift build/test lanes for touched app/MCP files.
- [ ] 8.5 Follow `docs/testing.md` contract-ledger and authoritative XCTest-list workflow when adding, renaming, consolidating, or removing tests.
- [ ] 8.6 Run contribution preflight before commit and push.
