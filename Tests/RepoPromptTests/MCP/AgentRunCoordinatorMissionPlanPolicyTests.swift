import Foundation
@testable import RepoPrompt
import XCTest

final class AgentRunCoordinatorMissionPlanPolicyTests: XCTestCase {
    func testNonCoordinatorAllowsWithoutPlan() {
        XCTAssertEqual(
            decision(isCoordinatorParent: false, missionPlan: nil),
            .allow
        )
    }

    func testCoordinatorBlocksNilPlan() {
        XCTAssertRequiresApprovedMissionPlan(
            decision(missionPlan: nil)
        )
    }

    func testCoordinatorBlocksEmptyPlan() {
        XCTAssertRequiresApprovedMissionPlan(
            decision(missionPlan: plan(approvalState: .approved, nodes: []))
        )
    }

    func testCoordinatorBlocksAwaitingApprovalPlan() {
        XCTAssertRequiresApprovedMissionPlan(
            decision(missionPlan: plan(approvalState: .awaitingApproval, nodes: [node()]))
        )
    }

    func testCoordinatorBlocksLegacyNotRequiredPlan() {
        XCTAssertRequiresApprovedMissionPlan(
            decision(missionPlan: plan(approvalState: .notRequired, nodes: [node()]))
        )
    }

    func testPendingRevisionProposalBlocksApprovedStartsBeforeCapacity() throws {
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.maxConcurrent = 1
        let heldPlan = try planWithPendingProposal(
            approvalState: .approved,
            policySnapshot: policy,
            nodes: [node(status: .running)]
        )

        XCTAssertPendingRevisionProposalHold(decision(missionPlan: heldPlan))
    }

    func testPendingRevisionProposalBlocksPreapprovalPlanningAndProbeExceptions() throws {
        let planningNodeID = uuid(77)
        var heldPlan = try planWithPendingProposal(
            approvalState: .approved,
            nodes: [node(id: planningNodeID, executionPolicy: .freshReadOnlyChild)]
        )
        heldPlan.approvalState = .awaitingApproval

        XCTAssertPendingRevisionProposalHold(decision(
            missionPlan: heldPlan,
            operation: .agentExploreStart,
            missionNodeID: planningNodeID
        ))
    }

