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

    func testCoordinatorAllowsApprovedPlanWithNodes() {
        XCTAssertEqual(
            decision(missionPlan: plan(approvalState: .approved, nodes: [node()])),
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
            usesCreatedWorktree: usesCreatedWorktree
        )
    }

    private func plan(
        approvalState: CoordinatorMissionPlanApprovalState,
        nodes: [CoordinatorMissionPlanNode]
    ) -> CoordinatorMissionPlan {
        CoordinatorMissionPlan(
            objective: "Add CSV export to orders table",
            approvalState: approvalState,
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
        role: String? = nil
    ) -> CoordinatorMissionPlanNode {
        CoordinatorMissionPlanNode(
            id: id,
            title: "Generate CSV from filtered rows",
            workflowHint: workflowHint,
            workstreamID: workstreamID,
            role: role,
            executionPolicy: executionPolicy
        )
    }

    private var workstreamID: UUID {
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    }

    private func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0x9A, 0x2B, 0x55, 0x55, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, suffix))
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
