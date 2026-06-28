## Why

The first Coordinator role can supervise the agents it launched using session handles returned by `agent_run.start`, so broad workspace `list_sessions` visibility is not required for the core v1 delegation loop.

A later Coordinator capability still benefits from seeing sessions it did not spawn: pre-existing Agent Mode work, sibling sessions in the active workspace, and sessions the user expects the Coordinator to summarize or coordinate. That visibility widens an MCP enumeration boundary, so it should be reviewed separately from the role identity.

## What Changes

- Define a Coordinator-specific widening of `agent_manage.list_sessions` visibility.
- Preserve ordinary in-app Agent caller child scoping.
- Limit widened visibility to Coordinator-marked connections.
- Exclude the Coordinator runtime itself from results.
- Define parity with the chosen Coordinator mode projection source for the same current-window active-workspace scope.
- Make the capability explicitly deferrable from launched-fleet-only Coordinator v1.

## Capabilities

### New Capabilities
- `coordinator-list-sessions-visibility`: Defines broad Coordinator `agent_manage.list_sessions` visibility into active-workspace supervised sessions beyond the Coordinator's launched delegated fleet.

### Modified Capabilities

None in the base role. This change depends on `add-coordinator-role` and should not be required for the core role loop.

## Impact

- `agent_manage.list_sessions`: adds a Coordinator-marked visibility mode.
- Ordinary Agent Mode sub-agent scoping: unchanged; ordinary in-app agents remain child-scoped where applicable.
- Coordinator mode projection: provides the parity source for what broad Coordinator listing should be able to see within the chosen current-window scope.
- Coordinator role: may consume this capability when available, but still functions without it by tracking returned delegated session handles.
