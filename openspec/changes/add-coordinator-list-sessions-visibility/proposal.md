## Why

The current Coordinator/Director runtime supervises Missions, not loose sessions. External callers need lifecycle inventory for live, terminal, and archived Missions so they can validate, collect receipts, and clean up. Coordinator runtime callers, however, must remain scoped to their own Mission and must not inspect or archive peer Missions.

Generic `agent_manage.list_sessions` is still a session enumeration surface, not the Mission inventory surface. It must exclude Coordinator runtime sessions and preserve ordinary in-app child scoping. Broader Coordinator visibility into non-owned workspace sessions remains a later capability unless separately accepted.

## What Changes

- Define `coordinator_chat list_missions` as the Coordinator Mission fleet inventory surface for external callers.
- Preserve runtime `list_missions` scoping to the caller's own Mission.
- Specify archived/terminal Mission retention visibility: archives hide Missions from ordinary live rail surfaces but preserve inventory, receipts, events, decisions, evidence, status, and lineage.
- Preserve generic `agent_manage.list_sessions` behavior as session listing, not Mission inventory, with Coordinator runtimes excluded from results.
- Keep broader Coordinator `agent_manage.list_sessions` visibility into sessions it did not spawn deferred unless a later accepted spec grants it.

## Capabilities

### New Capabilities
- `coordinator-list-sessions-visibility`: Defines Coordinator Mission inventory/session-enumeration visibility boundaries, including `list_missions`, `agent_manage.list_sessions`, archived retention, and runtime own-Mission scoping.

### Modified Capabilities

None to core Mission semantics; `add-coordinator-mode` remains authoritative for stop/archive operation behavior and receipt projection.

## Impact

- `coordinator_chat list_missions`: external callers see live and archived Mission inventory by default; runtime callers are scoped to their own Mission.
- `coordinator_chat archive_mission`: external-only terminal retention cleanup; runtime callers cannot archive.
- `agent_manage.list_sessions`: continues to list Agent Mode sessions in caller-appropriate scope and excludes Coordinator runtime sessions.
- Coordinator board/rail: may show Mission-oriented Coordinator options, but must not be treated as broader generic session visibility.
