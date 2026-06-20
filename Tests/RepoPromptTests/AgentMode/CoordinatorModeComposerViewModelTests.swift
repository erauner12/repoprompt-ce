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

    func testForceNewCoordinatorRuntimeCreatesDifferentRuntimeEvenWhenOldRuntimeIsMarked() async throws {
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
        XCTAssertFalse(oldSession.isCoordinatorRuntimeDemo)
        XCTAssertNotEqual(fixture.manager.composeTabName(with: oldTabID), "Coordinator Runtime Demo")
        XCTAssertTrue(viewModel.sessions[next.tabID]?.isCoordinatorRuntimeDemo == true)
    }

    func testClearCoordinatorRuntimeDemoTargetForcesResolverToCreateDifferentRuntime() async throws {
        let oldTabID = uuid(201)
        let oldSessionID = uuid(202)
        let replacementTabID = uuid(203)
        let replacementSessionID = uuid(204)
        var oldTab = ComposeTabState(id: oldTabID, name: "Coordinator Runtime Demo", activeAgentSessionID: oldSessionID)
        oldTab.lastModified = date(20)
        var replacementTab = ComposeTabState(id: replacementTabID, name: "Coordinator Runtime Demo", activeAgentSessionID: replacementSessionID)
        replacementTab.lastModified = date(30)
        let fixture = makeAgentModeFixture(tabs: [oldTab, replacementTab], activeTabID: oldTabID)
        let viewModel = fixture.viewModel
        let oldSession = await viewModel.ensureSessionReady(tabID: oldTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: oldSessionID, on: oldSession)
        oldSession.isCoordinatorRuntimeDemo = true
        let replacementSession = await viewModel.ensureSessionReady(tabID: replacementTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: replacementSessionID, on: replacementSession)

        let original = try await viewModel.test_resolveOrCreateCoordinatorRuntimeDemoTarget(preferredSessionID: nil)
        XCTAssertEqual(original.tabID, oldTabID)
        XCTAssertEqual(original.sessionID, oldSessionID)

        viewModel.test_clearCoordinatorRuntimeDemoTarget(preferredSessionID: uuid(999))

        XCTAssertFalse(oldSession.isCoordinatorRuntimeDemo)
        XCTAssertNotEqual(fixture.manager.composeTabName(with: oldTabID), "Coordinator Runtime Demo")

        let next = try await viewModel.test_resolveOrCreateCoordinatorRuntimeDemoTarget(preferredSessionID: nil)

        XCTAssertEqual(next.tabID, replacementTabID)
        XCTAssertEqual(next.sessionID, replacementSessionID)
        XCTAssertTrue(replacementSession.isCoordinatorRuntimeDemo)
    }

    func testClearCoordinatorResetsDemoRuntimeBeforeNextDirective() async {
        let coordinatorID = uuid(1)
        let coordinatorTab = uuid(101)
        var demoCoordinatorIDs: Set<UUID> = [coordinatorID]
        var resetCoordinatorID: UUID?
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
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { text, sessionID, forceNewRuntime in
                submissions.append((text, sessionID, forceNewRuntime))
                return .accepted
            },
            coordinatorResetHandler: { sessionID in
                resetCoordinatorID = sessionID
                if let sessionID {
                    demoCoordinatorIDs.remove(sessionID)
                }
            }
        )
        viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.selectionSource, .demoRuntime)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.coordinatorSessionID, coordinatorID)

        viewModel.startNewCoordinatorRun()
        XCTAssertEqual(resetCoordinatorID, coordinatorID)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.state, .chooseCoordinator)
        XCTAssertNil(viewModel.snapshot.coordinatorRail.coordinatorSessionID)
        XCTAssertTrue(viewModel.isFreshCoordinatorRunPending)
        XCTAssertEqual(viewModel.composerNotice, "Next directive will start a new Codex Coordinator runtime.")

        let result = await viewModel.submitCoordinatorDirective("start fresh")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.first?.text, "start fresh")
        XCTAssertNil(submissions.first?.sessionID)
        XCTAssertEqual(submissions.first?.forceNewRuntime, true)
        XCTAssertFalse(viewModel.isFreshCoordinatorRunPending)
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

        XCTAssertEqual(result, .rejected(message: "Open agent chat to message this Coordinator."))
        XCTAssertFalse(submitterCalled)
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertEqual(viewModel.composerNotice, "Open agent chat to message this Coordinator.")
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
