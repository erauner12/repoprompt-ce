## Context

`add-coordinator-mode` defines Mission lifecycle operations. This supporting change owns the visibility boundary between Mission inventory (`coordinator_chat list_missions`) and generic Agent Mode session enumeration (`agent_manage.list_sessions`).

Current implementation facts:

- `coordinator_chat list_missions` returns compact lifecycle inventory. External callers see the Mission fleet, including archived/persisted-only Missions by default. Coordinator runtime callers are scoped to their own Mission and cannot inspect peer Missions.
- `coordinator_chat archive_mission` is external-only and terminal-only. It hides completed/stopped Missions from ordinary live rail surfaces but preserves receipt, status, events, decisions, evidence, lineage, and inventory access.
- `agent_manage.list_sessions` is a session list, not a Mission inventory. It excludes Coordinator runtime sessions from persisted, index, and live rows; in-app Agent callers remain scoped through spawn-parent/child scoping.
- Broad Coordinator `agent_manage.list_sessions` visibility into sessions the runtime did not spawn is not part of the current baseline.

## Goals / Non-Goals

**Goals:**

- Define external vs runtime visibility for `coordinator_chat list_missions`.
- Preserve archived/terminal Mission retention visibility for receipts and cleanup.
- Keep Coordinator runtime callers scoped to their own Mission for Mission inventory.
- Keep generic `agent_manage.list_sessions` from returning Coordinator runtime sessions.
- Preserve ordinary in-app Agent child-scoped session listing.

**Non-Goals:**

- Re-defining archive/stop mutation semantics already specified by `add-coordinator-mode`.
- Adding a broad Coordinator-specific `agent_manage.list_sessions` mode in this baseline.
- Granting cross-window or app-global session visibility.
- Treating UI board membership parity as broader permission than accepted MCP visibility.

## Decisions

### 1. `list_missions` is the Mission fleet inventory surface

External drivers should use `coordinator_chat list_missions` to discover live, terminal, and archived Coordinator Missions for validation, receipt collection, and cleanup. `include_archived` defaults to true so terminal retained Missions remain visible unless explicitly filtered out.

### 2. Runtime `list_missions` is own-Mission scoped

A Coordinator runtime caller may list only its own Mission. If it omits `coordinator_session_id`, the request resolves from verified request metadata; if it passes a different Mission ID or the runtime Mission cannot be resolved, the operation fails closed. Runtime callers must not use selected UI state as a fallback.

### 3. Archive is retention cleanup, not deletion

Archived terminal Missions leave ordinary live rail surfaces but remain available to inventory/status/receipt/event consumers. External cleanup visibility therefore includes archived Missions, while runtime callers cannot archive or use archive visibility to inspect peer Missions.

### 4. Generic session listing remains session-scoped

`agent_manage.list_sessions` enumerates Agent Mode sessions for the caller-appropriate scope. It must exclude Coordinator runtime sessions at the enumeration boundary and preserve ordinary child scoping for in-app Agent callers. This operation is not the authoritative Mission inventory and should not be used as a substitute for `list_missions`.

### 5. Broader Coordinator session visibility remains deferred

Visibility into workspace sessions the Coordinator did not spawn may be useful later, but it widens a session enumeration boundary and needs a separate accepted design. Until then, the runtime supervises delegated children through returned session handles and Mission status, and external Mission inventory goes through `list_missions`.

## Risks / Trade-offs

- **Inventory/session confusion** → document `list_missions` vs `agent_manage.list_sessions` separately.
- **Runtime peer leakage** → scope runtime inventory to its own Mission and fail closed on ambiguity.
- **Lost receipts after archive** → archive must preserve retained Mission state and inventory access.
- **Coordinator self-listing** → exclude Coordinator runtime sessions from generic session lists.
- **Scope creep** → defer broad workspace session visibility and cross-window enumeration.
