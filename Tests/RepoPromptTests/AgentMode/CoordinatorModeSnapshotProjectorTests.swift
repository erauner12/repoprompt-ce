@testable import RepoPrompt
import XCTest

private extension CoordinatorModeWorkflowDisplaySummary {
    static let orchestrate = CoordinatorModeWorkflowDisplaySummary(AgentWorkflow.orchestrate.definition)
    static let review = CoordinatorModeWorkflowDisplaySummary(AgentWorkflow.review.definition)
    static let investigate = CoordinatorModeWorkflowDisplaySummary(AgentWorkflow.investigate.definition)
}

final class CoordinatorModeSnapshotProjectorTests: XCTestCase {
    private let projector = CoordinatorModeSnapshotProjector()

    func testColdOpenShowsCoordinatorHistoryWithoutSelectingOne() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)

        let snapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: uuid(101), title: "Persisted coordinator", updatedAt: date(20), coordinatorRuntime: true),
                persisted(id: childID, tab: uuid(102), title: "Child", updatedAt: date(10), parent: coordinatorID)
            ],
            autoSelectDemoCoordinator: false
        ))

        XCTAssertEqual(snapshot.coordinatorRail.state, .chooseCoordinator)
        XCTAssertNil(snapshot.coordinatorRail.coordinatorSessionID)
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.map(\.sessionID), [coordinatorID])
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.first?.isPersistedOnly, true)
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.first?.childCounts.total, 1)
        XCTAssertTrue(allRows(in: snapshot).isEmpty)
    }

    func testPersistedCoordinatorSelectionScopesBoardToDescendants() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let unrelatedCoordinatorID = uuid(3)
        let unrelatedChildID = uuid(4)

        let snapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: uuid(101), title: "Persisted coordinator", updatedAt: date(20), coordinatorRuntime: true),
                persisted(id: childID, tab: uuid(102), title: "Child", updatedAt: date(10), parent: coordinatorID),
                persisted(id: unrelatedCoordinatorID, tab: uuid(103), title: "Other coordinator", updatedAt: date(30), coordinatorRuntime: true),
                persisted(id: unrelatedChildID, tab: uuid(104), title: "Other child", updatedAt: date(25), parent: unrelatedCoordinatorID)
            ],
            selectedCoordinatorID: coordinatorID,
            autoSelectDemoCoordinator: false
        ))

        XCTAssertEqual(snapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(snapshot.coordinatorRail.selectionSource, .mcpLineageRoot)
        XCTAssertEqual(Set(allRows(in: snapshot).map(\.sessionID)), [childID])
        XCTAssertEqual(snapshot.coordinatorRail.childCounts.total, 1)
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.map(\.sessionID), [unrelatedCoordinatorID, coordinatorID])
    }

    func testPinnedCoordinatorOptionsSortBeforeRecentUnpinned() {
        let pinnedID = uuid(1)
        let recentID = uuid(2)

        let snapshot = projector.project(input(
            persisted: [
                persisted(id: pinnedID, tab: uuid(101), title: "Pinned", updatedAt: date(10), coordinatorRuntime: true, pinned: true),
                persisted(id: recentID, tab: uuid(102), title: "Recent", updatedAt: date(30), coordinatorRuntime: true)
            ],
            autoSelectDemoCoordinator: false
        ))

        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.map(\.sessionID), [pinnedID, recentID])
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.map(\.isPinned), [true, false])
    }

    func testMissionPlanProjectsToRailAndDeclaredWorkstreams() throws {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let reviewID = uuid(3)
        let plan = CoordinatorMissionPlan(
            objective: "Ship docs flow",
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: uuid(10),
                    title: "Docs implementation",
                    purpose: "Apply the README wording change.",
                    role: "Implement",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .createIsolated,
                        worktreeID: "wt-docs",
                        reason: "Mutable docs work should stay off the parent checkout."
                    ),
                    primarySessionID: childID,
                    relatedSessionIDs: [reviewID]
                )
            ],
            updatedAt: date(50)
        )

        let snapshot = projector.project(input(
            live: [
                live(
                    id: coordinatorID,
                    tab: uuid(101),
                    title: "Coordinator Runtime Demo",
                    updatedAt: date(100),
                    state: .idle,
                    coordinatorRuntime: true,
                    missionTemplate: CoordinatorMissionTemplateSummary(.scopedChange),
                    missionPlan: plan
                ),
                live(id: childID, tab: uuid(102), title: "Implement docs", updatedAt: date(90), state: .running, parent: coordinatorID),
                live(id: reviewID, tab: uuid(103), title: "Review docs", updatedAt: date(80), state: .completed, parent: coordinatorID)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(snapshot.coordinatorRail.missionPlan, plan)
        XCTAssertEqual(snapshot.coordinatorRail.missionTemplate, CoordinatorMissionTemplateSummary(.scopedChange))
        let childSummary = try XCTUnwrap(allRows(in: snapshot).first { $0.sessionID == childID }?.workstreamSummary)
        XCTAssertEqual(childSummary.declaredWorkstream?.title, "Docs implementation")
        XCTAssertEqual(childSummary.declaredWorkstream?.defaultPolicy, .freshWorktree)
        XCTAssertEqual(childSummary.declaredWorkstream?.worktreeStrategy.mode, .createIsolated)
        let reviewSummary = try XCTUnwrap(allRows(in: snapshot).first { $0.sessionID == reviewID }?.workstreamSummary)
        XCTAssertEqual(reviewSummary.declaredWorkstream?.id, uuid(10))
    }

    func testMissionSummaryProjectsShapePolicyLedgerCountsAndMovesFingerprint() throws {
        let coordinatorID = uuid(1)
        let basePlan = CoordinatorMissionPlan(
            revision: 2,
            objective: "Ship ledger projection",
            approvalState: .awaitingApproval,
            shapeSummary: CoordinatorMissionShapeSummary(
                id: "scoped-change",
                displayName: "Scoped Change",
                reason: "Small repo-local change.",
                namedClose: "PR"
            ),
            policySnapshot: .carefulWrites,
            autonomy: [
                CoordinatorMissionDecisionClass.plan.rawValue: .ask,
                CoordinatorMissionDecisionClass.writes.rawValue: .ask,
                "unknown": .auto
            ],
            decisions: [
                CoordinatorMissionDecisionRecord(
                    userDecision: .approvedMissionPlan,
                    decisionClass: .plan,
                    checkpointInstanceID: "coordinator-1:plan:r2",
                    timestamp: date(10),
                    checkpointID: "plan-approval"
                ),
                CoordinatorMissionDecisionRecord(
                    decisionClass: CoordinatorMissionDecisionClass.writes.rawValue,
                    actor: .director,
                    label: "selected read-only evidence lane",
                    reason: "Policy allows evidence gathering.",
                    timestamp: date(11)
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(verdict: .meets, summary: "Tests passed.", timestamp: date(12)),
                CoordinatorMissionEvidenceRecord(verdict: .short, summary: "Lint not run yet.", timestamp: date(13))
            ],
            updatedAt: date(20)
        )

        let snapshot = projector.project(input(
            live: [
                live(
                    id: coordinatorID,
                    tab: uuid(101),
                    title: "Coordinator Runtime Demo",
                    updatedAt: date(30),
                    state: .idle,
                    coordinatorRuntime: true,
                    missionPlan: basePlan
                )
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))

        let summary = try XCTUnwrap(snapshot.coordinatorRail.missionSummary)
        XCTAssertEqual(summary.shape?.displayName, "Scoped Change")
        XCTAssertEqual(summary.shape?.namedClose, "PR")
        XCTAssertEqual(summary.policy?.name, "Careful writes")
        XCTAssertEqual(summary.policy?.maxConcurrent, CoordinatorMissionPolicySnapshot.carefulWrites.maxConcurrent)
        XCTAssertEqual(summary.askAutonomyClasses, ["plan", "unknown", "writes"])
        XCTAssertEqual(summary.decisions.userCount, 1)
        XCTAssertEqual(summary.decisions.directorCount, 1)
        XCTAssertEqual(summary.decisions.recentLabels, ["approved the Mission plan", "selected read-only evidence lane"])
        XCTAssertEqual(summary.evidence.meetsCount, 1)
        XCTAssertEqual(summary.evidence.shortCount, 1)
        XCTAssertEqual(summary.evidence.recentSummaries, ["Tests passed.", "Lint not run yet."])
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.first?.missionSummary, summary)

        var revisedPlan = basePlan
        revisedPlan.decisions.append(CoordinatorMissionDecisionRecord(
            userDecision: .requestedPlanRevision,
            decisionClass: .plan,
            checkpointInstanceID: "coordinator-1:plan:r2",
            timestamp: date(14),
            checkpointID: "plan-approval"
        ))
        let revisedSnapshot = projector.project(input(
            live: [
                live(
                    id: coordinatorID,
                    tab: uuid(101),
                    title: "Coordinator Runtime Demo",
                    updatedAt: date(30),
                    state: .idle,
                    coordinatorRuntime: true,
                    missionPlan: revisedPlan
                )
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertNotEqual(snapshot.fingerprint, revisedSnapshot.fingerprint)
        XCTAssertEqual(revisedSnapshot.coordinatorRail.missionSummary?.decisions.userCount, 2)
    }

    func testBoardIncludesOnlyCurrentDemoCoordinatorDescendants() {
        let coordinatorID = uuid(1)
        let directChildID = uuid(2)
        let nestedChildID = uuid(3)
        let proofID = uuid(4)
        let unrelatedID = uuid(5)
        let previousCoordinatorID = uuid(6)
        let previousChildID = uuid(7)

        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(100), state: .idle),
                live(id: directChildID, tab: uuid(102), title: "Delegate A", updatedAt: date(90), state: .waitingForApproval, parent: coordinatorID),
                live(id: nestedChildID, tab: uuid(103), title: "Delegate B", updatedAt: date(80), state: .running, parent: directChildID),
                live(id: proofID, tab: uuid(104), title: "Coordinator loopback proof", updatedAt: date(70), state: .completed, parent: coordinatorID, internalSession: true),
                live(id: unrelatedID, tab: uuid(105), title: "Unrelated", updatedAt: date(60), state: .running),
                live(id: previousCoordinatorID, tab: uuid(106), title: "Coordinator Runtime Demo (cleared)", updatedAt: date(50), state: .completed),
                live(id: previousChildID, tab: uuid(107), title: "Previous child", updatedAt: date(40), state: .running, parent: previousCoordinatorID)
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(snapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(snapshot.coordinatorRail.selectionSource, .demoRuntime)
        XCTAssertEqual(Set(allRows(in: snapshot).map(\.sessionID)), [directChildID, nestedChildID])
        XCTAssertFalse(allRows(in: snapshot).contains { $0.sessionID == coordinatorID })
        XCTAssertFalse(allRows(in: snapshot).contains { $0.sessionID == unrelatedID })
        XCTAssertEqual(rows(in: snapshot, group: .needsYou).map(\.sessionID), [directChildID])
        XCTAssertEqual(rows(in: snapshot, group: .working).map(\.sessionID), [nestedChildID])
        XCTAssertTrue(rows(in: snapshot, group: .done).isEmpty)
        XCTAssertEqual(allRows(in: snapshot).first { $0.sessionID == directChildID }?.childSessionIDs, [nestedChildID])
        XCTAssertEqual(allRows(in: snapshot).first { $0.sessionID == directChildID }?.parentCoordinator?.sessionID, coordinatorID)
        XCTAssertEqual(allRows(in: snapshot).first { $0.sessionID == nestedChildID }?.parentCoordinator?.sessionID, coordinatorID)
    }

    func testBoardIncludesOnlySelectedCoordinatorDescendantsAndKeepsHistoryOptions() {
        let firstCoordinatorID = uuid(1)
        let firstChildID = uuid(2)
        let secondCoordinatorID = uuid(3)
        let secondChildID = uuid(4)

        let snapshot = projector.project(input(
            live: [
                live(id: firstCoordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(100), state: .idle),
                live(id: firstChildID, tab: uuid(102), title: "First delegate", updatedAt: date(90), state: .completed, parent: firstCoordinatorID),
                live(id: secondCoordinatorID, tab: uuid(103), title: "Coordinator Runtime Demo", updatedAt: date(200), state: .idle),
                live(id: secondChildID, tab: uuid(104), title: "Second delegate", updatedAt: date(190), state: .running, parent: secondCoordinatorID)
            ],
            selectedCoordinatorID: firstCoordinatorID,
            demoCoordinatorIDs: [firstCoordinatorID, secondCoordinatorID]
        ))

        XCTAssertEqual(snapshot.coordinatorRail.coordinatorSessionID, firstCoordinatorID)
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.map(\.sessionID), [secondCoordinatorID, firstCoordinatorID])
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.map(\.title), ["Coordinator Runtime Demo", "Coordinator Runtime Demo"])
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.map(\.isSelected), [false, true])
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.map(\.isLiveInCurrentWindow), [true, true])
        XCTAssertEqual(Set(allRows(in: snapshot).map(\.sessionID)), [firstChildID])
        XCTAssertEqual(allRows(in: snapshot).first { $0.sessionID == firstChildID }?.parentCoordinator?.sessionID, firstCoordinatorID)
        XCTAssertEqual(allRows(in: snapshot).first { $0.sessionID == firstChildID }?.parentCoordinator?.isSelected, true)
        XCTAssertNil(allRows(in: snapshot).first { $0.sessionID == secondChildID })
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.first { $0.sessionID == firstCoordinatorID }?.childCounts.total, 1)
        XCTAssertEqual(snapshot.coordinatorRail.availableCoordinators.first { $0.sessionID == secondCoordinatorID }?.childCounts.total, 1)

        let switchedSnapshot = projector.project(input(
            live: [
                live(id: firstCoordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(100), state: .idle),
                live(id: firstChildID, tab: uuid(102), title: "First delegate", updatedAt: date(90), state: .completed, parent: firstCoordinatorID),
                live(id: secondCoordinatorID, tab: uuid(103), title: "Coordinator Runtime Demo", updatedAt: date(200), state: .idle),
                live(id: secondChildID, tab: uuid(104), title: "Second delegate", updatedAt: date(190), state: .running, parent: secondCoordinatorID)
            ],
            selectedCoordinatorID: secondCoordinatorID,
            demoCoordinatorIDs: [firstCoordinatorID, secondCoordinatorID]
        ))

        XCTAssertEqual(switchedSnapshot.coordinatorRail.coordinatorSessionID, secondCoordinatorID)
        XCTAssertEqual(Set(allRows(in: switchedSnapshot).map(\.sessionID)), [secondChildID])
        XCTAssertNil(allRows(in: switchedSnapshot).first { $0.sessionID == firstChildID })
        XCTAssertEqual(allRows(in: switchedSnapshot).first { $0.sessionID == secondChildID }?.parentCoordinator?.isSelected, true)
    }

    func testAllAgentsScopeIncludesLiveDelegatesAcrossCoordinatorRoots() {
        let coordinatorID = uuid(1)
        let delegatedID = uuid(2)
        let directID = uuid(3)
        let directChildID = uuid(4)
        let internalID = uuid(5)
        let persistedOnlyID = uuid(6)
        let secondCoordinatorID = uuid(7)
        let secondDelegatedID = uuid(8)
        let sessions = [
            live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(100), state: .idle),
            live(id: delegatedID, tab: uuid(102), title: "Delegated", updatedAt: date(90), state: .completed, parent: coordinatorID),
            live(id: directID, tab: uuid(103), title: "Direct agent", updatedAt: date(80), state: .running),
            live(id: directChildID, tab: uuid(104), title: "Direct child", updatedAt: date(70), state: .waitingForUser, parent: directID),
            live(id: internalID, tab: uuid(105), title: "Coordinator proof", updatedAt: date(60), state: .completed, parent: coordinatorID, internalSession: true),
            live(id: secondCoordinatorID, tab: uuid(107), title: "Second Coordinator Runtime Demo", updatedAt: date(50), state: .idle),
            live(id: secondDelegatedID, tab: uuid(108), title: "Second delegated", updatedAt: date(40), state: .running, parent: secondCoordinatorID)
        ]

        let focused = projector.project(input(
            live: sessions,
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID, secondCoordinatorID]
        ))
        XCTAssertEqual(Set(allRows(in: focused).map(\.sessionID)), [delegatedID])
        XCTAssertEqual(allRows(in: focused).first?.origin, .coordinatorFleet)

        let allAgents = projector.project(input(
            persisted: [
                persisted(id: persistedOnlyID, tab: uuid(106), title: "Historical direct", updatedAt: date(110), state: .completed)
            ],
            live: sessions,
            selectedCoordinatorID: coordinatorID,
            boardScope: .allAgents,
            demoCoordinatorIDs: [coordinatorID, secondCoordinatorID]
        ))

        XCTAssertEqual(allAgents.boardScope, CoordinatorModeBoardScope.allAgents)
        XCTAssertEqual(Set(allRows(in: allAgents).map(\.sessionID)), [delegatedID, secondDelegatedID])
        XCTAssertFalse(allRows(in: allAgents).contains { $0.sessionID == coordinatorID })
        XCTAssertFalse(allRows(in: allAgents).contains { $0.sessionID == secondCoordinatorID })
        XCTAssertFalse(allRows(in: allAgents).contains { $0.sessionID == internalID })
        XCTAssertFalse(allRows(in: allAgents).contains { $0.sessionID == persistedOnlyID })
        XCTAssertFalse(allRows(in: allAgents).contains { $0.sessionID == directID })
        XCTAssertFalse(allRows(in: allAgents).contains { $0.sessionID == directChildID })
        XCTAssertEqual(allRows(in: allAgents).first { $0.sessionID == delegatedID }?.origin, .coordinatorFleet)
        XCTAssertEqual(allRows(in: allAgents).first { $0.sessionID == delegatedID }?.parentCoordinator?.sessionID, coordinatorID)
        XCTAssertEqual(allRows(in: allAgents).first { $0.sessionID == secondDelegatedID }?.origin, .coordinatorFleet)
        XCTAssertEqual(allRows(in: allAgents).first { $0.sessionID == secondDelegatedID }?.parentCoordinator?.sessionID, secondCoordinatorID)
    }

    func testDelegatedRowProjectsStructuredWorkstreamSummary() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Docs sweep", updatedAt: date(100), state: .idle),
                live(
                    id: childID,
                    tab: uuid(102),
                    title: "Investigate README tests",
                    updatedAt: date(90),
                    state: .running,
                    parent: coordinatorID,
                    workflow: .investigate,
                    bindings: [
                        binding(visualLabel: "Docs worktree", branch: "docs/readme-tests")
                    ]
                )
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        let row = allRows(in: snapshot).first { $0.sessionID == childID }
        let summary = row?.workstreamSummary
        let workstream: CoordinatorWorkstream? = summary
        XCTAssertEqual(workstream?.id, childID)
        XCTAssertEqual(summary?.objective, "Investigate README tests")
        XCTAssertEqual(summary?.phase, .running)
        XCTAssertEqual(summary?.childSessionID, childID)
        XCTAssertEqual(summary?.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(summary?.worktree?.label, "Docs worktree")
        XCTAssertEqual(summary?.worktree?.branch, "docs/readme-tests")
        XCTAssertEqual(summary?.workflow?.id, AgentWorkflow.investigate.definition.id)
        XCTAssertEqual(summary?.nextAction?.kind, .waitForChild)
    }

    func testReviewRowProjectsMergePreviewInspectionAction() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let merge = mergeSummary(id: "merge-review-1", status: .previewed, conflicts: 0, updatedAt: date(95))
        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Merge preview demo", updatedAt: date(100), state: .idle),
                live(
                    id: childID,
                    tab: uuid(102),
                    title: "Prepare merge preview",
                    updatedAt: date(90),
                    state: .completed,
                    parent: coordinatorID,
                    workflow: .review,
                    merges: [merge]
                )
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        let summary = allRows(in: snapshot).first { $0.sessionID == childID }?.workstreamSummary
        XCTAssertEqual(summary?.phase, .review)
        XCTAssertEqual(summary?.nextAction?.kind, .inspectOutput)
        XCTAssertEqual(summary?.nextAction?.title, "Inspect merge preview")
    }

    func testReviewRowStaysReviewUntilCoordinatorContinuesIt() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let merge = mergeSummary(id: "merge-review-1", status: .previewed, conflicts: 0, updatedAt: date(95))
        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Merge preview demo", updatedAt: date(100), state: .idle),
                live(
                    id: childID,
                    tab: uuid(102),
                    title: "Prepare merge preview",
                    updatedAt: date(90),
                    state: .completed,
                    parent: coordinatorID,
                    workflow: .review,
                    merges: [merge]
                )
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        let row = allRows(in: snapshot).first { $0.sessionID == childID }
        XCTAssertEqual(row?.statusGroup, .review)
        XCTAssertEqual(row?.mergeAttention?.id, "merge-review-1")
        XCTAssertEqual(row?.workstreamSummary?.nextAction?.kind, .inspectOutput)
    }

    func testBoardIncludesRunningDelegatedSnapshotBeforePersistence() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let coordinatorTab = uuid(101)
        let childTab = uuid(102)

        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator Runtime Demo", updatedAt: date(10), state: .idle)
            ],
            mcpSnapshots: [
                childID: mcpSnapshot(
                    sessionID: childID,
                    tabID: childTab,
                    sessionName: "Live delegate",
                    status: .running,
                    statusText: "Running focused validation",
                    assistantPreview: "make dev-test FILTER=CoordinatorModeSnapshotProjectorTests",
                    interaction: nil,
                    parent: coordinatorID
                )
            ],
            resolvableTabs: [coordinatorTab, childTab],
            demoCoordinatorIDs: [coordinatorID]
        ))

        let row = rows(in: snapshot, group: .working).first
        XCTAssertEqual(snapshot.counts.totalRows, 1)
        XCTAssertEqual(snapshot.counts.liveRows, 1)
        XCTAssertEqual(row?.sessionID, childID)
        XCTAssertEqual(row?.title, "Live delegate")
        XCTAssertEqual(row?.runState, .running)
        XCTAssertEqual(row?.parentSessionID, coordinatorID)
        XCTAssertFalse(row?.isPersistedOnly ?? true)
        XCTAssertEqual(row?.statusReport?.status, .running)
        XCTAssertEqual(row?.statusReport?.statusText, "Running focused validation")
        XCTAssertEqual(row?.statusReport?.assistantPreview, "make dev-test FILTER=CoordinatorModeSnapshotProjectorTests")
        XCTAssertNil(row?.statusReport?.terminalOutput)
        XCTAssertNotNil(row?.openAgentChatRoute)
    }

    func testManualSelectionCannotPromotePlainSessionAsCoordinator() {
        let plainID = uuid(1)
        let demoID = uuid(2)

        let plainSelected = projector.project(input(
            live: [live(id: plainID, tab: uuid(101), title: "Plain Live Session", updatedAt: date(10), state: .idle)],
            selectedCoordinatorID: plainID
        ))

        XCTAssertEqual(plainSelected.coordinatorRail.state, .chooseCoordinator)
        XCTAssertTrue(plainSelected.isEmpty)

        let demoSelected = projector.project(input(
            live: [
                live(id: demoID, tab: uuid(102), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle),
                live(id: uuid(3), tab: uuid(103), title: "Delegate", updatedAt: date(19), state: .running, parent: demoID)
            ],
            selectedCoordinatorID: demoID,
            demoCoordinatorIDs: [demoID]
        ))

        XCTAssertEqual(demoSelected.coordinatorRail.state, .selected)
        XCTAssertEqual(demoSelected.coordinatorRail.coordinatorSessionID, demoID)
        XCTAssertEqual(demoSelected.coordinatorRail.selectionSource, .demoRuntime)
        XCTAssertEqual(demoSelected.counts.totalRows, 1)
    }

    func testComposerAvailabilityRequiresLiveCurrentWindowDemoCoordinator() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let coordinatorTab = uuid(101)
        let childTab = uuid(102)

        let liveSnapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: coordinatorTab, title: "Coordinator Runtime Demo", updatedAt: date(10), isMCP: true),
                persisted(id: childID, tab: childTab, title: "Child", updatedAt: date(9), parent: coordinatorID)
            ],
            live: [
                live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator Runtime Demo", updatedAt: date(11), state: .idle, isMCP: true)
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(liveSnapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
        XCTAssertTrue(liveSnapshot.coordinatorRail.isLiveInCurrentWindow)
        XCTAssertTrue(liveSnapshot.coordinatorRail.isComposerEnabled)
        XCTAssertTrue(liveSnapshot.coordinatorRail.isComposerSendEnabled)

        let runningSnapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: coordinatorTab, title: "Coordinator Runtime Demo", updatedAt: date(10), isMCP: true),
                persisted(id: childID, tab: childTab, title: "Child", updatedAt: date(9), parent: coordinatorID)
            ],
            live: [
                live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator Runtime Demo", updatedAt: date(12), state: .running, isMCP: true)
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertTrue(runningSnapshot.coordinatorRail.isComposerEnabled)
        XCTAssertFalse(runningSnapshot.coordinatorRail.isComposerSendEnabled)

        let persistedOnlySnapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: coordinatorTab, title: "Coordinator Runtime Demo", updatedAt: date(10), isMCP: true),
                persisted(id: childID, tab: childTab, title: "Child", updatedAt: date(9), parent: coordinatorID)
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(persistedOnlySnapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
        XCTAssertFalse(persistedOnlySnapshot.coordinatorRail.isLiveInCurrentWindow)
        XCTAssertFalse(persistedOnlySnapshot.coordinatorRail.isComposerEnabled)
        XCTAssertFalse(persistedOnlySnapshot.coordinatorRail.isComposerSendEnabled)
        XCTAssertNil(persistedOnlySnapshot.coordinatorRail.openAgentChatRoute)
        XCTAssertNotNil(allRows(in: persistedOnlySnapshot).first?.openAgentChatRoute)
    }

    func testComposerFallbackWhenCoordinatorIsUnreachable() {
        let snapshot = projector.project(input(persisted: [
            persisted(id: uuid(1), tab: uuid(101), title: "Plain Parent", updatedAt: date(10)),
            persisted(id: uuid(2), tab: uuid(102), title: "Plain Child", updatedAt: date(9), parent: uuid(1))
        ]))

        XCTAssertEqual(snapshot.coordinatorRail.state, .chooseCoordinator)
        XCTAssertNil(snapshot.coordinatorRail.coordinatorSessionID)
        XCTAssertFalse(snapshot.coordinatorRail.isComposerEnabled)
        XCTAssertFalse(snapshot.coordinatorRail.isComposerSendEnabled)
        XCTAssertNil(snapshot.coordinatorRail.openAgentChatRoute)
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testGroupingCountsUseFiveBoardTaxonomy() {
        let coordinatorID = uuid(1)
        let needs = live(id: uuid(2), tab: uuid(102), title: "Needs", updatedAt: date(50), state: .waitingForApproval, parent: coordinatorID)
        let working = live(id: uuid(3), tab: uuid(103), title: "Working", updatedAt: date(40), state: .running, parent: coordinatorID)
        let blocked = live(id: uuid(4), tab: uuid(104), title: "Blocked", updatedAt: date(30), state: .failed, parent: coordinatorID)
        let review = live(
            id: uuid(5),
            tab: uuid(105),
            title: "Review",
            updatedAt: date(20),
            state: .completed,
            parent: coordinatorID,
            merges: [mergeSummary(id: "preview", status: .previewed, conflicts: 0, updatedAt: date(20))]
        )
        let done = persisted(id: uuid(6), tab: uuid(106), title: "Done", updatedAt: date(10), state: .completed, parent: coordinatorID)

        let snapshot = projector.project(input(
            persisted: [done],
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(60), state: .idle),
                needs,
                working,
                blocked,
                review
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(
            snapshot.groups.map(\.group),
            [
                CoordinatorModeStatusGroup.needsYou,
                .working,
                .blocked,
                .review,
                .done
            ]
        )
        XCTAssertEqual(snapshot.counts.totalRows, 5)
        XCTAssertEqual(snapshot.counts.liveRows, 4)
        XCTAssertEqual(snapshot.counts.needsYou, 1)
        XCTAssertEqual(snapshot.counts.working, 1)
        XCTAssertEqual(snapshot.counts.blocked, 1)
        XCTAssertEqual(snapshot.counts.review, 1)
        XCTAssertEqual(snapshot.counts.done, 1)
        XCTAssertEqual(snapshot.counts.stalePersistedOnly, 1)
        XCTAssertEqual(rows(in: snapshot, group: .needsYou).map(\.sessionID), [needs.sessionID])
        XCTAssertEqual(rows(in: snapshot, group: .working).map(\.sessionID), [working.sessionID])
        XCTAssertEqual(rows(in: snapshot, group: .blocked).map(\.sessionID), [blocked.sessionID])
        XCTAssertEqual(rows(in: snapshot, group: .review).map(\.sessionID), [review.sessionID])
        XCTAssertEqual(rows(in: snapshot, group: .done).map(\.sessionID), [done.id])
    }

    func testConflictedWorktreeMergeForcesBlockedAndProjectsMergeAttention() {
        let coordinatorID = uuid(1)
        let sessionID = uuid(2)
        let merge = mergeSummary(id: "merge-conflict", status: .conflicted, conflicts: 2, updatedAt: date(90))
        let conflicted = live(
            id: sessionID,
            tab: uuid(102),
            title: "Merge conflict",
            updatedAt: date(10),
            state: .idle,
            parent: coordinatorID,
            merges: [merge]
        )

        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle),
                conflicted
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))
        let row = rows(in: snapshot, group: .blocked).first

        XCTAssertEqual(snapshot.counts.blocked, 1)
        XCTAssertEqual(row?.sessionID, sessionID)
        XCTAssertEqual(row?.runState, .idle)
        XCTAssertEqual(row?.mergeAttention?.id, merge.id)
        XCTAssertEqual(row?.mergeAttention?.status, .conflicted)
        XCTAssertEqual(row?.mergeAttention?.conflictFileCount, 2)
    }

    func testCompletedSessionWithReviewableMergeStaysInReview() {
        let coordinatorID = uuid(1)
        let sessionID = uuid(2)
        let merge = mergeSummary(id: "merge-review", status: .previewed, conflicts: 0, updatedAt: date(90))
        let completed = live(
            id: sessionID,
            tab: uuid(102),
            title: "Merge preview",
            updatedAt: date(100),
            state: .completed,
            parent: coordinatorID,
            merges: [merge]
        )

        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(110), state: .idle),
                completed
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        let row = rows(in: snapshot, group: .review).first
        XCTAssertEqual(row?.sessionID, sessionID)
        XCTAssertEqual(row?.mergeAttention?.id, "merge-review")
        XCTAssertTrue(rows(in: snapshot, group: .done).isEmpty)
    }

    func testCoordinatorDetectionMetadataAloneDoesNotRenderBoard() {
        let coordinatorID = uuid(1)
        let offWindowChildID = uuid(2)
        let coordinator = live(
            id: coordinatorID,
            tab: uuid(101),
            title: "Coordinator",
            updatedAt: date(10),
            state: .idle,
            workflow: .orchestrate
        )

        let snapshot = projector.project(input(
            live: [coordinator],
            detection: [
                detection(id: coordinatorID, title: "Coordinator", updatedAt: date(10), workflow: .orchestrate),
                detection(id: offWindowChildID, title: "Off-window child", updatedAt: date(9), parent: coordinatorID)
            ]
        ))

        XCTAssertEqual(snapshot.coordinatorRail.state, .chooseCoordinator)
        XCTAssertTrue(allRows(in: snapshot).isEmpty)
    }

    func testSortingReordersOnlyWithinStatusGroups() {
        let coordinatorID = uuid(10)
        let lowPriorityRecent = live(id: uuid(1), tab: uuid(101), title: "Beta", updatedAt: date(30), state: .running, parent: coordinatorID, priority: 1)
        let highPriorityOld = live(id: uuid(2), tab: uuid(102), title: "Alpha", updatedAt: date(10), state: .running, parent: coordinatorID, priority: 10)
        let needsYou = live(id: uuid(3), tab: uuid(103), title: "Needs", updatedAt: date(20), state: .waitingForUser, parent: coordinatorID, priority: 100)

        let prioritySorted = projector.project(input(
            live: [live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(40), state: .idle), lowPriorityRecent, highPriorityOld, needsYou],
            sort: .priority,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertEqual(rows(in: prioritySorted, group: .working).map(\.sessionID), [highPriorityOld.sessionID, lowPriorityRecent.sessionID])
        XCTAssertEqual(rows(in: prioritySorted, group: .needsYou).map(\.sessionID), [needsYou.sessionID])

        let nameSorted = projector.project(input(
            live: [live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(40), state: .idle), lowPriorityRecent, highPriorityOld, needsYou],
            sort: .name,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertEqual(rows(in: nameSorted, group: .working).map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(rows(in: nameSorted, group: .needsYou).map(\.title), ["Needs"])
    }

    func testPrioritySortSinksNilPriorityAndBreaksTiesByRecencyThenTitle() {
        let coordinatorID = uuid(10)
        let nilPriorityRecent = live(id: uuid(1), tab: uuid(101), title: "Nil", updatedAt: date(100), state: .running, parent: coordinatorID)
        let priorityRecent = live(id: uuid(2), tab: uuid(102), title: "Zulu", updatedAt: date(30), state: .running, parent: coordinatorID, priority: 5)
        let priorityTitleBeta = live(id: uuid(3), tab: uuid(103), title: "Beta", updatedAt: date(20), state: .running, parent: coordinatorID, priority: 5)
        let priorityTitleAlpha = live(id: uuid(4), tab: uuid(104), title: "Alpha", updatedAt: date(20), state: .running, parent: coordinatorID, priority: 5)
        let lowerPriority = live(id: uuid(5), tab: uuid(105), title: "Lower", updatedAt: date(200), state: .running, parent: coordinatorID, priority: 1)

        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(300), state: .idle),
                nilPriorityRecent,
                priorityTitleBeta,
                lowerPriority,
                priorityRecent,
                priorityTitleAlpha
            ],
            sort: .priority,
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(rows(in: snapshot, group: .working).map(\.sessionID), [
            priorityRecent.sessionID,
            priorityTitleAlpha.sessionID,
            priorityTitleBeta.sessionID,
            lowerPriority.sessionID,
            nilPriorityRecent.sessionID
        ])
    }

    func testWorkstreamLabelFallbackOrder() {
        let coordinatorID = uuid(10)
        let rows = allRows(in: projector.project(input(live: [
            live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(60), state: .idle),
            live(id: uuid(1), tab: uuid(101), title: "Visual", updatedAt: date(50), state: .idle, parent: coordinatorID, bindings: [binding(visualLabel: "Visual", worktreeName: "Worktree", logicalRootName: "Root", branch: "branch", repoKey: "repo")]),
            live(id: uuid(2), tab: uuid(102), title: "Worktree", updatedAt: date(40), state: .idle, parent: coordinatorID, bindings: [binding(visualLabel: nil, worktreeName: "Worktree", logicalRootName: "Root", branch: "branch", repoKey: "repo")]),
            live(id: uuid(3), tab: uuid(103), title: "Root", updatedAt: date(30), state: .idle, parent: coordinatorID, bindings: [binding(visualLabel: nil, worktreeName: nil, logicalRootName: "Root", branch: "branch", repoKey: "repo")]),
            live(id: uuid(4), tab: uuid(104), title: "Branch", updatedAt: date(20), state: .idle, parent: coordinatorID, bindings: [binding(visualLabel: nil, worktreeName: nil, logicalRootName: nil, branch: "branch", repoKey: "repo")]),
            live(id: uuid(5), tab: uuid(105), title: "Repo", updatedAt: date(10), state: .idle, parent: coordinatorID, bindings: [binding(visualLabel: nil, worktreeName: nil, logicalRootName: nil, branch: nil, repoKey: "repo")])
        ], demoCoordinatorIDs: [coordinatorID])))

        XCTAssertEqual(rows.map { $0.workstream?.label }, ["Visual", "Worktree", "Root", "branch", "repo"])
    }

    func testWorkflowMetadataDefaultsToNil() {
        let coordinatorID = uuid(10)
        let sessionID = uuid(1)
        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle),
                live(id: sessionID, tab: uuid(101), title: "Plain", updatedAt: date(10), state: .running, parent: coordinatorID)
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertNil(allRows(in: snapshot).first?.workflow)
    }

    func testWorkflowMetadataProjectsRealDisplaySummary() {
        let coordinatorID = uuid(10)
        let sessionID = uuid(1)
        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle),
                live(id: sessionID, tab: uuid(101), title: "Review README", updatedAt: date(10), state: .running, parent: coordinatorID, workflow: .review)
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        let workflow = allRows(in: snapshot).first?.workflow
        XCTAssertEqual(workflow?.id, AgentWorkflow.review.definition.id)
        XCTAssertEqual(workflow?.displayName, "Review")
        XCTAssertEqual(workflow?.iconName, "eye.fill")
    }

    func testLiveWorkflowNilClearsPersistedWorkflow() {
        let coordinatorID = uuid(10)
        let sessionID = uuid(1)
        let tabID = uuid(101)
        let snapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(30)),
                persisted(id: sessionID, tab: tabID, title: "Review README", updatedAt: date(20), parent: coordinatorID, workflow: .review)
            ],
            live: [
                live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(40), state: .idle),
                live(id: sessionID, tab: tabID, title: "Review README", updatedAt: date(35), state: .completed, parent: coordinatorID)
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertNil(allRows(in: snapshot).first { $0.sessionID == sessionID }?.workflow)
    }

    func testWorkflowMetadataChangesBetweenTurns() {
        let coordinatorID = uuid(10)
        let sessionID = uuid(1)
        let first = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle),
                live(id: sessionID, tab: uuid(101), title: "Investigate", updatedAt: date(10), state: .running, parent: coordinatorID, workflow: .investigate)
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))
        let second = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(30), state: .idle),
                live(id: sessionID, tab: uuid(101), title: "Review", updatedAt: date(25), state: .running, parent: coordinatorID, workflow: .review)
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(allRows(in: first).first?.workflow?.id, AgentWorkflow.investigate.definition.id)
        XCTAssertEqual(allRows(in: second).first?.workflow?.id, AgentWorkflow.review.definition.id)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    func testCoordinatorRailAndRowsReportOnlySnapshotStatusFields() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let coordinatorTab = uuid(101)
        let childTab = uuid(102)

        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator", updatedAt: date(20), state: .running),
                live(id: childID, tab: childTab, title: "Delegate", updatedAt: date(10), state: .failed, parent: coordinatorID)
            ],
            mcpSnapshots: [
                coordinatorID: mcpSnapshot(
                    sessionID: coordinatorID,
                    tabID: coordinatorTab,
                    status: .running,
                    statusText: "Dispatching delegated work…",
                    assistantPreview: "Do not use active streaming as terminal output",
                    interaction: nil
                ),
                childID: mcpSnapshot(
                    sessionID: childID,
                    tabID: childTab,
                    status: .failed,
                    statusText: "Timed out waiting for tests",
                    assistantPreview: "Last delegate output",
                    interaction: nil,
                    failureReason: .timeout
                )
            ],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(snapshot.coordinatorRail.statusReport?.status, .running)
        XCTAssertEqual(snapshot.coordinatorRail.statusReport?.statusText, "Dispatching delegated work…")
        XCTAssertEqual(snapshot.coordinatorRail.statusReport?.assistantPreview, "Do not use active streaming as terminal output")
        XCTAssertNil(snapshot.coordinatorRail.statusReport?.terminalOutput)
        XCTAssertNil(snapshot.coordinatorRail.statusReport?.failureReason)

        let childReport = allRows(in: snapshot).first { $0.sessionID == childID }?.statusReport
        XCTAssertEqual(childReport?.status, .failed)
        XCTAssertEqual(childReport?.statusText, "Timed out waiting for tests")
        XCTAssertNil(childReport?.assistantPreview)
        XCTAssertEqual(childReport?.terminalOutput, "Last delegate output")
        XCTAssertEqual(childReport?.failureReason, .timeout)
    }

    func testPendingInteractionProjectsStructuredMCPDataAndNullableRouteOnly() {
        let coordinatorID = uuid(10)
        let sessionID = uuid(1)
        let tabID = uuid(101)
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: uuid(200),
            kind: .approval,
            responseType: .decision,
            title: "Approve edit?",
            prompt: "Allow apply_edits?",
            context: nil,
            allowsMultiple: nil,
            options: [],
            fields: [],
            details: [AgentRunMCPSnapshot.Interaction.Detail(label: "File", value: "Sources/App.swift", isCode: true)]
        )
        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle),
                live(id: sessionID, tab: tabID, title: "Needs", updatedAt: date(10), state: .waitingForApproval, parent: coordinatorID)
            ],
            mcpSnapshots: [sessionID: mcpSnapshot(sessionID: sessionID, tabID: tabID, interaction: interaction)],
            resolvableTabs: [uuid(110), tabID],
            demoCoordinatorIDs: [coordinatorID]
        ))

        let summary = snapshot.pendingInteractions.first
        XCTAssertEqual(summary?.id, interaction.id)
        XCTAssertEqual(summary?.kind, .approval)
        XCTAssertEqual(summary?.title, "Approve edit?")
        XCTAssertEqual(summary?.prompt, "Allow apply_edits?")
        XCTAssertEqual(summary?.details.first?.label, "File")
        XCTAssertNotNil(summary?.openAgentChatRoute)

        let missingRouteSnapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle),
                live(id: sessionID, tab: tabID, title: "Needs", updatedAt: date(10), state: .waitingForApproval, parent: coordinatorID)
            ],
            mcpSnapshots: [sessionID: mcpSnapshot(sessionID: sessionID, tabID: tabID, interaction: interaction)],
            resolvableTabs: [],
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertNil(missingRouteSnapshot.pendingInteractions.first?.openAgentChatRoute)
    }

    func testChildAskAutoSuppressesUserFacingPendingInteraction() {
        let coordinatorID = uuid(10)
        let childID = uuid(1)
        let childTabID = uuid(101)
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = .auto
        let plan = CoordinatorMissionPlan(
            objective: "Answer child questions as Director.",
            status: .running,
            approvalState: .approved,
            autonomy: autonomy,
            updatedAt: date(30)
        )
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: uuid(200),
            kind: .question,
            responseType: .structured,
            title: "S5 child marker choice",
            prompt: "Which marker should this child use?",
            context: nil,
            allowsMultiple: nil,
            options: [],
            fields: [],
            details: []
        )

        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(40), state: .idle, coordinatorRuntime: true, missionPlan: plan),
                live(id: childID, tab: childTabID, title: "Child", updatedAt: date(20), state: .waitingForQuestion, parent: coordinatorID)
            ],
            mcpSnapshots: [
                childID: mcpSnapshot(
                    sessionID: childID,
                    tabID: childTabID,
                    status: .waitingForInput,
                    interaction: interaction,
                    parent: coordinatorID
                )
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertTrue(snapshot.pendingInteractions.isEmpty)
        XCTAssertFalse(snapshot.decisionQueue.contains { $0.source == .interaction })
        XCTAssertEqual(snapshot.counts.needsYou, 0)
        XCTAssertEqual(snapshot.counts.working, 1)
        XCTAssertEqual(rows(in: snapshot, group: .working).first?.sessionID, childID)
        XCTAssertNil(rows(in: snapshot, group: .working).first?.pendingInteraction)
    }

    func testSelectedCoordinatorOwnPendingInteractionProjectsToRail() {
        let coordinatorID = uuid(10)
        let tabID = uuid(110)
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: uuid(200),
            kind: .question,
            responseType: .structured,
            title: "Approve Mission Plan?",
            prompt: "Choose how to continue.",
            context: "The Coordinator is waiting on a user-owned checkpoint.",
            allowsMultiple: nil,
            options: [],
            fields: [
                AgentRunMCPSnapshot.Interaction.Field(
                    id: "decision",
                    header: "Coordinator decision",
                    prompt: "What should happen next?",
                    context: nil,
                    isSecret: false,
                    allowsOther: false,
                    allowsMultiple: false,
                    allowsCustom: false,
                    options: [
                        AgentRunMCPSnapshot.Interaction.Option(label: "Proceed", description: nil),
                        AgentRunMCPSnapshot.Interaction.Option(label: "Revise", description: nil)
                    ]
                )
            ],
            details: []
        )

        let snapshot = projector.project(input(
            live: [
                live(
                    id: coordinatorID,
                    tab: tabID,
                    title: "Coordinator Runtime Demo",
                    updatedAt: date(20),
                    state: .waitingForQuestion,
                    coordinatorRuntime: true
                )
            ],
            mcpSnapshots: [coordinatorID: mcpSnapshot(sessionID: coordinatorID, tabID: tabID, interaction: interaction)],
            selectedCoordinatorID: coordinatorID,
            resolvableTabs: [tabID],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(snapshot.coordinatorRail.pendingInteraction?.id, interaction.id)
        XCTAssertEqual(snapshot.coordinatorRail.pendingInteraction?.title, "Approve Mission Plan?")
        XCTAssertEqual(snapshot.coordinatorRail.pendingInteraction?.fields.first?.id, "decision")
    }

    func testPersistedOnlyRowWithoutLiveSnapshotDoesNotProjectPendingInteraction() {
        let coordinatorID = uuid(10)
        let sessionID = uuid(1)
        let tabID = uuid(101)
        let snapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(20)),
                persisted(id: sessionID, tab: tabID, title: "Stale", updatedAt: date(10), state: .waitingForQuestion, parent: coordinatorID)
            ],
            resolvableTabs: [uuid(110), tabID],
            demoCoordinatorIDs: [coordinatorID]
        ))
        let row = allRows(in: snapshot).first

        XCTAssertTrue(snapshot.pendingInteractions.isEmpty)
        XCTAssertNil(row?.pendingInteraction)
        XCTAssertEqual(row?.statusGroup, .done)
    }

    func testAssistantProseAndStreamingTextDoesNotCreatePendingButRefreshesProgressFingerprint() {
        let coordinatorID = uuid(10)
        let sessionID = uuid(1)
        let tabID = uuid(101)
        let coordinator = live(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle)
        let liveSession = live(id: sessionID, tab: tabID, title: "Mentions decision", updatedAt: date(10), state: .running, parent: coordinatorID)
        let first = projector.project(input(
            live: [coordinator, liveSession],
            mcpSnapshots: [sessionID: mcpSnapshot(sessionID: sessionID, tabID: tabID, assistantPreview: "Please decide yes or no", interaction: nil)],
            demoCoordinatorIDs: [coordinatorID]
        ))
        let second = projector.project(input(
            live: [coordinator, liveSession],
            mcpSnapshots: [sessionID: mcpSnapshot(sessionID: sessionID, tabID: tabID, assistantPreview: "Please decide yes or no. More streamed text.", interaction: nil)],
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertTrue(first.pendingInteractions.isEmpty)
        XCTAssertTrue(second.pendingInteractions.isEmpty)
        XCTAssertEqual(allRows(in: first).first?.statusReport?.assistantPreview, "Please decide yes or no")
        XCTAssertEqual(allRows(in: second).first?.statusReport?.assistantPreview, "Please decide yes or no. More streamed text.")
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    func testPersistedOnlyRowsWithoutResolvableTabsDoNotCreateRoutes() {
        let coordinatorID = uuid(10)
        let sessionID = uuid(1)
        let tabID = uuid(101)
        let snapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: uuid(110), title: "Coordinator Runtime Demo", updatedAt: date(20)),
                persisted(id: sessionID, tab: tabID, title: "Archived", updatedAt: date(10), state: .running, parent: coordinatorID)
            ],
            resolvableTabs: [],
            demoCoordinatorIDs: [coordinatorID]
        ))

        let row = allRows(in: snapshot).first
        XCTAssertEqual(row?.sessionID, sessionID)
        XCTAssertEqual(row?.isPersistedOnly, true)
        XCTAssertNil(row?.openAgentChatRoute)
        XCTAssertEqual(row?.statusGroup, .done)
    }

    func testDecisionQueueUsesStablePlanApprovalIDs() {
        let coordinatorID = uuid(1)
        let planID = uuid(50)
        let nodeID = uuid(60)
        let workstreamID = uuid(70)
        let plan = CoordinatorMissionPlan(
            id: planID,
            revision: 2,
            objective: "Approve stable queue",
            status: .draft,
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Implement",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree
                )
            ],
            updatedAt: date(10)
        )

        let first = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle, missionPlan: plan)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))

        let expectedID = CoordinatorMissionStableIdentity.uuid(
            namespace: "coordinator-mode-decision-plan-approval",
            parts: [
                coordinatorID.uuidString,
                planID.uuidString,
                "r2",
                "coordinator:\(coordinatorID.uuidString):plan-approval:r2"
            ]
        )
        XCTAssertEqual(first.decisionQueue.map(\.source), [.planApproval])
        XCTAssertEqual(first.decisionQueue.first?.id, expectedID)
        XCTAssertEqual(first.decisionQueue.first?.planID, planID)
        XCTAssertEqual(first.decisionQueue.first?.planRevision, 2)

        var retitled = plan
        retitled.objective = "Retitled without identity churn"
        retitled.updatedAt = date(40)
        let second = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(50), state: .idle, missionPlan: retitled)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertEqual(second.decisionQueue.first?.id, expectedID)

        var revised = retitled
        revised.revision = 3
        let third = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(60), state: .idle, missionPlan: revised)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertNotEqual(third.decisionQueue.first?.id, expectedID)
    }

    func testDecisionQueueOrdersFIFOThenStableID() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let reviewID = uuid(3)
        let planID = uuid(50)
        let holdID = uuid(51)
        let interactionID = uuid(52)
        let merge = mergeSummary(id: "merge-review", status: .previewed, conflicts: 0, updatedAt: date(40))
        let plan = CoordinatorMissionPlan(
            id: planID,
            revision: 1,
            objective: "Order decisions",
            status: .running,
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: uuid(60),
                    title: "Implementation",
                    workstreamID: uuid(70),
                    executionPolicy: .freshWorktree
                )
            ],
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    id: holdID,
                    timestamp: date(10),
                    decision: .holdForUser,
                    operation: .coordinatorHold,
                    reason: "Ask before mutable follow-through."
                )
            ],
            updatedAt: date(30)
        )
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: interactionID,
            kind: .question,
            responseType: .structured,
            title: "Answer child",
            prompt: "Choose next step.",
            context: nil,
            allowsMultiple: nil,
            options: [],
            fields: [],
            details: []
        )

        let snapshot = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(100), state: .idle, missionPlan: plan),
                live(id: childID, tab: uuid(102), title: "Child", updatedAt: date(20), state: .waitingForQuestion, parent: coordinatorID),
                live(id: reviewID, tab: uuid(103), title: "Review", updatedAt: date(35), state: .completed, parent: coordinatorID, merges: [merge])
            ],
            mcpSnapshots: [
                childID: mcpSnapshot(
                    sessionID: childID,
                    tabID: uuid(102),
                    status: .waitingForInput,
                    interaction: interaction,
                    parent: coordinatorID
                )
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertEqual(snapshot.decisionQueue.map(\.source), [
            .followThroughBoundary,
            .interaction,
            .planApproval
        ])
        XCTAssertEqual(snapshot.decisionQueue.map(\.waitingSince), [date(10), date(20), date(30)])
        XCTAssertTrue(snapshot.decisionQueue.contains { $0.source == .interaction && $0.id == interactionID })
        XCTAssertFalse(snapshot.decisionQueue.contains { $0.source == .review })

        let sameAgePlan = CoordinatorMissionPlan(
            id: planID,
            revision: 1,
            objective: "Stable tie-break",
            status: .running,
            approvalState: .notRequired,
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    id: uuid(80),
                    timestamp: date(10),
                    decision: .holdForUser,
                    operation: .coordinatorHold,
                    reason: "First hold."
                ),
                CoordinatorMissionRoutingDecision(
                    id: uuid(81),
                    timestamp: date(10),
                    decision: .holdForUser,
                    operation: .coordinatorHold,
                    reason: "Second hold."
                )
            ],
            updatedAt: date(10)
        )
        let tied = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(100), state: .idle, missionPlan: sameAgePlan)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertEqual(tied.decisionQueue.map(\.id), tied.decisionQueue.map(\.id).sorted { $0.uuidString < $1.uuidString })
    }

    func testDecisionQueueExcludesCompletedStoppedAndResolvedPlans() {
        let coordinatorID = uuid(1)
        let workstreamID = uuid(70)
        let nodeID = uuid(60)
        let interactionID = uuid(90)
        let basePlan = CoordinatorMissionPlan(
            id: uuid(50),
            revision: 1,
            objective: "Approval exclusions",
            status: .completed,
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Implementation",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .blocked,
                    boundInteractionID: interactionID
                )
            ],
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    id: uuid(80),
                    timestamp: date(12),
                    nodeID: nodeID,
                    workstreamID: workstreamID,
                    decision: .holdForUser,
                    operation: .coordinatorHold,
                    reason: "Ask before mutable follow-through."
                )
            ],
            updatedAt: date(10)
        )

        let completed = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle, missionPlan: basePlan)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertFalse(completed.decisionQueue.contains { $0.source == .planApproval })
        XCTAssertFalse(completed.decisionQueue.contains { $0.source == .followThroughBoundary })
        XCTAssertFalse(completed.decisionQueue.contains { $0.source == .blockedUserAction })

        var stoppedPlan = basePlan
        stoppedPlan.status = .stopped
        let stopped = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle, missionPlan: stoppedPlan)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertFalse(stopped.decisionQueue.contains { $0.source == .planApproval })
        XCTAssertFalse(stopped.decisionQueue.contains { $0.source == .followThroughBoundary })
        XCTAssertFalse(stopped.decisionQueue.contains { $0.source == .blockedUserAction })

        var approvedPlan = basePlan
        approvedPlan.status = .running
        approvedPlan.approvalState = .approved
        let approved = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle, missionPlan: approvedPlan)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertFalse(approved.decisionQueue.contains { $0.source == .planApproval })

        let noNodePlan = CoordinatorMissionPlan(
            id: uuid(51),
            revision: 1,
            objective: "No actionable checkpoint yet",
            status: .running,
            approvalState: .awaitingApproval,
            updatedAt: date(10)
        )
        let noNode = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle, missionPlan: noNodePlan)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertFalse(noNode.decisionQueue.contains { $0.source == .planApproval })
    }

    func testHeldBoundaryDecisionIDTracksPlanRevisionNotRoutingID() {
        let coordinatorID = uuid(1)
        let nodeID = uuid(60)
        let workstreamID = uuid(70)
        let planID = uuid(50)
        let routingID = uuid(80)
        let plan = CoordinatorMissionPlan(
            id: planID,
            revision: 1,
            objective: "Hold identity",
            status: .running,
            approvalState: .approved,
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    id: routingID,
                    timestamp: date(10),
                    nodeID: nodeID,
                    workstreamID: workstreamID,
                    decision: .holdForUser,
                    operation: .coordinatorHold,
                    reason: "Ask before mutable follow-through."
                )
            ],
            updatedAt: date(20)
        )

        let first = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(30), state: .idle, missionPlan: plan)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        let expectedID = CoordinatorMissionStableIdentity.uuid(
            namespace: "coordinator-mode-decision-held-boundary",
            parts: [
                coordinatorID.uuidString,
                planID.uuidString,
                "held-checkpoint",
                "r1",
                "node:\(nodeID.uuidString)"
            ]
        )
        XCTAssertEqual(first.decisionQueue.first?.source, .followThroughBoundary)
        XCTAssertEqual(first.decisionQueue.first?.id, expectedID)

        var sameRevisionNewRouting = plan
        sameRevisionNewRouting.routingDecisions = [
            CoordinatorMissionRoutingDecision(
                id: uuid(81),
                timestamp: date(10),
                nodeID: nodeID,
                workstreamID: workstreamID,
                decision: .holdForUser,
                operation: .coordinatorHold,
                reason: "Ask before mutable follow-through."
            )
        ]
        let sameRevision = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(40), state: .idle, missionPlan: sameRevisionNewRouting)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertEqual(sameRevision.decisionQueue.first?.id, expectedID)

        var revised = sameRevisionNewRouting
        revised.revision = 2
        let secondRevision = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(50), state: .idle, missionPlan: revised)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertNotEqual(secondRevision.decisionQueue.first?.id, expectedID)
    }

    func testDecisionQueueExcludesPersistedOnlyStoppedMissionInteractions() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let interactionID = uuid(52)
        let stoppedPlan = CoordinatorMissionPlan(
            id: uuid(50),
            revision: 3,
            objective: "Stopped persisted mission",
            status: .stopped,
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: uuid(60),
                    title: "Old approval",
                    workstreamID: uuid(70),
                    executionPolicy: .freshWorktree
                )
            ],
            updatedAt: date(10)
        )
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: interactionID,
            kind: .question,
            responseType: .structured,
            title: "Old child ask",
            prompt: "This should not surface.",
            context: nil,
            allowsMultiple: nil,
            options: [],
            fields: [],
            details: []
        )

        let snapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: uuid(101), title: "Stopped Coordinator", updatedAt: date(20), state: .completed, coordinatorRuntime: true, missionPlan: stoppedPlan),
                persisted(id: childID, tab: uuid(102), title: "Old child", updatedAt: date(15), state: .waitingForQuestion, parent: coordinatorID)
            ],
            mcpSnapshots: [
                childID: mcpSnapshot(
                    sessionID: childID,
                    tabID: uuid(102),
                    status: .waitingForInput,
                    interaction: interaction,
                    parent: coordinatorID
                )
            ],
            selectedCoordinatorID: nil,
            demoCoordinatorIDs: [coordinatorID]
        ))

        XCTAssertTrue(snapshot.decisionQueue.isEmpty)
    }

    func testDecisionQueueExcludesTelemetryBlockedNodes() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let workstreamID = uuid(70)
        let telemetryBlockedPlan = CoordinatorMissionPlan(
            id: uuid(50),
            revision: 1,
            objective: "Telemetry only blockers",
            status: .blocked,
            approvalState: .approved,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: uuid(60),
                    title: "Dependency waiting",
                    workstreamID: workstreamID,
                    dependsOn: [uuid(61)],
                    executionPolicy: .freshReadOnlyChild,
                    status: .pending
                ),
                CoordinatorMissionPlanNode(
                    id: uuid(62),
                    title: "Blocked without explicit interaction",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .blocked
                )
            ],
            updatedAt: date(10)
        )

        let telemetryOnly = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle, missionPlan: telemetryBlockedPlan),
                live(id: childID, tab: uuid(102), title: "Failed child", updatedAt: date(15), state: .failed, parent: coordinatorID)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertTrue(telemetryOnly.decisionQueue.isEmpty)

        let interactionID = uuid(90)
        var explicitBlockedPlan = telemetryBlockedPlan
        explicitBlockedPlan.nodes[1] = CoordinatorMissionPlanNode(
            id: uuid(62),
            title: "Blocked on user decision",
            workstreamID: workstreamID,
            executionPolicy: .freshWorktree,
            status: .blocked,
            boundSessionID: childID,
            boundInteractionID: interactionID
        )
        let explicitBlocked = projector.project(input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator Runtime Demo", updatedAt: date(20), state: .idle, missionPlan: explicitBlockedPlan)
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        ))
        XCTAssertEqual(explicitBlocked.decisionQueue.map(\.source), [.blockedUserAction])
        XCTAssertEqual(explicitBlocked.decisionQueue.first?.interactionID, interactionID)
    }

    func testMCPCompactProjectionCoversOffEmptyIdleAndActiveStates() {
        let off = projector.project(input(dashboard: dashboard(isRunning: false)))
        XCTAssertEqual(off.mcpAwareness.state, .off)

        let empty = projector.project(input(dashboard: dashboard(isRunning: true)))
        XCTAssertEqual(empty.mcpAwareness.state, .empty)
        XCTAssertEqual(empty.mcpAwareness.connectedClientCount, 0)
        XCTAssertTrue(empty.mcpAwareness.recentToolCalls.isEmpty)

        let historyOnly = projector.project(input(dashboard: dashboard(
            isRunning: true,
            recentToolCalls: [toolCall(name: "list_agents", client: "Codex", at: date(9))]
        )))
        XCTAssertEqual(historyOnly.mcpAwareness.state, .idle)
        XCTAssertEqual(historyOnly.mcpAwareness.connectedClientCount, 0)
        XCTAssertEqual(historyOnly.mcpAwareness.inFlightToolCallCount, 0)
        XCTAssertEqual(historyOnly.mcpAwareness.recentToolCalls.first?.toolName, "list_agents")

        let idle = projector.project(input(dashboard: dashboard(
            isRunning: true,
            connections: [connection(name: "Claude")],
            recentToolCalls: [toolCall(name: "read_file", client: "Claude", at: date(10))]
        )))
        XCTAssertEqual(idle.mcpAwareness.state, .idle)
        XCTAssertEqual(idle.mcpAwareness.connectedClientCount, 1)
        XCTAssertEqual(idle.mcpAwareness.idleClientCount, 1)
        XCTAssertEqual(idle.mcpAwareness.recentToolCalls.first?.toolName, "read_file")

        let active = projector.project(input(dashboard: dashboard(
            isRunning: true,
            connections: [connection(name: "Codex", inFlight: true, scopes: [ConnectionDashboardActiveToolScope(windowID: 7, toolName: "apply_edits", sequence: 1)])]
        )))
        XCTAssertEqual(active.mcpAwareness.state, .active)
        XCTAssertEqual(active.mcpAwareness.activeClientCount, 1)
        XCTAssertEqual(active.mcpAwareness.inFlightToolCallCount, 2)
    }

    private func input(
        workspaceID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000090"),
        persisted: [CoordinatorModeSnapshotProjector.PersistedSession] = [],
        live: [CoordinatorModeSnapshotProjector.LiveSession] = [],
        mcpSnapshots: [UUID: AgentRunMCPSnapshot] = [:],
        dashboard: MCPService.DashboardSnapshot? = nil,
        detection: [CoordinatorModeSnapshotProjector.CoordinatorDetectionSession] = [],
        selectedCoordinatorID: UUID? = nil,
        autoSelectDemoCoordinator: Bool = true,
        sort: CoordinatorModeSortMode = .lastUpdated,
        boardScope: CoordinatorModeBoardScope = .coordinatorFleet,
        resolvableTabs: Set<UUID>? = nil,
        demoCoordinatorIDs: Set<UUID> = [],
        coordinatorInternalIDs: Set<UUID> = []
    ) -> CoordinatorModeSnapshotProjector.Input {
        let tabs = resolvableTabs ?? Set(persisted.map(\.tabID) + live.map(\.tabID))
        let resolvedSelectedCoordinatorID = selectedCoordinatorID ?? (autoSelectDemoCoordinator ? newestDemoCoordinatorID(
            demoCoordinatorIDs,
            persisted: persisted,
            live: live,
            detection: detection,
            mcpSnapshots: mcpSnapshots
        ) : nil)
        return CoordinatorModeSnapshotProjector.Input(
            workspaceID: workspaceID,
            windowID: 7,
            persistedSessions: persisted,
            liveSessions: live,
            mcpSnapshotsBySessionID: mcpSnapshots,
            dashboard: dashboard,
            coordinatorDetectionSessions: detection,
            selectedCoordinatorID: resolvedSelectedCoordinatorID,
            sortMode: sort,
            boardScope: boardScope,
            resolvableTabIDs: tabs,
            demoCoordinatorSessionIDs: demoCoordinatorIDs,
            coordinatorInternalSessionIDs: coordinatorInternalIDs
        )
    }

    private func newestDemoCoordinatorID(
        _ ids: Set<UUID>,
        persisted: [CoordinatorModeSnapshotProjector.PersistedSession],
        live: [CoordinatorModeSnapshotProjector.LiveSession],
        detection: [CoordinatorModeSnapshotProjector.CoordinatorDetectionSession],
        mcpSnapshots: [UUID: AgentRunMCPSnapshot]
    ) -> UUID? {
        ids.max { lhs, rhs in
            let lhsDate = coordinatorDate(lhs, persisted: persisted, live: live, detection: detection, mcpSnapshots: mcpSnapshots)
            let rhsDate = coordinatorDate(rhs, persisted: persisted, live: live, detection: detection, mcpSnapshots: mcpSnapshots)
            if lhsDate == rhsDate { return lhs.uuidString < rhs.uuidString }
            return lhsDate < rhsDate
        }
    }

    private func coordinatorDate(
        _ id: UUID,
        persisted: [CoordinatorModeSnapshotProjector.PersistedSession],
        live: [CoordinatorModeSnapshotProjector.LiveSession],
        detection: [CoordinatorModeSnapshotProjector.CoordinatorDetectionSession],
        mcpSnapshots: [UUID: AgentRunMCPSnapshot]
    ) -> Date {
        [
            live.first { $0.sessionID == id }?.updatedAt,
            persisted.first { $0.id == id }?.updatedAt,
            detection.first { $0.id == id }?.updatedAt,
            mcpSnapshots[id]?.updatedAt
        ]
        .compactMap(\.self)
        .max() ?? .distantPast
    }

    private func persisted(
        id: UUID,
        tab: UUID,
        title: String,
        updatedAt: Date,
        state: AgentSessionRunState? = .idle,
        parent: UUID? = nil,
        isMCP: Bool = false,
        workflow: CoordinatorModeWorkflowDisplaySummary? = nil,
        internalSession: Bool = false,
        coordinatorRuntime: Bool = false,
        pinned: Bool = false,
        priority: Int? = nil,
        bindings: [AgentSessionWorktreeBindingSummary] = [],
        merges: [AgentSessionWorktreeMergeSummary] = [],
        missionTemplate: CoordinatorMissionTemplateSummary? = nil,
        missionPlan: CoordinatorMissionPlan? = nil
    ) -> CoordinatorModeSnapshotProjector.PersistedSession {
        CoordinatorModeSnapshotProjector.PersistedSession(
            id: id,
            tabID: tab,
            title: title,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP,
            worktreeBindingSummaries: bindings,
            activeWorktreeMergeSummaries: merges,
            workflow: workflow,
            isCoordinatorInternal: internalSession,
            isCoordinatorRuntime: coordinatorRuntime,
            isPinned: pinned,
            coordinatorMissionTemplate: missionTemplate,
            coordinatorMissionPlan: missionPlan,
            priority: priority
        )
    }

    private func live(
        id: UUID,
        tab: UUID,
        title: String,
        updatedAt: Date,
        state: AgentSessionRunState,
        parent: UUID? = nil,
        isMCP: Bool = false,
        workflow: CoordinatorModeWorkflowDisplaySummary? = nil,
        internalSession: Bool = false,
        coordinatorRuntime: Bool = false,
        pinned: Bool = false,
        priority: Int? = nil,
        bindings: [AgentSessionWorktreeBindingSummary] = [],
        merges: [AgentSessionWorktreeMergeSummary] = [],
        missionTemplate: CoordinatorMissionTemplateSummary? = nil,
        missionPlan: CoordinatorMissionPlan? = nil
    ) -> CoordinatorModeSnapshotProjector.LiveSession {
        CoordinatorModeSnapshotProjector.LiveSession(
            sessionID: id,
            tabID: tab,
            title: title,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP,
            worktreeBindingSummaries: bindings,
            activeWorktreeMergeSummaries: merges,
            workflow: workflow,
            isCoordinatorInternal: internalSession,
            isCoordinatorRuntime: coordinatorRuntime,
            isPinned: pinned,
            coordinatorMissionTemplate: missionTemplate,
            coordinatorMissionPlan: missionPlan,
            priority: priority
        )
    }

    private func detection(
        id: UUID,
        title: String,
        updatedAt: Date,
        parent: UUID? = nil,
        isMCP: Bool = false,
        workflow: CoordinatorModeWorkflowDisplaySummary? = nil,
        internalSession: Bool = false,
        coordinatorRuntime: Bool = false,
        pinned: Bool = false,
        missionTemplate: CoordinatorMissionTemplateSummary? = nil,
        missionPlan: CoordinatorMissionPlan? = nil
    ) -> CoordinatorModeSnapshotProjector.CoordinatorDetectionSession {
        CoordinatorModeSnapshotProjector.CoordinatorDetectionSession(
            id: id,
            title: title,
            updatedAt: updatedAt,
            parentSessionID: parent,
            isMCPOriginated: isMCP,
            workflow: workflow,
            isCoordinatorInternal: internalSession,
            isCoordinatorRuntime: coordinatorRuntime,
            isPinned: pinned,
            coordinatorMissionTemplate: missionTemplate,
            coordinatorMissionPlan: missionPlan
        )
    }

    private func binding(
        visualLabel: String? = "Visual",
        worktreeName: String? = "Worktree",
        logicalRootName: String? = "Root",
        branch: String? = "main",
        repoKey: String = "repo"
    ) -> AgentSessionWorktreeBindingSummary {
        AgentSessionWorktreeBindingSummary(
            id: UUID().uuidString,
            repositoryID: "repo-id",
            repoKey: repoKey,
            logicalRootPath: "/tmp/Repo",
            logicalRootName: logicalRootName,
            worktreeID: "wt-id",
            worktreeRootPath: "/tmp/Repo-wt",
            worktreeName: worktreeName,
            branch: branch,
            visualLabel: visualLabel,
            visualColorHex: "#abcdef",
            boundAt: date(0)
        )
    }

    private func mergeSummary(
        id: String,
        status: AgentSessionWorktreeMergeOperation.Status,
        conflicts: Int,
        updatedAt: Date
    ) -> AgentSessionWorktreeMergeSummary {
        AgentSessionWorktreeMergeSummary(
            id: id,
            status: status,
            sourceWorktreeID: "source",
            sourceLabel: "Source",
            sourceBranch: "feature",
            sourcePath: "/tmp/source",
            targetWorktreeID: "target",
            targetLabel: "Target",
            targetBranch: "main",
            targetPath: "/tmp/target",
            repositoryID: "repo-id",
            repoKey: "repo",
            conflictFileCount: conflicts,
            updatedAt: updatedAt
        )
    }

    private func mcpSnapshot(
        sessionID: UUID,
        tabID: UUID,
        sessionName: String = "Session",
        status: AgentRunMCPSnapshot.Status = .running,
        statusText: String? = nil,
        assistantPreview: String? = nil,
        interaction: AgentRunMCPSnapshot.Interaction?,
        failureReason: AgentRunMCPSnapshot.FailureReason? = nil,
        parent: UUID? = nil
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: tabID,
            sessionName: sessionName,
            agentRaw: nil,
            agentDisplayName: nil,
            modelRaw: nil,
            reasoningEffortRaw: nil,
            status: status,
            statusText: statusText,
            latestAssistantPreview: assistantPreview,
            interaction: interaction,
            transcriptItemCount: 10,
            updatedAt: date(20),
            parentSessionID: parent,
            failureReason: failureReason,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }

    private func dashboard(
        isRunning: Bool,
        connections: [MCPService.DashboardConnection] = [],
        recentToolCalls: [MCPService.ToolCallHistoryEntry] = []
    ) -> MCPService.DashboardSnapshot {
        MCPService.DashboardSnapshot(
            isRunning: isRunning,
            diagnostics: MCPDiagnostics(),
            connections: connections,
            recentToolCalls: recentToolCalls,
            alwaysAllowedClients: [],
            autoApproveAllClients: false
        )
    }

    private func connection(
        name: String,
        inFlight: Bool = false,
        scopes: [ConnectionDashboardActiveToolScope] = []
    ) -> MCPService.DashboardConnection {
        MCPService.DashboardConnection(
            id: UUID(),
            clientName: name,
            windowID: 7,
            transport: .filesystem,
            state: .ready,
            createdAt: date(0),
            lastToolCallAt: nil,
            totalToolCalls: 0,
            idleSeconds: inFlight ? nil : 5,
            hasInFlightCalls: inFlight,
            activeToolScope: scopes.first,
            activeToolScopes: scopes,
            sessionKey: nil
        )
    }

    private func toolCall(name: String, client: String, at: Date) -> MCPService.ToolCallHistoryEntry {
        MCPService.ToolCallHistoryEntry(timestamp: at, toolName: name, clientName: client)
    }

    private func rows(in snapshot: CoordinatorModeSnapshot, group: CoordinatorModeStatusGroup) -> [CoordinatorModeRow] {
        snapshot.groups.first { $0.group == group }?.rows ?? []
    }

    private func allRows(in snapshot: CoordinatorModeSnapshot) -> [CoordinatorModeRow] {
        snapshot.groups.flatMap(\.rows)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
