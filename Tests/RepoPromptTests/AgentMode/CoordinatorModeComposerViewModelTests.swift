@testable import RepoPrompt
import XCTest

private extension CoordinatorModeWorkflowDisplaySummary {
    static let orchestrate = CoordinatorModeWorkflowDisplaySummary(AgentWorkflow.orchestrate.definition)
}

@MainActor
final class CoordinatorModeComposerViewModelTests: XCTestCase {
    func testColdOpenStartsAsDraftAndFirstSendCreatesCoordinatorRuntime() async {
        let coordinatorID = uuid(1)
        var liveSessions: [CoordinatorModeSnapshotProjector.LiveSession] = []
        var demoCoordinatorIDs: Set<UUID> = []
        var submissions: [(text: String, sessionID: UUID?, forceNewRuntime: Bool)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode,
                    demoCoordinatorIDs: demoCoordinatorIDs
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append((submission.providerText, submission.coordinatorSessionID, submission.forceNewRuntime))
                liveSessions = [
                    self.live(id: coordinatorID, tab: self.uuid(101), title: "New coordinator", updatedAt: self.date(30), state: .idle, isMCP: true)
                ]
                demoCoordinatorIDs.insert(coordinatorID)
                return .accepted
            }
        )

        viewModel.refresh()

        XCTAssertEqual(viewModel.snapshot.coordinatorRail.state, .chooseCoordinator)

