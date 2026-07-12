## ADDED Requirements

### Requirement: Revision proposals preserve the single trusted approval door
A Director-authored proposal SHALL request reconsideration but SHALL NOT approve, replace, waive, or mutate the approved Mission contract.

#### Scenario: Director proposes a revision
- **WHEN** the owning runtime files a valid proposal
- **THEN** the Mission SHALL remain approved under its existing contract
- **AND** autonomous advancement SHALL pause pending an external user decision.

#### Scenario: Director claims a change is non-material
- **WHEN** a summary proposal supplies advisory affected fields or materiality metadata
- **THEN** the system SHALL still treat the v1 proposal as material
- **AND** Director metadata SHALL NOT waive the pause or ratify a replacement.

#### Scenario: Director attempts self-approval
- **WHEN** runtime-authored input attempts to record Revise, Keep, Stop, approval, or user decision metadata
- **THEN** the system SHALL reject the attempt
- **AND** only app-owned external user paths SHALL resolve the proposal.

### Requirement: Revise and Keep require authoritative proposal CAS
Trusted Revise plan and Keep current plan transactions SHALL validate authoritative proposal, checkpoint, Mission terminal, and material-contract state at execution time.

#### Scenario: Rendered proposal is current
- **WHEN** the proposal remains unresolved, the Mission is nonterminal, proposal and checkpoint identities match, and the current canonical contract structurally equals the proposal base snapshot
- **THEN** the transaction MAY append its user decision and resolution.

#### Scenario: Contract changed after rendering
- **WHEN** the current canonical contract no longer equals the proposal base snapshot
- **THEN** Revise plan and Keep current plan SHALL both fail closed as stale
- **AND** neither action SHALL write a decision against the wrong contract.

#### Scenario: Stop is submitted against stale rendering
- **WHEN** target-bound Stop is submitted after proposal/checkpoint rendering changed
- **THEN** Stop SHALL remain allowed because it withdraws consent
- **AND** it SHALL follow terminal monotonicity and race precedence.

### Requirement: Proposal transitions are durable before authority changes
Proposal append and every proposal resolution SHALL cross a generation-aware persistence barrier before success is reported or autonomy authority is created or restored. Each resolution SHALL form one authoritative generation containing the resolution, linked trusted user decision, approval or terminal state transition, continuation invalidation or restoration disposition, and an explicit durability hold.

#### Scenario: Proposal append persistence succeeds
- **WHEN** the authoritative proposal pause is persisted
- **THEN** `propose_revision` MAY return success
- **AND** all gates SHALL observe the pending pause.

#### Scenario: Proposal append persistence fails
- **WHEN** the proposal generation cannot be durably persisted
- **THEN** the operation SHALL fail closed and remain retryable
- **AND** no new work SHALL start based on an in-memory-only transition.

#### Scenario: Resolution generation is installed
- **WHEN** Revise, Keep, or Stop is accepted in authoritative state
- **THEN** one generation SHALL contain the proposal resolution, linked trusted user decision, `revisionRequested` or unchanged-approved or terminal state as applicable, continuation invalidation or restoration disposition, and a durability hold
- **AND** no field from that generation SHALL independently restore authority.

#### Scenario: Resolution generation persists
- **WHEN** the generation-aware barrier confirms that exact generation is durable
- **THEN** the app MAY clear its durability hold and expose only the authority permitted by the complete outcome
- **AND** every final start or continuation enqueue SHALL revalidate no pending proposal, no durability hold, and Stop precedence.

#### Scenario: Resolution persistence fails
- **WHEN** the resolution generation cannot be durably persisted
- **THEN** the explicit durability hold SHALL remain fail-closed across follow-through, child-question availability, continuation, and policy gates
- **AND** approved authority SHALL NOT resume from the in-memory resolution
- **AND** retry or reload SHALL reconcile from the last durable generation without creating a conflicting effective resolution.

### Requirement: Trusted proposal outcomes have distinct authority effects
The trusted transaction SHALL map Revise plan, Keep current plan, and Stop Mission to distinct append-only outcomes.

#### Scenario: User chooses Revise plan
- **WHEN** the Revise transaction passes CAS and its full authoritative generation persists
- **THEN** that generation SHALL contain `acceptedForConcreteRevision`, the linked user decision, prior-continuation invalidation, and `revisionRequested`
- **AND** it SHALL require later approval of a concrete replacement plan before execution resumes.

#### Scenario: User chooses Keep current plan
- **WHEN** the Keep transaction passes CAS and its full authoritative generation persists
- **THEN** that generation SHALL contain `rejected`, the linked user decision, unchanged approved state, and restored continuation disposition
- **AND** only after the durability hold clears SHALL still-pending child questions become answerable and eligible follow-through be evaluated once.

#### Scenario: User chooses Stop Mission
- **WHEN** Stop targets the Mission while a proposal is pending
- **THEN** one authoritative generation SHALL contain the stopped/terminal proposal resolution, linked Stop decision, terminal Mission state, continuation invalidation, and durability hold
- **AND** no continuation or new start SHALL win the race.

#### Scenario: Another trusted action changes contract identity
- **WHEN** a manual revision flow or trusted pace, `childAsk`, autonomy, or policy action alters fields included in contract identity
- **THEN** one authoritative generation SHALL contain the trusted contract change, `invalidatedContractChanged`, old-contract continuation invalidation, checkpoint removal, and the durability hold
- **AND** no child-question availability or follow-through SHALL resume before that generation persists
- **AND** after persistence existing unanswered child interactions SHALL return to ordinary projection and interaction policy under the resulting contract
- **AND** any later revision request SHALL require a new proposal against the new canonical base contract.

### Requirement: Exact revised-plan approval is absent from v1
The system SHALL NOT offer one-click exact revised-plan approval until a later accepted contract defines a complete replacement/diff, acceptance-time rebasing, runtime-field-preserving application, active-node reconciliation, authority rotation, and dedicated validation.

#### Scenario: Proposal checkpoint is rendered
- **WHEN** a summary proposal awaits user action
- **THEN** its positive revision action SHALL be named **Revise plan**
- **AND** it SHALL NOT be named **Approve revised plan** or imply that an exact replacement is available.

### Requirement: Revised-plan UX preserves the trusted approval door
The promise check and material delta are review evidence only. They SHALL NOT approve or ratify a proposal. The concrete revised Mission Plan SHALL continue through the existing exact plan-approval transaction and checkpoint identity.

#### Scenario: User approves the concrete revised plan
- **WHEN** the revised-plan promise check and delta are visible
- **THEN** neither artifact SHALL grant execution authority
- **AND** only the existing exact plan-approval transaction SHALL approve the concrete plan.
