import Combine
import Foundation
import MCP

@MainActor
final class CoordinatorModeViewModel: ObservableObject {
    enum DirectiveSubmissionResult: Equatable {
        case accepted
        case rejected(message: String)
    }

    enum ContinuationAction: Equatable {
        case proceed
        case stopHere

        var directiveText: String {
            switch self {
            case .proceed:
                "Approved to proceed with the next safe step you proposed. Do not merge, apply, commit, push, create a PR, or perform irreversible actions unless I explicitly request that next."
            case .stopHere:
                "Stop here. Do not continue this objective unless I ask again."
            }
        }
    }

    enum CoordinatorSelectionState: Equatable {
        case newDraft
        case session(UUID)

        var selectedCoordinatorID: UUID? {
            switch self {
            case .newDraft:
                nil
            case let .session(sessionID):
                sessionID
            }
        }
    }

    typealias InputProvider = @MainActor (_ sortMode: CoordinatorModeSortMode, _ selectedCoordinatorID: UUID?) -> CoordinatorModeSnapshotProjector.Input
    typealias TranscriptProvider = @MainActor (_ coordinatorSessionID: UUID?) -> [CoordinatorModeRailTranscriptEntry]
    typealias DashboardVisibilityHandler = @MainActor (_ visible: Bool) -> Void
    typealias DirectiveSubmitter = @MainActor (_ text: String, _ coordinatorSessionID: UUID?, _ forceNewRuntime: Bool) async -> DirectiveSubmissionResult
    typealias ChildDirectiveSubmitter = @MainActor (_ text: String, _ row: CoordinatorModeRow) async -> DirectiveSubmissionResult
    typealias ContinuationGateHandler = @MainActor (_ gate: CoordinatorContinuationGate, _ snapshotBeforeGateCleared: CoordinatorModeSnapshot) async -> Void
    typealias CoordinatorActivationHandler = @MainActor (_ sessionID: UUID) async -> Void
    typealias CoordinatorPinHandler = @MainActor (_ option: CoordinatorModeCoordinatorOption, _ isPinned: Bool) -> Void

    @Published private(set) var snapshot: CoordinatorModeSnapshot = .empty
    @Published private(set) var railTranscriptEntries: [CoordinatorModeRailTranscriptEntry] = []
    @Published private(set) var currentRailActivityText: String?
    @Published private(set) var composerNotice: String?
    @Published private(set) var isFreshCoordinatorRunPending = false
    @Published private(set) var allowsProactiveFollowThrough: Bool
    @Published var selectedWorkflowTemplate: CoordinatorWorkflowTemplate?
    @Published var sortMode: CoordinatorModeSortMode = .lastUpdated {
        didSet {
            guard sortMode != oldValue else { return }
            refresh()
        }
    }

    @Published var boardScope: CoordinatorModeBoardScope = .coordinatorFleet {
        didSet {
            guard boardScope != oldValue else { return }
            refresh()
        }
    }

    private let inputProvider: InputProvider
    private let transcriptProvider: TranscriptProvider
    private let dashboardVisibilityHandler: DashboardVisibilityHandler
    private let directiveSubmitter: DirectiveSubmitter
    private let childDirectiveSubmitter: ChildDirectiveSubmitter
    private let continuationGateHandler: ContinuationGateHandler
    private let coordinatorActivationHandler: CoordinatorActivationHandler
    private let coordinatorPinHandler: CoordinatorPinHandler
    private let projector: CoordinatorModeSnapshotProjector
    private let userDefaults: UserDefaults
    private var coordinatorSelectionByWorkspaceID: [UUID: CoordinatorSelectionState] = [:]
    private var lastPublishedFingerprint: CoordinatorModeSnapshotFingerprint?
    private var displayedTranscriptCoordinatorSessionID: UUID?
    private var lastDurableRailStatusEntryKey: String?
    private var displayedDelegateActionTargetIDs: Set<UUID> = []
    private(set) var isVisible = false

