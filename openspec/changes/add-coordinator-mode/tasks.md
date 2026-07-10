## 1. Mission runtime state

- [x] 1.1 Persist Coordinator follow-through state on Coordinator-backed Agent sessions.
- [x] 1.2 Persist Mission objective summary, selected Mission Template metadata, Mission Plan, observed child phases, pending/handled follow-through event IDs, last resume result, and child interaction response records.
- [x] 1.3 Preserve older persisted payload compatibility by defaulting absent Mission Plan, routing, decision, evidence, and autonomy fields.
- [x] 1.4 Reset Mission Plan/follow-through state for fresh objectives while allowing same-Mission follow-up turns to preserve the plan.

## 2. Mission Plan and ledgers

- [x] 2.1 Implement `CoordinatorMissionPlan` with stable ID, monotonic revision, mission key, objective, predecessor context, status, approval state, template, shape, policy snapshot, autonomy, workstreams, nodes, routing decisions, decision ledger, evidence ledger, events, and updated timestamp.
- [x] 2.2 Implement workstream lane summaries with execution policy, worktree strategy, primary child session, related child sessions, and stable ID/title upsert behavior.
- [x] 2.3 Implement DAG-lite nodes with workflow hints, done criteria, completion evidence, dependencies, execution policy, status, bound session, and bound interaction.
- [x] 2.4 Preserve omitted Mission Plan fields on partial updates.
- [x] 2.5 Upsert workstreams and nodes by ID/title unless explicit replacement is requested.
- [x] 2.6 Upsert routing decisions by ID and sort them chronologically.
- [x] 2.7 Append decisions and evidence with ID-only dedupe; do not replace existing ledger records.
- [x] 2.8 Add deterministic user-decision IDs from checkpoint instance plus label.
- [x] 2.9 Preserve unknown autonomy and decision classes while resolving unknown autonomy to Ask.
- [x] 2.10 Preserve terminal node status against later regression.
- [x] 2.11 Prevent Mission completion while non-terminal nodes remain.

## 3. Mission Policy and autonomy

- [x] 3.1 Add Mission Policy snapshots separate from Mission Templates.
- [x] 3.2 Provide Default, Hands-off, Careful writes, and Read-only built-in policies.
- [x] 3.3 Store default pace, autonomy map, `maxConcurrent`, Definition of Done, standing guidance, pinned skill IDs, and pinned context IDs on policy snapshots.
- [x] 3.4 Define known decision/autonomy classes: `plan`, `advance`, `writes`, `childAsk`, `recover`, and `irreversible`.
- [x] 3.5 Force unknown autonomy classes and irreversible actions to resolve to Ask.
- [x] 3.6 Expose external user-action parity for pace via `coordinator_chat set_pace`.
- [x] 3.7 Expose external user-action parity for `childAsk` via `coordinator_chat set_autonomy`.
- [x] 3.8 Reject runtime callers from user-action parity operations.

## 4. `coordinator_chat` control surface

- [x] 4.1 Implement `list`, `select`, `new`, `ensure_mission`, `start_mission`, and `submit` operations.
- [x] 4.2 Implement `mission_plan` as a state-only update path that does not submit a Coordinator chat turn.
- [x] 4.3 Implement full and compact `mission_status` serialization.
- [x] 4.4 Implement `wait_for_update` using compact Mission status fingerprints.
- [x] 4.5 Implement `mission_events` as an observational sequenced journal.
- [x] 4.6 Implement `receipt format=markdown` from the receipt projection.
- [x] 4.7 Implement `doctor` capability reporting.
- [x] 4.8 Implement `list_missions` lifecycle inventory.
- [x] 4.9 Implement `stop_mission` and `archive_mission` lifecycle operations.
- [x] 4.10 Support `coordinator_model_id` on fresh Coordinator Mission starts/submits without changing Coordinator identity or policy semantics.
- [x] 4.11 Scope runtime caller resolution to the caller Mission and fail closed when unresolved.

## 5. Approval, delegation, and scheduling guardrails

