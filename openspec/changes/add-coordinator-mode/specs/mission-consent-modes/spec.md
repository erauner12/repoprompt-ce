## ADDED Requirements

### Requirement: Mission consent mode is selected at start by the external user channel
The system SHALL let external callers select, per Mission, whether the initial Mission Plan requires a blocking user approval checkpoint, defaulting to required approval, and SHALL treat that selection as an external user action.

#### Scenario: Default Mission start keeps required approval
- **WHEN** `start_mission` or `ensure_mission` runs without a consent-mode selection
- **THEN** Mission bootstrap SHALL publish the initial plan with `approval_state:"awaiting_approval"` and a revision-bound approval checkpoint, unchanged from approval-required behavior.

#### Scenario: External caller starts a policy-consented Mission
- **WHEN** an external user/CLI caller passes the `plan:"auto"` autonomy override to `start_mission` or `ensure_mission`
- **THEN** Mission bootstrap SHALL publish the initial plan with `approval_state:"not_required"`
- **AND** it SHALL NOT publish an initial plan approval checkpoint
- **AND** it SHALL record a user-actor decision that initial plan approval was waived by Mission Policy at start.

#### Scenario: Runtime cannot select or change consent mode
- **WHEN** a Coordinator runtime caller attempts to pass `plan` autonomy at Mission start or change it later through `set_autonomy`
- **THEN** the system SHALL reject the request as external user-action parity
- **AND** the instructive error SHALL name the external user channel.

#### Scenario: set_autonomy accepts the plan class from external callers
- **WHEN** an external caller invokes `set_autonomy` with class `plan` and value `ask` or `auto`
- **THEN** the system SHALL record the dial change as a user-actor decision and update Mission Policy
- **AND** unknown classes SHALL keep rejecting with an instructive error.

### Requirement: Consent mode changes ceremony, never record-keeping
The system SHALL keep the Mission Plan, decision ledger, and delegation gates as the substrate for policy-consented Missions.

#### Scenario: Policy-consented delegation still requires recorded nodes
- **WHEN** a Mission has `approval_state:"not_required"` selected through the external user channel
- **THEN** normal delegated starts SHALL still require a Mission Plan with at least one recorded node
- **AND** sandboxing, flight-cap, node-binding, evidence, and terminal-honesty checks SHALL apply identically to approved Missions.

#### Scenario: Status and receipt disclose the consent mode
- **WHEN** `mission_status` or `receipt` render a policy-consented Mission
- **THEN** they SHALL disclose that initial plan approval was waived by Mission Policy
- **AND** the decision ledger SHALL contain the user-actor decision that selected the mode.

### Requirement: awaiting_approval exits only through the user checkpoint
The system SHALL treat exit from a gated approval state as a user-checkpoint-only transition in every consent mode.

#### Scenario: mission_plan cannot waive a pending approval
- **WHEN** any `mission_plan` update sets `approval_state:"not_required"` while the existing plan is `awaiting_approval` or `revision_requested`
- **THEN** the system SHALL reject the update
- **AND** the instructive error SHALL name checkpoint submit as the only exit from a pending approval.

#### Scenario: Consent-mode flip does not consume a pending approval
- **WHEN** `plan` autonomy flips `ask` to `auto` while an approval checkpoint is pending
- **THEN** the pending checkpoint SHALL remain pending with stable identity
- **AND** the Mission SHALL still require an explicit user checkpoint action to exit the gated state.

### Requirement: Escalation to required approval takes effect immediately
The system SHALL let the external user re-impose the approval gate on a running policy-consented Mission.

#### Scenario: plan autonomy flips auto to ask mid-Mission
- **WHEN** an external caller flips `plan` autonomy from `auto` to `ask` on a Mission whose plan is `not_required`
- **THEN** the system SHALL transition the current plan revision to `awaiting_approval` with a fresh revision-bound checkpoint instance
- **AND** further normal delegated starts SHALL be blocked until the user proceeds
- **AND** already-running children SHALL be unaffected
- **AND** the dial-change user decision SHALL precede any later approval decision in the Mission journal.

### Requirement: Consent modes never weaken unrelated invariants
The system SHALL resolve consent mode independently from other autonomy classes and safety gates.

#### Scenario: Unrelated dials keep their own resolution
- **WHEN** a Mission runs with `plan:"auto"`
- **THEN** `childAsk`, pace, `irreversible`, sandboxing, flight caps, actor attribution, archive gating, and terminal honesty SHALL resolve exactly as they would for an approved Mission
- **AND** `irreversible` SHALL continue to resolve to ask regardless of consent mode.

#### Scenario: Consent-mode traceability is planned before implementation
- **WHEN** maintainers verify consent-mode enforcement
- **THEN** enforcement SHOULD be discoverable in `CoordinatorChatMCPToolService.swift` bootstrap and `set_autonomy` handling, `AgentRunCoordinatorMissionPlanPolicy.swift` delegation gating, and `CoordinatorModeViewModel` dial handling
- **AND** validation SHOULD include a planned S10 harness scenario covering a policy-consented Mission with mid-flight escalation, plus unit coverage for not-required bootstrap, waive-block rejection, flip escalation, and receipt disclosure before the feature is treated as shipped.
