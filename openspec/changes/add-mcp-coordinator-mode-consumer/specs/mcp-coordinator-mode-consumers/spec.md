## ADDED Requirements

### Requirement: Named MCP Coordinator mode consumers
The system SHALL support a named MCP consumer for Coordinator mode without changing existing MCP UI consumers.

#### Scenario: Coordinator mode consumer is available
- **WHEN** MCP consumers are referenced
- **THEN** the system SHALL provide a named Coordinator mode consumer identity alongside existing toolbar popover and status view consumers.

#### Scenario: Existing consumers remain available
- **WHEN** existing MCP UI surfaces subscribe to MCP updates
- **THEN** toolbar popover and status view consumers SHALL continue to use their existing consumer identities and behavior.

### Requirement: Shared MCP subscription lifecycle
The system SHALL keep one shared MCP update subscription active while any consumer requires it.

#### Scenario: First consumer appears
- **WHEN** no consumer is visible and one consumer becomes visible
- **THEN** the system SHALL start MCP update observation.

#### Scenario: Additional consumer appears
- **WHEN** MCP update observation is already active for one visible consumer and another consumer becomes visible
- **THEN** the system SHALL keep using the shared MCP update observation path
- **AND** it SHALL NOT start a duplicate MCP update task solely because another consumer appeared.

#### Scenario: One of multiple consumers disappears
- **WHEN** multiple consumers are visible and one consumer becomes hidden
- **THEN** the system SHALL keep MCP update observation active for the remaining visible consumer or consumers.

#### Scenario: Last consumer disappears
- **WHEN** the final visible consumer becomes hidden and window tools do not otherwise require MCP observation
- **THEN** the system SHALL stop MCP update observation
- **AND** it SHALL clear MCP snapshot state according to the existing lifecycle.

#### Scenario: Window tools force observation
- **WHEN** window tools require MCP observation independent of visible consumers
- **THEN** the system SHALL keep MCP update observation active even if the consumer set is empty.
