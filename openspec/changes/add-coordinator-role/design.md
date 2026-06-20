## Context

RepoPrompt CE now has a Coordinator mode surface that can supervise active-workspace Agent Mode sessions through board/list projection, rail context, inspector summaries, and a scoped composer. That surface is intentionally Layer 1: it can target a user-selected live Agent Mode session and send ordinary user messages, but the selected session is still part of the workspace fleet.

The real Coordinator role is a different architectural object. It should be a layer-above meta-agent that supervises workspace sessions without being projected as one of them. pvncher's notes frame this as a new `coordinator` role with broader/top-level session visibility than `pair`, `engineer`, `explore`, or `design`. He also called out the core tool-design fork: the Coordinator could focus tabs and inherit scoped file/search tools, or it could avoid tab focus and talk to agents that already own their scopes. This design chooses the delegate-only direction for the first implementation.

The key product boundary is: agent/model text is output; Agent run/session state is the RepoPrompt control plane. Coordinator and external callers should not infer completion, blockers, or deliverables from assistant prose when RepoPrompt can expose deterministic lifecycle state.

Important existing anchors:

- `openspec/changes/add-coordinator-mode/design.md`: current Coordinator view/composer design and v1 non-goals.
- `openspec/changes/add-coordinator-mode/end-state.md`: later action/directive layers and cross-window Option A/B/C fork.
- `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModelCatalog.swift`: existing `explore`, `engineer`, `pair`, and `design` task-label registry.
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentManageMCPToolService.swift`: current MCP `agent_manage` adapter and session listing behavior.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentModeMCPPolicyInstaller.swift` and `AgentModeRunLease.swift`: current run-lease / connection-policy installer path that carries tool policy and external-control fields.
- `Sources/RepoPrompt/Infrastructure/MCP/Policies/AgentModeMCPToolPolicy.swift`: current tab-scoped Agent Mode policy.
- `Sources/RepoPrompt/Infrastructure/MCP/MCPBindingResolver.swift`: context binding and ambiguity handling.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/CoordinatorModeViewModel.swift`: current selected-session demo composer.
- `Sources/RepoPrompt/Features/AgentMode/Services/CoordinatorModeSnapshotProjector.swift`: current workspace session projection and demo Coordinator detection.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeSidebarSessionBuilder.swift`: Agent Mode sidebar/session-list projection fed by `sessionIndex`.
- `openspec/changes/add-coordinator-role/reference/coordinator-runtime-separability.md`: separability spike explaining why Coordinator v1 uses a marked `TabSession` instead of a non-enrolled provider runtime.

## Glossary

- **Coordinator mode/view**: the human-facing control-plane surface from `add-coordinator-mode`.
- **Demo Coordinator session**: an ordinary selected or auto-detected Agent Mode session used by the current scoped composer.
- **Coordinator role/runtime**: the new layer-above meta-agent identity defined by this change.
- **Agent run/session lifecycle surface**: the existing `agent_run` / `agent_manage` control surface and structured snapshots used for starting, observing, waiting on, steering, and reporting run status/failure.
- **Native lifecycle facade**: a possible follow-up extraction of typed lifecycle/control helpers out of MCP tool services; not a prerequisite for Coordinator v1.

## Goals / Non-Goals

### Durable invariants vs v1 lines

Durable invariants: the Coordinator must not be part of the supervised fleet it controls, and Coordinator-visible state must come from structured lifecycle/action records rather than assistant prose. The delegate-only toolset, per-window/lazy ownership recommendation, snapshot-field reporting surface, and deferred `respond`/cancel/autonomy capabilities are v1 scope lines that may be relaxed by later accepted specs without weakening those invariants.

**Goals:**

