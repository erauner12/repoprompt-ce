## Context

RepoPrompt CE now has a Coordinator mode surface that can supervise active-workspace Agent Mode sessions through board/list projection, rail context, inspector summaries, and a scoped composer. That surface is intentionally Layer 1: it can target a user-selected live Agent Mode session and send ordinary user messages, but the selected session is still part of the workspace fleet.

The real Coordinator role is a different architectural object. It should be a layer-above meta-agent that supervises workspace sessions without being projected as one of them. pvncher's notes frame this as a new `coordinator` role with broader/top-level session visibility than `pair`, `engineer`, `explore`, or `design`. He also called out the core tool-design fork: the Coordinator could focus tabs and inherit scoped file/search tools, or it could avoid tab focus and talk to agents that already own their scopes. This design chooses the delegate-only direction for the first implementation.

The key product boundary is: agent/model text is output; Agent task/session state is the RepoPrompt control plane. Coordinator and external callers should not infer completion, blockers, or deliverables from assistant prose. They should query deterministic RepoPrompt task/session state and artifact references.

Important existing anchors:

- `openspec/changes/add-coordinator-mode/design.md`: current Coordinator view/composer design and v1 non-goals.
- `openspec/changes/add-coordinator-mode/end-state.md`: later action/directive layers and cross-window Option A/B/C fork.
- `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModelCatalog.swift`: existing `explore`, `engineer`, `pair`, and `design` task-label registry.
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentManageMCPToolService.swift`: current MCP `agent_manage` adapter and session listing behavior.
- `Sources/RepoPrompt/Infrastructure/MCP/Policies/AgentModeMCPToolPolicy.swift`: current tab-scoped Agent Mode policy.
- `Sources/RepoPrompt/Infrastructure/MCP/MCPBindingResolver.swift`: context binding and ambiguity handling.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/CoordinatorModeViewModel.swift`: current selected-session demo composer.
- `Sources/RepoPrompt/Features/AgentMode/Services/CoordinatorModeSnapshotProjector.swift`: current workspace session projection and demo Coordinator detection.

## Glossary

- **Coordinator mode/view**: the human-facing control-plane surface from `add-coordinator-mode`.
- **Demo Coordinator session**: an ordinary selected or auto-detected Agent Mode session used by the current scoped composer.
- **Coordinator role/runtime**: the new layer-above meta-agent identity defined by this change.
- **Agent task/session lifecycle contract**: the native RepoPrompt control-plane contract for starting, observing, steering, responding to, cancelling, and exporting task/session state.
- **MCP adapter**: the external `agent_run` / `agent_manage` tool schema that exposes parts of the native lifecycle contract to MCP callers.

## Goals / Non-Goals

**Goals:**

- Define the first real Coordinator role as a layer-above meta-agent, not a workspace session/card.
- Define a native RepoPrompt Agent task/session lifecycle contract underneath MCP tool schemas.
- Treat MCP `agent_run` and `agent_manage` as adapters/consumers of the native lifecycle contract, not as the only durable boundary.
- Give the first Coordinator role a delegate-only tool boundary: observe/list sessions, spawn agents, poll/wait deterministic state, steer/message agents, and summarize/export through artifact references.
- Give the Coordinator top-level active-workspace session visibility, or a stricter explicitly recorded scope, without applying ordinary child-only agent scoping.
- Keep Coordinator runtime state out of `CoordinatorModeSnapshot` workspace row groups by construction.
- Define auditable directive records before adding autonomy or broad mutation powers.
- Preserve the existing manual selected-session composer as a demo shim until the real role replaces or supersedes it.

**Non-Goals:**

- Implementing the role in this OpenSpec change.
- Granting the first Coordinator role direct tab focus, file reads/searches scoped to focused tabs, file-selection mutation, or worktree mutation.
- Replacing Agent Mode as the canonical deep-work surface.
- Making the Coordinator board/list a full transcript, log, file, or diff viewer.
- Treating MCP tool argument/result JSON as the durable source-of-truth contract instead of an adapter over native lifecycle state.
- Hiding a normal workspace session row after using it as Coordinator. The real role should not be projected into the workspace fleet in the first place.
- Defining broad autonomous behavior without explicit directive classes, authorization rules, and failure semantics.

## Decisions

### 1. Coordinator is a meta-agent identity, not row state

The Coordinator role is a runtime identity above the workspace fleet. The Coordinator view remains the human-facing observation/control plane over workspace Agent Mode sessions. The role may consume and produce Coordinator-view state later, but its own runtime identity is separate from board/list row projection.

Adding a `coordinator` role label alongside `pair`, `engineer`, `explore`, and `design` is necessary only if the accepted implementation needs a user/model-selection identity. It is not sufficient by itself. A plain task-label addition that starts an ordinary tab-backed, window-scoped Agent Mode session must not be treated as the real Coordinator runtime.

