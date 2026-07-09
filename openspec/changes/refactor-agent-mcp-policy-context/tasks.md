## 1. Named policy context

- [x] 1.1 Keep Agent Mode MCP policy fields in a named context instead of positional privilege arguments.
- [x] 1.2 Preserve existing tool restrictions, additional tools, run purpose, task-label context, external-control availability, expected-PID behavior, and Codex/non-Codex lease paths.

## 2. Coordinator runtime marker propagation

- [x] 2.1 Include durable `isCoordinatorRuntime` in Agent Mode MCP policy context.
- [x] 2.2 Preserve the marker through pending connection policy and run-scoped policy cache.
- [x] 2.3 Preserve the marker through reconnect/handover and request metadata capture.
- [x] 2.4 Normalize `.coordinator` task-label context to the runtime marker only on trusted policy construction/cache paths.

## 3. Spoofing and attribution invariants

- [x] 3.1 Ensure caller-controlled strings, `model_id` arguments, session names, transcript text, client names, selected UI state, and demo booleans do not spoof Coordinator runtime context.
- [x] 3.2 Ensure missing or ambiguous Coordinator context falls back to non-Coordinator behavior or fails closed.
- [x] 3.3 Ensure runtime callers are attributed as Director/runtime actor only when verified by request metadata.
- [x] 3.4 Ensure external user-action parity remains external-only and is not forged by runtime callers.

## 4. Validation

- [x] 4.1 Run `openspec validate refactor-agent-mcp-policy-context` after reconciliation.
