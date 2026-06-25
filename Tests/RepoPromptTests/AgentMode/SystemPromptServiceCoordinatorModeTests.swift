@testable import RepoPrompt
import XCTest

final class SystemPromptServiceCoordinatorModeTests: XCTestCase {
    func testCoordinatorPromptOmitsAutoPaceByDefault() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeDemo: true
        )

        XCTAssertTrue(prompt.contains("Coordinator runtime demo mode"))
        XCTAssertFalse(prompt.contains("Coordinator Auto pace"))
        XCTAssertTrue(prompt.contains("Coordinator execution pace is app-controlled"))
        XCTAssertTrue(prompt.contains("In Step pace, pause at Mission Plan"))
        XCTAssertTrue(prompt.contains("In Auto pace, the app may send follow-through resume events"))
        XCTAssertTrue(prompt.contains("Do not use raw shell/bash from the Coordinator turn"))
        XCTAssertTrue(prompt.contains("raw shell can block the control plane"))
        XCTAssertTrue(prompt.contains("Workflow fidelity rule"))
        XCTAssertTrue(prompt.contains("Mission Plan workflow metadata is an execution contract"))
        XCTAssertTrue(prompt.contains("Default workflow mapping"))
        XCTAssertTrue(prompt.contains("Mutable implementation nodes use `workflow_name:\"Orchestrate\"` by default"))
        XCTAssertTrue(prompt.contains("Independent review nodes use `workflow_name:\"Review\"` by default"))
        XCTAssertTrue(prompt.contains("workflow-less read-only probe nodes may use `agent_explore.start`"))
        XCTAssertTrue(prompt.contains("durable/formal investigation deliverables"))
        XCTAssertTrue(prompt.contains("should not pretend to be Investigate"))
        XCTAssertTrue(prompt.contains("agent_run.start"))
        XCTAssertTrue(prompt.contains("choose an appropriate role/model for the investigation"))
        XCTAssertTrue(prompt.contains("record that model choice in `routing_decisions`"))
        XCTAssertTrue(prompt.contains("workflow_name:\"Investigate\""))
        XCTAssertTrue(prompt.contains("worktree_create:true"))
        XCTAssertTrue(prompt.contains("node with `workflow_name` or `workflow_id`"))
        XCTAssertTrue(prompt.contains("revise the Mission Plan to the real workflow"))
        XCTAssertTrue(prompt.contains("coordinator_chat op=mission_plan"))
        XCTAssertTrue(prompt.contains("approval_state:\"awaiting_approval\""))
        XCTAssertTrue(prompt.contains("Proceed / Revise / Gather evidence / Deepen plan / Get independent critique / Start smaller / Stop"))
        XCTAssertTrue(prompt.contains("Proceed is phase-aware"))
        XCTAssertTrue(prompt.contains("do not invent an implementation phase"))
        XCTAssertTrue(prompt.contains("evidence-gathering"))
        XCTAssertTrue(prompt.contains("workflow_name:\"Deep Plan\""))
        XCTAssertTrue(prompt.contains("visible design-agent critique node instead of Oracle"))
        XCTAssertTrue(prompt.contains("execution_policy:\"plan_critique\""))
        XCTAssertTrue(prompt.contains("mission_node_id"))
        XCTAssertTrue(prompt.contains("model_id:\"design\""))
        XCTAssertTrue(prompt.contains("worktree_create:true"))
        XCTAssertTrue(prompt.contains("For `createIsolated` mutable workstreams"))
        XCTAssertTrue(prompt.contains("worktree_strategy.base_ref"))
        XCTAssertTrue(prompt.contains("issue/PR-style implementation work"))
        XCTAssertTrue(prompt.contains("repository default branch/ref"))
        XCTAssertTrue(prompt.contains("use the actual repo default"))
        XCTAssertTrue(prompt.contains("worktree_base_ref"))
        XCTAssertTrue(prompt.contains("operation values must be `agent_explore.start`, `agent_run.start`, `agent_run.steer`, `agent_run.respond`, `agent_run.cancel`, or `coordinator_hold`"))
    }

    func testBuiltInMissionTemplatesAvoidCoordinatorProtocolDetails() {
        let templates = [
            CoordinatorMissionTemplate.scopedChange,
            CoordinatorMissionTemplate.deepPlanOrchestrateReview
        ]
        for template in templates {
            for forbidden in CoordinatorMissionTemplate.coordinatorProtocolDetailTerms {
                XCTAssertFalse(
                    template.template.contains(forbidden),
                    "\(template.displayName) should not include Coordinator protocol detail: \(forbidden)"
                )
            }
        }
    }

    func testBuiltInMissionTemplatesKeepUserFacingMissionPreferences() {
        XCTAssertTrue(CoordinatorMissionTemplate.scopedChange.template.contains("visible plan"))
        XCTAssertTrue(CoordinatorMissionTemplate.scopedChange.template.contains("read-only discovery"))
        XCTAssertTrue(CoordinatorMissionTemplate.scopedChange.template.contains("isolated worktree"))
        XCTAssertTrue(CoordinatorMissionTemplate.scopedChange.template.contains("independent Review"))

        XCTAssertTrue(CoordinatorMissionTemplate.deepPlanOrchestrateReview.template.contains("Deep Plan"))
        XCTAssertTrue(CoordinatorMissionTemplate.deepPlanOrchestrateReview.template.contains("Orchestrate"))
        XCTAssertTrue(CoordinatorMissionTemplate.deepPlanOrchestrateReview.template.contains("independent Review"))
        XCTAssertTrue(CoordinatorMissionTemplate.deepPlanOrchestrateReview.template.contains("fix loop"))
    }

    func testCoordinatorPromptIncludesAutoPaceWhenEnabled() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeDemo: true,
            coordinatorRuntimeAutoMode: true
        )

        XCTAssertTrue(prompt.contains("Coordinator runtime demo mode"))
        XCTAssertTrue(prompt.contains("Coordinator Auto pace"))
        XCTAssertTrue(prompt.contains("Auto execution pace is enabled"))
        XCTAssertTrue(prompt.contains("Respect boundaries"))
        XCTAssertTrue(prompt.contains("If a delegated child or workflow appears stuck"))
        XCTAssertTrue(prompt.contains("wait once with a bounded timeout"))
        XCTAssertTrue(prompt.contains("Do not enter a raw shell loop in the Coordinator"))
    }

    func testAutoPaceRequiresCoordinatorRuntimeDemoMode() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            coordinatorRuntimeAutoMode: true
        )

        XCTAssertFalse(prompt.contains("Coordinator Auto pace"))
    }
}
