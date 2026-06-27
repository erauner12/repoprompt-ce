## Context

Agent Mode MCP policy state currently flows through several related seams:

- `AgentModeMCPPolicyInstaller`
- `AgentModeRunLease`
- `MCPBootstrapLeaseSpec.agentMode`
- `MCPBootstrapLease.agentModePolicyInstaller`
- `AgentModeViewModel.ConnectionPolicyInstaller`
- `CodexAgentModeCoordinator.ConnectionPolicyInstaller`
- `ServerNetworkManager.installClientConnectionPolicy`

The fields include client/window/run identity, restricted tools, additional tools, one-shot behavior, policy reason/TTL, run purpose, task label, external-control tool availability, and expected-PID enforcement. These are privilege-bearing values, so a positional call-site mismatch is high impact even when the compiler accepts it.

## Goals / Non-Goals

**Goals:**

- Replace the long positional Agent Mode MCP policy installer path with a named context or equivalent typed structure.
- Preserve all current behavior exactly.
- Establish characterization coverage or a concrete regression anchor before refactoring.
- Make future Coordinator privilege additions named-field changes instead of positional-argument changes.

**Non-Goals:**

- Adding the Coordinator role marker.
- Changing granted or restricted tools.
- Changing Agent Mode MCP advertisement policy.
- Changing `agent_run` / `agent_manage` behavior.
- Changing `list_sessions` visibility.

## Decisions

### 1. This is a no-behavior-change prerequisite

The refactor should be reviewed as plumbing fidelity, not as a Coordinator feature. It is valuable independently because the current policy installer carries security-sensitive fields through a fragile positional interface.

### 2. Characterization comes before mutation

Before replacing the installer shape, implementation should identify existing regression coverage or add focused characterization coverage that proves current policy behavior is preserved. The proof target includes restricted tools, additional/granted tools, task-label policy, top-level-only external-control tools, expected-PID routing, and Codex/non-Codex lease paths.

### 3. The context should cover current fields only

The named context should initially carry the current effective policy fields. Coordinator-specific fields should be added by the later Coordinator role implementation after this prerequisite lands.

## Risks / Trade-offs

- **Silent privilege regression** → require characterization coverage before mutation.
- **Scope creep** → do not add Coordinator marker or tool-policy changes in this refactor.
- **Partial migration** → migrate Codex and non-Codex Agent Mode paths together so behavior remains consistent.
