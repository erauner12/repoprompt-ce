import Foundation

enum CoordinatorMissionPresentationPolicy {
    enum PrimaryStatus: Equatable {
        case mission(CoordinatorMissionPlanStatus)
        case approval(CoordinatorMissionPlanApprovalState)
    }

    enum ConversationMode: Equatable {
        case noPlan
        case planReference
        case terminalSummary(CoordinatorMissionPlanStatus)
    }

    static func primaryStatus(for plan: CoordinatorMissionPlan) -> PrimaryStatus {
        if plan.status.isTerminal {
            return .mission(plan.status)
        }
        switch plan.approvalState {
        case .awaitingApproval, .revisionRequested:
            return .approval(plan.approvalState)
        case .notRequired, .approved:
            return .mission(plan.status)
        }
    }

    static func conversationMode(for plan: CoordinatorMissionPlan?) -> ConversationMode {
        guard let plan else { return .noPlan }
        if plan.status.isTerminal {
            return .terminalSummary(plan.status)
        }
        return .planReference
    }

    static func shouldShowLiveBadge(for plan: CoordinatorMissionPlan?) -> Bool {
        !(plan?.status.isTerminal ?? false)
    }

    static func shouldShowPlanRevisionComposer(for plan: CoordinatorMissionPlan?) -> Bool {
        guard let plan else { return false }
        return !plan.status.isTerminal
    }
}

extension CoordinatorMissionPlanStatus {
    var isTerminal: Bool {
        switch self {
        case .completed, .stopped:
            true
        case .draft, .approved, .running, .blocked:
            false
        }
    }
}
