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
        let workstreams = mergeWorkstreams(
            existing: missionPlan?.workstreams ?? [],
            incoming: update.workstreams,
            replace: update.replaceWorkstreams,
            existingByID: existingByID,
            existingByTitle: existingByTitle
        )
        let nodes = mergeNodes(
            existing: missionPlan?.nodes ?? [],
            incoming: update.nodes,
            replace: update.replaceNodes
        )
        let routingDecisions = mergeRoutingDecisions(
            existing: missionPlan?.routingDecisions ?? [],
            incoming: update.routingDecisions
        )
        let decisions = mergeDecisionRecords(
            existing: missionPlan?.decisions ?? [],
            incoming: update.decisions
        )
        let evidence = mergeEvidenceRecords(
            existing: missionPlan?.evidence ?? [],
            incoming: update.evidence
        )
        missionPlan = CoordinatorMissionPlan(
            id: missionPlan?.id ?? UUID(),
            revision: (missionPlan?.revision ?? 0) + 1,
            missionKey: update.missionKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? missionPlan?.missionKey,
            objective: update.objective?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? missionPlan?.objective,
            predecessorMissionID: update.predecessorMissionID ?? missionPlan?.predecessorMissionID,
            predecessorTitle: update.predecessorTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? missionPlan?.predecessorTitle,
            predecessorSummary: update.predecessorSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? missionPlan?.predecessorSummary,
            status: update.status ?? missionPlan?.status ?? .draft,
            approvalState: update.approvalState ?? missionPlan?.approvalState ?? .notRequired,
            template: missionTemplate,
            shapeSummary: update.shapeSummary ?? missionPlan?.shapeSummary,
            policySnapshot: update.policySnapshot ?? missionPlan?.policySnapshot,
            autonomy: update.autonomy ?? missionPlan?.autonomy ?? CoordinatorMissionPolicySnapshot.defaultAutonomy,
            workstreams: workstreams,
            nodes: nodes,
            routingDecisions: routingDecisions,
            decisions: decisions,
            evidence: evidence,
            events: (missionPlan?.events ?? []) + [
                CoordinatorMissionPlanEvent(
                    kind: missionPlan == nil ? .created : .revised,
                    timestamp: update.updatedAt,
                    summary: "Mission plan updated"
                )
            ] + update.events,
            updatedAt: update.updatedAt
        )
        if missionPlan?.status == .stopped {
            pendingEvents.removeAll()
        }
    }

    private func mergeWorkstreams(
        existing: [CoordinatorMissionWorkstreamSummary],
        incoming: [CoordinatorMissionWorkstreamSummary]?,
        replace: Bool,
        existingByID: [UUID: CoordinatorMissionWorkstreamSummary],
        existingByTitle: [String: CoordinatorMissionWorkstreamSummary]
    ) -> [CoordinatorMissionWorkstreamSummary] {
        if replace {
            return incoming ?? []
        }
        guard let incoming else { return existing }
        guard !existing.isEmpty else { return incoming }

        let normalizedIncoming = incoming.map { workstream -> CoordinatorMissionWorkstreamSummary in
            if let existing = existingByID[workstream.id] {
                return workstream.reusingStableID(existing.id)
            }
            if let existing = existingByTitle[workstream.title.normalizedMissionPlanTitleKey] {
                return workstream.reusingStableID(existing.id)
            }
            return workstream
        }

        var updatesByID = Dictionary(uniqueKeysWithValues: normalizedIncoming.map { ($0.id, $0) })
        var merged = existing.map { workstream -> CoordinatorMissionWorkstreamSummary in
            updatesByID.removeValue(forKey: workstream.id) ?? workstream
        }
        merged.append(contentsOf: normalizedIncoming.filter { updatesByID[$0.id] != nil })
        return merged
    }

    private func mergeNodes(
        existing: [CoordinatorMissionPlanNode],
        incoming: [CoordinatorMissionPlanNode]?,
        replace: Bool
    ) -> [CoordinatorMissionPlanNode] {
        if replace {
            return incoming ?? []
        }
        guard let incoming else { return existing }
        guard !existing.isEmpty else { return incoming }

        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let existingByTitle = Dictionary(
            existing.map { ($0.title.normalizedMissionPlanTitleKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let normalizedIncoming = incoming.map { node -> CoordinatorMissionPlanNode in
            if existingByID[node.id] != nil {
                return node
            }
            if let existingNode = existingByTitle[node.title.normalizedMissionPlanTitleKey] {
                return node.reusingStableID(existingNode.id)
            }
            return node
        }

        var updatesByID = Dictionary(uniqueKeysWithValues: normalizedIncoming.map { ($0.id, $0) })
        var merged = existing.map { node -> CoordinatorMissionPlanNode in
            updatesByID.removeValue(forKey: node.id) ?? node
        }
        merged.append(contentsOf: normalizedIncoming.filter { updatesByID[$0.id] != nil })
        return merged
    }

    private func mergeRoutingDecisions(
        existing: [CoordinatorMissionRoutingDecision],
        incoming: [CoordinatorMissionRoutingDecision]?
    ) -> [CoordinatorMissionRoutingDecision] {
        guard let incoming, !incoming.isEmpty else { return existing }
        var mergedByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for decision in incoming {
            mergedByID[decision.id] = decision
        }
        return mergedByID.values.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private func mergeDecisionRecords(
        existing: [CoordinatorMissionDecisionRecord],
        incoming: [CoordinatorMissionDecisionRecord]?
    ) -> [CoordinatorMissionDecisionRecord] {
        guard let incoming, !incoming.isEmpty else { return existing }
        var seenIDs = Set(existing.map(\.id))
        var merged = existing
        for record in incoming where !seenIDs.contains(record.id) {
            merged.append(record)
            seenIDs.insert(record.id)
        }
        return merged
    }

    private func mergeEvidenceRecords(
        existing: [CoordinatorMissionEvidenceRecord],
        incoming: [CoordinatorMissionEvidenceRecord]?
    ) -> [CoordinatorMissionEvidenceRecord] {
        guard let incoming, !incoming.isEmpty else { return existing }
        var seenIDs = Set(existing.map(\.id))
        var merged = existing
        for record in incoming where !seenIDs.contains(record.id) {
            merged.append(record)
            seenIDs.insert(record.id)
        }
        return merged
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
    var missionKey: String?
    var objective: String?
    var predecessorMissionID: UUID?
    var predecessorTitle: String?
    var predecessorSummary: String?
    var status: CoordinatorMissionPlanStatus?
    var approvalState: CoordinatorMissionPlanApprovalState?
    var shapeSummary: CoordinatorMissionShapeSummary?
    var policySnapshot: CoordinatorMissionPolicySnapshot?
    var autonomy: [String: CoordinatorMissionAutonomyMode]?
    var workstreams: [CoordinatorMissionWorkstreamSummary]?
    var nodes: [CoordinatorMissionPlanNode]?
    var replaceWorkstreams: Bool
    var replaceNodes: Bool
    var routingDecisions: [CoordinatorMissionRoutingDecision]?
    var decisions: [CoordinatorMissionDecisionRecord]?
    var evidence: [CoordinatorMissionEvidenceRecord]?
    var events: [CoordinatorMissionPlanEvent]
    var updatedAt: Date

    init(
        objective: String? = nil,
        missionKey: String? = nil,
        predecessorMissionID: UUID? = nil,
        predecessorTitle: String? = nil,
        predecessorSummary: String? = nil,
        status: CoordinatorMissionPlanStatus? = nil,
        approvalState: CoordinatorMissionPlanApprovalState? = nil,
        shapeSummary: CoordinatorMissionShapeSummary? = nil,
        policySnapshot: CoordinatorMissionPolicySnapshot? = nil,
        autonomy: [String: CoordinatorMissionAutonomyMode]? = nil,
        workstreams: [CoordinatorMissionWorkstreamSummary]? = nil,
        nodes: [CoordinatorMissionPlanNode]? = nil,
        replaceWorkstreams: Bool = false,
        replaceNodes: Bool = false,
        routingDecisions: [CoordinatorMissionRoutingDecision]? = nil,
        decisions: [CoordinatorMissionDecisionRecord]? = nil,
        evidence: [CoordinatorMissionEvidenceRecord]? = nil,
        events: [CoordinatorMissionPlanEvent] = [],
        updatedAt: Date = Date()
    ) {
        self.missionKey = missionKey
        self.objective = objective
        self.predecessorMissionID = predecessorMissionID
        self.predecessorTitle = predecessorTitle
        self.predecessorSummary = predecessorSummary
        self.status = status
        self.approvalState = approvalState
        self.shapeSummary = shapeSummary
        self.policySnapshot = policySnapshot
        self.autonomy = autonomy
        self.workstreams = workstreams
        self.nodes = nodes
        self.replaceWorkstreams = replaceWorkstreams
        self.replaceNodes = replaceNodes
        self.routingDecisions = routingDecisions
        self.decisions = decisions
        self.evidence = evidence
        self.events = events
        self.updatedAt = updatedAt
    }
}

struct CoordinatorMissionPlan: Codable, Equatable {
    var id: UUID
    var revision: Int
    var missionKey: String?
    var objective: String?
    var predecessorMissionID: UUID?
    var predecessorTitle: String?
    var predecessorSummary: String?
    var status: CoordinatorMissionPlanStatus
    var approvalState: CoordinatorMissionPlanApprovalState
    var template: CoordinatorMissionTemplateSummary?
    var shapeSummary: CoordinatorMissionShapeSummary?
    var policySnapshot: CoordinatorMissionPolicySnapshot?
    var autonomy: [String: CoordinatorMissionAutonomyMode]
    var workstreams: [CoordinatorMissionWorkstreamSummary]
    var nodes: [CoordinatorMissionPlanNode]
    var routingDecisions: [CoordinatorMissionRoutingDecision]
    var decisions: [CoordinatorMissionDecisionRecord]
    var evidence: [CoordinatorMissionEvidenceRecord]
    var events: [CoordinatorMissionPlanEvent]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        revision: Int = 1,
        missionKey: String? = nil,
        objective: String? = nil,
        predecessorMissionID: UUID? = nil,
        predecessorTitle: String? = nil,
        predecessorSummary: String? = nil,
        status: CoordinatorMissionPlanStatus = .draft,
        approvalState: CoordinatorMissionPlanApprovalState = .notRequired,
        template: CoordinatorMissionTemplateSummary? = nil,
        shapeSummary: CoordinatorMissionShapeSummary? = nil,
        policySnapshot: CoordinatorMissionPolicySnapshot? = nil,
        autonomy: [String: CoordinatorMissionAutonomyMode] = CoordinatorMissionPolicySnapshot.defaultAutonomy,
        workstreams: [CoordinatorMissionWorkstreamSummary] = [],
        nodes: [CoordinatorMissionPlanNode] = [],
        routingDecisions: [CoordinatorMissionRoutingDecision] = [],
        decisions: [CoordinatorMissionDecisionRecord] = [],
        evidence: [CoordinatorMissionEvidenceRecord] = [],
        events: [CoordinatorMissionPlanEvent] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.revision = max(1, revision)
        self.missionKey = missionKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.objective = objective?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.predecessorMissionID = predecessorMissionID
        self.predecessorTitle = predecessorTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.predecessorSummary = predecessorSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.status = status
        self.approvalState = approvalState
        self.template = template
        self.shapeSummary = shapeSummary
        self.policySnapshot = policySnapshot
        self.autonomy = autonomy
        self.workstreams = workstreams
        self.nodes = nodes
        self.routingDecisions = routingDecisions.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.timestamp < rhs.timestamp
        }
        self.decisions = decisions
        self.evidence = evidence
        self.events = events
        self.updatedAt = updatedAt
    }

    mutating func stopMission(cancelledSessionIDs: Set<UUID>, at date: Date = Date()) {
        status = .stopped
        updatedAt = date
        nodes = nodes.map { node in
            var next = node
            let boundSessionWasCancelled = next.boundSessionID.map(cancelledSessionIDs.contains) ?? false
            if next.status == .running || next.status == .blocked || boundSessionWasCancelled {
                next.status = .cancelled
            }
            return next
        }
        let routingDecisions = cancelledSessionIDs
            .sorted { $0.uuidString < $1.uuidString }
            .map { sessionID in
                CoordinatorMissionRoutingDecision(
                    timestamp: date,
                    decision: .cancelOrReplace,
                    operation: .agentRunCancel,
                    sessionID: sessionID,
                    reason: "User stopped the Coordinator Mission."
                )
            }
        self.routingDecisions.append(contentsOf: routingDecisions)
        events.append(CoordinatorMissionPlanEvent(
            kind: .revised,
            timestamp: date,
            summary: "Mission stopped by user."
        ))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case revision
        case missionKey
        case objective
        case predecessorMissionID
        case predecessorTitle
        case predecessorSummary
        case status
        case approvalState
        case template
        case shapeSummary
        case policySnapshot
        case autonomy
        case workstreams
        case nodes
        case routingDecisions
        case decisions
        case evidence
        case events
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            revision: container.decode(Int.self, forKey: .revision),
            missionKey: container.decodeIfPresent(String.self, forKey: .missionKey),
            objective: container.decodeIfPresent(String.self, forKey: .objective),
            predecessorMissionID: container.decodeIfPresent(UUID.self, forKey: .predecessorMissionID),
            predecessorTitle: container.decodeIfPresent(String.self, forKey: .predecessorTitle),
            predecessorSummary: container.decodeIfPresent(String.self, forKey: .predecessorSummary),
            status: container.decode(CoordinatorMissionPlanStatus.self, forKey: .status),
            approvalState: container.decode(CoordinatorMissionPlanApprovalState.self, forKey: .approvalState),
            template: container.decodeIfPresent(CoordinatorMissionTemplateSummary.self, forKey: .template),
            shapeSummary: container.decodeIfPresent(CoordinatorMissionShapeSummary.self, forKey: .shapeSummary),
            policySnapshot: container.decodeIfPresent(CoordinatorMissionPolicySnapshot.self, forKey: .policySnapshot),
            autonomy: container.decodeIfPresent([String: CoordinatorMissionAutonomyMode].self, forKey: .autonomy)
                ?? CoordinatorMissionPolicySnapshot.defaultAutonomy,
            workstreams: container.decode([CoordinatorMissionWorkstreamSummary].self, forKey: .workstreams),
            nodes: container.decode([CoordinatorMissionPlanNode].self, forKey: .nodes),
            routingDecisions: container.decodeIfPresent([CoordinatorMissionRoutingDecision].self, forKey: .routingDecisions) ?? [],
            decisions: container.decodeIfPresent([CoordinatorMissionDecisionRecord].self, forKey: .decisions) ?? [],
            evidence: container.decodeIfPresent([CoordinatorMissionEvidenceRecord].self, forKey: .evidence) ?? [],
            events: container.decode([CoordinatorMissionPlanEvent].self, forKey: .events),
            updatedAt: container.decode(Date.self, forKey: .updatedAt)
        )
    }
}

extension CoordinatorMissionPlan {
    func resolvedAutonomy(for decisionClass: String) -> CoordinatorMissionAutonomyMode {
        CoordinatorMissionPolicySnapshot.resolveAutonomy(autonomy[decisionClass], for: decisionClass)
    }

    func resolvedAutonomy(for decisionClass: CoordinatorMissionDecisionClass) -> CoordinatorMissionAutonomyMode {
        resolvedAutonomy(for: decisionClass.rawValue)
    }
}

struct CoordinatorMissionShapeSummary: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var reason: String?
    var namedClose: String?

    init(
        id: String,
        displayName: String,
        reason: String? = nil,
        namedClose: String? = nil
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.namedClose = namedClose?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct CoordinatorMissionPolicySnapshot: Codable, Equatable, Identifiable {
    static let defaultMaxConcurrent = 3

    static let defaultAutonomy: [String: CoordinatorMissionAutonomyMode] = [
        CoordinatorMissionDecisionClass.plan.rawValue: .ask,
        CoordinatorMissionDecisionClass.advance.rawValue: .ask,
        CoordinatorMissionDecisionClass.writes.rawValue: .auto,
        CoordinatorMissionDecisionClass.childAsk.rawValue: .ask,
        CoordinatorMissionDecisionClass.recover.rawValue: .auto,
        CoordinatorMissionDecisionClass.irreversible.rawValue: .ask
    ]

    static let defaultPolicy = CoordinatorMissionPolicySnapshot(
        id: "default",
        name: "Default",
        defaultPace: .step,
        autonomy: defaultAutonomy,
        standingGuidance: "Keep every boundary visible while trust is earned."
    )

    static let handsOff = CoordinatorMissionPolicySnapshot(
        id: "hands-off",
        name: "Hands-off",
        defaultPace: .auto,
        autonomy: autonomy(asking: [.plan, .irreversible]),
        standingGuidance: "Approve the Mission once, then let the Director proceed when evidence clears the bar."
    )

    static let carefulWrites = CoordinatorMissionPolicySnapshot(
        id: "careful-writes",
        name: "Careful writes",
        defaultPace: .step,
        autonomy: autonomy(asking: [.plan, .advance, .writes, .childAsk, .irreversible]),
        standingGuidance: "Ask before crossing into mutable work."
    )

    static let readOnly = CoordinatorMissionPolicySnapshot(
        id: "read-only",
        name: "Read-only",
        defaultPace: .auto,
        autonomy: autonomy(asking: [.plan, .writes, .irreversible]),
        definitionOfDone: "A written report of the findings. No code changes.",
        standingGuidance: "Keep the Mission read-only and report findings clearly."
    )

    static let builtInPolicies: [CoordinatorMissionPolicySnapshot] = [
        .defaultPolicy,
        .handsOff,
        .carefulWrites,
        .readOnly
    ]

    var id: String
    var name: String
    var defaultPace: CoordinatorMissionPolicyPace
    var autonomy: [String: CoordinatorMissionAutonomyMode]
    var maxConcurrent: Int
    var definitionOfDone: String?
    var standingGuidance: String?
    var pinnedSkillIDs: [String]
    var pinnedContextIDs: [String]

    init(
        id: String,
        name: String,
        defaultPace: CoordinatorMissionPolicyPace,
        autonomy: [String: CoordinatorMissionAutonomyMode] = Self.defaultAutonomy,
        maxConcurrent: Int = Self.defaultMaxConcurrent,
        definitionOfDone: String? = nil,
        standingGuidance: String? = nil,
        pinnedSkillIDs: [String] = [],
        pinnedContextIDs: [String] = []
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultPace = defaultPace
        self.autonomy = autonomy
        self.maxConcurrent = max(1, maxConcurrent)
        self.definitionOfDone = definitionOfDone?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.standingGuidance = standingGuidance?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.pinnedSkillIDs = pinnedSkillIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.pinnedContextIDs = pinnedContextIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case defaultPace
        case autonomy
        case maxConcurrent
        case definitionOfDone
        case standingGuidance
        case pinnedSkillIDs
        case pinnedContextIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            defaultPace: container.decode(CoordinatorMissionPolicyPace.self, forKey: .defaultPace),
            autonomy: container.decodeIfPresent([String: CoordinatorMissionAutonomyMode].self, forKey: .autonomy) ?? Self.defaultAutonomy,
            maxConcurrent: container.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? Self.defaultMaxConcurrent,
            definitionOfDone: container.decodeIfPresent(String.self, forKey: .definitionOfDone),
            standingGuidance: container.decodeIfPresent(String.self, forKey: .standingGuidance),
            pinnedSkillIDs: container.decodeIfPresent([String].self, forKey: .pinnedSkillIDs) ?? [],
            pinnedContextIDs: container.decodeIfPresent([String].self, forKey: .pinnedContextIDs) ?? []
        )
    }

    func resolvedAutonomy(for decisionClass: String) -> CoordinatorMissionAutonomyMode {
        Self.resolveAutonomy(autonomy[decisionClass], for: decisionClass)
    }

    func resolvedAutonomy(for decisionClass: CoordinatorMissionDecisionClass) -> CoordinatorMissionAutonomyMode {
        resolvedAutonomy(for: decisionClass.rawValue)
    }

    static func resolveAutonomy(
        _ mode: CoordinatorMissionAutonomyMode?,
        for decisionClass: String
    ) -> CoordinatorMissionAutonomyMode {
        guard let knownClass = CoordinatorMissionDecisionClass(rawValue: decisionClass) else { return .ask }
        if knownClass == .irreversible { return .ask }
        return mode ?? defaultAutonomy[decisionClass] ?? .ask
    }

    private static func autonomy(
        asking askClasses: Set<CoordinatorMissionDecisionClass>
    ) -> [String: CoordinatorMissionAutonomyMode] {
        Dictionary(uniqueKeysWithValues: CoordinatorMissionDecisionClass.allCases.map { decisionClass in
            (decisionClass.rawValue, askClasses.contains(decisionClass) ? .ask : .auto)
        })
    }
}

enum CoordinatorMissionPolicyPace: String, Codable, Equatable, CaseIterable {
    case step
    case auto
}

enum CoordinatorMissionAutonomyMode: String, Codable, Equatable, CaseIterable {
    case ask
    case auto
}

enum CoordinatorMissionDecisionClass: String, Codable, Equatable, Hashable, CaseIterable {
    case plan
    case advance
    case writes
    case childAsk
    case recover
    case irreversible
}

struct CoordinatorMissionAutonomyClass: Equatable, Identifiable {
    var id: String {
        key
    }

    let key: String
    let displayName: String
    let description: String
    let defaultMode: CoordinatorMissionAutonomyMode
}

enum CoordinatorMissionAutonomyClasses {
    static let childAsk = CoordinatorMissionAutonomyClass(
        key: CoordinatorMissionDecisionClass.childAsk.rawValue,
        displayName: "Child questions",
        description: "Who answers delegated workers when they need direction.",
        defaultMode: CoordinatorMissionPolicySnapshot.defaultAutonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] ?? .ask
    )

    static let all: [CoordinatorMissionAutonomyClass] = [
        childAsk
    ]

    static func definition(for key: String) -> CoordinatorMissionAutonomyClass? {
        all.first { $0.key == key }
    }
}

