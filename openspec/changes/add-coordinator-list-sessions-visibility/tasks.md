## 1. Scope definition

- [ ] 1.1 Confirm this change depends on `add-coordinator-role` and remains deferrable from launched-fleet-only Coordinator v1.
- [ ] 1.2 Define the first broad visibility scope as current-window active-workspace supervised sessions unless a later accepted design chooses another scope.
- [ ] 1.3 Name the Coordinator mode projection/input that serves as the membership parity source.
- [ ] 1.4 Define how Coordinator-marked runtimes are excluded from returned rows.

## 2. `list_sessions` scope behavior

- [ ] 2.1 Add or specify the Coordinator-marked visibility path in `AgentManageMCPToolService.executeListSessions`.
- [ ] 2.2 Preserve existing spawn-parent / child-scoped behavior for ordinary in-app Agent callers.
- [ ] 2.3 Ensure non-Coordinator callers cannot opt into Coordinator broad visibility by arguments alone.
- [ ] 2.4 Keep cross-window listing out of scope unless a later accepted spec grants it.

## 3. Tests and validation

- [ ] 3.1 Add leakage tests proving ordinary in-app Agent callers remain child-scoped.
- [ ] 3.2 Add Coordinator broad-list tests proving sessions the Coordinator did not spawn are included when in scope.
- [ ] 3.3 Add tests proving the Coordinator runtime itself is excluded from returned rows.
- [ ] 3.4 Add parity tests against the named Coordinator mode projection/input, excluding ordering, pagination, and transient liveness differences.
- [ ] 3.5 Run `openspec validate add-coordinator-list-sessions-visibility`.