Alternatives considered:

- **Reuse manual selected session as the Coordinator role:** rejected because it makes the supervisor part of the supervised fleet.
- **Filter the Coordinator card out of the board:** rejected because it treats a modeling error as a UI problem.
- **Plain task-label-only Coordinator:** rejected because it risks creating the wrong layer: a normal tab-scoped agent with a new label.

### 2. Native Agent task/session lifecycle is the durable control-plane contract

RepoPrompt should define the underlying Agent task/session lifecycle as a native contract. MCP `agent_run` and `agent_manage` expose that contract externally, but the MCP schema should not be the only durable boundary.

The lifecycle contract should include:

- stable task/session handles;
- deterministic lifecycle status sufficient for Coordinator decisions;
- active/actionable/terminal status classification;
- pending interaction shape;
- respond-by-interaction-id semantics;
- cancel semantics;
- durable artifact references for summaries, logs, handoff/export artifacts, worktree metadata, and related structured outputs;
- public contract tests for caller-visible start, poll/status, wait, steer with `wait: true`, respond, cancel, and artifact/export shapes.

Coordinator needs functional state categories more than a final universal enum:

- **Active:** work that has been accepted and is waiting to start or already in progress.
- **Actionable:** work waiting for structured input from the user or Coordinator.
- **Terminal:** work that ended with a structured outcome.

Existing RepoPrompt vocabulary to preserve or map from:

- Internal Agent Mode run states include `running`, `waitingForUser`, `waitingForQuestion`, `waitingForApproval`, `completed`, `cancelled`, and `failed`.
- MCP-facing snapshot statuses include `running`, `waiting_for_input`, `completed`, `failed`, `cancelled`, and `expired`.

Coordinator should preserve these semantic categories rather than introduce unrelated new state names. The internal waiting states may collapse to a Coordinator-facing `waiting_for_input` / actionable category when the specific pending interaction shape carries the detail. Additional outcomes should be added only when the runtime has concrete semantics for them.

Coordinator directives and external integrations should derive state from this contract instead of parsing assistant prose.

Alternatives considered:

- **MCP schema as the durable contract:** rejected because MCP tool JSON is an adapter boundary and may evolve independently from native app/runtime needs.
- **Assistant prose as status:** rejected because completion, failure, and pending interactions need deterministic state.

### 3. Delegate-only is the first Coordinator capability boundary

The first Coordinator role should list sessions, inspect compact metadata, spawn agents, poll/wait task state, steer/message agents, and summarize/export through durable artifact references. It should not directly focus tabs, read files through tab-scoped tools, mutate file selections, or control worktrees.

Rationale: delegate-only matches pvncher's “maybe coordinator doesnt focus tabs at all, and just talks to agents who do” direction. It avoids the session/tab/file-selection/worktree coupling that makes current in-app agents tab-scoped. Agents that need deep project context can focus/read/search in their own scoped sessions; the Coordinator coordinates them.

Coordinator v1 allowed verbs should map to the native lifecycle contract as:

- `list` / `observe`: enumerate visible sessions, models, compact status, and artifact refs.
- `start` / `spawn`: create a delegated Agent task/session.
- `poll` / `status` / `wait`: observe deterministic lifecycle categories and terminal/actionable transitions.
- `steer` / `message`: send follow-up work to an existing delegated session.
- `summarize` / `export`: request compact summaries or durable artifact refs without loading full transcripts into the supervision loop.

The underlying lifecycle contract may define `respond` and `cancel`, but Coordinator v1 should expose only the safe delegate subset until each higher-risk action has accepted authorization and failure semantics. Coordinator access to `respond`, `cancel`, approve/decline, worktree mutation, tab focus, full log read, and direct file/search capabilities remains deferred or gated.

Alternatives considered:

- **Focus-tabs first:** deferred because it forces the Coordinator into the most coupled part of the app before the role identity and permission model are stable.
- **Full app-user capability:** rejected for v1 because it is too broad to audit or validate.

### 4. MCP adapters expose the lifecycle contract, but current agent-control scoping is not enough

The current external lifecycle is useful and should be preserved as an adapter surface:

- `agent_manage.list_agents` / `agent_manage.list_sessions` for listing.
- `agent_run.start` and possibly `agent_manage.create_session` for spawn/create.
- `agent_run.poll` / `agent_run.wait` for deterministic status observation.
- `agent_run.steer` for follow-up messages.
- `agent_run.respond` for pending interactions as a lifecycle capability; Coordinator use remains gated until accepted.
- `agent_run.cancel` for cancellation as a lifecycle capability; Coordinator use remains gated until accepted.
- `agent_manage.get_log` / `agent_manage.handoff` or export-like surfaces for artifact refs, compact summaries, and handoff/export artifacts.

