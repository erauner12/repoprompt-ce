## ADDED Requirements

### Requirement: Coordinator broad session visibility
The system SHALL define a Coordinator-specific `agent_manage.list_sessions` visibility mode for active-workspace supervised sessions beyond the Coordinator's launched delegated fleet.

#### Scenario: Coordinator lists broader active-workspace sessions
- **WHEN** a Coordinator-marked connection calls `agent_manage.list_sessions` with broad visibility enabled
- **THEN** the response SHALL include the current-window active-workspace supervised-session set for the chosen scope
- **AND** that set MAY include sessions the Coordinator did not spawn.

#### Scenario: Coordinator runtime is excluded
- **WHEN** broad Coordinator session visibility is used
- **THEN** the Coordinator runtime itself SHALL be excluded from returned session rows
- **AND** the Coordinator SHALL NOT appear as a supervised session in its own list output.

#### Scenario: Coordinator role lacks broad visibility
- **WHEN** the broad visibility capability is unavailable or deferred
- **THEN** the Coordinator role SHALL still be able to supervise its launched delegated fleet through handles returned by `agent_run.start`
- **AND** broad `list_sessions` visibility SHALL NOT be required for the core Coordinator role loop.

### Requirement: Ordinary Agent Mode caller scoping is preserved
The system SHALL preserve existing child-scoped listing behavior for ordinary in-app Agent callers.

#### Scenario: Non-Coordinator in-app agent lists sessions
- **WHEN** an ordinary in-app Agent Mode caller invokes `agent_manage.list_sessions`
- **THEN** existing spawn-parent / child scoping SHALL continue to apply
- **AND** the caller SHALL NOT receive Coordinator broad active-workspace visibility.

#### Scenario: Coordinator marker is missing or invalid
- **WHEN** a connection is not Coordinator-marked or the Coordinator marker cannot be verified
- **THEN** `list_sessions` SHALL fall back to the existing caller-appropriate scope
- **AND** it SHALL NOT use the Coordinator broad visibility mode.

### Requirement: Visibility parity is testable
The broad Coordinator list scope SHALL define a concrete parity target for the chosen current-window active-workspace scope.

#### Scenario: Parity source is selected
- **WHEN** implementation defines the broad Coordinator list scope
- **THEN** it SHALL name the Coordinator mode projection/input used as the membership source of truth
- **AND** tests SHALL compare membership for that source, excluding ordering, pagination, and transient liveness differences.

#### Scenario: Cross-window visibility is requested
- **WHEN** a Coordinator behavior would list sessions outside the current window's active workspace
- **THEN** that behavior SHALL be rejected or deferred unless a later accepted spec defines cross-window routing or a shared session-control service.
