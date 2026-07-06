import Foundation

enum AgentRunCoordinatorMissionPlanPolicy {
    enum Decision: Equatable {
        case allow
        case requireApprovedMissionPlan(String)
        case denyFlightCapReached(String)
    }

    enum Operation: Equatable {
        case agentRunStart
        case agentExploreStart
    }

    static let approvedMissionPlanRequiredMessage = """
    Coordinator missions must record and approve a concrete Mission Plan before launching delegated Agent Mode sessions. Use coordinator_chat op=mission_plan to create DAG-lite nodes for the user's actual deliverables, set approval_state to "awaiting_approval", and ask the user: Proceed / Revise / Gather evidence / Deepen plan / Get independent critique / Start smaller / Stop. Proceed advances the next planned phase; if that phase is mutable work, update the Mission Plan to approval_state "approved" before starting implementation/review child sessions with agent_run.start or agent_explore.start. A planning delegate is not a Mission Plan. The only pre-approval child exceptions are node-bound planning actions: agent_explore.start with mission_node_id bound to a workflow-less fresh_readonly_child node, agent_run.start with workflow_name:"Investigate" or workflow_name:"Deep Plan" and mission_node_id bound to a matching fresh_readonly_child node, or agent_run.start with model_id:"design" and mission_node_id bound to a workflow-less plan_critique node. Investigate, Deep Plan, and design critique launches must use worktree_create:true.
    """

    static func decision(
        isCoordinatorParent: Bool,
        missionPlan: CoordinatorMissionPlan?,
        operation: Operation = .agentRunStart,
        missionNodeID: UUID? = nil,
        requestedModelID: String? = nil,
        requestedWorkflowID: String? = nil,
        requestedWorkflowName: String? = nil,
        usesCreatedWorktree: Bool = false
    ) -> Decision {
        guard isCoordinatorParent else { return .allow }
        guard let missionPlan else {
            return .requireApprovedMissionPlan(approvedMissionPlanRequiredMessage)
        }
        guard !missionPlan.nodes.isEmpty else {
            return .requireApprovedMissionPlan(approvedMissionPlanRequiredMessage)
        }
        let runningNodeCount = missionPlan.nodes.count { $0.status == .running }
        let maxConcurrent = missionPlan.policySnapshot?.maxConcurrent ?? CoordinatorMissionPolicySnapshot.defaultMaxConcurrent
        if runningNodeCount >= maxConcurrent {
            return .denyFlightCapReached(flightCapReachedMessage(cap: maxConcurrent, runningCount: runningNodeCount))
        }
        if missionPlan.approvalState == .awaitingApproval,
           allowsPreApprovalPlanningAction(
               missionPlan: missionPlan,
               operation: operation,
               missionNodeID: missionNodeID,
               requestedModelID: requestedModelID,
               requestedWorkflowID: requestedWorkflowID,
               requestedWorkflowName: requestedWorkflowName,
               usesCreatedWorktree: usesCreatedWorktree
           )
        {
            return .allow
        }
        guard missionPlan.approvalState == .approved else {
            return .requireApprovedMissionPlan(approvedMissionPlanRequiredMessage)
        }
        return .allow
    }

    private static func allowsPreApprovalPlanningAction(
        missionPlan: CoordinatorMissionPlan,
        operation: Operation,
        missionNodeID: UUID?,
        requestedModelID: String?,
        requestedWorkflowID: String?,
        requestedWorkflowName: String?,
        usesCreatedWorktree: Bool
    ) -> Bool {
        guard let missionNodeID,
              let node = missionPlan.nodes.first(where: { $0.id == missionNodeID })
        else { return false }

        switch operation {
        case .agentExploreStart:
            return node.executionPolicy == .freshReadOnlyChild
                && node.workflowHint == nil
        case .agentRunStart:
            if node.executionPolicy == .planCritique {
                return usesCreatedWorktree
                    && normalized(requestedModelID) == "design"
                    && normalized(requestedWorkflowName) == nil
                    && node.workflowHint == nil
            }
            guard usesCreatedWorktree,
                  node.executionPolicy == .freshReadOnlyChild,
                  let requestedWorkflowID = normalized(requestedWorkflowID),
                  let plannedWorkflow = normalized(node.workflowHint?.name),
                  let requestedWorkflow = normalized(requestedWorkflowName),
                  plannedWorkflow == requestedWorkflow,
                  let expectedWorkflowID = preApprovalWorkflowID(for: plannedWorkflow),
                  requestedWorkflowID == expectedWorkflowID
            else { return false }
            if let plannedWorkflowID = normalized(node.workflowHint?.id),
               plannedWorkflowID != expectedWorkflowID
            {
                return false
            }
            return true
        }
    }

    private static func flightCapReachedMessage(cap: Int, runningCount: Int) -> String {
        "Coordinator Mission flight cap reached: max_concurrent is \(cap), and \(runningCount) Mission node(s) are already running. Wait for capacity with coordinator_chat op=wait_for_update before starting another node."
    }

    private static func preApprovalWorkflowID(for normalizedName: String) -> String? {
        switch normalizedName {
        case "deep plan": "builtin-deepplan"
        case "investigate": "builtin-investigate"
        default: nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed.lowercased()
    }
}
