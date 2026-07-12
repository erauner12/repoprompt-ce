## ADDED Requirements

### Requirement: Pending revision proposal is the highest-priority active checkpoint
Coordinator mode SHALL derive exactly one pending revision-proposal decision item from canonical Mission Plan state and SHALL make it the active checkpoint ahead of every child interaction.

#### Scenario: Proposal becomes pending
- **WHEN** a selected Mission has one unresolved revision proposal
- **THEN** projection SHALL add exactly one revision-proposal decision source/reference and exactly one Needs You decision item
- **AND** it SHALL make the proposal the highest-priority active checkpoint
- **AND** display payload SHALL be resolved from `rail.missionPlan` by proposal ID at render time.

#### Scenario: Projection refreshes
- **WHEN** the same unresolved proposal is projected repeatedly
- **THEN** its decision and checkpoint identities SHALL remain stable across runtime-only plan revisions
- **AND** identity SHALL be scoped by Coordinator session, proposal ID, and base contract fingerprint.

#### Scenario: Proposal resolves or terminalizes
- **WHEN** the proposal gains an effective resolution or the Mission terminalizes
- **THEN** the pending proposal item SHALL leave the active decision queue
- **AND** retained lifecycle history MAY remain visible in status or receipt detail.

#### Scenario: Trusted contract dial invalidates the proposal
- **WHEN** a trusted pace, `childAsk`, autonomy, or policy action changes a field included in contract identity
- **THEN** the same authoritative generation SHALL resolve the proposal as `invalidatedContractChanged`, invalidate old-contract continuation, install the durability hold, and remove its decision item/checkpoint
- **AND** the old checkpoint SHALL NOT accept Revise plan or Keep current plan
- **AND** child interactions SHALL return to ordinary projection only after persistence under the resulting contract
- **AND** a new proposal SHALL be required against the changed base contract.

### Requirement: Proposal checkpoint has proposal-specific trusted actions
The revision-proposal card SHALL present exactly **Revise plan**, **Keep current plan**, and **Stop Mission** as its three user actions.

#### Scenario: User chooses Revise plan
- **WHEN** the user activates Revise plan
- **THEN** the UI SHALL submit proposal ID, expected contract identity, and expected checkpoint instance ID to the trusted resolution transaction
- **AND** it SHALL describe the next step as concrete-plan revision and later approval, not immediate replacement approval.

#### Scenario: User chooses Keep current plan
- **WHEN** the user activates Keep current plan
- **THEN** the UI SHALL submit the same CAS identities to the trusted rejection transaction
- **AND** it SHALL preserve the current approved contract.

#### Scenario: User chooses Stop Mission
- **WHEN** the user activates Stop Mission
- **THEN** the UI SHALL route through the app-owned target-bound Stop transaction.

#### Scenario: Exact replacement data is absent
- **WHEN** the checkpoint action arguments are constructed
- **THEN** they SHALL NOT duplicate proposal payload or include an exact replacement plan
- **AND** the card SHALL NOT expose an **Approve revised plan** action in v1.

### Requirement: Proposal checkpoint precedence is deterministic
Coordinator mode SHALL select active checkpoints in this order: pending revision proposal, pending selected-Mission child interaction when no proposal is pending, concrete plan approval, then step boundary.

#### Scenario: Child interaction and proposal are both pending
- **WHEN** both sources are projectable
- **THEN** the revision proposal SHALL be the sole active checkpoint
- **AND** the child interaction SHALL remain persisted but unavailable/disabled with reason `held pending revision proposal`.

#### Scenario: Held child question receives submit
- **WHEN** the user attempts to answer a held child interaction while the proposal checkpoint is active
- **THEN** the UI SHALL reject submission with the hold reason
- **AND** it SHALL NOT record or queue an answer.

#### Scenario: Proposal and plan approval or step boundary coexist
- **WHEN** recovery or inconsistent legacy state exposes those sources together
- **THEN** the revision proposal SHALL take precedence
- **AND** plan approval and step boundary SHALL NOT bypass the proposal pause.

#### Scenario: Normal approved Mission has a proposal
- **WHEN** a proposal is pending under the normal v1 lifecycle
- **THEN** concrete plan approval and step boundary SHOULD be unreachable because the Mission remains approved and follow-through is held
- **AND** projection SHALL still enforce the explicit precedence defensively.

### Requirement: Child-question projection follows proposal outcomes
Coordinator mode SHALL preserve held child interactions without accepting answers and SHALL transition them according to the trusted proposal outcome.

#### Scenario: User keeps current plan
- **WHEN** Keep current plan becomes durable
- **THEN** the existing still-pending child interaction SHALL become active/answerable again.

#### Scenario: User requests revision
- **WHEN** Revise plan becomes durable
- **THEN** child interactions SHALL remain unavailable throughout `revisionRequested` and concrete revised-plan drafting.

