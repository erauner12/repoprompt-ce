## 1. Design confirmation

- [ ] 1.1 Record the accepted direction that Coordinator is a first-class role backed by a native RepoPrompt Agent run/session lifecycle contract, with MCP `agent_run` / `agent_manage` as adapters and delegate-only v1 scope.
- [ ] 1.2 Decide the first Coordinator listing/control scope: active-workspace top-level, explicitly attached sessions, or app-global; keep app-global deferred unless cross-window ownership semantics are accepted.
- [ ] 1.3 Review the narrowed design with wren, using delegate-vs-focus, lifecycle-contract-vs-MCP-schema, active-workspace-top-level-vs-global, and current-window-vs-cross-window as the explicit discussion forks.
- [ ] 1.4 Update the spec/design with any accepted review changes before implementation begins.

## 2. Native Agent run/session lifecycle contract

- [ ] 2.1 Define the stable run/session handle model that Coordinator and external callers use for start, observe, steer, and summarize/export behavior.
- [ ] 2.2 Define deterministic lifecycle status categories sufficient for Coordinator decisions: active work, actionable input-required work, and terminal work.
- [ ] 2.3 Define terminal outcome semantics for completed, failed, and cancelled; preserve or map existing expired semantics only if supported by the runtime.
- [ ] 2.4 Define pending-interaction metadata sufficient to surface actionable state; defer response-by-interaction-ID requirements until Coordinator `respond` access is accepted.
- [ ] 2.5 Keep `cancel` semantics as an underlying lifecycle concern, but require only clean gating/rejection for Coordinator v1 unless cancel access is explicitly accepted.
- [ ] 2.6 Define durable artifact references or compact diagnostic fields for summaries, compact supervision outputs, and bounded failure diagnostics; leave full logs, full transcripts, exported context, and worktree metadata gated or optional unless later Coordinator behavior requires them.
- [ ] 2.7 Add public contract tests for caller-visible start, poll/status, wait, steer with wait semantics, lifecycle category/outcome, summary/failure artifact references, and clean rejection/gating for unsupported Coordinator operations.

## 3. MCP adapter and role identity

- [ ] 3.1 Map existing MCP adapter operations needed for Coordinator v1 to the native lifecycle contract: `agent_run.start`, `poll`, `wait`, `steer`; `agent_manage.list_agents`, `list_sessions`, and summary/export-like behavior. Keep `respond`, `cancel`, and full-log access gated unless explicitly accepted.
- [ ] 3.2 Identify where current `agent_run` / `agent_manage` behavior is window, workspace, tab, or child scoped and cannot satisfy Coordinator scope.
- [ ] 3.3 Implement or specify the explicit Coordinator binding, adapter scope, or native lifecycle surface required for the accepted listing/control scope.
- [ ] 3.4 Add or reserve the `coordinator` role identity alongside existing role labels without changing default `pair`, `engineer`, `explore`, or `design` behavior.
- [ ] 3.5 Guard against the role-label trap: adding `coordinator` as a label must not by itself create an ordinary tab-backed session that is treated as the real Coordinator runtime.
- [ ] 3.6 Ensure Coordinator runtime identity is distinguishable from workspace Agent Mode sessions in state, logs, tool policy, and UI-facing metadata.

## 4. Coordinator role behavior and prompt contract

- [ ] 4.1 Define the Coordinator-specific runtime prompt/instructions so the role classifies user input as conversational/status/advisory, coordination instruction, or workspace/code work request before acting.
- [ ] 4.2 Ensure conversational/status/advisory input can be answered directly from Coordinator-visible lifecycle state, action records, summaries, bounded failure diagnostics, artifact references, and conversation history without spawning or steering another agent.
- [ ] 4.3 Ensure coordination instructions use lifecycle/control APIs and structured action records.
- [ ] 4.4 Ensure workspace/code work requests are delegated to appropriately scoped Agent Mode sessions rather than handled through Coordinator tools directly.
- [ ] 4.5 Add deterministic prompt assembly or routing/classification tests where possible; avoid brittle assertions on model-generated natural-language output.

## 5. Coordinator scope and permissions

