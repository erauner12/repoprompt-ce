import Combine
import Foundation

@MainActor
final class CoordinatorModeViewModel: ObservableObject {
    typealias InputProvider = @MainActor (_ sortMode: CoordinatorModeSortMode, _ selectedCoordinatorID: UUID?) -> CoordinatorModeSnapshotProjector.Input
    typealias DashboardVisibilityHandler = @MainActor (_ visible: Bool) -> Void

    @Published private(set) var snapshot: CoordinatorModeSnapshot = .empty
    @Published var sortMode: CoordinatorModeSortMode = .lastUpdated {
        didSet {
            guard sortMode != oldValue else { return }
            refresh()
        }
    }

    private let inputProvider: InputProvider
    private let dashboardVisibilityHandler: DashboardVisibilityHandler
    private let projector: CoordinatorModeSnapshotProjector
    private var selectedCoordinatorIDByWorkspaceID: [UUID: UUID] = [:]
    private var lastPublishedFingerprint: CoordinatorModeSnapshotFingerprint?
    private(set) var isVisible = false

    init(
        inputProvider: @escaping InputProvider,
        dashboardVisibilityHandler: @escaping DashboardVisibilityHandler,
        projector: CoordinatorModeSnapshotProjector = CoordinatorModeSnapshotProjector()
    ) {
        self.inputProvider = inputProvider
        self.dashboardVisibilityHandler = dashboardVisibilityHandler
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

    private func publishIfChanged(_ nextSnapshot: CoordinatorModeSnapshot) {
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