    init(
        inputProvider: @escaping InputProvider,
        transcriptProvider: @escaping TranscriptProvider = { _ in [] },
        dashboardVisibilityHandler: @escaping DashboardVisibilityHandler,
        directiveSubmitter: @escaping DirectiveSubmitter = { _, _, _ in
            .rejected(message: "Coordinator composer is unavailable.")
        },
        childDirectiveSubmitter: @escaping ChildDirectiveSubmitter = { _, _ in
            .rejected(message: "Session replies are unavailable.")
        },
        continuationGateHandler: @escaping ContinuationGateHandler = { _, _ in },
        coordinatorActivationHandler: @escaping CoordinatorActivationHandler = { _ in },
        coordinatorPinHandler: @escaping CoordinatorPinHandler = { _, _ in },
        projector: CoordinatorModeSnapshotProjector = CoordinatorModeSnapshotProjector(),
        userDefaults: UserDefaults = .standard
    ) {
        self.inputProvider = inputProvider
        self.transcriptProvider = transcriptProvider
        self.dashboardVisibilityHandler = dashboardVisibilityHandler
        self.directiveSubmitter = directiveSubmitter
        self.childDirectiveSubmitter = childDirectiveSubmitter
        self.continuationGateHandler = continuationGateHandler
        self.coordinatorActivationHandler = coordinatorActivationHandler
        self.coordinatorPinHandler = coordinatorPinHandler
        self.projector = projector
        self.userDefaults = userDefaults
        allowsProactiveFollowThrough = CoordinatorModeFollowThroughPreference.isEnabled(defaults: userDefaults)
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
        let selectionState = input.workspaceID.flatMap { coordinatorSelectionByWorkspaceID[$0] }
        if let selectionState {
            input.selectedCoordinatorID = selectionState.selectedCoordinatorID
        }
        input.boardScope = boardScope
        let projected = projector.project(input)
        let isNewDraft = selectionState == .newDraft
        isFreshCoordinatorRunPending = isNewDraft
        publishIfChanged(isNewDraft ? pendingFreshCoordinatorSnapshot(from: projected) : projected)
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
        if sessionID != nil {
            isFreshCoordinatorRunPending = false
        }
        coordinatorSelectionByWorkspaceID[workspaceID] = sessionID.map(CoordinatorSelectionState.session) ?? .newDraft
        refresh()
        if let sessionID,
           let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == sessionID }),
           option.isPersistedOnly || !option.isLiveInCurrentWindow
        {
            Task { @MainActor in
                await coordinatorActivationHandler(sessionID)
                refresh()
            }
        }
    }

    func startNewCoordinatorRun() {
        isFreshCoordinatorRunPending = true
        displayedTranscriptCoordinatorSessionID = nil
        lastDurableRailStatusEntryKey = nil
        displayedDelegateActionTargetIDs.removeAll()
        railTranscriptEntries.removeAll()
        currentRailActivityText = nil
        lastPublishedFingerprint = nil
        if let workspaceID = snapshot.workspaceID ?? inputProvider(sortMode, nil).workspaceID {
            coordinatorSelectionByWorkspaceID[workspaceID] = .newDraft
        }
        refresh()
        composerNotice = "Next directive will start another Coordinator runtime."
    }

    func togglePinnedCoordinator(_ option: CoordinatorModeCoordinatorOption) {
        coordinatorPinHandler(option, !option.isPinned)
        refresh()
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

    func setAllowsProactiveFollowThrough(_ allowsFollowThrough: Bool) {
        guard allowsProactiveFollowThrough != allowsFollowThrough else { return }
        allowsProactiveFollowThrough = allowsFollowThrough
        CoordinatorModeFollowThroughPreference.setEnabled(allowsFollowThrough, defaults: userDefaults)
    }

    @discardableResult
    func submitCoordinatorDirective(_ text: String) async -> DirectiveSubmissionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            composerNotice = nil
            return .rejected(message: "")
        }
        let forceNewRuntime = isFreshCoordinatorRunPending || snapshot.coordinatorRail.state == .chooseCoordinator
        let coordinatorSessionID = forceNewRuntime ? nil : snapshot.coordinatorRail.coordinatorSessionID
        let previousCoordinatorIDs = Set(snapshot.coordinatorRail.availableCoordinators.map(\.sessionID))
        let submissionWorkspaceID = snapshot.workspaceID
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

        let submittedText = forceNewRuntime ? selectedWorkflowTemplate.map { $0.wrap(trimmed) } ?? trimmed : trimmed
        let result = await directiveSubmitter(submittedText, coordinatorSessionID, forceNewRuntime)
        switch result {
        case .accepted:
            isFreshCoordinatorRunPending = false
            selectedWorkflowTemplate = nil
            composerNotice = nil
            if forceNewRuntime {
                selectFreshCoordinatorRuntimeIfAvailable(
                    previousCoordinatorIDs: previousCoordinatorIDs,
                    workspaceID: submissionWorkspaceID
                )
            }
            refresh()
            appendUserTranscriptEntryIfMissing(trimmed)
        case let .rejected(message):
            composerNotice = message.isEmpty ? nil : message
        }
        return result
    }

    @discardableResult
    func submitCoordinatorContinuation(_ action: ContinuationAction) async -> DirectiveSubmissionResult {
        await submitCoordinatorDirective(action.directiveText)
    }

    private func selectFreshCoordinatorRuntimeIfAvailable(
        previousCoordinatorIDs: Set<UUID>,
        workspaceID: UUID?
    ) {
        let input = inputProvider(sortMode, nil)
        guard let workspaceID = workspaceID ?? input.workspaceID else { return }
        let newCoordinatorIDs = coordinatorSessionIDs(in: input).subtracting(previousCoordinatorIDs)
        guard let selectedCoordinatorID = newestCoordinatorID(in: newCoordinatorIDs, input: input) else { return }
        coordinatorSelectionByWorkspaceID[workspaceID] = .session(selectedCoordinatorID)
    }

    private func coordinatorSessionIDs(in input: CoordinatorModeSnapshotProjector.Input) -> Set<UUID> {
        var ids = input.demoCoordinatorSessionIDs
        ids.formUnion(input.persistedSessions.compactMap { $0.isCoordinatorRuntime ? $0.id : nil })
        ids.formUnion(input.liveSessions.compactMap { $0.isCoordinatorRuntime ? $0.sessionID : nil })
        ids.formUnion(input.coordinatorDetectionSessions.compactMap { $0.isCoordinatorRuntime ? $0.id : nil })
        return ids
    }

    private func newestCoordinatorID(
        in coordinatorIDs: Set<UUID>,
        input: CoordinatorModeSnapshotProjector.Input
    ) -> UUID? {
        coordinatorIDs.max { lhs, rhs in
            let lhsDate = coordinatorUpdatedAt(lhs, input: input)
            let rhsDate = coordinatorUpdatedAt(rhs, input: input)
            if lhsDate == rhsDate {
                return lhs.uuidString < rhs.uuidString
            }
            return lhsDate < rhsDate
        }
    }

    private func coordinatorUpdatedAt(
        _ sessionID: UUID,
        input: CoordinatorModeSnapshotProjector.Input
    ) -> Date {
        [
            input.liveSessions.first { $0.sessionID == sessionID }?.updatedAt,
            input.persistedSessions.first { $0.id == sessionID }?.updatedAt,
            input.coordinatorDetectionSessions.first { $0.id == sessionID }?.updatedAt,
            input.mcpSnapshotsBySessionID[sessionID]?.updatedAt
        ]
        .compactMap(\.self)
        .max() ?? .distantPast
    }

    private func pendingFreshCoordinatorSnapshot(from projected: CoordinatorModeSnapshot) -> CoordinatorModeSnapshot {
        let options = projected.coordinatorRail.availableCoordinators.map { option in
            CoordinatorModeCoordinatorOption(
                sessionID: option.sessionID,
                tabID: option.tabID,
                workspaceID: option.workspaceID,
                title: option.title,
                selectionSource: option.selectionSource,
                isSelected: false,
                isLiveInCurrentWindow: option.isLiveInCurrentWindow,
                isPinned: option.isPinned,
                isPersistedOnly: option.isPersistedOnly,
                childCounts: option.childCounts,
                runState: option.runState,
                updatedAt: option.updatedAt,
                lastActivityAt: option.lastActivityAt
            )
        }
        let rail = CoordinatorModeCoordinatorRail(
            state: .chooseCoordinator,
            coordinatorSessionID: nil,
            coordinatorTabID: nil,
            selectionSource: nil,
            title: nil,
            availableCoordinators: options,
            isLiveInCurrentWindow: false,
            isPersistedOnly: false,
            isPinned: false,
            childCounts: .empty,
            openAgentChatRoute: nil,
            statusReport: nil,
            isComposerEnabled: false,
            isComposerSendEnabled: false
        )
        return CoordinatorModeSnapshot(
            workspaceID: projected.workspaceID,
            sortMode: projected.sortMode,
            boardScope: projected.boardScope,
            counts: projected.counts,
            groups: projected.groups,
            coordinatorRail: rail,
            pendingInteractions: projected.pendingInteractions,
            mcpAwareness: projected.mcpAwareness,
            isEmpty: projected.isEmpty
        )
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
            let previousCoordinatorSessionID = displayedTranscriptCoordinatorSessionID
            railTranscriptEntries.removeAll()
            composerNotice = nil
            displayedTranscriptCoordinatorSessionID = nextCoordinatorSessionID
            currentRailActivityText = nil
            lastDurableRailStatusEntryKey = nil
            if previousCoordinatorSessionID == nil,
               let coordinatorSessionID = nextCoordinatorSessionID
            {
                displayedDelegateActionTargetIDs = Set(directDelegatedRows(
                    in: nextSnapshot,
                    coordinatorSessionID: coordinatorSessionID
                ).map(\.sessionID))
            } else {
                displayedDelegateActionTargetIDs.removeAll()
            }
        }
        updateRailStatusPresentation(from: nextSnapshot.coordinatorRail)
        updateRailActionPresentation(from: nextSnapshot)
        syncRailConversationTranscript(for: nextCoordinatorSessionID)
        let nextFingerprint = nextSnapshot.fingerprint
        guard lastPublishedFingerprint != nextFingerprint else { return }
        lastPublishedFingerprint = nextFingerprint
        snapshot = nextSnapshot
    }

    private func appendUserTranscriptEntryIfMissing(_ text: String) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }
        let alreadyVisible = railTranscriptEntries.contains { entry in
            entry.role == .user
                && entry.action == nil
                && entry.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText
        }
        guard !alreadyVisible else { return }
        railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
            id: UUID(),
            role: .user,
            text: normalizedText,
            createdAt: Date(),
            action: nil
        ))
    }

    private func syncRailConversationTranscript(for coordinatorSessionID: UUID?) {
        let transcriptEntries = transcriptProvider(coordinatorSessionID)
        guard !transcriptEntries.isEmpty else { return }

        var mergedEntries = railTranscriptEntries.filter { entry in
            entry.role == .event || entry.action != nil
        }
        var seenIDs = Set(mergedEntries.map(\.id))
        for entry in transcriptEntries where !seenIDs.contains(entry.id) {
            mergedEntries.append(entry)
            seenIDs.insert(entry.id)
        }
        mergedEntries.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
        railTranscriptEntries = mergedEntries
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
        let role: CoordinatorModeRailTranscriptEntry.Role = report.status.isTerminal ? .coordinator : .event
        var displayText = text
        var checkpoint: CoordinatorModeConversationCheckpoint?
        if role == .coordinator {
            let parsed = CoordinatorModeConversationCheckpointParser.parse(text)
            displayText = parsed.visibleText
            checkpoint = parsed.checkpoint
        }

        railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
            id: UUID(),
            role: role,
            text: displayText,
            createdAt: Date(),
            action: nil,
            checkpoint: checkpoint
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
    func refreshCoordinatorModeIfVisible() -> Bool {
        visibleCoordinatorModeViewModel?.refreshIfVisible() ?? false
    }

    @MainActor
    @discardableResult
    func refreshCoordinatorModeForChildLifecycleIfVisible() -> Bool {
        let refreshed = visibleCoordinatorModeViewModel?.refreshIfVisible() ?? false
        guard refreshed else { return false }
        Task { @MainActor [weak self] in
            await self?.evaluateCoordinatorFollowThrough(trigger: .lifecycle)
        }
        return true
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
        } transcriptProvider: { [weak self] coordinatorSessionID in
            self?.coordinatorModeRailTranscriptEntries(for: coordinatorSessionID) ?? []
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
        } continuationGateHandler: { [weak self] gate, snapshotBeforeGateCleared in
            if let ownerID = gate.ownerCoordinatorSessionID {
                await self?.evaluateCoordinatorFollowThrough(
                    coordinatorSessionID: ownerID,
                    snapshot: snapshotBeforeGateCleared,
                    trigger: .gateCleared(gate)
                )
            } else {
                await self?.evaluateCoordinatorFollowThrough(
                    trigger: .gateCleared(gate),
                    snapshot: snapshotBeforeGateCleared
                )
            }
        } coordinatorActivationHandler: { [weak self] sessionID in
            await self?.activateCoordinatorRuntimeSession(sessionID)
        } coordinatorPinHandler: { [weak self] option, isPinned in
            self?.setCoordinatorRuntimePinned(isPinned, option: option)
        }
    }

    @MainActor
    func coordinatorModeRailTranscriptEntries(for coordinatorSessionID: UUID?) -> [CoordinatorModeRailTranscriptEntry] {
        guard let coordinatorSessionID,
              let session = sessions.values.first(where: { session in
                  session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
              })
        else { return [] }

        return session.items.compactMap { item in
            guard let role = coordinatorModeRailRole(for: item.kind) else { return nil }
            var text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var checkpoint: CoordinatorModeConversationCheckpoint?
            if role == .coordinator {
                let parsed = CoordinatorModeConversationCheckpointParser.parse(text)
                text = parsed.visibleText
                checkpoint = parsed.checkpoint
            }
            guard AgentDisplayableText.hasDisplayableBody(text) else { return nil }
            if role == .user, isCoordinatorFollowThroughResumeDirective(text) {
                return nil
            }
            return CoordinatorModeRailTranscriptEntry(
                id: item.id,
                role: role,
                text: text,
                createdAt: item.timestamp,
                action: nil,
                checkpoint: checkpoint
            )
        }
    }

    private func coordinatorModeRailRole(for itemKind: AgentChatItemKind) -> CoordinatorModeRailTranscriptEntry.Role? {
        switch itemKind {
        case .user:
            .user
        case .assistant, .assistantInline, .error:
            .coordinator
        case .toolCall, .toolResult, .system, .thinking:
            nil
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
        let result = await submitUserTurnCreatingSessionIfNeeded(text: text, target: target) {
            nil
        }
        if case .submitted = result,
           !isCoordinatorFollowThroughResumeDirective(text)
        {
            rememberCoordinatorObjective(text, tabID: runtime.tabID)
        }
        return result
    }

    @MainActor
    private func evaluateCoordinatorFollowThrough(
        trigger: CoordinatorFollowThroughBoundaryClassifier.Trigger,
        snapshot explicitSnapshot: CoordinatorModeSnapshot? = nil
    ) async {
        guard coordinatorModeViewModel.allowsProactiveFollowThrough else { return }
        let snapshot = explicitSnapshot ?? coordinatorModeViewModel.snapshot
        let rows = coordinatorModeRows(in: snapshot)
        let coordinatorIDs = Set(
            rows.compactMap { $0.parentCoordinator?.sessionID }
                + snapshot.coordinatorRail.availableCoordinators.map(\.sessionID)
        )
        for coordinatorID in coordinatorIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            await evaluateCoordinatorFollowThrough(
                coordinatorSessionID: coordinatorID,
                rows: rows,
                trigger: trigger
            )
        }
    }

    @MainActor
    private func evaluateCoordinatorFollowThrough(
        coordinatorSessionID: UUID,
        snapshot explicitSnapshot: CoordinatorModeSnapshot,
        trigger: CoordinatorFollowThroughBoundaryClassifier.Trigger
    ) async {
        guard coordinatorModeViewModel.allowsProactiveFollowThrough else { return }
        await evaluateCoordinatorFollowThrough(
            coordinatorSessionID: coordinatorSessionID,
            rows: coordinatorModeRows(in: explicitSnapshot),
            trigger: trigger
        )
    }

    @MainActor
    private func evaluateCoordinatorFollowThrough(
        coordinatorSessionID: UUID,
        rows: [CoordinatorModeRow],
        trigger: CoordinatorFollowThroughBoundaryClassifier.Trigger
    ) async {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else { return }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        guard state.originalObjectiveSummary?.isEmpty == false else { return }

        let ownedRows = rows.filter { $0.parentCoordinator?.sessionID == coordinatorSessionID }
        defer {
            var latest = session.coordinatorFollowThroughState ?? state
            latest.updateObservedPhases(from: ownedRows)
            session.coordinatorFollowThroughState = latest
            scheduleSave(for: tabID)
        }

        if case .gateCleared = trigger {
            let classifier = CoordinatorFollowThroughBoundaryClassifier()
            let input = CoordinatorFollowThroughBoundaryClassifier.Input(
                followThroughEnabled: coordinatorModeViewModel.allowsProactiveFollowThrough,
                coordinatorSessionID: coordinatorSessionID,
                coordinatorRunState: session.runState,
                rows: rows,
                state: state,
                trigger: trigger
            )
            switch classifier.classify(input) {
            case let .resume(event):
                state.removePendingEvents { pending in
                    pending.kind != .gateCleared
                        && (
                            (event.childSessionID != nil && pending.childSessionID == event.childSessionID)
                                || (event.gate?.subjectID != nil && pending.gate?.subjectID == event.gate?.subjectID)
                        )
                }
                session.coordinatorFollowThroughState = state
                await submitCoordinatorFollowThroughEvent(event, tabID: tabID, session: session)
            case .hold(.coordinatorActive):
                var idleInput = input
                idleInput.coordinatorRunState = .idle
                if case let .resume(event) = classifier.classify(idleInput) {
                    state.removePendingEvents { pending in
                        pending.kind != .gateCleared
                            && (
                                (event.childSessionID != nil && pending.childSessionID == event.childSessionID)
                                    || (event.gate?.subjectID != nil && pending.gate?.subjectID == event.gate?.subjectID)
                            )
                    }
                    state.enqueue(event)
                    session.coordinatorFollowThroughState = state
                    scheduleSave(for: tabID)
                }
            case .hold:
                break
            }
            return
        }

        if !session.runState.isActive, let pending = state.pendingEvents.first {
            await submitCoordinatorFollowThroughEvent(pending, tabID: tabID, session: session)
            return
        }

        let classifier = CoordinatorFollowThroughBoundaryClassifier()
        var input = CoordinatorFollowThroughBoundaryClassifier.Input(
            followThroughEnabled: coordinatorModeViewModel.allowsProactiveFollowThrough,
            coordinatorSessionID: coordinatorSessionID,
            coordinatorRunState: session.runState,
            rows: rows,
            state: state,
            trigger: trigger
        )
        let decision = classifier.classify(input)
        switch decision {
        case let .resume(event):
            await submitCoordinatorFollowThroughEvent(event, tabID: tabID, session: session)
        case .hold(.coordinatorActive):
            input.coordinatorRunState = .idle
            if case let .resume(event) = classifier.classify(input) {
                state.enqueue(event)
                session.coordinatorFollowThroughState = state
            }
        case .hold:
            break
        }
    }

    @MainActor
    private func submitCoordinatorFollowThroughEvent(
        _ event: CoordinatorFollowThroughEvent,
        tabID: UUID,
        session: TabSession
    ) async {
        guard !session.runState.isActive else {
            var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
            state.enqueue(event)
            session.coordinatorFollowThroughState = state
            scheduleSave(for: tabID)
            return
        }
        let result = await submitCoordinatorDirectiveToAgentMode(
            event.resumeDirective,
            coordinatorSessionID: event.coordinatorSessionID,
            forceNewRuntime: false
        )
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        switch result {
        case .submitted:
            state.markSubmitted(event)
        case .blocked:
            state.enqueue(event)
            state.markDeferred(event)
        }
        session.coordinatorFollowThroughState = state
        scheduleSave(for: tabID)
    }

    @MainActor
    private func rememberCoordinatorObjective(_ text: String, tabID: UUID) {
        guard let session = sessions[tabID], session.isCoordinatorRuntime else { return }
        var state = CoordinatorFollowThroughState()
        state.rememberObjective(text)
        if let coordinatorID = session.activeAgentSessionID {
            let existingRows = coordinatorModeRows(in: coordinatorModeViewModel.snapshot)
                .filter { $0.parentCoordinator?.sessionID == coordinatorID }
            state.updateObservedPhases(from: existingRows)
        }
        session.coordinatorFollowThroughState = state
        scheduleSave(for: tabID)
    }

    private func isCoordinatorFollowThroughResumeDirective(_ text: String) -> Bool {
        text.contains("<coordinator_follow_through_resume")
    }

    private func coordinatorModeRows(in snapshot: CoordinatorModeSnapshot) -> [CoordinatorModeRow] {
        snapshot.groups.flatMap(\.rows)
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

        if let preferredSessionID,
           ownerValidatedSessionIndex[preferredSessionID]?.isCoordinatorRuntime == true
        {
            let target = try await mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: preferredSessionID,
                createIfNeeded: true,
                sessionName: ownerValidatedSessionIndex[preferredSessionID]?.name ?? Self.coordinatorRuntimeDemoSessionName
            )
            guard let sessionID = target.sessionID else {
                throw MCPError.invalidParams("The Coordinator runtime tab could not be bound to the selected session.")
            }
            try await ensureCoordinatorRuntimeDemoControl(tabID: target.tabID, sessionID: sessionID)
            return (target.tabID, sessionID)
        }

        return try await createCoordinatorRuntimeDemoTarget()
    }

    @MainActor
    private func activateCoordinatorRuntimeSession(_ sessionID: UUID) async {
        do {
            let target = try await mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: sessionID,
                createIfNeeded: true,
                sessionName: ownerValidatedSessionIndex[sessionID]?.name ?? Self.coordinatorRuntimeDemoSessionName
            )
            guard let resolvedSessionID = target.sessionID else { return }
            try await ensureCoordinatorRuntimeDemoControl(tabID: target.tabID, sessionID: resolvedSessionID)
        } catch {
            #if DEBUG
                AgentModePerfDiagnostics.event(
                    "coordinator.runtime.activateFailed",
                    fields: ["sessionID": sessionID.uuidString, "error": String(describing: error)]
                )
            #endif
        }
    }

    @MainActor
    private func setCoordinatorRuntimePinned(
        _ isPinned: Bool,
        option: CoordinatorModeCoordinatorOption
    ) {
        guard let tabID = option.tabID else { return }
        promptManager?.setComposeTabPinned(isPinned, for: tabID)
    }

    @MainActor
    private func createCoordinatorRuntimeDemoTarget() async throws -> (tabID: UUID, sessionID: UUID) {
        let tabID = try await mcpCreateCoordinatorRuntimeTab(name: Self.coordinatorRuntimeDemoSessionName)
        let session = await ensureSessionReady(tabID: tabID)
        guard let sessionID = ensureSessionBoundToTab(session) else {
            throw MCPError.invalidParams("The Coordinator runtime tab could not be bound to an agent session.")
        }
        session.isCoordinatorRuntime = true
        try await ensureCoordinatorRuntimeDemoControl(tabID: tabID, sessionID: sessionID)
        return (tabID, sessionID)
    }

    @MainActor
    private func ensureCoordinatorRuntimeDemoControl(tabID: UUID, sessionID: UUID) async throws {
        let session = await ensureSessionReady(tabID: tabID)
        session.isCoordinatorRuntime = true
        if session.mcpControlContext?.sessionID != sessionID {
            try await mcpActivateControlContext(
                forTabID: tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                taskLabelKind: .coordinator,
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
        let tabStateByID = coordinatorModeTabStateByID()
        let persistedSessions = ownerValidatedSessionIndex.values.map { entry in
            var persisted = CoordinatorModeSnapshotProjector.PersistedSession(
                entry: entry,
                updatedAt: ownerValidatedSessionListSortDates[entry.tabID]
                    ?? AgentSessionRestoreSupport.sidebarActivityDate(for: entry)
            )
            if let tab = tabStateByID[entry.tabID] {
                persisted.title = tab.name
                persisted.isPinned = tab.isPinned
            }
            return persisted
        }
        let liveSessions = sessions.values.compactMap { session -> CoordinatorModeSnapshotProjector.LiveSession? in
            guard let sessionID = session.activeAgentSessionID,
                  resolvableTabIDs.contains(session.tabID)
            else { return nil }
            let workflow = session.items.last(where: { $0.kind == .user })?.workflow
            let tab = tabStateByID[session.tabID]
            return CoordinatorModeSnapshotProjector.LiveSession(
                sessionID: sessionID,
                tabID: session.tabID,
                title: tab?.name ?? ownerValidatedSessionIndex[sessionID]?.name ?? "Agent Session",
                updatedAt: session.lastUserMessageAt ?? session.lastActivityAt,
                runState: session.runState,
                agentKind: session.selectedAgent.rawValue,
                agentModel: session.selectedModelRaw,
                parentSessionID: session.parentSessionID,
                isMCPOriginated: session.isMCPOriginated,
                worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries,
                workflow: workflow.map(CoordinatorModeWorkflowDisplaySummary.init),
                isCoordinatorInternal: session.isCoordinatorInternalSession,
                isCoordinatorRuntime: session.isCoordinatorRuntime,
                isPinned: tab?.isPinned ?? false
            )
        }
        var mcpSnapshotsBySessionID: [UUID: AgentRunMCPSnapshot] = [:]
        for tabID in mcpControlledTabIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let session = sessions[tabID],
                  !session.isCoordinatorRuntime,
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
    private func coordinatorModeTabStateByID() -> [UUID: ComposeTabState] {
        let composeTabs = promptManager?.currentComposeTabs ?? workspaceManager?.activeWorkspace?.composeTabs ?? []
        let stashedTabs = workspaceManager?.activeWorkspace?.stashedTabs.map(\.tab) ?? []
        return Dictionary((composeTabs + stashedTabs).map { ($0.id, $0) }, uniquingKeysWith: { active, _ in active })
    }

    @MainActor
    private func coordinatorModeTabName(for tabID: UUID) -> String? {
        promptManager?.currentComposeTabs.first(where: { $0.id == tabID })?.name
            ?? workspaceManager?.composeTabName(with: tabID)
    }
}
