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
        XCTAssertEqual(submissions.first?.text, "start scoped work")
        XCTAssertNil(submissions.first?.sessionID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, true)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
    }

    func testScopedChangeTemplateWrapsInitialCoordinatorDirectiveOnly() async {
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
        viewModel.selectedMissionTemplate = .scopedChange
        viewModel.refresh()

        let result = await viewModel.submitCoordinatorDirective("fix flaky docs tests")

        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(submissions.first?.text.contains("Run this as a scoped Coordinator change.") == true)
        XCTAssertTrue(submissions.first?.text.hasSuffix("fix flaky docs tests") == true)
        XCTAssertNil(submissions.first?.sessionID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, true)
        XCTAssertEqual(submissions.first?.template, CoordinatorMissionTemplateSummary(.scopedChange))
        XCTAssertNil(viewModel.selectedMissionTemplate)
        XCTAssertEqual(viewModel.railTranscriptEntries.first?.text, "fix flaky docs tests")
    }

    func testCustomMissionTemplateWrapsFreshMissionOnlyAndFollowUpStaysRaw() async {
        let coordinatorID = uuid(1)
        var liveSessions: [CoordinatorModeSnapshotProjector.LiveSession] = []
        var demoCoordinatorIDs: Set<UUID> = []
        let customTemplate = CoordinatorMissionTemplate(
            source: .custom(uuid(700)),
            displayName: "Custom Mission",
            iconName: "wand.and.stars",
            accentColorHex: "#FF00AA",
            tooltipText: nil,
            descriptionText: nil,
            template: "CUSTOM WRAP\n$ARGUMENTS"
        )
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
        viewModel.selectedMissionTemplate = customTemplate
        viewModel.refresh()

        let freshResult = await viewModel.submitCoordinatorDirective("  start mission  ")
        let followUpResult = await viewModel.submitCoordinatorDirective("  follow up  ")

        XCTAssertEqual(freshResult, .accepted)
        XCTAssertEqual(followUpResult, .accepted)
        XCTAssertEqual(submissions.map(\.visibleText), ["start mission", "follow up"])
        XCTAssertEqual(submissions.map(\.providerText), ["CUSTOM WRAP\nstart mission", "follow up"])
        XCTAssertEqual(submissions.first?.missionTemplate, CoordinatorMissionTemplateSummary(customTemplate))
        XCTAssertNil(submissions.last?.missionTemplate)
        XCTAssertNil(viewModel.selectedMissionTemplate)
        XCTAssertEqual(viewModel.railTranscriptEntries.filter { $0.role == .user }.map(\.text), ["start mission", "follow up"])
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
                    skippedSessionIDs: [visibleChildID, planBoundChildID]
                )
            }
        )
        viewModel.selectCoordinator(sessionID: coordinatorID)

        XCTAssertTrue(viewModel.canStopSelectedCoordinatorMission)
        let result = await viewModel.stopSelectedCoordinatorMission()

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(stopRequests.first?.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(stopRequests.first?.sessionIDs, [coordinatorID, visibleChildID, planBoundChildID])
        let stoppedPlan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(stoppedPlan.status, .stopped)
        XCTAssertEqual(stoppedPlan.nodes.map(\.status), [.cancelled, .cancelled, .pending])
        XCTAssertEqual(stoppedPlan.routingDecisions.suffix(1).map(\.operation), [.agentRunCancel])
        XCTAssertEqual(
            Set(stoppedPlan.routingDecisions.suffix(1).compactMap(\.sessionID)),
            Set([coordinatorID])
        )
        XCTAssertTrue(viewModel.railTranscriptEntries.contains { entry in
            entry.role == .event
                && entry.text == "Mission stopped. Requested cancellation for 1 active session; skipped 2 inactive or unavailable linked sessions."
        })
    }

    func testRejectedDraftSendPreservesTemplateSelection() async {
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
        viewModel.selectedMissionTemplate = .scopedChange
        viewModel.refresh()

        let result = await viewModel.submitCoordinatorDirective("try this")

        XCTAssertEqual(result, .rejected(message: "Nope"))
        XCTAssertEqual(viewModel.selectedMissionTemplate, .scopedChange)
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

    func testProceedContinuationSubmitsVisibleCoordinatorMessage() async {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        let input = input(
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

        let result = await viewModel.submitCoordinatorContinuation(.proceed)

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.text, CoordinatorModeViewModel.ContinuationAction.proceed.directiveText)
        XCTAssertEqual(submissions.first?.sessionID, coordinatorID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, false)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.user])
        XCTAssertEqual(viewModel.railTranscriptEntries.first?.text, CoordinatorModeViewModel.ContinuationAction.proceed.directiveText)
    }

    func testLightweightDiscoveryContinuationSubmitsDiscoveryDirective() async throws {
        let text = try await submittedContinuationText(.runLightweightDiscovery)

        XCTAssertTrue(text.contains("coordinator_chat op=mission_status"))
        XCTAssertTrue(text.contains("approval_state:\"awaiting_approval\""))
        XCTAssertTrue(text.contains("execution_policy:\"fresh_readonly_child\""))
        XCTAssertTrue(text.contains("agent_explore.start"))
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
        let input = input(
            live: [
                live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator", updatedAt: date(20), state: .idle, isMCP: true)
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

        let result = await viewModel.submitCoordinatorContinuation(action)

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

    func testExecutionPaceDefaultsStepAndPersistsChanges() throws {
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
        XCTAssertEqual(restored.executionPace, .auto)
        XCTAssertTrue(restored.usesAutoMode)
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

    func testAcceptedDirectiveDoesNotDuplicateRuntimeBackedUserTranscriptEntry() async {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        var transcriptEntries: [CoordinatorModeRailTranscriptEntry] = []
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
                            isMCP: true
                        )
                    ],
                    selectedCoordinatorID: selectedCoordinatorID,
                    sort: sortMode,
                    demoCoordinatorIDs: [coordinatorID]
                )
            },
            transcriptProvider: { _ in transcriptEntries },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { submission in
                transcriptEntries = [
                    self.transcriptEntry(
                        id: self.uuid(1001),
                        role: .user,
                        text: submission.visibleText,
                        at: self.date(30)
                    )
                ]
                return .accepted
            }
        )
        viewModel.refresh()

        let result = await viewModel.submitCoordinatorDirective("what did it say?")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.user])
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.text), ["what did it say?"])
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
        XCTAssertEqual(viewModel.composerNotice, "Next directive will start another Coordinator runtime.")

        let result = await viewModel.submitCoordinatorDirective("start fresh")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.first?.text, "start fresh")
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
        interaction: AgentRunMCPSnapshot.Interaction? = nil
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
            failureReason: nil,
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

    private func makeAgentModeFixture(
        tabs: [ComposeTabState],
        activeTabID: UUID?
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
            codexControllerFactory: { _, _, _, _, _, _ in CoordinatorResetFakeCodexController() }
        )
        viewModel.test_setSidebarAutoArchiveDependencies(promptManager: prompt, workspaceManager: manager)
        return (viewModel, manager, prompt)
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

private final class CoordinatorResetFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
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
