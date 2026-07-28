## 1. Reconcile role scope with core runtime

- [x] 1.1 Cross-reference `add-coordinator-mode` as the owner of Mission Plan, Mission Policy, childAsk, evidence, status/events, receipt, stop/archive, and E2E runtime doctrine.
- [x] 1.2 Remove duplicate lifecycle/tool/autonomy requirements from this supporting role change.
- [x] 1.3 Keep this change focused on role naming, dedicated launch/marker, model selection, and ordinary-role separation.

## 2. Director / Coordinator vocabulary

- [x] 2.1 Specify Director as user-facing supervisory actor vocabulary.
- [x] 2.2 Specify Coordinator as the technical contract name for Swift, MCP, persistence, fixtures, and debug payloads.
- [x] 2.3 Leave any full technical rename to a later no-behavior migration.

## 3. Dedicated role and launch semantics

- [x] 3.1 Document that `coordinator` may be exposed as a role/model-binding label.
- [x] 3.2 Require ordinary `agent_run` / `agent_manage` session-creation paths to reject `model_id:"coordinator"` as an ordinary child role.
- [x] 3.3 Require fresh Coordinator runtime creation to install durable Coordinator identity (`isCoordinatorRuntime`) and typed Coordinator policy context.
- [x] 3.4 Keep delegated child sessions ordinary scoped Agent Mode sessions rather than Coordinator runtimes.

## 4. Model override and runtime backing

- [x] 4.1 Specify `coordinator_model_id` as fresh-runtime provider/model selection only.
- [x] 4.2 Specify that model override does not change Director prompt, Coordinator tools, typed policy context, or Mission Policy semantics.
- [x] 4.3 Record that the current branch uses a marked/background Agent Mode session and defers non-enrolled runtime extraction.

## 5. Validation

- [x] 5.1 Run `openspec validate add-coordinator-role` after reconciliation.
