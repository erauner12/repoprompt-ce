## 1. Design confirmation

- [ ] 1.1 Record the accepted direction that Coordinator is a constrained top-level orchestrator runtime using existing `agent_run` / `agent_manage` lifecycle/control surfaces with delegate-only v1 scope.
- [ ] 1.2 Decide whether to accept the leading ownership recommendation: per-window Coordinator runtime, lazy creation on first real Coordinator instruction, persisted/restored with the Coordinator marker.
- [ ] 1.3 Confirm that the Coordinator still resolves to a concrete provider/model selection while its Coordinator identity marker remains separate from ordinary task-label role selection.
- [ ] 1.4 Review the narrowed design with wren, using delegate-vs-focus, runtime ownership, list-session scope, execution policy, op/arg guard, and projection marker seams as the explicit discussion forks.
- [ ] 1.5 Update the spec/design with any accepted review changes before implementation begins.

## 1A. Privilege plumbing prework

- [ ] 1A.1 Refactor the run-lease / connection-policy installer from the current many-positional-argument closure into a named policy context struct or equivalent typed context without behavior changes.
- [ ] 1A.2 Migrate existing callers to the named policy context before adding Coordinator privilege fields.
- [ ] 1A.3 Add focused no-behavior-change coverage or review checks proving ordinary Agent Mode runs retain their existing restricted tools, additional tools, task label, external-control, and expected-PID policy behavior.

## 2. Existing Agent run/session lifecycle surfaces

- [ ] 2.1 Verify the Coordinator v1 flow can reuse existing `agent_run.start`, `poll`, `wait`, and `steer` behavior without requiring a new native lifecycle subsystem.
- [ ] 2.2 Map Coordinator active/actionable/terminal categories to existing Agent Mode and MCP-facing state vocabulary, including expired handles as terminal/untrackable outcomes.
- [ ] 2.3 Use existing structured pending-interaction metadata to surface actionable state; keep Coordinator `respond` authorization and stale-interaction failure semantics deferred unless accepted.
- [ ] 2.4 Use existing terminal output, status text, failure reason, and compact failure diagnostics for Coordinator failure explanation and rollups.
- [ ] 2.5 Add only Coordinator-delta contract tests: lifecycle category mapping, expired-handle handling, status/failure diagnostics, and clean gating for unsupported Coordinator operations.
- [ ] 2.6 If implementation exposes duplicated MCP-specific parsing or `Value`-level coupling, file a follow-up for typed native facade extraction instead of making it a first Coordinator prerequisite.

## 3. Coordinator runtime identity, ownership, and launch

- [ ] 3.1 Define the runtime ownership unit, with per-window lazy creation as the preferred first implementation unless a concrete alternative is accepted.
- [ ] 3.2 Define lazy vs eager runtime creation and restore semantics for the chosen owner, including whether persisted-only Coordinator state is hydrated or leaves the composer disabled until live.
- [ ] 3.3 Implement or specify a dedicated Coordinator launch path or additional runtime marker; do not rely solely on adding `coordinator` to `AgentModelCatalog.TaskLabelKind`, task labels, or candidate chains.
- [ ] 3.4 Ensure Coordinator runtime identity is distinguishable from workspace Agent Mode sessions in state, logs, tool policy, restore metadata, and UI-facing metadata.
- [ ] 3.5 Ensure the identity marker is threaded through run lease / connection policy / tool policy seams before Coordinator scope or permissions are granted.

## 4. Coordinator role behavior and prompt contract

- [ ] 4.1 Define the Coordinator-specific runtime prompt/instructions so the role classifies user input as conversational/status/advisory, coordination instruction, or workspace/code work request before acting.
- [ ] 4.2 Ensure conversational/status/advisory input can be answered directly from Coordinator-visible lifecycle state, action records, terminal output, status text, compact failure diagnostics, and conversation history without spawning or steering another agent.
- [ ] 4.3 Ensure coordination instructions use lifecycle/control APIs and structured action records.
- [ ] 4.4 Ensure workspace/code work requests are delegated to appropriately scoped Agent Mode sessions rather than handled through Coordinator tools directly.
- [ ] 4.5 Teach the Coordinator prompt to continue polling or waiting on remaining delegated run handles after a multi-session wait returns the first actionable/terminal run, so detached sibling runs are not left unattended.
- [ ] 4.6 Add deterministic prompt assembly or routing/classification tests where possible; avoid brittle assertions on model-generated natural-language output.

## 5. Coordinator scope and permissions