- [ ] 5.1 Implement the accepted first listing/control scope from section 1, with active-workspace top-level as the leading default unless review chooses a stricter or broader scope.
- [ ] 5.2 Restrict the first Coordinator role toolset to lifecycle/control-plane capabilities: session/model listing, start/spawn, poll/status/wait, message/steer, and summarize/export through artifact references.
- [ ] 5.3 Keep Coordinator access to `respond` unavailable until pending-interaction shape, authorization, and failure semantics are accepted; if accepted, audit it as a structured action record.
- [ ] 5.4 Block direct tab focus, tab-scoped file read/search, file-selection mutation, worktree mutation, approval/decline, cancel, stop, and unbounded full-log/full-transcript read unless a later spec grants Coordinator access.
- [ ] 5.5 Enforce the boundary through MCP/Agent Mode tool policy and advertisement, not just prompts or model instructions.
- [ ] 5.6 Define and test the Coordinator v1 allow/deny matrix for CLI-adjacent tools: allow lifecycle listing/start/poll/wait/steer/summarize, gate respond/cancel, and block tab focus, file/search/edit, selection, and worktree mutation.
- [ ] 5.7 Ensure requests requiring direct workspace investigation or mutation are routed to delegated Agent Mode sessions rather than handled by Coordinator tools directly.
- [ ] 5.8 Record the cross-window stance for Coordinator actions: current-window-only, route to owning windows, or shared session-control service.
- [ ] 5.9 Add focused permission tests for allowed lifecycle tools and blocked tab/workspace mutation tools.

## 6. Coordinator context and history

- [ ] 6.1 Implement the accepted Coordinator history/action-log storage location outside workspace row projection.
- [ ] 6.2 Restore Coordinator context without creating, restoring, or promoting a supervised workspace session.
- [ ] 6.3 Add tests for history persistence/restoration and board/list invisibility.

## 7. Instruction/action audit contract

- [ ] 7.1 Define the structured Coordinator action record with source, target, action type, lifecycle handle, status, and failure fields.
- [ ] 7.2 Implement the initial action verbs: list, start/spawn, poll/wait, message/steer, and summarize/export.
- [ ] 7.3 Surface action delivery/completion/failure states from native lifecycle state, pending interactions, bounded failure diagnostics, and artifact references without parsing assistant prose.
- [ ] 7.4 Support instructions that create one delegated run, sequential delegated runs, or multiple concurrent delegated runs by tracking each delegated run handle and action status separately.
- [ ] 7.5 Ensure Coordinator v1 remains human-directed: observed session lifecycle changes may update sourced status/summaries, but must not trigger new higher-level directives without a later accepted autonomy spec.
- [ ] 7.6 Add tests for successful actions, failed delivery, terminal/actionable transitions, sequential and concurrent delegated-run tracking, no-autonomous-dispatch from background session changes, and unsupported higher-risk actions.

## 8. Coordinator view integration

- [ ] 8.1 Reconcile the real Coordinator runtime with existing `CoordinatorModeSnapshotProjector` demo Coordinator detection.
- [ ] 8.2 Define the identity/exclusion predicate that keeps the real Coordinator runtime out of `CoordinatorModeSnapshot.groups`.
- [ ] 8.3 Wire Coordinator mode to show or address the real Coordinator runtime when available while preserving the existing manual selected-session composer as a demo/manual fallback until migration is decided.
- [ ] 8.4 Decide whether to retire, hide, or keep the manual selected-session composer after the real role is stable.
- [ ] 8.5 Add UI/snapshot coverage for no Coordinator runtime, real Coordinator runtime available, manual fallback states, and board/list invisibility.

## 9. Feature boundary and validation

- [ ] 9.1 Implement the lifecycle contract and Coordinator role behind a feature boundary or guarded availability path so rollback leaves existing Coordinator mode behavior intact.
- [ ] 9.2 Run `openspec validate add-coordinator-role` after each spec/design change.
- [ ] 9.3 Run focused role/scope/action/lifecycle tests added by this implementation.
- [ ] 9.4 Run the smallest relevant coordinated Swift build/test lanes for touched app/MCP files.
- [ ] 9.5 Follow `docs/testing.md` contract-ledger and authoritative XCTest-list workflow when adding, renaming, consolidating, or removing tests.
- [ ] 9.6 Run contribution preflight before commit and push.
