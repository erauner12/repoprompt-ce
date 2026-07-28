## Why

Agent Mode MCP policy is privilege-bearing: it controls tool restrictions, additional tools, run purpose, task-label context, expected-PID routing, and now whether a connection is the Coordinator runtime. The current Coordinator/Director Mission baseline relies on this plumbing to decide actor attribution and runtime-scoped behavior without trusting model text or caller-supplied arguments.

This change reconciles the original no-behavior plumbing refactor with the implemented core runtime baseline: the named policy context exists, and the durable `isCoordinatorRuntime` marker is now the typed privilege/context bit that must survive leases, reconnects, cached run policy state, and request metadata.

## What Changes

- Keep Agent Mode MCP policy fields grouped in a named policy context instead of long positional argument forwarding.
- Add/own the durable `isCoordinatorRuntime` policy context marker and its preservation through run lease, connection policy, cached run policy state, reconnect/handover, and request metadata.
- Normalize `.coordinator` task-label policy into Coordinator runtime context only on trusted Agent Mode policy paths; user/tool arguments must not spoof Coordinator attribution.
- Preserve ordinary Agent Mode behavior for all non-Coordinator connections.
- Require conservative actor attribution: only a verified Coordinator runtime connection may be treated as Director/runtime actor; ambiguous or missing context falls back to non-Coordinator behavior or fails closed.

## Capabilities

### New Capabilities
- `agent-mcp-policy-context`: Defines typed Agent Mode MCP policy context, including the durable Coordinator runtime marker and conservative policy-cache/request-metadata propagation invariants.

### Modified Capabilities

None for user-visible tool permissions. Core Mission runtime behavior remains in `add-coordinator-mode`; role semantics remain in `add-coordinator-role`.

## Impact

- Agent Mode run lease plumbing: forwards named context, including `isCoordinatorRuntime`, instead of positional privilege fields.
- MCP connection policy/cache: preserves Coordinator runtime context in pending policy, run-scoped policy state, live reconnect/handover, and request metadata.
- `coordinator_chat`: can distinguish runtime callers from external callers for Director actor attribution and external-only operation gates.
- Ordinary Agent Mode sessions: remain non-Coordinator unless the trusted launch/policy path marks them as Coordinator runtime.