- Define the first real Coordinator role as a layer-above meta-agent, not a workspace session/card.
- Reuse existing `agent_run` / `agent_manage` lifecycle/control behavior for Coordinator v1 delegation.
- Identify any later native lifecycle facade extraction as cleanup, not as a first Coordinator role prerequisite.
- Give the first Coordinator role a delegate-only tool boundary: observe/list sessions, spawn agents, poll/wait deterministic state, steer/message agents, and report status/failure from existing snapshot fields.
- Let Coordinator v1 supervise its own launched delegated fleet through lifecycle handles returned by `agent_run.start`, without requiring broadened active-workspace `list_sessions` visibility.
- Keep Coordinator runtime state out of all session-enumerating supervised-session surfaces, including Coordinator mode groups, Agent Mode sidebar/session lists, and MCP session lists.
- Define auditable Coordinator action records for v1 instructions before adding higher-level directive/autonomy behavior.
- Preserve the existing manual selected-session composer as a demo shim until the real role replaces or supersedes it.

**Non-Goals:**

- Implementing the role in this OpenSpec change.
- Granting the first Coordinator role direct tab focus, file reads/searches scoped to focused tabs, file-selection mutation, or worktree mutation.
- Replacing Agent Mode as the canonical deep-work surface.
- Making the Coordinator board/list a full transcript, log, file, or diff viewer.
- Extracting a broad native lifecycle/provenance platform before the first Coordinator role proves it needs one.
- Building a non-enrolled Coordinator runtime that still uses the existing `agent_run.start` path. The separability spike shows that path either needs a larger runtime registry/context-provider extraction or recreates enough compose-tab/session state to become a marked `TabSession` in practice.
- Hiding a normal workspace session row after using it as Coordinator. The real role should not be projected into the workspace fleet in the first place.
- Defining broad autonomous directive behavior without explicit directive classes, authorization rules, and failure semantics.

## Decisions

### 1. Coordinator is a meta-agent identity, not row state

The Coordinator role is a runtime identity above the workspace fleet. The Coordinator view remains the human-facing observation/control plane over workspace Agent Mode sessions. The role may consume and produce Coordinator-view state later, but its own runtime identity is separate from board/list row projection.

Decision 1 now rests on the separability spike in `openspec/changes/add-coordinator-role/reference/coordinator-runtime-separability.md`. The cleaner alternative was a Coordinator-owned provider runtime outside the tab/session model, which would avoid projection exclusion entirely. That alternative is rejected for v1 because provider start, transcript persistence, file/worktree context assembly, terminal-commit publication, and loopback `agent_run` routing all key off the compose-tab-to-Agent-session binding. A non-enrolled runtime cannot drive a Coordinator-representative turn through the existing run path without a larger runtime registry/context-provider extraction.

Coordinator v1 therefore reuses the existing run path through a marked/background Agent `TabSession`. `AgentModeRunService.startRun` remains a possible future extraction seam, but pulling on that seam is explicitly out of v1 scope; if implementation starts requiring `startRun`-level runtime extraction, the work should stop and be re-scoped instead of becoming a creeping refactor.

Adding a `coordinator` task label alongside `pair`, `engineer`, `explore`, and `design` is still the wrong default seam because `AgentMCPSelectionResolver`, `AgentModelCatalog.taskLabels`, and candidate chains currently mean “spawn an ordinary selectable Agent Mode role.” The real Coordinator needs a dedicated launch path or additional runtime marker before it receives Coordinator scope and policy. A plain task-label addition that starts an ordinary tab-backed, window-scoped Agent Mode session must not be treated as the real Coordinator runtime.

Alternatives considered:

- **Reuse manual selected session as the Coordinator role:** rejected because it makes the supervisor part of the supervised fleet.
- **Filter the Coordinator card out of the board:** rejected because it treats a modeling error as a UI problem.
- **Plain task-label-only Coordinator:** rejected because it risks creating the wrong layer: a normal tab-scoped agent with a new label.
- **Provider runtime outside the tab/session model:** rejected for v1 because the existing provider/run path depends on compose-tab-to-Agent-session binding across provider start, transcript persistence, file/worktree context assembly, terminal commit publication, and loopback `agent_run` routing.

### 2. Existing Agent run/session lifecycle surfaces are enough for v1

Coordinator v1 should be framed as a constrained in-app top-level orchestrator session that uses the existing `agent_run` / `agent_manage` lifecycle/control surfaces, not as a new native lifecycle subsystem. The reusable structured snapshot already exists in `AgentRunMCPSnapshot`; the main missing native seam is a possible typed facade around control verbs currently embedded in `AgentRunMCPToolService` and `AgentManageMCPToolService`.