- [x] 5.1 Require Coordinator parents to record a non-empty Mission Plan before normal delegated child starts.
- [x] 5.2 Require `approval_state: approved` before normal runtime progress or delegated starts.
- [x] 5.3 Allow only the documented pre-approval planning exceptions for workflow-less read-only probes, Investigate/Deep Plan planning nodes, and design critique nodes.
- [x] 5.4 Require `mission_node_id` for pre-approval exceptions.
- [x] 5.5 Require matching workflow metadata for workflow-bearing nodes.
- [x] 5.6 Require `worktree_create:true` for pre-approval Investigate/Deep Plan/design critique exceptions.
- [x] 5.7 Enforce policy `maxConcurrent` as a running-node flight cap for both `agent_run.start` and `agent_explore.start`.
- [x] 5.8 Require explicit child worktree isolation for mutable Coordinator delegated work.
- [x] 5.9 Reject mutable Coordinator delegated starts before child creation when no explicit sandbox is provided.
- [x] 5.10 Keep ordinary non-Coordinator Agent Mode starts on their existing worktree behavior.

## 6. childAsk and pending child interactions

- [x] 6.1 Route selected-Mission pending child interactions through `coordinator_chat submit` when active.
- [x] 6.2 Support structured `answers` payloads, freeform text fallback, and explicit `skip` for child interactions.
- [x] 6.3 Record visible child interaction response records in Coordinator follow-through state.
- [x] 6.4 Reject Coordinator runtime child-answer submits unless current `childAsk` autonomy resolves to Auto.
- [x] 6.5 Require Director childAsk decisions and evidence before childAsk:auto bound nodes can complete.
- [x] 6.6 Block generic `agent_run.respond` for active Mission-bound child questions so ledger paths cannot be bypassed.
- [x] 6.7 Preserve actor integrity for Ask → Auto and Auto → Ask rerouting semantics.

## 7. Follow-through runtime

- [x] 7.1 Track observed child phases from Coordinator row/workstream projection.
- [x] 7.2 Enqueue stable follow-through events for child terminal, child question, gate cleared, and eligible work observations.
- [x] 7.3 Deduplicate follow-through events with pending/handled event IDs.
- [x] 7.4 Generate structured resume directives that instruct the Coordinator to inspect compact `mission_status`, respect dependencies, honor `maxConcurrent`, and avoid duplicate starts.
- [x] 7.5 Mark resume events submitted/deferred/rejected without creating new Coordinator parents.
- [x] 7.6 Hold follow-through at active Coordinator turns, Needs-you/Blocked children, human permission boundaries, or ambiguous next steps.
- [x] 7.7 Complete Coordinator-only and terminal-bound running nodes when sourced evidence supports completion.
- [x] 7.8 Keep stale/waiting completion evidence from satisfying completed-node evidence requirements.

## 8. Status, events, receipt, and lifecycle projection

- [x] 8.1 Include shape, policy, autonomy, decision counts, evidence counts, recent ledgers, ready nodes, dependency satisfaction, active nodes, liveness warnings, checkpoint metadata, events, and routing decisions in Mission status outputs.
- [x] 8.2 Include every wait-unblocking ledger/status field in compact fingerprints.
- [x] 8.3 Expose revision-bound plan approval checkpoint instance IDs in compact status.
- [x] 8.4 Reject stale consent-granting checkpoint submits while accepting stale Stop.
- [x] 8.5 Project terminal receipts from Mission-owned state rather than persisted Markdown.
- [x] 8.6 Include objective/summary, policy, decision counts, evidence, and reserved Spend section in receipt Markdown.
- [x] 8.7 Preserve receipt, status, events, decisions, evidence, and lineage after archive.
- [x] 8.8 Reject archive for non-terminal Missions and reject runtime callers from archive.

## 9. Prompt and tool contract alignment

- [x] 9.1 Document `coordinator_chat` as an external/demo control API in the MCP tool schema.
- [x] 9.2 Document Coordinator Mission node hooks on `agent_run` and `agent_explore` schemas.
- [x] 9.3 Instruct Coordinator runtimes to use Mission Plan/status/ledger operations before delegation.
- [x] 9.4 Instruct runtime callers not to start follow-up Missions themselves.
- [x] 9.5 Keep workflow fidelity: planned workflow metadata must match delegated `agent_run` workflow metadata.
- [x] 9.6 Keep Director user-facing vocabulary while using raw Coordinator keys only inside structured payloads/debug contracts.

