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
        XCTAssertTrue(prompt.contains("Workflow fidelity rule"))
        XCTAssertTrue(prompt.contains("Mission Plan workflow metadata is an execution contract"))
        XCTAssertTrue(prompt.contains("Default workflow mapping"))
        XCTAssertTrue(prompt.contains("Mutable implementation nodes use `workflow_name:\"Orchestrate\"` by default"))
        XCTAssertTrue(prompt.contains("Independent review nodes use `workflow_name:\"Review\"` by default"))
        XCTAssertTrue(prompt.contains("workflow-less read-only probe nodes may use `agent_explore.start`"))
        XCTAssertTrue(prompt.contains("should not pretend to be Investigate"))
        XCTAssertTrue(prompt.contains("agent_run.start"))
        XCTAssertTrue(prompt.contains("model_id:\"explore\""))
        XCTAssertTrue(prompt.contains("workflow_name:\"Investigate\""))
        XCTAssertTrue(prompt.contains("node with `workflow_name` or `workflow_id`"))
        XCTAssertTrue(prompt.contains("revise the Mission Plan to the real workflow"))
        XCTAssertTrue(prompt.contains("For `createIsolated` mutable workstreams"))
        XCTAssertTrue(prompt.contains("worktree_strategy.base_ref"))
        XCTAssertTrue(prompt.contains("issue/PR-style implementation work"))
        XCTAssertTrue(prompt.contains("repository default branch/ref"))
        XCTAssertTrue(prompt.contains("use the actual repo default"))
        XCTAssertTrue(prompt.contains("worktree_base_ref"))
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
