import Foundation

enum AgentRunCoordinatorMissionPlanPolicy {
    enum Decision: Equatable {
        case allow
        case requireApprovedMissionPlan(String)
    }

    static let approvedMissionPlanRequiredMessage = """
    Coordinator missions must record and approve a concrete Mission Plan before launching delegated Agent Mode sessions. Use coordinator_chat op=mission_plan to create DAG-lite nodes for the user's actual deliverables, set approval_state to "awaiting_approval", and ask the user: Proceed / Revise / Start smaller. After the user chooses Proceed, update the Mission Plan to approval_state "approved" before calling agent_run.start. A planning delegate is not a Mission Plan.
    """

    static func decision(
        isCoordinatorParent: Bool,
        missionPlan: CoordinatorMissionPlan?
    ) -> Decision {
        guard isCoordinatorParent else { return .allow }
        guard let missionPlan else {
            return .requireApprovedMissionPlan(approvedMissionPlanRequiredMessage)
        }
        guard !missionPlan.nodes.isEmpty else {
            return .requireApprovedMissionPlan(approvedMissionPlanRequiredMessage)
        }
        guard missionPlan.approvalState == .approved else {
            return .requireApprovedMissionPlan(approvedMissionPlanRequiredMessage)
        }
        return .allow
    }
}
