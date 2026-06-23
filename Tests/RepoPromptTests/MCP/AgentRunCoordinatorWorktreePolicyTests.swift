import Foundation
@testable import RepoPrompt
import XCTest

final class AgentRunCoordinatorWorktreePolicyTests: XCTestCase {
    func testNonCoordinatorMutableStartAllowsWithoutWorktree() {
        XCTAssertEqual(
            decision(isCoordinatorParent: false, message: "Create a tiny doc file."),
            .allow
        )
    }

    func testCoordinatorReadOnlyStartAllowsWithoutWorktree() {
        XCTAssertEqual(
            decision(
                message: "Read the README and tell me in one sentence what the project is. Do not edit files."
            ),
            .allow
        )
    }

    func testCoordinatorReadOnlySafetyConstraintsDoNotForceWorktree() {
        XCTAssertEqual(
            decision(
                message: "Read README.md and answer in one sentence what this project is. It must not edit files, run tests, create a review packet, merge, commit, push, or create a PR."
            ),
            .allow
        )
    }

    func testCoordinatorInvestigationAllowsWithoutWorktree() {
        XCTAssertEqual(
            decision(
                message: "Investigate whether README mentions tests. Report back with the relevant sentence."
            ),
            .allow
        )
    }

    func testCoordinatorInvestigationAndFixRequiresExplicitWorktree() {
        XCTAssertRequiresWorktree(
            decision(message: "Investigate why the README is unclear and fix it.")
        )
    }

    func testCoordinatorMutableStartRequiresExplicitWorktree() {
        XCTAssertRequiresWorktree(
            decision(message: "Create a root file named review-packet-smoke.md with one sentence.")
        )
    }

    func testCoordinatorMutableStartDoesNotTreatInheritedWorktreeAsExplicit() {
        XCTAssertRequiresWorktree(
            decision(message: "Create a tiny doc file using the inherited parent worktree binding.")
        )
    }

    func testCoordinatorReviewPacketRequiresExplicitWorktree() {
        XCTAssertRequiresWorktree(
            decision(message: "Prepare a review packet and merge preview for the documentation change.")
        )
    }

    func testCoordinatorTestRunRequiresExplicitWorktree() {
        XCTAssertRequiresWorktree(
            decision(message: "Run the focused tests for the documentation change and report back.")
        )
    }

    func testCoordinatorPullRequestPreparationRequiresExplicitWorktree() {
        XCTAssertRequiresWorktree(
            decision(message: "Prepare a PR for the README wording change.")
        )
    }

    func testCoordinatorBuiltInOrchestrateRequiresExplicitWorktree() {
        XCTAssertRequiresWorktree(
            decision(
                message: "Break this into implementation subtasks.",
                workflow: AgentWorkflow.orchestrate.definition
            )
        )
    }

    func testCoordinatorBuiltInReviewAllowsWithoutWorktreeForReadOnlyReview() {
        XCTAssertEqual(
            decision(
                message: "Review the existing notes and report risks. Do not edit files.",
                workflow: AgentWorkflow.review.definition
            ),
            .allow
        )
    }

    func testCoordinatorMutableStartAllowsWithExplicitWorktree() {
        XCTAssertEqual(
            decision(
                message: "Create a tiny doc file.",
                hasExplicitWorktree: true
            ),
            .allow
        )
    }

    private func decision(
        isCoordinatorParent: Bool = true,
        message: String,
        workflow: AgentWorkflowDefinition? = nil,
        hasExplicitWorktree: Bool = false
    ) -> AgentRunCoordinatorWorktreePolicy.Decision {
        AgentRunCoordinatorWorktreePolicy.decision(
            isCoordinatorParent: isCoordinatorParent,
            message: message,
            workflow: workflow,
            hasExplicitWorktree: hasExplicitWorktree
        )
    }

    private func XCTAssertRequiresWorktree(
        _ decision: AgentRunCoordinatorWorktreePolicy.Decision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .requireExplicitWorktree(reason) = decision else {
            XCTFail("Expected explicit worktree requirement, got \(decision)", file: file, line: line)
            return
        }
        XCTAssertTrue(reason.contains("worktree_create=true"), file: file, line: line)
    }
}
