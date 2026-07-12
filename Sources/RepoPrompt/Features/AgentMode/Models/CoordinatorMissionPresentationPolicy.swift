import Foundation

enum CoordinatorMissionPresentationPolicy {
    enum SignalFactClass: Equatable {
        case state
        case attention
        case count
        case metadata
        case identity
    }

    enum SignalShape: Equatable {
        case filledCapsule
        case plainText
        case mutedText
        case linkText
    }

    enum PrimaryStatus: Equatable {
        case mission(CoordinatorMissionPlanStatus)
        case approval(CoordinatorMissionPlanApprovalState)
    }

    enum ConversationMode: Equatable {
        case noPlan
        case planReference
        case terminalSummary(CoordinatorMissionPlanStatus)
    }

    enum ComposerMode: Equatable {
        case standard
        case terminalPrompt(TerminalComposerAction)
    }

    enum TerminalComposerAction: Equatable {
        case followUp
        case restartOrRevise

        var title: String {
            switch self {
            case .followUp:
                "Start a follow-up Mission →"
            case .restartOrRevise:
                "Restart or revise Mission →"
            }
        }

        var placeholder: String {
            switch self {
            case .followUp:
                "Start a follow-up Mission..."
            case .restartOrRevise:
                "Restart or revise this Mission..."
            }
        }
    }

    enum PaneEmphasis: Equatable {
        case normal
        case terminalQuiet

        var usesStateCapsulesInBody: Bool {
            self == .normal
        }

        var collapsesCompletedEvidence: Bool {
            self == .terminalQuiet
        }
    }

    enum BoardColumnEmphasis: Equatable {
        case occupied
        case emptyDimmed

        var contentOpacity: Double {
            switch self {
            case .occupied:
                1.0
            case .emptyDimmed:
                0.62
            }
        }

        var backgroundOpacity: Double {
            switch self {
            case .occupied:
                0.12
            case .emptyDimmed:
                0.055
            }
        }

        var strokeOpacity: Double {
            switch self {
            case .occupied:
                0.12
            case .emptyDimmed:
                0.07
            }
        }

        var countFillOpacity: Double {
            switch self {
            case .occupied:
                0.10
            case .emptyDimmed:
                0.045
            }
        }

        var countStrokeOpacity: Double {
            switch self {
            case .occupied:
                0.16
            case .emptyDimmed:
                0.08
            }
        }
    }

    enum RailRowSignal: Equatable {
        case filledBadge(RailRowBadgeKind)
        case mutedTerminalStatus(CoordinatorMissionPlanStatus)
        case none
    }

    enum RailRowBadgeKind: Equatable {
        case live
        case activeRun(String)

        var title: String {
            switch self {
            case .live:
                "Live"
            case let .activeRun(title):
                title
            }
        }
    }

    static func signalShape(for factClass: SignalFactClass) -> SignalShape {
        switch factClass {
        case .state, .attention:
            .filledCapsule
        case .count:
            .plainText
        case .metadata:
            .mutedText
        case .identity:
            .linkText
        }
    }

    static func primaryStatus(for plan: CoordinatorMissionPlan) -> PrimaryStatus {
        if plan.status.isTerminal {
            return .mission(plan.status)
        }
        switch plan.approvalState {
        case .notRequired, .awaitingApproval, .revisionRequested:
            return .approval(plan.approvalState)
        case .approved:
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

    static func composerMode(
        for plan: CoordinatorMissionPlan?,
        hasPendingChildQuestion: Bool
    ) -> ComposerMode {
        if hasPendingChildQuestion {
            return .standard
        }
        switch plan?.status {
        case .completed:
            return .terminalPrompt(.followUp)
        case .stopped:
            return .terminalPrompt(.restartOrRevise)
        case .draft, .approved, .running, .blocked, nil:
            return .standard
        }
    }

    static func paneEmphasis(for plan: CoordinatorMissionPlan?) -> PaneEmphasis {
        guard plan?.status.isTerminal == true else { return .normal }
        return .terminalQuiet
    }

    static func boardColumnEmphasis(isEmpty: Bool) -> BoardColumnEmphasis {
        isEmpty ? .emptyDimmed : .occupied
    }

    static func railRowSignal(
        for plan: CoordinatorMissionPlan?,
        activeRunTitle: String?,
        isLiveInCurrentWindow: Bool
    ) -> RailRowSignal {
        if let status = plan?.status,
           status.isTerminal
        {
            return .mutedTerminalStatus(status)
        }
        if let activeRunTitle {
            return .filledBadge(.activeRun(activeRunTitle))
        }
        if isLiveInCurrentWindow {
            return .filledBadge(.live)
        }
        return .none
    }

    static func shouldShowLiveBadge(for plan: CoordinatorMissionPlan?) -> Bool {
        !(plan?.status.isTerminal ?? false)
    }

    static func policyMetadataParts(for policy: CoordinatorMissionPolicySnapshot) -> [String] {
        var title = policy.name
        if isPolicyEdited(policy) {
            title += " · edited"
        }
        return [title, policy.defaultPace.rawValue, "cap \(policy.maxConcurrent)"]
    }

    static func policyMetadataLine(for policy: CoordinatorMissionPolicySnapshot) -> String {
        policyMetadataParts(for: policy).joined(separator: " · ")
    }

    static func missionPlanMetadataParts(for plan: CoordinatorMissionPlan) -> [String] {
        var parts = ["r\(plan.revision)"]
        if let policySnapshot = plan.policySnapshot {
            parts.append(contentsOf: policyMetadataParts(for: policySnapshot))
        }
        return parts
    }

    static func uniqueMetadataParts(_ parts: [String?]) -> [String] {
        var seen: Set<String> = []
        return parts.compactMap { rawPart in
            guard let part = rawPart?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !part.isEmpty
            else { return nil }
            let key = part.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return part
        }
    }

    static func shouldShowInspector(
        for destination: CoordinatorModeViewModel.RailDestination,
        hasInspectorTarget: Bool
    ) -> Bool {
        hasInspectorTarget && destination == .board
    }

    private static func isPolicyEdited(_ policy: CoordinatorMissionPolicySnapshot) -> Bool {
        guard let base = CoordinatorMissionPolicySnapshot.builtInPolicies.first(where: { $0.id == policy.id }) else {
            return false
        }
        return base.defaultPace != policy.defaultPace
            || base.autonomy != policy.autonomy
            || base.maxConcurrent != policy.maxConcurrent
            || base.definitionOfDone != policy.definitionOfDone
            || base.standingGuidance != policy.standingGuidance
            || base.pinnedSkillIDs != policy.pinnedSkillIDs
            || base.pinnedContextIDs != policy.pinnedContextIDs
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