The first Coordinator role needs only the lifecycle pieces already present or narrowly exposed through those surfaces:

- stable run/session handles;
- deterministic lifecycle status sufficient for Coordinator decisions;
- active/actionable/terminal status classification;
- pending-interaction metadata sufficient to surface actionable state;
- terminal output, status text, failure reason, and compact failure diagnostics for failure explanation and rollups.

`respond`, `cancel`, full logs, full transcripts, exported context, worktree metadata, and broader artifact shapes may exist in the underlying MCP adapters, but Coordinator v1 should not require full design of those surfaces unless the accepted first toolset grants access. Compact failure diagnostics are in scope so the Coordinator can explain delegated run failures without becoming a full log viewer. A native lifecycle facade may be proposed later if implementation shows duplicated MCP-specific parsing or `Value`-level coupling, but it should not block the first Coordinator role.

Coordinator needs functional state categories more than a final universal enum:

- **Active:** work that has been accepted and is waiting to start or already in progress.
- **Actionable:** work waiting for structured input from the user or Coordinator.
- **Terminal:** work that ended with a structured outcome.

Existing RepoPrompt vocabulary to preserve or map from:

- Internal Agent Mode run states include `running`, `waitingForUser`, `waitingForQuestion`, `waitingForApproval`, `completed`, `cancelled`, and `failed`.
- MCP-facing snapshot statuses include `running`, `waiting_for_input`, `completed`, `failed`, `cancelled`, and `expired`.

Coordinator should preserve these semantic categories rather than introduce unrelated new state names. The internal waiting states may collapse to a Coordinator-facing `waiting_for_input` / actionable category when the specific pending interaction shape carries the detail. Additional outcomes should be added only when the runtime has concrete semantics for them.

Coordinator actions, future directives, and external integrations should derive state from structured snapshots and action records instead of parsing assistant prose.

Alternatives considered:

- **Native facade first:** deferred because Coordinator v1 can reuse existing `agent_run` / `agent_manage` semantics; facade extraction is cleanup unless the current surfaces cannot support the role.
- **Assistant prose as status:** rejected because completion, failure, and pending interactions need deterministic state.

### 3. Delegate-only is the first Coordinator capability boundary

The first Coordinator role should list sessions, inspect compact metadata, spawn agents, poll/wait run state, steer/message agents, and report status/failure from existing snapshot fields such as terminal output, status text, and failure reason. It should not directly focus tabs, read files through tab-scoped tools, mutate file selections, or control worktrees.

Rationale: delegate-only matches pvncher's “maybe coordinator doesnt focus tabs at all, and just talks to agents who do” direction. It avoids the session/tab/file-selection/worktree coupling that makes current in-app agents tab-scoped. Agents that need deep project context can focus/read/search in their own scoped sessions; the Coordinator coordinates them.

Coordinator v1 allowed verbs should map to existing lifecycle/control operations as:

- `list` / `observe`: enumerate visible sessions, models, compact status, and lifecycle metadata.
- `start` / `spawn`: create a delegated Agent run/session.
- `poll` / `status` / `wait`: observe deterministic lifecycle categories and terminal/actionable transitions.
- `steer` / `message`: send follow-up work to an existing delegated session.
- `report` / `explain`: describe visible status and failure using lifecycle state, terminal output, status text, and failure reason without loading full transcripts or requiring a compact-summary artifact.

A single user instruction may produce one delegated run, sequential delegated runs, or multiple concurrent delegated runs when the work naturally splits into independent items. The Coordinator should track each delegated run handle and action status separately, then report combined outcomes from lifecycle state, action records, terminal output, status text, and compact failure diagnostics. When a multi-session wait returns the first actionable or terminal run, the Coordinator prompt must teach the wait-winner-then-wait-remaining loop so detached sibling runs are not stranded.

The existing lifecycle/control surfaces include `respond` and `cancel`, but Coordinator v1 should expose only the safe delegate subset until each higher-risk action has accepted authorization and failure semantics. Coordinator access to `respond`, `cancel`, approve/decline, worktree mutation, tab focus, full log read, and direct file/search capabilities remains deferred or gated.

