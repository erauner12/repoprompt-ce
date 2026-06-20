## 1. Design confirmation

- [ ] 1.1 Ask pvncher whether “new agent role in code” means an MCP-bound role entry or a true in-app non-tab-scoped Agent Mode role.
- [ ] 1.2 Record the accepted runtime-home decision in `design.md`, including the rejected alternative and rationale.
- [ ] 1.3 Review the accepted runtime-home decision with wren, using delegate-vs-focus and MCP-bound-vs-in-app as the explicit discussion forks.
- [ ] 1.4 Update the spec/design with any accepted review changes before implementation begins.

## 2. Role identity and registration

- [ ] 2.1 Add the `coordinator` role identity alongside existing role labels without changing default `pair`, `engineer`, `explore`, or `design` behavior.
- [ ] 2.2 Implement Coordinator runtime launch/binding according to the accepted runtime-home decision.
- [ ] 2.3 Ensure Coordinator runtime identity is distinguishable from workspace Agent Mode sessions in state, logs, and UI-facing metadata.
- [ ] 2.4 Add tests or contract checks proving a Coordinator runtime is not projected as a normal Coordinator mode board/list row.

## 3. Scope and permissions

- [ ] 3.1 Implement the initial top-level/global or explicitly-attached session listing scope chosen by the design.
- [ ] 3.2 Restrict the first Coordinator role toolset to session/model listing, spawn, message/steer, and summarize capabilities.
- [ ] 3.3 Block direct tab focus, tab-scoped file read/search, file-selection mutation, worktree mutation, approval/decline, cancel, and stop unless a later spec grants them.
- [ ] 3.4 Add focused permission tests for allowed and blocked Coordinator capabilities.

## 4. Coordinator context and history

- [ ] 4.1 Implement the accepted Coordinator history/directive-log storage location outside workspace row projection.
- [ ] 4.2 Restore Coordinator context without creating, restoring, or promoting a supervised workspace session.
- [ ] 4.3 Add tests for history persistence/restoration and board/list invisibility.

## 5. Directive contract

- [ ] 5.1 Define the structured Coordinator directive record with source, target, action type, status, and failure fields.
- [ ] 5.2 Implement the initial directive verbs: list, spawn, message/steer, and summarize.
- [ ] 5.3 Surface directive delivery/completion/failure states without parsing assistant prose.
- [ ] 5.4 Add tests for successful directives, failed delivery, and unsupported higher-risk actions.

## 6. Coordinator view integration

- [ ] 6.1 Wire Coordinator mode to show the real Coordinator runtime when available while preserving the existing manual selected-session composer as a demo/manual fallback until migration is decided.
- [ ] 6.2 Ensure the real Coordinator runtime never appears in `CoordinatorModeSnapshot.groups` as a supervised row.
- [ ] 6.3 Decide whether to retire, hide, or keep the manual selected-session composer after the real role is stable.
- [ ] 6.4 Add UI/snapshot coverage for no Coordinator runtime, real Coordinator runtime available, and manual fallback states.

## 7. Validation

- [ ] 7.1 Run `openspec validate add-coordinator-role` after each spec/design change.
- [ ] 7.2 Run focused role/scope/directive tests added by this implementation.
- [ ] 7.3 Run the smallest relevant coordinated Swift build/test lanes for touched app/MCP files.
- [ ] 7.4 Run contribution preflight before commit and push.
