import Combine
import Foundation
import MCP

@MainActor
final class CoordinatorModeViewModel: ObservableObject {
    enum DirectiveSubmissionResult: Equatable {
        case accepted
        case rejected(message: String)
    }

    typealias InputProvider = @MainActor (_ sortMode: CoordinatorModeSortMode, _ selectedCoordinatorID: UUID?) -> CoordinatorModeSnapshotProjector.Input
    typealias DashboardVisibilityHandler = @MainActor (_ visible: Bool) -> Void
    typealias DirectiveSubmitter = @MainActor (_ text: String, _ coordinatorSessionID: UUID?, _ forceNewRuntime: Bool) async -> DirectiveSubmissionResult
    typealias ChildDirectiveSubmitter = @MainActor (_ text: String, _ row: CoordinatorModeRow) async -> DirectiveSubmissionResult

    @Published private(set) var snapshot: CoordinatorModeSnapshot = .empty
    @Published private(set) var railTranscriptEntries: [CoordinatorModeRailTranscriptEntry] = []
    @Published private(set) var currentRailActivityText: String?
    @Published private(set) var composerNotice: String?
    @Published private(set) var isFreshCoordinatorRunPending = false
    @Published var sortMode: CoordinatorModeSortMode = .lastUpdated {
        didSet {
            guard sortMode != oldValue else { return }
            refresh()
        }
    }

    private let inputProvider: InputProvider
    private let dashboardVisibilityHandler: DashboardVisibilityHandler
    private let directiveSubmitter: DirectiveSubmitter
    private let childDirectiveSubmitter: ChildDirectiveSubmitter
    private let projector: CoordinatorModeSnapshotProjector
    private var selectedCoordinatorIDByWorkspaceID: [UUID: UUID] = [:]
    private var lastPublishedFingerprint: CoordinatorModeSnapshotFingerprint?
    private var displayedTranscriptCoordinatorSessionID: UUID?
    private var lastDurableRailStatusEntryKey: String?
    private var displayedDelegateActionTargetIDs: Set<UUID> = []
    private(set) var isVisible = false

    init(
        inputProvider: @escaping InputProvider,
        dashboardVisibilityHandler: @escaping DashboardVisibilityHandler,
        directiveSubmitter: @escaping DirectiveSubmitter = { _, _, _ in
            .rejected(message: "Coordinator composer is unavailable.")
        },
        childDirectiveSubmitter: @escaping ChildDirectiveSubmitter = { _, _ in
            .rejected(message: "Session replies are unavailable.")
        },
        projector: CoordinatorModeSnapshotProjector = CoordinatorModeSnapshotProjector()
    ) {
        self.inputProvider = inputProvider
        self.dashboardVisibilityHandler = dashboardVisibilityHandler
        self.directiveSubmitter = directiveSubmitter
        self.childDirectiveSubmitter = childDirectiveSubmitter
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

    @discardableResult
    func refreshIfVisible() -> Bool {
        guard isVisible else { return false }
        refresh()
        return true
    }

    func selectCoordinator(sessionID: UUID?, workspaceID explicitWorkspaceID: UUID? = nil) {
        let workspaceID = explicitWorkspaceID ?? snapshot.workspaceID ?? inputProvider(sortMode, nil).workspaceID
        guard let workspaceID else { return }
        selectedCoordinatorIDByWorkspaceID[workspaceID] = sessionID
        refresh()
    }

    func startNewCoordinatorRun() {
        isFreshCoordinatorRunPending = true
        displayedTranscriptCoordinatorSessionID = nil
        lastDurableRailStatusEntryKey = nil
        displayedDelegateActionTargetIDs.removeAll()
        railTranscriptEntries.removeAll()
        currentRailActivityText = nil
        lastPublishedFingerprint = nil
        selectCoordinator(sessionID: nil)
        composerNotice = "Next directive will start another Codex Coordinator runtime."
    }

    func clearCoordinator() {
        clearCoordinatorRailTranscript()
    }

    func clearCoordinatorRailTranscript() {
        railTranscriptEntries.removeAll()
        lastDurableRailStatusEntryKey = nil
        displayedDelegateActionTargetIDs.removeAll()
        currentRailActivityText = nil
        composerNotice = nil
    }

    @discardableResult
    func submitCoordinatorDirective(_ text: String) async -> DirectiveSubmissionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            composerNotice = nil
            return .rejected(message: "")
        }
        let forceNewRuntime = isFreshCoordinatorRunPending
        let coordinatorSessionID = forceNewRuntime ? nil : snapshot.coordinatorRail.coordinatorSessionID
        if snapshot.coordinatorRail.state == .selected, !forceNewRuntime {
            guard snapshot.coordinatorRail.isComposerEnabled else {
                let message = "Coordinator is not available in this window."
                composerNotice = message
                return .rejected(message: message)
            }
            guard snapshot.coordinatorRail.isComposerSendEnabled else {
                let message = "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary."
                composerNotice = message
                return .rejected(message: message)
            }
        }