However, today's agent-control MCP tools are not automatically the Coordinator scope. Existing tools are tied to window/workspace/tab context and ordinary agents may be scoped to their own sub-agents. The Coordinator needs one layer up: at minimum active-workspace top-level session listing without the ordinary child-only filter, and possibly an explicit global or attached-session scope later.

Implementation must therefore choose and document the first listing/control scope before building:

1. **Active-workspace top-level:** leading first implementation; broad enough to supervise a workspace fleet while avoiding app-global ambiguity.
2. **Explicitly attached sessions:** safer but less useful; Coordinator only sees sessions intentionally attached to its control plane.
3. **App-global:** powerful but deferred unless cross-window ownership and privacy/visibility semantics are accepted.

If the native lifecycle contract is exposed through MCP, the adapter must make the Coordinator binding explicit rather than relying on ordinary tab focus.

### 5. Tool policy enforces delegate-only behavior

Delegate-only must be enforced by policy, not just by prompt wording. The Coordinator runtime must not be advertised tab-scoped file read/search, file-selection mutation, worktree mutation, approval/decline, cancel/stop, or tab-focus tools unless a later accepted spec grants Coordinator access with authorization and audit semantics.

The enforcement seam is the MCP/Agent Mode tool policy and advertisement layer, including `AgentModeMCPToolPolicy` and related advertisement/install paths. The Coordinator should receive explicit lifecycle/control-plane tools rather than inheriting all ordinary tab-scoped Agent Mode tools.

#### Coordinator v1 tool boundary examples

| Capability | Coordinator v1 | Delegated Agent Mode session |
| --- | --- | --- |
| `agent_manage.list_agents` / `list_workflows` | Allowed for role/workflow discovery. | May also use when needed within its own scope. |
| `agent_manage.list_sessions` | Allowed with explicit Coordinator top-level/active-workspace scope. | Ordinary agents remain scoped to their spawned children where applicable. |
| `agent_run.start` | Allowed to spawn delegated agents. | Not recursive for sub-agents unless a later role explicitly allows it. |
| `agent_run.poll` / `wait` | Allowed to observe deterministic lifecycle state. | Allowed for sessions it owns or is scoped to. |
| `agent_run.steer` | Allowed to message/redirect delegated agents. | Allowed within the agent's own session scope. |
| `agent_run.respond` | Lifecycle-supported but Coordinator access gated until authorization/audit semantics are accepted. | Target agent or user-facing Agent Mode UI handles pending interactions today. |
| `agent_run.cancel`, `agent_manage.stop_session`, `cleanup_sessions` | Deferred/gated for Coordinator v1. | Existing UI/MCP paths keep their current semantics. |
| `agent_manage.get_log` / `handoff` / export | Limited to compact summaries or durable artifact refs by default. | Delegated agents may inspect deeper context when scoped to their task. |
| `bind_context`, tab focus, workspace/tab switching | Not allowed for Coordinator v1. | Delegated agents operate within their own bound tab/session scope. |
| `read_file`, `file_search`, `workspace_context`, `manage_selection` | Not allowed for Coordinator v1. | Delegated agents perform project reading/search/selection in their scoped context. |
| `apply_edits`, `file_actions` | Not allowed for Coordinator v1. | Delegated implementation agents make file changes when assigned that work. |
| `manage_worktree` mutation or `agent_run.start` worktree creation options | Deferred/gated for Coordinator v1. | Delegated agents may use task-scoped worktree context when permitted by existing policies. |

When the user's intent requires direct codebase investigation or mutation, the Coordinator should spawn or steer an appropriately scoped agent and then observe its lifecycle state and artifacts. It should not focus tabs or acquire file/worktree tools to do the work itself in v1.

### 6. Coordinator history is control-plane state, not workspace fleet state

The Coordinator's own conversation/history/directive log must live outside workspace row projection. It may be app-level Coordinator state, MCP client/runtime state, or a new persisted control-plane store, but it must not be represented as a normal supervised `AgentSession` row in Coordinator mode.

The final storage decision depends on the lifecycle/runtime implementation, but the invisibility requirement does not. Restoring Coordinator state must not create, restore, or promote a workspace Agent Mode session into the supervised fleet.

### 7. Directives are structured and auditable before autonomy

The first directive model should include a small set of explicit verbs: list, start/spawn, poll/wait, steer/message, and summarize/export. Each directive records source, target, action type, lifecycle handle, status, and failure information. Higher-risk Coordinator operations such as respond, cancel/stop, approvals, worktree mutation, and tab focus remain deferred until their authorization and audit semantics are designed.

