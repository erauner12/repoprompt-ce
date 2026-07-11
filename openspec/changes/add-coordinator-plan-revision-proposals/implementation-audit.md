# Tranche 1 implementation audit

Recorded 2026-07-10 for tasks 1.1–1.4 of `add-coordinator-plan-revision-proposals`. This is a point-in-time seam audit, not a declaration that any prerequisite is complete.

## Prerequisite status

The authoritative checkboxes in `openspec/changes/add-coordinator-mode/tasks.md` currently show:

| Task | Current recorded status | Relevant seam / remaining note |
| --- | --- | --- |
| 13.3 | unchecked | Fresh defaults and legacy `not_required` retirement are centered on `CoordinatorMissionPlanApprovalState`, `CoordinatorFollowThroughState.updateMissionPlan(_:)`, and `CoordinatorChatMCPToolService.validateMissionPlanUpdateApprovalGate`. The task says focused paths are patched but full legacy recovery coverage remains. No shared proposal-authority path was found, so this remains soft/independent for this change. |
| 13.6 | unchecked | Prompt/schema/status alignment is centered on `CoordinatorChatMCPToolService`, Coordinator MCP schema construction, `AgentModePrompts`, status/projection code, and their focused tests. The task is reopened pending a final audit, so proposal prompt/schema/doctor work must wait. |
| 13.7 | unchecked | App-owned Stop/terminal monotonicity is centered on `CoordinatorModeViewModel.stopCoordinatorMission(targetMissionID:)`, `CoordinatorMissionPlan.stopMission(cancelledSessionIDs:at:)`, terminal guards in `CoordinatorFollowThroughState.updateMissionPlan(_:)`, and MCP terminal validation. Core invariants are described as patched, but rendered target-bound Stop UI validation remains; later sections 5–8 must not treat it as available. |
| 13.8 | unchecked | Durable handoff is centered on `CoordinatorPostApprovalContinuationRecord`, continuation mutators in `CoordinatorFollowThroughState`, `CoordinatorModeViewModel`'s persistence barrier/token and final delivery authority checks, plus Mission status projection. It is reopened for persistence/authority races and focused validation; later sections 5–8 must not treat it as available. |

## Material contract and runtime seams

The canonical Mission model is `CoordinatorMissionPlan` in `Features/AgentMode/Runtime/CoordinatorFollowThroughState.swift`. Its current approved-contract ingress guard is `CoordinatorChatMCPToolService.validateApprovedMissionContractImmutability`, with field helpers for autonomy, policies, workstreams, worktree strategy, and nodes.

Material contract fields recorded by the ratified change and current approved-contract guard are:

- objective/scope: `missionKey`, `objective`, and `shapeSummary`;
- predecessor lineage: `predecessorMissionID`, `predecessorTitle`, and `predecessorSummary`;
- workstreams: stable membership/IDs, title, purpose, role, default execution policy, and planned worktree strategy;
- nodes: stable membership/IDs, title/detail, workflow hint, workstream membership, dependency set, role, execution policy, and done criteria;
- policy/authority: policy identity/name, pace, autonomy including `childAsk`, concurrency, definition of done, standing guidance, pinned skills, and pinned contexts;
- plan-level autonomy overrides, including all autonomy keys.

Runtime-only state is deliberately outside contract identity: plan revision/ID/status/approval lifecycle, template presentation metadata, runtime worktree IDs, primary/related session IDs, node status/completion evidence/bindings, routing decisions, user/runtime decisions, evidence, events, timestamps, observed child phases, pending/handled follow-through events, resume records, child interaction responses, terminal provenance, and post-approval continuation bookkeeping.

Lifecycle ownership seams audited for later work:

- Stop: `CoordinatorModeViewModel.stopCoordinatorMission(targetMissionID:)`, `CoordinatorMissionPlan.stopMission`, MCP Stop dispatch/terminal guards.
- Continuation: `CoordinatorPostApprovalContinuationRecord`, `CoordinatorFollowThroughState` continuation mutators, and `CoordinatorModeViewModel` persistence barrier/delivery checks.
- Child interactions: pending interaction projection in `CoordinatorModeSnapshotProjector`, response recording in `CoordinatorFollowThroughState.rememberChildInteractionResponse`, and submit routing in `CoordinatorModeViewModel` / `AgentModeViewModel`.
- Projection: `CoordinatorModeSnapshotProjector`, `CoordinatorMissionPresentationPolicy`, Coordinator mode view models/views, MCP Mission status and event journal surfaces.

## Implementation partial order