enum CoordinatorMissionUserDecisionLabel: String, Codable, Equatable, CaseIterable {
    case approvedMissionPlan = "approved the Mission plan"
    case requestedPlanRevision = "requested plan revision"
    case stoppedMission = "stopped the Mission"
    case continuedPastStepCheckIn = "continued past a step check-in"
    case answeredChildQuestion = "answered a child question"
    case setPaceToAuto = "set pace to Auto"
    case setPaceToStep = "set pace to Step"
    case routedChildQuestionsToMe = "routed child questions to Me"
    case routedChildQuestionsToDirector = "routed child questions to the Director"
}

enum CoordinatorMissionDecisionActor: String, Codable, Equatable, CaseIterable {
    case user
    case director
}

struct CoordinatorMissionDecisionRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var decisionClass: String
    var actor: CoordinatorMissionDecisionActor
    var label: String
    var reason: String?
    var timestamp: Date
    var nodeID: UUID?
    var workstreamID: UUID?
    var sessionID: UUID?
    var interactionID: UUID?
    var checkpointID: String?
    var checkpointInstanceID: String?
    var overruledDecisionID: UUID?
    var overruleReason: String?
    var correctionReason: String?
    var correctionSteerText: String?

    init(
        id: UUID = UUID(),
        decisionClass: String,
        actor: CoordinatorMissionDecisionActor,
        label: String,
        reason: String? = nil,
        timestamp: Date = Date(),
        nodeID: UUID? = nil,
        workstreamID: UUID? = nil,
        sessionID: UUID? = nil,
        interactionID: UUID? = nil,
        checkpointID: String? = nil,
        checkpointInstanceID: String? = nil,
        overruledDecisionID: UUID? = nil,
        overruleReason: String? = nil,
        correctionReason: String? = nil,
        correctionSteerText: String? = nil
    ) {
        self.id = id
        self.decisionClass = decisionClass.trimmingCharacters(in: .whitespacesAndNewlines)
        self.actor = actor
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.timestamp = timestamp
        self.nodeID = nodeID
        self.workstreamID = workstreamID
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.checkpointID = checkpointID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.checkpointInstanceID = checkpointInstanceID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.overruledDecisionID = overruledDecisionID
        self.overruleReason = overruleReason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.correctionReason = correctionReason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.correctionSteerText = correctionSteerText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    init(
        userDecision label: CoordinatorMissionUserDecisionLabel,
        decisionClass: CoordinatorMissionDecisionClass,
        checkpointInstanceID: String,
        reason: String? = nil,
        timestamp: Date = Date(),
        nodeID: UUID? = nil,
        workstreamID: UUID? = nil,
        sessionID: UUID? = nil,
        interactionID: UUID? = nil,
        checkpointID: String? = nil
    ) {
        self.init(
            id: Self.deterministicUserDecisionID(
                checkpointInstanceID: checkpointInstanceID,
                label: label.rawValue
            ),
            decisionClass: decisionClass.rawValue,
            actor: .user,
            label: label.rawValue,
            reason: reason,
            timestamp: timestamp,
            nodeID: nodeID,
            workstreamID: workstreamID,
            sessionID: sessionID,
            interactionID: interactionID,
            checkpointID: checkpointID,
            checkpointInstanceID: checkpointInstanceID
        )
    }

    var resolvedAutonomyClass: CoordinatorMissionDecisionClass? {
        CoordinatorMissionDecisionClass(rawValue: decisionClass)
    }

    static func deterministicUserDecisionID(checkpointInstanceID: String, label: String) -> UUID {
        CoordinatorMissionStableIdentity.uuid(
            namespace: "coordinator-mission-user-decision",
            parts: [checkpointInstanceID, label]
        )
    }
}