    func testCoordinatorAllowsPreApprovalDesignCritiqueNodeWithFreshWorktree() {
        let critiqueNodeID = uuid(2)
        XCTAssertEqual(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(id: critiqueNodeID, executionPolicy: .planCritique, role: "design")
                ]),
                missionNodeID: critiqueNodeID,
                requestedModelID: "design",
                usesCreatedWorktree: true
            ),
            .allow
        )
    }

    func testCoordinatorBlocksPreApprovalDesignCritiqueWithRequestedWorkflow() {
        let critiqueNodeID = uuid(2)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(id: critiqueNodeID, executionPolicy: .planCritique, role: "design")
                ]),
                missionNodeID: critiqueNodeID,
                requestedModelID: "design",
                requestedWorkflowName: "Orchestrate",
                usesCreatedWorktree: true
            )
        )
    }

    func testCoordinatorBlocksPreApprovalDesignCritiqueWithWorkflowHint() {
        let critiqueNodeID = uuid(2)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(
                        id: critiqueNodeID,
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(name: "Review"),
                        executionPolicy: .planCritique,
                        role: "design"
                    )
                ]),
                missionNodeID: critiqueNodeID,
                requestedModelID: "design",
                usesCreatedWorktree: true
            )
        )
    }

    func testCoordinatorAllowsPreApprovalLightweightDiscoveryExploreNode() {
        let discoveryNodeID = uuid(3)
        XCTAssertEqual(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(id: discoveryNodeID, executionPolicy: .freshReadOnlyChild)
                ]),
                operation: .agentExploreStart,
                missionNodeID: discoveryNodeID
            ),
            .allow
        )
    }

    func testCoordinatorAllowsPreApprovalDeepPlanNodeWithFreshWorktree() {
        let deepPlanNodeID = uuid(4)
        XCTAssertEqual(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(
                        id: deepPlanNodeID,
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(name: "Deep Plan"),
                        executionPolicy: .freshReadOnlyChild
                    )
                ]),
                missionNodeID: deepPlanNodeID,
                requestedWorkflowID: "builtin-deepPlan",
                requestedWorkflowName: "Deep Plan",
                usesCreatedWorktree: true
            ),
            .allow
        )
    }

    func testCoordinatorAllowsPreApprovalInvestigateNodeWithFreshWorktree() {
        let investigateNodeID = uuid(5)
        XCTAssertEqual(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(
                        id: investigateNodeID,
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(name: "Investigate"),
                        executionPolicy: .freshReadOnlyChild
                    )
                ]),
                missionNodeID: investigateNodeID,
                requestedWorkflowID: "builtin-investigate",
                requestedWorkflowName: "Investigate",
                usesCreatedWorktree: true
            ),
            .allow
        )
    }

    func testCoordinatorBlocksPreApprovalInvestigateWithoutFreshWorktree() {
        let investigateNodeID = uuid(5)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(
                        id: investigateNodeID,
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(name: "Investigate"),
                        executionPolicy: .freshReadOnlyChild
                    )
                ]),
                missionNodeID: investigateNodeID,
                requestedWorkflowID: "builtin-investigate",
                requestedWorkflowName: "Investigate",
                usesCreatedWorktree: false
            )
        )
    }

    func testCoordinatorBlocksPreApprovalInvestigateForCustomWorkflowWithSameName() {
        let investigateNodeID = uuid(5)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(
                        id: investigateNodeID,
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(name: "Investigate"),
                        executionPolicy: .freshReadOnlyChild
                    )
                ]),
                missionNodeID: investigateNodeID,
                requestedWorkflowID: "custom-22222222-2222-2222-2222-222222222222",
                requestedWorkflowName: "Investigate",
                usesCreatedWorktree: true
            )
        )
    }

    func testCoordinatorBlocksPreApprovalInvestigateForMismatchedPlannedWorkflowID() {
        let investigateNodeID = uuid(5)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(
                        id: investigateNodeID,
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(id: "custom-33333333-3333-3333-3333-333333333333", name: "Investigate"),
                        executionPolicy: .freshReadOnlyChild
                    )
                ]),
                missionNodeID: investigateNodeID,
                requestedWorkflowID: "builtin-investigate",
                requestedWorkflowName: "Investigate",
                usesCreatedWorktree: true
            )
        )
    }

    func testCoordinatorBlocksPreApprovalCritiqueWithoutMissionNodeID() {
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(executionPolicy: .planCritique, role: "design")
                ]),
                requestedModelID: "design",
                usesCreatedWorktree: true
            )
        )
    }

    func testCoordinatorBlocksPreApprovalCritiqueForWrongPolicy() {
        let nodeID = uuid(2)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(id: nodeID, executionPolicy: .freshWorktree, role: "design")
                ]),
                missionNodeID: nodeID,
                requestedModelID: "design",
                usesCreatedWorktree: true
            )
        )
    }

    func testCoordinatorBlocksPreApprovalCritiqueForWrongRole() {
        let nodeID = uuid(2)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(id: nodeID, executionPolicy: .planCritique, role: "design")
                ]),
                missionNodeID: nodeID,
                requestedModelID: "engineer",
                usesCreatedWorktree: true
            )
        )
    }

    func testCoordinatorBlocksPreApprovalCritiqueWithoutCreatedWorktree() {
        let nodeID = uuid(2)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(id: nodeID, executionPolicy: .planCritique, role: "design")
                ]),
                missionNodeID: nodeID,
                requestedModelID: "design",
                usesCreatedWorktree: false
            )
        )
    }

    func testCoordinatorBlocksPreApprovalExploreForWorkflowBearingNode() {
        let nodeID = uuid(5)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(
                        id: nodeID,
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(name: "Deep Plan"),
                        executionPolicy: .freshReadOnlyChild
                    )
                ]),
                operation: .agentExploreStart,
                missionNodeID: nodeID
            )
        )
    }

    func testCoordinatorBlocksPreApprovalDeepPlanWithoutWorkflowOrWorktree() {
        let nodeID = uuid(6)
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(
                        id: nodeID,
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(name: "Deep Plan"),
                        executionPolicy: .freshReadOnlyChild
                    )
                ]),
                missionNodeID: nodeID,
                requestedWorkflowName: "Deep Plan",
                usesCreatedWorktree: false
            )
        )
        XCTAssertRequiresApprovedMissionPlan(
            decision(
                missionPlan: plan(approvalState: .awaitingApproval, nodes: [
                    node(
                        id: nodeID,
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(name: "Deep Plan"),
                        executionPolicy: .freshReadOnlyChild
                    )
                ]),
                missionNodeID: nodeID,
                requestedWorkflowName: nil,
                usesCreatedWorktree: true
            )
        )
    }

    func testCoordinatorBlocksApprovedPlanWithoutDurableAuthorityToken() {
        XCTAssertRequiresApprovedMissionPlan(
            AgentRunCoordinatorMissionPlanPolicy.decision(
                isCoordinatorParent: true,
                missionPlan: barePlan(approvalState: .approved, nodes: [node()])
            )
        )
    }

    func testCoordinatorAllowsApprovedPlanWithNodes() {
        let approvedPlan = plan(approvalState: .approved, nodes: [node()])
        XCTAssertEqual(
            decision(missionPlan: approvedPlan),
            .allow
        )
    }

    func testCoordinatorAllowsStartUnderFlightCap() {
        XCTAssertEqual(
            decision(missionPlan: plan(
                approvalState: .approved,
                policySnapshot: CoordinatorMissionPolicySnapshot(
                    id: "cap-two",
                    name: "Cap two",
                    defaultPace: .auto,
                    maxConcurrent: 2
                ),
                nodes: [
                    node(status: .running),
                    node(status: .pending)
                ]
            )),
            .allow
        )
    }

    func testCoordinatorDeniesStartAtExactFlightCapForRunAndExplore() {
        let cappedPlan = plan(
            approvalState: .approved,
            policySnapshot: CoordinatorMissionPolicySnapshot(
                id: "cap-two",
                name: "Cap two",
                defaultPace: .auto,
                maxConcurrent: 2
            ),
            nodes: [
                node(status: .running),
                node(status: .running),
                node(status: .pending)
            ]
        )

        XCTAssertFlightCapReached(decision(missionPlan: cappedPlan), cap: 2, runningCount: 2)
        XCTAssertFlightCapReached(
            decision(missionPlan: cappedPlan, operation: .agentExploreStart),
            cap: 2,
            runningCount: 2
        )
    }

    func testCoordinatorUsesDefaultFlightCapWhenPolicyIsAbsent() {
        XCTAssertEqual(
            decision(missionPlan: plan(approvalState: .approved, nodes: [
                node(status: .running),
                node(status: .running),
                node(status: .pending)
            ])),
            .allow
        )
        XCTAssertFlightCapReached(
            decision(missionPlan: plan(approvalState: .approved, nodes: [
                node(status: .running),
                node(status: .running),
                node(status: .running),
                node(status: .pending)
            ])),
            cap: CoordinatorMissionPolicySnapshot.defaultMaxConcurrent,
            runningCount: 3
        )
    }

    func testCoordinatorFlightCapCountsRunningNodesNotBoundSessions() {
        XCTAssertEqual(
            decision(missionPlan: plan(
                approvalState: .approved,
                policySnapshot: CoordinatorMissionPolicySnapshot(
                    id: "cap-two",
                    name: "Cap two",
                    defaultPace: .auto,
                    maxConcurrent: 2
                ),
                nodes: [
                    node(status: .running, boundSessionID: uuid(21)),
                    node(status: .pending, boundSessionID: uuid(22)),
                    node(status: .pending, boundSessionID: uuid(23))
                ]
            )),
            .allow
        )
    }

    private func decision(
        isCoordinatorParent: Bool = true,
        missionPlan: CoordinatorMissionPlan?,
        operation: AgentRunCoordinatorMissionPlanPolicy.Operation = .agentRunStart,
        missionNodeID: UUID? = nil,
        requestedModelID: String? = nil,
        requestedWorkflowID: String? = nil,
        requestedWorkflowName: String? = nil,
        usesCreatedWorktree: Bool = false
    ) -> AgentRunCoordinatorMissionPlanPolicy.Decision {
        AgentRunCoordinatorMissionPlanPolicy.decision(
            isCoordinatorParent: isCoordinatorParent,
            missionPlan: missionPlan,
            operation: operation,
            missionNodeID: missionNodeID,
            requestedModelID: requestedModelID,
            requestedWorkflowID: requestedWorkflowID,
            requestedWorkflowName: requestedWorkflowName,
            usesCreatedWorktree: usesCreatedWorktree,
            durableApprovalAuthorityToken: missionPlan?.expectedDurableApprovalAuthorityToken
        )
    }

    private func plan(
        approvalState: CoordinatorMissionPlanApprovalState,
        policySnapshot: CoordinatorMissionPolicySnapshot? = nil,
        nodes: [CoordinatorMissionPlanNode]
    ) -> CoordinatorMissionPlan {
        var plan = barePlan(
            approvalState: approvalState,
            policySnapshot: policySnapshot,
            nodes: nodes
        )
        if approvalState == .approved {
            let coordinatorID = uuid(100)
            let continuation = CoordinatorPostApprovalContinuationRecord(
                coordinatorSessionID: coordinatorID,
                checkpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r\(plan.revision)",
                planID: plan.id,
                planRevision: plan.revision,
                directiveText: "Proceed.",
                status: .delivered,
                attempts: 1
            ).confirmingDurableApprovalAuthority()
            plan.postApprovalContinuation = continuation
        }
        return plan
    }

    private func planWithPendingProposal(
        approvalState: CoordinatorMissionPlanApprovalState,
        policySnapshot: CoordinatorMissionPolicySnapshot? = nil,
        nodes: [CoordinatorMissionPlanNode]
    ) throws -> CoordinatorMissionPlan {
        var state = CoordinatorFollowThroughState(missionPlan: plan(
            approvalState: approvalState,
            policySnapshot: policySnapshot,
            nodes: nodes
        ))
        let current = try XCTUnwrap(state.missionPlan)
        _ = try state.appendRevisionProposal(CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: current.id,
            expectedBaseContractFingerprint: current.materialContractFingerprint(),
            summary: "Revise approved scope",
            affectedFields: ["objective"],
            remedy: "revise_scope",
            supportingEvidenceIDs: [],
            requestedChange: "Revise approved scope.",
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: uuid(100),
                runtimeSessionID: uuid(100)
            )
        ))
        return try XCTUnwrap(state.missionPlan)
    }

    private func barePlan(
        approvalState: CoordinatorMissionPlanApprovalState,
        policySnapshot: CoordinatorMissionPolicySnapshot? = nil,
        nodes: [CoordinatorMissionPlanNode]
    ) -> CoordinatorMissionPlan {
        CoordinatorMissionPlan(
            objective: "Add CSV export to orders table",
            approvalState: approvalState,
            policySnapshot: policySnapshot,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Product Behavior",
                    purpose: "Implement the visible export behavior.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                )
            ],
            nodes: nodes
        )
    }

    private func node(
        id: UUID = UUID(),
        workflowHint: CoordinatorMissionPlanNodeWorkflowHint? = nil,
        executionPolicy: CoordinatorMissionExecutionPolicy = .freshWorktree,
        role: String? = nil,
        status: CoordinatorMissionPlanNodeStatus = .pending,
        boundSessionID: UUID? = nil
    ) -> CoordinatorMissionPlanNode {
        CoordinatorMissionPlanNode(
            id: id,
            title: "Generate CSV from filtered rows",
            workflowHint: workflowHint,
            workstreamID: workstreamID,
            role: role,
            executionPolicy: executionPolicy,
            status: status,
            boundSessionID: boundSessionID
        )
    }

    private var workstreamID: UUID {
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    }

    private func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0x9A, 0x2B, 0x55, 0x55, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, suffix))
    }

    private func XCTAssertPendingRevisionProposalHold(
        _ decision: AgentRunCoordinatorMissionPlanPolicy.Decision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .holdPendingRevisionProposal(reason) = decision else {
            XCTFail("Expected pending revision proposal hold, got \(decision)", file: file, line: line)
            return
        }
        XCTAssertEqual(reason, CoordinatorMissionRevisionProposalPause.heldReason, file: file, line: line)
    }

    private func XCTAssertFlightCapReached(
        _ decision: AgentRunCoordinatorMissionPlanPolicy.Decision,
        cap: Int,
        runningCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .denyFlightCapReached(reason) = decision else {
            XCTFail("Expected flight-cap denial, got \(decision)", file: file, line: line)
            return
        }
        XCTAssertTrue(reason.contains("max_concurrent"), file: file, line: line)
        XCTAssertTrue(reason.contains("\(cap)"), file: file, line: line)
        XCTAssertTrue(reason.contains("\(runningCount) Mission node"), file: file, line: line)
        XCTAssertTrue(reason.contains("wait_for_update"), file: file, line: line)
    }

    private func XCTAssertRequiresApprovedMissionPlan(
        _ decision: AgentRunCoordinatorMissionPlanPolicy.Decision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .requireApprovedMissionPlan(reason) = decision else {
            XCTFail("Expected approved Mission Plan requirement, got \(decision)", file: file, line: line)
            return
        }
        XCTAssertTrue(reason.contains("coordinator_chat op=mission_plan"), file: file, line: line)
        XCTAssertTrue(reason.contains("approval_state"), file: file, line: line)
        XCTAssertTrue(reason.contains("agent_run.start"), file: file, line: line)
        XCTAssertTrue(reason.contains("agent_explore.start"), file: file, line: line)
        XCTAssertTrue(reason.contains("plan_critique"), file: file, line: line)
        XCTAssertTrue(reason.contains("Deep Plan"), file: file, line: line)
        XCTAssertTrue(reason.contains("Investigate"), file: file, line: line)
    }
}
