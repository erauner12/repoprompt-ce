## ADDED Requirements

### Requirement: Named Agent Mode MCP policy context
The system SHALL carry Agent Mode MCP run-lease and connection-policy installer fields through a named policy context or equivalent typed structure.

#### Scenario: Policy context replaces positional privilege plumbing
- **WHEN** Agent Mode installs or leases MCP connection policy for a run
- **THEN** policy fields SHALL be grouped in a named context or equivalent typed structure
- **AND** implementation SHALL NOT rely on long positional privilege/tool-policy argument forwarding between Agent Mode run lease and connection-policy installer call sites.

#### Scenario: Existing policy fields are preserved
- **WHEN** the named context is used
- **THEN** it SHALL preserve effective policy fields including client/window/run identity, restricted tools, additional tools, one-shot behavior, reason, TTL, run purpose, task label, external-control tool availability, expected-PID behavior, and Coordinator runtime marker state
- **AND** Codex and non-Codex Agent Mode run paths SHALL carry equivalent policy state.

### Requirement: Durable Coordinator runtime policy marker
The system SHALL carry `isCoordinatorRuntime` as typed Agent Mode MCP policy context.

#### Scenario: Trusted Coordinator runtime context is installed
- **WHEN** the trusted Coordinator runtime launch or Agent Mode policy path installs policy for a Coordinator runtime
- **THEN** the policy context SHALL set `isCoordinatorRuntime=true`
- **AND** the marker SHALL be preserved in pending connection policy, run-scoped policy state, effective connection policy, and captured request metadata.

#### Scenario: Coordinator task label normalizes on trusted path
- **WHEN** a trusted Agent Mode policy context contains task label `.coordinator`
- **THEN** the effective Coordinator runtime marker MAY normalize to true
- **AND** that normalization SHALL apply only inside trusted policy-context construction or cache restoration paths.

#### Scenario: Non-Coordinator session uses ordinary policy
- **WHEN** an ordinary `pair`, `engineer`, `explore`, `design`, or unlabeled Agent Mode run installs policy
- **THEN** `isCoordinatorRuntime` SHALL remain false
- **AND** the connection SHALL NOT receive Coordinator runtime actor attribution or runtime-scoped behavior.

### Requirement: Coordinator runtime context cannot be spoofed
The system SHALL NOT grant Coordinator runtime policy context from untrusted caller-controlled strings or ambiguous metadata.

#### Scenario: Tool argument names Coordinator
- **WHEN** a caller passes `model_id:"coordinator"`, a session name containing Coordinator, a raw JSON argument, transcript text, or other caller-controlled data naming Coordinator
- **THEN** that data SHALL NOT by itself set `isCoordinatorRuntime`
- **AND** ordinary session creation paths SHALL continue to require the dedicated Coordinator runtime launch path.

#### Scenario: Context is missing or ambiguous
- **WHEN** request metadata lacks verified Coordinator runtime policy context or cannot resolve the owning runtime Mission
- **THEN** Coordinator-runtime-only behavior SHALL fall back to caller-appropriate non-Coordinator behavior or reject fail-closed
- **AND** it SHALL NOT infer Coordinator status from selected UI state, client name, task label text outside policy context, or demo booleans.

### Requirement: Conservative actor attribution
The system SHALL derive Coordinator runtime vs external caller attribution from verified request metadata.

#### Scenario: Runtime records a Director decision
- **WHEN** `coordinator_chat` receives a runtime call with verified `isCoordinatorRuntime=true`
- **THEN** runtime-authored Mission decisions and evidence SHALL be attributed to the Director/runtime actor where allowed by `add-coordinator-mode`
- **AND** user-action parity operations SHALL remain unavailable to the runtime.

#### Scenario: External caller records user action
- **WHEN** an external user/CLI path invokes an allowed user-action operation
- **THEN** the operation MAY record a user-actor decision through the external path
- **AND** it SHALL NOT be treated as a Director/runtime action merely because it references a Coordinator Mission.

### Requirement: MCP policy cache preserves Coordinator context
The system SHALL preserve Coordinator runtime context across MCP run-policy caching and reconnect/handover.

#### Scenario: Run policy state is cached
- **WHEN** Agent Mode policy is admitted or seeded for a run
- **THEN** cached run-scoped policy state SHALL include `isCoordinatorRuntime`
- **AND** later effective policy reads for that run SHALL return the same marker unless a newer trusted policy supersedes it.

#### Scenario: Connection is rehydrated from cached policy
- **WHEN** a live reconnect, handover, or tab-context rebind reapplies cached run policy state
- **THEN** the rehydrated connection SHALL preserve the Coordinator runtime marker
- **AND** request metadata captured after rehydration SHALL expose the preserved marker.

#### Scenario: Cache miss occurs
- **WHEN** no trusted cached policy exists for a reconnecting connection or run
- **THEN** the system SHALL NOT infer `isCoordinatorRuntime` from client name, session key, selected Mission, or role-label strings
- **AND** Coordinator runtime-only operations SHALL reject or behave as non-Coordinator according to their own operation contract.