1. This audit permits sections 2–3 and pure proposal parsing/validation to begin.
2. Prompt, public schema, doctor discovery, and overlapping tests wait for 13.6.
3. Pause/resolution/Stop/continuation/child-interaction/projection integration in sections 5–8 waits for both 13.7 and 13.8.
4. Task 13.3 remains soft/independent because this audit found no shared proposal authority path. Its unchecked status is not promoted to a blocker.

# Section 10 validation-matrix audit

Recorded 2026-07-10 against committed feature range `e2576618..c2fb618a`, plus the non-live S8 harness addition.

| Matrix area | Implementation and focused evidence | Result |
| --- | --- | --- |
| Canonical contract identity | `CoordinatorMissionMaterialContract` is shared by ingress/CAS/status/checkpoint logic; `CoordinatorMissionMaterialContractTests` covers every ratified material field, runtime exclusions, deterministic ordering, evidence-only stability, Unicode normalization, and stale structural CAS. | Covered |
| Proposal ingress and canonical request identity | `CoordinatorChatMCPToolService` restricts `propose_revision` to the owning runtime and dedicated persisted callback; MCP and ledger tests cover approved/nonterminal/base checks, summary parsing, exact payload/authority rejection, Unicode/whitespace identity, case/punctuation preservation, exact pending retry, and post-resolution occurrence. | Covered |
| Ledger, persistence, and migration | Dedicated append/resolve mutators preserve append-only history and generic-update isolation; ledger/view-model tests cover empty decode defaults, reset, round trip, restart reprojection, terminal invalidation, persistence failure, reentrant corruption, and identical retry recovery. | Covered |
| Pause gates and held questions | Run policy blocks starts before capacity including preapproval exceptions; classifier holds before `childAsk:auto`; reducer/MCP/view-model tests cover bindings/progress/contract/Director-decision rejection, continuation/final-enqueue holds, existing/new disabled questions, answer rejection without record, and terminal bookkeeping. | Covered |
| Revise, Keep, Stop, and stale actions | Ledger and production view-model transactions cover accepted `revisionRequested`, unchanged Keep restoration/evaluate-once, target-bound Stop/terminal races, stale checkpoint/contract rejection, conflicting first-writer decisions, atomic trusted contract-change invalidation, durability ordering, and retry after persistence failure. | Covered |
| Projection and actions | Snapshot, MCP, and view-model tests cover one highest-priority proposal checkpoint, stable identity, child-question suppression, exact labels, external action parity, identity-only capture, restart projection, and absence of replacement plan/diff or **Approve revised plan**. | Covered |
| Observability and receipts | MCP status/wait/journal tests cover append/resolution fingerprints without plan revision, wait wakeups, status lifecycle/held state, and event candidates; receipt tests cover runtime proposal plus trusted resolution without approval/execution claims. | Covered |
| Prompt/schema/doctor | `SystemPromptServiceCoordinatorModeTests` and `CoordinatorChatMCPToolServiceTests` cover proposal doctrine, self-resolution prohibition, public schema, and doctor feature advertisement. | Covered |
| Live narrative harness | New `s8` asserts stable proposal/base-contract/checkpoint identities across repeated paused observations, zero running work, no intervening decision/self-resolution, identity-only actions/no exact replacement payload, external Revise, accepted resolution, a materially changed concrete plan awaiting a distinct exact approval, external Proceed, and terminal completion. | Harness ready; live run remains task 10.3 |

Coordinated validation completed successfully:

- `make dev-format` (initial audit: 0/1224 changed; final review correction formatted 1 file, then 0).
- Nine focused `make dev-test FILTER=...` lanes: 346 tests, 0 failures after the final review correction.
- `make dev-swift-build PRODUCT=RepoPrompt`.
- `make dev-swift-build PRODUCT=repoprompt-mcp`.
- `make dev-lint` (0 formatter findings, 0 strict SwiftLint violations).
- `openspec validate add-coordinator-plan-revision-proposals --strict`.

Final Oracle review found a Stop-versus-non-Stop-durability-hold race. The narrow correction makes Stop supersede any proposal durability hold while preserving an already-written append-only proposal resolution, installs and persists a stopped hold before cancellation, keeps retries idempotent, and fails contract dials closed during other unresolved holds. Reducer coverage spans accepted, rejected, and contract-invalidated holds; production view-model coverage exercises accepted-hold persistence failure through external Stop.

Repository policy requires the smallest relevant coordinated tests/builds for routine changes; it does not require a full-root run for this focused handoff. Task 10.3 remains intentionally unchecked pending the parent-run visible-app narrative.
