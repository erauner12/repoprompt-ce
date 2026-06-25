import Foundation

struct CoordinatorFollowThroughState: Codable, Equatable {
    var originalObjectiveSummary: String?
    var missionTemplate: CoordinatorMissionTemplateSummary?
    var missionPlan: CoordinatorMissionPlan?
    var observedChildPhases: [UUID: CoordinatorFollowThroughChildPhase]
    var pendingEvents: [CoordinatorFollowThroughEvent]
    var handledEventIDs: Set<String>
    var lastResume: CoordinatorFollowThroughResumeRecord?
    var childInteractionResponses: [CoordinatorChildInteractionResponseRecord]

    init(
        originalObjectiveSummary: String? = nil,
        missionTemplate: CoordinatorMissionTemplateSummary? = nil,
        missionPlan: CoordinatorMissionPlan? = nil,
        observedChildPhases: [UUID: CoordinatorFollowThroughChildPhase] = [:],
        pendingEvents: [CoordinatorFollowThroughEvent] = [],
        handledEventIDs: Set<String> = [],
        lastResume: CoordinatorFollowThroughResumeRecord? = nil,
        childInteractionResponses: [CoordinatorChildInteractionResponseRecord] = []
    ) {
        self.originalObjectiveSummary = originalObjectiveSummary
        self.missionTemplate = missionTemplate
        self.missionPlan = missionPlan
        self.observedChildPhases = observedChildPhases
        self.pendingEvents = pendingEvents
        self.handledEventIDs = handledEventIDs
        self.lastResume = lastResume
        self.childInteractionResponses = childInteractionResponses
    }

    mutating func rememberObjective(
        _ text: String,
        missionTemplate: CoordinatorMissionTemplateSummary? = nil,
        resetMissionPlan: Bool = true
    ) {
        originalObjectiveSummary = Self.summary(from: text)
        self.missionTemplate = missionTemplate
        if resetMissionPlan {
            missionPlan = nil
        }
        observedChildPhases.removeAll()
        pendingEvents.removeAll()
        handledEventIDs.removeAll()
        lastResume = nil
        childInteractionResponses.removeAll()
    }

    mutating func updateMissionPlan(
        objective: String?,
        workstreams incomingWorkstreams: [CoordinatorMissionWorkstreamSummary],
        updatedAt: Date = Date()
    ) {
        updateMissionPlan(
            CoordinatorMissionPlanUpdate(
                objective: objective,
                workstreams: incomingWorkstreams,
                updatedAt: updatedAt
            )
        )
    }

