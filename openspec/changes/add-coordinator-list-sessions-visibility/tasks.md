## 1. Scope definition

- [ ] 1.1 Confirm this change depends on `add-coordinator-role` and remains deferrable from launched-fleet-only Coordinator v1.
- [ ] 1.1a Confirm broad visibility is gated by verified Coordinator role identity plus typed Coordinator policy context, not by the production-demo boolean marker.
- [ ] 1.2 Define the first broad visibility scope as current-window active-workspace supervised sessions unless a later accepted design chooses another scope.
- [ ] 1.3 Name the Coordinator mode projection/input that serves as the membership parity source.
- [ ] 1.4 Define how Coordinator runtimes are excluded from returned rows through the accepted Coordinator identity/policy predicate.

## 2. `list_sessions` scope behavior

- [ ] 2.1 Add or specify the Coordinator-policy visibility path in `AgentManageMCPToolService.executeListSessions`.
- [ ] 2.2 Preserve existing spawn-parent / child-scoped behavior for ordinary in-app Agent callers.
- [ ] 2.3 Ensure callers without verified Coordinator policy context cannot opt into Coordinator broad visibility by arguments alone.
- [ ] 2.4 Keep cross-window listing out of scope unless a later accepted spec grants it.

## 3. Tests and validation

- [ ] 3.1 Add leakage tests proving ordinary in-app Agent callers remain child-scoped.
- [ ] 3.2 Add Coordinator broad-list tests proving sessions the Coordinator did not spawn are included when in scope.
- [ ] 3.3 Add tests proving the Coordinator runtime itself is excluded from returned rows.
- [ ] 3.4 Add parity tests against the named Coordinator mode projection/input, excluding ordering, pagination, and transient liveness differences.
- [ ] 3.4a Add a parity assertion that the aggregate board does not display a broader supervised set than the Coordinator-visible `list_sessions` scope.
- [ ] 3.5 Run `openspec validate add-coordinator-list-sessions-visibility`.