enum CoordinatorMissionEvidenceVerdict: String, Codable, Equatable, CaseIterable {
    case meets
    case short
}

struct CoordinatorMissionEvidenceRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var verdict: CoordinatorMissionEvidenceVerdict
    var summary: String
    var timestamp: Date
    var nodeID: UUID?
    var workstreamID: UUID?
    var sessionID: UUID?
    var interactionID: UUID?
    var decisionID: UUID?
    var source: CoordinatorMissionEvidenceSource?
    var judgmentBundle: CoordinatorMissionJudgmentBundle?

    init(
        id: UUID = UUID(),
        verdict: CoordinatorMissionEvidenceVerdict,
        summary: String,
        timestamp: Date = Date(),
        nodeID: UUID? = nil,
        workstreamID: UUID? = nil,
        sessionID: UUID? = nil,
        interactionID: UUID? = nil,
        decisionID: UUID? = nil,
        source: CoordinatorMissionEvidenceSource? = nil,
        judgmentBundle: CoordinatorMissionJudgmentBundle? = nil
    ) {
        self.id = id
        self.verdict = verdict
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timestamp = timestamp
        self.nodeID = nodeID
        self.workstreamID = workstreamID
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.decisionID = decisionID
        self.source = source
        self.judgmentBundle = judgmentBundle
    }
}

