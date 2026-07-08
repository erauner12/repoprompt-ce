import Foundation

@MainActor
final class CoordinatorMissionEventJournal {
    struct Batch: Equatable {
        let events: [Entry]
        let nextSeq: Int
        let oldestSeq: Int?
        let latestSeq: Int?
        let truncated: Bool
    }

    struct Entry: Equatable {
        let seq: Int
        let observedAt: Date
        let coordinatorSessionID: UUID
        let fingerprint: String
        let title: String
        let selected: Bool
        let runState: String?
        let hasPlan: Bool
        let plan: PlanSummary?
        let nodeCounts: [String: Int]
        let readyNodeIDs: [UUID]
        let activeNodeIDs: [UUID]
        let nodes: [NodeSummary]
        let recentEventIDs: [UUID]
        let routingDecisionIDs: [UUID]
        let decisionIDs: [UUID]
        let evidenceIDs: [UUID]
        let livenessWarnings: [String]
    }

    struct PlanSummary: Equatable {
        let revision: Int
        let missionKey: String?
        let status: String
        let approvalState: String
        let terminalNodeCount: Int
        let nodeCount: Int
    }

    struct NodeSummary: Equatable {
        let id: UUID
        let title: String
        let status: String
        let executionPolicy: String
        let workstreamID: UUID
        let dependsOn: [UUID]
        let depsSatisfied: Bool
        let boundSessionID: UUID?
        let boundInteractionID: UUID?
    }

    static let shared = CoordinatorMissionEventJournal()

    private let capacity: Int
    private var entriesByMissionID: [UUID: [Entry]] = [:]
    private var nextSequenceByMissionID: [UUID: Int] = [:]
    private var lastFingerprintByMissionID: [UUID: String] = [:]

    init(capacity: Int = 512) {
        self.capacity = max(8, capacity)
    }

    func record(snapshot: CoordinatorModeSnapshot, observedAt: Date = Date()) {
        let rows = snapshot.groups.flatMap(\.rows)
        for option in snapshot.coordinatorRail.availableCoordinators {
            let candidate = makeCandidate(
                option: option,
                snapshot: snapshot,
                rows: rows,
                observedAt: observedAt
            )
            guard lastFingerprintByMissionID[option.sessionID] != candidate.fingerprint else {
                continue
            }

            var missionEntries = entriesByMissionID[option.sessionID] ?? []
            if let interlude = readyInterlude(previous: missionEntries.last, candidate: candidate) {
                let interludeSeq = nextSequence(for: option.sessionID)
                missionEntries.append(entry(interlude, seq: interludeSeq))
            }

            let nextSeq = nextSequence(for: option.sessionID)
            lastFingerprintByMissionID[option.sessionID] = candidate.fingerprint
            let entry = entry(candidate, seq: nextSeq)

            missionEntries.append(entry)
            if missionEntries.count > capacity {
                missionEntries.removeFirst(missionEntries.count - capacity)
            }
            entriesByMissionID[option.sessionID] = missionEntries
        }
    }

    func events(for coordinatorSessionID: UUID, sinceSeq: Int = 0, limit: Int = 200) -> Batch {
        let boundedSinceSeq = max(0, sinceSeq)
        let boundedLimit = max(1, min(limit, capacity))
        let entries = entriesByMissionID[coordinatorSessionID] ?? []
        let filtered = entries.filter { $0.seq > boundedSinceSeq }
        let limited = Array(filtered.prefix(boundedLimit))
        return Batch(
            events: limited,
            nextSeq: entries.last?.seq ?? boundedSinceSeq,
            oldestSeq: entries.first?.seq,
            latestSeq: entries.last?.seq,
            truncated: filtered.count > limited.count
        )
    }

    func reset() {
        entriesByMissionID.removeAll()
        nextSequenceByMissionID.removeAll()
        lastFingerprintByMissionID.removeAll()
    }

    private func nextSequence(for coordinatorSessionID: UUID) -> Int {
        let nextSeq = (nextSequenceByMissionID[coordinatorSessionID] ?? 0) + 1
        nextSequenceByMissionID[coordinatorSessionID] = nextSeq
        return nextSeq
    }

    private func entry(_ source: Entry, seq: Int) -> Entry {
        Entry(
            seq: seq,
            observedAt: source.observedAt,
            coordinatorSessionID: source.coordinatorSessionID,
            fingerprint: source.fingerprint,
            title: source.title,
            selected: source.selected,
            runState: source.runState,
            hasPlan: source.hasPlan,
            plan: source.plan,
            nodeCounts: source.nodeCounts,
            readyNodeIDs: source.readyNodeIDs,
            activeNodeIDs: source.activeNodeIDs,
            nodes: source.nodes,
            recentEventIDs: source.recentEventIDs,
            routingDecisionIDs: source.routingDecisionIDs,
            decisionIDs: source.decisionIDs,
            evidenceIDs: source.evidenceIDs,
            livenessWarnings: source.livenessWarnings
        )
    }

