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
        XCTAssertTrue(prompt.contains("Do not use raw shell/bash from the Coordinator turn"))
        XCTAssertTrue(prompt.contains("raw shell can block the control plane"))
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
        XCTAssertTrue(prompt.contains("If a delegated child or workflow appears stuck"))
        XCTAssertTrue(prompt.contains("wait once with a bounded timeout"))
        XCTAssertTrue(prompt.contains("Do not enter a raw shell loop in the Coordinator"))
    }

    func testAutoModeRequiresCoordinatorRuntimeDemoMode() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeAutoMode: true
        )

        XCTAssertFalse(prompt.contains("Coordinator auto mode"))
    }
}
