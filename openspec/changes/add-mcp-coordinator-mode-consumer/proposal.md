## Why

`MCPServerViewModel.dashboard` already has a shared subscription lifecycle used by the toolbar popover and status view. Coordinator mode should consume the same MCP update stream, but adding another consumer touches shared MCP infrastructure that existing surfaces rely on. This should land as a small prerequisite before the Coordinator mode UI consumes it.

## What Changes

- Add an explicit Coordinator mode consumer identity to `MCPServerViewModel.DashboardConsumer`.
- Preserve the existing ref-counted MCP update lifecycle across toolbar popover, status view, and the new Coordinator mode consumer.
- Validate that one shared subscription remains active while any consumer is visible and stops only after the last consumer hides.
- Do not add Coordinator mode UI or Coordinator mode snapshot logic in this change.

## Capabilities

### New Capabilities
- `mcp-coordinator-mode-consumers`: Allows multiple named MCP consumers, including the future Coordinator mode, to share the existing MCP update stream safely.

### Modified Capabilities

None.

## Impact

- MCP infrastructure: extends `MCPServerViewModel.DashboardConsumer` and validates shared subscription behavior.
- Existing MCP UI: toolbar popover and status view must continue to subscribe/unsubscribe without regression.
- Coordinator mode: can depend on this change for its compact MCP footer/popover.
- Tests: requires lifecycle coverage for third-consumer visibility and last-consumer cleanup.
