## Context

RepoPrompt CE now has a Coordinator mode surface that can supervise active-workspace Agent Mode sessions through board/list projection, rail context, inspector summaries, and a scoped composer. That surface is intentionally Layer 1: it can target a user-selected live Agent Mode session and send ordinary user messages, but the selected session is still part of the workspace fleet.

The real Coordinator role is a different architectural object. It should be a layer-above meta-agent that supervises workspace sessions without being projected as one of them. pvncher's notes frame this as a new `coordinator` role with broader/top-level session visibility than `pair`, `engineer`, `explore`, or `design`. wren's concern is the coupling between tabs, sessions, file selection, and worktree controls. Current code reflects that coupling: Agent Mode MCP policy is tab-scoped, while MCP binding already has explicit context binding and ambiguity handling seams.

Important existing anchors:

- `openspec/changes/add-coordinator-mode/design.md`: current Coordinator view/composer design and v1 non-goals.
- `openspec/changes/add-coordinator-mode/end-state.md`: later action/directive layers.
- `Sources/RepoPrompt/Infrastructure/MCP/Policies/AgentModeMCPToolPolicy.swift`: current tab-scoped Agent Mode policy.
- `Sources/RepoPrompt/Infrastructure/MCP/MCPBindingResolver.swift`: context binding and ambiguity handling.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/CoordinatorModeViewModel.swift`: current selected-session demo composer.
- `Sources/RepoPrompt/Features/AgentMode/Services/CoordinatorModeSnapshotProjector.swift`: current workspace session projection.

## Goals / Non-Goals

**Goals:**

- Define the first real Coordinator role as a layer-above meta-agent, not a workspace session/card.
- Resolve or explicitly stage the runtime-home decision: MCP-bound role entry versus true in-app non-tab-scoped Agent Mode role.
- Give the first Coordinator role a delegate-only tool boundary: observe sessions, spawn/message/steer agents through explicit APIs, and summarize state.
- Keep Coordinator runtime state out of `CoordinatorModeSnapshot` workspace row groups by construction.
- Define auditable directive records before adding autonomy or broad mutation powers.
- Preserve the existing manual selected-session composer as a demo shim until the real role replaces or supersedes it.

**Non-Goals:**

- Implementing the role in this OpenSpec change.
- Granting the first Coordinator role direct tab focus, file reads/searches scoped to focused tabs, file-selection mutation, or worktree mutation.
- Replacing Agent Mode as the canonical deep-work surface.
- Making the Coordinator board/list a full transcript, log, file, or diff viewer.
- Hiding a normal workspace session row after using it as Coordinator. The real role should not be projected into the workspace fleet in the first place.
- Defining broad autonomous behavior without explicit directive classes, authorization rules, and failure semantics.

## Decisions

### 1. Coordinator is a meta-agent identity, not row state

The Coordinator role is a runtime identity above the workspace fleet. The Coordinator view remains the human-facing observation/control plane over workspace Agent Mode sessions. The role may consume and produce Coordinator-view state later, but its own runtime identity is separate from board/list row projection.

Alternatives considered:

- **Reuse manual selected session as the Coordinator role:** rejected because it makes the supervisor part of the supervised fleet.
- **Filter the Coordinator card out of the board:** rejected because it treats a modeling error as a UI problem.

### 2. Delegate-only is the first capability boundary

The first Coordinator role should list sessions, inspect compact metadata, spawn/message/steer agents through explicit Agent Mode/MCP APIs, and summarize status. It should not directly focus tabs, read files through tab-scoped tools, mutate file selections, or control worktrees.

Rationale: delegate-only avoids the session/tab/file-selection/worktree coupling that makes current in-app agents tab-scoped. Agents that need deep project context can focus/read/search in their own scoped sessions; the Coordinator coordinates them.

Alternatives considered:

- **Focus-tabs first:** deferred because it forces the Coordinator into the most coupled part of the app before the role identity and permission model are stable.
- **Full app-user capability:** rejected for v1 because it is too broad to audit or validate.

### 3. MCP-bound global/top-level scope is the leading runtime hypothesis

The leading design hypothesis is a Coordinator role entry that launches or binds to an MCP-backed runtime with top-level/global session visibility. This fits the existing MCP binding seam and avoids inventing an in-app unscoped Agent Mode session before proving one is needed.

This is not final until pvncher's wording is clarified. “New agent role in code” may mean a role catalog entry that launches an MCP-bound runtime, or it may mean a true in-app Agent Mode role with non-tab-scoped permissions. That clarification should happen before detailed implementation planning.

Alternatives considered:

- **True in-app non-tab-scoped role:** viable only if the implementation also introduces a new non-tab-scoped agent/session abstraction and permission policy.
- **Current tab-scoped Agent Mode role with broader tools:** rejected because it preserves the wrong layer and keeps the Coordinator in the tab/session coupling problem.

### 4. Coordinator history is control-plane state, not workspace fleet state

The Coordinator's own conversation/history/directive log must live outside workspace row projection. It may be app-level Coordinator state, MCP client/runtime state, or a new persisted control-plane store, but it must not be represented as a normal supervised `AgentSession` row in Coordinator mode.

The final storage decision depends on the runtime-home decision. The spec should require invisibility from the board/list regardless of storage location.

### 5. Directives are structured and auditable before autonomy

The first directive model should include a small set of explicit verbs: list, spawn, message/steer, and summarize. Each directive records source, target, status, and failure information. Higher-risk operations such as cancel/stop, approvals, worktree mutation, and tab focus remain deferred until their authorization and audit semantics are designed.

This keeps the Coordinator role from becoming an ad hoc command box and aligns with the later Layer 2/3 direction already described by `add-coordinator-mode/end-state.md`.

### 6. Current selected-session composer remains a demo shim

The manual “Use as Coordinator” affordance and selected-session composer remain valid for demoing the current Coordinator view, but they are not the implementation path for the real Coordinator role. The future role may replace that composer target, coexist behind an explicit manual override, or remove the shim after migration.

## Risks / Trade-offs

- **Runtime ambiguity** → Ask pvncher one direct clarification before wren deep design: did “role in code” mean MCP-bound role entry or true in-app non-tab-scoped role?
- **Over-broad Coordinator power** → Start delegate-only and require a later spec for tab focus, file access, worktree mutation, or approval/cancel actions.
- **Coordinator appears on its own board** → Keep Coordinator runtime state outside workspace row projection by requirement, not by filtering.
- **MCP-bound runtime feels disconnected from app UI** → Define explicit role identity, history ownership, and view integration before implementation.
- **Duplicate directive paths** → Treat the current composer as Layer 1/demo and make structured directives part of the role spec, not an ad hoc extension of ordinary user messages.

## Migration Plan

1. Create and validate this OpenSpec change.
2. Ask pvncher the narrow runtime clarification question before detailed implementation: whether `coordinator` should be an MCP-bound role entry or a true in-app non-tab-scoped role.
3. Review the design with wren using the delegate-vs-focus and MCP-bound-vs-in-app forks as the discussion spine.
4. After the runtime-home decision is accepted, implement the role behind a feature boundary while preserving existing Coordinator mode behavior.
5. Integrate the real role with Coordinator view/composer only after role identity, scope, history, and directive records are stable.
6. Retire, hide, or keep the manual selected-session composer as an explicit demo/manual override based on the accepted migration decision.

Rollback for the first implementation should leave the existing Coordinator view and manual selected-session composer intact. The real role should be additive until it is proven stable.

## Open Questions

- Does “new agent role in code” mean an MCP-bound role entry or a true in-app non-tab-scoped Agent Mode role?
- Should initial Coordinator visibility be app-global, active-workspace top-level only, or explicitly attached sessions only?
- Where should Coordinator history/directive logs live if the Coordinator is not a workspace session?
- Should the first directive set include cancel/stop, or should those remain deferred until explicit authorization semantics exist?
- What evidence would justify adding direct tab focus later?