- [ ] 5.1 Implement current-window active-workspace fleet visibility for the Coordinator runtime, including delegated child sessions that are part of the supervised fleet.
- [ ] 5.2 Bypass ordinary child-only `agent_manage.list_sessions` scoping for Coordinator connections so the model-visible fleet has membership parity with the Coordinator view's active-workspace projection, excluding ordering, pagination, transient liveness differences, and the Coordinator runtime itself.
- [ ] 5.3 Restrict the first Coordinator role toolset to lifecycle/control-plane capabilities: session/model listing, start/spawn, poll/status/wait, message/steer, and status/failure reporting from existing snapshot fields.
- [ ] 5.4 Keep Coordinator access to `respond` unavailable until authorization and stale-interaction failure semantics are accepted; if accepted, audit it as a structured action record.
- [ ] 5.5 Block direct tab focus, tab-scoped file read/search, file-selection mutation, worktree mutation, approval/decline, cancel, stop, and unbounded full-log/full-transcript read unless a later spec grants Coordinator access.
- [ ] 5.6 Hide blocked whole tools from Coordinator tool-list advertisement.
- [ ] 5.7 Enforce blocked whole tools at execution time for Coordinator connections, because hidden tools remain callable by name.
- [ ] 5.8 Enforce op/arg-level boundaries inside `agent_run` / `agent_manage` dispatch for Coordinator connections, including `respond`, `cancel`, `stop_session`, `cleanup_sessions`, and worktree creation/binding args on `agent_run.start`.
- [ ] 5.9 Ensure requests requiring direct workspace investigation or mutation are routed to delegated Agent Mode sessions rather than handled by Coordinator tools directly.
- [ ] 5.10 Add focused permission tests for allowed lifecycle tools, Coordinator-specific list scope, rejected op/arg-level actions, execution-blocked whole tools, and blocked tab/workspace mutation tools.
- [ ] 5.11 Add membership-parity fixture coverage proving Coordinator list scope and Coordinator view projection include the same active-workspace sessions, including supervised child sessions and excluding ordering, pagination, transient liveness differences, and the Coordinator runtime itself.

## 6. Coordinator context, history, and enumeration invisibility

- [ ] 6.1 Decide whether Coordinator conversation/history/action logs reuse Agent session persistence or a separate store; do not make separate storage a prerequisite if enumeration invisibility is satisfied.
- [ ] 6.2 Exclude Coordinator-marked runtimes at shared supervised-session enumeration inputs, not ad hoc in leaf views.
- [ ] 6.3 Ensure the Coordinator runtime is absent from Coordinator mode groups, Agent Mode sidebar/session lists, and MCP `list_sessions` output.
- [ ] 6.4 Restore Coordinator context with its identity marker intact and without creating, restoring, or promoting a supervised workspace row in any enumeration surface.
- [ ] 6.5 Add tests for persistence/restoration behavior and Coordinator invisibility across board/list, sidebar/session list, and MCP session list surfaces.

## 7. Instruction/action audit contract

- [ ] 7.1 Define the structured Coordinator action record with source, target, action type, lifecycle handle, status, and failure fields; start by projecting from existing Coordinator transcript tool-call items if that satisfies v1 audit needs.
- [ ] 7.2 Implement the initial action verbs: list, start/spawn, poll/wait, message/steer, and report status/failure.
- [ ] 7.3 Surface action delivery/completion/failure states from structured lifecycle state, pending interactions, terminal output, status text, and compact failure diagnostics without parsing assistant prose.
- [ ] 7.4 Support instructions that create one delegated run, sequential delegated runs, or multiple concurrent delegated runs by tracking each delegated run handle and action status separately.
- [ ] 7.5 Ensure Coordinator v1 remains human-directed: observed session lifecycle changes may update sourced status/failure fields, but must not trigger new higher-level directives without a later accepted autonomy spec.
- [ ] 7.6 Add tests for successful actions, failed delivery, terminal/actionable transitions, sequential and concurrent delegated-run tracking, no-autonomous-dispatch from background session changes, and unsupported higher-risk actions.

## 8. Coordinator view integration and instruction delivery

- [ ] 8.1 Reconcile the real Coordinator runtime with existing `CoordinatorModeSnapshotProjector` demo Coordinator detection.
- [ ] 8.2 Define the identity/exclusion predicate that keeps the real Coordinator runtime out of all supervised-session enumeration surfaces.
- [ ] 8.3 Define the human-to-Coordinator instruction delivery path for the real runtime; do not rely on the selected-session demo composer as the final architecture.
- [ ] 8.4 Define precedence and labeling when both real Coordinator runtime and manual selected-session fallback are available.
- [ ] 8.5 Wire Coordinator mode to show or address the real Coordinator runtime when available while preserving the existing manual selected-session composer as a demo/manual fallback until migration is decided.
- [ ] 8.6 Decide whether to retire, hide, or keep the manual selected-session composer after the real role is stable.
- [ ] 8.7 Add UI/snapshot coverage for no Coordinator runtime, real Coordinator runtime available, manual fallback states, instruction delivery precedence, and supervised-session enumeration invisibility.

## 9. Feature boundary and validation

- [ ] 9.1 Implement the Coordinator role behind a feature boundary or guarded availability path so rollback leaves existing Coordinator mode behavior intact.
- [ ] 9.2 Run `openspec validate add-coordinator-role` after each spec/design change.
- [ ] 9.3 Run focused role/scope/action/lifecycle tests added by this implementation.
- [ ] 9.4 Run the smallest relevant coordinated Swift build/test lanes for touched app/MCP files.
- [ ] 9.5 Follow `docs/testing.md` contract-ledger and authoritative XCTest-list workflow when adding, renaming, consolidating, or removing tests.
- [ ] 9.6 Run contribution preflight before commit and push.
