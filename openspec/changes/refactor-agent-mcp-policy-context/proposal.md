## Why

Agent Mode run leases and MCP connection-policy installation currently pass privilege and tool-policy fields through long positional argument lists. The Coordinator role will need to thread additional privilege state through this path, and adding one more positional argument would make a silent privilege-boundary miswiring easy to compile.

This change proposes a no-behavior-change prerequisite refactor: collapse Agent Mode MCP policy installation plumbing into a named policy context before Coordinator-specific privilege fields are introduced.

## What Changes

- Introduce a named Agent Mode MCP policy context or equivalent typed structure for the existing policy fields.
- Route existing Agent Mode lease/install paths through the named context instead of many positional arguments.
- Preserve current behavior for restricted tools, granted tools, task-label policy, external-control tool availability, expected-PID routing, and Codex/non-Codex lease paths.
- Add or identify characterization coverage proving the refactor is behavior-preserving before any Coordinator-specific marker is added.

## Capabilities

### New Capabilities
- `agent-mcp-policy-context`: Defines a named policy context for Agent Mode MCP run-lease / connection-policy installation.

### Modified Capabilities

None. This is prerequisite plumbing and should not change caller-visible MCP behavior.

## Impact

- Agent Mode run lease plumbing: replaces positional privilege/tool-policy argument forwarding with a named context.
- MCP connection policy installation: continues to install the same effective policy fields with the same semantics.
- Coordinator role: depends on this change before adding Coordinator privilege state.
- No changes to Coordinator runtime identity, tool permissions, `list_sessions` scope, or production behavior are intended.
