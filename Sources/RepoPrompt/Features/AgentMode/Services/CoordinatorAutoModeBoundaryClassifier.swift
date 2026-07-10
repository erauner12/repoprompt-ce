import Foundation

struct CoordinatorAutoModeBoundaryClassifier {
    enum Trigger: Equatable {
        case lifecycle
        case gateCleared(CoordinatorContinuationGate)
    }

    enum Decision: Equatable {
        case resume(CoordinatorFollowThroughEvent)
        case hold(HoldReason)
    }

    enum HoldReason: Equatable {
        case autoModeDisabled
        case missingCoordinator
        case missingObjective
        case coordinatorActive
        case childNeedsUser(UUID)
        case childBlocked(UUID)
        case duplicateEvent(String)
        case noResumableEvent
    }

    struct Input {
        var autoModeEnabled: Bool
        var coordinatorSessionID: UUID?
        var coordinatorRunState: AgentSessionRunState?
        var rows: [CoordinatorModeRow]
        var state: CoordinatorFollowThroughState
        var trigger: Trigger
    }

    func classify(_ input: Input) -> Decision {
        guard input.autoModeEnabled else { return .hold(.autoModeDisabled) }
        guard let coordinatorSessionID = input.coordinatorSessionID else { return .hold(.missingCoordinator) }
        guard input.state.originalObjectiveSummary?.isEmpty == false else { return .hold(.missingObjective) }
        if isCoordinatorBusy(input.coordinatorRunState) {
            return .hold(.coordinatorActive)
        }

        let ownedRows = input.rows.filter { isOwnedByCoordinator($0, coordinatorSessionID: coordinatorSessionID) }
        let childAskAuto = input.state.missionPlan?.resolvedAutonomy(for: .childAsk) == .auto
        if childAskAuto,
           let pendingQuestion = ownedRows.first(where: isWaitingForChildQuestion)
        {
            return childQuestionDecision(
                coordinatorSessionID: coordinatorSessionID,
                row: pendingQuestion,
                state: input.state
            )
        }
        if let needsUser = ownedRows.first(where: { phase(for: $0) == .needsUser }) {
            if childAskAuto, isWaitingForChildQuestion(needsUser) {
                return childQuestionDecision(
                    coordinatorSessionID: coordinatorSessionID,
                    row: needsUser,
                    state: input.state
                )
            }
            return .hold(.childNeedsUser(needsUser.sessionID))
        }
        if let blocked = ownedRows.first(where: { phase(for: $0) == .blocked }) {
            return .hold(.childBlocked(blocked.sessionID))
        }

        switch input.trigger {
        case .lifecycle:
            return lifecycleDecision(
                coordinatorSessionID: coordinatorSessionID,
                rows: ownedRows,
                state: input.state
            )
        case let .gateCleared(gate):
            return gateClearedDecision(
                coordinatorSessionID: coordinatorSessionID,
                gate: gate,
                rows: ownedRows,
                state: input.state
            )
        }
    }

    private func lifecycleDecision(
        coordinatorSessionID: UUID,
        rows: [CoordinatorModeRow],
        state: CoordinatorFollowThroughState
    ) -> Decision {
        if let completed = rows.first(where: { row in
            phase(for: row) == .done
                && (state.observedChildPhases[row.sessionID].map { $0 != .done } ?? true)
        }) {
            let phase = phase(for: completed)
            let event = CoordinatorFollowThroughEvent(
                id: "child:\(completed.sessionID.uuidString):terminal:\(completed.runState.rawValue)",
                kind: .childTerminal,
                coordinatorSessionID: coordinatorSessionID,
                childSessionID: completed.sessionID,
                childTitle: completed.title,
                gate: nil,
                phase: phase,
                detail: "Delegated child reached terminal state \(completed.runState.rawValue)."
            )
            return deduped(event, state: state)
        }

        if let reviewable = rows.first(where: { row in
            phase(for: row) == .review
                && (state.observedChildPhases[row.sessionID].map { $0 != .review } ?? true)
        }) {
            let event = CoordinatorFollowThroughEvent(
                id: "child:\(reviewable.sessionID.uuidString):review:\(reviewable.mergeAttention?.id ?? reviewable.sessionID.uuidString)",
                kind: .childTerminal,
                coordinatorSessionID: coordinatorSessionID,
                childSessionID: reviewable.sessionID,
                childTitle: reviewable.title,
                gate: nil,
                phase: .review,
                detail: "Delegated child produced reviewable output."
            )
            return deduped(event, state: state)
        }

        if let event = eligibleWorkEvent(coordinatorSessionID: coordinatorSessionID, state: state) {
            return deduped(event, state: state)
        }

        return .hold(.noResumableEvent)
    }

