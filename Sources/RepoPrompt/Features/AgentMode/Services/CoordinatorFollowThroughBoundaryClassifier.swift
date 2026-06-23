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

        let ownedRows = input.rows.filter { isOwnedByCoordinator($0, coordinatorSessionID: coordinatorSessionID) }
        if let needsUser = ownedRows.first(where: { phase(for: $0) == .needsUser }) {
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
        if let requiredReview = rows.first(where: requiresHumanReviewAcknowledgement) {
            return .hold(.requiredReviewUncleared(requiredReview.sessionID))
        }

        if let advisory = rows.first(where: { row in
            phase(for: row) == .done
                && reviewID(for: row) != nil
                && state.observedChildPhases[row.sessionID] == .review
        }) {
            let reviewID = reviewID(for: advisory)
            let event = CoordinatorFollowThroughEvent(
                id: "review:\(reviewID ?? advisory.sessionID.uuidString):advisory",
                kind: .advisoryReview,
                coordinatorSessionID: coordinatorSessionID,
                childSessionID: advisory.sessionID,
                childTitle: advisory.title,
                reviewID: reviewID,
                gate: nil,
                phase: .done,
                detail: "Advisory review packet is available without a hard human-review gate."
            )
            return deduped(event, state: state)
        }

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
        if let ownerID = gate.ownerCoordinatorSessionID,
           ownerID != coordinatorSessionID
        {
            return .hold(.noResumableEvent)
        }

        if gate.type == .actionApprovalRequired,
           let requiredReview = rows.first(where: requiresHumanReviewAcknowledgement)
        {
            return .hold(.requiredReviewUncleared(requiredReview.sessionID))
        }

        let row = rows.first {
            $0.pendingHumanReviewID == gate.subjectID || reviewID(for: $0) == gate.subjectID
        }
        let event = CoordinatorFollowThroughEvent(
            id: "gate:\(gate.id):cleared",
            kind: .gateCleared,
            coordinatorSessionID: coordinatorSessionID,
            childSessionID: row?.sessionID,
            childTitle: row?.title,
            reviewID: gate.type == .reviewRequired ? gate.subjectID : nil,
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

    private func phase(for row: CoordinatorModeRow) -> CoordinatorFollowThroughChildPhase {
        CoordinatorFollowThroughChildPhase(row: row)
    }

    private func reviewID(for row: CoordinatorModeRow) -> String? {
        row.workstreamSummary?.reviewPacketID ?? row.mergeAttention?.id
    }

    private func requiresHumanReviewAcknowledgement(_ row: CoordinatorModeRow) -> Bool {
        guard phase(for: row) == .review else { return false }
        if row.pendingHumanReviewID != nil {
            return true
        }
        return row.workstreamSummary?.nextAction?.kind == .markReviewHandled
            && row.workstreamSummary?.reviewPacketID != nil
    }
}