    private func readyInterlude(previous: Entry?, candidate: Entry) -> Entry? {
        guard let previous, candidate.hasPlan else { return nil }
        let previousNodesByID = Dictionary(uniqueKeysWithValues: previous.nodes.map { ($0.id, $0) })
        let missingReadyIDs = candidate.nodes.compactMap { node -> UUID? in
            guard node.status == "running" || node.status == "completed",
                  node.depsSatisfied,
                  !node.dependsOn.isEmpty,
                  !candidate.readyNodeIDs.contains(node.id),
                  !previous.readyNodeIDs.contains(node.id),
                  let previousNode = previousNodesByID[node.id],
                  previousNode.status == "pending",
                  previousNode.depsSatisfied == false
            else { return nil }
            return node.id
        }
        guard !missingReadyIDs.isEmpty else { return nil }

        let missingReadyIDSet = Set(missingReadyIDs)
        let interludeNodes = candidate.nodes.map { node in
            guard missingReadyIDSet.contains(node.id) else { return node }
            return NodeSummary(
                id: node.id,
                title: node.title,
                status: "pending",
                executionPolicy: node.executionPolicy,
                workstreamID: node.workstreamID,
                dependsOn: node.dependsOn,
                depsSatisfied: true,
                boundSessionID: nil,
                boundInteractionID: nil
            )
        }
        let readyIDSet = Set(previous.readyNodeIDs).union(missingReadyIDSet)
        let readyNodeIDs = candidate.nodes.compactMap { readyIDSet.contains($0.id) ? $0.id : nil }
        let activeNodeIDs = candidate.activeNodeIDs.filter { !missingReadyIDSet.contains($0) }
        let nodeCounts = Dictionary(grouping: interludeNodes, by: { $0.status }).mapValues(\.count)
        let fingerprint = stableFingerprint([
            "coordinator",
            candidate.coordinatorSessionID.uuidString,
            "ready-interlude",
            previous.fingerprint,
            candidate.fingerprint,
            missingReadyIDs.map(\.uuidString).joined(separator: ",")
        ])

        return Entry(
            seq: 0,
            observedAt: candidate.observedAt,
            coordinatorSessionID: candidate.coordinatorSessionID,
            fingerprint: fingerprint,
            title: candidate.title,
            selected: candidate.selected,
            runState: candidate.runState,
            hasPlan: candidate.hasPlan,
            plan: candidate.plan,
            nodeCounts: nodeCounts,
            readyNodeIDs: readyNodeIDs,
            activeNodeIDs: activeNodeIDs,
            nodes: interludeNodes,
            recentEventIDs: candidate.recentEventIDs,
            routingDecisionIDs: candidate.routingDecisionIDs,
            decisionIDs: candidate.decisionIDs,
            evidenceIDs: candidate.evidenceIDs,
            livenessWarnings: candidate.livenessWarnings
        )
    }

