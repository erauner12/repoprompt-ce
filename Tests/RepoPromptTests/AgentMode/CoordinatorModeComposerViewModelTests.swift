@testable import RepoPrompt
import XCTest

@MainActor
final class CoordinatorModeComposerViewModelTests: XCTestCase {
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
                next.selectedCoordinatorID = selectedCoordinatorID
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { text, sessionID, forceNewRuntime in
                submissions.append((text, sessionID, forceNewRuntime))
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
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.role), [.user])
        XCTAssertEqual(viewModel.railTranscriptEntries.first?.text, "Coordinate the child session")
        XCTAssertEqual(viewModel.snapshot.groups, rowsBeforeSubmit)

        viewModel.clearCoordinatorRailTranscript()
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertNil(viewModel.composerNotice)
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

    func testHumanReviewGateDefaultsRequiredAndPersistsChanges() throws {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            userDefaults: defaults
        )
        XCTAssertTrue(initial.requiresHumanReviewAcknowledgement)

        initial.setRequiresHumanReviewAcknowledgement(false)
        XCTAssertFalse(initial.requiresHumanReviewAcknowledgement)

        let restored = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            userDefaults: defaults
        )
        XCTAssertFalse(restored.requiresHumanReviewAcknowledgement)
    }

    func testProactiveFollowThroughDefaultsManualAndPersistsChanges() throws {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            userDefaults: defaults
        )
        XCTAssertFalse(initial.allowsProactiveFollowThrough)

        initial.setAllowsProactiveFollowThrough(true)
        XCTAssertTrue(initial.allowsProactiveFollowThrough)

        let restored = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            userDefaults: defaults
        )
        XCTAssertTrue(restored.allowsProactiveFollowThrough)
    }

    func testMarkReviewedWakesFollowThroughHandlerWhenEnabled() async {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expectation = expectation(description: "follow-through handler")
        var capturedGate: CoordinatorContinuationGate?
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            continuationGateHandler: { gate, _ in
                capturedGate = gate
                expectation.fulfill()
            },
            userDefaults: defaults
        )
        viewModel.setAllowsProactiveFollowThrough(true)

        viewModel.markHumanReviewHandled("merge-review")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(capturedGate?.type, .reviewRequired)
        XCTAssertEqual(capturedGate?.subjectID, "merge-review")
        XCTAssertNil(capturedGate?.ownerCoordinatorSessionID)
        XCTAssertNil(capturedGate?.approvedAction)
    }

    func testMarkReviewedScopesGateToOwningCoordinatorWhenProvided() async {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownerID = uuid(42)
        let expectation = expectation(description: "follow-through handler")
        var capturedGate: CoordinatorContinuationGate?
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            continuationGateHandler: { gate, _ in
                capturedGate = gate
                expectation.fulfill()
            },
            userDefaults: defaults
        )
        viewModel.setAllowsProactiveFollowThrough(true)

        viewModel.markHumanReviewHandled("merge-review", coordinatorSessionID: ownerID)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(capturedGate?.type, .reviewRequired)
        XCTAssertEqual(capturedGate?.subjectID, "merge-review")
        XCTAssertEqual(capturedGate?.ownerCoordinatorSessionID, ownerID)
    }

    func testMarkReviewedDoesNotWakeFollowThroughHandlerWhenManual() async {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expectation = expectation(description: "follow-through handler not called")
        expectation.isInverted = true
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            continuationGateHandler: { _, _ in
                expectation.fulfill()
            },
            userDefaults: defaults
        )

        viewModel.markHumanReviewHandled("merge-review")

        await fulfillment(of: [expectation], timeout: 0.1)
    }

    func testApproveContinuationWakesScopedActionGateWhenEnabled() async {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expectation = expectation(description: "follow-through action approval")
        var capturedGate: CoordinatorContinuationGate?
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            continuationGateHandler: { gate, _ in
                capturedGate = gate
                expectation.fulfill()
            },
            userDefaults: defaults
        )
        viewModel.setAllowsProactiveFollowThrough(true)

        viewModel.approveCoordinatorContinuation(reviewID: "merge-review", subjectTitle: "Review packet")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(capturedGate?.id, "approval:continue:merge-review")
        XCTAssertEqual(capturedGate?.type, .actionApprovalRequired)
        XCTAssertEqual(capturedGate?.subjectID, "merge-review")
        XCTAssertEqual(capturedGate?.subjectTitle, "Review packet")
        XCTAssertNil(capturedGate?.ownerCoordinatorSessionID)
        XCTAssertEqual(capturedGate?.approvedAction, .continuePlan)
    }

    func testApproveContinuationScopesActionGateToOwningCoordinatorWhenProvided() async {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownerID = uuid(42)
        let expectation = expectation(description: "follow-through action approval")
        var capturedGate: CoordinatorContinuationGate?
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            continuationGateHandler: { gate, _ in
                capturedGate = gate
                expectation.fulfill()
            },
            userDefaults: defaults
        )
        viewModel.setAllowsProactiveFollowThrough(true)

        viewModel.approveCoordinatorContinuation(
            reviewID: "merge-review",
            subjectTitle: "Review packet",
            coordinatorSessionID: ownerID
        )

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(capturedGate?.id, "approval:continue:merge-review")
        XCTAssertEqual(capturedGate?.type, .actionApprovalRequired)
        XCTAssertEqual(capturedGate?.subjectID, "merge-review")
        XCTAssertEqual(capturedGate?.subjectTitle, "Review packet")
        XCTAssertEqual(capturedGate?.ownerCoordinatorSessionID, ownerID)
        XCTAssertEqual(capturedGate?.approvedAction, .continuePlan)
    }

    func testApproveContinuationDoesNotWakeWhenManual() async {
        let suiteName = "CoordinatorModeComposerViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expectation = expectation(description: "follow-through action approval not called")
        expectation.isInverted = true
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { _, _ in self.input() },
            dashboardVisibilityHandler: { _ in },
            continuationGateHandler: { _, _ in
                expectation.fulfill()
            },
            userDefaults: defaults
        )

        viewModel.approveCoordinatorContinuation(reviewID: "merge-review", subjectTitle: "Review packet")

        await fulfillment(of: [expectation], timeout: 0.1)
        XCTAssertEqual(
            viewModel.composerNotice,
            "Follow is off. Turn on Follow to approve the next Coordinator step automatically."
        )
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
            directiveSubmitter: { text, _, _ in
                transcriptEntries = [
                    self.transcriptEntry(
                        id: self.uuid(1001),
                        role: .user,
                        text: text,
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
                next.selectedCoordinatorID = selectedCoordinatorID
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { _, _, _ in
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
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
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
            directiveSubmitter: { text, sessionID, forceNewRuntime in
                submissions.append((text, sessionID, forceNewRuntime))
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
        XCTAssertEqual(viewModel.composerNotice, "Next directive will start another Codex Coordinator runtime.")

        let result = await viewModel.submitCoordinatorDirective("start fresh")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.first?.text, "start fresh")
        XCTAssertNil(submissions.first?.sessionID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, true)
        XCTAssertFalse(viewModel.isFreshCoordinatorRunPending)
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
            directiveSubmitter: { text, sessionID, forceNewRuntime in
                submissions.append((text, sessionID, forceNewRuntime))
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
                next.selectedCoordinatorID = selectedCoordinatorID
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { _, _, _ in
                submitterCalled = true
                return .accepted
            }
        )
        viewModel.refresh()
        XCTAssertFalse(viewModel.snapshot.coordinatorRail.isComposerEnabled)

        let result = await viewModel.submitCoordinatorDirective("message")

        XCTAssertEqual(result, .rejected(message: "Coordinator is not available in this window."))
        XCTAssertFalse(submitterCalled)
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertEqual(viewModel.composerNotice, "Coordinator is not available in this window.")
    }

    private func input(
        workspaceID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000090"),
        persisted: [CoordinatorModeSnapshotProjector.PersistedSession] = [],
        live: [CoordinatorModeSnapshotProjector.LiveSession] = [],
        mcpSnapshots: [UUID: AgentRunMCPSnapshot] = [:],
        selectedCoordinatorID: UUID? = nil,
        sort: CoordinatorModeSortMode = .lastUpdated,
        demoCoordinatorIDs: Set<UUID> = []
    ) -> CoordinatorModeSnapshotProjector.Input {
        CoordinatorModeSnapshotProjector.Input(
            workspaceID: workspaceID,
            windowID: 7,
            persistedSessions: persisted,
            liveSessions: live,
            mcpSnapshotsBySessionID: mcpSnapshots,
            selectedCoordinatorID: selectedCoordinatorID,
            sortMode: sort,
            resolvableTabIDs: Set(persisted.map(\.tabID) + live.map(\.tabID) + mcpSnapshots.values.compactMap(\.tabID)),
            demoCoordinatorSessionIDs: demoCoordinatorIDs
        )
    }

    private func persisted(
        id: UUID,
        tab: UUID,
        title: String,
        updatedAt: Date,
        state: AgentSessionRunState? = .idle,
        parent: UUID? = nil,
        isMCP: Bool = false
    ) -> CoordinatorModeSnapshotProjector.PersistedSession {
        CoordinatorModeSnapshotProjector.PersistedSession(
            id: id,
            tabID: tab,
            title: title,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP
        )
    }

    private func live(
        id: UUID,
        tab: UUID,
        title: String,
        updatedAt: Date,
        state: AgentSessionRunState,
        parent: UUID? = nil,
        isMCP: Bool = false
    ) -> CoordinatorModeSnapshotProjector.LiveSession {
        CoordinatorModeSnapshotProjector.LiveSession(
            sessionID: id,
            tabID: tab,
            title: title,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP
        )
    }

    private func mcpSnapshot(
        sessionID: UUID,
        tabID: UUID,
        sessionName: String,
        status: AgentRunMCPSnapshot.Status,
        statusText: String?,
        assistantPreview: String?,
        parent: UUID?
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
            interaction: nil,
            transcriptItemCount: 1,
            updatedAt: date(30),
            parentSessionID: parent,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
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
