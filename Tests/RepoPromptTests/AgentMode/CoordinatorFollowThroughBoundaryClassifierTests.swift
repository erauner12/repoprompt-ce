@testable import RepoPrompt
import XCTest

final class CoordinatorFollowThroughBoundaryClassifierTests: XCTestCase {
    private let classifier = CoordinatorFollowThroughBoundaryClassifier()

    func testFollowOffHolds() {
        let decision = classifier.classify(input(followThroughEnabled: false))

        XCTAssertEqual(decision, .hold(.followThroughDisabled))
    }

    func testRunningCoordinatorHolds() {
        let decision = classifier.classify(input(coordinatorRunState: .running))

        XCTAssertEqual(decision, .hold(.coordinatorActive))
    }

    func testCompletedChildResumes() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let row = childRow(
            coordinatorID: coordinatorID,
            childID: childID,
            statusGroup: .done,
            runState: .completed
        )
        var state = baseState()
        state.observedChildPhases[childID] = .running

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row],
            state: state
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .childTerminal)
        XCTAssertEqual(event.id, "child:\(childID.uuidString):terminal:completed")
        XCTAssertEqual(event.childSessionID, childID)
        XCTAssertEqual(event.phase, .done)
    }

    func testFirstObservedCompletedChildResumes() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let row = childRow(
            coordinatorID: coordinatorID,
            childID: childID,
            statusGroup: .done,
            runState: .completed
        )

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row],
            state: baseState()
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .childTerminal)
        XCTAssertEqual(event.childSessionID, childID)
    }

    func testRequiredReviewHoldsUntilAcknowledged() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let row = childRow(
            coordinatorID: coordinatorID,
            childID: childID,
            statusGroup: .review,
            runState: .completed,
            mergeAttention: mergeAttention(id: "merge-review"),
            pendingHumanReviewID: "merge-review"
        )

        let lifecycleDecision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row]
        ))

        XCTAssertEqual(lifecycleDecision, .hold(.requiredReviewUncleared(childID)))

        let acknowledgementDecision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row],
            trigger: .gateCleared(.reviewAcknowledgement(reviewID: "merge-review"))
        ))

        guard case let .resume(event) = acknowledgementDecision else {
            return XCTFail("Expected resume, got \(acknowledgementDecision)")
        }
        XCTAssertEqual(event.kind, .gateCleared)
        XCTAssertEqual(event.id, "gate:review:merge-review:cleared")
        XCTAssertEqual(event.reviewID, "merge-review")
        XCTAssertEqual(event.childSessionID, childID)
        XCTAssertEqual(event.gate?.type, .reviewRequired)
        XCTAssertNil(event.gate?.approvedAction)
    }

    func testWorkstreamReviewPhaseHoldsEvenWhenRawStatusIsDone() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let row = childRow(
            coordinatorID: coordinatorID,
            childID: childID,
            statusGroup: .done,
            runState: .completed,
            mergeAttention: mergeAttention(id: "merge-review"),
            workstreamSummary: workstreamSummary(
                coordinatorID: coordinatorID,
                childID: childID,
                phase: .review,
                reviewPacketID: "merge-review",
                nextAction: .init(
                    kind: .markReviewHandled,
                    title: "Mark reviewed",
                    detail: "Human review is required."
                )
            )
        )

        let lifecycleDecision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row]
        ))

        XCTAssertEqual(lifecycleDecision, .hold(.requiredReviewUncleared(childID)))

        let acknowledgementDecision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row],
            trigger: .gateCleared(.reviewAcknowledgement(reviewID: "merge-review"))
        ))

        guard case let .resume(event) = acknowledgementDecision else {
            return XCTFail("Expected resume, got \(acknowledgementDecision)")
        }
        XCTAssertEqual(event.kind, .gateCleared)
        XCTAssertEqual(event.reviewID, "merge-review")
        XCTAssertEqual(event.childSessionID, childID)
        XCTAssertEqual(event.phase, .review)
    }

    func testWorkstreamDonePhaseResumesEvenWhenRawStatusIsWorking() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let row = childRow(
            coordinatorID: coordinatorID,
            childID: childID,
            statusGroup: .working,
            runState: .completed,
            workstreamSummary: workstreamSummary(
                coordinatorID: coordinatorID,
                childID: childID,
                phase: .done
            )
        )
        var state = baseState()
        state.observedChildPhases[childID] = .running

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row],
            state: state
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .childTerminal)
        XCTAssertEqual(event.childSessionID, childID)
        XCTAssertEqual(event.phase, .done)
    }

    func testObservedPhasesPreferWorkstreamSummary() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let row = childRow(
            coordinatorID: coordinatorID,
            childID: childID,
            statusGroup: .done,
            runState: .completed,
            workstreamSummary: workstreamSummary(
                coordinatorID: coordinatorID,
                childID: childID,
                phase: .review
            )
        )
        var state = baseState()

        state.updateObservedPhases(from: [row])

        XCTAssertEqual(state.observedChildPhases[childID], .review)
    }

    func testGateClearedResumesEvenWithPendingChildTerminalEvent() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let row = childRow(
            coordinatorID: coordinatorID,
            childID: childID,
            statusGroup: .review,
            runState: .completed,
            mergeAttention: mergeAttention(id: "merge-review"),
            pendingHumanReviewID: "merge-review"
        )
        var state = baseState()
        state.enqueue(CoordinatorFollowThroughEvent(
            id: "child:\(childID.uuidString):terminal:completed",
            kind: .childTerminal,
            coordinatorSessionID: coordinatorID,
            childSessionID: childID,
            childTitle: "Child",
            reviewID: nil,
            gate: nil,
            phase: .done,
            detail: "Delegated child reached terminal state completed."
        ))

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row],
            state: state,
            trigger: .gateCleared(.reviewAcknowledgement(reviewID: "merge-review"))
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected gate-cleared resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .gateCleared)
        XCTAssertEqual(event.id, "gate:review:merge-review:cleared")
    }

    func testActionApprovalGateResumesOnlyScopedAction() {
        let coordinatorID = uuid(1)
        let gate = CoordinatorContinuationGate.actionApproval(
            gateID: "approval:create-pr:merge-review",
            action: .createPullRequest,
            subjectID: "merge-review",
            subjectTitle: "Review packet"
        )

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            trigger: .gateCleared(gate)
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected action approval gate resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .gateCleared)
        XCTAssertEqual(event.id, "gate:approval:create-pr:merge-review:cleared")
        XCTAssertEqual(event.gate?.type, .actionApprovalRequired)
        XCTAssertEqual(event.gate?.approvedAction, .createPullRequest)
        XCTAssertTrue(event.resumeDirective.contains("Approved action: createPullRequest"))
        XCTAssertTrue(event.resumeDirective.contains("permits only the explicitly approved action"))
    }

    func testAdvisoryReviewResumes() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let row = childRow(
            coordinatorID: coordinatorID,
            childID: childID,
            statusGroup: .done,
            runState: .completed,
            mergeAttention: mergeAttention(id: "merge-advisory")
        )
        var state = baseState()
        state.observedChildPhases[childID] = .review

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row],
            state: state
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .advisoryReview)
        XCTAssertEqual(event.id, "review:merge-advisory:advisory")
        XCTAssertEqual(event.reviewID, "merge-advisory")
    }

    func testNeedsUserAndBlockedHold() {
        let coordinatorID = uuid(1)
        let needsUserID = uuid(2)
        let blockedID = uuid(3)

        XCTAssertEqual(
            classifier.classify(input(
                coordinatorID: coordinatorID,
                rows: [
                    childRow(
                        coordinatorID: coordinatorID,
                        childID: needsUserID,
                        statusGroup: .needsYou,
                        runState: .waitingForUser
                    )
                ]
            )),
            .hold(.childNeedsUser(needsUserID))
        )

        XCTAssertEqual(
            classifier.classify(input(
                coordinatorID: coordinatorID,
                rows: [
                    childRow(
                        coordinatorID: coordinatorID,
                        childID: blockedID,
                        statusGroup: .blocked,
                        runState: .failed
                    )
                ]
            )),
            .hold(.childBlocked(blockedID))
        )
    }

    func testDuplicateEventHolds() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let eventID = "child:\(childID.uuidString):terminal:completed"
        var state = baseState()
        state.observedChildPhases[childID] = .running
        state.handledEventIDs.insert(eventID)

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [
                childRow(
                    coordinatorID: coordinatorID,
                    childID: childID,
                    statusGroup: .done,
                    runState: .completed
                )
            ],
            state: state
        ))

        XCTAssertEqual(decision, .hold(.duplicateEvent(eventID)))
    }

    func testDirectNonCoordinatorRowsDoNotResume() {
        let childID = uuid(2)
        let row = CoordinatorModeRow(
            id: childID,
            sessionID: childID,
            tabID: uuid(100),
            title: "Direct Agent",
            providerName: "codexExec",
            modelName: "gpt-5.5",
            runState: .completed,
            statusGroup: .done,
            parentSessionID: nil,
            parentCoordinator: nil,
            childSessionIDs: [],
            isMCPOriginated: true,
            isPersistedOnly: false,
            isCoordinator: false,
            updatedAt: date(10),
            priority: nil,
            workstream: nil,
            workstreamSummary: nil,
            workflow: nil,
            mergeAttention: nil,
            pendingHumanReviewID: nil,
            pendingInteraction: nil,
            openAgentChatRoute: nil,
            statusReport: nil,
            origin: .directAgent
        )

        let decision = classifier.classify(input(rows: [row]))

        XCTAssertEqual(decision, .hold(.noResumableEvent))
    }

    private func input(
        followThroughEnabled: Bool = true,
        coordinatorID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        coordinatorRunState: AgentSessionRunState = .idle,
        rows: [CoordinatorModeRow] = [],
        state: CoordinatorFollowThroughState? = nil,
        trigger: CoordinatorFollowThroughBoundaryClassifier.Trigger = .lifecycle
    ) -> CoordinatorFollowThroughBoundaryClassifier.Input {
        CoordinatorFollowThroughBoundaryClassifier.Input(
            followThroughEnabled: followThroughEnabled,
            coordinatorSessionID: coordinatorID,
            coordinatorRunState: coordinatorRunState,
            rows: rows,
            state: state ?? baseState(),
            trigger: trigger
        )
    }

    private func baseState() -> CoordinatorFollowThroughState {
        CoordinatorFollowThroughState(originalObjectiveSummary: "Finish the requested task.")
    }

    private func childRow(
        coordinatorID: UUID,
        childID: UUID,
        statusGroup: CoordinatorModeStatusGroup,
        runState: AgentSessionRunState,
        mergeAttention: CoordinatorModeRow.MergeAttention? = nil,
        pendingHumanReviewID: String? = nil,
        workstreamSummary: CoordinatorModeRow.WorkstreamSummary? = nil
    ) -> CoordinatorModeRow {
        CoordinatorModeRow(
            id: childID,
            sessionID: childID,
            tabID: uuid(100),
            title: "Child",
            providerName: "codexExec",
            modelName: "gpt-5.5",
            runState: runState,
            statusGroup: statusGroup,
            parentSessionID: coordinatorID,
            parentCoordinator: .init(sessionID: coordinatorID, title: "Coordinator", isSelected: true),
            childSessionIDs: [],
            isMCPOriginated: true,
            isPersistedOnly: false,
            isCoordinator: false,
            updatedAt: date(10),
            priority: nil,
            workstream: nil,
            workstreamSummary: workstreamSummary,
            workflow: nil,
            mergeAttention: mergeAttention,
            pendingHumanReviewID: pendingHumanReviewID,
            pendingInteraction: nil,
            openAgentChatRoute: nil,
            statusReport: nil,
            origin: .coordinatorFleet
        )
    }

    private func workstreamSummary(
        coordinatorID: UUID,
        childID: UUID,
        phase: CoordinatorModeRow.WorkstreamSummary.Phase,
        reviewPacketID: String? = nil,
        nextAction: CoordinatorModeRow.WorkstreamSummary.NextAction? = nil
    ) -> CoordinatorModeRow.WorkstreamSummary {
        CoordinatorModeRow.WorkstreamSummary(
            objective: "Child",
            phase: phase,
            childSessionID: childID,
            coordinatorSessionID: coordinatorID,
            worktree: nil,
            workflow: nil,
            reviewPacketID: reviewPacketID,
            nextAction: nextAction
        )
    }

    private func mergeAttention(id: String) -> CoordinatorModeRow.MergeAttention {
        CoordinatorModeRow.MergeAttention(
            id: id,
            status: .previewed,
            conflictFileCount: 0,
            updatedAt: date(20)
        )
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