    private func eligibleWorkEvent(
        coordinatorSessionID: UUID,
        state: CoordinatorFollowThroughState
    ) -> CoordinatorFollowThroughEvent? {
        guard let plan = state.missionPlan,
              plan.approvalState == .approved,
              plan.status == .approved || plan.status == .running
        else { return nil }

        let nodesByID = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0) })
        let readyNodes = plan.nodes.filter { node in
            node.status == .pending
                && node.dependsOn.allSatisfy { nodesByID[$0]?.status == .completed }
        }
        guard !readyNodes.isEmpty else { return nil }

        let runningCapacityCount = plan.nodes.count { node in
            node.status == .running && usesStartCapacity(node.executionPolicy)
        }
        let maxConcurrent = plan.policySnapshot?.maxConcurrent ?? CoordinatorMissionPolicySnapshot.defaultMaxConcurrent
        let hasLaunchableReadyNode = readyNodes.contains { node in
            !usesStartCapacity(node.executionPolicy) || runningCapacityCount < maxConcurrent
        }
        guard hasLaunchableReadyNode else { return nil }

        let readyIDs = readyNodes
            .map(\.id.uuidString)
            .sorted()
        let readyTitles = readyNodes
            .map(\.title)
            .sorted()
            .prefix(3)
            .joined(separator: ", ")
        let suffix = readyNodes.count > 3 ? " (+\(readyNodes.count - 3) more)" : ""
        return CoordinatorFollowThroughEvent(
            id: "mission:\(coordinatorSessionID.uuidString):eligible:r\(plan.revision):\(readyIDs.joined(separator: ","))",
            kind: .eligibleWork,
            coordinatorSessionID: coordinatorSessionID,
            childSessionID: nil,
            childTitle: nil,
            gate: nil,
            phase: nil,
            detail: "Mission has \(readyNodes.count) eligible ready node\(readyNodes.count == 1 ? "" : "s") with capacity available: \(readyTitles)\(suffix)."
        )
    }

    private func childQuestionDecision(
        coordinatorSessionID: UUID,
        row: CoordinatorModeRow,
        state: CoordinatorFollowThroughState
    ) -> Decision {
        let fallbackInteractionID = "\(row.runState.rawValue):\(Int(row.updatedAt.timeIntervalSince1970 * 1000))"
        let interactionID = row.pendingInteraction?.id.uuidString ?? fallbackInteractionID
        let event = CoordinatorFollowThroughEvent(
            id: "child:\(row.sessionID.uuidString):question:\(interactionID)",
            kind: .childQuestion,
            coordinatorSessionID: coordinatorSessionID,
            childSessionID: row.sessionID,
            childTitle: row.title,
            gate: nil,
            phase: .needsUser,
            detail: "Delegated child is asking for direction and Mission Policy routes child questions to Director."
        )
        return deduped(event, state: state)
    }

    private func gateClearedDecision(
        coordinatorSessionID: UUID,
        gate: CoordinatorContinuationGate,
        rows: [CoordinatorModeRow],
        state: CoordinatorFollowThroughState
    ) -> Decision {
        if let ownerID = gate.ownerCoordinatorSessionID,
           ownerID != coordinatorSessionID
        {
            return .hold(.noResumableEvent)
        }

        let row = rows.first {
            $0.sessionID.uuidString == gate.subjectID || $0.mergeAttention?.id == gate.subjectID
        }
        let event = CoordinatorFollowThroughEvent(
            id: "gate:\(gate.id):cleared",
            kind: .gateCleared,
            coordinatorSessionID: coordinatorSessionID,
            childSessionID: row?.sessionID,
            childTitle: row?.title,
            gate: gate,
            phase: row.map(phase(for:)),
            detail: "Continuation gate was cleared."
        )
        return deduped(event, state: state)
    }

    private func deduped(
        _ event: CoordinatorFollowThroughEvent,
        state: CoordinatorFollowThroughState
    ) -> Decision {
        if state.handledEventIDs.contains(event.id) || state.pendingEvents.contains(where: { $0.id == event.id }) {
            return .hold(.duplicateEvent(event.id))
        }
        return .resume(event)
    }

    private func isOwnedByCoordinator(_ row: CoordinatorModeRow, coordinatorSessionID: UUID) -> Bool {
        row.workstreamSummary?.coordinatorSessionID == coordinatorSessionID
            || row.parentCoordinator?.sessionID == coordinatorSessionID
    }

    private func isWaitingForChildQuestion(_ row: CoordinatorModeRow) -> Bool {
        row.runState == .waitingForQuestion || row.pendingInteraction?.kind == .question
    }

    private func isCoordinatorBusy(_ runState: AgentSessionRunState?) -> Bool {
        switch runState {
        case .running, .waitingForUser, .waitingForApproval:
            true
        case .idle, .waitingForQuestion, .completed, .cancelled, .failed, nil:
            false
        }
    }

    private func phase(for row: CoordinatorModeRow) -> CoordinatorFollowThroughChildPhase {
        CoordinatorFollowThroughChildPhase(row: row)
    }

    private func usesStartCapacity(_ policy: CoordinatorMissionExecutionPolicy) -> Bool {
        switch policy {
        case .freshReadOnlyChild, .freshWorktree, .freshSiblingOnSameWorktree, .planCritique:
            true
        case .coordinatorOnly, .steerPrimary, .askUser:
            false
        }
    }
}