        let result = await directiveSubmitter(trimmed, coordinatorSessionID, forceNewRuntime)
        switch result {
        case .accepted:
            isFreshCoordinatorRunPending = false
            composerNotice = nil
            refresh()
            railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
                id: UUID(),
                role: .user,
                text: trimmed,
                createdAt: Date(),
                action: nil
            ))
        case let .rejected(message):
            composerNotice = message.isEmpty ? nil : message
        }
        return result
    }

    @discardableResult
    func submitChildDirective(_ text: String, to row: CoordinatorModeRow) async -> DirectiveSubmissionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected(message: "")
        }
        guard row.tabID != nil, !row.isPersistedOnly else {
            return .rejected(message: "This session is not live in the current window.")
        }
        guard row.runState != .running else {
            return .rejected(message: "This session is mid-run. Reply when it reaches a turn boundary.")
        }

        let result = await childDirectiveSubmitter(trimmed, row)
        if result == .accepted {
            refresh()
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
            currentRailActivityText = nil
            lastDurableRailStatusEntryKey = nil
            displayedDelegateActionTargetIDs = delegatedActionTargetIDs(in: nextSnapshot)
        }
        updateRailStatusPresentation(from: nextSnapshot.coordinatorRail)
        updateRailActionPresentation(from: nextSnapshot)
        let nextFingerprint = nextSnapshot.fingerprint
        guard lastPublishedFingerprint != nextFingerprint else { return }
        lastPublishedFingerprint = nextFingerprint
        snapshot = nextSnapshot
    }

    private func updateRailActionPresentation(from snapshot: CoordinatorModeSnapshot) {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else {
            displayedDelegateActionTargetIDs.removeAll()
            return
        }

        let rows = directDelegatedRows(in: snapshot, coordinatorSessionID: coordinatorSessionID)
            .filter { !displayedDelegateActionTargetIDs.contains($0.sessionID) }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.updatedAt < rhs.updatedAt
            }

        for row in rows {
            displayedDelegateActionTargetIDs.insert(row.sessionID)
            railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
                id: row.sessionID,
                role: .event,
                text: "Delegated to \(row.title)",
                createdAt: row.updatedAt,
                action: CoordinatorModeCoordinatorAction(
                    ownerCoordinatorSessionID: coordinatorSessionID,
                    ownerTitle: snapshot.coordinatorRail.title ?? "Coordinator",
                    targetSessionID: row.sessionID,
                    targetTitle: row.title,
                    verb: .delegate,
                    phase: .resolved
                )
            ))
        }
    }

    private func delegatedActionTargetIDs(in snapshot: CoordinatorModeSnapshot) -> Set<UUID> {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else {
            return []
        }
        return Set(directDelegatedRows(in: snapshot, coordinatorSessionID: coordinatorSessionID).map(\.sessionID))
    }

    private func directDelegatedRows(
        in snapshot: CoordinatorModeSnapshot,
        coordinatorSessionID: UUID
    ) -> [CoordinatorModeRow] {
        snapshot.groups
            .flatMap(\.rows)
            .filter { row in
                row.parentSessionID == coordinatorSessionID && !row.isCoordinator
            }
    }

    private func updateRailStatusPresentation(from rail: CoordinatorModeCoordinatorRail) {
        guard let report = rail.statusReport,
              let text = railStatusConversationText(from: report)
        else {
            currentRailActivityText = nil
            return
        }

        switch railStatusVisibility(for: report) {
        case .ephemeral:
            currentRailActivityText = railEphemeralActivityText(from: report) ?? text
            return
        case .durable:
            currentRailActivityText = nil
        }

        let key = [
            String(describing: report.status),
            report.statusText ?? "",
            report.assistantPreview ?? "",
            report.terminalOutput ?? "",
            report.failureReason.map { String(describing: $0) } ?? ""
        ].joined(separator: "\u{1F}")
        guard key != lastDurableRailStatusEntryKey else { return }

        lastDurableRailStatusEntryKey = key
        railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
            id: UUID(),
            role: report.status.isTerminal ? .coordinator : .event,
            text: text,
            createdAt: Date(),
            action: nil
        ))
    }

    private enum RailStatusVisibility {
        case durable
        case ephemeral
    }

    private func railStatusVisibility(for report: CoordinatorModeSessionStatusReport) -> RailStatusVisibility {
        if report.status.isTerminal || report.status == .waitingForInput || report.failureReason != nil {
            return .durable
        }
        if report.status == .running {
            return .ephemeral
        }
        return .durable
    }

    private func railEphemeralActivityText(from report: CoordinatorModeSessionStatusReport) -> String? {
        let statusText = report.statusText
        return statusText.flatMap { text -> String? in
            switch normalizedTransportStatusText(text) {
            case "queued to start":
                return "Queued to start"
            case "connecting":
                return "Connecting"
            case "sending message":
                return "Sending message"
            case "waiting for response":
                return "Waiting for response"
            case "codex is active", "thinking":
                return "Coordinator is thinking"
            case "compacting context":
                return "Compacting context"
            default:
                return text
            }
        } ?? "Coordinator is working"
    }

    private func railStatusConversationText(from report: CoordinatorModeSessionStatusReport) -> String? {
        if report.status == .completed, let terminalOutput = report.terminalOutput {
            return terminalOutput
        }

        var parts: [String] = []
        if let statusText = report.statusText {
            parts.append(statusText)
        }
        if let failureReason = report.failureReason {
            parts.append("Failure: \(failureReason.displayLabel)")
        }
        if let assistantPreview = report.assistantPreview {
            parts.append(assistantPreview)
        }
        if let terminalOutput = report.terminalOutput {
            parts.append(terminalOutput)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func normalizedTransportStatusText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
            .lowercased()
    }
}

