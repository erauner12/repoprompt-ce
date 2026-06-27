## ADDED Requirements

### Requirement: Named Agent Mode MCP policy context
The system SHALL carry Agent Mode MCP run-lease and connection-policy installer fields through a named policy context or equivalent typed structure.

#### Scenario: Policy context replaces positional privilege plumbing
- **WHEN** Agent Mode installs or leases MCP connection policy for a run
- **THEN** policy fields SHALL be grouped in a named context or equivalent typed structure
- **AND** implementation SHALL NOT rely on long positional privilege/tool-policy argument forwarding between Agent Mode run lease and connection-policy installer call sites.

#### Scenario: Existing policy fields are preserved
- **WHEN** the named context is introduced
- **THEN** it SHALL preserve all current effective policy fields established by characterization coverage, including but not limited to client/window/run identity, restricted tools, additional tools, one-shot behavior, reason, TTL, run purpose, task label, external-control tool availability, and expected-PID behavior
- **AND** Codex and non-Codex Agent Mode run paths SHALL carry equivalent policy state.

### Requirement: Behavior-preserving prerequisite
The refactor SHALL be behavior-preserving and SHALL NOT introduce Coordinator-specific behavior.

#### Scenario: Characterization precedes refactor
- **WHEN** implementation starts changing policy installer plumbing
- **THEN** existing regression coverage SHALL be identified or focused characterization coverage SHALL be added for current policy behavior
- **AND** that coverage SHALL include restricted tools, granted tools, task-label policy, top-level-only external-control tools, expected-PID routing, and Codex/non-Codex lease paths.

#### Scenario: Coordinator-specific behavior is requested
- **WHEN** implementation attempts to add Coordinator identity markers, Coordinator privileges, Coordinator tool restrictions, or Coordinator `list_sessions` visibility
- **THEN** that behavior SHALL be deferred to the dependent Coordinator role or visibility changes
- **AND** this prerequisite SHALL remain a no-behavior-change policy-context refactor.
