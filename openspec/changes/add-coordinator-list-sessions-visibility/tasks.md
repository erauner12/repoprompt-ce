## 1. Mission inventory scope

- [x] 1.1 Define `coordinator_chat list_missions` as the Mission fleet inventory surface for external callers.
- [x] 1.2 Define `include_archived` behavior so archived/persisted-only Missions remain visible by default.
- [x] 1.3 Define compact retained Mission rows as audit/cleanup inventory, not transcript-derived truth.

## 2. Runtime scoping and archive retention

- [x] 2.1 Scope Coordinator runtime `list_missions` calls to the caller's own Mission.
- [x] 2.2 Reject runtime attempts to list peer Missions or fall back to selected UI Mission when caller Mission resolution fails.
- [x] 2.3 Define archive as external-only terminal retention cleanup that preserves receipt, status, events, decisions, evidence, lineage, and inventory access.
- [x] 2.4 Reject runtime `archive_mission` attempts.

## 3. Generic session listing boundaries

- [x] 3.1 Preserve `agent_manage.list_sessions` as generic Agent Mode session listing, not Mission inventory.
- [x] 3.2 Exclude Coordinator runtime sessions from generic `list_sessions` persisted/index/live rows.
- [x] 3.3 Preserve ordinary in-app Agent spawn-parent / child scoping.
- [x] 3.4 Defer broad Coordinator `agent_manage.list_sessions` visibility into unowned workspace sessions to a later accepted design.
- [x] 3.5 Keep cross-window visibility out of scope unless a later accepted spec grants it.

## 4. Validation

- [x] 4.1 Run `openspec validate add-coordinator-list-sessions-visibility` after reconciliation.