extension AgentModeViewModel {
    @MainActor
    @discardableResult
    func refreshCoordinatorModeForChildLifecycleIfVisible() -> Bool {
        coordinatorModeViewModel.refreshIfVisible()
    }

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
        } directiveSubmitter: { [weak self] text, coordinatorSessionID, forceNewRuntime in
            guard let self else {
                return .rejected(message: "Coordinator composer is unavailable.")
            }
            switch await submitCoordinatorDirectiveToAgentMode(
                text,
                coordinatorSessionID: coordinatorSessionID,
                forceNewRuntime: forceNewRuntime
            ) {
            case .submitted:
                return .accepted
            case let .blocked(message):
                return .rejected(message: message)
            }
        } childDirectiveSubmitter: { [weak self] text, row in
            guard let self else {
                return .rejected(message: "Session replies are unavailable.")
            }
            switch await submitChildDirectiveToAgentMode(text, row: row) {
            case .submitted:
                return .accepted
            case let .blocked(message):
                return .rejected(message: message)
            }
        }
    }

    @MainActor
    func submitCoordinatorDirectiveToAgentMode(
        _ text: String,
        coordinatorSessionID: UUID?,
        forceNewRuntime: Bool = false
    ) async -> UserTurnSubmissionResult {
        let runtime: (tabID: UUID, sessionID: UUID)
        do {
            runtime = try await resolveOrCreateCoordinatorRuntimeDemoTarget(
                preferredSessionID: coordinatorSessionID,
                forceNewRuntime: forceNewRuntime
            )
        } catch {
            return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard let session = sessions[runtime.tabID] else {
            return .blocked(message: "Coordinator composer is unavailable for this session state.")
        }
        guard !session.runState.isActive else {
            return .blocked(message: "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary.")
        }
        guard let target = makeComposerSubmitTarget(tabID: runtime.tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == runtime.sessionID
        else {
            return .blocked(message: "Coordinator composer is unavailable for this session state.")
        }
        return await submitUserTurnCreatingSessionIfNeeded(text: text, target: target) {
            nil
        }
    }

    @MainActor
    func submitChildDirectiveToAgentMode(
        _ text: String,
        row: CoordinatorModeRow
    ) async -> UserTurnSubmissionResult {
        guard let tabID = row.tabID else {
            return .blocked(message: "This session is not live in the current window.")
        }
        guard let session = sessions[tabID] else {
            return .blocked(message: "This session is no longer available.")
        }
        guard session.activeAgentSessionID == row.sessionID else {
            return .blocked(message: "This session changed before the reply could be sent.")
        }
        guard row.runState != .running else {
            return .blocked(message: "This session is mid-run. Reply when it reaches a turn boundary.")
        }
        guard let target = makeComposerSubmitTarget(tabID: tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == row.sessionID
        else {
            return .blocked(message: "This session cannot receive a reply yet.")
        }
        return await submitUserTurnCreatingSessionIfNeeded(text: text, target: target) {
            nil
        }
    }

    @MainActor
    private func clearCoordinatorRuntimeDemoTarget(preferredSessionID: UUID?) {
        for (tabID, session) in sessions {
            let isPreferredLiveSession = preferredSessionID != nil && session.activeAgentSessionID == preferredSessionID
            guard session.isCoordinatorRuntimeDemo || isPreferredLiveSession else { continue }
            session.isCoordinatorRuntimeDemo = false
            renameCoordinatorRuntimeDemoTabForReset(tabID)
        }
    }

    @MainActor
    private func renameCoordinatorRuntimeDemoTabForReset(_ tabID: UUID) {
        guard coordinatorModeTabName(for: tabID) == Self.coordinatorRuntimeDemoSessionName else { return }
        let clearedName = "\(Self.coordinatorRuntimeDemoSessionName) (cleared)"
        var tab = workspaceManager?.composeTab(with: tabID)
        tab?.name = clearedName
        tab?.lastModified = Date()
        if let tab {
            workspaceManager?.updateComposeTab(tab)
            if let workspace = workspaceManager?.workspaces.first(where: { workspace in
                workspace.composeTabs.contains(where: { $0.id == tabID })
            }) {
                promptManager?.loadComposeTabsFromWorkspace(workspace)
            }
        } else {
            promptManager?.renameComposeTab(tabID, to: clearedName)
        }
    }

    #if DEBUG
        @MainActor
        func test_clearCoordinatorRuntimeDemoTarget(preferredSessionID: UUID?) {
            clearCoordinatorRuntimeDemoTarget(preferredSessionID: preferredSessionID)
        }

        @MainActor
        func test_resolveOrCreateCoordinatorRuntimeDemoTarget(
            preferredSessionID: UUID?,
            forceNewRuntime: Bool = false
        ) async throws -> (tabID: UUID, sessionID: UUID) {
            try await resolveOrCreateCoordinatorRuntimeDemoTarget(
                preferredSessionID: preferredSessionID,
                forceNewRuntime: forceNewRuntime
            )
        }

        @MainActor
        func test_refreshCoordinatorModeForChildLifecycleIfVisible() -> Bool {
            refreshCoordinatorModeForChildLifecycleIfVisible()
        }
    #endif

    @MainActor
    private func resolveOrCreateCoordinatorRuntimeDemoTarget(
        preferredSessionID: UUID?,
        forceNewRuntime: Bool = false
    ) async throws -> (tabID: UUID, sessionID: UUID) {
        if forceNewRuntime {
            return try await createCoordinatorRuntimeDemoTarget()
        }

        if let preferredSessionID,
           let match = sessions.first(where: { $0.value.activeAgentSessionID == preferredSessionID })
        {
            let session = match.value
            session.isCoordinatorRuntimeDemo = true
            try await ensureCoordinatorRuntimeDemoControl(tabID: match.key, sessionID: preferredSessionID)
            return (match.key, preferredSessionID)
        }

        return try await createCoordinatorRuntimeDemoTarget()
    }

    @MainActor
    private func createCoordinatorRuntimeDemoTarget() async throws -> (tabID: UUID, sessionID: UUID) {
        let tabID = try await mcpCreateBackgroundSessionTab(name: Self.coordinatorRuntimeDemoSessionName)
        let session = await ensureSessionReady(tabID: tabID)
        guard let sessionID = ensureSessionBoundToTab(session) else {
            throw MCPError.invalidParams("The Coordinator runtime tab could not be bound to an agent session.")
        }
        session.isCoordinatorRuntimeDemo = true
        try await ensureCoordinatorRuntimeDemoControl(tabID: tabID, sessionID: sessionID)
        return (tabID, sessionID)
    }

    @MainActor
    private func ensureCoordinatorRuntimeDemoControl(tabID: UUID, sessionID: UUID) async throws {
        let session = await ensureSessionReady(tabID: tabID)
        session.isCoordinatorRuntimeDemo = true
        if session.mcpControlContext?.sessionID != sessionID {
            try await mcpActivateControlContext(
                forTabID: tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                taskLabelKind: nil,
                startPending: false
            )
        }
        try await mcpConfigureSession(
            tabID: tabID,
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt55CodexHigh.rawValue,
            reasoningEffortRaw: nil
        )
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
        let liveSessions = sessions.values.compactMap { session -> CoordinatorModeSnapshotProjector.LiveSession? in
            guard let sessionID = session.activeAgentSessionID,
                  resolvableTabIDs.contains(session.tabID)
            else { return nil }
            let workflow = session.items.last(where: { $0.kind == .user })?.workflow
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
                activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries,
                workflow: workflow.map(CoordinatorModeWorkflowDisplaySummary.init),
                isCoordinatorInternal: session.isCoordinatorInternalSession
            )
        }
        var mcpSnapshotsBySessionID: [UUID: AgentRunMCPSnapshot] = [:]
        for tabID in mcpControlledTabIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let session = sessions[tabID],
                  let snapshot = mcpSnapshot(for: session)
            else { continue }
            mcpSnapshotsBySessionID[snapshot.sessionID] = snapshot
        }

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
            resolvableTabIDs: resolvableTabIDs,
            demoCoordinatorSessionIDs: Set(sessions.values.compactMap { session in
                session.isCoordinatorRuntimeDemo ? session.activeAgentSessionID : nil
            }),
            coordinatorInternalSessionIDs: Set(sessions.values.compactMap { session in
                session.isCoordinatorInternalSession ? session.activeAgentSessionID : nil
            })
        )
    }

    private static let coordinatorRuntimeDemoSessionName = "Coordinator Runtime Demo"

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