Alternatives considered:

- **Focus-tabs first:** deferred because it forces the Coordinator into the most coupled part of the app before the role identity and permission model are stable.
- **Full app-user capability:** rejected for v1 because it is too broad to audit or validate.

### 4. Coordinator v1 can supervise its own launched fleet without broadened listing

The existing external lifecycle is close to the desired Coordinator runtime: a parent-less MCP-controlled top-level Agent Mode session can already use `agent_run.start`, `poll`, `wait`, `steer`, and `agent_manage` through loopback MCP, and child sessions do not recursively receive external-control tools. Multi-run delegation can reuse `start(detach: true)`, returned session handles, `wait`/`poll` with multiple session IDs, and the wait-winner-then-wait-remaining pattern already documented for orchestration.

Coordinator v1 does not need broadened active-workspace `list_sessions` visibility to perform its core delegation loop. It can supervise the delegated fleet it launched because each `agent_run.start` response returns a stable `session_id`, and subsequent `poll`, `wait`, and `steer` calls can operate on those handles. Visibility into sessions the Coordinator did not spawn is useful, but it is a separate visibility-boundary capability specified by `add-coordinator-list-sessions-visibility` rather than a role prerequisite.

Cross-window control remains deferred. In this architecture, active-workspace scope is effectively current-window active-workspace scope; app-global behavior should not appear unless a later spec grants owning-window routing or a shared session-control service.

### 5. Runtime ownership and launch path are real implementation seams

The first implementation must choose whether the Coordinator runtime is owned per window, per workspace, or by another explicit unit. That choice controls visibility, restore, history, and how the Coordinator view addresses the runtime. The leading recommendation is per-window ownership with lazy creation on first real Coordinator instruction, because it matches the existing per-window Coordinator view model and avoids cross-window coordination that this spec defers.

The accepted v1 path should reuse the existing Agent Mode runtime machinery with a Coordinator identity marker rather than inventing a new provider/runtime stack. The Coordinator is still backed by a concrete provider/model selection; the marker is separate from the model-selection task label. Reuse is acceptable as long as the marker, launch path, prompt, scope, and policy distinguish the Coordinator from ordinary supervised Agent Mode sessions. The likely creation seam is the existing MCP background compose-tab path used for non-foreground Agent sessions, with the Coordinator marker attached, but implementation should confirm the exact `.mcpBackgroundAgent` / background-tab behavior before relying on it. Creation may be lazy on first instruction or eager when the Coordinator surface appears, but the choice must be explicit before UI integration. In the lazy case, first-instruction delivery and runtime creation are the same event.

### 6. Human-to-Coordinator instruction delivery must be explicit

The current selected-session composer path sends an ordinary user message to a live Agent Mode session. That is valid demo behavior, but it is not automatically the real Coordinator delivery path. Once the real runtime exists, the view/model needs an explicit addressing path to deliver user instructions to that runtime and a clear precedence rule when both a real runtime and manual fallback are available.

The Coordinator must also be able to issue accepted lifecycle/control actions from within its turn using its Coordinator-scoped tool policy. Delegated child runs should be created through the existing Agent run lifecycle/control surface and observed through lifecycle state rather than prose. If the real runtime exists only as persisted state or is not live in the current window, the accepted design must specify whether delivery hydrates that runtime or disables the composer until it is live. For concurrent delegated runs, the prompt must instruct the Coordinator to continue waiting or polling remaining run handles after the first run becomes actionable or terminal.

### 7. Coordinator prompt behavior classifies input before acting

The Coordinator needs a role-specific behavior contract, not only a new role label or tool set. Its prompt/instructions should tell it to classify user input before acting:

1. **Conversational/status/advisory input:** answer directly from Coordinator-visible lifecycle state, action records, terminal output, status text, compact failure diagnostics, and conversation history without spawning or steering another agent.
2. **Coordination instruction:** use lifecycle/control APIs to list, start/spawn, poll/wait, steer/message, or report delegated run status/failure from snapshot fields, recording structured action state.
3. **Workspace/code work request:** delegate to an appropriately scoped Agent Mode session because Coordinator v1 does not receive tab-scoped file/search/edit/worktree tools.

