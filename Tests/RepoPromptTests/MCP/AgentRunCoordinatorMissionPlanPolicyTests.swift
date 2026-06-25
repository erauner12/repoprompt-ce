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

    func testCoordinatorAllowsApprovedPlanWithNodes() {
        XCTAssertEqual(
            decision(missionPlan: plan(approvalState: .approved, nodes: [node()])),
            .allow
        )
    }

    private func decision(
        isCoordinatorParent: Bool = true,
        missionPlan: CoordinatorMissionPlan?
    ) -> AgentRunCoordinatorMissionPlanPolicy.Decision {
        AgentRunCoordinatorMissionPlanPolicy.decision(
            isCoordinatorParent: isCoordinatorParent,
            missionPlan: missionPlan
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

    private func node() -> CoordinatorMissionPlanNode {
        CoordinatorMissionPlanNode(
            title: "Generate CSV from filtered rows",
            workstreamID: workstreamID,
            executionPolicy: .freshWorktree
        )
    }

    private var workstreamID: UUID {
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
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
    }
}
