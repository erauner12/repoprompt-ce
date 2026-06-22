@testable import RepoPrompt
import XCTest

final class SystemPromptServiceCoordinatorModeTests: XCTestCase {
    func testCoordinatorPromptOmitsFollowThroughPolicyByDefault() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeDemo: true
        )

        XCTAssertTrue(prompt.contains("Coordinator runtime demo mode"))
        XCTAssertFalse(prompt.contains("Coordinator follow-through policy"))
    }

    func testCoordinatorPromptIncludesFollowThroughPolicyWhenEnabled() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeDemo: true,
            coordinatorRuntimeFollowThrough: true
        )

        XCTAssertTrue(prompt.contains("Coordinator runtime demo mode"))
        XCTAssertTrue(prompt.contains("Coordinator follow-through policy"))
        XCTAssertTrue(prompt.contains("Respect boundaries"))
    }

    func testFollowThroughPolicyRequiresCoordinatorRuntimeDemoMode() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeFollowThrough: true
        )

        XCTAssertFalse(prompt.contains("Coordinator follow-through policy"))
    }
}
