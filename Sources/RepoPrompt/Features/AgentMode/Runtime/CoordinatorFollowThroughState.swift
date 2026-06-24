import Foundation

struct CoordinatorFollowThroughState: Codable, Equatable {
    var originalObjectiveSummary: String?
    var missionTemplate: CoordinatorMissionTemplateSummary?
    var observedChildPhases: [UUID: CoordinatorFollowThroughChildPhase]
    var pendingEvents: [CoordinatorFollowThroughEvent]
    var handledEventIDs: Set<String>
    var lastResume: CoordinatorFollowThroughResumeRecord?
    var childInteractionResponses: [CoordinatorChildInteractionResponseRecord]

    init(
        originalObjectiveSummary: String? = nil,
        missionTemplate: CoordinatorMissionTemplateSummary? = nil,
        observedChildPhases: [UUID: CoordinatorFollowThroughChildPhase] = [:],
        pendingEvents: [CoordinatorFollowThroughEvent] = [],
        handledEventIDs: Set<String> = [],
        lastResume: CoordinatorFollowThroughResumeRecord? = nil,
        childInteractionResponses: [CoordinatorChildInteractionResponseRecord] = []
    ) {
        self.originalObjectiveSummary = originalObjectiveSummary
        self.missionTemplate = missionTemplate
        self.observedChildPhases = observedChildPhases
        self.pendingEvents = pendingEvents
        self.handledEventIDs = handledEventIDs
        self.lastResume = lastResume
        self.childInteractionResponses = childInteractionResponses
    }

    mutating func rememberObjective(_ text: String, missionTemplate: CoordinatorMissionTemplateSummary? = nil) {
        originalObjectiveSummary = Self.summary(from: text)
        self.missionTemplate = missionTemplate
        observedChildPhases.removeAll()
        pendingEvents.removeAll()
        handledEventIDs.removeAll()
        lastResume = nil
        childInteractionResponses.removeAll()
    }

    mutating func updateObservedPhases(from rows: [CoordinatorModeRow]) {
        for row in rows {
            guard row.parentCoordinator != nil else { continue }
            observedChildPhases[row.sessionID] = CoordinatorFollowThroughChildPhase(row: row)
        }
    }

    mutating func enqueue(_ event: CoordinatorFollowThroughEvent) {
        guard !handledEventIDs.contains(event.id),
              !pendingEvents.contains(where: { $0.id == event.id })
        else { return }
        pendingEvents.append(event)
    }

    mutating func removePendingEvents(where shouldRemove: (CoordinatorFollowThroughEvent) -> Bool) {
        pendingEvents.removeAll(where: shouldRemove)
    }

    mutating func markSubmitted(_ event: CoordinatorFollowThroughEvent, at date: Date = Date()) {
        pendingEvents.removeAll { $0.id == event.id }
        handledEventIDs.insert(event.id)
        lastResume = CoordinatorFollowThroughResumeRecord(
            eventID: event.id,
            resumedAt: date,
            result: .submitted
        )
    }

    mutating func markDeferred(_ event: CoordinatorFollowThroughEvent, at date: Date = Date()) {
        lastResume = CoordinatorFollowThroughResumeRecord(
            eventID: event.id,
            resumedAt: date,
            result: .deferred
        )
    }

    mutating func rememberChildInteractionResponse(row: CoordinatorModeRow, text: String, at date: Date = Date()) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }
        let interactionID = row.pendingInteraction?.id
        if let existingIndex = childInteractionResponses.firstIndex(where: { record in
            record.childSessionID == row.sessionID && record.interactionID == interactionID
        }) {
            childInteractionResponses[existingIndex] = CoordinatorChildInteractionResponseRecord(
                id: childInteractionResponses[existingIndex].id,
                childSessionID: row.sessionID,
                childTitle: row.title,
                interactionID: interactionID,
                answeredAt: date,
                responseText: Self.summary(from: normalizedText, maxLength: 1000)
            )
        } else {
            childInteractionResponses.append(CoordinatorChildInteractionResponseRecord(
                childSessionID: row.sessionID,
                childTitle: row.title,
                interactionID: interactionID,
                answeredAt: date,
                responseText: Self.summary(from: normalizedText, maxLength: 1000)
            ))
        }
        childInteractionResponses.sort { lhs, rhs in
            if lhs.answeredAt == rhs.answeredAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.answeredAt < rhs.answeredAt
        }
        if childInteractionResponses.count > 50 {
            childInteractionResponses.removeFirst(childInteractionResponses.count - 50)
        }
    }

    private static func summary(from text: String) -> String {
        summary(from: text, maxLength: 240)
    }

    private static func summary(from text: String, maxLength: Int) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard collapsed.count > maxLength else { return collapsed }
        return "\(collapsed.prefix(maxLength - 3))..."
    }
}

struct CoordinatorChildInteractionResponseRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let childSessionID: UUID
    let childTitle: String
    let interactionID: UUID?
    let answeredAt: Date
    let responseText: String

    init(
        id: UUID = UUID(),
        childSessionID: UUID,
        childTitle: String,
        interactionID: UUID?,
        answeredAt: Date,
        responseText: String
    ) {
        self.id = id
        self.childSessionID = childSessionID
        self.childTitle = childTitle
        self.interactionID = interactionID
        self.answeredAt = answeredAt
        self.responseText = responseText
    }

    var transcriptText: String {
        "You answered \(childTitle):\n\n\(responseText)"
    }
}

enum CoordinatorFollowThroughChildPhase: String, Codable, Equatable {
    case delegated
    case running
    case needsUser
    case review
    case blocked
    case done

    init(statusGroup: CoordinatorModeStatusGroup) {
        switch statusGroup {
        case .needsYou:
            self = .needsUser
        case .working:
            self = .running
        case .blocked:
            self = .blocked
        case .review:
            self = .review
        case .done:
            self = .done
        }
    }

    init(workstreamPhase: CoordinatorModeRow.WorkstreamSummary.Phase) {
        switch workstreamPhase {
        case .delegated:
            self = .delegated
        case .running:
            self = .running
        case .needsUser:
            self = .needsUser
        case .review:
            self = .review
        case .blocked:
            self = .blocked
        case .done:
            self = .done
        }
    }

    init(row: CoordinatorModeRow) {
        if let workstreamPhase = row.workstreamSummary?.phase {
            self.init(workstreamPhase: workstreamPhase)
        } else {
            self.init(statusGroup: row.statusGroup)
        }
    }
}

struct CoordinatorFollowThroughResumeRecord: Codable, Equatable {
    let eventID: String
    let resumedAt: Date
    let result: CoordinatorFollowThroughResumeResult
}

enum CoordinatorFollowThroughResumeResult: String, Codable, Equatable {
    case submitted
    case deferred
    case rejected
}

struct CoordinatorFollowThroughEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, Equatable {
        case childTerminal
        case gateCleared
    }

    let id: String
    let kind: Kind
    let coordinatorSessionID: UUID
    let childSessionID: UUID?
    let childTitle: String?
    let gate: CoordinatorContinuationGate?
    let phase: CoordinatorFollowThroughChildPhase?
    let detail: String

    var resumeDirective: String {
        var lines = [
            "<coordinator_follow_through_resume event_id=\"\(id)\" kind=\"\(kind.rawValue)\">",
            "The app observed a Coordinator follow-through event for your current parent thread.",
            "",
            "Event:",
            "- \(detail)"
        ]
        if let childTitle {
            lines.append("- Child session: \(childTitle)")
        }
        if let gate {
            lines.append(contentsOf: gate.directiveLines)
        }
        lines.append(contentsOf: [
            "",
            "Continue the original objective only if this clears a safe boundary.",
            "An action-approval gate permits only the explicitly approved action and does not approve any later action.",
            "Respect any remaining permission, approval, blocked, or needs-user boundary. If the next safe step is unclear, ask one concise question and stop.",
            "</coordinator_follow_through_resume>"
        ])
        return lines.joined(separator: "\n")
    }
}

struct CoordinatorContinuationGate: Codable, Equatable, Identifiable {
    enum GateType: String, Codable, Equatable {
        case actionApprovalRequired
        case needsInput
        case permission
        case blocked
        case manualCheckpoint
    }

    enum ApprovedAction: String, Codable, Equatable {
        case continuePlan
        case commitChanges
        case createPullRequest
        case applyMergePreview
        case mergePullRequest
        case pushBranch
    }

    enum ClearedBy: String, Codable, Equatable {
        case human
        case app
        case tool
    }

    let id: String
    let type: GateType
    let subjectID: String?
    let subjectTitle: String?
    let ownerCoordinatorSessionID: UUID?
    let approvedAction: ApprovedAction?
    let detail: String
    let clearedBy: ClearedBy

    static func actionApproval(
        gateID: String,
        action: ApprovedAction,
        subjectID: String? = nil,
        subjectTitle: String? = nil,
        ownerCoordinatorSessionID: UUID? = nil
    ) -> Self {
        Self(
            id: gateID,
            type: .actionApprovalRequired,
            subjectID: subjectID,
            subjectTitle: subjectTitle,
            ownerCoordinatorSessionID: ownerCoordinatorSessionID,
            approvedAction: action,
            detail: "Human approved exactly one next action: \(action.rawValue).",
            clearedBy: .human
        )
    }

    var directiveLines: [String] {
        var lines = [
            "",
            "Gate:",
            "- Gate ID: \(id)",
            "- Gate type: \(type.rawValue)",
            "- Cleared by: \(clearedBy.rawValue)",
            "- \(detail)"
        ]
        if let subjectID {
            lines.append("- Subject ID: \(subjectID)")
        }
        if let subjectTitle {
            lines.append("- Subject: \(subjectTitle)")
        }
        if let ownerCoordinatorSessionID {
            lines.append("- Owning Coordinator session: \(ownerCoordinatorSessionID.uuidString)")
        }
        if let approvedAction {
            lines.append("- Approved action: \(approvedAction.rawValue)")
        }
        return lines
    }
}
