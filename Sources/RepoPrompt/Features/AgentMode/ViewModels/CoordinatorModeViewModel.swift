import Combine
import Foundation

@MainActor
final class CoordinatorModeViewModel: ObservableObject {
    enum DirectiveSubmissionResult: Equatable {
        case accepted
        case rejected(message: String)
    }

    typealias InputProvider = @MainActor (_ sortMode: CoordinatorModeSortMode, _ selectedCoordinatorID: UUID?) -> CoordinatorModeSnapshotProjector.Input
    typealias DashboardVisibilityHandler = @MainActor (_ visible: Bool) -> Void
    typealias DirectiveSubmitter = @MainActor (_ text: String, _ coordinatorSessionID: UUID) async -> DirectiveSubmissionResult

    @Published private(set) var snapshot: CoordinatorModeSnapshot = .empty
    @Published private(set) var railTranscriptEntries: [CoordinatorModeRailTranscriptEntry] = []
    @Published private(set) var composerNotice: String?
    @Published var sortMode: CoordinatorModeSortMode = .lastUpdated {
        didSet {
            guard sortMode != oldValue else { return }
            refresh()
        }
    }

    private let inputProvider: InputProvider
    private let dashboardVisibilityHandler: DashboardVisibilityHandler
    private let directiveSubmitter: DirectiveSubmitter
    private let projector: CoordinatorModeSnapshotProjector
    private var selectedCoordinatorIDByWorkspaceID: [UUID: UUID] = [:]
    private var lastPublishedFingerprint: CoordinatorModeSnapshotFingerprint?
    private var displayedTranscriptCoordinatorSessionID: UUID?
    private(set) var isVisible = false

    init(
        inputProvider: @escaping InputProvider,
        dashboardVisibilityHandler: @escaping DashboardVisibilityHandler,
        directiveSubmitter: @escaping DirectiveSubmitter = { _, _ in
            .rejected(message: "Coordinator composer is unavailable.")
        },
        projector: CoordinatorModeSnapshotProjector = CoordinatorModeSnapshotProjector()
    ) {
        self.inputProvider = inputProvider
        self.dashboardVisibilityHandler = dashboardVisibilityHandler
        self.directiveSubmitter = directiveSubmitter
        self.projector = projector
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        dashboardVisibilityHandler(visible)
        if visible {
            refresh()
        }
    }

    func refresh() {
        var input = inputProvider(sortMode, nil)
        input.selectedCoordinatorID = input.workspaceID.flatMap { selectedCoordinatorIDByWorkspaceID[$0] }
        publishIfChanged(projector.project(input))
    }

    func selectCoordinator(sessionID: UUID?, workspaceID explicitWorkspaceID: UUID? = nil) {
        let workspaceID = explicitWorkspaceID ?? snapshot.workspaceID ?? inputProvider(sortMode, nil).workspaceID
        guard let workspaceID else { return }
        selectedCoordinatorIDByWorkspaceID[workspaceID] = sessionID
        refresh()
    }

    func clearCoordinatorRailTranscript() {
        railTranscriptEntries.removeAll()
        composerNotice = nil
    }

    @discardableResult
    func submitCoordinatorDirective(_ text: String) async -> DirectiveSubmissionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            composerNotice = nil
            return .rejected(message: "")
        }
        guard snapshot.coordinatorRail.state == .selected,
              snapshot.coordinatorRail.isComposerEnabled,
              let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID
        else {
            let message = "Open agent chat to message this Coordinator."
            composerNotice = message
            return .rejected(message: message)
        }
        guard snapshot.coordinatorRail.isComposerSendEnabled else {
            let message = "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary."
            composerNotice = message
            return .rejected(message: message)
        }

        let result = await directiveSubmitter(trimmed, coordinatorSessionID)
        switch result {
        case .accepted:
            composerNotice = nil
            railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
                id: UUID(),
                role: .user,
                text: trimmed,
                createdAt: Date()
            ))
            refresh()
        case let .rejected(message):
            composerNotice = message.isEmpty ? nil : message
        }
        return result
    }

    #if DEBUG
        func testPublish(_ snapshot: CoordinatorModeSnapshot) {
            self.snapshot = snapshot
        }
    #endif

    private func publishIfChanged(_ nextSnapshot: CoordinatorModeSnapshot) {
        let nextCoordinatorSessionID = nextSnapshot.coordinatorRail.coordinatorSessionID
        if displayedTranscriptCoordinatorSessionID != nextCoordinatorSessionID {
            railTranscriptEntries.removeAll()
            composerNotice = nil
            displayedTranscriptCoordinatorSessionID = nextCoordinatorSessionID
        }
        let nextFingerprint = nextSnapshot.fingerprint
        guard lastPublishedFingerprint != nextFingerprint else { return }
        lastPublishedFingerprint = nextFingerprint
        snapshot = nextSnapshot
    }
}