struct CoordinatorMissionEvidenceSource: Codable, Equatable {
    var kind: String
    var operation: CoordinatorMissionRoutingOperation?
    var routingDecisionID: UUID?
    var nodeID: UUID?
    var sessionID: UUID?
    var interactionID: UUID?
    var answerID: String?
    var summary: String?

    init(
        kind: String,
        operation: CoordinatorMissionRoutingOperation? = nil,
        routingDecisionID: UUID? = nil,
        nodeID: UUID? = nil,
        sessionID: UUID? = nil,
        interactionID: UUID? = nil,
        answerID: String? = nil,
        summary: String? = nil
    ) {
        self.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.operation = operation
        self.routingDecisionID = routingDecisionID
        self.nodeID = nodeID
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.answerID = answerID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct CoordinatorMissionJudgmentBundle: Codable, Equatable {
    static let notTranscriptFraming = "not_transcript_summary"

    var doneCriteria: String?
    var structuredEvidence: String?
    var diffStats: CoordinatorMissionDiffStats?
    var probeAnswer: CoordinatorMissionProbeAnswerSummary?
    var transcriptFraming: String

    init(
        doneCriteria: String? = nil,
        structuredEvidence: String? = nil,
        diffStats: CoordinatorMissionDiffStats? = nil,
        probeAnswer: CoordinatorMissionProbeAnswerSummary? = nil,
        transcriptFraming: String = Self.notTranscriptFraming
    ) {
        self.doneCriteria = doneCriteria?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.structuredEvidence = structuredEvidence?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.diffStats = diffStats
        self.probeAnswer = probeAnswer
        self.transcriptFraming = transcriptFraming.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Self.notTranscriptFraming
    }

    private enum CodingKeys: String, CodingKey {
        case doneCriteria
        case structuredEvidence
        case diffStats
        case probeAnswer
        case transcriptFraming
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            doneCriteria: container.decodeIfPresent(String.self, forKey: .doneCriteria),
            structuredEvidence: container.decodeIfPresent(String.self, forKey: .structuredEvidence),
            diffStats: container.decodeIfPresent(CoordinatorMissionDiffStats.self, forKey: .diffStats),
            probeAnswer: container.decodeIfPresent(CoordinatorMissionProbeAnswerSummary.self, forKey: .probeAnswer),
            transcriptFraming: container.decodeIfPresent(String.self, forKey: .transcriptFraming) ?? Self.notTranscriptFraming
        )
    }
}

struct CoordinatorMissionDiffStats: Codable, Equatable {
    var filesChanged: Int?
    var insertions: Int?
    var deletions: Int?
    var summary: String?