This prompt behavior prevents two failure modes: over-delegating every user message, and trying to perform workspace work directly. It complements, but does not replace, tool-policy enforcement.

### 8. Tool policy enforces delegate-only behavior

Delegate-only must be enforced by execution policy, not just by prompt wording or tool-list advertisement. The Coordinator runtime must not be able to execute tab-scoped file read/search, file-selection mutation, worktree mutation, approval/decline, cancel/stop, or tab-focus tools unless a later accepted spec grants Coordinator access with authorization and audit semantics.

The enforcement seam has two levels. Tool advertisement can hide whole tab-scoped tools such as file read/search/edit, selection, worktree, and focus tools from list output, but hidden tools remain callable if invoked by name. Coordinator therefore needs a Coordinator-specific execution restricted set for whole-tool blocking, plus op/arg guards in the `agent_run` / `agent_manage` dispatch path for disallowed operations such as `respond`, `cancel`, `stop_session`, `cleanup_sessions`, and worktree creation/binding arguments on `agent_run.start`.

Before threading the Coordinator privilege marker, the run-lease / connection-policy installer should be collapsed from the current many-positional-argument closure into a named policy context struct by the prerequisite `refactor-agent-mcp-policy-context` change. This is load-bearing privilege plumbing: adding a Coordinator flag as another positional argument would make a miswired call site compile while silently granting the wrong scope or tools.

#### Coordinator v1 tool boundary examples

| Capability | Coordinator v1 | Delegated Agent Mode session |
| --- | --- | --- |
| `agent_manage.list_agents` / `list_workflows` | Allowed for role/workflow discovery. | May also use when needed within its own scope. |
| `agent_manage.list_sessions` | Allowed only within the accepted v1 scope; broad active-workspace visibility into sessions the Coordinator did not spawn is deferred to a separate change. | Ordinary agents remain scoped to their spawned children where applicable. |
| `agent_run.start` | Allowed to spawn delegated agents. | Not recursive for sub-agents unless a later role explicitly allows it. |
| `agent_run.poll` / `wait` | Allowed to observe deterministic lifecycle state. | Allowed for sessions it owns or is scoped to. |
| `agent_run.steer` | Allowed to message/redirect delegated agents. | Allowed within the agent's own session scope. |
| `agent_run.respond` | Lifecycle-supported but Coordinator access gated until authorization/audit semantics are accepted. | Target agent or user-facing Agent Mode UI handles pending interactions today. |
| `agent_run.cancel`, `agent_manage.stop_session`, `cleanup_sessions` | Deferred/gated for Coordinator v1. | Existing UI/MCP paths keep their current semantics. |
| `agent_manage.get_log` / export-like surfaces | Not a default v1 Coordinator action. Coordinator v1 uses terminal output, status text, failure reason, and bounded diagnostics; full logs/transcripts remain gated. | Delegated agents may inspect deeper context when scoped to their task. |
| `bind_context`, tab focus, workspace/tab switching | Not allowed for Coordinator v1. | Delegated agents operate within their own bound tab/session scope. |
| `read_file`, `file_search`, `workspace_context`, `manage_selection` | Not allowed for Coordinator v1. | Delegated agents perform project reading/search/selection in their scoped context. |
| `apply_edits`, `file_actions` | Not allowed for Coordinator v1. | Delegated implementation agents make file changes when assigned that work. |
| `manage_worktree` mutation or `agent_run.start` worktree creation options | Deferred/gated for Coordinator v1. | Delegated agents may use task-scoped worktree context when permitted by existing policies. |

When the user's intent requires direct codebase investigation or mutation, the Coordinator should spawn or steer an appropriately scoped agent and then observe its lifecycle state and artifacts. It should not focus tabs or acquire file/worktree tools to do the work itself in v1.

### 9. Coordinator history may reuse persistence, but enumeration invisibility is mandatory

The Coordinator's own conversation/history/action log must be invisible to supervised-session enumeration. Storage does not have to be separate from `AgentSession` persistence if the runtime has a first-class Coordinator identity marker and is excluded from every supervised-session enumeration path.

