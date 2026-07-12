## ADDED Requirements

### Requirement: Director-facing role vocabulary
The system SHALL present the supervising Mission actor as Director while preserving Coordinator as the technical runtime contract name for this change.

#### Scenario: Product copy names the Director
- **WHEN** users see Mission supervision, policy, decisions, evidence, receipts, or childAsk routing labels
- **THEN** user-facing copy SHOULD use Director vocabulary
- **AND** it SHOULD avoid presenting Coordinator as the product actor except in technical/debug contexts.

#### Scenario: Technical contracts remain Coordinator-named
- **WHEN** Swift symbols, MCP operations, Codable keys, persisted records, fixtures, or debug payloads refer to the runtime
- **THEN** they SHALL keep Coordinator naming for this change
- **AND** any technical rename from Coordinator to Director SHALL be a separate no-behavior migration.

### Requirement: Dedicated Coordinator runtime identity
The system SHALL distinguish Coordinator runtime identity from ordinary Agent Mode task-label roles.

#### Scenario: Coordinator role label is discovered
- **WHEN** role discovery or model binding exposes a `coordinator` label
- **THEN** that label MAY describe the model/default selection for a Coordinator runtime
- **AND** it SHALL NOT by itself grant Coordinator runtime scope, tools, or actor attribution.

#### Scenario: Ordinary start path requests Coordinator label
- **WHEN** `agent_run.start`, `agent_manage.create_session`, or `agent_manage.resume_session` would create an ordinary Agent Mode session using `model_id:"coordinator"` or an equivalent Coordinator task label
- **THEN** the system SHALL reject that ordinary-session launch
- **AND** it SHALL direct callers to the dedicated Coordinator runtime creation path.

#### Scenario: Coordinator runtime is created
- **WHEN** a fresh Coordinator runtime is created for a Mission
- **THEN** the runtime SHALL receive durable Coordinator identity such as `isCoordinatorRuntime`
- **AND** it SHALL install typed Coordinator policy context before Coordinator-scoped behavior is granted.

### Requirement: Marked Agent Mode runtime reuse is explicit
The system SHALL treat the current marked/background Agent Mode session implementation as the accepted runtime backing for this branch, without making ordinary child sessions into Coordinators.

#### Scenario: Marked runtime persists and restores
- **WHEN** Coordinator runtime state is saved, indexed, restored, or reconnected
- **THEN** the durable Coordinator marker SHALL be preserved through session persistence and metadata/index paths
- **AND** restored state SHALL remain identifiable as a Coordinator runtime rather than an ordinary supervised Agent Mode session.

#### Scenario: Child session is delegated
- **WHEN** a Coordinator runtime launches or supervises a child Agent Mode session
- **THEN** the child SHALL keep ordinary role identity and scoped Agent Mode state
- **AND** it SHALL NOT inherit Coordinator runtime marker, Coordinator actor attribution, or Coordinator policy context merely because its parent is a Coordinator runtime.

#### Scenario: Non-enrolled runtime extraction is requested
- **WHEN** implementation would require a provider runtime outside Agent Mode session persistence and routing
- **THEN** that extraction SHALL be treated as deferred follow-up work
- **AND** the current role contract SHALL continue to rely on the marked runtime path unless a later accepted spec replaces it.

### Requirement: Fresh Coordinator model override
The system SHALL allow external fresh-Mission creation to select the underlying Coordinator runtime model without changing runtime identity.

#### Scenario: External start passes coordinator_model_id
- **WHEN** an external caller starts a fresh Mission through `coordinator_chat` operations such as `new`, `ensure_mission`, `start_mission`, or `submit new_parent=true`
- **AND** it passes `coordinator_model_id`
- **THEN** the system SHALL apply that value only to the fresh Coordinator runtime's underlying provider/model selection
- **AND** the runtime SHALL remain a Coordinator runtime with the same Director prompt contract, Coordinator tools, typed policy context, and Mission Policy semantics.

#### Scenario: Existing Mission receives coordinator_model_id
- **WHEN** a caller targets an existing Mission or runtime and includes `coordinator_model_id`
- **THEN** the argument SHALL NOT silently reconfigure the existing Coordinator runtime
- **AND** any model-change behavior for existing Missions SHALL require a later explicit spec.

### Requirement: Core Mission semantics are owned by add-coordinator-mode
This role capability SHALL cross-reference the core runtime rather than duplicating Mission behavior.

#### Scenario: Mission runtime behavior is needed
- **WHEN** requirements involve Mission Plan gating, policy/autonomy, childAsk routing, decisions/evidence, status/events/waits, receipt projection, stop/archive, scripted children, or live E2E doctrine
- **THEN** the authoritative requirement SHALL be in `openspec/changes/add-coordinator-mode`
- **AND** this role change SHALL state only role identity, naming, model-selection, dedicated-launch, and ordinary-role separation requirements.