## 10. Deterministic validation support

- [x] 10.1 Add DEBUG-only scripted child backend selected by `model_id:"scripted"` / scripted selector.
- [x] 10.2 Require the exact scripted prompt line `SCRIPTED_CHILD_V1 ask_marker token=<TOKEN> options=Alpha,Beta`.
- [x] 10.3 Create a real `AgentAskUserInteraction` and complete with `SCRIPTED_CHILD_V1 answer=<Alpha|Beta> token=<TOKEN>`.
- [x] 10.4 Keep scripted child hidden from normal user-facing model lists.
- [x] 10.5 Report scripted child availability through `coordinator_chat doctor`.

## 11. Tests and validation coverage

- [x] 11.1 Add Mission Plan persistence, merge, terminal honesty, policy/autonomy, childAsk, and follow-through tests.
- [x] 11.2 Add `coordinator_chat` tests for start/submit, model override, mission_plan, mission_status, wait/update, set_pace, set_autonomy, doctor, list_missions, archive_mission, mission_events, and receipt.
- [x] 11.3 Add delegated-run policy tests for approved-plan gating, pre-approval exceptions, workflow matching, created-worktree requirement, and flight cap.
- [x] 11.4 Add receipt projection tests.
- [x] 11.5 Add prompt contract tests for Coordinator runtime instructions.
- [x] 11.6 Add scripted child lifecycle tests.
- [x] 11.7 Maintain the live E2E plan for S1, S2, S4, S5, S6, S7, capability doctor, mission events, receipts, and archive cleanup.
- [x] 11.8 Split `add-coordinator-mode` specs by capability while preserving shipped surface/UI coverage and runtime normative content.

## 12. Explicit deferrals

- [ ] 12.1 Full Coordinator-to-Director technical rename.
- [ ] 12.2 First-class Coordinator role/runtime extraction and durable role/session-visibility policy.
- [ ] 12.3 Restart durability scenario for pending checkpoints and pending child questions.
- [ ] 12.4 Recovery/chaos scenario for steer-not-respawn and killed/stuck child handling.
- [ ] 12.5 Custom policy CRUD and save-as-policy flow.
- [ ] 12.6 Spend capture/enforcement beyond the reserved receipt section.
- [ ] 12.7 Hierarchical Coordinator-of-Coordinators.
- [ ] 12.8 Broader UI/Command Center layout reshaping not required by the core runtime baseline.
- [ ] 12.9 UI render-to-click race hardening.
- [ ] 12.10 Toggle dedup beyond current idempotent ledger behavior.
- [ ] 12.11 Worktree garbage collection for Coordinator-created child worktrees.
- [ ] 12.12 Backend fallback between live child providers/backends.

## 13. Mission consent modes (spec-first; implement after the single-door guard and fresh S5/S6 batches)

- [ ] 13.1 Implement the not-required-aware single-door guard: `mission_plan` rejects `approval_state` writes of `approved` (self-approval) and of `not_required` over `awaiting_approval`/`revision_requested` (waiver), with instructive errors naming checkpoint submit.
- [ ] 13.2 Accept external `plan:"auto"` autonomy at `start_mission`/`ensure_mission`: bootstrap publishes `not_required` with nodes, no approval checkpoint, and a recorded user-actor waiver decision; runtime callers rejected.
- [ ] 13.3 Extend `set_autonomy` to class `plan` (external-only): ask→auto never consumes a pending gate; auto→ask transitions the current revision to `awaiting_approval` with a fresh checkpoint instance and blocks further delegated starts.
- [ ] 13.4 Widen the delegation gate (`AgentRunCoordinatorMissionPlanPolicy`) to accept consented plans (`approved` or user-selected `not_required`) with unchanged sandbox/cap/binding checks.
- [ ] 13.5 Disclose consent mode in compact `mission_status` and `receipt`; keep the waiver decision visible in the actor chain.
- [ ] 13.6 Deterministic coverage per the `mission-consent-modes` traceability scenario; add harness S10 and run it scripted before any live-child validation.
- [ ] 13.7 Coordinator prompt branch for policy-consented Missions, validated at the negotiation tier (High) before landing prompt text.