    init(
        filesChanged: Int? = nil,
        insertions: Int? = nil,
        deletions: Int? = nil,
        summary: String? = nil
    ) {
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
        self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct CoordinatorMissionProbeAnswerSummary: Codable, Equatable {
    var answerID: String?
    var source: String?
    var answer: String?
    var sessionID: UUID?
    var interactionID: UUID?
    var routingDecisionID: UUID?

    init(
        answerID: String? = nil,
        source: String? = nil,
        answer: String? = nil,
        sessionID: UUID? = nil,
        interactionID: UUID? = nil,
        routingDecisionID: UUID? = nil
    ) {
        self.answerID = answerID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.source = source?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.routingDecisionID = routingDecisionID
    }
}

enum CoordinatorMissionStableIdentity {
    static func uuid(namespace: String, parts: [String]) -> UUID {
        let payload = ([namespace] + parts).joined(separator: "\u{1F}")
        var bytes = bytes(from: fnv1a64(payload)) + bytes(from: fnv1a64("uuid-v2\u{1F}\(payload)"))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func bytes(from value: UInt64) -> [UInt8] {
        (0 ..< 8).map { shift in
            UInt8((value >> UInt64((7 - shift) * 8)) & 0xFF)
        }
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
    var baseRef: String?
    var baseReason: String?
    var reason: String?

    init(
        mode: CoordinatorMissionWorktreeMode,
        worktreeID: String? = nil,
        baseRef: String? = nil,
        baseReason: String? = nil,
        reason: String? = nil
    ) {
        self.mode = mode
        self.worktreeID = worktreeID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.baseRef = baseRef?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.baseReason = baseReason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
    var workflowHint: CoordinatorMissionPlanNodeWorkflowHint?
    var completionEvidence: String?
    var doneCriteria: String?
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
        workflowHint: CoordinatorMissionPlanNodeWorkflowHint? = nil,
        completionEvidence: String? = nil,
        doneCriteria: String? = nil,
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
        self.workflowHint = workflowHint
        self.completionEvidence = completionEvidence?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.doneCriteria = doneCriteria?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.workstreamID = workstreamID
        self.dependsOn = dependsOn
        self.role = role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.executionPolicy = executionPolicy
        self.status = status
        self.boundSessionID = boundSessionID
        self.boundInteractionID = boundInteractionID
    }

    fileprivate func reusingStableID(_ stableID: UUID) -> CoordinatorMissionPlanNode {
        CoordinatorMissionPlanNode(
            id: stableID,
            title: title,
            detail: detail,
            workflowHint: workflowHint,
            completionEvidence: completionEvidence,
            doneCriteria: doneCriteria,
            workstreamID: workstreamID,
            dependsOn: dependsOn,
            role: role,
            executionPolicy: executionPolicy,
            status: status,
            boundSessionID: boundSessionID,
            boundInteractionID: boundInteractionID
        )
    }
}

struct CoordinatorMissionPlanNodeWorkflowHint: Codable, Equatable {
    var id: String?
    var name: String
    var iconName: String?
    var accentColorHex: String?

    init(
        id: String? = nil,
        name: String,
        iconName: String? = nil,
        accentColorHex: String? = nil
    ) {
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.iconName = iconName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.accentColorHex = accentColorHex?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct CoordinatorMissionRoutingDecision: Codable, Equatable, Identifiable {
    let id: UUID
    var timestamp: Date
    var nodeID: UUID?
    var workstreamID: UUID?
    var decision: CoordinatorMissionRoutingDecisionKind
    var operation: CoordinatorMissionRoutingOperation
    var sessionID: UUID?
    var priorSessionID: UUID?
    var worktreeID: String?
    var workflowName: String?
    var modelID: String?
    var role: String?
    var reason: String
    var contextSummary: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        nodeID: UUID? = nil,
        workstreamID: UUID? = nil,
        decision: CoordinatorMissionRoutingDecisionKind,
        operation: CoordinatorMissionRoutingOperation,
        sessionID: UUID? = nil,
        priorSessionID: UUID? = nil,
        worktreeID: String? = nil,
        workflowName: String? = nil,
        modelID: String? = nil,
        role: String? = nil,
        reason: String,
        contextSummary: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.nodeID = nodeID
        self.workstreamID = workstreamID
        self.decision = decision
        self.operation = operation
        self.sessionID = sessionID
        self.priorSessionID = priorSessionID
        self.worktreeID = worktreeID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.workflowName = workflowName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.role = role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contextSummary = contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

enum CoordinatorMissionRoutingDecisionKind: String, Codable, Equatable, CaseIterable {
    case startFreshReadOnlyChild = "start_fresh_readonly_child"
    case startFreshWorktree = "start_fresh_worktree"
    case steerPrimary = "steer_primary"
    case startFreshSiblingOnSameWorktree = "start_fresh_sibling_on_same_worktree"
    case respondToInteraction = "respond_to_interaction"
    case holdForUser = "hold_for_user"
    case cancelOrReplace = "cancel_or_replace"

    var displayName: String {
        switch self {
        case .startFreshReadOnlyChild: "Start read-only child"
        case .startFreshWorktree: "Start fresh worktree"
        case .steerPrimary: "Steer primary"
        case .startFreshSiblingOnSameWorktree: "Start sibling review"
        case .respondToInteraction: "Respond to checkpoint"
        case .holdForUser: "Hold for user"
        case .cancelOrReplace: "Cancel or replace"
        }
    }
}

enum CoordinatorMissionRoutingOperation: String, Codable, Equatable, CaseIterable {
    case agentExploreStart = "agent_explore.start"
    case agentRunStart = "agent_run.start"
    case agentRunSteer = "agent_run.steer"
    case agentRunRespond = "agent_run.respond"
    case agentRunCancel = "agent_run.cancel"
    case coordinatorHold = "coordinator_hold"
    case coordinatorPublish = "coordinator_publish"

    var displayName: String {
        switch self {
        case .agentExploreStart: "agent_explore.start"
        case .agentRunStart: "agent_run.start"
        case .agentRunSteer: "agent_run.steer"
        case .agentRunRespond: "agent_run.respond"
        case .agentRunCancel: "agent_run.cancel"
        case .coordinatorHold: "Coordinator hold"
        case .coordinatorPublish: "Coordinator publish"
        }
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
    case freshReadOnlyChild = "fresh_readonly_child"
    case steerPrimary = "steer_primary"
    case freshSiblingOnSameWorktree = "fresh_sibling_on_same_worktree"
    case freshWorktree = "fresh_worktree"
    case planCritique = "plan_critique"
    case askUser = "ask_user"

    var displayName: String {
        switch self {
        case .coordinatorOnly: "Coordinator only"
        case .freshReadOnlyChild: "Read-only child"
        case .steerPrimary: "Steer primary"
        case .freshSiblingOnSameWorktree: "Sibling on same worktree"
        case .freshWorktree: "Fresh worktree"
        case .planCritique: "Plan critique"
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
            "If this event completed or unblocked Mission work, consult `coordinator_chat op=mission_status` with `compact:true`: any pending node whose dependencies are now all completed is eligible. Launch eligible nodes per their execution policies and the Mission policy `max_concurrent` cap, in parallel where worktree strategies permit. Never start a node that is already running or has a bound session.",
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
