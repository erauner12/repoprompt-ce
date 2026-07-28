## ADDED Requirements

### Requirement: Pending revision proposal is a hard autonomy pause
A pending material revision proposal SHALL prevent autonomous advancement at delegated-run, Auto-mode, follow-through, continuation, MCP transition, and reducer boundaries.

#### Scenario: New delegated work is requested
- **WHEN** `agent_run` or `agent_explore` is requested while a proposal is pending
- **THEN** the request SHALL be blocked before preapproval planning exceptions or concurrency checks
- **AND** planning/probe exceptions SHALL NOT bypass the proposal pause.

#### Scenario: Automatic user-surrogate behavior is considered
- **WHEN** Director `childAsk:auto` or another automatic user-surrogate decision would run while a proposal is pending
- **THEN** Auto-mode SHALL return an early proposal-specific hold
- **AND** it SHALL NOT author a user decision.

#### Scenario: Follow-through is evaluated
- **WHEN** the app evaluates automatic follow-through, gate-cleared resume, coordinator-only completion, or post-approval continuation
- **THEN** it SHALL reconcile terminal observations first
- **AND** it SHALL hold before delivery, resume, completion, or new advancement.

#### Scenario: Runtime tries to advance Mission Plan state
- **WHEN** a runtime update would start a node, bind a new session/interaction, transition pending or blocked work to running, mark coordinator-only work complete, advance Mission status as if new work started, or change the approved contract
- **THEN** the transition SHALL be rejected by MCP and reducer validation.

### Requirement: Pending proposal permits bounded bookkeeping and observation
The pending-proposal pause SHALL continue to accept state needed for honest reconciliation, user control, and observability without authorizing new work.

#### Scenario: Already-running child reports terminal output
- **WHEN** terminal output arrives from work that started before the proposal
- **THEN** the system SHALL accept the output and applicable evidence-valid terminal transition.

#### Scenario: Runtime records non-advancing state
- **WHEN** the runtime appends evidence, failure, or changed-assumption bookkeeping, transitions running to blocked, or transitions running/blocked to evidence-valid terminal state
- **THEN** the system SHALL accept the mutation
- **AND** it SHALL NOT treat the mutation as restored authority.

#### Scenario: Existing child question is held
- **WHEN** a revision proposal becomes pending while a child interaction already awaits an answer
- **THEN** the existing interaction SHALL remain persisted but unavailable/disabled with reason `held pending revision proposal`
- **AND** the proposal SHALL become the highest-priority active checkpoint.

#### Scenario: Already-running child asks a new question
- **WHEN** a child that started before the proposal produces a new question while the proposal remains pending
- **THEN** the interaction SHALL be persisted but unavailable/disabled with reason `held pending revision proposal`
- **AND** it SHALL NOT displace the proposal checkpoint.

#### Scenario: User submits an answer while held
- **WHEN** any caller attempts to answer a child interaction held by a pending revision proposal
- **THEN** the submit SHALL fail closed with the hold reason
- **AND** the system SHALL NOT record an answer, queue an answer, resume the child, or enqueue delivery.

#### Scenario: Held child completes independently
- **WHEN** an already-running child terminalizes while its question is held
- **THEN** terminal completion SHALL be accepted
- **AND** the obsolete persisted question SHALL be removed.

#### Scenario: External user stops
- **WHEN** an external user invokes Stop while a proposal is pending
- **THEN** the user action SHALL remain available
- **AND** Stop SHALL win races.

#### Scenario: Observer reads Mission state
- **WHEN** a caller requests status, waits, events, or receipt state
- **THEN** observation SHALL remain available and reflect the pending proposal.

### Requirement: Continuation lifecycle follows proposal outcome
A proposal SHALL defer but not invalidate an otherwise deliverable post-approval continuation at filing time, and later resolution SHALL restore or invalidate that authority according to outcome.

#### Scenario: Proposal is filed before continuation dispatch
- **WHEN** an authorized continuation is deliverable and a proposal becomes pending
- **THEN** continuation SHALL be deferred with a proposal-specific reason
- **AND** its authority SHALL remain recoverable if the user keeps the current plan.

#### Scenario: User keeps current plan
- **WHEN** the rejected resolution, linked user decision, unchanged approved state, restored continuation disposition, and durability hold are persisted as one authoritative generation
- **THEN** the proposal hold SHALL clear and any still-pending child interaction SHALL become active/answerable again
- **AND** ordinary eligibility evaluation SHALL run once.

#### Scenario: User requests plan revision
- **WHEN** `acceptedForConcreteRevision` is durably persisted
- **THEN** continuation authority for the old contract SHALL be invalidated
- **AND** child questions SHALL remain held throughout `revisionRequested` and concrete revised-plan drafting.

#### Scenario: Revised plan is approved
- **WHEN** a concrete revised plan is durably approved after `revisionRequested`
- **THEN** each held child interaction SHALL be revalidated against the new plan
- **AND** it SHALL become active/answerable only if still applicable, otherwise it SHALL be canceled or superseded.

#### Scenario: Mission stops or terminalizes
- **WHEN** Stop or independent Mission terminalization resolves the proposal
- **THEN** continuation authority SHALL be invalidated through terminal Mission logic
- **AND** held child questions SHALL be canceled.

#### Scenario: Work is finally enqueued
- **WHEN** any start or continuation reaches its final enqueue point
- **THEN** it SHALL revalidate that no proposal is pending and Stop has not won the race.
