## 1. Characterize current behavior

- [x] 1.1 Identify existing tests or add focused characterization coverage for Agent Mode MCP policy installation behavior.
- [x] 1.2 Cover restricted tools and granted/additional tools.
- [x] 1.3 Cover task-label policy and advertisement-relevant fields.
- [x] 1.4 Cover top-level-only external-control tool availability.
- [x] 1.5 Cover expected-PID routing/enforcement behavior.
- [x] 1.6 Cover Codex and non-Codex Agent Mode lease paths.

## 2. Define named policy context

- [x] 2.1 Define a named Agent Mode MCP policy context or equivalent typed structure for current policy fields.
- [x] 2.2 Include current client/window/run identity fields, tool policy fields, run purpose fields, task-label fields, external-control fields, and expected-PID fields.
- [x] 2.3 Do not add Coordinator-specific marker or privilege fields in this prerequisite change.

## 3. Migrate installer plumbing

- [x] 3.1 Migrate `AgentModeMCPPolicyInstaller` and `AgentModeRunLease` call paths to the named context.
- [x] 3.2 Migrate `MCPBootstrapLeaseSpec.agentMode` / `MCPBootstrapLease.agentModePolicyInstaller` paths to the named context or explicitly document why they are fully covered by the `AgentModeRunLease` migration.
- [x] 3.3 Migrate `AgentModeViewModel.ConnectionPolicyInstaller` usage to the named context or adapter.
- [x] 3.4 Migrate `CodexAgentModeCoordinator.ConnectionPolicyInstaller` usage to the named context or adapter.
- [x] 3.5 Preserve `ServerNetworkManager.installClientConnectionPolicy` effective behavior.

## 4. Validate no behavior change

- [x] 4.1 Run `openspec validate refactor-agent-mcp-policy-context`.
- [x] 4.2 Run focused policy/Agent Mode MCP tests identified in section 1.
- [x] 4.3 Run the smallest relevant coordinated Swift build/test lane for touched Agent Mode/MCP files.
- [x] 4.4 Confirm no Coordinator role marker, Coordinator tool policy, or `list_sessions` visibility behavior was added.
