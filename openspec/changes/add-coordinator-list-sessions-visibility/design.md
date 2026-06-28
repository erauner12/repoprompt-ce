## Context

Coordinator v1 can coordinate its own launched delegated fleet without broad `list_sessions` visibility because `agent_run.start` returns stable session handles and `poll`, `wait`, and `steer` can operate on those handles.

Broad session visibility is still useful when the Coordinator should understand Agent Mode sessions it did not start. The current MCP `agent_manage.list_sessions` behavior has an important scope boundary: in-app Agent callers are normally scoped through spawn-parent resolution and see direct child sessions, while non-routed MCP caller behavior should be confirmed during implementation. Widening the in-app Coordinator boundary is security-relevant and must be gated by the typed Coordinator policy context introduced by `add-coordinator-role`, not by the production-demo boolean marker.

Important seams:

- `AgentManageMCPToolService.executeListSessions`
- `resolveSpawnParentSessionID`
- `mcpSpawnParentSessionID`
- Coordinator mode projection source used for parity

## Goals / Non-Goals

**Goals:**

- Define a Coordinator-marked `list_sessions` visibility mode for sessions beyond the Coordinator's launched fleet.
- Preserve ordinary in-app Agent child scoping.
- Exclude the Coordinator runtime itself.
- Define membership parity with the selected Coordinator mode projection/input for the same current-window active-workspace scope.
- Keep the capability deferrable from `add-coordinator-role`.

**Non-Goals:**

- Implementing the Coordinator role identity.
- Changing Coordinator runtime creation or ownership.
- Granting direct file/search/edit/worktree tools.
- Granting `respond`, `cancel`, stop, cleanup, or approval actions.
- Adding cross-window control.

## Decisions

### 1. This is a visibility-boundary change, not a role prerequisite

The role can ship without this change by supervising returned session handles. This change only adds visibility into sessions the Coordinator did not spawn.

### 2. Coordinator policy context is the gate

Only connections with verified Coordinator role identity and typed Coordinator policy context should receive widened list scope. Ordinary Agent Mode callers must keep their existing child-scoped behavior. The production-demo marker can remain a UI bridge, but it must not be the final privilege gate for broad `list_sessions`.

### 3. Current-window active-workspace is the first scope

The first visibility scope should be current-window active-workspace supervised sessions, excluding the Coordinator runtime itself. Cross-window enumeration requires a later routing/control-plane decision.

### 4. Parity needs a named source of truth

The implementation must name the Coordinator mode projection/input used as the parity source for the chosen scope. Parity excludes ordering, pagination, and transient liveness differences.

### 5. The board should converge on Coordinator-visible state

The production-demo board currently has an independent projection of the fleet. The target architecture is that the board displays the same current-window active-workspace supervised-session set that a Coordinator role can see through its Coordinator-scoped `list_sessions` visibility. If implementation keeps the projector for UI performance or staging, tests must prove membership parity so the board does not see more than the Coordinator role.

## Risks / Trade-offs

- **Scope leakage** → require tests proving ordinary in-app Agent callers remain child-scoped.
- **Projection drift** → name one Coordinator mode projection/input as parity source instead of comparing against vague UI behavior.
- **Coordinator self-listing** → exclude Coordinator-marked runtime from broad list results.
- **Marker-as-policy regression** → require typed Coordinator policy context before broad listing is granted.
- **Scope creep** → do not add mutation, response, stop, cleanup, or cross-window behavior in this visibility change.
