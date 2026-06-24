@testable import RepoPrompt
import XCTest

final class SystemPromptServiceCoordinatorModeTests: XCTestCase {
    func testCoordinatorPromptOmitsAutoModeByDefault() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeDemo: true
        )

        XCTAssertTrue(prompt.contains("Coordinator runtime demo mode"))
        XCTAssertFalse(prompt.contains("Coordinator auto mode"))
    }

    func testCoordinatorPromptIncludesAutoModeWhenEnabled() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeDemo: true,
            coordinatorRuntimeAutoMode: true
        )

        XCTAssertTrue(prompt.contains("Coordinator runtime demo mode"))
        XCTAssertTrue(prompt.contains("Coordinator auto mode"))
        XCTAssertTrue(prompt.contains("Respect boundaries"))
    }

    func testAutoModeRequiresCoordinatorRuntimeDemoMode() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeAutoMode: true
        )

        XCTAssertFalse(prompt.contains("Coordinator auto mode"))
    }
}