        let result = await viewModel.submitCoordinatorDirective("start scoped work")

        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(submissions.first?.text.hasPrefix("start scoped work\n\n---\nMission Policy (provider-only)") == true)
        XCTAssertTrue(submissions.first?.text.contains("Max concurrent child sessions: 3") == true)
        XCTAssertTrue(submissions.first?.text.contains("Standing guidance: Keep every boundary visible while trust is earned.") == true)
        XCTAssertNil(submissions.first?.sessionID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, true)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
    }

    func testRailDestinationTransitionsUseBoardWithoutClearingSelectedMission() {
        let firstCoordinatorID = uuid(1)
        let secondCoordinatorID = uuid(2)
        let liveSessions = [
            live(
                id: firstCoordinatorID,
                tab: uuid(101),
                title: "First mission",
                updatedAt: date(10),
                state: .idle,
                isMCP: true,
                coordinatorRuntime: true
            ),
            live(
                id: secondCoordinatorID,
                tab: uuid(102),
                title: "Second mission",
                updatedAt: date(20),
                state: .idle,
                isMCP: true,
                coordinatorRuntime: true
            )
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode
                )
            },
            dashboardVisibilityHandler: { _ in }
        )
        viewModel.refresh()

        viewModel.selectCoordinator(sessionID: firstCoordinatorID)
        XCTAssertEqual(viewModel.railDestination, .mission)
        XCTAssertEqual(viewModel.boardScope, .coordinatorFleet)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, firstCoordinatorID)

        viewModel.showBoardDestination()
        XCTAssertEqual(viewModel.railDestination, .board)
        XCTAssertEqual(viewModel.boardScope, .allAgents)
        XCTAssertEqual(viewModel.snapshot.boardScope, .allAgents)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, firstCoordinatorID)

        viewModel.showDecisionsDestination()
        XCTAssertEqual(viewModel.railDestination, .decisions)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, firstCoordinatorID)

        viewModel.selectCoordinator(sessionID: secondCoordinatorID)
        XCTAssertEqual(viewModel.railDestination, .mission)
        XCTAssertEqual(viewModel.boardScope, .coordinatorFleet)
        XCTAssertEqual(viewModel.snapshot.boardScope, .coordinatorFleet)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, secondCoordinatorID)
    }

    func testStartingDraftReturnsToMissionDestination() {
        let coordinatorID = uuid(1)
        let liveSessions = [
            live(
                id: coordinatorID,
                tab: uuid(101),
                title: "Mission",
                updatedAt: date(10),
                state: .idle,
                isMCP: true,
                coordinatorRuntime: true
            )
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode
                )
            },
            dashboardVisibilityHandler: { _ in }
        )
        viewModel.refresh()
        viewModel.selectCoordinator(sessionID: coordinatorID)
        viewModel.showBoardDestination()

        viewModel.startNewCoordinatorRun()

        XCTAssertEqual(viewModel.railDestination, .mission)
        XCTAssertEqual(viewModel.boardScope, .coordinatorFleet)
        XCTAssertEqual(viewModel.snapshot.boardScope, .coordinatorFleet)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.state, .chooseCoordinator)
    }

    func testInitialCoordinatorDirectiveUsesRawTextWithoutMissionTemplate() async {
        var submissions: [(text: String, sessionID: UUID?, forceNewRuntime: Bool, template: CoordinatorMissionTemplateSummary?)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append((
                    submission.providerText,
                    submission.coordinatorSessionID,
                    submission.forceNewRuntime,
                    submission.missionTemplate
                ))
                return .accepted
            }
        )
        viewModel.refresh()

        let result = await viewModel.submitCoordinatorDirective("fix flaky docs tests")

        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(submissions.first?.text.hasPrefix("fix flaky docs tests") == true)
        XCTAssertTrue(submissions.first?.text.contains("Mission Policy (provider-only)") == true)
        XCTAssertNil(submissions.first?.sessionID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, true)
        XCTAssertNil(submissions.first?.template)
        XCTAssertEqual(viewModel.railTranscriptEntries.first?.text, "fix flaky docs tests")
    }

    func testFreshMissionAndFollowUpStayRawWithoutMissionTemplate() async {
        let coordinatorID = uuid(1)
        var liveSessions: [CoordinatorModeSnapshotProjector.LiveSession] = []
        var demoCoordinatorIDs: Set<UUID> = []
        var submissions: [CoordinatorDirectiveSubmission] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode,
                    demoCoordinatorIDs: demoCoordinatorIDs
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append(submission)
                if submission.forceNewRuntime {
                    liveSessions = [
                        self.live(id: coordinatorID, tab: self.uuid(101), title: "Coordinator", updatedAt: self.date(30), state: .idle, isMCP: true)
                    ]
                    demoCoordinatorIDs.insert(coordinatorID)
                }
                return .accepted
            }
        )
        viewModel.refresh()

        let freshResult = await viewModel.submitCoordinatorDirective("  start mission  ")
        let followUpResult = await viewModel.submitCoordinatorDirective("  follow up  ")

        XCTAssertEqual(freshResult, .accepted)
        XCTAssertEqual(followUpResult, .accepted)
        XCTAssertEqual(submissions.map(\.visibleText), ["start mission", "follow up"])
        XCTAssertTrue(submissions.first?.providerText.hasPrefix("start mission\n\n---\nMission Policy (provider-only)") == true)
        XCTAssertEqual(submissions.last?.providerText, "follow up")
        XCTAssertNil(submissions.first?.missionTemplate)
        XCTAssertNil(submissions.last?.missionTemplate)
        XCTAssertEqual(viewModel.railTranscriptEntries.filter { $0.role == .user }.map(\.text), ["start mission", "follow up"])
    }

    func testFreshMissionPolicyInjectsProviderTextAndCapturesSnapshot() async throws {
        let coordinatorID = uuid(1)
        var liveSessions: [CoordinatorModeSnapshotProjector.LiveSession] = []
        var demoCoordinatorIDs: Set<UUID> = []
        var state = CoordinatorFollowThroughState()
        var submissions: [CoordinatorDirectiveSubmission] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode,
                    demoCoordinatorIDs: demoCoordinatorIDs
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append(submission)
                liveSessions = [
                    self.live(
                        id: coordinatorID,
                        tab: self.uuid(101),
                        title: "Director",
                        updatedAt: self.date(30),
                        state: .idle,
                        isMCP: true,
                        coordinatorRuntime: true,
                        missionPlan: state.missionPlan
                    )
                ]
                demoCoordinatorIDs.insert(coordinatorID)
                return .accepted
            },
            missionPlanUpdater: { sessionID, update in
                XCTAssertEqual(sessionID, coordinatorID)
                state.updateMissionPlan(update)
                liveSessions = [
                    self.live(
                        id: coordinatorID,
                        tab: self.uuid(101),
                        title: "Director",
                        updatedAt: self.date(31),
                        state: .idle,
                        isMCP: true,
                        coordinatorRuntime: true,
                        missionPlan: state.missionPlan
                    )
                ]
            }
        )
        viewModel.selectedMissionPolicy = .readOnly
        viewModel.refresh()

        let result = await viewModel.submitCoordinatorDirective("Audit risky scripts")

        XCTAssertEqual(result, .accepted)
        let submission = try XCTUnwrap(submissions.first)
        XCTAssertEqual(submission.visibleText, "Audit risky scripts")
        XCTAssertTrue(submission.providerText.hasPrefix("Audit risky scripts\n\n---\nMission Policy (provider-only)"))
        XCTAssertTrue(submission.providerText.contains("Policy: Read-only [read-only]"))
        XCTAssertTrue(submission.providerText.contains("Definition of Done: A written report of the findings. No code changes."))
        XCTAssertTrue(submission.providerText.contains("Standing guidance: Keep the Mission read-only and report findings clearly."))
        XCTAssertEqual(submission.missionPolicySnapshot, .readOnly)
        XCTAssertEqual(state.missionPlan?.objective, "Audit risky scripts")
        XCTAssertEqual(state.missionPlan?.policySnapshot, .readOnly)
        XCTAssertEqual(state.missionPlan?.autonomy, CoordinatorMissionPolicySnapshot.readOnly.autonomy)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.missionSummary?.policy?.name, "Read-only")
        XCTAssertEqual(viewModel.railTranscriptEntries.first(where: { $0.role == .user })?.text, "Audit risky scripts")
        XCTAssertEqual(viewModel.selectedMissionPolicy, .defaultPolicy)
    }

    func testFreshMissionDialsAreCapturedInProviderTextAndPolicySnapshot() async throws {
        let coordinatorID = uuid(1)
        var liveSessions: [CoordinatorModeSnapshotProjector.LiveSession] = []
        var demoCoordinatorIDs: Set<UUID> = []
        var state = CoordinatorFollowThroughState()
        var submissions: [CoordinatorDirectiveSubmission] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode,
                    demoCoordinatorIDs: demoCoordinatorIDs
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append(submission)
                liveSessions = [
                    self.live(
                        id: coordinatorID,
                        tab: self.uuid(101),
                        title: "Director",
                        updatedAt: self.date(30),
                        state: .idle,
                        isMCP: true,
                        coordinatorRuntime: true,
                        missionPlan: state.missionPlan
                    )
                ]
                demoCoordinatorIDs.insert(coordinatorID)
                return .accepted
            },
            missionPlanUpdater: { sessionID, update in
                XCTAssertEqual(sessionID, coordinatorID)
                state.updateMissionPlan(update)
                liveSessions = [
                    self.live(
                        id: coordinatorID,
                        tab: self.uuid(101),
                        title: "Director",
                        updatedAt: self.date(31),
                        state: .idle,
                        isMCP: true,
                        coordinatorRuntime: true,
                        missionPlan: state.missionPlan
                    )
                ]
            }
        )
        viewModel.refresh()

        viewModel.setExecutionPace(.auto)
        viewModel.setChildAskSelection(.auto)
        let result = await viewModel.submitCoordinatorDirective("Run the smoke mission")

        XCTAssertEqual(result, .accepted)
        let submission = try XCTUnwrap(submissions.first)
        XCTAssertTrue(submission.providerText.contains("Default pace: auto"))
        XCTAssertTrue(submission.providerText.contains("childAsk=auto"))
        XCTAssertEqual(submission.missionPolicySnapshot?.defaultPace, .auto)
        XCTAssertEqual(submission.missionPolicySnapshot?.resolvedAutonomy(for: .childAsk), .auto)
        XCTAssertEqual(state.missionPlan?.policySnapshot?.defaultPace, .auto)
        XCTAssertEqual(state.missionPlan?.policySnapshot?.resolvedAutonomy(for: .childAsk), .auto)
        XCTAssertEqual(state.missionPlan?.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key], .auto)
    }

    func testMissionDialsMutatePlanSnapshotAndRecordLedgerWithoutClearingApprovalCheckpoint() async throws {
        let coordinatorID = uuid(1)
        let childAskAutoEvaluation = expectation(description: "childAsk auto re-evaluates follow-through")
        var evaluatedCoordinatorIDs: [UUID] = []
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Smoke the platform layer",
            status: .running,
            approvalState: .awaitingApproval,
            policySnapshot: .defaultPolicy,
            autonomy: CoordinatorMissionPolicySnapshot.defaultAutonomy
        ))
        var liveSessions = [
            live(
                id: coordinatorID,
                tab: uuid(101),
                title: "Director",
                updatedAt: date(20),
                state: .idle,
                isMCP: true,
                coordinatorRuntime: true,
                missionPlan: state.missionPlan
            )
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            missionPlanUpdater: { sessionID, update in
                XCTAssertEqual(sessionID, coordinatorID)
                state.updateMissionPlan(update)
                liveSessions = [
                    self.live(
                        id: coordinatorID,
                        tab: self.uuid(101),
                        title: "Director",
                        updatedAt: self.date(21),
                        state: .idle,
                        isMCP: true,
                        coordinatorRuntime: true,
                        missionPlan: state.missionPlan
                    )
                ]
            },
            followThroughEvaluationHandler: { sessionID in
                evaluatedCoordinatorIDs.append(sessionID)
                childAskAutoEvaluation.fulfill()
            }
        )
        viewModel.refresh()

        viewModel.setExecutionPace(.auto)
        var plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.policySnapshot?.defaultPace, .auto)
        XCTAssertEqual(plan.approvalState, .awaitingApproval)
        XCTAssertEqual(plan.decisions.last?.label, CoordinatorMissionUserDecisionLabel.setPaceToAuto.rawValue)
        XCTAssertEqual(plan.decisions.last?.actor, .user)

        viewModel.setChildAskSelection(.auto)
        plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.policySnapshot?.resolvedAutonomy(for: .childAsk), .auto)
        XCTAssertEqual(plan.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key], .auto)
        XCTAssertEqual(plan.approvalState, .awaitingApproval)
        XCTAssertEqual(plan.decisions.last?.label, CoordinatorMissionUserDecisionLabel.routedChildQuestionsToDirector.rawValue)
        XCTAssertEqual(plan.decisions.last?.actor, .user)
        await fulfillment(of: [childAskAutoEvaluation], timeout: 1)
        XCTAssertEqual(evaluatedCoordinatorIDs, [coordinatorID])

        let result = await viewModel.setCoordinatorMissionPace(coordinatorSessionID: coordinatorID, pace: .step)
        XCTAssertEqual(result, .accepted)
        plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.policySnapshot?.defaultPace, .step)
        XCTAssertEqual(plan.decisions.last?.label, CoordinatorMissionUserDecisionLabel.setPaceToStep.rawValue)
        XCTAssertEqual(plan.decisions.last?.actor, .user)

        let autonomyResult = await viewModel.setCoordinatorMissionAutonomy(
            coordinatorSessionID: coordinatorID,
            autonomyClassKey: CoordinatorMissionAutonomyClasses.childAsk.key,
            mode: .ask
        )
        XCTAssertEqual(autonomyResult, .accepted)
        plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.policySnapshot?.resolvedAutonomy(for: .childAsk), .ask)
        XCTAssertEqual(plan.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key], .ask)
        XCTAssertEqual(plan.decisions.last?.label, CoordinatorMissionUserDecisionLabel.routedChildQuestionsToMe.rawValue)
        XCTAssertEqual(plan.decisions.last?.actor, .user)
    }

    func testMissionPlanUpdaterRefreshesSelectedCoordinatorSnapshot() throws {
        let coordinatorID = uuid(1)
        let workstream = CoordinatorMissionWorkstreamSummary(
            title: "Docs implementation",
            purpose: "Update README wording.",
            defaultPolicy: .freshWorktree,
            worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
        )
        var missionPlan: CoordinatorMissionPlan?
        var updaterCalls: [(UUID, CoordinatorMissionPlanUpdate)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: missionPlan
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            missionPlanUpdater: { sessionID, update in
                updaterCalls.append((sessionID, update))
                missionPlan = CoordinatorMissionPlan(
                    objective: update.objective,
                    workstreams: update.workstreams ?? []
                )
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        try viewModel.updateMissionPlan(
            coordinatorSessionID: coordinatorID,
            update: CoordinatorMissionPlanUpdate(
                objective: "Ship docs",
                workstreams: [workstream]
            )
        )

        XCTAssertEqual(updaterCalls.first?.0, coordinatorID)
        XCTAssertEqual(updaterCalls.first?.1.objective, "Ship docs")
        XCTAssertEqual(updaterCalls.first?.1.workstreams, [workstream])
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.missionPlan?.objective, "Ship docs")
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.missionPlan?.workstreams.first?.title, "Docs implementation")
    }

    func testStopSelectedCoordinatorMissionCancelsLinkedSessionsAndMarksPlanStopped() async throws {
        let coordinatorID = uuid(1)
        let visibleChildID = uuid(2)
        let planBoundChildID = uuid(3)
        let unrelatedChildID = uuid(4)
        let helperChildID = uuid(5)
        let workstreamID = uuid(20)
        let runningNodeID = uuid(30)
        let blockedNodeID = uuid(31)
        let pendingNodeID = uuid(32)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Issue 298 provider cleanup",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Discovery",
                    purpose: "Map cleanup paths.",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly),
                    primarySessionID: planBoundChildID
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: runningNodeID,
                    title: "Map cleanup entry points",
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: visibleChildID
                ),
                CoordinatorMissionPlanNode(
                    id: blockedNodeID,
                    title: "Resolve cleanup decision",
                    workstreamID: workstreamID,
                    executionPolicy: .coordinatorOnly,
                    status: .blocked,
                    boundSessionID: planBoundChildID
                ),
                CoordinatorMissionPlanNode(
                    id: pendingNodeID,
                    title: "Review cleanup implementation",
                    workstreamID: workstreamID,
                    executionPolicy: .freshSiblingOnSameWorktree,
                    status: .pending
                )
            ]
        ))
        var stopRequests: [CoordinatorMissionStopRequest] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(50),
                            state: .running,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        ),
                        self.live(
                            id: visibleChildID,
                            tab: self.uuid(102),
                            title: "Visible child",
                            updatedAt: self.date(40),
                            state: .running,
                            parent: coordinatorID
                        ),
                        self.live(
                            id: helperChildID,
                            tab: self.uuid(104),
                            title: "Worker helper",
                            updatedAt: self.date(35),
                            state: .running,
                            parent: visibleChildID
                        ),
                        self.live(
                            id: unrelatedChildID,
                            tab: self.uuid(103),
                            title: "Unrelated child",
                            updatedAt: self.date(30),
                            state: .running
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            missionPlanUpdater: { _, update in
                state.updateMissionPlan(update)
            },
            missionStopper: { request in
                stopRequests.append(request)
                return CoordinatorMissionStopResult(
                    requestedSessionIDs: request.sessionIDs,
                    cancelledSessionIDs: [coordinatorID],
                    skippedSessionIDs: [visibleChildID, helperChildID, planBoundChildID]
                )
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        XCTAssertTrue(viewModel.canStopSelectedCoordinatorMission)
        let result = await viewModel.stopSelectedCoordinatorMission()

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(stopRequests.first?.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(stopRequests.first?.sessionIDs, [coordinatorID, visibleChildID, helperChildID, planBoundChildID])
        let stoppedPlan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(stoppedPlan.status, .stopped)
        XCTAssertEqual(stoppedPlan.nodes.map(\.status), [.cancelled, .cancelled, .cancelled])
        XCTAssertTrue(stoppedPlan.routingDecisions.suffix(4).allSatisfy { $0.operation == .agentRunCancel })
        XCTAssertEqual(
            Set(stoppedPlan.routingDecisions.suffix(4).compactMap(\.sessionID)),
            Set([coordinatorID, visibleChildID, helperChildID, planBoundChildID])
        )
        XCTAssertEqual(stoppedPlan.decisions.map(\.label), ["stopped the Mission"])
        XCTAssertEqual(stoppedPlan.decisions.first?.checkpointID, "mission-stop")
        XCTAssertEqual(stoppedPlan.decisions.first?.checkpointInstanceID, "mission-stop:\(coordinatorID.uuidString):r1")
        XCTAssertTrue(viewModel.railTranscriptEntries.contains { entry in
            entry.role == .event
                && entry.text == "Mission stopped. Requested cancellation for 1 active session; skipped 3 inactive or unavailable linked sessions."
        })
    }

    func testPlanCheckpointUserDecisionsAppendThroughMissionUpdaterAndRefresh() async throws {
        let coordinatorID = uuid(1)
        let workstreamID = uuid(20)
        let nodeID = uuid(30)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 3,
            objective: "Ship the plan",
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Implement safely",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree
                )
            ]
        ))
        var submissions: [CoordinatorDirectiveSubmission] = []
        var approvalStatesAtSubmission: [CoordinatorMissionPlanApprovalState?] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                approvalStatesAtSubmission.append(state.missionPlan?.approvalState)
                submissions.append(submission)
                if submission.visibleText.hasPrefix("Revise the plan") {
                    state.updateMissionPlan(CoordinatorMissionPlanUpdate(
                        approvalState: .awaitingApproval,
                        nodes: state.missionPlan?.nodes,
                        updatedAt: self.date(30)
                    ))
                }
                return .accepted
            },
            missionPlanUpdater: { _, update in
                state.updateMissionPlan(update)
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        XCTAssertTrue(state.missionPlan?.decisions.isEmpty == true)
        let revisionResult = await viewModel.submitPlanRevisionDirective("Revise the plan: keep this read-only first.")
        let revisedRevision = try XCTUnwrap(state.missionPlan?.revision)
        let result = await viewModel.submitCoordinatorContinuation(
            .proceed,
            expectedCheckpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r\(revisedRevision)"
        )

        XCTAssertEqual(revisionResult, .accepted)
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(approvalStatesAtSubmission, [.revisionRequested])
        let decisions = try XCTUnwrap(state.missionPlan?.decisions)
        XCTAssertEqual(decisions.map(\.label), ["requested plan revision", "approved the Mission plan"])
        XCTAssertEqual(decisions.map(\.checkpointID), ["plan-approval", "plan-approval"])
        XCTAssertEqual(decisions.first?.checkpointInstanceID, "coordinator:\(coordinatorID.uuidString):plan-approval:r3")
        XCTAssertEqual(decisions.last?.checkpointInstanceID, "coordinator:\(coordinatorID.uuidString):plan-approval:r\(revisedRevision)")
        XCTAssertEqual(state.missionPlan?.approvalState, .approved)
        XCTAssertEqual(state.missionPlan?.status, .running)
        XCTAssertTrue(state.missionPlan?.events.contains(where: { $0.kind == .approved }) == true)
        XCTAssertEqual(state.missionPlan?.postApprovalContinuation?.status, .deferred)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.missionSummary?.decisions.userCount, 2)
    }

    func testPlanCheckpointApprovalDoesNotResumeWhenPersistenceFails() async {
        let coordinatorID = uuid(1)
        let nodeID = uuid(30)
        let state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 3,
            objective: "Ship the plan",
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Implement safely",
                    workstreamID: uuid(40),
                    executionPolicy: .freshWorktree
                )
            ]
        ))
        var submissions: [CoordinatorDirectiveSubmission] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append(submission)
                return .accepted
            },
            missionPlanUpdater: { _, _ in
                throw NSError(domain: "CoordinatorModeComposerViewModelTests", code: 1)
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        let result = await viewModel.submitCoordinatorContinuation(
            .proceed,
            expectedCheckpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r3"
        )

        guard case let .rejected(message) = result else {
            XCTFail("Expected rejected result when approval append fails.")
            return
        }
        XCTAssertTrue(message.contains("could not be recorded"), message)
        XCTAssertTrue(submissions.isEmpty)
    }

    func testApprovedPlanRevisionTransitionsToRevisionRequestedBeforeDispatch() async {
        let coordinatorID = uuid(1)
        let nodeID = uuid(30)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 7,
            objective: "Revise after approval",
            status: .running,
            approvalState: .approved,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Approved work",
                    workstreamID: uuid(40),
                    executionPolicy: .freshWorktree,
                    status: .pending
                )
            ]
        ))
        var approvalStatesAtSubmission: [CoordinatorMissionPlanApprovalState?] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { _ in
                approvalStatesAtSubmission.append(state.missionPlan?.approvalState)
                return .accepted
            },
            missionPlanUpdater: { _, update in
                state.updateMissionPlan(update)
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        let result = await viewModel.submitPlanRevisionDirective("Revise the plan: split the approved work.")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(approvalStatesAtSubmission, [.revisionRequested])
        XCTAssertEqual(state.missionPlan?.approvalState, .revisionRequested)
        XCTAssertEqual(state.missionPlan?.decisions.map(\.label), ["requested plan revision"])
        XCTAssertEqual(state.missionPlan?.decisions.first?.checkpointInstanceID, "coordinator:\(coordinatorID.uuidString):plan-revision:r7")
    }

    func testPlanCheckpointApprovalPersistsDurableHandoffWithoutImmediateMidRunResume() async throws {
        let coordinatorID = uuid(1)
        let nodeID = uuid(30)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 3,
            objective: "Ship the plan",
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Implement safely",
                    workstreamID: uuid(40),
                    executionPolicy: .freshWorktree
                )
            ]
        ))
        var submissions: [CoordinatorDirectiveSubmission] = []
        var barrierTokens: [CoordinatorModeViewModel.PostApprovalContinuationPersistenceToken] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append(submission)
                return .rejected(message: "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary.")
            },
            missionPlanUpdater: { _, update in
                state.updateMissionPlan(update)
            },
            postApprovalContinuationPersistenceBarrier: { token in
                barrierTokens.append(token)
                XCTAssertEqual(token.coordinatorSessionID, coordinatorID)
                XCTAssertEqual(token.checkpointInstanceID, "coordinator:\(coordinatorID.uuidString):plan-approval:r3")
                XCTAssertEqual(token.planRevision, 3)
                XCTAssertGreaterThan(state.missionPlan?.revision ?? 0, token.planRevision)
                XCTAssertEqual(state.missionPlan?.approvalState, .approved)
                XCTAssertEqual(state.missionPlan?.postApprovalContinuation?.status, .deferred)
                XCTAssertNil(state.missionPlan?.postApprovalContinuation?.durableApprovalAuthorityToken)
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        let result = await viewModel.submitCoordinatorContinuation(
            .proceed,
            expectedCheckpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r3"
        )

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(barrierTokens.count, 1)
        XCTAssertEqual(submissions.count, 0)
        XCTAssertEqual(state.missionPlan?.approvalState, .approved)
        XCTAssertEqual(state.missionPlan?.status, .running)
        XCTAssertEqual(state.missionPlan?.decisions.map(\.label), ["approved the Mission plan"])
        XCTAssertEqual(state.missionPlan?.decisions.first?.checkpointInstanceID, "coordinator:\(coordinatorID.uuidString):plan-approval:r3")
        let handoff = try XCTUnwrap(state.missionPlan?.postApprovalContinuation)
        XCTAssertEqual(handoff.checkpointInstanceID, "coordinator:\(coordinatorID.uuidString):plan-approval:r3")
        XCTAssertEqual(handoff.status, .deferred)
        XCTAssertEqual(handoff.attempts, 0)
        XCTAssertEqual(handoff.durableApprovalAuthorityToken, handoff.expectedDurableApprovalAuthorityToken)
        XCTAssertEqual(viewModel.durableApprovalAuthorityToken(coordinatorSessionID: coordinatorID), handoff.expectedDurableApprovalAuthorityToken)
        XCTAssertTrue(handoff.directiveText.contains("coordinator_post_approval_continuation"))
        XCTAssertTrue(handoff.lastError?.contains("queued for the next ordinary turn boundary") == true)
        XCTAssertEqual(
            viewModel.postApprovalContinuationStatus,
            .deferred(checkpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r3")
        )
        XCTAssertTrue(viewModel.composerNotice?.contains("will be delivered once") == true)
    }

    func testPlanCheckpointApprovalFailsClosedWhenDurableBarrierFails() async throws {
        let coordinatorID = uuid(1)
        let nodeID = uuid(30)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 3,
            objective: "Ship the plan",
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Implement safely",
                    workstreamID: uuid(40),
                    executionPolicy: .freshWorktree
                )
            ]
        ))
        var submissions: [CoordinatorDirectiveSubmission] = []
        var evaluations: [UUID] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append(submission)
                return .accepted
            },
            missionPlanUpdater: { _, update in
                state.updateMissionPlan(update)
            },
            followThroughEvaluationHandler: { sessionID in
                evaluations.append(sessionID)
            },
            postApprovalContinuationPersistenceBarrier: { token in
                XCTAssertEqual(token.coordinatorSessionID, coordinatorID)
                XCTAssertEqual(token.checkpointInstanceID, "coordinator:\(coordinatorID.uuidString):plan-approval:r3")
                throw NSError(domain: "CoordinatorModeComposerViewModelTests", code: 99)
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        let result = await viewModel.submitCoordinatorContinuation(
            .proceed,
            expectedCheckpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r3"
        )

        guard case let .rejected(message) = result else {
            XCTFail("Expected rejected result when the durable persistence barrier fails.")
            return
        }
        XCTAssertTrue(message.contains("durable continuation persistence failed"), message)
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertTrue(evaluations.isEmpty)
        let continuation = try XCTUnwrap(state.missionPlan?.postApprovalContinuation)
        XCTAssertEqual(continuation.status, .failed)
        XCTAssertEqual(continuation.attempts, 0)
        XCTAssertNil(continuation.durableApprovalAuthorityToken)
        XCTAssertNil(viewModel.durableApprovalAuthorityToken(coordinatorSessionID: coordinatorID))
        XCTAssertTrue(continuation.lastError?.contains("durable continuation persistence failed") == true)
    }

    func testStopMissionDoesNotCancelWhenPersistenceFails() async {
        let coordinatorID = uuid(1)
        let nodeID = uuid(30)
        let state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 3,
            objective: "Stop safely",
            status: .running,
            approvalState: .approved,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Running child",
                    workstreamID: uuid(40),
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: uuid(2)
                )
            ]
        ))
        var stopRequests: [CoordinatorMissionStopRequest] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .running,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            missionPlanUpdater: { _, _ in
                throw NSError(domain: "CoordinatorModeComposerViewModelTests", code: 2)
            },
            missionStopper: { request in
                stopRequests.append(request)
                return CoordinatorMissionStopResult(
                    requestedSessionIDs: request.sessionIDs,
                    cancelledSessionIDs: request.sessionIDs,
                    skippedSessionIDs: []
                )
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        let result = await viewModel.stopCoordinatorMission(targetMissionID: coordinatorID)

        guard case let .rejected(message) = result else {
            XCTFail("Expected stop rejection when terminal state cannot persist.")
            return
        }
        XCTAssertTrue(message.contains("could not be recorded"), message)
        XCTAssertTrue(stopRequests.isEmpty)
    }

    func testFollowThroughAndChildAnswersRecordUserDecisionsButCoordinatorOwnedPendingInteractionsDoNot() async throws {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let interactionID = uuid(900)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Supervise child questions",
            approvalState: .approved
        ))
        let childQuestion = pendingQuestionInteraction(
            id: interactionID,
            title: "Child checkpoint",
            prompt: "Should the child continue?"
        )
        var childSubmissions = 0
        var coordinatorSubmissions = 0
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(40),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        ),
                        self.live(
                            id: childID,
                            tab: self.uuid(102),
                            title: "Child",
                            updatedAt: self.date(30),
                            state: .waitingForQuestion,
                            parent: coordinatorID
                        )
                    ],
                    mcpSnapshots: [
                        childID: self.mcpSnapshot(
                            sessionID: childID,
                            tabID: self.uuid(102),
                            sessionName: "Child",
                            status: .waitingForInput,
                            statusText: "Waiting",
                            assistantPreview: nil,
                            parent: coordinatorID,
                            interaction: childQuestion
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            childInteractionResponseSubmitter: { _, _ in
                childSubmissions += 1
                return .accepted
            },
            coordinatorInteractionResponseSubmitter: { _, _, _ in
                coordinatorSubmissions += 1
                return .accepted
            },
            missionPlanUpdater: { _, update in
                state.updateMissionPlan(update)
            },
            followThroughEventSubmitter: { _ in
                .accepted
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)
        let event = CoordinatorFollowThroughEvent(
            id: "event-continue-1",
            kind: .childTerminal,
            coordinatorSessionID: coordinatorID,
            childSessionID: childID,
            childTitle: "Child",
            gate: nil,
            phase: .done,
            detail: "Child completed."
        )

        let followThroughResult = await viewModel.submitPendingFollowThroughEvent(event)
        let row = try XCTUnwrap(viewModel.activePendingChildInteractionRow())
        let childResult = await viewModel.submitPendingChildInteractionResponse("Continue with the safe option.", to: row)
        let coordinatorPending = CoordinatorModePendingInteractionSummary(
            id: uuid(901),
            sessionID: coordinatorID,
            kind: .question,
            responseType: .text,
            title: "Generic Coordinator question",
            prompt: "This is not a typed app checkpoint.",
            context: nil,
            options: [],
            fields: [],
            details: [],
            openAgentChatRoute: nil
        )
        let coordinatorResult = await viewModel.submitCoordinatorPendingInteractionResponse(.text("Answer"), pending: coordinatorPending)

        XCTAssertEqual(followThroughResult, .accepted)
        XCTAssertEqual(childResult, .accepted)
        XCTAssertEqual(coordinatorResult, .accepted)
        XCTAssertEqual(childSubmissions, 1)
        XCTAssertEqual(coordinatorSubmissions, 1)
        let decisions = try XCTUnwrap(state.missionPlan?.decisions)
        XCTAssertEqual(decisions.map(\.label), ["continued past a step check-in", "answered a child question"])
        XCTAssertEqual(decisions.first?.checkpointInstanceID, "follow-through:event-continue-1")
        XCTAssertEqual(decisions.last?.checkpointInstanceID, "child-interaction:\(interactionID.uuidString)")
        XCTAssertEqual(decisions.last?.reason, "Answered child question with: Continue with the safe option.")
        let evidence = try XCTUnwrap(state.missionPlan?.evidence)
        XCTAssertEqual(evidence.map(\.summary), [
            "User answered child question for Child: Continue with the safe option."
        ])
        XCTAssertEqual(evidence.first?.decisionID, decisions.last?.id)
        XCTAssertEqual(evidence.first?.interactionID, interactionID)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.missionSummary?.decisions.userCount, 2)
    }

    func testPendingRevisionProposalHoldsExistingAndNewChildQuestionsWithoutQueuingAnswers() async throws {
        let coordinatorID = uuid(1)
        let existingChildID = uuid(2)
        let newChildID = uuid(3)
        let existingInteractionID = uuid(901)
        let newInteractionID = uuid(902)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Answer child questions.",
            status: .running,
            approvalState: .approved,
            nodes: [
                CoordinatorMissionPlanNode(
                    title: "Wait for child direction",
                    workstreamID: uuid(80),
                    executionPolicy: .coordinatorOnly
                )
            ],
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    timestamp: date(5),
                    decision: .holdForUser,
                    operation: .coordinatorHold,
                    reason: "Existing step boundary."
                )
            ]
        ))
        var childStates: [(UUID, AgentSessionRunState)] = [(existingChildID, .waitingForQuestion)]
        var interactions: [UUID: AgentRunMCPSnapshot.Interaction] = [
            existingChildID: pendingQuestionInteraction(
                id: existingInteractionID,
                title: "Existing question",
                prompt: "Question before proposal?"
            )
        ]
        var submissions = 0
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                let children = childStates.map { childID, runState in
                    self.live(
                        id: childID,
                        tab: self.uuid(childID == existingChildID ? 102 : 103),
                        title: childID == existingChildID ? "Existing child" : "New child",
                        updatedAt: self.date(childID == existingChildID ? 30 : 35),
                        state: runState,
                        parent: coordinatorID
                    )
                }
                let snapshots = Dictionary(uniqueKeysWithValues: interactions.map { childID, interaction in
                    (childID, self.mcpSnapshot(
                        sessionID: childID,
                        tabID: self.uuid(childID == existingChildID ? 102 : 103),
                        sessionName: childID == existingChildID ? "Existing child" : "New child",
                        status: .waitingForInput,
                        statusText: "Waiting",
                        assistantPreview: nil,
                        parent: coordinatorID,
                        interaction: interaction
                    ))
                })
                return self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(40),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        )
                    ] + children,
                    mcpSnapshots: snapshots,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            childInteractionResponseSubmitter: { _, _ in
                submissions += 1
                return .accepted
            },
            missionPlanUpdater: { _, update in
                try state.applyMissionPlanUpdate(update)
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)
        XCTAssertEqual(viewModel.activePendingChildInteractionRow()?.sessionID, existingChildID)

        let plan = try XCTUnwrap(state.missionPlan)
        _ = try state.appendRevisionProposal(CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: plan.id,
            expectedBaseContractFingerprint: plan.materialContractFingerprint(),
            summary: "Revise child direction",
            affectedFields: ["objective"],
            remedy: "revise_scope",
            supportingEvidenceIDs: [],
            requestedChange: "Revise child direction.",
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: coordinatorID,
                runtimeSessionID: coordinatorID
            )
        ))
        var legacyCoexistingPlan = try XCTUnwrap(state.missionPlan)
        legacyCoexistingPlan.approvalState = .awaitingApproval
        state.missionPlan = legacyCoexistingPlan
        childStates.append((newChildID, .waitingForQuestion))
        interactions[newChildID] = pendingQuestionInteraction(
            id: newInteractionID,
            title: "New question",
            prompt: "Question during proposal?"
        )
        viewModel.refresh()

        let heldRows = viewModel.snapshot.groups.flatMap(\.rows).filter { $0.pendingInteraction != nil }
        XCTAssertEqual(Set(heldRows.map(\.sessionID)), [existingChildID, newChildID])
        XCTAssertTrue(heldRows.allSatisfy { $0.pendingInteraction?.isAvailable == false })
        XCTAssertTrue(heldRows.allSatisfy {
            $0.pendingInteraction?.unavailableReason == CoordinatorMissionRevisionProposalPause.heldReason
        })
        XCTAssertNil(viewModel.activePendingChildInteractionRow())
        XCTAssertEqual(viewModel.snapshot.decisionQueue.map(\.source), [.revisionProposal])
        let paceResult = await viewModel.setCoordinatorMissionPace(
            coordinatorSessionID: coordinatorID,
            pace: .step
        )
        XCTAssertEqual(paceResult, .rejected(message: CoordinatorMissionRevisionProposalPause.heldReason))
        let autonomyResult = await viewModel.setCoordinatorMissionAutonomy(
            coordinatorSessionID: coordinatorID,
            autonomyClassKey: CoordinatorMissionAutonomyClasses.childAsk.key,
            mode: .auto
        )
        XCTAssertEqual(autonomyResult, .rejected(message: CoordinatorMissionRevisionProposalPause.heldReason))

        let heldExisting = try XCTUnwrap(heldRows.first(where: { $0.sessionID == existingChildID }))
        let result = await viewModel.submitPendingChildInteractionResponse(
            .text("Do not queue this answer."),
            to: heldExisting,
            actor: .director
        )
        XCTAssertEqual(result, .rejected(message: CoordinatorMissionRevisionProposalPause.heldReason))
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(state.missionPlan?.decisions, [])
        XCTAssertEqual(state.missionPlan?.evidence, [])

        childStates = [
            (existingChildID, .waitingForQuestion),
            (newChildID, .completed)
        ]
        interactions.removeValue(forKey: newChildID)
        viewModel.refresh()
        XCTAssertEqual(Set(viewModel.snapshot.pendingInteractions.map(\.sessionID)), [existingChildID])
    }

    func testEmptyChildInteractionResponseStillRecordsEvidence() async throws {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let interactionID = uuid(901)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Answer child question.",
            status: .running,
            approvalState: .approved
        ))
        let childQuestion = pendingQuestionInteraction(
            id: interactionID,
            title: "Child checkpoint",
            prompt: "Can this be skipped?"
        )
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(40),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        ),
                        self.live(
                            id: childID,
                            tab: self.uuid(102),
                            title: "Child",
                            updatedAt: self.date(30),
                            state: .waitingForQuestion,
                            parent: coordinatorID
                        )
                    ],
                    mcpSnapshots: [
                        childID: self.mcpSnapshot(
                            sessionID: childID,
                            tabID: self.uuid(102),
                            sessionName: "Child",
                            status: .waitingForInput,
                            statusText: "Waiting",
                            assistantPreview: nil,
                            parent: coordinatorID,
                            interaction: childQuestion
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            childInteractionResponseSubmitter: { _, _ in .accepted },
            missionPlanUpdater: { _, update in
                state.updateMissionPlan(update)
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)
        let row = try XCTUnwrap(viewModel.activePendingChildInteractionRow())

        let result = await viewModel.submitPendingChildInteractionResponse(
            CoordinatorModeViewModel.ChildInteractionResponseSubmission(
                text: nil,
                skip: true,
                answersByQuestionID: [:],
                displayText: ""
            ),
            to: row,
            actor: .director
        )

        XCTAssertEqual(result, .accepted)
        let evidence = try XCTUnwrap(state.missionPlan?.evidence.first)
        XCTAssertEqual(evidence.summary, "Director answered child question for Child: No answer text recorded.")
        XCTAssertEqual(evidence.interactionID, interactionID)
        XCTAssertEqual(evidence.decisionID, state.missionPlan?.decisions.first?.id)
    }

    func testChildInteractionResponseWithoutCoordinatorLedgerLinkRejectsBeforeSubmit() async {
        let childID = uuid(2)
        let interactionID = uuid(901)
        let childQuestion = CoordinatorModePendingInteractionSummary(
            id: interactionID,
            sessionID: childID,
            kind: .question,
            responseType: .text,
            title: "Child checkpoint",
            prompt: "Can this be answered?",
            context: nil,
            options: [],
            fields: [],
            details: [],
            openAgentChatRoute: nil
        )
        var submitted = false
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode
                )
            },
            dashboardVisibilityHandler: { _ in },
            childInteractionResponseSubmitter: { _, _ in
                submitted = true
                return .accepted
            }
        )
        let row = CoordinatorModeRow(
            id: childID,
            sessionID: childID,
            tabID: uuid(102),
            title: "Child",
            providerName: "codexExec",
            modelName: "gpt-5.5",
            runState: .waitingForQuestion,
            statusGroup: .needsYou,
            parentSessionID: nil,
            parentCoordinator: nil,
            childSessionIDs: [],
            isMCPOriginated: true,
            isPersistedOnly: false,
            isCoordinator: false,
            startedAt: nil,
            updatedAt: date(30),
            priority: nil,
            workstream: nil,
            workstreamSummary: nil,
            workflow: nil,
            mergeAttention: nil,
            pendingInteraction: childQuestion,
            openAgentChatRoute: nil,
            statusReport: nil,
            origin: .coordinatorFleet
        )

        let result = await viewModel.submitPendingChildInteractionResponse(.text("Alpha"), to: row, actor: .director)

        XCTAssertEqual(
            result,
            CoordinatorModeViewModel.DirectiveSubmissionResult
                .rejected(message: "This child answer could not be recorded because it is no longer linked to a Coordinator mission.")
        )
        XCTAssertFalse(submitted)
        XCTAssertEqual(
            viewModel.composerNotice,
            "This child answer could not be recorded because it is no longer linked to a Coordinator mission."
        )
    }

    func testRejectedDraftSendKeepsComposerNotice() async {
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { _ in .rejected(message: "Nope") }
        )
        viewModel.refresh()

        let result = await viewModel.submitCoordinatorDirective("try this")

        XCTAssertEqual(result, .rejected(message: "Nope"))
        XCTAssertEqual(viewModel.composerNotice, "Nope")
    }

    func testAcceptedDirectiveUsesSubmitterEchoesIntoRailAndKeepsSnapshotRowsReadOnly() async {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let coordinatorTab = uuid(101)
        let childTab = uuid(102)
        let input = input(
            persisted: [
                persisted(id: childID, tab: childTab, title: "Child", updatedAt: date(10), parent: coordinatorID)
            ],
            live: [
                live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator", updatedAt: date(20), state: .idle, isMCP: true)
            ],
            demoCoordinatorIDs: [coordinatorID]
        )
        var submissions: [(text: String, sessionID: UUID?, forceNewRuntime: Bool)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                if let selectedCoordinatorID {
                    next.selectedCoordinatorID = selectedCoordinatorID
                }
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append((submission.providerText, submission.coordinatorSessionID, submission.forceNewRuntime))
                return .accepted
            }
        )
        viewModel.refresh()
        let rowsBeforeSubmit = viewModel.snapshot.groups

        let result = await viewModel.submitCoordinatorDirective("  Coordinate the child session  ")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.text, "Coordinate the child session")
        XCTAssertEqual(submissions.first?.sessionID, coordinatorID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, false)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.event, .user])
        XCTAssertEqual(viewModel.railTranscriptEntries.first?.action?.targetSessionID, childID)
        XCTAssertEqual(viewModel.railTranscriptEntries.last?.text, "Coordinate the child session")
        XCTAssertEqual(viewModel.snapshot.groups, rowsBeforeSubmit)

        viewModel.clearCoordinatorRailTranscript()
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertNil(viewModel.composerNotice)
    }

    func testProceedContinuationQueuesDurableHandoffWithoutVisibleCoordinatorMessage() async {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 2,
            objective: "Approve visible continuation",
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: uuid(30),
                    title: "Continue",
                    workstreamID: uuid(40),
                    executionPolicy: .coordinatorOnly
                )
            ]
        ))
        var submissions: [(text: String, sessionID: UUID?, forceNewRuntime: Bool)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: coordinatorTab,
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            isMCP: true,
                            missionPlan: state.missionPlan
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append((submission.providerText, submission.coordinatorSessionID, submission.forceNewRuntime))
                return .accepted
            },
            missionPlanUpdater: { _, update in
                state.updateMissionPlan(update)
            }
        )
        viewModel.refresh()

        let result = await viewModel.submitCoordinatorContinuation(
            .proceed,
            expectedCheckpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r2"
        )

        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertEqual(state.missionPlan?.postApprovalContinuation?.status, .deferred)
        XCTAssertEqual(state.missionPlan?.postApprovalContinuation?.attempts, 0)
        XCTAssertNotNil(state.missionPlan?.postApprovalContinuation?.durableApprovalAuthorityToken)
        XCTAssertTrue(viewModel.composerNotice?.contains("queued and will be delivered once") == true)
    }

    func testLightweightDiscoveryContinuationSubmitsDiscoveryDirective() async throws {
        let text = try await submittedContinuationText(.runLightweightDiscovery)

        XCTAssertTrue(text.contains("coordinator_chat op=mission_status"))
        XCTAssertTrue(text.contains("approval_state:\"awaiting_approval\""))
        XCTAssertTrue(text.contains("execution_policy:\"fresh_readonly_child\""))
        XCTAssertTrue(text.contains("agent_explore.start"))
        XCTAssertTrue(text.contains("bounded Mission ledger"))
        XCTAssertTrue(text.contains("judgment_bundle/probe_answer"))
        XCTAssertTrue(text.contains("Auto decisions are visible and contestable"))
        XCTAssertTrue(text.contains("correction steer"))
        XCTAssertTrue(text.contains("workflow_name:\"Investigate\""))
        XCTAssertTrue(text.contains("chosen model_id"))
        XCTAssertTrue(text.contains("agent_run.start"))
        XCTAssertTrue(text.contains("mission_node_id"))
        XCTAssertTrue(text.contains("worktree_create:true"))
        XCTAssertFalse(text.contains("model_id:\"explore\""))
        XCTAssertTrue(text.contains("read-only"))
    }

    func testDeepPlanContinuationSubmitsDeepPlanDirective() async throws {
        let text = try await submittedContinuationText(.runDeepPlan)

        XCTAssertTrue(text.contains("coordinator_chat op=mission_status"))
        XCTAssertTrue(text.contains("approval_state:\"awaiting_approval\""))
        XCTAssertTrue(text.contains("workflow_name:\"Deep Plan\""))
        XCTAssertTrue(text.contains("agent_run.start"))
        XCTAssertTrue(text.contains("mission_node_id"))
        XCTAssertTrue(text.contains("worktree_create:true"))
        XCTAssertTrue(text.contains("not as a replacement source of truth"))
    }

    func testDesignCritiqueContinuationSubmitsDesignCritiqueDirective() async throws {
        let text = try await submittedContinuationText(.runDesignCritique)

        XCTAssertTrue(text.contains("coordinator_chat op=mission_status"))
        XCTAssertTrue(text.contains("approval_state:\"awaiting_approval\""))
        XCTAssertTrue(text.contains("execution_policy:\"plan_critique\""))
        XCTAssertTrue(text.contains("agent_run.start"))
        XCTAssertTrue(text.contains("model_id:\"design\""))
        XCTAssertTrue(text.contains("mission_node_id"))
        XCTAssertTrue(text.contains("worktree_create:true"))
        XCTAssertTrue(text.contains("Critique this RepoPrompt Coordinator Mission Plan"))
        XCTAssertFalse(text.contains("ask_oracle"))
    }

    func testStartSmallerContinuationSubmitsRevisionDirective() async throws {
        let text = try await submittedContinuationText(.startSmaller)

        XCTAssertTrue(text.contains("Start smaller before approval"))
        XCTAssertTrue(text.contains("coordinator_chat op=mission_status"))
        XCTAssertTrue(text.contains("approval_state:\"awaiting_approval\""))
        XCTAssertTrue(text.contains("smallest useful first phase"))
    }

    private func submittedContinuationText(_ action: CoordinatorModeViewModel.ContinuationAction) async throws -> String {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        let plan = CoordinatorMissionPlan(
            revision: 2,
            objective: "Approve continuation action",
            approvalState: .awaitingApproval,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: uuid(30),
                    title: "Continue",
                    workstreamID: uuid(40),
                    executionPolicy: .coordinatorOnly
                )
            ]
        )
        let input = input(
            live: [
                live(
                    id: coordinatorID,
                    tab: coordinatorTab,
                    title: "Coordinator",
                    updatedAt: date(20),
                    state: .idle,
                    isMCP: true,
                    missionPlan: plan
                )
            ],
            demoCoordinatorIDs: [coordinatorID]
        )
        var submissions: [CoordinatorDirectiveSubmission] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                if let selectedCoordinatorID {
                    next.selectedCoordinatorID = selectedCoordinatorID
                }
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append(submission)
                return .accepted
            }
        )
        viewModel.refresh()

        let result = await viewModel.submitCoordinatorContinuation(
            action,
            expectedCheckpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r2"
        )

        XCTAssertEqual(result, .accepted)
        let text = try XCTUnwrap(submissions.first?.providerText)
        XCTAssertEqual(submissions.first?.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, false)
        return text
    }

    func testCoordinatorRailRestoresSelectedRuntimeConversationTranscript() {
        let firstCoordinatorID = uuid(1)
        let secondCoordinatorID = uuid(2)
        let firstTabID = uuid(101)
        let secondTabID = uuid(102)
        let transcriptByCoordinatorID: [UUID: [CoordinatorModeRailTranscriptEntry]] = [
            firstCoordinatorID: [
                transcriptEntry(id: uuid(1001), role: .user, text: "first directive", at: date(10)),
                transcriptEntry(id: uuid(1002), role: .coordinator, text: "first answer", at: date(11))
            ],
            secondCoordinatorID: [
                transcriptEntry(id: uuid(2001), role: .user, text: "second directive", at: date(20)),
                transcriptEntry(id: uuid(2002), role: .coordinator, text: "second answer", at: date(21))
            ]
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: firstCoordinatorID,
                            tab: firstTabID,
                            title: "First coordinator",
                            updatedAt: self.date(11),
                            state: .idle,
                            isMCP: true
                        ),
                        self.live(
                            id: secondCoordinatorID,
                            tab: secondTabID,
                            title: "Second coordinator",
                            updatedAt: self.date(21),
                            state: .idle,
                            isMCP: true
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [firstCoordinatorID, secondCoordinatorID]
                )
            },
            transcriptProvider: { coordinatorID in
                coordinatorID.flatMap { transcriptByCoordinatorID[$0] } ?? []
            },
            dashboardVisibilityHandler: { _ in }
        )

        viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, secondCoordinatorID)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.text), ["second directive", "second answer"])

        viewModel.selectCoordinator(sessionID: firstCoordinatorID)

        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, firstCoordinatorID)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.text), ["first directive", "first answer"])
    }

    func testExecutionPaceDefaultsToDraftPolicyInsteadOfRestoringGlobalPreference() throws {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            userDefaults: defaults
        )
        XCTAssertEqual(initial.executionPace, .step)
        XCTAssertFalse(initial.usesAutoMode)

        initial.setExecutionPace(.auto)
        XCTAssertEqual(initial.executionPace, .auto)
        XCTAssertTrue(initial.usesAutoMode)

        let restored = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            userDefaults: defaults
        )
        XCTAssertEqual(restored.executionPace, .step)
        XCTAssertFalse(restored.usesAutoMode)

        restored.selectedMissionPolicy = .handsOff
        XCTAssertEqual(restored.executionPace, .auto)
        XCTAssertEqual(restored.missionPaceSelection, .auto)
        XCTAssertEqual(restored.childAskSelection, .auto)
    }

    func testStepPaceExposesPendingFollowThroughEventAndAutoHidesIt() throws {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let event = CoordinatorFollowThroughEvent(
            id: "child:\(childID.uuidString):terminal:completed",
            kind: .childTerminal,
            coordinatorSessionID: coordinatorID,
            childSessionID: childID,
            childTitle: "Discovery child",
            gate: nil,
            phase: .done,
            detail: "Delegated child reached terminal state completed."
        )
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            coordinatorRuntime: true
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            pendingFollowThroughEventProvider: { selectedCoordinatorID in
                selectedCoordinatorID == coordinatorID ? event : nil
            },
            userDefaults: defaults
        )

        viewModel.refresh()
        XCTAssertEqual(viewModel.executionPace, .step)
        XCTAssertEqual(viewModel.activePendingFollowThroughEvent(), event)

        viewModel.setExecutionPace(.auto)
        XCTAssertNil(viewModel.activePendingFollowThroughEvent())

        viewModel.setExecutionPace(.step)
        XCTAssertEqual(viewModel.activePendingFollowThroughEvent(), event)
    }

    func testSwitchingStepToAutoSubmitsPendingFollowThroughEvent() async throws {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let event = CoordinatorFollowThroughEvent(
            id: "child:\(childID.uuidString):terminal:completed",
            kind: .childTerminal,
            coordinatorSessionID: coordinatorID,
            childSessionID: childID,
            childTitle: "Discovery child",
            gate: nil,
            phase: .done,
            detail: "Delegated child reached terminal state completed."
        )
        var submittedEvents: [CoordinatorFollowThroughEvent] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            coordinatorRuntime: true
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            pendingFollowThroughEventProvider: { selectedCoordinatorID in
                selectedCoordinatorID == coordinatorID ? event : nil
            },
            followThroughEventSubmitter: { event in
                submittedEvents.append(event)
                return .accepted
            },
            userDefaults: defaults
        )

        viewModel.refresh()
        XCTAssertEqual(viewModel.activePendingFollowThroughEvent(), event)

        viewModel.setExecutionPace(.auto)
        await Task.yield()

        XCTAssertEqual(submittedEvents, [event])
    }

    func testAcceptedDirectiveDoesNotDuplicateRuntimeBackedUserTranscriptEntryAndStripsProviderOnlyPolicyMetadata() async {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        var liveSessions: [CoordinatorModeSnapshotProjector.LiveSession] = []
        var demoCoordinatorIDs: Set<UUID> = []
        var transcriptEntries: [CoordinatorModeRailTranscriptEntry] = []
        var submissions: [CoordinatorDirectiveSubmission] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: demoCoordinatorIDs
                )
            },
            transcriptProvider: { _ in transcriptEntries },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append(submission)
                liveSessions = [
                    self.live(
                        id: coordinatorID,
                        tab: coordinatorTab,
                        title: "Coordinator",
                        updatedAt: self.date(20),
                        state: .idle,
                        isMCP: true
                    )
                ]
                demoCoordinatorIDs.insert(coordinatorID)
                transcriptEntries = [
                    self.transcriptEntry(
                        id: self.uuid(1001),
                        role: .user,
                        text: submission.providerText,
                        at: self.date(30)
                    )
                ]
                return .accepted
            }
        )
        viewModel.refresh()

        let result = await viewModel.submitCoordinatorDirective("what did it say?")

        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(submissions.first?.providerText.contains("Mission Policy (provider-only)") == true)
        XCTAssertTrue(submissions.first?.providerText.contains("Max concurrent child sessions: 3") == true)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.user])
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.text), ["what did it say?"])
        XCTAssertFalse(viewModel.railTranscriptEntries.contains { $0.text.contains("Mission Policy (provider-only)") })
    }

    func testPresentationPolicyShowsTerminalStatusAheadOfStaleApproval() {
        let completedPlan = CoordinatorMissionPlan(
            id: uuid(690),
            status: .completed,
            approvalState: .awaitingApproval
        )
        let stoppedPlan = CoordinatorMissionPlan(
            id: uuid(691),
            status: .stopped,
            approvalState: .revisionRequested
        )

        XCTAssertEqual(CoordinatorMissionPresentationPolicy.primaryStatus(for: completedPlan), .mission(.completed))
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.primaryStatus(for: stoppedPlan), .mission(.stopped))
    }

    func testPresentationPolicyKeepsActiveApprovalVisible() {
        let plan = CoordinatorMissionPlan(
            id: uuid(692),
            status: .running,
            approvalState: .awaitingApproval
        )

        XCTAssertEqual(CoordinatorMissionPresentationPolicy.primaryStatus(for: plan), .approval(.awaitingApproval))
    }

    func testPresentationPolicySuppressesLiveAndPlanRevisionForTerminalMissions() {
        let completedPlan = CoordinatorMissionPlan(id: uuid(693), status: .completed)
        let stoppedPlan = CoordinatorMissionPlan(id: uuid(694), status: .stopped)
        let runningPlan = CoordinatorMissionPlan(id: uuid(695), status: .running)

        XCTAssertFalse(CoordinatorMissionPresentationPolicy.shouldShowLiveBadge(for: completedPlan))
        XCTAssertFalse(CoordinatorMissionPresentationPolicy.shouldShowLiveBadge(for: stoppedPlan))
        XCTAssertTrue(CoordinatorMissionPresentationPolicy.shouldShowLiveBadge(for: runningPlan))
        XCTAssertFalse(CoordinatorMissionPresentationPolicy.shouldShowPlanRevisionComposer(for: completedPlan))
        XCTAssertFalse(CoordinatorMissionPresentationPolicy.shouldShowPlanRevisionComposer(for: stoppedPlan))
        XCTAssertTrue(CoordinatorMissionPresentationPolicy.shouldShowPlanRevisionComposer(for: runningPlan))
    }

    func testPresentationPolicyUsesTerminalConversationSummary() {
        let completedPlan = CoordinatorMissionPlan(id: uuid(696), status: .completed)
        let runningPlan = CoordinatorMissionPlan(id: uuid(697), status: .running)

        XCTAssertEqual(CoordinatorMissionPresentationPolicy.conversationMode(for: completedPlan), .terminalSummary(.completed))
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.conversationMode(for: runningPlan), .planReference)
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.conversationMode(for: nil), .noPlan)
    }

    func testPresentationPolicyUsesTerminalComposerPrompts() {
        let completedPlan = CoordinatorMissionPlan(id: uuid(6900), status: .completed)
        let stoppedPlan = CoordinatorMissionPlan(id: uuid(6901), status: .stopped)
        let runningPlan = CoordinatorMissionPlan(id: uuid(6902), status: .running)

        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.composerMode(
                for: completedPlan,
                hasPendingChildQuestion: false
            ),
            .terminalPrompt(.followUp)
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.composerMode(
                for: stoppedPlan,
                hasPendingChildQuestion: false
            ),
            .terminalPrompt(.restartOrRevise)
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.composerMode(
                for: runningPlan,
                hasPendingChildQuestion: false
            ),
            .standard
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.composerMode(
                for: completedPlan,
                hasPendingChildQuestion: true
            ),
            .standard
        )
    }

    func testPresentationPolicyTerminalComposerActionCopy() {
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.TerminalComposerAction.followUp.title,
            "Start a follow-up Mission →"
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.TerminalComposerAction.followUp.placeholder,
            "Start a follow-up Mission..."
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.TerminalComposerAction.restartOrRevise.title,
            "Restart or revise Mission →"
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.TerminalComposerAction.restartOrRevise.placeholder,
            "Restart or revise this Mission..."
        )
    }

    func testPresentationPolicyClassifiesTerminalPaneEmphasis() {
        let completedPlan = CoordinatorMissionPlan(id: uuid(6903), status: .completed)
        let stoppedPlan = CoordinatorMissionPlan(id: uuid(6904), status: .stopped)
        let draftPlan = CoordinatorMissionPlan(id: uuid(6905), status: .draft)

        XCTAssertEqual(CoordinatorMissionPresentationPolicy.paneEmphasis(for: completedPlan), .terminalQuiet)
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.paneEmphasis(for: stoppedPlan), .terminalQuiet)
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.paneEmphasis(for: draftPlan), .normal)
        XCTAssertTrue(CoordinatorMissionPresentationPolicy.PaneEmphasis.terminalQuiet.collapsesCompletedEvidence)
        XCTAssertFalse(CoordinatorMissionPresentationPolicy.PaneEmphasis.terminalQuiet.usesStateCapsulesInBody)
        XCTAssertTrue(CoordinatorMissionPresentationPolicy.PaneEmphasis.normal.usesStateCapsulesInBody)
    }

    func testPresentationPolicyClassifiesBoardColumnEmphasis() {
        let occupied = CoordinatorMissionPresentationPolicy.boardColumnEmphasis(isEmpty: false)
        let empty = CoordinatorMissionPresentationPolicy.boardColumnEmphasis(isEmpty: true)

        XCTAssertEqual(occupied, .occupied)
        XCTAssertEqual(empty, .emptyDimmed)
        XCTAssertGreaterThan(occupied.backgroundOpacity, empty.backgroundOpacity)
        XCTAssertGreaterThan(occupied.contentOpacity, empty.contentOpacity)
        XCTAssertGreaterThan(occupied.countFillOpacity, empty.countFillOpacity)
    }

    func testPresentationPolicyClassifiesRailRowSignals() {
        let completedPlan = CoordinatorMissionPlan(id: uuid(6906), status: .completed)
        let runningPlan = CoordinatorMissionPlan(id: uuid(6907), status: .running)

        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.railRowSignal(
                for: completedPlan,
                activeRunTitle: "Running",
                isLiveInCurrentWindow: true
            ),
            .mutedTerminalStatus(.completed)
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.railRowSignal(
                for: runningPlan,
                activeRunTitle: "Needs you",
                isLiveInCurrentWindow: true
            ),
            .filledBadge(.activeRun("Needs you"))
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.railRowSignal(
                for: runningPlan,
                activeRunTitle: nil,
                isLiveInCurrentWindow: true
            ),
            .filledBadge(.live)
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.railRowSignal(
                for: runningPlan,
                activeRunTitle: nil,
                isLiveInCurrentWindow: false
            ),
            .none
        )
    }

    func testPresentationPolicyClassifiesSignalShapes() {
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.signalShape(for: .state), .filledCapsule)
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.signalShape(for: .attention), .filledCapsule)
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.signalShape(for: .count), .plainText)
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.signalShape(for: .metadata), .mutedText)
        XCTAssertEqual(CoordinatorMissionPresentationPolicy.signalShape(for: .identity), .linkText)
    }

    func testPresentationPolicyBuildsMetadataLineWithoutStateFacts() {
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.defaultPace = .auto

        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.policyMetadataParts(for: policy),
            ["Default · edited", "auto", "cap 3"]
        )
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.policyMetadataLine(for: policy),
            "Default · edited · auto · cap 3"
        )

        let plan = CoordinatorMissionPlan(
            id: uuid(698),
            revision: 7,
            status: .completed,
            approvalState: .awaitingApproval,
            policySnapshot: policy
        )
        let metadataLine = CoordinatorMissionPresentationPolicy.missionPlanMetadataParts(for: plan).joined(separator: " · ")
        XCTAssertEqual(metadataLine, "r7 · Default · edited · auto · cap 3")
        XCTAssertFalse(metadataLine.localizedCaseInsensitiveContains("Completed"))
        XCTAssertFalse(metadataLine.localizedCaseInsensitiveContains("Awaiting approval"))
        XCTAssertFalse(metadataLine.localizedCaseInsensitiveContains("needs you"))
    }

    func testPresentationPolicyDeduplicatesMetadataParts() {
        XCTAssertEqual(
            CoordinatorMissionPresentationPolicy.uniqueMetadataParts([
                "Read-only child",
                "read-only child",
                "explore",
                nil,
                "  ",
                "bound session"
            ]),
            ["Read-only child", "explore", "bound session"]
        )
    }

    func testPresentationPolicyShowsInspectorOnlyForBoardDestination() {
        XCTAssertFalse(
            CoordinatorMissionPresentationPolicy.shouldShowInspector(
                for: .mission,
                hasInspectorTarget: true
            )
        )
        XCTAssertFalse(
            CoordinatorMissionPresentationPolicy.shouldShowInspector(
                for: .decisions,
                hasInspectorTarget: true
            )
        )
        XCTAssertFalse(
            CoordinatorMissionPresentationPolicy.shouldShowInspector(
                for: .board,
                hasInspectorTarget: false
            )
        )
        XCTAssertTrue(
            CoordinatorMissionPresentationPolicy.shouldShowInspector(
                for: .board,
                hasInspectorTarget: true
            )
        )
    }

    func testMissionLedgerEntriesAreIdempotentAcrossRepeatedSnapshotApplies() {
        let coordinatorID = uuid(1)
        var plan = CoordinatorMissionPlan(
            id: uuid(700),
            status: .completed,
            shapeSummary: CoordinatorMissionShapeSummary(
                id: "scoped-change",
                displayName: "Scoped change",
                reason: "Limit the mission to one narrow change."
            ),
            policySnapshot: .readOnly,
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    id: uuid(701),
                    timestamp: date(30),
                    decision: .startFreshReadOnlyChild,
                    operation: .agentRunStart,
                    reason: "Need an independent review."
                )
            ],
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: uuid(702),
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "started review",
                    reason: "Evidence was needed.",
                    timestamp: date(40)
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: uuid(703),
                    verdict: .meets,
                    summary: "Review passed.",
                    timestamp: date(50)
                )
            ],
            events: [
                CoordinatorMissionPlanEvent(
                    id: uuid(704),
                    kind: .nodeCompleted,
                    timestamp: date(60),
                    summary: "Review node landed."
                )
            ],
            updatedAt: date(70)
        )
        let viewModel = ledgerTestViewModel(coordinatorID: coordinatorID, plan: { plan })

        viewModel.refresh()
        viewModel.refresh()
        plan.updatedAt = date(70)
        viewModel.refresh()

        let ledgerEntries = viewModel.railTranscriptEntries.filter { $0.ledger != nil }
        XCTAssertEqual(ledgerEntries.count, 4)
        XCTAssertEqual(Set(ledgerEntries.map(\.id)).count, 4)
        XCTAssertEqual(decisionLedgerEntries(in: viewModel).map(\.id), [uuid(702)])
        XCTAssertEqual(evidenceLedgerEntries(in: viewModel).map(\.id), [uuid(703)])
        XCTAssertEqual(routingLedgerEntries(in: viewModel).map(\.id), [uuid(701)])
        XCTAssertEqual(planEventLedgerEntries(in: viewModel).map(\.id), [])
        XCTAssertEqual(planUpdateLedgerEntries(in: viewModel).map(\.id), [])
        XCTAssertEqual(wrapUpLedgerEntryCount(in: viewModel), 1)
        XCTAssertEqual(groundingLedgerEntryCount(in: viewModel), 0)
    }

    func testMissionLedgerCoalescesRoutinePlanProgressEvents() {
        let coordinatorID = uuid(1)
        let plan = CoordinatorMissionPlan(
            id: uuid(705),
            revision: 7,
            events: [
                CoordinatorMissionPlanEvent(
                    id: uuid(7051),
                    kind: .sessionBound,
                    timestamp: date(20),
                    summary: "Bound child session."
                ),
                CoordinatorMissionPlanEvent(
                    id: uuid(7052),
                    kind: .nodeCompleted,
                    timestamp: date(21),
                    summary: "Discovery completed."
                ),
                CoordinatorMissionPlanEvent(
                    id: uuid(7053),
                    kind: .nodeCompleted,
                    timestamp: date(22),
                    summary: "Report completed."
                ),
                CoordinatorMissionPlanEvent(
                    id: uuid(7054),
                    kind: .revised,
                    timestamp: date(23),
                    summary: "Mission plan updated"
                )
            ],
            updatedAt: date(24)
        )
        let viewModel = ledgerTestViewModel(coordinatorID: coordinatorID, plan: { plan })

        viewModel.refresh()

        XCTAssertEqual(planEventLedgerEntries(in: viewModel).map(\.id), [])
        let updates = planUpdateLedgerEntries(in: viewModel)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.id, uuid(7054))
        XCTAssertEqual(updates.first?.previousRevision, 6)
        XCTAssertEqual(updates.first?.revision, 7)
        XCTAssertEqual(updates.first?.foldedEventCount, 3)
        XCTAssertNil(updates.first?.summary)
        XCTAssertEqual(viewModel.railTranscriptEntries.filter { $0.ledger != nil }.map(\.id), [uuid(7054)])
    }

    func testMissionLedgerKeepsBlockingPlanEventsVisible() {
        let coordinatorID = uuid(1)
        let plan = CoordinatorMissionPlan(
            id: uuid(706),
            events: [
                CoordinatorMissionPlanEvent(
                    id: uuid(7061),
                    kind: .nodeBlocked,
                    timestamp: date(20),
                    summary: "Reviewer is blocked on missing evidence."
                )
            ],
            updatedAt: date(21)
        )
        let viewModel = ledgerTestViewModel(coordinatorID: coordinatorID, plan: { plan })

        viewModel.refresh()

        XCTAssertEqual(planEventLedgerEntries(in: viewModel).map(\.id), [uuid(7061)])
        XCTAssertEqual(planUpdateLedgerEntries(in: viewModel), [])
    }

    func testMissionLedgerEntriesInterleaveByTimestampAndID() {
        let coordinatorID = uuid(1)
        let firstTranscriptID = uuid(900)
        let secondTranscriptID = uuid(901)
        let plan = CoordinatorMissionPlan(
            id: uuid(710),
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    id: uuid(7104),
                    timestamp: date(35),
                    decision: .steerPrimary,
                    operation: .agentRunSteer,
                    reason: "Steer primary before deciding."
                )
            ],
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: uuid(7102),
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "continue",
                    timestamp: date(40)
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: uuid(7101),
                    verdict: .short,
                    summary: "Needs another pass.",
                    timestamp: date(30)
                )
            ],
            events: [
                CoordinatorMissionPlanEvent(
                    id: uuid(7103),
                    kind: .revised,
                    timestamp: date(45),
                    summary: "Plan revised."
                )
            ],
            updatedAt: date(55)
        )
        let transcript = [
            transcriptEntry(id: firstTranscriptID, role: .user, text: "start", at: date(20)),
            transcriptEntry(id: secondTranscriptID, role: .coordinator, text: "done", at: date(50))
        ]
        let viewModel = ledgerTestViewModel(coordinatorID: coordinatorID, plan: { plan }, transcript: { transcript })

        viewModel.refresh()

        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.id), [
            firstTranscriptID,
            uuid(7101),
            uuid(7104),
            uuid(7102),
            uuid(7103),
            secondTranscriptID
        ])
    }

    func testMissionLedgerEntriesArePreservedAcrossTranscriptResync() {
        let coordinatorID = uuid(1)
        let evidenceID = uuid(7201)
        var transcript = [
            transcriptEntry(id: uuid(920), role: .user, text: "original", at: date(20))
        ]
        let plan = CoordinatorMissionPlan(
            id: uuid(720),
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: evidenceID,
                    verdict: .meets,
                    summary: "Evidence survives transcript reload.",
                    timestamp: date(30)
                )
            ],
            updatedAt: date(40)
        )
        let viewModel = ledgerTestViewModel(coordinatorID: coordinatorID, plan: { plan }, transcript: { transcript })

        viewModel.refresh()
        transcript = [
            transcriptEntry(id: uuid(921), role: .coordinator, text: "resynced", at: date(25))
        ]
        viewModel.refresh()

        XCTAssertEqual(evidenceLedgerEntries(in: viewModel).map(\.id), [evidenceID])
        XCTAssertTrue(viewModel.railTranscriptEntries.contains { $0.id == uuid(921) })
        XCTAssertFalse(viewModel.railTranscriptEntries.contains { $0.id == uuid(920) })
    }

    func testMissionLedgerWrapUpAppearsOnceOnlyWhenCompleted() {
        let coordinatorID = uuid(1)
        var plan = CoordinatorMissionPlan(
            id: uuid(730),
            status: .running,
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: uuid(7301),
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .user,
                    label: "continued",
                    timestamp: date(20)
                ),
                CoordinatorMissionDecisionRecord(
                    id: uuid(7302),
                    decisionClass: CoordinatorMissionDecisionClass.recover.rawValue,
                    actor: .director,
                    label: "recovered",
                    timestamp: date(30)
                )
            ],
            updatedAt: date(40)
        )
        let viewModel = ledgerTestViewModel(coordinatorID: coordinatorID, plan: { plan })

        viewModel.refresh()
        XCTAssertEqual(wrapUpLedgerEntryCount(in: viewModel), 0)

        plan.status = .completed
        plan.updatedAt = date(50)
        viewModel.refresh()
        viewModel.refresh()

        XCTAssertEqual(wrapUpLedgerEntryCount(in: viewModel), 1)
        XCTAssertTrue(viewModel.railTranscriptEntries.contains { entry in
            if case let .wrapUp(userCount, directorCount)? = entry.ledger {
                return userCount == 1 && directorCount == 1
            }
            return false
        })

        plan.status = .running
        plan.updatedAt = date(60)
        viewModel.refresh()

        XCTAssertEqual(wrapUpLedgerEntryCount(in: viewModel), 0)
    }

    func testMissionLedgerDedupesDecisionsByIDNotLabel() {
        let coordinatorID = uuid(1)
        let plan = CoordinatorMissionPlan(
            id: uuid(740),
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: uuid(7401),
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "continue",
                    timestamp: date(20)
                ),
                CoordinatorMissionDecisionRecord(
                    id: uuid(7402),
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "continue",
                    timestamp: date(21)
                )
            ],
            updatedAt: date(30)
        )
        let viewModel = ledgerTestViewModel(coordinatorID: coordinatorID, plan: { plan })

        viewModel.refresh()

        let decisions = decisionLedgerEntries(in: viewModel)
        XCTAssertEqual(decisions.map(\.id), [uuid(7401), uuid(7402)])
        XCTAssertEqual(decisions.map(\.label), ["continue", "continue"])
    }

    func testCoordinatorStatusMirrorsIntoConversationOncePerStatus() {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        var mcpSnapshots: [UUID: AgentRunMCPSnapshot] = [
            coordinatorID: mcpSnapshot(
                sessionID: coordinatorID,
                tabID: coordinatorTab,
                sessionName: "Coordinator",
                status: .running,
                statusText: "Starting delegated work",
                assistantPreview: "I'll start the first child now.",
                parent: nil
            )
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: coordinatorTab,
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .running,
                            isMCP: true
                        )
                    ],
                    mcpSnapshots: mcpSnapshots,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in }
        )

        viewModel.refresh()
        viewModel.refresh()

        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertEqual(viewModel.currentRailActivityText, "Starting delegated work")

        mcpSnapshots[coordinatorID] = mcpSnapshot(
            sessionID: coordinatorID,
            tabID: coordinatorTab,
            sessionName: "Coordinator",
            status: .completed,
            statusText: "Delegated work complete",
            assistantPreview: "Done.",
            parent: nil
        )

        viewModel.refresh()

        XCTAssertNil(viewModel.currentRailActivityText)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.coordinator])
        XCTAssertEqual(viewModel.railTranscriptEntries.last?.text, "Done.")
    }

    func testCoordinatorCancelledStatusMirrorsAsNeutralConversationEntry() {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        let mcpSnapshots: [UUID: AgentRunMCPSnapshot] = [
            coordinatorID: mcpSnapshot(
                sessionID: coordinatorID,
                tabID: coordinatorTab,
                sessionName: "Coordinator",
                status: .failed,
                statusText: "Cancelled",
                assistantPreview: nil,
                parent: nil,
                failureReason: .cancelled
            )
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: coordinatorTab,
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .cancelled,
                            isMCP: true
                        )
                    ],
                    mcpSnapshots: mcpSnapshots,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in }
        )

        viewModel.refresh()

        XCTAssertNil(viewModel.currentRailActivityText)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.coordinator])
        XCTAssertEqual(viewModel.railTranscriptEntries.first?.text, "Cancelled")
        XCTAssertFalse(viewModel.railTranscriptEntries.contains { $0.text.contains("Failure: Cancelled") })
    }

    func testCoordinatorTransportStatusesCoalesceIntoCurrentActivity() {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        var mcpSnapshots: [UUID: AgentRunMCPSnapshot] = [
            coordinatorID: mcpSnapshot(
                sessionID: coordinatorID,
                tabID: coordinatorTab,
                sessionName: "Coordinator",
                status: .running,
                statusText: "Queued to start",
                assistantPreview: nil,
                parent: nil
            )
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: coordinatorTab,
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .running,
                            isMCP: true
                        )
                    ],
                    mcpSnapshots: mcpSnapshots,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in }
        )

        viewModel.refresh()

        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertEqual(viewModel.currentRailActivityText, "Queued to start")

        mcpSnapshots[coordinatorID] = mcpSnapshot(
            sessionID: coordinatorID,
            tabID: coordinatorTab,
            sessionName: "Coordinator",
            status: .running,
            statusText: "Connecting…",
            assistantPreview: nil,
            parent: nil
        )

        viewModel.refresh()

        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertEqual(viewModel.currentRailActivityText, "Connecting")

        mcpSnapshots[coordinatorID] = mcpSnapshot(
            sessionID: coordinatorID,
            tabID: coordinatorTab,
            sessionName: "Coordinator",
            status: .running,
            statusText: "Thinking…",
            assistantPreview: nil,
            parent: nil
        )

        viewModel.refresh()

        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertEqual(viewModel.currentRailActivityText, "Coordinator is thinking")

        mcpSnapshots[coordinatorID] = mcpSnapshot(
            sessionID: coordinatorID,
            tabID: coordinatorTab,
            sessionName: "Coordinator",
            status: .completed,
            statusText: "Run complete",
            assistantPreview: "Done.",
            parent: nil
        )

        viewModel.refresh()

        XCTAssertNil(viewModel.currentRailActivityText)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.coordinator])
        XCTAssertEqual(viewModel.railTranscriptEntries.first?.text, "Done.")
    }

    func testVisibleLifecycleRefreshPublishesRunningDelegatedSnapshot() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let coordinatorTab = uuid(101)
        let childTab = uuid(102)
        var mcpSnapshots: [UUID: AgentRunMCPSnapshot] = [:]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: coordinatorTab,
                            title: "Coordinator Runtime Demo",
                            updatedAt: self.date(20),
                            state: .idle,
                            isMCP: true
                        )
                    ],
                    mcpSnapshots: mcpSnapshots,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in }
        )
        viewModel.setVisible(true)
        XCTAssertEqual(viewModel.snapshot.counts.totalRows, 0)

        viewModel.setVisible(false)
        mcpSnapshots[childID] = mcpSnapshot(
            sessionID: childID,
            tabID: childTab,
            sessionName: "Live delegate",
            status: .running,
            statusText: "Working on loopback proof",
            assistantPreview: "COORDINATOR_LOOPBACK_WORKING",
            parent: coordinatorID
        )
        XCTAssertFalse(viewModel.refreshIfVisible())
        XCTAssertEqual(viewModel.snapshot.counts.totalRows, 0)

        viewModel.setVisible(true)

        let row = viewModel.snapshot.groups.first { $0.group == .working }?.rows.first
        XCTAssertEqual(viewModel.snapshot.counts.totalRows, 1)
        XCTAssertEqual(row?.sessionID, childID)
        XCTAssertEqual(row?.title, "Live delegate")
        XCTAssertEqual(row?.runState, .running)
        XCTAssertEqual(row?.statusReport?.statusText, "Working on loopback proof")
        XCTAssertEqual(row?.statusReport?.assistantPreview, "COORDINATOR_LOOPBACK_WORKING")
    }

    func testNewDirectDelegateAddsSingleCoordinatorActionEntry() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let coordinatorTab = uuid(101)
        let childTab = uuid(102)
        var liveSessions = [
            live(
                id: coordinatorID,
                tab: coordinatorTab,
                title: "Coordinator Runtime Demo",
                updatedAt: date(20),
                state: .idle,
                isMCP: true
            )
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in }
        )

        viewModel.refresh()
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)

        liveSessions.append(live(
            id: childID,
            tab: childTab,
            title: "README probe",
            updatedAt: date(30),
            state: .running,
            parent: coordinatorID,
            isMCP: true
        ))
        viewModel.refresh()

        let actionEntries = viewModel.railTranscriptEntries.compactMap(\.action)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.event])
        XCTAssertEqual(actionEntries.count, 1)
        XCTAssertEqual(actionEntries.first?.ownerCoordinatorSessionID, coordinatorID)
        XCTAssertEqual(actionEntries.first?.ownerTitle, "Coordinator Runtime Demo")
        XCTAssertEqual(actionEntries.first?.targetSessionID, childID)
        XCTAssertEqual(actionEntries.first?.targetTitle, "README probe")
        XCTAssertEqual(actionEntries.first?.verb, .delegate)
        XCTAssertEqual(actionEntries.first?.phase, .resolved)

        liveSessions[1] = live(
            id: childID,
            tab: childTab,
            title: "README probe",
            updatedAt: date(40),
            state: .idle,
            parent: coordinatorID,
            isMCP: true
        )
        viewModel.refresh()

        XCTAssertEqual(viewModel.railTranscriptEntries.compactMap(\.action).count, 1)
    }

    func testExistingRunningDelegateAddsCoordinatorActionEntryOnInitialSelection() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator Runtime Demo",
                            updatedAt: self.date(20),
                            state: .idle,
                            isMCP: true
                        ),
                        self.live(
                            id: childID,
                            tab: self.uuid(102),
                            title: "Delegated docs change",
                            updatedAt: self.date(30),
                            state: .running,
                            parent: coordinatorID,
                            isMCP: true,
                            workflow: .orchestrate,
                            bindings: [self.binding(label: "rp/agent/docs-change", color: "#22C55E")]
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in }
        )

        viewModel.refresh()

        let actions: [CoordinatorModeCoordinatorAction] = viewModel.railTranscriptEntries.compactMap(\.action)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.event])
        XCTAssertEqual(actions.map(\.targetSessionID), [childID])
        XCTAssertEqual(actions.first?.ownerCoordinatorSessionID, coordinatorID)
        XCTAssertEqual(actions.first?.targetTitle, "Delegated docs change")
        XCTAssertEqual(actions.first?.verb, .delegate)
        XCTAssertEqual(actions.first?.statusGroup, .working)
        XCTAssertEqual(actions.first?.workflow, .orchestrate)
        XCTAssertEqual(actions.first?.workstream?.label, "rp/agent/docs-change")
        XCTAssertEqual(actions.first?.workstream?.colorHex, "#22C55E")

        viewModel.refresh()

        XCTAssertEqual(viewModel.railTranscriptEntries.compactMap(\.action).map(\.targetSessionID), [childID])
    }

    func testPersistedDelegateActionEntriesUseStartChronologyAfterRestart() {
        let coordinatorID = uuid(1)
        let orchestrateID = uuid(2)
        let reviewID = uuid(3)
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    persisted: [
                        self.persisted(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator Runtime Demo",
                            updatedAt: self.date(80),
                            state: .completed,
                            isMCP: true
                        ),
                        self.persisted(
                            id: reviewID,
                            tab: self.uuid(103),
                            title: "Smoke Review README summary",
                            startedAt: self.date(50),
                            updatedAt: self.date(70),
                            state: .completed,
                            parent: coordinatorID,
                            isMCP: true,
                            workflow: .init(AgentWorkflow.review.definition)
                        ),
                        self.persisted(
                            id: orchestrateID,
                            tab: self.uuid(102),
                            title: "Smoke Orchestrate README summary",
                            startedAt: self.date(30),
                            updatedAt: self.date(90),
                            state: .completed,
                            parent: coordinatorID,
                            isMCP: true,
                            workflow: .orchestrate
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in }
        )

        viewModel.refresh()

        let actionEntries = viewModel.railTranscriptEntries.filter { $0.action != nil }
        XCTAssertEqual(actionEntries.map(\.action?.targetSessionID), [orchestrateID, reviewID])
        XCTAssertEqual(actionEntries.map(\.createdAt), [date(30), date(50)])
    }

    func testSelectingCoordinatorRebuildsDelegateActionEntriesForSelectedParent() {
        let firstCoordinatorID = uuid(1)
        let firstChildID = uuid(2)
        let secondCoordinatorID = uuid(3)
        let secondChildID = uuid(4)
        var liveSessions = [
            live(
                id: firstCoordinatorID,
                tab: uuid(101),
                title: "Parent A",
                updatedAt: date(20),
                state: .idle,
                isMCP: true
            ),
            live(
                id: firstChildID,
                tab: uuid(102),
                title: "A child",
                updatedAt: date(30),
                state: .completed,
                parent: firstCoordinatorID,
                isMCP: true
            ),
            live(
                id: secondCoordinatorID,
                tab: uuid(103),
                title: "Parent B",
                updatedAt: date(40),
                state: .idle,
                isMCP: true
            )
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [firstCoordinatorID, secondCoordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in }
        )

        viewModel.refresh()

        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, secondCoordinatorID)
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)

        liveSessions.append(live(
            id: secondChildID,
            tab: uuid(104),
            title: "B child",
            updatedAt: date(50),
            state: .completed,
            parent: secondCoordinatorID,
            isMCP: true
        ))
        viewModel.refresh()

        XCTAssertEqual(viewModel.railTranscriptEntries.compactMap(\.action).map(\.targetSessionID), [secondChildID])
        XCTAssertEqual(viewModel.railTranscriptEntries.compactMap(\.action).first?.ownerCoordinatorSessionID, secondCoordinatorID)

        viewModel.selectCoordinator(sessionID: firstCoordinatorID)

        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, firstCoordinatorID)
        XCTAssertEqual(viewModel.railTranscriptEntries.compactMap(\.action).map(\.targetSessionID), [firstChildID])
        XCTAssertEqual(viewModel.railTranscriptEntries.compactMap(\.action).first?.ownerCoordinatorSessionID, firstCoordinatorID)
    }

    func testMidRunCoordinatorRejectsDirectiveWithoutCallingSubmitter() async {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let input = input(
            persisted: [
                persisted(id: childID, tab: uuid(102), title: "Child", updatedAt: date(10), parent: coordinatorID)
            ],
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator", updatedAt: date(20), state: .running, isMCP: true)
            ],
            demoCoordinatorIDs: [coordinatorID]
        )
        var submitterCalled = false
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                if let selectedCoordinatorID {
                    next.selectedCoordinatorID = selectedCoordinatorID
                }
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { _ in
                submitterCalled = true
                return .accepted
            }
        )
        viewModel.refresh()
        XCTAssertTrue(viewModel.snapshot.coordinatorRail.isComposerEnabled)
        XCTAssertFalse(viewModel.snapshot.coordinatorRail.isComposerSendEnabled)

        let result = await viewModel.submitCoordinatorDirective("message")

        XCTAssertEqual(result, .rejected(message: "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary."))
        XCTAssertFalse(submitterCalled)
        XCTAssertEqual(viewModel.railTranscriptEntries.compactMap(\.action).map(\.targetSessionID), [childID])
    }

    func testCoordinatorQuestionBoundaryAcceptsDirective() async {
        let coordinatorID = uuid(1)
        let input = input(
            live: [
                live(
                    id: coordinatorID,
                    tab: uuid(101),
                    title: "Coordinator",
                    updatedAt: date(20),
                    state: .waitingForQuestion,
                    isMCP: true,
                    coordinatorRuntime: true
                )
            ],
            demoCoordinatorIDs: [coordinatorID]
        )
        var submissions: [CoordinatorDirectiveSubmission] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                if let selectedCoordinatorID {
                    next.selectedCoordinatorID = selectedCoordinatorID
                }
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append(submission)
                return .accepted
            }
        )
        viewModel.refresh()
        XCTAssertTrue(viewModel.snapshot.coordinatorRail.isComposerEnabled)
        XCTAssertTrue(viewModel.snapshot.coordinatorRail.isComposerSendEnabled)

        let result = await viewModel.submitCoordinatorDirective("Proceed with the approved plan.")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.map(\.visibleText), ["Proceed with the approved plan."])
        XCTAssertEqual(submissions.first?.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, false)
    }

    func testForceNewCoordinatorRuntimeAddsRuntimeEvenWhenOldRuntimeIsMarked() async throws {
        let oldTabID = uuid(301)
        let oldSessionID = uuid(302)
        var oldTab = ComposeTabState(id: oldTabID, name: "Coordinator Runtime Demo", activeAgentSessionID: oldSessionID)
        oldTab.lastModified = date(20)
        let fixture = makeAgentModeFixture(tabs: [oldTab], activeTabID: oldTabID)
        let viewModel = fixture.viewModel
        let oldSession = await viewModel.ensureSessionReady(tabID: oldTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: oldSessionID, on: oldSession)
        oldSession.isCoordinatorRuntimeDemo = true

        let next = try await viewModel.test_resolveOrCreateCoordinatorRuntimeDemoTarget(
            preferredSessionID: oldSessionID,
            forceNewRuntime: true
        )

        XCTAssertNotEqual(next.tabID, oldTabID)
        XCTAssertNotEqual(next.sessionID, oldSessionID)
        XCTAssertTrue(oldSession.isCoordinatorRuntimeDemo)
        XCTAssertEqual(fixture.manager.composeTabName(with: oldTabID), "Coordinator Runtime Demo")
        XCTAssertTrue(viewModel.sessions[next.tabID]?.isCoordinatorRuntimeDemo == true)
        XCTAssertTrue(viewModel.sessions[next.tabID]?.isCoordinatorRuntime == true)
    }

    func testCoordinatorRuntimeExplicitModelOverrideKeepsCoordinatorIdentity() async throws {
        let fixture = makeAgentModeFixture(tabs: [], activeTabID: nil)
        let viewModel = fixture.viewModel

        let next = try await viewModel.test_resolveOrCreateCoordinatorRuntimeDemoTarget(
            preferredSessionID: nil,
            forceNewRuntime: true,
            coordinatorModelID: "\(AgentProviderKind.codexExec.rawValue):\(AgentModel.gpt55CodexLow.rawValue)"
        )
        let session = try XCTUnwrap(viewModel.sessions[next.tabID])

        XCTAssertTrue(session.isCoordinatorRuntime)
        XCTAssertEqual(session.mcpControlContext?.taskLabelKind, .coordinator)
        XCTAssertEqual(session.selectedAgent, .codexExec)
        XCTAssertEqual(session.selectedModelRaw, "gpt-5.5")
        XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.low.rawValue)
    }

    func testCoordinatorRuntimeRoleModelOverrideKeepsCoordinatorIdentity() async throws {
        let fixture = makeAgentModeFixture(tabs: [], activeTabID: nil)
        let viewModel = fixture.viewModel

        let next = try await viewModel.test_resolveOrCreateCoordinatorRuntimeDemoTarget(
            preferredSessionID: nil,
            forceNewRuntime: true,
            coordinatorModelID: "engineer"
        )
        let session = try XCTUnwrap(viewModel.sessions[next.tabID])

        XCTAssertTrue(session.isCoordinatorRuntime)
        XCTAssertEqual(session.mcpControlContext?.taskLabelKind, .coordinator)
        XCTAssertEqual(session.selectedAgent, .codexExec)
        XCTAssertEqual(session.selectedModelRaw, "gpt-5.5")
        XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.low.rawValue)
    }

    func testCoordinatorRuntimeRejectsScriptedModelOverride() async throws {
        let fixture = makeAgentModeFixture(tabs: [], activeTabID: nil)
        let viewModel = fixture.viewModel

        do {
            _ = try await viewModel.test_resolveOrCreateCoordinatorRuntimeDemoTarget(
                preferredSessionID: nil,
                forceNewRuntime: true,
                coordinatorModelID: "scripted"
            )
            XCTFail("Coordinator runtimes must not accept scripted child model selectors.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("scripted"))
        }
    }

    func testSelectedCoordinatorRuntimeRefreshesStaleControlLabel() async throws {
        let tabID = uuid(331)
        let sessionID = uuid(332)
        let tab = ComposeTabState(id: tabID, name: "Coordinator Runtime Demo", activeAgentSessionID: sessionID)
        let fixture = makeAgentModeFixture(tabs: [tab], activeTabID: tabID)
        let viewModel = fixture.viewModel
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            taskLabelKind: .pair
        )
        XCTAssertEqual(session.mcpControlContext?.taskLabelKind, .pair)

        let target = try await viewModel.test_resolveOrCreateCoordinatorRuntimeDemoTarget(
            preferredSessionID: sessionID
        )

        XCTAssertEqual(target.tabID, tabID)
        XCTAssertEqual(target.sessionID, sessionID)
        XCTAssertTrue(session.isCoordinatorRuntime)
        XCTAssertEqual(session.mcpControlContext?.taskLabelKind, .coordinator)
    }

    func testResolverWithoutSelectedRuntimeCreatesInsteadOfGuessingByMarkerOrName() async throws {
        let oldTabID = uuid(201)
        let oldSessionID = uuid(202)
        let namedTabID = uuid(203)
        let namedSessionID = uuid(204)
        var oldTab = ComposeTabState(id: oldTabID, name: "Coordinator Runtime Demo", activeAgentSessionID: oldSessionID)
        oldTab.lastModified = date(20)
        var namedTab = ComposeTabState(id: namedTabID, name: "Coordinator Runtime Demo", activeAgentSessionID: namedSessionID)
        namedTab.lastModified = date(30)
        let fixture = makeAgentModeFixture(tabs: [oldTab, namedTab], activeTabID: oldTabID)
        let viewModel = fixture.viewModel
        let oldSession = await viewModel.ensureSessionReady(tabID: oldTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: oldSessionID, on: oldSession)
        oldSession.isCoordinatorRuntimeDemo = true
        let namedSession = await viewModel.ensureSessionReady(tabID: namedTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: namedSessionID, on: namedSession)

        let next = try await viewModel.test_resolveOrCreateCoordinatorRuntimeDemoTarget(preferredSessionID: nil)

        XCTAssertNotEqual(next.tabID, oldTabID)
        XCTAssertNotEqual(next.tabID, namedTabID)
        XCTAssertNotEqual(next.sessionID, oldSessionID)
        XCTAssertNotEqual(next.sessionID, namedSessionID)
        XCTAssertTrue(oldSession.isCoordinatorRuntimeDemo)
        XCTAssertFalse(namedSession.isCoordinatorRuntimeDemo)
        XCTAssertTrue(viewModel.sessions[next.tabID]?.isCoordinatorRuntimeDemo == true)
        XCTAssertTrue(viewModel.sessions[next.tabID]?.isCoordinatorRuntime == true)
    }

    func testSnapshotInputKeepsCoordinatorRuntimeAsParentWithoutRenderingItAsWork() async {
        let coordinatorTabID = uuid(301)
        let coordinatorSessionID = uuid(302)
        let childTabID = uuid(303)
        let childSessionID = uuid(304)
        let fixture = makeAgentModeFixture(tabs: [
            ComposeTabState(id: coordinatorTabID, name: "Coordinator Runtime Demo", activeAgentSessionID: coordinatorSessionID),
            ComposeTabState(id: childTabID, name: "Investigate README", activeAgentSessionID: childSessionID)
        ], activeTabID: coordinatorTabID)
        let viewModel = fixture.viewModel
        let coordinator = await viewModel.ensureSessionReady(tabID: coordinatorTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: coordinatorSessionID, on: coordinator)
        coordinator.isCoordinatorRuntime = true
        coordinator.runState = .idle
        let child = await viewModel.ensureSessionReady(tabID: childTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: childSessionID, on: child)
        child.parentSessionID = coordinatorSessionID
        child.isMCPOriginated = true
        child.runState = .running

        let snapshot = CoordinatorModeSnapshotProjector().project(
            viewModel.coordinatorModeSnapshotInput(selectedCoordinatorID: coordinatorSessionID)
        )

        XCTAssertEqual(snapshot.coordinatorRail.coordinatorSessionID, coordinatorSessionID)
        XCTAssertEqual(snapshot.counts.totalRows, 1)
        XCTAssertEqual(snapshot.groups.flatMap(\.rows).map(\.sessionID), [childSessionID])
        XCTAssertFalse(snapshot.groups.flatMap(\.rows).contains { $0.sessionID == coordinatorSessionID })
        XCTAssertEqual(snapshot.groups.flatMap(\.rows).first?.parentSessionID, coordinatorSessionID)
    }

    func testNewCoordinatorRunPreservesExistingRuntimeBeforeNextDirective() async {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        let demoCoordinatorIDs: Set<UUID> = [coordinatorID]
        let persistedTranscript = [
            transcriptEntry(id: uuid(901), role: .user, text: "old directive", at: date(21)),
            transcriptEntry(id: uuid(902), role: .coordinator, text: "old answer", at: date(22))
        ]
        var submissions: [(text: String, sessionID: UUID?, forceNewRuntime: Bool)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator Runtime Demo", updatedAt: self.date(20), state: .idle, isMCP: true)
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: demoCoordinatorIDs
                )
            },
            transcriptProvider: { sessionID in
                sessionID == coordinatorID ? persistedTranscript : []
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append((submission.providerText, submission.coordinatorSessionID, submission.forceNewRuntime))
                return .accepted
            }
        )
        viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.selectionSource, .demoRuntime)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.text), ["old directive", "old answer"])

        viewModel.startNewCoordinatorRun()
        XCTAssertEqual(demoCoordinatorIDs, [coordinatorID])
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.state, .chooseCoordinator)
        XCTAssertNil(viewModel.snapshot.coordinatorRail.coordinatorSessionID)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.title, nil)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.availableCoordinators.map(\.sessionID), [coordinatorID])
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.availableCoordinators.map(\.isSelected), [false])
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertTrue(viewModel.isFreshCoordinatorRunPending)
        XCTAssertNil(viewModel.composerNotice)

        let result = await viewModel.submitCoordinatorDirective("start fresh")

        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(submissions.first?.text.hasPrefix("start fresh\n\n---\nMission Policy (provider-only)") == true)
        XCTAssertNil(submissions.first?.sessionID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, true)
        XCTAssertTrue(viewModel.isFreshCoordinatorRunPending)
    }

    func testSelectingExistingCoordinatorCancelsPendingFreshRunAndRestoresTranscript() {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        let persistedTranscript = [
            transcriptEntry(id: uuid(901), role: .user, text: "saved directive", at: date(21)),
            transcriptEntry(id: uuid(902), role: .coordinator, text: "saved answer", at: date(22))
        ]
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: coordinatorTab,
                            title: "Saved coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            isMCP: true
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            transcriptProvider: { sessionID in
                sessionID == coordinatorID ? persistedTranscript : []
            },
            dashboardVisibilityHandler: { _ in }
        )
        viewModel.refresh()

        viewModel.startNewCoordinatorRun()
        viewModel.selectCoordinator(sessionID: coordinatorID)

        XCTAssertFalse(viewModel.isFreshCoordinatorRunPending)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.state, .selected)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.text), ["saved directive", "saved answer"])
    }

    func testNewCoordinatorDirectiveSelectsCreatedRuntime() async {
        let firstCoordinatorID = uuid(1)
        let secondCoordinatorID = uuid(2)
        let firstTabID = uuid(101)
        let secondTabID = uuid(102)
        var liveSessions = [
            live(
                id: firstCoordinatorID,
                tab: firstTabID,
                title: "First coordinator",
                updatedAt: date(20),
                state: .idle,
                isMCP: true
            )
        ]
        var demoCoordinatorIDs: Set<UUID> = [firstCoordinatorID]
        var submissions: [(text: String, sessionID: UUID?, forceNewRuntime: Bool)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: liveSessions,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: demoCoordinatorIDs
                )
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                submissions.append((submission.providerText, submission.coordinatorSessionID, submission.forceNewRuntime))
                liveSessions.append(self.live(
                    id: secondCoordinatorID,
                    tab: secondTabID,
                    title: "Second coordinator",
                    updatedAt: self.date(30),
                    state: .idle,
                    isMCP: true
                ))
                demoCoordinatorIDs.insert(secondCoordinatorID)
                return .accepted
            }
        )
        viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, firstCoordinatorID)

        viewModel.startNewCoordinatorRun()
        let result = await viewModel.submitCoordinatorDirective("start another parent")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.first?.sessionID, nil)
        XCTAssertEqual(submissions.first?.forceNewRuntime, true)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, secondCoordinatorID)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.title, "Second coordinator")
        XCTAssertEqual(
            viewModel.snapshot.coordinatorRail.availableCoordinators.map(\.sessionID),
            [secondCoordinatorID, firstCoordinatorID]
        )
    }

    func testUnreachableCoordinatorRejectsDirectiveWithoutCallingSubmitter() async {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let input = input(
            persisted: [
                persisted(id: coordinatorID, tab: uuid(101), title: "Coordinator", updatedAt: date(20), isMCP: true),
                persisted(id: childID, tab: uuid(102), title: "Child", updatedAt: date(10), parent: coordinatorID)
            ],
            demoCoordinatorIDs: [coordinatorID]
        )
        var submitterCalled = false
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                if let selectedCoordinatorID {
                    next.selectedCoordinatorID = selectedCoordinatorID
                }
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { _ in
                submitterCalled = true
                return .accepted
            }
        )
        viewModel.refresh()
        XCTAssertFalse(viewModel.snapshot.coordinatorRail.isComposerEnabled)

        let result = await viewModel.submitCoordinatorDirective("message")

        XCTAssertEqual(result, .rejected(message: "Coordinator is not available in this window."))
        XCTAssertFalse(submitterCalled)
        XCTAssertEqual(viewModel.railTranscriptEntries.compactMap(\.action).map(\.targetSessionID), [childID])
        XCTAssertEqual(viewModel.composerNotice, "Coordinator is not available in this window.")
    }

    func testActivePendingChildInteractionUsesSelectedCoordinatorScope() {
        let selectedCoordinatorID = uuid(1)
        let selectedChildID = uuid(2)
        let otherCoordinatorID = uuid(3)
        let otherChildID = uuid(4)
        let selectedQuestion = pendingQuestionInteraction(
            id: uuid(900),
            title: "Deep Plan checkpoint",
            prompt: "How involved do you want to be?"
        )
        let otherQuestion = pendingQuestionInteraction(
            id: uuid(901),
            title: "Other checkpoint",
            prompt: "Unrelated question"
        )
        let input = input(
            live: [
                live(id: selectedCoordinatorID, tab: uuid(101), title: "Selected mission", updatedAt: date(40), state: .idle, isMCP: true),
                live(id: selectedChildID, tab: uuid(102), title: "Deep Plan child", updatedAt: date(10), state: .waitingForQuestion, parent: selectedCoordinatorID),
                live(id: otherCoordinatorID, tab: uuid(103), title: "Other mission", updatedAt: date(30), state: .idle, isMCP: true),
                live(id: otherChildID, tab: uuid(104), title: "Other child", updatedAt: date(5), state: .waitingForQuestion, parent: otherCoordinatorID)
            ],
            mcpSnapshots: [
                selectedChildID: mcpSnapshot(
                    sessionID: selectedChildID,
                    tabID: uuid(102),
                    sessionName: "Deep Plan child",
                    status: .waitingForInput,
                    statusText: "Waiting for your answer",
                    assistantPreview: nil,
                    parent: selectedCoordinatorID,
                    interaction: selectedQuestion
                ),
                otherChildID: mcpSnapshot(
                    sessionID: otherChildID,
                    tabID: uuid(104),
                    sessionName: "Other child",
                    status: .waitingForInput,
                    statusText: "Waiting for your answer",
                    assistantPreview: nil,
                    parent: otherCoordinatorID,
                    interaction: otherQuestion
                )
            ],
            selectedCoordinatorID: selectedCoordinatorID,
            demoCoordinatorIDs: [selectedCoordinatorID, otherCoordinatorID]
        )
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                if let selectedCoordinatorID {
                    next.selectedCoordinatorID = selectedCoordinatorID
                }
                return next
            },
            dashboardVisibilityHandler: { _ in }
        )

        viewModel.refresh()

        let row = viewModel.activePendingChildInteractionRow()
        XCTAssertEqual(row?.sessionID, selectedChildID)
        XCTAssertEqual(row?.pendingInteraction?.id, selectedQuestion.id)
        XCTAssertEqual(row?.statusGroup, .needsYou)
    }

    func testDirectorRoutedChildInteractionRecoversSuppressedRowAndRecordsLedger() async throws {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let interactionID = uuid(900)
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = .auto
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Answer child question.",
            status: .running,
            approvalState: .approved,
            policySnapshot: policy,
            autonomy: policy.autonomy
        ))
        let question = pendingQuestionInteraction(
            id: interactionID,
            title: "Child checkpoint",
            prompt: "Choose Alpha or Beta."
        )
        var childSubmissions: [(submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission, row: CoordinatorModeRow)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator mission",
                            updatedAt: self.date(40),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: state.missionPlan
                        ),
                        self.live(
                            id: childID,
                            tab: self.uuid(102),
                            title: "Child",
                            updatedAt: self.date(30),
                            state: .waitingForQuestion,
                            parent: coordinatorID
                        )
                    ],
                    mcpSnapshots: [
                        childID: self.mcpSnapshot(
                            sessionID: childID,
                            tabID: self.uuid(102),
                            sessionName: "Child",
                            status: .waitingForInput,
                            statusText: "Waiting",
                            assistantPreview: nil,
                            parent: coordinatorID,
                            interaction: question
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in },
            childInteractionResponseSubmitter: { submission, row in
                childSubmissions.append((submission, row))
                return .accepted
            },
            missionPlanUpdater: { _, update in
                state.updateMissionPlan(update)
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        let visualChildRow = try XCTUnwrap(viewModel.snapshot.groups.flatMap(\.rows).first { $0.sessionID == childID })
        XCTAssertNil(visualChildRow.pendingInteraction)
        XCTAssertEqual(visualChildRow.statusGroup, .working)

        let routingRow = try XCTUnwrap(viewModel.activePendingChildInteractionRow())
        XCTAssertEqual(routingRow.sessionID, childID)
        XCTAssertEqual(routingRow.pendingInteraction?.id, interactionID)

        let result = await viewModel.submitPendingChildInteractionResponse(.text("Alpha"), to: routingRow, actor: .director)

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(childSubmissions.first?.row.pendingInteraction?.id, interactionID)
        let decision = try XCTUnwrap(state.missionPlan?.decisions.first)
        XCTAssertEqual(decision.actor, .director)
        XCTAssertEqual(decision.resolvedAutonomyClass, .childAsk)
        XCTAssertEqual(decision.interactionID, interactionID)
        let evidence = try XCTUnwrap(state.missionPlan?.evidence.first)
        XCTAssertEqual(evidence.interactionID, interactionID)
        XCTAssertEqual(evidence.decisionID, decision.id)
    }

    func testMissionBoundChildQuestionsRedirectAgentRunRespondForMeAndDirectorRouting() throws {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let interactionID = uuid(900)

        for mode in [CoordinatorMissionAutonomyMode.ask, .auto] {
            var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
            policy.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = mode
            let plan = CoordinatorMissionPlan(
                objective: "Answer child question.",
                status: .running,
                approvalState: .approved,
                policySnapshot: policy,
                autonomy: policy.autonomy
            )
            let question = pendingQuestionInteraction(
                id: interactionID,
                title: "Child checkpoint",
                prompt: "Choose Alpha or Beta."
            )
            let viewModel = CoordinatorModeViewModel(
                inputProvider: { sortMode, selectedCoordinatorID in
                    self.input(
                        live: [
                            self.live(
                                id: coordinatorID,
                                tab: self.uuid(101),
                                title: "Coordinator mission",
                                updatedAt: self.date(40),
                                state: .idle,
                                coordinatorRuntime: true,
                                missionPlan: plan
                            ),
                            self.live(
                                id: childID,
                                tab: self.uuid(102),
                                title: "Child",
                                updatedAt: self.date(30),
                                state: .waitingForQuestion,
                                parent: coordinatorID
                            )
                        ],
                        mcpSnapshots: [
                            childID: self.mcpSnapshot(
                                sessionID: childID,
                                tabID: self.uuid(102),
                                sessionName: "Child",
                                status: .waitingForInput,
                                statusText: "Waiting",
                                assistantPreview: nil,
                                parent: coordinatorID,
                                interaction: question
                            )
                        ],
                        selectedCoordinatorID: selectedCoordinatorID,
                        sort: sortMode,
                        demoCoordinatorIDs: [coordinatorID]
                    )
                },
                dashboardVisibilityHandler: { _ in }
            )
            viewModel.selectCoordinator(sessionID: coordinatorID)

            let redirect = try XCTUnwrap(viewModel.missionBoundChildInteractionRespondRedirectMessage(
                sessionID: childID,
                interactionID: interactionID
            ))
            XCTAssertTrue(redirect.contains("coordinator_chat op=submit"), redirect)
            XCTAssertTrue(redirect.contains(coordinatorID.uuidString), redirect)
            XCTAssertNil(viewModel.missionBoundChildInteractionRespondRedirectMessage(
                sessionID: childID,
                interactionID: uuid(901)
            ))
        }

        var autoPolicy = CoordinatorMissionPolicySnapshot.defaultPolicy
        autoPolicy.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = .auto
        let planBoundCoordinatorID = uuid(11)
        let planBoundChildID = uuid(12)
        let planBoundInteractionID = uuid(902)
        let workstreamID = uuid(20)
        let planBoundPlan = CoordinatorMissionPlan(
            objective: "Answer suppressed child question.",
            status: .running,
            approvalState: .approved,
            policySnapshot: autoPolicy,
            autonomy: autoPolicy.autonomy,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: uuid(30),
                    title: "Ask scripted child",
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: planBoundChildID,
                    boundInteractionID: planBoundInteractionID
                )
            ]
        )
        let planBoundViewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: planBoundCoordinatorID,
                            tab: self.uuid(111),
                            title: "Auto coordinator",
                            updatedAt: self.date(40),
                            state: .idle,
                            coordinatorRuntime: true,
                            missionPlan: planBoundPlan
                        ),
                        self.live(
                            id: planBoundChildID,
                            tab: self.uuid(112),
                            title: "Suppressed child",
                            updatedAt: self.date(30),
                            state: .waitingForQuestion,
                            parent: planBoundCoordinatorID
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [planBoundCoordinatorID]
                )
            },
            dashboardVisibilityHandler: { _ in }
        )
        planBoundViewModel.selectCoordinator(sessionID: planBoundCoordinatorID)

        let planBoundRedirect = try XCTUnwrap(planBoundViewModel.missionBoundChildInteractionRespondRedirectMessage(
            sessionID: planBoundChildID,
            interactionID: planBoundInteractionID
        ))
        XCTAssertTrue(planBoundRedirect.contains("coordinator_chat op=submit"), planBoundRedirect)
        XCTAssertTrue(planBoundRedirect.contains(planBoundCoordinatorID.uuidString), planBoundRedirect)
        XCTAssertNil(planBoundViewModel.missionBoundChildInteractionRespondRedirectMessage(
            sessionID: uuid(13),
            interactionID: uuid(903)
        ))

        let nonMissionViewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: childID,
                            tab: self.uuid(102),
                            title: "Ordinary child",
                            updatedAt: self.date(30),
                            state: .waitingForQuestion
                        )
                    ],
                    mcpSnapshots: [
                        childID: self.mcpSnapshot(
                            sessionID: childID,
                            tabID: self.uuid(102),
                            sessionName: "Ordinary child",
                            status: .waitingForInput,
                            statusText: "Waiting",
                            assistantPreview: nil,
                            parent: nil,
                            interaction: self.pendingQuestionInteraction(
                                id: interactionID,
                                title: "Ordinary question",
                                prompt: "Choose Alpha or Beta."
                            )
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    autoSelectDemoCoordinator: false,
                    sort: sortMode
                )
            },
            dashboardVisibilityHandler: { _ in }
        )
        nonMissionViewModel.refresh()

        XCTAssertNil(nonMissionViewModel.missionBoundChildInteractionRespondRedirectMessage(
            sessionID: childID,
            interactionID: interactionID
        ))
    }

    func testPendingChildInteractionResponseForwardsToChildAndRecordsVisibleAnswer() async throws {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let question = pendingQuestionInteraction(
            id: uuid(900),
            title: "Deep Plan checkpoint",
            prompt: "How involved do you want to be?"
        )
        let input = input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator mission", updatedAt: date(40), state: .idle, isMCP: true),
                live(id: childID, tab: uuid(102), title: "Deep Plan child", updatedAt: date(10), state: .waitingForQuestion, parent: coordinatorID)
            ],
            mcpSnapshots: [
                childID: mcpSnapshot(
                    sessionID: childID,
                    tabID: uuid(102),
                    sessionName: "Deep Plan child",
                    status: .waitingForInput,
                    statusText: "Waiting for your answer",
                    assistantPreview: nil,
                    parent: coordinatorID,
                    interaction: question
                )
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        )
        var childSubmissions: [(text: String, rowID: UUID)] = []
        var recordedChildResponses: [(text: String, rowID: UUID)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                if let selectedCoordinatorID {
                    next.selectedCoordinatorID = selectedCoordinatorID
                }
                return next
            },
            dashboardVisibilityHandler: { _ in },
            childDirectiveSubmitter: { text, row in
                childSubmissions.append((text, row.sessionID))
                return .accepted
            },
            childInteractionResponseRecorder: { text, row in
                recordedChildResponses.append((text, row.sessionID))
            }
        )
        viewModel.refresh()
        let row = try XCTUnwrap(viewModel.activePendingChildInteractionRow())

        let result = await viewModel.submitPendingChildInteractionResponse("  Keep me involved at review checkpoints.  ", to: row)

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(childSubmissions.count, 1)
        XCTAssertEqual(childSubmissions.first?.text, "Keep me involved at review checkpoints.")
        XCTAssertEqual(childSubmissions.first?.rowID, childID)
        XCTAssertEqual(recordedChildResponses.count, 1)
        XCTAssertEqual(recordedChildResponses.first?.text, "Keep me involved at review checkpoints.")
        XCTAssertEqual(recordedChildResponses.first?.rowID, childID)
        XCTAssertNil(viewModel.composerNotice)
        XCTAssertTrue(viewModel.railTranscriptEntries.contains { entry in
            entry.role == .event
                && entry.text == "You answered Deep Plan child:\n\nKeep me involved at review checkpoints."
        })

        viewModel.refresh()
        XCTAssertTrue(viewModel.railTranscriptEntries.contains { entry in
            entry.role == .event
                && entry.text == "You answered Deep Plan child:\n\nKeep me involved at review checkpoints."
        })

        var followThroughState = CoordinatorFollowThroughState(originalObjectiveSummary: "Demo")
        followThroughState.rememberChildInteractionResponse(
            row: row,
            text: "  Keep me involved at review checkpoints.  ",
            at: date(50)
        )
        let decodedState = try JSONDecoder().decode(
            CoordinatorFollowThroughState.self,
            from: JSONEncoder().encode(followThroughState)
        )
        XCTAssertEqual(decodedState.childInteractionResponses.count, 1)
        XCTAssertEqual(
            decodedState.childInteractionResponses.first?.transcriptText,
            "You answered Deep Plan child:\n\nKeep me involved at review checkpoints."
        )
    }

    func testStructuredPendingChildInteractionResponseForwardsSelectedOptions() async throws {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let question = pendingQuestionInteraction(
            id: uuid(901),
            title: "Deep Plan involvement",
            prompt: "How involved do you want to be?"
        )
        let input = input(
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator mission", updatedAt: date(40), state: .idle, isMCP: true),
                live(id: childID, tab: uuid(102), title: "Deep Plan child", updatedAt: date(10), state: .waitingForQuestion, parent: coordinatorID)
            ],
            mcpSnapshots: [
                childID: mcpSnapshot(
                    sessionID: childID,
                    tabID: uuid(102),
                    sessionName: "Deep Plan child",
                    status: .waitingForInput,
                    statusText: "Waiting for your answer",
                    assistantPreview: nil,
                    parent: coordinatorID,
                    interaction: question
                )
            ],
            selectedCoordinatorID: coordinatorID,
            demoCoordinatorIDs: [coordinatorID]
        )
        var childSubmissions: [(submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission, rowID: UUID)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                if let selectedCoordinatorID {
                    next.selectedCoordinatorID = selectedCoordinatorID
                }
                return next
            },
            dashboardVisibilityHandler: { _ in },
            childInteractionResponseSubmitter: { submission, row in
                childSubmissions.append((submission, row.sessionID))
                return .accepted
            }
        )
        viewModel.refresh()
        let row = try XCTUnwrap(viewModel.activePendingChildInteractionRow())

        let result = await viewModel.submitPendingChildInteractionResponse(
            CoordinatorModeViewModel.ChildInteractionResponseSubmission(
                text: nil,
                skip: false,
                answersByQuestionID: [
                    "involvement": AgentAskUserAnswer(
                        answers: ["Mid-flow"],
                        selectedOptions: ["Mid-flow"],
                        customResponse: nil,
                        skipped: false
                    )
                ],
                displayText: "Plan involvement: Mid-flow"
            ),
            to: row
        )

        XCTAssertEqual(result, .accepted)
        let submission = try XCTUnwrap(childSubmissions.first?.submission)
        XCTAssertEqual(submission.answersByQuestionID["involvement"]?.selectedOptions, ["Mid-flow"])
        XCTAssertEqual(childSubmissions.first?.rowID, childID)
        XCTAssertTrue(viewModel.railTranscriptEntries.contains { entry in
            entry.role == .event
                && entry.text == "You answered Deep Plan child:\n\nPlan involvement: Mid-flow"
        })
    }

    func testRevisionProposalProductionPersistenceBarrierSupportsExactSuccessAndRetryAfterFlushFailure() async throws {
        let harness = await makeRevisionProposalPersistenceHarness()
        var barrierAttempts = 0
        harness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { tabID, minimumGeneration in
            XCTAssertEqual(tabID, harness.tabID)
            XCTAssertGreaterThan(minimumGeneration, 0)
            barrierAttempts += 1
            return barrierAttempts > 1
        }

        do {
            _ = try await harness.coordinatorModeViewModel.appendRevisionProposal(
                coordinatorSessionID: harness.coordinatorID,
                request: harness.request
            )
            XCTFail("Expected the first persistence barrier attempt to fail.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not durably save"))
        }
        let pendingAfterFailure = try XCTUnwrap(
            harness.session.coordinatorFollowThroughState?.missionPlan?.pendingRevisionProposal
        )
        XCTAssertEqual(
            harness.session.coordinatorFollowThroughState?.missionPlan?.events
                .count(where: { $0.kind == .revisionProposalFiled }),
            1
        )

        let retryRequest = revisionProposalRequest(
            coordinatorID: harness.coordinatorID,
            plan: harness.plan,
            summary: "Retry summary intentionally differs.",
            rationale: "Retry rationale intentionally differs."
        )
        let retry = try await harness.coordinatorModeViewModel.appendRevisionProposal(
            coordinatorSessionID: harness.coordinatorID,
            request: retryRequest
        )

        XCTAssertEqual(retry.proposalID, pendingAfterFailure.id)
        XCTAssertEqual(retry.disposition, .existingPendingRetry)
        XCTAssertEqual(barrierAttempts, 2)
        let persistedPlan = try XCTUnwrap(harness.session.coordinatorFollowThroughState?.missionPlan)
        XCTAssertEqual(persistedPlan.pendingRevisionProposal, pendingAfterFailure)
        XCTAssertEqual(persistedPlan.decisions, [])
        XCTAssertEqual(persistedPlan.revisionProposalResolutions, [])
        XCTAssertEqual(
            persistedPlan.events.count(where: { $0.kind == .revisionProposalFiled }),
            1
        )
    }

    func testRevisionProposalResolutionPersistenceFailureStaysHeldAndIdenticalRetryClearsHold() async throws {
        let harness = await makeRevisionProposalPersistenceHarness()
        harness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in true }
        _ = try await harness.coordinatorModeViewModel.appendRevisionProposal(
            coordinatorSessionID: harness.coordinatorID,
            request: harness.request
        )
        let proposal = try XCTUnwrap(
            harness.session.coordinatorFollowThroughState?.missionPlan?.pendingRevisionProposal
        )
        let request = CoordinatorMissionRevisionProposalTrustedResolutionRequest(
            coordinatorSessionID: harness.coordinatorID,
            action: .keepCurrentPlan,
            proposalID: proposal.id,
            expectedContractFingerprint: proposal.baseContractFingerprint,
            expectedCheckpointInstanceID: CoordinatorMissionRevisionProposalCheckpoint.instanceID(
                coordinatorSessionID: harness.coordinatorID,
                proposal: proposal
            )
        )

        var resolutionBarrierAttempts = 0
        harness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in
            resolutionBarrierAttempts += 1
            return resolutionBarrierAttempts != 2
        }
        let failed = await harness.coordinatorModeViewModel.resolveRevisionProposal(request)
        guard case let .rejected(message) = failed else {
            return XCTFail("Expected failed resolution persistence.")
        }
        XCTAssertTrue(message.contains("authority remains held"), message)
        XCTAssertTrue(
            harness.session.coordinatorFollowThroughState?.missionPlan?.hasRevisionProposalDurabilityHold == true
        )
        XCTAssertEqual(
            harness.session.coordinatorFollowThroughState?.missionPlan?.revisionProposalResolutions.count,
            1
        )

        let retry = await harness.coordinatorModeViewModel.resolveRevisionProposal(request)
        XCTAssertEqual(retry, .accepted)
        XCTAssertFalse(
            harness.session.coordinatorFollowThroughState?.missionPlan?.hasRevisionProposalDurabilityHold == true
        )
        XCTAssertEqual(
            harness.session.coordinatorFollowThroughState?.missionPlan?.revisionProposalResolutions.count,
            1
        )
        XCTAssertEqual(harness.session.coordinatorFollowThroughState?.missionPlan?.approvalState, .approved)
        XCTAssertEqual(resolutionBarrierAttempts, 4)
    }

    func testStopAndContractChangeRetriesRecoverFailedProposalPersistence() async throws {
        let stopHarness = await makeRevisionProposalPersistenceHarness()
        stopHarness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in true }
        _ = try await stopHarness.coordinatorModeViewModel.appendRevisionProposal(
            coordinatorSessionID: stopHarness.coordinatorID,
            request: stopHarness.request
        )
        stopHarness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in false }
        let failedStop = await stopHarness.coordinatorModeViewModel.stopCoordinatorMission(
            targetMissionID: stopHarness.coordinatorID
        )
        guard case .rejected = failedStop else {
            return XCTFail("Expected Stop persistence failure.")
        }
        XCTAssertEqual(stopHarness.session.coordinatorFollowThroughState?.missionPlan?.status, .stopped)
        XCTAssertEqual(
            stopHarness.session.coordinatorFollowThroughState?.missionPlan?.revisionProposalDurabilityHold?.outcome,
            .stopped
        )
        stopHarness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in true }
        let stopRetry = await stopHarness.coordinatorModeViewModel.stopCoordinatorMission(
            targetMissionID: stopHarness.coordinatorID
        )
        XCTAssertEqual(stopRetry, .accepted)
        XCTAssertNil(
            stopHarness.session.coordinatorFollowThroughState?.missionPlan?.revisionProposalDurabilityHold
        )

        let contractHarness = await makeRevisionProposalPersistenceHarness()
        contractHarness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in true }
        _ = try await contractHarness.coordinatorModeViewModel.appendRevisionProposal(
            coordinatorSessionID: contractHarness.coordinatorID,
            request: contractHarness.request
        )
        contractHarness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in false }
        guard case .rejected = await contractHarness.coordinatorModeViewModel.setCoordinatorMissionPace(
            coordinatorSessionID: contractHarness.coordinatorID,
            pace: .auto
        ) else {
            return XCTFail("Expected contract-change persistence failure.")
        }
        XCTAssertEqual(
            contractHarness.session.coordinatorFollowThroughState?.missionPlan?.revisionProposalDurabilityHold?.outcome,
            .invalidatedContractChanged
        )
        contractHarness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in true }
        let contractRetry = await contractHarness.coordinatorModeViewModel.setCoordinatorMissionPace(
            coordinatorSessionID: contractHarness.coordinatorID,
            pace: .auto
        )
        XCTAssertEqual(contractRetry, .accepted)
        XCTAssertNil(
            contractHarness.session.coordinatorFollowThroughState?.missionPlan?.revisionProposalDurabilityHold
        )
    }

    func testRevisionProposalProductionPersistenceBarrierRejectsReentrantStateCorruption() async throws {
        let unapprovedHarness = await makeRevisionProposalPersistenceHarness()
        var unapprovedPlan = unapprovedHarness.plan
        unapprovedPlan.approvalState = .revisionRequested
        unapprovedHarness.session.coordinatorFollowThroughState = CoordinatorFollowThroughState(
            missionPlan: unapprovedPlan
        )
        unapprovedHarness.coordinatorModeViewModel.refresh()
        var unapprovedBarrierCalls = 0
        unapprovedHarness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in
            unapprovedBarrierCalls += 1
            return true
        }
        do {
            _ = try await unapprovedHarness.coordinatorModeViewModel.appendRevisionProposal(
                coordinatorSessionID: unapprovedHarness.coordinatorID,
                request: revisionProposalRequest(
                    coordinatorID: unapprovedHarness.coordinatorID,
                    plan: unapprovedPlan
                )
            )
            XCTFail("Expected authoritative callback approval validation to reject.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("approved Mission Plan"))
        }
        XCTAssertEqual(unapprovedBarrierCalls, 0)
        XCTAssertEqual(unapprovedHarness.session.coordinatorFollowThroughState?.missionPlan?.revisionProposals, [])

        for mutation in RevisionProposalBarrierMutation.allCases {
            let harness = await makeRevisionProposalPersistenceHarness()
            harness.agentModeViewModel.test_setRevisionProposalPersistenceBarrier { _, _ in
                switch mutation {
                case .sessionReplacement:
                    harness.agentModeViewModel.test_replaceSessionForRevisionProposal(tabID: harness.tabID)

                case .planReplacement:
                    harness.session.coordinatorFollowThroughState = CoordinatorFollowThroughState(
                        missionPlan: CoordinatorMissionPlan(
                            objective: "Replacement Mission",
                            status: .running,
                            approvalState: .approved
                        )
                    )

                case .proposalReplacement:
                    var state = try! XCTUnwrap(harness.session.coordinatorFollowThroughState)
                    var plan = try! XCTUnwrap(state.missionPlan)
                    let proposal = try! XCTUnwrap(plan.pendingRevisionProposal)
                    plan.revisionProposals = [
                        CoordinatorMissionRevisionProposal(
                            id: proposal.id,
                            canonicalRequestIdentity: proposal.canonicalRequestIdentity,
                            canonicalRequestIdentityVersion: proposal.canonicalRequestIdentityVersion,
                            basePlanID: proposal.basePlanID,
                            baseContractSnapshot: proposal.baseContractSnapshot,
                            baseContractFingerprint: proposal.baseContractFingerprint,
                            representation: proposal.representation,
                            summary: "Corrupted persisted summary",
                            rationale: proposal.rationale,
                            affectedFields: proposal.affectedFields,
                            remedy: proposal.remedy,
                            supportingEvidenceIDs: proposal.supportingEvidenceIDs,
                            requestedChange: proposal.requestedChange,
                            actor: proposal.actor,
                            filedAt: proposal.filedAt
                        )
                    ]
                    state.missionPlan = plan
                    harness.session.coordinatorFollowThroughState = state

                case .actorCorruption:
                    var state = try! XCTUnwrap(harness.session.coordinatorFollowThroughState)
                    var plan = try! XCTUnwrap(state.missionPlan)
                    let proposal = try! XCTUnwrap(plan.pendingRevisionProposal)
                    plan.revisionProposals = [
                        CoordinatorMissionRevisionProposal(
                            id: proposal.id,
                            canonicalRequestIdentity: proposal.canonicalRequestIdentity,
                            canonicalRequestIdentityVersion: proposal.canonicalRequestIdentityVersion,
                            basePlanID: proposal.basePlanID,
                            baseContractSnapshot: proposal.baseContractSnapshot,
                            baseContractFingerprint: proposal.baseContractFingerprint,
                            representation: proposal.representation,
                            summary: proposal.summary,
                            rationale: proposal.rationale,
                            affectedFields: proposal.affectedFields,
                            remedy: proposal.remedy,
                            supportingEvidenceIDs: proposal.supportingEvidenceIDs,
                            requestedChange: proposal.requestedChange,
                            actor: CoordinatorMissionRevisionProposalActor(
                                coordinatorSessionID: harness.coordinatorID,
                                runtimeSessionID: harness.coordinatorID,
                                modelID: "replacement-model",
                                role: "director"
                            ),
                            filedAt: proposal.filedAt
                        )
                    ]
                    state.missionPlan = plan
                    harness.session.coordinatorFollowThroughState = state

                case .proposalResolution:
                    var state = try! XCTUnwrap(harness.session.coordinatorFollowThroughState)
                    let proposal = try! XCTUnwrap(state.missionPlan?.pendingRevisionProposal)
                    _ = try! state.resolveRevisionProposal(
                        CoordinatorMissionRevisionProposalResolutionRequest(
                            proposalID: proposal.id,
                            outcome: .rejected
                        )
                    )
                    harness.session.coordinatorFollowThroughState = state

                case .materialContractMutation:
                    var state = try! XCTUnwrap(harness.session.coordinatorFollowThroughState)
                    var plan = try! XCTUnwrap(state.missionPlan)
                    plan.objective = "Mutated contract"
                    state.missionPlan = plan
                    harness.session.coordinatorFollowThroughState = state

                case .eventCorruption:
                    var state = try! XCTUnwrap(harness.session.coordinatorFollowThroughState)
                    var plan = try! XCTUnwrap(state.missionPlan)
                    plan.events.removeAll { $0.kind == .revisionProposalFiled }
                    state.missionPlan = plan
                    harness.session.coordinatorFollowThroughState = state

                case .decisionCorruption:
                    var state = try! XCTUnwrap(harness.session.coordinatorFollowThroughState)
                    var plan = try! XCTUnwrap(state.missionPlan)
                    plan.decisions.append(CoordinatorMissionDecisionRecord(
                        decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                        actor: .director,
                        label: "unauthorized during proposal persistence"
                    ))
                    state.missionPlan = plan
                    harness.session.coordinatorFollowThroughState = state

                case .resolutionCorruption:
                    var state = try! XCTUnwrap(harness.session.coordinatorFollowThroughState)
                    var plan = try! XCTUnwrap(state.missionPlan)
                    let proposal = try! XCTUnwrap(plan.pendingRevisionProposal)
                    plan.revisionProposalResolutions.append(
                        CoordinatorMissionRevisionProposalResolution(
                            id: UUID(),
                            proposalID: proposal.id,
                            outcome: .rejected,
                            userDecisionID: nil,
                            checkpointID: nil,
                            checkpointInstanceID: nil,
                            resultingPlanID: plan.id,
                            resultingContractFingerprint: proposal.baseContractFingerprint,
                            resolvedAt: Date()
                        )
                    )
                    state.missionPlan = plan
                    harness.session.coordinatorFollowThroughState = state
                }
                return true
            }

            do {
                _ = try await harness.coordinatorModeViewModel.appendRevisionProposal(
                    coordinatorSessionID: harness.coordinatorID,
                    request: harness.request
                )
                XCTFail("Expected \(mutation.rawValue) to fail closed.")
            } catch {
                XCTAssertFalse(String(describing: error).isEmpty)
            }
        }
    }

    func testPostApprovalContinuationProductionFlushWaitsForGenerationAndRejectsPersistenceRaces() async throws {
        let success = await makePostApprovalContinuationHarness()
        var observedGeneration: UInt64?
        success.agentModeViewModel.test_setPostApprovalContinuationPersistenceBarrier { tabID, minimumGeneration in
            XCTAssertEqual(tabID, success.tabID)
            observedGeneration = minimumGeneration
            return true
        }

        try await success.agentModeViewModel.test_flushCoordinatorPostApprovalContinuationPersistence(success.token)

        XCTAssertEqual(observedGeneration, success.session.saveRequestGeneration)
        XCTAssertGreaterThan(observedGeneration ?? 0, 0)

        let failure = await makePostApprovalContinuationHarness()
        failure.agentModeViewModel.test_setPostApprovalContinuationPersistenceBarrier { _, _ in false }
        do {
            try await failure.agentModeViewModel.test_flushCoordinatorPostApprovalContinuationPersistence(failure.token)
            XCTFail("Expected the failed persistence barrier to reject.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not durably save"))
        }

        for mutation in PostApprovalFlushMutation.allCases {
            let harness = await makePostApprovalContinuationHarness()
            harness.agentModeViewModel.test_setPostApprovalContinuationPersistenceBarrier { _, _ in
                switch mutation {
                case .sessionReplacement:
                    harness.agentModeViewModel.test_replaceSessionForRevisionProposal(tabID: harness.tabID)
                case .continuationIdentity:
                    var state = harness.session.coordinatorFollowThroughState!
                    var plan = state.missionPlan!
                    let replacement = self.makePostApprovalContinuation(
                        coordinatorID: harness.coordinatorID,
                        plan: plan,
                        id: UUID()
                    )
                    state.recordPostApprovalContinuation(replacement)
                    plan.postApprovalContinuation = replacement
                    state.missionPlan = plan
                    harness.session.coordinatorFollowThroughState = state
                case .planIdentity:
                    var state = harness.session.coordinatorFollowThroughState!
                    let current = state.missionPlan!
                    state.missionPlan = CoordinatorMissionPlan(
                        id: UUID(),
                        revision: current.revision,
                        objective: current.objective,
                        status: current.status,
                        approvalState: current.approvalState,
                        postApprovalContinuation: current.postApprovalContinuation
                    )
                    harness.session.coordinatorFollowThroughState = state
                case .continuationRevision:
                    var state = harness.session.coordinatorFollowThroughState!
                    let plan = state.missionPlan!
                    let current = plan.postApprovalContinuation!
                    let replacement = CoordinatorPostApprovalContinuationRecord(
                        id: current.id,
                        coordinatorSessionID: current.coordinatorSessionID,
                        checkpointInstanceID: current.checkpointInstanceID,
                        planID: current.planID,
                        planRevision: current.planRevision + 1,
                        directiveText: current.directiveText,
                        durableApprovalAuthorityToken: current.durableApprovalAuthorityToken
                    )
                    state.recordPostApprovalContinuation(replacement)
                    harness.session.coordinatorFollowThroughState = state
                case .postFlushStatus:
                    var state = harness.session.coordinatorFollowThroughState!
                    _ = state.markPostApprovalContinuationDispatching()
                    harness.session.coordinatorFollowThroughState = state
                }
                return true
            }

            do {
                try await harness.agentModeViewModel.test_flushCoordinatorPostApprovalContinuationPersistence(harness.token)
                XCTFail("Expected \(mutation.rawValue) to fail closed.")
            } catch {
                XCTAssertFalse(String(describing: error).isEmpty, mutation.rawValue)
            }
        }
    }

    func testPostApprovalContinuationProductionEnqueueAuthorityRejectsStaleMissionContracts() async throws {
        for mutation in PostApprovalEnqueueMutation.allCases {
            let harness = await makePostApprovalContinuationHarness(status: .dispatching)
            let expected = harness.continuation
            var state = try XCTUnwrap(harness.session.coordinatorFollowThroughState)
            var plan = try XCTUnwrap(state.missionPlan)
            switch mutation {
            case .missingAuthority:
                let current = try XCTUnwrap(plan.postApprovalContinuation)
                let replacement = CoordinatorPostApprovalContinuationRecord(
                    id: current.id,
                    coordinatorSessionID: current.coordinatorSessionID,
                    checkpointInstanceID: current.checkpointInstanceID,
                    planID: current.planID,
                    planRevision: current.planRevision,
                    directiveText: current.directiveText,
                    status: .dispatching
                )
                state.recordPostApprovalContinuation(replacement)
            case .revokedAuthority:
                plan.approvalState = .revisionRequested
                state.missionPlan = plan
            case .continuationIdentity:
                let replacement = makePostApprovalContinuation(
                    coordinatorID: harness.coordinatorID,
                    plan: plan,
                    id: UUID(),
                    status: .dispatching
                )
                state.recordPostApprovalContinuation(replacement)
            case .planIdentity:
                state.missionPlan = CoordinatorMissionPlan(
                    id: UUID(),
                    revision: plan.revision,
                    objective: plan.objective,
                    status: plan.status,
                    approvalState: plan.approvalState,
                    postApprovalContinuation: plan.postApprovalContinuation
                )
            case .continuationRevision:
                let current = try XCTUnwrap(plan.postApprovalContinuation)
                let replacement = CoordinatorPostApprovalContinuationRecord(
                    id: current.id,
                    coordinatorSessionID: current.coordinatorSessionID,
                    checkpointInstanceID: current.checkpointInstanceID,
                    planID: current.planID,
                    planRevision: current.planRevision + 1,
                    directiveText: current.directiveText,
                    status: .dispatching,
                    durableApprovalAuthorityToken: current.durableApprovalAuthorityToken
                )
                state.recordPostApprovalContinuation(replacement)
            case .terminalMission:
                plan.status = .stopped
                state.missionPlan = plan
            }
            harness.session.coordinatorFollowThroughState = state
            harness.coordinatorModeViewModel.refresh()

            XCTAssertThrowsError(
                try harness.agentModeViewModel.test_validatePostApprovalContinuationEnqueueAuthority(expected),
                mutation.rawValue
            )
        }
    }

    func testPendingRevisionProposalDefersContinuationAndFailsFinalEnqueueClosed() async throws {
        let harness = await makePostApprovalContinuationHarness(status: .pending)
        var state = try XCTUnwrap(harness.session.coordinatorFollowThroughState)
        let plan = try XCTUnwrap(state.missionPlan)
        _ = try state.appendRevisionProposal(CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: plan.id,
            expectedBaseContractFingerprint: plan.materialContractFingerprint(),
            summary: "Revise before continuation",
            affectedFields: ["objective"],
            remedy: "revise_scope",
            supportingEvidenceIDs: [],
            requestedChange: "Revise before continuation.",
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: harness.coordinatorID,
                runtimeSessionID: harness.coordinatorID
            )
        ))
        harness.session.coordinatorFollowThroughState = state
        var submissions = 0
        harness.agentModeViewModel.test_setCoordinatorContinuationSubmitter { _ in
            submissions += 1
            return .submitted
        }

        await harness.agentModeViewModel.test_evaluateCoordinatorPostApprovalContinuation(
            coordinatorSessionID: harness.coordinatorID
        )

        let deferred = try XCTUnwrap(harness.session.coordinatorFollowThroughState?.postApprovalContinuation)
        XCTAssertEqual(deferred.status, .deferred)
        XCTAssertEqual(deferred.lastError, CoordinatorMissionRevisionProposalPause.heldReason)
        XCTAssertEqual(deferred.attempts, 0)
        XCTAssertEqual(submissions, 0)
        XCTAssertThrowsError(
            try harness.agentModeViewModel.test_validatePostApprovalContinuationEnqueueAuthority(deferred)
        ) { error in
            XCTAssertTrue(
                ((error as? LocalizedError)?.errorDescription ?? "")
                    .contains(CoordinatorMissionRevisionProposalPause.heldReason)
            )
        }
    }

    func testPostApprovalContinuationHiddenLifecycleDefersWithoutChurnThenDeliversExactlyOnce() async throws {
        let harness = await makePostApprovalContinuationHarness(status: .pending, runState: .running)
        await harness.agentModeViewModel.test_evaluateCoordinatorPostApprovalContinuation(
            coordinatorSessionID: harness.coordinatorID
        )
        let firstDeferred = try XCTUnwrap(harness.session.coordinatorFollowThroughState?.postApprovalContinuation)
        XCTAssertEqual(firstDeferred.status, .deferred)
        XCTAssertEqual(firstDeferred.attempts, 0)

        await harness.agentModeViewModel.test_evaluateCoordinatorPostApprovalContinuation(
            coordinatorSessionID: harness.coordinatorID
        )
        XCTAssertEqual(harness.session.coordinatorFollowThroughState?.postApprovalContinuation, firstDeferred)

        var acceptedSubmits = 0
        harness.session.runState = .idle
        harness.agentModeViewModel.test_setCoordinatorContinuationSubmitter { continuation in
            acceptedSubmits += 1
            XCTAssertEqual(
                harness.session.coordinatorFollowThroughState?.postApprovalContinuation?.status,
                .dispatching
            )
            do {
                try harness.agentModeViewModel.test_validatePostApprovalContinuationEnqueueAuthority(continuation)
            } catch {
                XCTFail("Expected dispatching continuation authority to remain valid: \(error)")
            }
            return .submitted
        }

        await harness.agentModeViewModel.test_evaluateCoordinatorPostApprovalContinuation(
            coordinatorSessionID: harness.coordinatorID
        )
        XCTAssertEqual(acceptedSubmits, 1)
        XCTAssertEqual(harness.session.coordinatorFollowThroughState?.postApprovalContinuation?.status, .delivered)
        XCTAssertEqual(harness.session.coordinatorFollowThroughState?.postApprovalContinuation?.attempts, 1)

        await harness.agentModeViewModel.test_evaluateCoordinatorPostApprovalContinuation(
            coordinatorSessionID: harness.coordinatorID
        )
        XCTAssertEqual(acceptedSubmits, 1)
        XCTAssertEqual(harness.session.coordinatorFollowThroughState?.postApprovalContinuation?.status, .delivered)
    }

    func testAcceptedPostApprovalContinuationSessionReplacementSuppressesOrphanRedelivery() async throws {
        let harness = await makePostApprovalContinuationHarness(status: .pending)
        let durablePreDispatchState = try XCTUnwrap(harness.session.coordinatorFollowThroughState)
        let recorder = CoordinatorContinuationRaceRecorder()
        harness.agentModeViewModel.test_setCoordinatorContinuationSubmitter { _ in
            recorder.providerSubmissions += 1
            XCTAssertEqual(
                harness.session.coordinatorFollowThroughState?.postApprovalContinuation?.status,
                .dispatching
            )
            await Task.yield()
            return .submitted
        }
        harness.agentModeViewModel.test_setAfterCoordinatorContinuationSubmitResult { _, result in
            XCTAssertEqual(result, .submitted)
            harness.agentModeViewModel.test_replaceSessionForRevisionProposal(tabID: harness.tabID)
            let replacement = harness.agentModeViewModel.sessions[harness.tabID]!
            replacement.testInstallPersistentSessionBinding(sessionID: UUID())
            replacement.isCoordinatorRuntime = false
            replacement.coordinatorFollowThroughState = nil
            recorder.replacementSession = replacement
            recorder.afterSubmitHookCalls += 1
        }

        await harness.agentModeViewModel.test_evaluateCoordinatorPostApprovalContinuation(
            coordinatorSessionID: harness.coordinatorID
        )

        XCTAssertEqual(recorder.providerSubmissions, 1)
        XCTAssertEqual(recorder.afterSubmitHookCalls, 1)
        XCTAssertTrue(
            harness.agentModeViewModel.test_hasAcceptedCoordinatorContinuationReceipt(harness.continuation)
        )

        let replacement = try XCTUnwrap(recorder.replacementSession)
        replacement.testInstallPersistentSessionBinding(sessionID: harness.coordinatorID)
        replacement.isCoordinatorRuntime = true
        replacement.hasLoadedPersistedState = true
        replacement.runState = .idle
        replacement.coordinatorFollowThroughState = durablePreDispatchState

        await harness.agentModeViewModel.test_evaluateCoordinatorPostApprovalContinuation(
            coordinatorSessionID: harness.coordinatorID
        )

        XCTAssertEqual(recorder.providerSubmissions, 1)
        XCTAssertEqual(recorder.afterSubmitHookCalls, 1)
        XCTAssertEqual(
            replacement.coordinatorFollowThroughState?.postApprovalContinuation?.status,
            .delivered
        )
        XCTAssertEqual(replacement.coordinatorFollowThroughState?.postApprovalContinuation?.attempts, 1)
    }

    func testPostApprovalContinuationRealFinalEnqueueRejectsAuthorityRevokedBeforeSubmit() async {
        for replaceTargetSession in [false, true] {
            let harness = await makePostApprovalContinuationHarness(status: .dispatching)
            var validationHookCalls = 0
            let initialUserTurnCount = harness.session.items.count { $0.kind == .user }
            harness.agentModeViewModel.test_setBeforeCoordinatorContinuationEnqueueAuthorityValidation { _ in
                validationHookCalls += 1
                if replaceTargetSession {
                    harness.agentModeViewModel.test_replaceSessionForRevisionProposal(tabID: harness.tabID)
                } else {
                    var state = harness.session.coordinatorFollowThroughState!
                    var plan = state.missionPlan!
                    plan.approvalState = .revisionRequested
                    state.missionPlan = plan
                    harness.session.coordinatorFollowThroughState = state
                    harness.coordinatorModeViewModel.refresh()
                }
            }

            let result = await harness.agentModeViewModel
                .test_submitCoordinatorPostApprovalContinuationAtFinalEnqueue(harness.continuation)

            guard case let .blocked(message) = result else {
                XCTFail("Expected final enqueue authority validation to block the user turn.")
                continue
            }
            if replaceTargetSession {
                XCTAssertTrue(message.contains("target Coordinator session changed"), message)
            } else {
                XCTAssertTrue(message.contains("authority changed before dispatch"), message)
            }
            XCTAssertEqual(validationHookCalls, 1)
            XCTAssertEqual(harness.session.items.count { $0.kind == .user }, initialUserTurnCount)
            XCTAssertEqual(harness.codexController.startUserTurnCount, 0)
        }
    }

    func testPostApprovalContinuationSameProcessDecodedDeliverableStatesRecoverWithoutRestartPromise() async throws {
        for status in [
            CoordinatorPostApprovalContinuationRecord.Status.pending,
            .deferred,
            .dispatching
        ] {
            let harness = await makePostApprovalContinuationHarness(status: status)
            let encoded = try JSONEncoder().encode(harness.session.coordinatorFollowThroughState)
            harness.session.coordinatorFollowThroughState = try JSONDecoder().decode(
                CoordinatorFollowThroughState.self,
                from: encoded
            )
            var submits = 0
            harness.agentModeViewModel.test_setCoordinatorContinuationSubmitter { _ in
                submits += 1
                return .submitted
            }

            await harness.agentModeViewModel.test_evaluateCoordinatorPostApprovalContinuation(
                coordinatorSessionID: harness.coordinatorID
            )
            XCTAssertEqual(submits, 1, status.rawValue)
            XCTAssertEqual(
                harness.session.coordinatorFollowThroughState?.postApprovalContinuation?.status,
                .delivered,
                status.rawValue
            )
            await harness.agentModeViewModel.test_evaluateCoordinatorPostApprovalContinuation(
                coordinatorSessionID: harness.coordinatorID
            )
            XCTAssertEqual(submits, 1, status.rawValue)
        }
    }

    private enum PostApprovalFlushMutation: String, CaseIterable {
        case sessionReplacement
        case continuationIdentity
        case planIdentity
        case continuationRevision
        case postFlushStatus
    }

    private enum PostApprovalEnqueueMutation: String, CaseIterable {
        case missingAuthority
        case revokedAuthority
        case continuationIdentity
        case planIdentity
        case continuationRevision
        case terminalMission
    }

    private struct PostApprovalContinuationHarness {
        let agentModeViewModel: AgentModeViewModel
        let coordinatorModeViewModel: CoordinatorModeViewModel
        let session: AgentModeViewModel.TabSession
        let tabID: UUID
        let coordinatorID: UUID
        let continuation: CoordinatorPostApprovalContinuationRecord
        let token: CoordinatorModeViewModel.PostApprovalContinuationPersistenceToken
        let codexController: CoordinatorResetFakeCodexController
        let workspaceManager: WorkspaceManagerViewModel
        let promptViewModel: PromptViewModel
    }

    private func makePostApprovalContinuationHarness(
        status: CoordinatorPostApprovalContinuationRecord.Status = .pending,
        runState: AgentSessionRunState = .idle
    ) async -> PostApprovalContinuationHarness {
        let tabID = UUID()
        let coordinatorID = UUID()
        var plan = CoordinatorMissionPlan(
            revision: 7,
            objective: "Approved continuation Mission",
            status: .running,
            approvalState: .approved
        )
        let continuation = makePostApprovalContinuation(
            coordinatorID: coordinatorID,
            plan: plan,
            status: status
        )
        plan.postApprovalContinuation = continuation
        let tab = ComposeTabState(
            id: tabID,
            name: "Coordinator Runtime",
            activeAgentSessionID: coordinatorID
        )
        let codexController = CoordinatorResetFakeCodexController()
        let fixture = makeAgentModeFixture(
            tabs: [tab],
            activeTabID: tabID,
            codexController: codexController
        )
        let agentModeViewModel = fixture.viewModel
        let session = await agentModeViewModel.ensureSessionReady(tabID: tabID)
        _ = agentModeViewModel.test_installPersistentSessionBinding(sessionID: coordinatorID, on: session)
        session.isCoordinatorRuntime = true
        session.hasLoadedPersistedState = true
        session.runState = runState
        session.coordinatorFollowThroughState = CoordinatorFollowThroughState(
            originalObjectiveSummary: "Approved continuation Mission",
            missionPlan: plan,
            postApprovalContinuation: continuation
        )
        session.isDirty = true
        agentModeViewModel.scheduleSave(for: tabID)
        let coordinatorModeViewModel = agentModeViewModel.coordinatorModeViewModel
        coordinatorModeViewModel.refresh()
        coordinatorModeViewModel.test_setPostApprovalContinuationDurableAuthority(continuation)
        return PostApprovalContinuationHarness(
            agentModeViewModel: agentModeViewModel,
            coordinatorModeViewModel: coordinatorModeViewModel,
            session: session,
            tabID: tabID,
            coordinatorID: coordinatorID,
            continuation: continuation,
            token: CoordinatorModeViewModel.PostApprovalContinuationPersistenceToken(
                coordinatorSessionID: coordinatorID,
                continuationID: continuation.id,
                checkpointInstanceID: continuation.checkpointInstanceID,
                planID: continuation.planID,
                planRevision: continuation.planRevision
            ),
            codexController: codexController,
            workspaceManager: fixture.manager,
            promptViewModel: fixture.prompt
        )
    }

    private func makePostApprovalContinuation(
        coordinatorID: UUID,
        plan: CoordinatorMissionPlan,
        id: UUID = UUID(),
        status: CoordinatorPostApprovalContinuationRecord.Status = .pending
    ) -> CoordinatorPostApprovalContinuationRecord {
        CoordinatorPostApprovalContinuationRecord(
            id: id,
            coordinatorSessionID: coordinatorID,
            checkpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r\(plan.revision)",
            planID: plan.id,
            planRevision: plan.revision,
            directiveText: "<coordinator_post_approval_continuation />",
            status: status
        ).confirmingDurableApprovalAuthority()
    }

    private enum RevisionProposalBarrierMutation: String, CaseIterable {
        case sessionReplacement
        case planReplacement
        case proposalReplacement
        case actorCorruption
        case proposalResolution
        case materialContractMutation
        case eventCorruption
        case decisionCorruption
        case resolutionCorruption
    }

    private struct RevisionProposalPersistenceHarness {
        let agentModeViewModel: AgentModeViewModel
        let coordinatorModeViewModel: CoordinatorModeViewModel
        let session: AgentModeViewModel.TabSession
        let tabID: UUID
        let coordinatorID: UUID
        let plan: CoordinatorMissionPlan
        let request: CoordinatorMissionRevisionProposalRequest
        let workspaceManager: WorkspaceManagerViewModel
        let promptViewModel: PromptViewModel
    }

    private func makeRevisionProposalPersistenceHarness() async -> RevisionProposalPersistenceHarness {
        let tabID = UUID()
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Approved Mission",
            status: .running,
            approvalState: .approved
        )
        let tab = ComposeTabState(
            id: tabID,
            name: "Coordinator Runtime",
            activeAgentSessionID: coordinatorID
        )
        let fixture = makeAgentModeFixture(tabs: [tab], activeTabID: tabID)
        let agentModeViewModel = fixture.viewModel
        let session = await agentModeViewModel.ensureSessionReady(tabID: tabID)
        _ = agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: coordinatorID,
            on: session
        )
        session.isCoordinatorRuntime = true
        session.hasLoadedPersistedState = true
        session.coordinatorFollowThroughState = CoordinatorFollowThroughState(missionPlan: plan)
        let coordinatorModeViewModel = agentModeViewModel.coordinatorModeViewModel
        coordinatorModeViewModel.refresh()
        XCTAssertTrue(
            coordinatorModeViewModel.snapshot.coordinatorRail.availableCoordinators
                .contains { $0.sessionID == coordinatorID }
        )
        return RevisionProposalPersistenceHarness(
            agentModeViewModel: agentModeViewModel,
            coordinatorModeViewModel: coordinatorModeViewModel,
            session: session,
            tabID: tabID,
            coordinatorID: coordinatorID,
            plan: plan,
            request: revisionProposalRequest(
                coordinatorID: coordinatorID,
                plan: plan
            ),
            workspaceManager: fixture.manager,
            promptViewModel: fixture.prompt
        )
    }

    private func revisionProposalRequest(
        coordinatorID: UUID,
        plan: CoordinatorMissionPlan,
        summary: String = "Request a material revision.",
        rationale: String? = "New evidence requires contract changes."
    ) -> CoordinatorMissionRevisionProposalRequest {
        CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: plan.id,
            expectedBaseContractFingerprint: try! plan.materialContractFingerprint(),
            summary: summary,
            rationale: rationale,
            affectedFields: ["objective", "workstreams"],
            remedy: "revise_plan",
            supportingEvidenceIDs: [uuid(9901)],
            requestedChange: "Expand the approved scope.",
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: coordinatorID,
                runtimeSessionID: coordinatorID,
                modelID: "coordinator-model",
                role: "director"
            )
        )
    }

    private func input(
        workspaceID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000090"),
        persisted: [CoordinatorModeSnapshotProjector.PersistedSession] = [],
        live: [CoordinatorModeSnapshotProjector.LiveSession] = [],
        mcpSnapshots: [UUID: AgentRunMCPSnapshot] = [:],
        selectedCoordinatorID: UUID? = nil,
        autoSelectDemoCoordinator: Bool = true,
        sort: CoordinatorModeSortMode = .lastUpdated,
        demoCoordinatorIDs: Set<UUID> = []
    ) -> CoordinatorModeSnapshotProjector.Input {
        let resolvedSelectedCoordinatorID = selectedCoordinatorID ?? (autoSelectDemoCoordinator ? newestDemoCoordinatorID(
            demoCoordinatorIDs,
            persisted: persisted,
            live: live,
            mcpSnapshots: mcpSnapshots
        ) : nil)
        return CoordinatorModeSnapshotProjector.Input(
            workspaceID: workspaceID,
            windowID: 7,
            persistedSessions: persisted,
            liveSessions: live,
            mcpSnapshotsBySessionID: mcpSnapshots,
            selectedCoordinatorID: resolvedSelectedCoordinatorID,
            sortMode: sort,
            resolvableTabIDs: Set(persisted.map(\.tabID) + live.map(\.tabID) + mcpSnapshots.values.compactMap(\.tabID)),
            demoCoordinatorSessionIDs: demoCoordinatorIDs
        )
    }

    private func newestDemoCoordinatorID(
        _ ids: Set<UUID>,
        persisted: [CoordinatorModeSnapshotProjector.PersistedSession],
        live: [CoordinatorModeSnapshotProjector.LiveSession],
        mcpSnapshots: [UUID: AgentRunMCPSnapshot]
    ) -> UUID? {
        ids.max { lhs, rhs in
            let lhsDate = coordinatorDate(lhs, persisted: persisted, live: live, mcpSnapshots: mcpSnapshots)
            let rhsDate = coordinatorDate(rhs, persisted: persisted, live: live, mcpSnapshots: mcpSnapshots)
            if lhsDate == rhsDate { return lhs.uuidString < rhs.uuidString }
            return lhsDate < rhsDate
        }
    }

    private func coordinatorDate(
        _ id: UUID,
        persisted: [CoordinatorModeSnapshotProjector.PersistedSession],
        live: [CoordinatorModeSnapshotProjector.LiveSession],
        mcpSnapshots: [UUID: AgentRunMCPSnapshot]
    ) -> Date {
        [
            live.first { $0.sessionID == id }?.updatedAt,
            persisted.first { $0.id == id }?.updatedAt,
            mcpSnapshots[id]?.updatedAt
        ]
        .compactMap(\.self)
        .max() ?? .distantPast
    }

    private func persisted(
        id: UUID,
        tab: UUID,
        title: String,
        startedAt: Date? = nil,
        updatedAt: Date,
        state: AgentSessionRunState? = .idle,
        parent: UUID? = nil,
        isMCP: Bool = false,
        workflow: CoordinatorModeWorkflowDisplaySummary? = nil,
        bindings: [AgentSessionWorktreeBindingSummary] = []
    ) -> CoordinatorModeSnapshotProjector.PersistedSession {
        CoordinatorModeSnapshotProjector.PersistedSession(
            id: id,
            tabID: tab,
            title: title,
            startedAt: startedAt,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP,
            worktreeBindingSummaries: bindings,
            workflow: workflow
        )
    }

    private func live(
        id: UUID,
        tab: UUID,
        title: String,
        startedAt: Date? = nil,
        updatedAt: Date,
        state: AgentSessionRunState,
        parent: UUID? = nil,
        isMCP: Bool = false,
        workflow: CoordinatorModeWorkflowDisplaySummary? = nil,
        coordinatorRuntime: Bool = false,
        bindings: [AgentSessionWorktreeBindingSummary] = [],
        missionPlan: CoordinatorMissionPlan? = nil
    ) -> CoordinatorModeSnapshotProjector.LiveSession {
        CoordinatorModeSnapshotProjector.LiveSession(
            sessionID: id,
            tabID: tab,
            title: title,
            startedAt: startedAt,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP,
            worktreeBindingSummaries: bindings,
            workflow: workflow,
            isCoordinatorRuntime: coordinatorRuntime,
            coordinatorMissionPlan: missionPlan
        )
    }

    private func binding(label: String, color: String) -> AgentSessionWorktreeBindingSummary {
        AgentSessionWorktreeBindingSummary(
            id: "binding-\(label)",
            repositoryID: "repo",
            repoKey: "repo",
            logicalRootPath: "/repo",
            worktreeID: label,
            worktreeRootPath: "/worktrees/\(label)",
            branch: label,
            visualLabel: label,
            visualColorHex: color,
            boundAt: date(5)
        )
    }

    private func mcpSnapshot(
        sessionID: UUID,
        tabID: UUID,
        sessionName: String,
        status: AgentRunMCPSnapshot.Status,
        statusText: String?,
        assistantPreview: String?,
        parent: UUID?,
        interaction: AgentRunMCPSnapshot.Interaction? = nil,
        failureReason: AgentRunMCPSnapshot.FailureReason? = nil
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
            transcriptItemCount: 1,
            updatedAt: date(30),
            parentSessionID: parent,
            failureReason: failureReason,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }

    private func pendingQuestionInteraction(
        id: UUID,
        title: String,
        prompt: String
    ) -> AgentRunMCPSnapshot.Interaction {
        AgentRunMCPSnapshot.Interaction(
            id: id,
            kind: .question,
            responseType: .structured,
            title: title,
            prompt: prompt,
            context: "This decides where the child pauses for input.",
            allowsMultiple: nil,
            options: [],
            fields: [
                AgentRunMCPSnapshot.Interaction.Field(
                    id: "involvement",
                    header: "Plan involvement",
                    prompt: prompt,
                    context: nil,
                    isSecret: false,
                    allowsOther: true,
                    allowsMultiple: false,
                    allowsCustom: true,
                    options: [
                        AgentRunMCPSnapshot.Interaction.Option(label: "Mid-flow", description: "Check in before review."),
                        AgentRunMCPSnapshot.Interaction.Option(label: "Hands-off", description: "Surface the plan when ready.")
                    ]
                )
            ],
            details: [
                AgentRunMCPSnapshot.Interaction.Detail(label: "Workflow", value: "Deep Plan", isCode: false)
            ]
        )
    }

    func testRenderedPlanAndStepStopActionsRetainMissionAcrossSelectionChangeAndRemainIdempotent() async throws {
        let missionA = uuid(1)
        let missionB = uuid(2)
        let childA = uuid(3)
        let renderedStepEvent = CoordinatorFollowThroughEvent(
            id: "rendered-step-a",
            kind: .gateCleared,
            coordinatorSessionID: missionA,
            childSessionID: childA,
            childTitle: "Active A work",
            gate: nil,
            phase: nil,
            detail: "Mission A reached a rendered step boundary."
        )
        var pendingEvent: CoordinatorFollowThroughEvent? = renderedStepEvent
        var resolvedEvents: [CoordinatorFollowThroughEvent] = []
        var states: [UUID: CoordinatorFollowThroughState] = [
            missionA: CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
                revision: 2,
                objective: "Mission A",
                status: .running,
                approvalState: .approved,
                nodes: [
                    CoordinatorMissionPlanNode(
                        title: "Active A work",
                        workstreamID: uuid(30),
                        executionPolicy: .freshReadOnlyChild,
                        status: .running,
                        boundSessionID: childA
                    )
                ]
            )),
            missionB: CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
                revision: 3,
                objective: "Mission B",
                status: .running,
                approvalState: .approved,
                nodes: [
                    CoordinatorMissionPlanNode(
                        title: "Active B work",
                        workstreamID: uuid(40),
                        executionPolicy: .coordinatorOnly,
                        status: .running
                    )
                ]
            ))
        ]
        var stopRequests: [CoordinatorMissionStopRequest] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [missionA, missionB].map { missionID in
                        self.live(
                            id: missionID,
                            tab: missionID == missionA ? self.uuid(101) : self.uuid(102),
                            title: missionID == missionA ? "Mission A" : "Mission B",
                            updatedAt: self.date(20),
                            state: .running,
                            coordinatorRuntime: true,
                            missionPlan: states[missionID]?.missionPlan
                        )
                    },
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [missionA, missionB]
                )
            },
            dashboardVisibilityHandler: { _ in },
            missionPlanUpdater: { missionID, update in
                var state = try XCTUnwrap(states[missionID])
                state.updateMissionPlan(update)
                states[missionID] = state
            },
            missionStopper: { request in
                stopRequests.append(request)
                return CoordinatorMissionStopResult(
                    requestedSessionIDs: request.sessionIDs,
                    cancelledSessionIDs: request.sessionIDs,
                    skippedSessionIDs: []
                )
            },
            pendingFollowThroughEventProvider: { coordinatorSessionID in
                coordinatorSessionID == missionA ? pendingEvent : nil
            },
            followThroughEventResolver: { event in
                resolvedEvents.append(event)
                if pendingEvent?.id == event.id {
                    pendingEvent = nil
                }
            }
        )
        viewModel.selectCoordinator(sessionID: missionA)
        XCTAssertEqual(viewModel.activePendingFollowThroughEvent(), renderedStepEvent)

        var renderedTargets: [UUID] = []
        let planApprovalStop = CoordinatorModeView.renderedPlanApprovalStopAction(coordinatorSessionID: missionA) {
            renderedTargets.append($0)
        }
        var stepStopResults: [CoordinatorModeViewModel.DirectiveSubmissionResult] = []
        let stepStopsFinished = expectation(description: "Rendered step Stop resolves and stops its bound Mission")
        stepStopsFinished.expectedFulfillmentCount = 2
        let stepBoundaryStop = CoordinatorModeView.renderedStepBoundaryStopAction(
            event: renderedStepEvent,
            resolve: { event, continuation in
                Task { @MainActor in
                    await viewModel.resolvePendingFollowThroughEvent(event)
                    continuation()
                }
            },
            stop: { targetMissionID in
                renderedTargets.append(targetMissionID)
                Task { @MainActor in
                    await stepStopResults.append(viewModel.stopCoordinatorMission(targetMissionID: targetMissionID))
                    stepStopsFinished.fulfill()
                }
            }
        )

        viewModel.selectCoordinator(sessionID: missionB)
        planApprovalStop()
        let planStopResult = try await viewModel.stopCoordinatorMission(targetMissionID: XCTUnwrap(renderedTargets.last))
        stepBoundaryStop()
        stepBoundaryStop()
        await fulfillment(of: [stepStopsFinished], timeout: 1)

        XCTAssertEqual(planStopResult, .accepted)
        XCTAssertEqual(stepStopResults, [.accepted, .accepted])

        XCTAssertEqual(renderedTargets, [missionA, missionA, missionA])
        XCTAssertEqual(resolvedEvents, [renderedStepEvent, renderedStepEvent])
        XCTAssertNil(pendingEvent)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, missionB)
        XCTAssertEqual(states[missionA]?.missionPlan?.status, .stopped)
        XCTAssertEqual(states[missionB]?.missionPlan?.status, .running)
        XCTAssertEqual(stopRequests.count, 1)
        XCTAssertEqual(stopRequests.first?.coordinatorSessionID, missionA)
        XCTAssertTrue(stopRequests.first?.sessionIDs.contains(childA) == true)
        XCTAssertEqual(states[missionA]?.missionPlan?.decisions.count(where: { $0.actor == .user }), 1)
        XCTAssertTrue(states[missionB]?.missionPlan?.decisions.isEmpty == true)
        viewModel.selectCoordinator(sessionID: missionA)
        XCTAssertNil(viewModel.activePendingFollowThroughEvent())
    }

    private func makeAgentModeFixture(
        tabs: [ComposeTabState],
        activeTabID: UUID?,
        codexController: CoordinatorResetFakeCodexController = CoordinatorResetFakeCodexController()
    ) -> (viewModel: AgentModeViewModel, manager: WorkspaceManagerViewModel, prompt: PromptViewModel) {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Coordinator reset",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: tabs,
            activeComposeTabID: activeTabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in codexController }
        )
        viewModel.test_setSidebarAutoArchiveDependencies(promptManager: prompt, workspaceManager: manager)
        return (viewModel, manager, prompt)
    }

    private func ledgerTestViewModel(
        coordinatorID: UUID,
        plan: @escaping () -> CoordinatorMissionPlan,
        transcript: @escaping () -> [CoordinatorModeRailTranscriptEntry] = { [] }
    ) -> CoordinatorModeViewModel {
        CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                self.input(
                    live: [
                        self.live(
                            id: coordinatorID,
                            tab: self.uuid(101),
                            title: "Coordinator",
                            updatedAt: self.date(20),
                            state: .idle,
                            isMCP: true,
                            coordinatorRuntime: true,
                            missionPlan: plan()
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            transcriptProvider: { _ in transcript() },
            dashboardVisibilityHandler: { _ in }
        )
    }

    private func decisionLedgerEntries(in viewModel: CoordinatorModeViewModel) -> [CoordinatorMissionDecisionRecord] {
        viewModel.railTranscriptEntries.compactMap { entry in
            if case let .decision(decision)? = entry.ledger {
                return decision
            }
            return nil
        }
    }

    private func evidenceLedgerEntries(in viewModel: CoordinatorModeViewModel) -> [CoordinatorMissionEvidenceRecord] {
        viewModel.railTranscriptEntries.compactMap { entry in
            if case let .evidence(evidence)? = entry.ledger {
                return evidence
            }
            return nil
        }
    }

    private func routingLedgerEntries(in viewModel: CoordinatorModeViewModel) -> [CoordinatorMissionRoutingDecision] {
        viewModel.railTranscriptEntries.compactMap { entry in
            if case let .routing(decision)? = entry.ledger {
                return decision
            }
            return nil
        }
    }

    private func planUpdateLedgerEntries(in viewModel: CoordinatorModeViewModel) -> [CoordinatorModePlanUpdateSummary] {
        viewModel.railTranscriptEntries.compactMap { entry in
            if case let .planUpdate(update)? = entry.ledger {
                return update
            }
            return nil
        }
    }

    private func planEventLedgerEntries(in viewModel: CoordinatorModeViewModel) -> [CoordinatorMissionPlanEvent] {
        viewModel.railTranscriptEntries.compactMap { entry in
            if case let .planEvent(event)? = entry.ledger {
                return event
            }
            return nil
        }
    }

    private func wrapUpLedgerEntryCount(in viewModel: CoordinatorModeViewModel) -> Int {
        viewModel.railTranscriptEntries.count { entry in
            if case .wrapUp(_, _)? = entry.ledger {
                return true
            }
            return false
        }
    }

    private func groundingLedgerEntryCount(in viewModel: CoordinatorModeViewModel) -> Int {
        viewModel.railTranscriptEntries.count { entry in
            if case .grounding(_, _)? = entry.ledger {
                return true
            }
            return false
        }
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func transcriptEntry(
        id: UUID,
        role: CoordinatorModeRailTranscriptEntry.Role,
        text: String,
        at date: Date
    ) -> CoordinatorModeRailTranscriptEntry {
        CoordinatorModeRailTranscriptEntry(
            id: id,
            role: role,
            text: text,
            createdAt: date,
            action: nil
        )
    }
}

@MainActor
private final class CoordinatorContinuationRaceRecorder {
    var providerSubmissions = 0
    var afterSubmitHookCalls = 0
    var replacementSession: AgentModeViewModel.TabSession?
}

private final class CoordinatorResetFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    private(set) var startUserTurnCount = 0

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        startUserTurnCount += 1
        return CodexTurnStartReceipt(provisionalSubmissionID: "<coordinator-test-submission>")
    }

    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
