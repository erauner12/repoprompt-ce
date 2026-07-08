@testable import RepoPrompt
import XCTest

final class CoordinatorAutoModeBoundaryClassifierTests: XCTestCase {
    private let classifier = CoordinatorAutoModeBoundaryClassifier()

    func testAutoModeOffHolds() {
        let decision = classifier.classify(input(autoModeEnabled: false))

        XCTAssertEqual(decision, .hold(.autoModeDisabled))
    }

    func testRunningCoordinatorHolds() {
        let decision = classifier.classify(input(coordinatorRunState: .running))

        XCTAssertEqual(decision, .hold(.coordinatorActive))
    }

    func testWaitingForQuestionCoordinatorCanResumeGateCleared() {
        let coordinatorID = uuid(1)
        let gate = CoordinatorContinuationGate.actionApproval(
            gateID: "approval:continue:mission-plan",
            action: .continuePlan,
            subjectID: "mission-plan",
            subjectTitle: "Mission Plan"
        )

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            coordinatorRunState: .waitingForQuestion,
            trigger: .gateCleared(gate)
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected gate-cleared resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .gateCleared)
        XCTAssertEqual(event.id, "gate:approval:continue:mission-plan:cleared")
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

    func testWorkstreamReviewPhaseResumesEvenWhenRawStatusIsDone() {
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
                nextAction: .init(
                    kind: .inspectOutput,
                    title: "Inspect merge preview",
                    detail: "Preview artifacts are available for inspection."
                )
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
            mergeAttention: mergeAttention(id: "merge-review")
        )
        var state = baseState()
        state.enqueue(CoordinatorFollowThroughEvent(
            id: "child:\(childID.uuidString):terminal:completed",
            kind: .childTerminal,
            coordinatorSessionID: coordinatorID,
            childSessionID: childID,
            childTitle: "Child",
            gate: nil,
            phase: .done,
            detail: "Delegated child reached terminal state completed."
        ))

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [row],
            state: state,
            trigger: .gateCleared(.actionApproval(
                gateID: "approval:continue:merge-review",
                action: .continuePlan,
                subjectID: "merge-review",
                subjectTitle: "Merge preview"
            ))
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected gate-cleared resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .gateCleared)
        XCTAssertEqual(event.id, "gate:approval:continue:merge-review:cleared")
    }

    func testActionApprovalGateResumesOnlyScopedAction() {
        let coordinatorID = uuid(1)
        let gate = CoordinatorContinuationGate.actionApproval(
            gateID: "approval:create-pr:merge-review",
            action: .createPullRequest,
            subjectID: "merge-review",
            subjectTitle: "Merge preview"
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

    func testOwnerScopedGateDoesNotResumeDifferentCoordinator() {
        let ownerID = uuid(1)
        let otherCoordinatorID = uuid(99)
        let gate = CoordinatorContinuationGate.actionApproval(
            gateID: "approval:continue:merge-review",
            action: .continuePlan,
            subjectID: "merge-review",
            subjectTitle: "Merge preview",
            ownerCoordinatorSessionID: ownerID
        )

        let decision = classifier.classify(input(
            coordinatorID: otherCoordinatorID,
            trigger: .gateCleared(gate)
        ))

        XCTAssertEqual(decision, .hold(.noResumableEvent))
    }

    func testReviewableOutputResumes() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let row = childRow(
            coordinatorID: coordinatorID,
            childID: childID,
            statusGroup: .review,
            runState: .completed,
            mergeAttention: mergeAttention(id: "merge-advisory")
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
        XCTAssertEqual(event.id, "child:\(childID.uuidString):review:merge-advisory")
        XCTAssertEqual(event.phase, .review)
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

    func testChildAskAutoResumesPendingChildQuestion() {
        let coordinatorID = uuid(1)
        let needsUserID = uuid(2)
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = .auto
        var state = baseState()
        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            objective: "Answer routine child questions.",
            status: .running,
            approvalState: .approved,
            policySnapshot: policy,
            autonomy: policy.autonomy
        ))

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [
                childRow(
                    coordinatorID: coordinatorID,
                    childID: needsUserID,
                    statusGroup: .needsYou,
                    runState: .waitingForQuestion
                )
            ],
            state: state
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected child question resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .childQuestion)
        XCTAssertEqual(event.phase, .needsUser)
        XCTAssertEqual(event.childSessionID, needsUserID)
        XCTAssertTrue(event.resumeDirective.contains("childAsk:auto"))
        XCTAssertTrue(event.resumeDirective.contains("Do not ask the user"))
        XCTAssertTrue(event.resumeDirective.contains("coordinator_session_id"))
    }

    func testChildAskAutoDoesNotResumeGenericNeedsUserRow() {
        let coordinatorID = uuid(1)
        let needsUserID = uuid(2)
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = .auto
        var state = baseState()
        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            objective: "Answer routine child questions.",
            status: .running,
            approvalState: .approved,
            policySnapshot: policy,
            autonomy: policy.autonomy
        ))

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [
                childRow(
                    coordinatorID: coordinatorID,
                    childID: needsUserID,
                    statusGroup: .needsYou,
                    runState: .waitingForUser
                )
            ],
            state: state
        ))

        XCTAssertEqual(decision, .hold(.childNeedsUser(needsUserID)))
    }

    func testChildAskAutoResumesSuppressedUserFacingQuestionRow() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = .auto
        var state = baseState()
        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            objective: "Answer routine child questions.",
            status: .running,
            approvalState: .approved,
            policySnapshot: policy,
            autonomy: policy.autonomy
        ))

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            rows: [
                childRow(
                    coordinatorID: coordinatorID,
                    childID: childID,
                    statusGroup: .working,
                    runState: .waitingForQuestion
                )
            ],
            state: state
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected child question resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .childQuestion)
        XCTAssertEqual(event.childSessionID, childID)
        XCTAssertTrue(event.resumeDirective.contains("childAsk:auto"))
    }

    func testChildAskAutoResumesWhenCoordinatorIsWaitingForQuestion() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = .auto
        var state = baseState()
        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            objective: "Answer routine child questions.",
            status: .running,
            approvalState: .approved,
            policySnapshot: policy,
            autonomy: policy.autonomy
        ))

        let decision = classifier.classify(input(
            coordinatorID: coordinatorID,
            coordinatorRunState: .waitingForQuestion,
            rows: [
                childRow(
                    coordinatorID: coordinatorID,
                    childID: childID,
                    statusGroup: .working,
                    runState: .waitingForQuestion
                )
            ],
            state: state
        ))

        guard case let .resume(event) = decision else {
            return XCTFail("Expected child question resume, got \(decision)")
        }
        XCTAssertEqual(event.kind, .childQuestion)
        XCTAssertEqual(event.childSessionID, childID)
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
            startedAt: nil,
            updatedAt: date(10),
            priority: nil,
            workstream: nil,
            workstreamSummary: nil,
            workflow: nil,
            mergeAttention: nil,
            pendingInteraction: nil,
            openAgentChatRoute: nil,
            statusReport: nil,
            origin: .directAgent
        )

        let decision = classifier.classify(input(rows: [row]))

        XCTAssertEqual(decision, .hold(.noResumableEvent))
    }

    private func input(
        autoModeEnabled: Bool = true,
        coordinatorID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        coordinatorRunState: AgentSessionRunState = .idle,
        rows: [CoordinatorModeRow] = [],
        state: CoordinatorFollowThroughState? = nil,
        trigger: CoordinatorAutoModeBoundaryClassifier.Trigger = .lifecycle
    ) -> CoordinatorAutoModeBoundaryClassifier.Input {
        CoordinatorAutoModeBoundaryClassifier.Input(
            autoModeEnabled: autoModeEnabled,
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
            startedAt: nil,
            updatedAt: date(10),
            priority: nil,
            workstream: nil,
            workstreamSummary: workstreamSummary,
            workflow: nil,
            mergeAttention: mergeAttention,
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
        nextAction: CoordinatorModeRow.WorkstreamSummary.NextAction? = nil
    ) -> CoordinatorModeRow.WorkstreamSummary {
        CoordinatorModeRow.WorkstreamSummary(
            objective: "Child",
            phase: phase,
            childSessionID: childID,
            coordinatorSessionID: coordinatorID,
            worktree: nil,
            workflow: nil,
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