#### Scenario: Revised plan is approved
- **WHEN** concrete revised-plan approval becomes durable
- **THEN** each held interaction SHALL be restored only if it remains applicable to the new plan
- **AND** otherwise it SHALL be canceled or superseded.

#### Scenario: Mission stops or child completes
- **WHEN** Stop becomes durable or the child independently terminalizes
- **THEN** Stop SHALL cancel held questions and child terminal completion SHALL remove its obsolete question.

### Requirement: Proposal display and observability remain state-derived
Coordinator mode SHALL display summary-only proposal lifecycle state from canonical Mission data and SHALL remain consistent with MCP status/wait/event projection.

#### Scenario: Proposal card renders
- **WHEN** the proposal is pending
- **THEN** the card SHALL show summary, rationale, material-field categories, base contract identity, and proposal lifecycle without inventing a replacement diff.

#### Scenario: App restarts with pending proposal
- **WHEN** persisted Mission state is restored
- **THEN** the same proposal SHALL reproject as Needs You with stable checkpoint identity
- **AND** autonomous advancement SHALL remain paused.

#### Scenario: Proposal resolution is shown
- **WHEN** a proposal is accepted for concrete revision, rejected, invalidated, or stopped
- **THEN** user-facing status and minimal receipt history SHALL describe the actual outcome
- **AND** it SHALL NOT imply exact plan approval, execution completion, merge, commit, push, or deployment.

### Requirement: Mission composer is state-aware during revision flows
Coordinator mode SHALL expose one Mission composer and SHALL NOT render a second plan-revision composer. Cards remain the authority surface for proposal resolution, plan approval, and Stop.

#### Scenario: Proposal awaits a decision
- **WHEN** a revision proposal is pending
- **THEN** the composer SHALL invite optional guidance with **Revise plan, and consider...**
- **AND** Enter/send SHALL NOT deliver, queue, or resolve that guidance independently
- **AND** inline copy SHALL state that decisions happen on the card and composer text is used only if Revise plan is chosen
- **AND** Revise plan SHALL atomically consume the rendered Mission/proposal identities and the exact current guidance
- **AND** Keep current plan and Stop Mission SHALL ignore the guidance
- **AND** the card SHALL state that the user will review the revised plan before work resumes.

#### Scenario: Accepted revision is being drafted
- **WHEN** an accepted proposal lineage is in `revisionRequested`
- **THEN** the composer SHALL invite **Add guidance for the revised plan...**
- **AND** send SHALL carry the rendered Mission and accepted-resolution identities through the narrow accepted-revision drafting path
- **AND** it SHALL NOT fall back to generic old-contract execution.

#### Scenario: Concrete revised plan awaits approval
- **WHEN** an accepted proposal lineage has produced a concrete plan in `awaitingApproval`
- **THEN** the composer SHALL invite **Request another change...**
- **AND** send SHALL request revision through the trusted rendered plan-checkpoint path before using accepted-resolution drafting authority
- **AND** send SHALL never approve the revised plan.

#### Scenario: Mission is in an ordinary approved or executing state
- **WHEN** no active revision flow owns composer routing
- **THEN** the composer SHALL invite **Message the Director...** and use ordinary Director messaging.

#### Scenario: Selection changes during send
- **WHEN** a composer or card action starts and the selected Mission changes before asynchronous work completes
- **THEN** the operation SHALL retain the rendered Mission and revision identities
- **AND** it SHALL fail closed rather than retargeting the newly selected Mission.

### Requirement: Plan Revision container morphs through revised approval
The Plan Revision container SHALL derive post-Revise state from the latest accepted-for-concrete-revision resolution/proposal lineage. It SHALL show drafting during `revisionRequested`, **Approve revised Mission Plan** during `awaitingApproval`, and **Plan revised to address: …** after approval.

#### Scenario: Concrete revised plan awaits approval
- **WHEN** the latest accepted proposal lineage has produced a concrete plan in `awaitingApproval`
- **THEN** the same Plan Revision container SHALL identify the proposal and lead with a promise check
- **AND** it SHALL prominently show changes outside stated affected areas second
- **AND** requested in-scope changes SHALL follow, while unchanged fields remain collapsed by default
- **AND** drafting completion SHALL create exactly one actionable Needs You item while drafting start creates none
- **AND** the full revised plan SHALL remain accessible
- **AND** approval SHALL use the existing exact plan-approval checkpoint transaction.

#### Scenario: Revised plan is approved
- **WHEN** that exact plan-approval transaction completes
- **THEN** the container SHALL collapse to **Plan revised to address: …**
- **AND** no exact proposal-ratification action SHALL be introduced.

#### Scenario: User keeps the original plan
- **WHEN** Keep current plan becomes durable
- **THEN** the same container SHALL morph to **Resumed under the original plan; the Director's concern is recorded.**
- **AND** the collapsed outcome SHALL remain derived from the latest proposal resolution until another revision lifecycle supersedes it or the Mission terminalizes
- **AND** proposal, decision, receipt, contract identity, and ledger history SHALL remain intact.