The hard requirement is enumeration invisibility and lifecycle protection: restoring Coordinator state must retain the marker and must not create, restore, or promote the Coordinator as a supervised Agent Mode row in any workspace-session enumeration surface. Because the Coordinator is a marked `TabSession`, every current or future surface that walks `sessionIndex` or equivalent workspace-session state must exclude the Coordinator marker at the enumeration boundary. Coordinator mode, the Agent Mode sidebar/session list, and MCP `list_sessions` are examples, not an exhaustive list.

If Coordinator creation reuses background MCP Agent machinery, the marker must also prevent inappropriate background-agent lifecycle treatment. The Coordinator should not be silently reclaimed as a disposable background worker, nor targeted by incidental cleanup/stop sweeps that act on MCP-originated sessions, unless a later accepted spec defines explicit user authorization and recovery semantics. Re-creation on next instruction is acceptable only if it restores persisted Coordinator history/action state; otherwise it is silent context loss.

### 10. Instructions and actions are auditable; higher-level directives are deferred

The first Coordinator model should treat user input as instructions/messages and resulting control-plane work as structured action records. The initial action verbs are list, start/spawn, poll/wait, steer/message, and report status/failure. Each action record stores source, target, action type, lifecycle handle, status, and failure information. The first implementation may project action records from the Coordinator transcript's existing structured tool-call items (`toolName`, `toolArgsJSON`, `toolResultJSON`, `toolInvocationID`) before introducing a separate persistent action store. Higher-risk Coordinator operations such as respond, cancel/stop, approvals, worktree mutation, full log access, export, and tab focus remain deferred until their authorization and audit semantics are designed.

Coordinator v1 should feel like a human-directed command rail: the user gives an instruction, the Coordinator decomposes or delegates within the accepted tool boundary, and the user can observe deterministic state as delegated sessions progress. Goal-like directives that span multiple sessions or trigger follow-up work from observed session lifecycle changes are deferred to a later spec.

#### Deferred directive/autonomy examples

These examples document the boundary only. Coordinator v1 does not perform these follow-up actions autonomously.

| Observed condition | Coordinator v1 behavior | Later autonomy spec could allow |
| --- | --- | --- |
| Delegated agent completes | Update status from terminal output/status text and wait for user direction. | Summarize and start the next planned phase. |
| Delegated agent is blocked or waiting | Surface actionable state to the user. | Ask the user a targeted question or route a response if authorized. |
| Delegated agent reports failure | Record failed outcome and bounded failure diagnostics. | Spawn a fix or investigation agent. |
| Delegated agent appears stale or long-running | Surface stale/long-running state. | Request confirmation to cancel, restart, or reassign. |
| Work appears ready to integrate | Report completion from visible lifecycle/status fields. | Start a review, merge, or check workflow under explicit policy. |

Coordinator action status should derive from structured lifecycle state, pending-interaction records, terminal output, status text, and compact failure diagnostics. It should not depend on parsing assistant prose as the source of action truth.

This keeps the Coordinator role from becoming an ad hoc command box and aligns with the later Layer 2/3 direction already described by `add-coordinator-mode/end-state.md`.

### 11. Existing Coordinator mode detection remains demo-layer behavior until reconciled

The manual “Use as Coordinator” affordance and selected-session composer remain valid for demoing the current Coordinator view, but they are not the implementation path for the real Coordinator role. The future role may replace that composer target, coexist behind an explicit manual override, or remove the shim after migration.

`CoordinatorModeSnapshotProjector` currently detects a demo Coordinator from workspace sessions. The real Coordinator runtime must have a distinct identity marker and must be excluded at the shared workspace-session enumeration boundary so it never appears as a supervised row in any `sessionIndex`-derived UI, service, or MCP session list. `CoordinatorModeSnapshot.groups`, the Agent Mode sidebar/session list, and MCP `list_sessions` must use that shared predicate or an equivalent enumeration-boundary filter. This is an explicit identity predicate at enumeration inputs, not ad hoc filtering in leaf views.

### 12. Cross-window control is deferred unless explicitly chosen

