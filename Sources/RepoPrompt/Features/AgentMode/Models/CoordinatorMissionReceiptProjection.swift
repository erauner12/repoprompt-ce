import Foundation

struct CoordinatorMissionReceiptProjection: Equatable {
    static let spendReserveCopy = "Not tracked in v1 — reserved for per-session usage across this Mission."

    var title: String
    var objective: String?
    var summary: String?
    var policy: PolicySummary?
    var decisionCounts: DecisionCounts
    var revisionProposalHistory: [RevisionProposalHistorySummary]
    var evidence: [EvidenceSummary]

    init(plan: CoordinatorMissionPlan) {
        title = Self.missionTitle(from: plan)
        objective = Self.trimmedNonEmpty(plan.objective)
        summary = Self.trimmedNonEmpty(plan.predecessorSummary)
        policy = plan.policySnapshot.map(PolicySummary.init(policy:))
        decisionCounts = DecisionCounts(decisions: plan.decisions)
        let evidenceByID = Dictionary(uniqueKeysWithValues: plan.evidence.map { ($0.id, $0) })
        revisionProposalHistory = plan.revisionProposals.map { proposal in
            RevisionProposalHistorySummary(
                proposal: proposal,
                resolution: plan.revisionProposalResolution(for: proposal.id),
                evidenceByID: evidenceByID
            )
        }
        evidence = plan.evidence
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.timestamp < rhs.timestamp
            }
            .map(EvidenceSummary.init(evidence:))
    }

    var markdown: String {
        var lines: [String] = ["# \(title)", ""]

        if let objective {
            lines.append("**Objective:** \(objective)")
        }
        if let summary {
            lines.append("**Summary:** \(summary)")
        }
        if objective != nil || summary != nil {
            lines.append("")
        }

        if let policy {
            lines.append("## Policy")
            lines.append("- Name: \(policy.name)")
            lines.append("- Pace: \(policy.pace)")
            lines.append("- Max concurrent sessions: \(policy.maxConcurrent)")
            if !policy.askClasses.isEmpty {
                lines.append("- Asks: \(policy.askClasses.joined(separator: ", "))")
            }
            if let definitionOfDone = policy.definitionOfDone {
                lines.append("- Definition of done: \(definitionOfDone)")
            }
            if let standingGuidance = policy.standingGuidance {
                lines.append("- Guidance: \(standingGuidance)")
            }
            lines.append("")
        }

        lines.append("## Decisions")
        lines.append("- Total: \(decisionCounts.total)")
        lines.append("- User: \(decisionCounts.user)")
        lines.append("- Director: \(decisionCounts.director)")
        if !decisionCounts.byClass.isEmpty {
            lines.append("- By class: \(decisionCounts.byClass.map { "\($0.name) \($0.count)" }.joined(separator: ", "))")
        }
        lines.append("")

        if !revisionProposalHistory.isEmpty {
            lines.append("## Revision proposal history")
            for item in revisionProposalHistory {
                lines.append("- Director/runtime proposal \(item.proposalID.uuidString): \(item.summary) (non-decision event).")
                if let resolutionID = item.resolutionID, let outcome = item.outcome {
                    let authority = item.wasTrustedUserResolution
                        ? "Trusted user resolution"
                        : "App lifecycle resolution"
                    lines.append("  - \(authority) \(resolutionID.uuidString): \(outcome).")
                } else {
                    lines.append("  - Outcome: pending.")
                }
                if item.referencedEvidence.isEmpty {
                    lines.append("  - Referenced evidence: none.")
                } else {
                    for evidence in item.referencedEvidence {
                        lines.append("  - Referenced evidence \(evidence.id.uuidString): [\(evidence.verdict)] \(evidence.summary)")
                    }
                }
            }
            lines.append("")
        }

        lines.append("## Evidence")
        if evidence.isEmpty {
            lines.append("- No evidence recorded for this Mission.")
        } else {
            lines.append(contentsOf: evidence.map { "- [\($0.verdict)] \($0.summary)" })
        }
        lines.append("")

        lines.append("## Spend")
        lines.append(Self.spendReserveCopy)

        return lines.joined(separator: "\n")
    }

    private static func missionTitle(from plan: CoordinatorMissionPlan) -> String {
        if let templateTitle = trimmedNonEmpty(plan.template?.displayName) {
            return templateTitle
        }
        if let missionKey = trimmedNonEmpty(plan.missionKey) {
            return missionKey
        }
        return "Mission Receipt"
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension CoordinatorMissionReceiptProjection {
    struct PolicySummary: Equatable {
        var name: String
        var pace: String
        var maxConcurrent: Int
        var askClasses: [String]
        var definitionOfDone: String?
        var standingGuidance: String?

        init(policy: CoordinatorMissionPolicySnapshot) {
            name = policy.name
            pace = policy.defaultPace.rawValue
            maxConcurrent = policy.maxConcurrent
            askClasses = Self.askClasses(from: policy)
            definitionOfDone = policy.definitionOfDone
            standingGuidance = policy.standingGuidance
        }

        private static func askClasses(from policy: CoordinatorMissionPolicySnapshot) -> [String] {
            let knownAskClasses = CoordinatorMissionDecisionClass.allCases
                .filter { policy.resolvedAutonomy(for: $0) == .ask }
                .map(\.rawValue)
            let knownClassNames = Set(CoordinatorMissionDecisionClass.allCases.map(\.rawValue))
            let unknownAskClasses = policy.autonomy
                .filter { key, mode in mode == .ask && !knownClassNames.contains(key) }
                .map(\.key)
                .sorted()
            return knownAskClasses + unknownAskClasses
        }
    }

    struct DecisionCounts: Equatable {
        struct ClassCount: Equatable {
            var name: String
            var count: Int
        }

        var total: Int
        var user: Int
        var director: Int
        var byClass: [ClassCount]

        init(decisions: [CoordinatorMissionDecisionRecord]) {
            total = decisions.count
            user = decisions.count { $0.actor == .user }
            director = decisions.count { $0.actor == .director }

            let countsByClass = Dictionary(grouping: decisions, by: \.decisionClass)
                .mapValues(\.count)
            let knownClassNames = Set(CoordinatorMissionDecisionClass.allCases.map(\.rawValue))
            let knownClassCounts = CoordinatorMissionDecisionClass.allCases.compactMap { decisionClass -> ClassCount? in
                guard let count = countsByClass[decisionClass.rawValue] else { return nil }
                return ClassCount(name: decisionClass.rawValue, count: count)
            }
            let unknownClassCounts = countsByClass
                .filter { key, _ in !knownClassNames.contains(key) }
                .map { ClassCount(name: $0.key, count: $0.value) }
                .sorted { $0.name < $1.name }
            byClass = knownClassCounts + unknownClassCounts
        }
    }

    struct RevisionProposalHistorySummary: Equatable {
        struct ReferencedEvidence: Equatable {
            var id: UUID
            var verdict: String
            var summary: String
        }

        var proposalID: UUID
        var summary: String
        var resolutionID: UUID?
        var outcome: String?
        var wasTrustedUserResolution: Bool
        var referencedEvidence: [ReferencedEvidence]

        init(
            proposal: CoordinatorMissionRevisionProposal,
            resolution: CoordinatorMissionRevisionProposalResolution?,
            evidenceByID: [UUID: CoordinatorMissionEvidenceRecord]
        ) {
            proposalID = proposal.id
            summary = proposal.summary
            resolutionID = resolution?.id
            outcome = resolution?.outcome.rawValue
            wasTrustedUserResolution = resolution?.userDecisionID != nil
            referencedEvidence = proposal.supportingEvidenceIDs.compactMap { evidenceID in
                evidenceByID[evidenceID].map {
                    ReferencedEvidence(
                        id: evidenceID,
                        verdict: $0.verdict.rawValue,
                        summary: $0.summary
                    )
                }
            }
        }
    }

    struct EvidenceSummary: Equatable {
        var verdict: String
        var summary: String

        init(evidence: CoordinatorMissionEvidenceRecord) {
            verdict = evidence.verdict.rawValue
            summary = evidence.summary
        }
    }
}
