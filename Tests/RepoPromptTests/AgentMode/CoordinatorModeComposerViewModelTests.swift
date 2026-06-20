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
            ]
        )
        var submissions: [(text: String, sessionID: UUID?)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                next.selectedCoordinatorID = selectedCoordinatorID
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { text, sessionID in
                submissions.append((text, sessionID))
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
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.text), ["Coordinate the child session"])
        XCTAssertEqual(viewModel.snapshot.groups, rowsBeforeSubmit)

        viewModel.clearCoordinatorRailTranscript()
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertNil(viewModel.composerNotice)
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
            ]
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
            directiveSubmitter: { _, _ in
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
        var submissions: [(text: String, sessionID: UUID?)] = []
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
            directiveSubmitter: { text, sessionID in
                submissions.append((text, sessionID))
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

        viewModel.clearCoordinator()

        XCTAssertEqual(resetCoordinatorID, coordinatorID)
        XCTAssertEqual(viewModel.snapshot.coordinatorRail.state, .chooseCoordinator)
        XCTAssertNil(viewModel.snapshot.coordinatorRail.coordinatorSessionID)

        let result = await viewModel.submitCoordinatorDirective("start fresh")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.first?.text, "start fresh")
        XCTAssertNil(submissions.first?.sessionID)
    }

    func testUnreachableCoordinatorRejectsDirectiveWithoutCallingSubmitter() async {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let input = input(persisted: [
            persisted(id: coordinatorID, tab: uuid(101), title: "Coordinator", updatedAt: date(20), isMCP: true),
            persisted(id: childID, tab: uuid(102), title: "Child", updatedAt: date(10), parent: coordinatorID)
        ])
        var submitterCalled = false
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                next.selectedCoordinatorID = selectedCoordinatorID
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { _, _ in
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
        selectedCoordinatorID: UUID? = nil,
        sort: CoordinatorModeSortMode = .lastUpdated,
        demoCoordinatorIDs: Set<UUID> = []
    ) -> CoordinatorModeSnapshotProjector.Input {
        CoordinatorModeSnapshotProjector.Input(
            workspaceID: workspaceID,
            windowID: 7,
            persistedSessions: persisted,
            liveSessions: live,
            selectedCoordinatorID: selectedCoordinatorID,
            sortMode: sort,
            resolvableTabIDs: Set(persisted.map(\.tabID) + live.map(\.tabID)),
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
