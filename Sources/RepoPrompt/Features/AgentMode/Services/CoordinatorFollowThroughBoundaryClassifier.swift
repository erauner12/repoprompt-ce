import Foundation

struct CoordinatorFollowThroughBoundaryClassifier {
    enum Trigger: Equatable {
        case lifecycle
        case gateCleared(CoordinatorContinuationGate)
    }

    enum Decision: Equatable {
        case resume(CoordinatorFollowThroughEvent)
        case hold(HoldReason)
    }

    enum HoldReason: Equatable {
        case followThroughDisabled
        case missingCoordinator
        case missingObjective
        case coordinatorActive
        case childNeedsUser(UUID)
        case childBlocked(UUID)
        case requiredReviewUncleared(UUID)
        case duplicateEvent(String)
        case noResumableEvent
    }

    struct Input {
        var followThroughEnabled: Bool
        var coordinatorSessionID: UUID?
        var coordinatorRunState: AgentSessionRunState?
        var rows: [CoordinatorModeRow]
        var state: CoordinatorFollowThroughState
        var trigger: Trigger
    }

    func classify(_ input: Input) -> Decision {
        guard input.followThroughEnabled else { return .hold(.followThroughDisabled) }
        guard let coordinatorSessionID = input.coordinatorSessionID else { return .hold(.missingCoordinator) }
        guard input.state.originalObjectiveSummary?.isEmpty == false else { return .hold(.missingObjective) }
        if input.coordinatorRunState?.isActive == true {
            return .hold(.coordinatorActive)
        }

        let ownedRows = input.rows.filter { $0.parentCoordinator?.sessionID == coordinatorSessionID }
        if let needsUser = ownedRows.first(where: { $0.statusGroup == .needsYou }) {
            return .hold(.childNeedsUser(needsUser.sessionID))
        }
        if let blocked = ownedRows.first(where: { $0.statusGroup == .blocked }) {
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
        if let requiredReview = rows.first(where: { $0.statusGroup == .review && $0.pendingHumanReviewID != nil }) {
            return .hold(.requiredReviewUncleared(requiredReview.sessionID))
        }

        if let advisory = rows.first(where: { row in
            row.statusGroup == .done
                && row.mergeAttention != nil
                && state.observedChildPhases[row.sessionID] == .review
        }) {
            let event = CoordinatorFollowThroughEvent(
                id: "review:\(advisory.mergeAttention?.id ?? advisory.sessionID.uuidString):advisory",
                kind: .advisoryReview,
                coordinatorSessionID: coordinatorSessionID,
                childSessionID: advisory.sessionID,
                childTitle: advisory.title,
                reviewID: advisory.mergeAttention?.id,
                gate: nil,
                phase: .done,
                detail: "Advisory review packet is available without a hard human-review gate."
            )
            return deduped(event, state: state)
        }

        if let completed = rows.first(where: { row in
            row.statusGroup == .done
                && (state.observedChildPhases[row.sessionID].map { $0 != .done } ?? true)
        }) {
            let phase = CoordinatorFollowThroughChildPhase(statusGroup: completed.statusGroup)
            let event = CoordinatorFollowThroughEvent(
                id: "child:\(completed.sessionID.uuidString):terminal:\(completed.runState.rawValue)",
                kind: .childTerminal,
                coordinatorSessionID: coordinatorSessionID,
                childSessionID: completed.sessionID,
                childTitle: completed.title,
                reviewID: nil,
                gate: nil,
                phase: phase,
                detail: "Delegated child reached terminal state \(completed.runState.rawValue)."
            )
            return deduped(event, state: state)
        }

        return .hold(.noResumableEvent)
    }

    private func gateClearedDecision(
        coordinatorSessionID: UUID,
        gate: CoordinatorContinuationGate,
        rows: [CoordinatorModeRow],
        state: CoordinatorFollowThroughState
    ) -> Decision {
        let row = rows.first {
            $0.pendingHumanReviewID == gate.subjectID || $0.mergeAttention?.id == gate.subjectID
        }
        let event = CoordinatorFollowThroughEvent(
            id: "gate:\(gate.id):cleared",
            kind: .gateCleared,
            coordinatorSessionID: coordinatorSessionID,
            childSessionID: row?.sessionID,
            childTitle: row?.title,
            reviewID: gate.type == .reviewRequired ? gate.subjectID : nil,
            gate: gate,
            phase: row.map { CoordinatorFollowThroughChildPhase(statusGroup: $0.statusGroup) },
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
}
