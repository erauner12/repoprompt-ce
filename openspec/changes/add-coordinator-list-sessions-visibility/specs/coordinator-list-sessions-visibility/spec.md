## ADDED Requirements

### Requirement: Mission inventory uses coordinator_chat list_missions
The system SHALL expose Coordinator Mission lifecycle inventory through `coordinator_chat op="list_missions"` rather than generic session listing.

#### Scenario: External caller lists Mission fleet
- **WHEN** an external user/CLI/test caller invokes `coordinator_chat list_missions`
- **THEN** the response SHALL include compact Mission lifecycle rows for visible Coordinator Missions in the current window/workspace scope
- **AND** it SHALL include archived/persisted-only Missions by default unless `include_archived=false` is requested.

#### Scenario: Mission row is compact but audit-aware
- **WHEN** a Mission appears in `list_missions`
- **THEN** the row SHALL include stable Mission identity such as `coordinator_session_id` and available plan summary/status fields
- **AND** it SHALL expose enough retained counts or summaries for external validation/cleanup without making transcripts the source of truth.

### Requirement: Runtime Mission inventory is own-Mission scoped
The system SHALL scope Coordinator runtime `list_missions` calls to the caller's own Mission.

#### Scenario: Runtime lists without explicit Mission ID
- **WHEN** a Coordinator runtime invokes `list_missions` without `coordinator_session_id`
- **THEN** the system SHALL resolve the caller Mission from verified request metadata
- **AND** the response SHALL include only that Mission.

#### Scenario: Runtime requests peer Mission
- **WHEN** a Coordinator runtime invokes `list_missions` with a `coordinator_session_id` other than its own resolved Mission
- **THEN** the system SHALL reject the request
- **AND** it SHALL NOT expose peer Mission inventory.

#### Scenario: Runtime Mission cannot be resolved
- **WHEN** a Coordinator runtime invokes `list_missions` but the caller Mission cannot be resolved
- **THEN** the operation SHALL fail closed
- **AND** it SHALL NOT fall back to the selected Coordinator in the UI.

### Requirement: Archived Mission retention remains visible to external inventory
The system SHALL preserve terminal Mission state after archive and keep it externally discoverable for receipt and cleanup workflows.

#### Scenario: Terminal Mission is archived
- **WHEN** an external caller archives a completed or stopped Mission
- **THEN** the Mission MAY be hidden from ordinary live rail surfaces
- **AND** `list_missions` with archived inclusion SHALL still be able to report the retained Mission row.

#### Scenario: Archived Mission state is retained
- **WHEN** an archived Mission is listed, inspected, or used for receipt retrieval
- **THEN** receipt, status, events, decisions, evidence, lineage, and plan summary state SHALL remain available according to the core runtime contracts
- **AND** archive SHALL NOT behave as deletion of audit state.

#### Scenario: Runtime tries to archive
- **WHEN** a Coordinator runtime caller invokes `archive_mission`
- **THEN** the operation SHALL be rejected as an external-only lifecycle cleanup action
- **AND** runtime callers SHALL NOT use archive behavior to hide or inspect peer Missions.

### Requirement: Generic list_sessions remains session-scoped
The system SHALL keep `agent_manage.list_sessions` as Agent Mode session enumeration, not Coordinator Mission inventory.

#### Scenario: list_sessions enumerates sessions
- **WHEN** any caller invokes `agent_manage.list_sessions`
- **THEN** the response SHALL list Agent Mode sessions in the caller-appropriate scope
- **AND** callers needing Mission lifecycle inventory SHALL use `coordinator_chat list_missions` instead.

#### Scenario: Coordinator runtime is excluded from generic session rows
- **WHEN** `agent_manage.list_sessions` gathers persisted, indexed, or live Agent Mode rows
- **THEN** Coordinator runtime sessions SHALL be excluded from returned session rows
- **AND** the Coordinator runtime SHALL NOT appear as a supervised child/session row in generic session list output.

#### Scenario: Ordinary in-app agent lists sessions
- **WHEN** an ordinary in-app Agent Mode caller invokes `agent_manage.list_sessions`
- **THEN** existing spawn-parent / child scoping SHALL continue to apply
- **AND** the caller SHALL NOT receive broad Coordinator workspace visibility.

### Requirement: Broader Coordinator session visibility is deferred
The system SHALL NOT imply a broad Coordinator-specific `agent_manage.list_sessions` mode from Mission inventory support.

#### Scenario: Coordinator wants sessions it did not spawn
- **WHEN** a Coordinator behavior needs generic visibility into pre-existing, sibling, or unowned workspace Agent Mode sessions
- **THEN** that broader `agent_manage.list_sessions` visibility SHALL require a later accepted design
- **AND** it SHALL NOT be inferred from `list_missions` fleet inventory.

#### Scenario: Cross-window visibility is requested
- **WHEN** a Coordinator behavior would list Missions or sessions outside the current accepted window/workspace scope
- **THEN** that behavior SHALL be rejected or deferred unless a later accepted spec defines cross-window routing or a shared session-control service.