Coordinator role implementation must not accidentally create an app-global cross-window control plane. The leading first scope is the Coordinator's own launched delegated fleet, tracked by lifecycle handles. Broader active-workspace visibility and cross-window action routing remain tied to later scope decisions, including the Option A/B/C fork in `add-coordinator-mode/end-state.md`:

- current-window control plane;
- route actions to owning windows;
- shared session-control service.

The first implementation should record its stance before enabling spawn/steer/respond behavior beyond the current window.

## Risks / Trade-offs

- **Native lifecycle scope creep** → Reuse existing lifecycle/control surfaces for v1; defer typed facade extraction unless implementation proves it is needed.
- **Role-label trap** → Do not equate a `coordinator` task label with the real Coordinator runtime unless launch path, identity marker, scope, policy, and projection semantics are also correct.
- **Privilege marker miswiring** → Depend on `refactor-agent-mcp-policy-context` so the run-lease / connection-policy installer uses a named context struct before Coordinator privilege state is threaded through it.
- **Existing MCP scope mismatch** → `agent_manage.list_sessions` child-scopes in-app agent callers. Coordinator v1 can still supervise its own launched fleet via returned lifecycle handles; broadened visibility into sessions it did not spawn should be handled by a separate visibility-boundary change.
- **Over-broad Coordinator power** → Start delegate-only and require a later spec before exposing tab focus, file access, worktree mutation, approval/respond/cancel actions, or app-global visibility to the Coordinator.
- **Hidden tool execution hole** → Do not rely on advertisement alone; enforce Coordinator's blocked whole tools at execution time.
- **Coordinator appears as a supervised session** → Use a first-class Coordinator identity marker and exclude it at the shared workspace-session enumeration boundary, with tests proving it never appears in generic `sessionIndex`-derived supervised enumerations rather than only in a few named leaf surfaces.
- **Coordinator inherits disposable background-agent lifecycle** → If creation reuses MCP background-agent capacity/persistence paths, ensure the Coordinator marker exempts it from inappropriate idle eviction, incidental cleanup, and incidental stop targeting unless explicitly authorized. Re-creation is acceptable only with persisted Coordinator history/action restoration.
- **Instruction vs directive ambiguity** → Treat the current composer as Layer 1/demo instructions/messages. Reserve goal-like directives for a later spec with explicit autonomy, authorization, and audit semantics.

## Migration Plan

1. Create and validate this OpenSpec change.
2. Record the accepted direction: Coordinator is a constrained top-level orchestrator runtime that reuses existing `agent_run` / `agent_manage` lifecycle/control surfaces with delegate-only v1 scope over its launched delegated fleet.
3. Review the narrowed design with wren using delegate-vs-focus, runtime ownership, list-session scope, execution policy, op/arg guard, and projection marker seams as the discussion spine.
4. Land `refactor-agent-mcp-policy-context` before adding Coordinator privilege fields.
5. Implement the Coordinator role behind a feature boundary while preserving existing Coordinator mode behavior.
6. Integrate the real role with Coordinator view/composer only after runtime ownership, instruction delivery, identity marker, scope, enumeration exclusion, and action records are stable.
7. Retire, hide, or keep the manual selected-session composer as an explicit demo/manual override based on the accepted migration decision.

Rollback for the first implementation should leave the existing Coordinator view and manual selected-session composer intact. The real role should be additive until it is proven stable.

## Open Questions

- Is the Coordinator runtime owned per window with lazy first-instruction creation as recommended here, or is there a concrete reason to choose another ownership/creation policy?
- What is the exact human-to-Coordinator instruction delivery path once the real runtime exists, and how does it take precedence over the manual selected-session fallback?
- If Coordinator creation reuses the MCP background compose-tab path, does the Coordinator marker exempt it from background-agent eviction/capacity cleanup, `cleanup_sessions`, and `stop_session` targeting, or is re-creation on next instruction accepted with persisted history/action restoration?
- Should `respond` be in the first action set once authorization and stale-interaction failure semantics are defined, or should it remain deferred with cancel/approval actions?
- Which dispatch-level guards are required in `agent_run` / `agent_manage` for Coordinator connections?
- What evidence would justify adding direct tab focus later?