Coordinator v1 should feel like a human-directed command rail: the user gives a directive, the Coordinator decomposes or delegates within the accepted tool boundary, and the user can observe deterministic state as delegated sessions progress. Autonomy, including follow-up directives triggered by observed session lifecycle changes, is deferred to a later spec.


#### Deferred autonomy examples

These examples document the boundary only. Coordinator v1 does not perform these follow-up directives autonomously.

| Observed condition | Coordinator v1 behavior | Later autonomy spec could allow |
| --- | --- | --- |
| Delegated agent completes | Update status/summaries and wait for user direction. | Summarize and start the next planned phase. |
| Delegated agent is blocked or waiting | Surface actionable state to the user. | Ask the user a targeted question or route a response if authorized. |
| Delegated agent reports failure | Record failed outcome and summarize artifacts. | Spawn a fix or investigation agent. |
| Delegated agent appears stale or long-running | Surface stale/long-running state. | Request confirmation to cancel, restart, or reassign. |
| Work appears ready to integrate | Report completion and artifact refs. | Start a review, merge, or check workflow under explicit policy. |

Directive status should derive from native lifecycle state, pending-interaction records, and durable artifact refs. It should not rely on assistant prose or absence of an error message.

This keeps the Coordinator role from becoming an ad hoc command box and aligns with the later Layer 2/3 direction already described by `add-coordinator-mode/end-state.md`.

### 8. Existing Coordinator mode detection remains demo-layer behavior until reconciled

The manual “Use as Coordinator” affordance and selected-session composer remain valid for demoing the current Coordinator view, but they are not the implementation path for the real Coordinator role. The future role may replace that composer target, coexist behind an explicit manual override, or remove the shim after migration.

`CoordinatorModeSnapshotProjector` currently detects a demo Coordinator from workspace sessions. The real Coordinator runtime must have a distinct identity/exclusion predicate so it never appears in `CoordinatorModeSnapshot.groups` as a supervised row. The projector and view model need an explicit reconciliation task when the real runtime integrates with the UI.

### 9. Cross-window control is deferred unless explicitly chosen

Coordinator role implementation must not accidentally create an app-global cross-window control plane. The leading first scope is active-workspace top-level visibility. Cross-window action routing remains tied to the Option A/B/C fork in `add-coordinator-mode/end-state.md`:

- current-window control plane;
- route actions to owning windows;
- shared session-control service.

The first implementation should record its stance before enabling spawn/steer/respond behavior beyond the current window.

## Risks / Trade-offs

- **Native lifecycle scope creep** → Define only the contract pieces needed for deterministic coordination first; avoid expanding this change into a general activity/provenance subsystem.
- **Role-label trap** → Do not equate a `coordinator` task label with the real Coordinator runtime unless launch, scope, policy, and projection semantics are also correct.
- **Existing MCP scope mismatch** → Current `agent_run` / `agent_manage` behavior may be window/workspace/tab scoped and child-filtered; implement an explicit Coordinator binding or adapter scope rather than assuming global visibility exists.
- **Over-broad Coordinator power** → Start delegate-only and require a later spec before exposing tab focus, file access, worktree mutation, approval/respond/cancel actions, or app-global visibility to the Coordinator.
- **Coordinator appears on its own board** → Keep Coordinator runtime state outside workspace row projection by requirement, not by filtering after projection.
- **Duplicate directive paths** → Treat the current composer as Layer 1/demo and make structured directives part of the role spec, not an ad hoc extension of ordinary user messages.

## Migration Plan

1. Create and validate this OpenSpec change.
2. Record the accepted direction: Coordinator is a first-class role backed by a native Agent task/session lifecycle contract, with MCP as adapter and delegate-only v1 scope.
3. Review the narrowed design with wren using delegate-vs-focus, lifecycle-contract-vs-MCP-schema, and active-workspace-top-level-vs-global scope as the discussion spine.
4. Implement the lifecycle contract and Coordinator role behind a feature boundary while preserving existing Coordinator mode behavior.
5. Integrate the real role with Coordinator view/composer only after role identity, scope, history, projection exclusion, and directive records are stable.
6. Retire, hide, or keep the manual selected-session composer as an explicit demo/manual override based on the accepted migration decision.

Rollback for the first implementation should leave the existing Coordinator view and manual selected-session composer intact. The real role should be additive until it is proven stable.

## Open Questions

- Should the first Coordinator listing scope be active-workspace top-level or explicitly attached sessions? App-global remains deferred unless cross-window ownership is accepted.
- Where should Coordinator history/directive logs live if the Coordinator is not a workspace session?
- Should `respond` be in the first directive set once pending-interaction shape is defined, or should it remain deferred with cancel/approval actions?
- Which MCP adapter changes are required so `agent_run` / `agent_manage` expose the native lifecycle contract without ordinary child-only scoping?
- What evidence would justify adding direct tab focus later?
