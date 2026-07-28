## ADDED Requirements

### Requirement: Coordinator runtime is an MCP consumer
The system SHALL treat the Coordinator runtime as a Mission-owning MCP consumer with runtime-specific prompt and tool guidance.

#### Scenario: Runtime prompt is assembled
- **WHEN** a Coordinator runtime receives system/developer guidance
- **THEN** the prompt SHALL describe `coordinator_chat` as the Mission control plane
- **AND** it SHALL describe `agent_run` and `agent_explore` as delegated-child surfaces subject to Mission Plan gates from `add-coordinator-mode`.

#### Scenario: Tool schema is advertised
- **WHEN** MCP tools are advertised to a Coordinator runtime
- **THEN** `coordinator_chat` schema text SHALL distinguish runtime operations from external-driver/user-action operations
- **AND** `agent_run` / `agent_explore` schemas SHALL expose Mission node/workflow fields where required by the core runtime.

### Requirement: Runtime uses coordinator_chat for Mission state
The Coordinator runtime SHALL use `coordinator_chat` for Mission state instead of inferring control-plane state from assistant prose.

#### Scenario: Runtime needs current Mission state
- **WHEN** the Coordinator runtime needs current plan, policy/autonomy, child rows, decisions, evidence, ready nodes, liveness warnings, or wait-unblocking fields
- **THEN** it SHALL call `coordinator_chat op="mission_status"` or `op="wait_for_update"`
- **AND** it SHALL NOT treat model prose as the authoritative Mission state.

#### Scenario: Runtime records plan/evidence
- **WHEN** the Coordinator runtime needs to record Mission Plan updates, Director decisions, or evidence
- **THEN** it SHALL use `coordinator_chat op="mission_plan"`
- **AND** it SHALL follow the merge, actor, and evidence constraints specified by `add-coordinator-mode`.

#### Scenario: Runtime observes event or receipt surfaces
- **WHEN** the Coordinator runtime or automation needs transition observation or terminal receipt projection
- **THEN** it SHALL use `coordinator_chat op="mission_events"` for the observation journal and `op="receipt"` for terminal receipt projection
- **AND** it SHALL treat Mission Plan/status as authoritative when events are unavailable.

### Requirement: Runtime delegates through Mission-gated child surfaces
The Coordinator runtime SHALL use child Agent Mode MCP surfaces according to Mission node metadata and core delegation gates.

#### Scenario: Runtime starts delegated work
- **WHEN** the Coordinator runtime starts delegated child work
- **THEN** it SHALL use `agent_run.start` or `agent_explore.start` with the owning Mission node ID where required
- **AND** workflow-bearing child starts SHOULD carry the workflow name or ID recorded on the Mission node.

#### Scenario: Runtime waits on delegated work
- **WHEN** the Coordinator runtime starts or observes multiple child sessions
- **THEN** it SHALL use `agent_run.poll`, `agent_run.wait`, or `coordinator_chat wait_for_update` as appropriate to observe deterministic lifecycle state
- **AND** after a wait returns one actionable or terminal child it SHALL continue tracking remaining active child handles rather than stranding them.

### Requirement: Runtime/external operation boundaries are respected
The Coordinator runtime SHALL NOT use external-driver or user-action parity operations as if it were the user.

#### Scenario: Runtime tries to create peer Mission
- **WHEN** a Coordinator runtime calls `coordinator_chat new`, `start_mission`, `ensure_mission`, or `submit new_parent=true`
- **THEN** the call SHALL be rejected by the core runtime gate
- **AND** runtime guidance SHALL tell the Coordinator to record follow-up recommendations in the current Mission instead.

#### Scenario: Runtime tries user-action parity operation
- **WHEN** a Coordinator runtime calls external user-action operations such as `set_pace`, `set_autonomy`, `archive_mission`, or other user-only lifecycle actions
- **THEN** the call SHALL be rejected or routed through the external user path only when invoked by an external caller
- **AND** the runtime SHALL NOT record those as user decisions itself.

### Requirement: childAsk response route is ledger-preserving
The Coordinator runtime SHALL answer Mission-bound child interactions only through the ledger-preserving Coordinator route.

#### Scenario: childAsk routes to Director
- **WHEN** a Mission-bound child interaction is pending and effective `childAsk` resolves to Director/Auto
- **THEN** the Coordinator runtime MAY answer through `coordinator_chat op="submit"`
- **AND** it SHALL satisfy the core requirement to record a Director childAsk decision and evidence for the same interaction.

#### Scenario: childAsk routes to Me
- **WHEN** a Mission-bound child interaction is pending and effective `childAsk` resolves to Me/Ask
- **THEN** Coordinator runtime child-answer attempts SHALL be rejected
- **AND** the interaction SHALL remain routed to the user-facing path.

#### Scenario: Generic respond would bypass ledger
- **WHEN** any caller tries to answer an active Mission-bound child interaction through generic `agent_run.respond`
- **THEN** the system SHALL reject or redirect that path according to `add-coordinator-mode`
- **AND** it SHALL tell callers to use `coordinator_chat submit` for the owning Coordinator Mission when Director routing is allowed.
