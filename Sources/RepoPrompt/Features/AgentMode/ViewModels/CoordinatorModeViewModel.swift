import Combine
import Foundation
import MCP

struct CoordinatorDirectiveSubmission: Equatable {
    let visibleText: String
    let providerText: String
    let missionTemplate: CoordinatorMissionTemplateSummary?
    let coordinatorSessionID: UUID?
    let forceNewRuntime: Bool
}

struct CoordinatorMissionStopRequest: Equatable {
    let coordinatorSessionID: UUID
    let sessionIDs: [UUID]
}

struct CoordinatorMissionStopResult: Equatable {
    let requestedSessionIDs: [UUID]
    let cancelledSessionIDs: [UUID]
    let skippedSessionIDs: [UUID]
}

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

    struct ChildInteractionResponseSubmission: Equatable {
        var text: String?
        var skip: Bool
        var answersByQuestionID: [String: AgentAskUserAnswer]
        var displayText: String

        static func text(_ text: String) -> ChildInteractionResponseSubmission {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChildInteractionResponseSubmission(
                text: trimmed,
                skip: false,
                answersByQuestionID: [:],
                displayText: trimmed
            )
        }

        var fallbackText: String {
            let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedText.isEmpty {
                return trimmedText
            }
            return displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var hasStructuredAnswers: Bool {
            !answersByQuestionID.isEmpty
        }
    }

    typealias InputProvider = @MainActor (_ sortMode: CoordinatorModeSortMode, _ selectedCoordinatorID: UUID?) -> CoordinatorModeSnapshotProjector.Input
    typealias TranscriptProvider = @MainActor (_ coordinatorSessionID: UUID?) -> [CoordinatorModeRailTranscriptEntry]
    typealias DashboardVisibilityHandler = @MainActor (_ visible: Bool) -> Void
    typealias DirectiveSubmitter = @MainActor (_ submission: CoordinatorDirectiveSubmission) async -> DirectiveSubmissionResult
    typealias ChildDirectiveSubmitter = @MainActor (_ text: String, _ row: CoordinatorModeRow) async -> DirectiveSubmissionResult
    typealias ChildInteractionResponseSubmitter = @MainActor (_ submission: ChildInteractionResponseSubmission, _ row: CoordinatorModeRow) async -> DirectiveSubmissionResult
    typealias CoordinatorInteractionResponseSubmitter = @MainActor (_ submission: ChildInteractionResponseSubmission, _ coordinatorSessionID: UUID, _ interactionID: UUID) async -> DirectiveSubmissionResult
    typealias ChildInteractionResponseRecorder = @MainActor (_ text: String, _ row: CoordinatorModeRow) -> Void
    typealias ContinuationGateHandler = @MainActor (_ gate: CoordinatorContinuationGate, _ snapshotBeforeGateCleared: CoordinatorModeSnapshot) async -> Void
    typealias CoordinatorActivationHandler = @MainActor (_ sessionID: UUID) async -> Void
    typealias CoordinatorPinHandler = @MainActor (_ option: CoordinatorModeCoordinatorOption, _ isPinned: Bool) -> Void
    typealias MissionPlanUpdater = @MainActor (_ coordinatorSessionID: UUID, _ update: CoordinatorMissionPlanUpdate) throws -> Void
    typealias MissionStopper = @MainActor (_ request: CoordinatorMissionStopRequest) async -> CoordinatorMissionStopResult

    @Published private(set) var snapshot: CoordinatorModeSnapshot = .empty
    @Published private(set) var railTranscriptEntries: [CoordinatorModeRailTranscriptEntry] = []
    @Published private(set) var currentRailActivityText: String?
    @Published private(set) var composerNotice: String?
    @Published private(set) var isFreshCoordinatorRunPending = false
    @Published private(set) var usesAutoMode: Bool
    @Published var selectedMissionTemplate: CoordinatorMissionTemplate?
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
    private let childInteractionResponseSubmitter: ChildInteractionResponseSubmitter
    private let coordinatorInteractionResponseSubmitter: CoordinatorInteractionResponseSubmitter
    private let childInteractionResponseRecorder: ChildInteractionResponseRecorder
    private let continuationGateHandler: ContinuationGateHandler
    private let coordinatorActivationHandler: CoordinatorActivationHandler
    private let coordinatorPinHandler: CoordinatorPinHandler
    private let missionPlanUpdater: MissionPlanUpdater
    private let missionStopper: MissionStopper
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
        directiveSubmitter: @escaping DirectiveSubmitter = { _ in
            .rejected(message: "Coordinator composer is unavailable.")
        },
        childDirectiveSubmitter: @escaping ChildDirectiveSubmitter = { _, _ in
            .rejected(message: "Session replies are unavailable.")
        },
        childInteractionResponseSubmitter: ChildInteractionResponseSubmitter? = nil,
        coordinatorInteractionResponseSubmitter: @escaping CoordinatorInteractionResponseSubmitter = { _, _, _ in
            .rejected(message: "Coordinator replies are unavailable.")
        },
        childInteractionResponseRecorder: @escaping ChildInteractionResponseRecorder = { _, _ in },
        continuationGateHandler: @escaping ContinuationGateHandler = { _, _ in },
        coordinatorActivationHandler: @escaping CoordinatorActivationHandler = { _ in },
        coordinatorPinHandler: @escaping CoordinatorPinHandler = { _, _ in },
        missionPlanUpdater: @escaping MissionPlanUpdater = { _, _ in },
        missionStopper: @escaping MissionStopper = { request in
            CoordinatorMissionStopResult(
                requestedSessionIDs: request.sessionIDs,
                cancelledSessionIDs: [],
                skippedSessionIDs: request.sessionIDs
            )
        },
        projector: CoordinatorModeSnapshotProjector = CoordinatorModeSnapshotProjector(),
        userDefaults: UserDefaults = .standard
    ) {
        self.inputProvider = inputProvider
        self.transcriptProvider = transcriptProvider
        self.dashboardVisibilityHandler = dashboardVisibilityHandler
        self.directiveSubmitter = directiveSubmitter
        self.childDirectiveSubmitter = childDirectiveSubmitter
        self.childInteractionResponseSubmitter = childInteractionResponseSubmitter ?? { submission, row in
            await childDirectiveSubmitter(submission.fallbackText, row)
        }
        self.coordinatorInteractionResponseSubmitter = coordinatorInteractionResponseSubmitter
        self.childInteractionResponseRecorder = childInteractionResponseRecorder
        self.continuationGateHandler = continuationGateHandler
        self.coordinatorActivationHandler = coordinatorActivationHandler
        self.coordinatorPinHandler = coordinatorPinHandler
        self.missionPlanUpdater = missionPlanUpdater
        self.missionStopper = missionStopper
        self.projector = projector
        self.userDefaults = userDefaults
        usesAutoMode = CoordinatorModeAutomationPreference.isEnabled(defaults: userDefaults)
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

    func updateMissionPlan(
        coordinatorSessionID: UUID,
        update: CoordinatorMissionPlanUpdate
    ) throws {
        guard snapshot.coordinatorRail.availableCoordinators.contains(where: { $0.sessionID == coordinatorSessionID }) else {
            throw MCPError.invalidParams("Coordinator session \(coordinatorSessionID.uuidString) is not available in this window.")
        }
        try missionPlanUpdater(coordinatorSessionID, update)
        refresh()
    }

    var canStopSelectedCoordinatorMission: Bool {
        guard snapshot.coordinatorRail.state == .selected,
              snapshot.coordinatorRail.isLiveInCurrentWindow,
              snapshot.coordinatorRail.missionPlan?.status != .stopped
        else { return false }
        return !coordinatorMissionStopTargetSessionIDs().isEmpty
    }

    @discardableResult
    func stopSelectedCoordinatorMission() async -> DirectiveSubmissionResult {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else {
            let message = "No Coordinator Mission is selected."
            composerNotice = message
            return .rejected(message: message)
        }
        let targetSessionIDs = coordinatorMissionStopTargetSessionIDs()
        guard !targetSessionIDs.isEmpty else {
            let message = "No live Coordinator-linked sessions were found to stop."
            composerNotice = message
            return .rejected(message: message)
        }

        let result = await missionStopper(CoordinatorMissionStopRequest(
            coordinatorSessionID: coordinatorSessionID,
            sessionIDs: targetSessionIDs
        ))
        let message = coordinatorMissionStopMessage(result)
        composerNotice = message
        appendCoordinatorEventTranscriptEntry(message)

        if var plan = snapshot.coordinatorRail.missionPlan {
            plan.stopMission(cancelledSessionIDs: Set(result.cancelledSessionIDs))
            try? missionPlanUpdater(
                coordinatorSessionID,
                CoordinatorMissionPlanUpdate(
                    status: plan.status,
                    nodes: plan.nodes,
                    routingDecisions: plan.routingDecisions,
                    events: [
                        CoordinatorMissionPlanEvent(
                            kind: .revised,
                            timestamp: plan.updatedAt,
                            summary: message
                        )
                    ],
                    updatedAt: plan.updatedAt
                )
            )
        }
        refresh()
        return .accepted
    }

    private func coordinatorMissionStopMessage(_ result: CoordinatorMissionStopResult) -> String {
        let cancelledCount = result.cancelledSessionIDs.count
        let skippedCount = result.skippedSessionIDs.count
        let cancelledText = "\(cancelledCount) active \(cancelledCount == 1 ? "session" : "sessions")"
        guard skippedCount > 0 else {
            return "Mission stopped. Requested cancellation for \(cancelledText)."
        }
        let skippedText = "\(skippedCount) inactive or unavailable linked \(skippedCount == 1 ? "session" : "sessions")"
        return "Mission stopped. Requested cancellation for \(cancelledText); skipped \(skippedText)."
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

    func setUsesAutoMode(_ usesAutoMode: Bool) {
        guard self.usesAutoMode != usesAutoMode else { return }
        self.usesAutoMode = usesAutoMode
        CoordinatorModeAutomationPreference.setEnabled(usesAutoMode, defaults: userDefaults)
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

        let missionTemplate = forceNewRuntime ? selectedMissionTemplate : nil
        let submission = CoordinatorDirectiveSubmission(
            visibleText: trimmed,
            providerText: missionTemplate.map { $0.wrap(trimmed) } ?? trimmed,
            missionTemplate: missionTemplate.map(CoordinatorMissionTemplateSummary.init),
            coordinatorSessionID: coordinatorSessionID,
            forceNewRuntime: forceNewRuntime
        )
        let result = await directiveSubmitter(submission)
        switch result {
        case .accepted:
            isFreshCoordinatorRunPending = false
            selectedMissionTemplate = nil
            composerNotice = nil
            if forceNewRuntime {
                selectFreshCoordinatorRuntimeIfAvailable(
                    previousCoordinatorIDs: previousCoordinatorIDs,
                    workspaceID: submissionWorkspaceID
                )
            }
            refresh()
            appendUserTranscriptEntryIfMissing(submission.visibleText)
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
                missionTemplate: option.missionTemplate,
                missionPlan: option.missionPlan,
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
            missionTemplate: nil,
            missionPlan: nil,
            pendingInteraction: nil,
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

    func activePendingChildInteractionRow() -> CoordinatorModeRow? {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else { return nil }
        return snapshot.groups
            .flatMap(\.rows)
            .filter { row in
                row.parentCoordinator?.sessionID == coordinatorSessionID
                    && row.pendingInteraction != nil
                    && row.statusGroup == .needsYou
                    && !row.isPersistedOnly
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.updatedAt < rhs.updatedAt
            }
            .first
    }

    @discardableResult
    func submitPendingChildInteractionResponse(_ text: String, to row: CoordinatorModeRow) async -> DirectiveSubmissionResult {
        await submitPendingChildInteractionResponse(.text(text), to: row)
    }

    @discardableResult
    func submitPendingChildInteractionResponse(
        _ submission: ChildInteractionResponseSubmission,
        to row: CoordinatorModeRow
    ) async -> DirectiveSubmissionResult {
        let displayText = submission.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty || submission.skip || submission.hasStructuredAnswers else {
            return .rejected(message: "")
        }
        guard row.pendingInteraction != nil else {
            let message = "This child session is no longer waiting for input."
            composerNotice = message
            return .rejected(message: message)
        }
        let result = await childInteractionResponseSubmitter(submission, row)
        switch result {
        case .accepted:
            composerNotice = nil
            childInteractionResponseRecorder(displayText, row)
            appendChildInteractionResponseTranscriptEntry(row: row, text: displayText)
        case let .rejected(message):
            composerNotice = message.isEmpty ? nil : message
        }
        return result
    }

    @discardableResult
    func submitCoordinatorPendingInteractionResponse(
        _ submission: ChildInteractionResponseSubmission,
        pending: CoordinatorModePendingInteractionSummary
    ) async -> DirectiveSubmissionResult {
        let displayText = submission.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty || submission.skip || submission.hasStructuredAnswers else {
            return .rejected(message: "")
        }
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else {
            return .rejected(message: "No Coordinator mission is selected.")
        }
        let result = await coordinatorInteractionResponseSubmitter(submission, coordinatorSessionID, pending.id)
        switch result {
        case .accepted:
            composerNotice = nil
        case let .rejected(message):
            composerNotice = message.isEmpty ? nil : message
        }
        refresh()
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
            displayedDelegateActionTargetIDs.removeAll()
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

    private func appendChildInteractionResponseTranscriptEntry(row: CoordinatorModeRow, text: String) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }
        let displayText = "You answered \(row.title):\n\n\(normalizedText)"
        let alreadyVisible = railTranscriptEntries.contains { entry in
            entry.role == .event
                && entry.action == nil
                && entry.text.trimmingCharacters(in: .whitespacesAndNewlines) == displayText
        }
        guard !alreadyVisible else { return }
        railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
            id: UUID(),
            role: .event,
            text: displayText,
            createdAt: Date(),
            action: nil
        ))
    }

    private func appendCoordinatorEventTranscriptEntry(_ text: String) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }
        guard !railTranscriptEntries.contains(where: { entry in
            entry.role == .event
                && entry.action == nil
                && entry.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText
        }) else { return }
        railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
            id: UUID(),
            role: .event,
            text: normalizedText,
            createdAt: Date(),
            action: nil
        ))
    }

    private func coordinatorMissionStopTargetSessionIDs() -> [UUID] {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else { return [] }
        var ids: [UUID] = []
        func append(_ id: UUID?) {
            guard let id, !ids.contains(id) else { return }
            ids.append(id)
        }

        append(coordinatorSessionID)

        for row in snapshot.groups.flatMap(\.rows) {
            let belongsToCoordinator = row.parentCoordinator?.sessionID == coordinatorSessionID
                || row.parentSessionID == coordinatorSessionID
            guard belongsToCoordinator else { continue }
            append(row.sessionID)
            for childSessionID in row.childSessionIDs {
                append(childSessionID)
            }
        }

        if let missionPlan = snapshot.coordinatorRail.missionPlan {
            for workstream in missionPlan.workstreams {
                for sessionID in workstream.linkedSessionIDs {
                    append(sessionID)
                }
            }
            for node in missionPlan.nodes {
                append(node.boundSessionID)
            }
        }

        return ids
    }

    private func syncRailConversationTranscript(for coordinatorSessionID: UUID?) {
        let transcriptEntries = transcriptProvider(coordinatorSessionID)
        guard !transcriptEntries.isEmpty else { return }

        var mergedEntries = railTranscriptEntries.filter { entry in
            entry.role == .event || entry.action != nil
        }
        var seenIDs = Set(mergedEntries.map(\.id))
        var seenDisplayKeys = Set(mergedEntries.map(Self.displayKey(for:)))
        for entry in transcriptEntries where !seenIDs.contains(entry.id) {
            let displayKey = Self.displayKey(for: entry)
            guard !seenDisplayKeys.contains(displayKey) else { continue }
            mergedEntries.append(entry)
            seenIDs.insert(entry.id)
            seenDisplayKeys.insert(displayKey)
        }
        mergedEntries.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
        railTranscriptEntries = mergedEntries
    }

    private static func displayKey(for entry: CoordinatorModeRailTranscriptEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionKey = if let targetID = entry.action?.targetSessionID {
            "action:\(targetID.uuidString)"
        } else {
            "action:nil"
        }
        return "\(entry.role.rawValue)|\(actionKey)|\(text)"
    }

    private func updateRailActionPresentation(from snapshot: CoordinatorModeSnapshot) {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else {
            displayedDelegateActionTargetIDs.removeAll()
            return
        }

        let rows = directDelegatedRows(in: snapshot, coordinatorSessionID: coordinatorSessionID)
            .filter { !displayedDelegateActionTargetIDs.contains($0.sessionID) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.startedAt ?? lhs.updatedAt
                let rhsDate = rhs.startedAt ?? rhs.updatedAt
                if lhsDate == rhsDate {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhsDate < rhsDate
            }

        for row in rows {
            let actionCreatedAt = row.startedAt ?? row.updatedAt
            displayedDelegateActionTargetIDs.insert(row.sessionID)
            railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
                id: row.sessionID,
                role: .event,
                text: "Delegated to \(row.title)",
                createdAt: actionCreatedAt,
                action: CoordinatorModeCoordinatorAction(
                    ownerCoordinatorSessionID: coordinatorSessionID,
                    ownerTitle: snapshot.coordinatorRail.title ?? "Coordinator",
                    targetSessionID: row.sessionID,
                    targetTitle: row.title,
                    verb: .delegate,
                    phase: .resolved,
                    statusGroup: row.statusGroup,
                    workflow: row.workflow,
                    workstream: row.workstream
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
        } directiveSubmitter: { [weak self] submission in
            guard let self else {
                return .rejected(message: "Coordinator composer is unavailable.")
            }
            switch await submitCoordinatorDirectiveToAgentMode(submission) {
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
        } childInteractionResponseSubmitter: { [weak self] submission, row in
            guard let self else {
                return .rejected(message: "Session replies are unavailable.")
            }
            switch await submitChildInteractionResponseToAgentMode(submission, row: row) {
            case .submitted:
                return .accepted
            case let .blocked(message):
                return .rejected(message: message)
            }
        } coordinatorInteractionResponseSubmitter: { [weak self] submission, coordinatorSessionID, interactionID in
            guard let self else {
                return .rejected(message: "Coordinator replies are unavailable.")
            }
            switch await submitCoordinatorInteractionResponseToAgentMode(
                submission,
                coordinatorSessionID: coordinatorSessionID,
                interactionID: interactionID
            ) {
            case .submitted:
                return .accepted
            case let .blocked(message):
                return .rejected(message: message)
            }
        } childInteractionResponseRecorder: { [weak self] text, row in
            self?.rememberCoordinatorChildInteractionResponse(text, row: row)
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
        } missionPlanUpdater: { [weak self] coordinatorSessionID, update in
            guard let self else {
                throw MCPError.invalidParams("Coordinator Mission Plan state is unavailable.")
            }
            try updateCoordinatorMissionPlan(
                coordinatorSessionID: coordinatorSessionID,
                update: update
            )
        } missionStopper: { [weak self] request in
            guard let self else {
                return CoordinatorMissionStopResult(
                    requestedSessionIDs: request.sessionIDs,
                    cancelledSessionIDs: [],
                    skippedSessionIDs: request.sessionIDs
                )
            }
            return await stopCoordinatorMissionRuntime(request)
        }
    }

    @MainActor
    func coordinatorModeRailTranscriptEntries(for coordinatorSessionID: UUID?) -> [CoordinatorModeRailTranscriptEntry] {
        guard let coordinatorSessionID,
              let session = sessions.values.first(where: { session in
                  session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
              })
        else { return [] }

        var entries: [CoordinatorModeRailTranscriptEntry] = session.items.compactMap { item in
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
        let childResponseEntries = session.coordinatorFollowThroughState?.childInteractionResponses.map { record in
            CoordinatorModeRailTranscriptEntry(
                id: record.id,
                role: .event,
                text: record.transcriptText,
                createdAt: record.answeredAt,
                action: nil
            )
        } ?? []
        entries.append(contentsOf: childResponseEntries)
        entries.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
        return entries
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
        await submitCoordinatorDirectiveToAgentMode(
            CoordinatorDirectiveSubmission(
                visibleText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                providerText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                missionTemplate: nil,
                coordinatorSessionID: coordinatorSessionID,
                forceNewRuntime: forceNewRuntime
            )
        )
    }

    @MainActor
    func submitCoordinatorDirectiveToAgentMode(
        _ submission: CoordinatorDirectiveSubmission
    ) async -> UserTurnSubmissionResult {
        let runtime: (tabID: UUID, sessionID: UUID)
        do {
            runtime = try await resolveOrCreateCoordinatorRuntimeDemoTarget(
                preferredSessionID: submission.coordinatorSessionID,
                forceNewRuntime: submission.forceNewRuntime
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
        let result = await submitUserTurnCreatingSessionIfNeeded(text: submission.providerText, target: target) {
            nil
        }
        if case .submitted = result,
           !isCoordinatorFollowThroughResumeDirective(submission.providerText)
        {
            rememberCoordinatorObjective(
                submission.visibleText,
                tabID: runtime.tabID,
                missionTemplate: submission.missionTemplate
            )
            completeStateOnlyMissionPlanIfRequested(
                by: submission.visibleText,
                tabID: runtime.tabID
            )
        }
        return result
    }

    @MainActor
    private func evaluateCoordinatorFollowThrough(
        trigger: CoordinatorAutoModeBoundaryClassifier.Trigger,
        snapshot explicitSnapshot: CoordinatorModeSnapshot? = nil
    ) async {
        guard coordinatorModeViewModel.usesAutoMode else { return }
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
        trigger: CoordinatorAutoModeBoundaryClassifier.Trigger
    ) async {
        guard coordinatorModeViewModel.usesAutoMode else { return }
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
        trigger: CoordinatorAutoModeBoundaryClassifier.Trigger
    ) async {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else { return }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        guard state.originalObjectiveSummary?.isEmpty == false else { return }
        guard state.missionPlan?.status != .stopped else { return }

        let ownedRows = rows.filter { $0.parentCoordinator?.sessionID == coordinatorSessionID }
        defer {
            var latest = session.coordinatorFollowThroughState ?? state
            latest.updateObservedPhases(from: ownedRows)
            persistCoordinatorFollowThroughState(latest, tabID: tabID, session: session)
        }

        if case .gateCleared = trigger {
            let classifier = CoordinatorAutoModeBoundaryClassifier()
            let input = CoordinatorAutoModeBoundaryClassifier.Input(
                autoModeEnabled: coordinatorModeViewModel.usesAutoMode,
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
                persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
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
                    persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
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

        let classifier = CoordinatorAutoModeBoundaryClassifier()
        var input = CoordinatorAutoModeBoundaryClassifier.Input(
            autoModeEnabled: coordinatorModeViewModel.usesAutoMode,
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
                persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
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
            persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
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
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
    }

    @MainActor
    private func rememberCoordinatorChildInteractionResponse(_ text: String, row: CoordinatorModeRow) {
        guard let coordinatorID = row.parentCoordinator?.sessionID,
              let match = sessions.first(where: { _, session in
                  session.activeAgentSessionID == coordinatorID && session.isCoordinatorRuntime
              })
        else { return }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        state.rememberChildInteractionResponse(row: row, text: text)
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
    }

    @MainActor
    private func rememberCoordinatorObjective(
        _ text: String,
        tabID: UUID,
        missionTemplate: CoordinatorMissionTemplateSummary? = nil
    ) {
        guard let session = sessions[tabID], session.isCoordinatorRuntime else { return }
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        state.rememberObjective(text, missionTemplate: missionTemplate, resetMissionPlan: false)
        if let coordinatorID = session.activeAgentSessionID {
            let existingRows = coordinatorModeRows(in: coordinatorModeViewModel.snapshot)
                .filter { $0.parentCoordinator?.sessionID == coordinatorID }
            state.updateObservedPhases(from: existingRows)
        }
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
    }

    @MainActor
    private func updateCoordinatorMissionPlan(
        coordinatorSessionID: UUID,
        update: CoordinatorMissionPlanUpdate
    ) throws {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            throw MCPError.invalidParams("Coordinator session \(coordinatorSessionID.uuidString) is not live in this window.")
        }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        state.updateMissionPlan(update)
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
    }

    @MainActor
    private func stopCoordinatorMissionRuntime(
        _ request: CoordinatorMissionStopRequest
    ) async -> CoordinatorMissionStopResult {
        var cancelledSessionIDs: [UUID] = []
        var skippedSessionIDs: [UUID] = []
        for sessionID in request.sessionIDs {
            guard let match = sessions.first(where: { _, session in
                session.activeAgentSessionID == sessionID
            }) else {
                skippedSessionIDs.append(sessionID)
                continue
            }
            let tabID = match.key
            let session = match.value
            guard session.runState.isActive else {
                skippedSessionIDs.append(sessionID)
                continue
            }
            await cancelAgentRun(tabID: tabID, completion: .terminalPublished)
            cancelledSessionIDs.append(sessionID)
        }
        return CoordinatorMissionStopResult(
            requestedSessionIDs: request.sessionIDs,
            cancelledSessionIDs: cancelledSessionIDs,
            skippedSessionIDs: skippedSessionIDs
        )
    }

    @MainActor
    private func persistCoordinatorFollowThroughState(
        _ state: CoordinatorFollowThroughState,
        tabID: UUID,
        session: TabSession
    ) {
        session.coordinatorFollowThroughState = state
        session.isDirty = true
        scheduleSave(for: tabID)
    }

    private func isCoordinatorFollowThroughResumeDirective(_ text: String) -> Bool {
        text.contains("<coordinator_follow_through_resume")
    }

    @MainActor
    private func completeStateOnlyMissionPlanIfRequested(by text: String, tabID: UUID) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains("complete"),
              normalized.contains("mission plan"),
              normalized.contains("review.dependencies_satisfied is true")
        else { return }
        guard let session = sessions[tabID], session.isCoordinatorRuntime else { return }
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        guard state.completeSatisfiedCoordinatorOnlyRunningMissionPlanNodes() else { return }
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
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
        if let pendingInteraction = row.pendingInteraction {
            do {
                _ = try await mcpResolvePendingInteraction(
                    sessionID: row.sessionID,
                    interactionID: pendingInteraction.id,
                    payload: MCPInteractionResponsePayload(
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        skip: false,
                        decisionRaw: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        amendment: nil,
                        answersByQuestionID: [:],
                        elicitationActionRaw: text.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
                return .submitted
            } catch {
                return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
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
    func submitChildInteractionResponseToAgentMode(
        _ submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission,
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
        guard let pendingInteraction = row.pendingInteraction else {
            return .blocked(message: "This child session is no longer waiting for input.")
        }
        do {
            _ = try await mcpResolvePendingInteraction(
                sessionID: row.sessionID,
                interactionID: pendingInteraction.id,
                payload: MCPInteractionResponsePayload(
                    text: submission.text,
                    skip: submission.skip,
                    explicitSkip: submission.skip,
                    decisionRaw: submission.text,
                    amendment: nil,
                    answersByQuestionID: [:],
                    askUserAnswersByQuestionID: submission.answersByQuestionID,
                    hasStructuredAnswerObjects: submission.hasStructuredAnswers,
                    elicitationActionRaw: submission.text
                )
            )
            return .submitted
        } catch {
            return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    @MainActor
    func submitCoordinatorInteractionResponseToAgentMode(
        _ submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission,
        coordinatorSessionID: UUID,
        interactionID: UUID
    ) async -> UserTurnSubmissionResult {
        guard sessions.values.contains(where: { session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            return .blocked(message: "This Coordinator mission is no longer available.")
        }
        do {
            _ = try await mcpResolvePendingInteraction(
                sessionID: coordinatorSessionID,
                interactionID: interactionID,
                payload: MCPInteractionResponsePayload(
                    text: submission.text,
                    skip: submission.skip,
                    explicitSkip: submission.skip,
                    decisionRaw: submission.text,
                    amendment: nil,
                    answersByQuestionID: [:],
                    askUserAnswersByQuestionID: submission.answersByQuestionID,
                    hasStructuredAnswerObjects: submission.hasStructuredAnswers,
                    elicitationActionRaw: submission.text
                )
            )
            return .submitted
        } catch {
            return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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
                startedAt: session.lastUserMessageAt,
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
                isPinned: tab?.isPinned ?? false,
                coordinatorMissionTemplate: session.coordinatorFollowThroughState?.missionTemplate,
                coordinatorMissionPlan: session.coordinatorFollowThroughState?.missionPlan
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