    private func makeCandidate(
        option: CoordinatorModeCoordinatorOption,
        snapshot: CoordinatorModeSnapshot,
        rows: [CoordinatorModeRow],
        observedAt: Date
    ) -> Entry {
        guard let plan = option.missionPlan else {
            let fingerprint = stableFingerprint([
                "coordinator",
                option.sessionID.uuidString,
                option.runState?.rawValue ?? "run_state:nil",
                option.isSelected ? "selected:true" : "selected:false",
                "has_plan:false",
                option.title
            ])
            return Entry(
                seq: 0,
                observedAt: observedAt,
                coordinatorSessionID: option.sessionID,
                fingerprint: fingerprint,
                title: option.title,
                selected: option.isSelected,
                runState: option.runState?.rawValue,
                hasPlan: false,
                plan: nil,
                nodeCounts: [:],
                readyNodeIDs: [],
                activeNodeIDs: [],
                nodes: [],
                recentEventIDs: [],
                routingDecisionIDs: [],
                decisionIDs: [],
                evidenceIDs: [],
                livenessWarnings: []
            )
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0) })
        let depsSatisfiedByNodeID = Dictionary(uniqueKeysWithValues: plan.nodes.map { node in
            (node.id, node.dependsOn.allSatisfy { nodesByID[$0]?.status == .completed })
        })
        let nodeCounts = Dictionary(grouping: plan.nodes, by: { $0.status.rawValue }).mapValues(\.count)
        let readyNodeIDs = plan.nodes.compactMap { node -> UUID? in
            guard node.status == .pending, depsSatisfiedByNodeID[node.id] == true else { return nil }
            return node.id
        }
        let activeNodeIDs = plan.nodes.compactMap { node -> UUID? in
            switch node.status {
            case .running, .blocked:
                node.id
            case .pending, .completed, .skipped, .cancelled:
                nil
            }
        }
        let nodeSummaries = plan.nodes.map { node in
            NodeSummary(
                id: node.id,
                title: node.title,
                status: node.status.rawValue,
                executionPolicy: node.executionPolicy.rawValue,
                workstreamID: node.workstreamID,
                dependsOn: node.dependsOn,
                depsSatisfied: depsSatisfiedByNodeID[node.id] == true,
                boundSessionID: node.boundSessionID,
                boundInteractionID: node.boundInteractionID
            )
        }
        let recentEventIDs = plan.events
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(10)
            .map(\.id)
        let routingDecisionIDs = plan.routingDecisions
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(10)
            .map(\.id)
        let decisionIDs = plan.decisions
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(10)
            .map(\.id)
        let evidenceIDs = plan.evidence
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(10)
            .map(\.id)
        let boundSessionIDs = Set(plan.nodes.compactMap(\.boundSessionID))
        let descendantRows = rows.filter { row in
            let belongsByCoordinator = row.parentCoordinator?.sessionID == option.sessionID
            let belongsByParent = row.parentSessionID == option.sessionID
            let belongsByBoundNode = boundSessionIDs.contains(row.sessionID)
            return belongsByCoordinator || belongsByParent || belongsByBoundNode
        }
        var fingerprintParts: [String] = []
        fingerprintParts.append("coordinator")
        fingerprintParts.append(option.sessionID.uuidString)
        fingerprintParts.append(option.runState?.rawValue ?? "run_state:nil")
        fingerprintParts.append(option.isSelected ? "selected:true" : "selected:false")
        fingerprintParts.append("plan")
        fingerprintParts.append(String(plan.revision))
        fingerprintParts.append(plan.status.rawValue)
        fingerprintParts.append(plan.approvalState.rawValue)
        fingerprintParts.append(String(plan.nodes.count))
        fingerprintParts.append(String(plan.workstreams.count))
        fingerprintParts.append(String(plan.decisions.count))
        fingerprintParts.append(String(plan.evidence.count))
        fingerprintParts.append("ready")
        fingerprintParts.append(readyNodeIDs.map(\.uuidString).joined(separator: ","))
        fingerprintParts.append("active")
        fingerprintParts.append(activeNodeIDs.map(\.uuidString).joined(separator: ","))
        for node in nodeSummaries {
            fingerprintParts.append(contentsOf: [
                "node",
                node.id.uuidString,
                node.status,
                node.executionPolicy,
                node.depsSatisfied ? "deps:true" : "deps:false",
                node.dependsOn.map(\.uuidString).joined(separator: ","),
                node.boundSessionID?.uuidString ?? "bound:nil",
                node.boundInteractionID?.uuidString ?? "interaction:nil"
            ])
        }
        for row in descendantRows {
            fingerprintParts.append(contentsOf: [
                "row",
                row.sessionID.uuidString,
                row.runState.rawValue,
                row.statusGroup.rawValue,
                row.pendingInteraction?.id.uuidString ?? "pending_interaction:nil"
            ])
        }
        let fingerprint = stableFingerprint(fingerprintParts)

        return Entry(
            seq: 0,
            observedAt: observedAt,
            coordinatorSessionID: option.sessionID,
            fingerprint: fingerprint,
            title: option.title,
            selected: option.isSelected,
            runState: option.runState?.rawValue,
            hasPlan: true,
            plan: PlanSummary(
                revision: plan.revision,
                missionKey: plan.missionKey,
                status: plan.status.rawValue,
                approvalState: plan.approvalState.rawValue,
                terminalNodeCount: plan.nodes.count { $0.status.isTerminal },
                nodeCount: plan.nodes.count
            ),
            nodeCounts: nodeCounts,
            readyNodeIDs: readyNodeIDs,
            activeNodeIDs: activeNodeIDs,
            nodes: nodeSummaries,
            recentEventIDs: recentEventIDs,
            routingDecisionIDs: routingDecisionIDs,
            decisionIDs: decisionIDs,
            evidenceIDs: evidenceIDs,
            livenessWarnings: []
        )
    }

    private func stableFingerprint(_ parts: [String]) -> String {
        let joined = parts.joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