    mutating func updateMissionPlan(_ update: CoordinatorMissionPlanUpdate) {
        let existingByID = Dictionary(uniqueKeysWithValues: (missionPlan?.workstreams ?? []).map { ($0.id, $0) })
        let existingByTitle = Dictionary(
            (missionPlan?.workstreams ?? []).map { ($0.title.normalizedMissionPlanTitleKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let workstreams = (update.workstreams ?? missionPlan?.workstreams ?? []).map { incoming -> CoordinatorMissionWorkstreamSummary in
            if let existing = existingByID[incoming.id] {
                return incoming.reusingStableID(existing.id)
            }
            if let existing = existingByTitle[incoming.title.normalizedMissionPlanTitleKey] {
                return incoming.reusingStableID(existing.id)
            }
            return incoming
        }
        missionPlan = CoordinatorMissionPlan(
            id: missionPlan?.id ?? UUID(),
            revision: (missionPlan?.revision ?? 0) + 1,
            objective: update.objective?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? missionPlan?.objective,
            status: update.status ?? missionPlan?.status ?? .draft,
            approvalState: update.approvalState ?? missionPlan?.approvalState ?? .notRequired,
            template: missionTemplate,
            workstreams: workstreams,
            nodes: update.nodes ?? missionPlan?.nodes ?? [],
            events: (missionPlan?.events ?? []) + [
                CoordinatorMissionPlanEvent(
                    kind: missionPlan == nil ? .created : .revised,
                    timestamp: update.updatedAt,
                    summary: "Mission plan updated"
                )
            ] + update.events,
            updatedAt: update.updatedAt
        )
    }

    @discardableResult
    mutating func completeSatisfiedCoordinatorOnlyRunningMissionPlanNodes(at date: Date = Date()) -> Bool {
        guard let plan = missionPlan,
              plan.status != .completed,
              !plan.nodes.isEmpty
        else { return false }

        let nodeByID = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0) })
        var nodes = plan.nodes
        var completedNodes: [CoordinatorMissionPlanNode] = []
        for index in nodes.indices {
            let node = nodes[index]
            guard node.status == .running,
                  node.executionPolicy == .coordinatorOnly,
                  node.dependsOn.allSatisfy({ nodeByID[$0]?.status.isTerminal == true })
            else { continue }
            nodes[index].status = .completed
            completedNodes.append(nodes[index])
        }
        guard !completedNodes.isEmpty else { return false }

        let status: CoordinatorMissionPlanStatus = nodes.allSatisfy(\.status.isTerminal) ? .completed : plan.status
        updateMissionPlan(CoordinatorMissionPlanUpdate(
            status: status,
            nodes: nodes,
            events: completedNodes.map { node in
                CoordinatorMissionPlanEvent(
                    kind: .nodeCompleted,
                    nodeID: node.id,
                    timestamp: date,
                    summary: "\(node.title) node completed."
                )
            },
            updatedAt: date
        ))
        return true
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

struct CoordinatorMissionPlanUpdate: Equatable {
    var objective: String?
    var status: CoordinatorMissionPlanStatus?
    var approvalState: CoordinatorMissionPlanApprovalState?
    var workstreams: [CoordinatorMissionWorkstreamSummary]?
    var nodes: [CoordinatorMissionPlanNode]?
    var events: [CoordinatorMissionPlanEvent]
    var updatedAt: Date

    init(
        objective: String? = nil,
        status: CoordinatorMissionPlanStatus? = nil,
        approvalState: CoordinatorMissionPlanApprovalState? = nil,
        workstreams: [CoordinatorMissionWorkstreamSummary]? = nil,
        nodes: [CoordinatorMissionPlanNode]? = nil,
        events: [CoordinatorMissionPlanEvent] = [],
        updatedAt: Date = Date()
    ) {
        self.objective = objective
        self.status = status
        self.approvalState = approvalState
        self.workstreams = workstreams
        self.nodes = nodes
        self.events = events
        self.updatedAt = updatedAt
    }
}

struct CoordinatorMissionPlan: Codable, Equatable {
    var id: UUID
    var revision: Int
    var objective: String?
    var status: CoordinatorMissionPlanStatus
    var approvalState: CoordinatorMissionPlanApprovalState
    var template: CoordinatorMissionTemplateSummary?
    var workstreams: [CoordinatorMissionWorkstreamSummary]
    var nodes: [CoordinatorMissionPlanNode]
    var events: [CoordinatorMissionPlanEvent]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        revision: Int = 1,
        objective: String? = nil,
        status: CoordinatorMissionPlanStatus = .draft,
        approvalState: CoordinatorMissionPlanApprovalState = .notRequired,
        template: CoordinatorMissionTemplateSummary? = nil,
        workstreams: [CoordinatorMissionWorkstreamSummary] = [],
        nodes: [CoordinatorMissionPlanNode] = [],
        events: [CoordinatorMissionPlanEvent] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.revision = max(1, revision)
        self.objective = objective?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.status = status
        self.approvalState = approvalState
        self.template = template
        self.workstreams = workstreams
        self.nodes = nodes
        self.events = events
        self.updatedAt = updatedAt
    }
}

struct CoordinatorMissionWorkstreamSummary: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var purpose: String
    var role: String?
    var defaultPolicy: CoordinatorMissionExecutionPolicy
    var worktreeStrategy: CoordinatorMissionWorktreeStrategy
    var primarySessionID: UUID?
    var relatedSessionIDs: [UUID]

    init(
        id: UUID = UUID(),
        title: String,
        purpose: String,
        role: String? = nil,
        defaultPolicy: CoordinatorMissionExecutionPolicy,
        worktreeStrategy: CoordinatorMissionWorktreeStrategy,
        primarySessionID: UUID? = nil,
        relatedSessionIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.defaultPolicy = defaultPolicy
        self.worktreeStrategy = worktreeStrategy
        self.primarySessionID = primarySessionID
        self.relatedSessionIDs = relatedSessionIDs
    }

    var worktreeID: String? {
        worktreeStrategy.worktreeID
    }

    var linkedSessionIDs: Set<UUID> {
        Set(([primarySessionID].compactMap(\.self)) + relatedSessionIDs)
    }