extension AgentModeViewModel {
    @MainActor
    func makeCoordinatorModeViewModel() -> CoordinatorModeViewModel {
        CoordinatorModeViewModel { [weak self] sortMode, selectedCoordinatorID in
            guard let self else {
                return CoordinatorModeSnapshotProjector.Input(
                    workspaceID: nil,
                    windowID: nil,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sortMode: sortMode
                )
            }
            return coordinatorModeSnapshotInput(
                sortMode: sortMode,
                selectedCoordinatorID: selectedCoordinatorID
            )
        } dashboardVisibilityHandler: { [weak self] visible in
            self?.setCoordinatorModeDashboardUpdatesVisible(visible)
        } directiveSubmitter: { [weak self] text, coordinatorSessionID in
            guard let self else {
                return .rejected(message: "Coordinator composer is unavailable.")
            }
            switch await submitDemoCoordinatorDirectiveAsAgentModeUserTurn(text, coordinatorSessionID: coordinatorSessionID) {
            case .submitted:
                return .accepted
            case let .blocked(message):
                return .rejected(message: message)
            }
        }
    }

    /// Layer 1 demo/manual fallback only: sends the rail composer text as an ordinary
    /// Agent Mode user turn to the selected current-window Coordinator session.
    /// Future real Coordinator runtime instruction delivery must use a distinct
    /// transport/API, not this selected-session demo path.
    @MainActor
    func submitDemoCoordinatorDirectiveAsAgentModeUserTurn(
        _ text: String,
        coordinatorSessionID: UUID
    ) async -> UserTurnSubmissionResult {
        guard let match = sessions.first(where: { $0.value.activeAgentSessionID == coordinatorSessionID }) else {
            return .blocked(message: "Open agent chat to message this Coordinator.")
        }
        let tabID = match.key
        let session = match.value
        guard !session.runState.isActive else {
            return .blocked(message: "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary.")
        }
        guard let target = makeComposerSubmitTarget(tabID: tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == coordinatorSessionID
        else {
            return .blocked(message: "Coordinator composer is unavailable for this session state.")
        }
        return await submitUserTurnCreatingSessionIfNeeded(text: text, target: target) {
            nil
        }
    }

    @MainActor
    func coordinatorModeSnapshotInput(
        sortMode: CoordinatorModeSortMode = .lastUpdated,
        selectedCoordinatorID: UUID? = nil
    ) -> CoordinatorModeSnapshotProjector.Input {
        let workspaceID = coordinatorModeActiveWorkspaceID
        let resolvableTabIDs = coordinatorModeResolvableTabIDs()
        let persistedSessions = ownerValidatedSessionIndex.values.map { entry in
            CoordinatorModeSnapshotProjector.PersistedSession(
                entry: entry,
                updatedAt: ownerValidatedSessionListSortDates[entry.tabID]
                    ?? AgentSessionRestoreSupport.sidebarActivityDate(for: entry)
            )
        }
        // Workflow and priority metadata remain nil here until Agent Mode exposes a cheap,
        // structured source. Do not derive them from transcript text, assistant prose, or titles.
        let liveSessions = sessions.values.compactMap { session -> CoordinatorModeSnapshotProjector.LiveSession? in
            guard let sessionID = session.activeAgentSessionID,
                  resolvableTabIDs.contains(session.tabID)
            else { return nil }
            return CoordinatorModeSnapshotProjector.LiveSession(
                sessionID: sessionID,
                tabID: session.tabID,
                title: coordinatorModeTabName(for: session.tabID) ?? ownerValidatedSessionIndex[sessionID]?.name ?? "Agent Session",
                updatedAt: session.lastUserMessageAt ?? session.lastActivityAt,
                runState: session.runState,
                agentKind: session.selectedAgent.rawValue,
                agentModel: session.selectedModelRaw,
                parentSessionID: session.parentSessionID,
                isMCPOriginated: session.isMCPOriginated,
                worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
            )
        }
        let liveSessionIDs = Set(liveSessions.map(\.sessionID))
        let mcpSnapshotsBySessionID = Dictionary(
            uniqueKeysWithValues: liveSessionIDs.compactMap { sessionID -> (UUID, AgentRunMCPSnapshot)? in
                guard let snapshot = mcpSnapshot(sessionID: sessionID) else { return nil }
                return (sessionID, snapshot)
            }
        )

        return CoordinatorModeSnapshotProjector.Input(
            workspaceID: workspaceID,
            windowID: coordinatorModeWindowID,
            persistedSessions: persistedSessions,
            liveSessions: liveSessions,
            mcpSnapshotsBySessionID: mcpSnapshotsBySessionID,
            dashboard: coordinatorModeDashboard,
            coordinatorDetectionSessions: persistedSessions.map(CoordinatorModeSnapshotProjector.CoordinatorDetectionSession.init),
            selectedCoordinatorID: selectedCoordinatorID,
            sortMode: sortMode,
            resolvableTabIDs: resolvableTabIDs
        )
    }

    @MainActor
    private func coordinatorModeResolvableTabIDs() -> Set<UUID> {
        let composeTabs = promptManager?.currentComposeTabs ?? workspaceManager?.activeWorkspace?.composeTabs ?? []
        let stashedTabs = workspaceManager?.activeWorkspace?.stashedTabs.map(\.tab) ?? []
        return Set((composeTabs + stashedTabs).map(\.id))
    }

    @MainActor
    private func coordinatorModeTabName(for tabID: UUID) -> String? {
        promptManager?.currentComposeTabs.first(where: { $0.id == tabID })?.name
            ?? workspaceManager?.composeTabName(with: tabID)
    }
}
