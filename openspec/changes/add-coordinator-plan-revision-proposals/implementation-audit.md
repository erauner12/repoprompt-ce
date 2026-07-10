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
