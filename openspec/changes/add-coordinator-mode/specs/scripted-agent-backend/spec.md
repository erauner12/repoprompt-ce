## ADDED Requirements

### Requirement: Scripted child backend supports deterministic childAsk validation
The system SHALL provide a hidden DEBUG-only scripted child backend for deterministic E2E child interaction tests.

#### Scenario: Scripted child selector is used in DEBUG
- **WHEN** a DEBUG build receives a child run using the scripted selector/model ID
- **THEN** it SHALL route to the scripted runner instead of Codex provider execution
- **AND** normal user-facing model lists SHALL NOT expose the scripted backend.

#### Scenario: Script line is valid
- **WHEN** the scripted runner sees `SCRIPTED_CHILD_V1 ask_marker token=<TOKEN> options=Alpha,Beta`
- **THEN** it SHALL create a real `AgentAskUserInteraction` with one marker-choice question
- **AND** after the interaction is answered it SHALL append `SCRIPTED_CHILD_V1 answer=<Alpha|Beta> token=<TOKEN>` and complete the Agent Mode run.

#### Scenario: Script line is invalid
- **WHEN** the scripted runner does not find the exact script line or receives an invalid answer
- **THEN** it SHALL fail the run with a `SCRIPTED_CHILD_BAD_SCRIPT` diagnostic.

#### Scenario: Scripted backend uses real Agent Mode lifecycle
- **WHEN** scripted child validation runs
- **THEN** it SHALL reuse the real Agent Mode run lifecycle, pending-interaction, and terminal-state paths
- **AND** it SHALL NOT become a general interpreter or replace live child/backend negotiation samples.

#### Scenario: Doctor reports scripted support
- **WHEN** `coordinator_chat op="doctor"` runs
- **THEN** it SHALL report structured child input support and scripted child availability facts.

### Requirement: Scripted backend scope remains narrow
The system SHALL keep the scripted backend as deterministic validation substrate, not a production backend policy.

#### Scenario: Backend fallback is requested
- **WHEN** a live child backend/provider is unavailable or fails
- **THEN** the scripted backend SHALL NOT be used as an automatic production fallback
- **AND** backend fallback SHALL remain deferred to a later provider/runtime design.

#### Scenario: Scripted selector leaks to user-facing lists
- **WHEN** normal user-facing model or provider lists are rendered
- **THEN** the scripted selector SHALL remain hidden from those lists.

#### Scenario: Traceability remains discoverable
- **WHEN** maintainers verify scripted backend behavior
- **THEN** enforcement SHOULD be discoverable in `ScriptedAgentModeRunner.swift`, provider/model selection glue for DEBUG builds, and `CoordinatorChatMCPToolService.swift` doctor reporting
- **AND** tests SHOULD include `AgentModeRunServiceLifecycleTests` scripted-run lifecycle coverage, `CoordinatorChatMCPToolServiceTests.testDoctorReportsCoordinatorCapabilities`, `testAgentModeChildrenAdvertiseStructuredUserInput`, and live E2E S5/S6 scripted childAsk slices where available.