    fileprivate func reusingStableID(_ stableID: UUID) -> CoordinatorMissionWorkstreamSummary {
        CoordinatorMissionWorkstreamSummary(
            id: stableID,
            title: title,
            purpose: purpose,
            role: role,
            defaultPolicy: defaultPolicy,
            worktreeStrategy: worktreeStrategy,
            primarySessionID: primarySessionID,
            relatedSessionIDs: relatedSessionIDs
        )
    }
}

struct CoordinatorMissionWorktreeStrategy: Codable, Equatable {
    var mode: CoordinatorMissionWorktreeMode
    var worktreeID: String?
    var reason: String?

    init(
        mode: CoordinatorMissionWorktreeMode,
        worktreeID: String? = nil,
        reason: String? = nil
    ) {
        self.mode = mode
        self.worktreeID = worktreeID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

enum CoordinatorMissionWorktreeMode: String, Codable, Equatable, CaseIterable {
    case noneReadOnly
    case createIsolated
    case reuseExisting
    case reuseWorkstream
    case askUser

    var displayName: String {
        switch self {
        case .noneReadOnly: "Read-only"
        case .createIsolated: "New isolated worktree"
        case .reuseExisting: "Existing worktree"
        case .reuseWorkstream: "Same workstream worktree"
        case .askUser: "Needs decision"
        }
    }
}

enum CoordinatorMissionPlanStatus: String, Codable, Equatable, CaseIterable {
    case draft
    case approved
    case running
    case blocked
    case completed
    case stopped
}

enum CoordinatorMissionPlanApprovalState: String, Codable, Equatable, CaseIterable {
    case notRequired = "not_required"
    case awaitingApproval = "awaiting_approval"
    case approved
    case revisionRequested = "revision_requested"
}

struct CoordinatorMissionPlanNode: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var detail: String?
    var workstreamID: UUID
    var dependsOn: [UUID]
    var role: String?
    var executionPolicy: CoordinatorMissionExecutionPolicy
    var status: CoordinatorMissionPlanNodeStatus
    var boundSessionID: UUID?
    var boundInteractionID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        workstreamID: UUID,
        dependsOn: [UUID] = [],
        role: String? = nil,
        executionPolicy: CoordinatorMissionExecutionPolicy,
        status: CoordinatorMissionPlanNodeStatus = .pending,
        boundSessionID: UUID? = nil,
        boundInteractionID: UUID? = nil
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.workstreamID = workstreamID
        self.dependsOn = dependsOn
        self.role = role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.executionPolicy = executionPolicy
        self.status = status
        self.boundSessionID = boundSessionID
        self.boundInteractionID = boundInteractionID
    }
}

enum CoordinatorMissionPlanNodeStatus: String, Codable, Equatable, CaseIterable {
    case pending
    case running
    case completed
    case blocked
    case skipped
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .skipped, .cancelled:
            true
        case .pending, .running, .blocked:
            false
        }
    }
}

struct CoordinatorMissionPlanEvent: Codable, Equatable, Identifiable {
    let id: UUID
    var kind: CoordinatorMissionPlanEventKind
    var nodeID: UUID?
    var sessionID: UUID?
    var interactionID: UUID?
    var timestamp: Date
    var summary: String?

    init(
        id: UUID = UUID(),
        kind: CoordinatorMissionPlanEventKind,
        nodeID: UUID? = nil,
        sessionID: UUID? = nil,
        interactionID: UUID? = nil,
        timestamp: Date = Date(),
        summary: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.nodeID = nodeID
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.timestamp = timestamp
        self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

enum CoordinatorMissionPlanEventKind: String, Codable, Equatable, CaseIterable {
    case created
    case revised
    case approved
    case nodeStarted = "node_started"
    case nodeCompleted = "node_completed"
    case nodeBlocked = "node_blocked"
    case sessionBound = "session_bound"
    case gateCleared = "gate_cleared"
}

enum CoordinatorMissionExecutionPolicy: String, Codable, Equatable, CaseIterable {
    case coordinatorOnly = "coordinator_only"
    case steerPrimary = "steer_primary"
    case freshSiblingOnSameWorktree = "fresh_sibling_on_same_worktree"
    case freshWorktree = "fresh_worktree"
    case askUser = "ask_user"

    var displayName: String {
        switch self {
        case .coordinatorOnly: "Coordinator only"
        case .steerPrimary: "Steer primary"
        case .freshSiblingOnSameWorktree: "Sibling on same worktree"
        case .freshWorktree: "Fresh worktree"
        case .askUser: "Ask user"
        }
    }
}

private extension String {
    var normalizedMissionPlanTitleKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
