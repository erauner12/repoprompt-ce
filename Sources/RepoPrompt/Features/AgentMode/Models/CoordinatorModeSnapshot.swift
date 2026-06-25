import Foundation

struct CoordinatorModeSnapshot: Equatable {
    static let empty = CoordinatorModeSnapshot(
        workspaceID: nil,
        sortMode: .lastUpdated,
        boardScope: .coordinatorFleet,
        counts: .empty,
        groups: CoordinatorModeStatusGroup.allCases.map { CoordinatorModeStatusSection(group: $0, rows: []) },
        coordinatorRail: .empty,
        pendingInteractions: [],
        mcpAwareness: .off,
        isEmpty: true
    )

    let workspaceID: UUID?
    let sortMode: CoordinatorModeSortMode
    let boardScope: CoordinatorModeBoardScope
    let counts: CoordinatorModeCounts
    let groups: [CoordinatorModeStatusSection]
    let coordinatorRail: CoordinatorModeCoordinatorRail
    let pendingInteractions: [CoordinatorModePendingInteractionSummary]
    let mcpAwareness: CoordinatorModeMCPAwareness
    let isEmpty: Bool

    var fingerprint: CoordinatorModeSnapshotFingerprint {
        CoordinatorModeSnapshotFingerprint(snapshot: self)
    }
}

struct CoordinatorModeSnapshotFingerprint: Equatable {
    fileprivate let snapshot: CoordinatorModeSnapshot
}

enum CoordinatorModeSortMode: String, CaseIterable, Equatable {
    case lastUpdated
    case name
    case priority
}

enum CoordinatorModeBoardScope: String, CaseIterable, Equatable {
    case coordinatorFleet
    case allAgents
}

struct CoordinatorModeCounts: Equatable {
    static let empty = CoordinatorModeCounts(
        totalRows: 0,
        needsYou: 0,
        blocked: 0,
        working: 0,
        review: 0,
        done: 0,
        stalePersistedOnly: 0,
        liveRows: 0
    )

    let totalRows: Int
    let needsYou: Int
    let blocked: Int
    let working: Int
    let review: Int
    let done: Int
    let stalePersistedOnly: Int
    let liveRows: Int
}

enum CoordinatorModeStatusGroup: String, CaseIterable, Equatable {
    case needsYou
    case working
    case blocked
    case review
    case done

    var displayName: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .blocked: "Blocked"
        case .review: "Review"
        case .done: "Done"
        }
    }
}

struct CoordinatorModeStatusSection: Equatable {
    let group: CoordinatorModeStatusGroup
    let rows: [CoordinatorModeRow]
}

struct CoordinatorWorkstreamBinding: Equatable {
    let label: String
    let branch: String?
    let colorHex: String?
}

struct CoordinatorWorkstream: Identifiable, Equatable {
    enum Phase: String, Equatable {
        case delegated
        case running
        case needsUser
        case review
        case blocked
        case done
    }

    enum NextActionKind: String, Equatable {
        case waitForChild
        case respondToChild
        case inspectOutput
        case approveNextStep
        case inspectBlocker
    }

    struct NextAction: Equatable {
        let kind: NextActionKind
        let title: String
        let detail: String?
    }

    var id: UUID {
        childSessionID
    }

    let objective: String
    let phase: Phase
    let childSessionID: UUID
    let coordinatorSessionID: UUID?
    let worktree: CoordinatorWorkstreamBinding?
    let workflow: CoordinatorModeWorkflowDisplaySummary?
    let declaredWorkstream: CoordinatorMissionWorkstreamSummary?
    let nextAction: NextAction?

    init(
        objective: String,
        phase: Phase,
        childSessionID: UUID,
        coordinatorSessionID: UUID?,
        worktree: CoordinatorWorkstreamBinding?,
        workflow: CoordinatorModeWorkflowDisplaySummary?,
        declaredWorkstream: CoordinatorMissionWorkstreamSummary? = nil,
        nextAction: NextAction?
    ) {
        self.objective = objective
        self.phase = phase
        self.childSessionID = childSessionID
        self.coordinatorSessionID = coordinatorSessionID
        self.worktree = worktree
        self.workflow = workflow
        self.declaredWorkstream = declaredWorkstream
        self.nextAction = nextAction
    }
}

struct CoordinatorModeRow: Identifiable, Equatable {
    typealias Workstream = CoordinatorWorkstreamBinding
    typealias WorkstreamSummary = CoordinatorWorkstream

    struct MergeAttention: Equatable {
        let id: String
        let status: AgentSessionWorktreeMergeOperation.Status
        let conflictFileCount: Int
        let updatedAt: Date
    }

    struct ParentCoordinator: Equatable {
        let sessionID: UUID
        let title: String
        let isSelected: Bool
    }

    let id: UUID
    let sessionID: UUID
    let tabID: UUID?
    let title: String
    let providerName: String?
    let modelName: String?
    let runState: AgentSessionRunState
    let statusGroup: CoordinatorModeStatusGroup
    let parentSessionID: UUID?
    let parentCoordinator: ParentCoordinator?
    let childSessionIDs: [UUID]
    let isMCPOriginated: Bool
    let isPersistedOnly: Bool
    let isCoordinator: Bool
    let startedAt: Date?
    let updatedAt: Date
    let priority: Int?
    let workstream: Workstream?
    let workstreamSummary: WorkstreamSummary?
    let workflow: CoordinatorModeWorkflowDisplaySummary?
    let mergeAttention: MergeAttention?
    let pendingInteraction: CoordinatorModePendingInteractionSummary?
    let openAgentChatRoute: AgentSessionDeepLinkRoute?
    let statusReport: CoordinatorModeSessionStatusReport?
    let origin: CoordinatorModeRowOrigin
}

enum CoordinatorModeRowOrigin: String, Equatable {
    case coordinatorFleet
    case directAgent
}

struct CoordinatorModeWorkflowDisplaySummary: Equatable {
    let id: String
    let displayName: String
    let iconName: String
    let accentColorHex: String?

    var isOrchestrateWorkflow: Bool {
        id == AgentWorkflow.orchestrate.definition.id
    }
}

struct CoordinatorModeSessionStatusReport: Equatable {
    let status: AgentRunMCPSnapshot.Status
    let statusText: String?
    let assistantPreview: String?
    let terminalOutput: String?
    let failureReason: AgentRunMCPSnapshot.FailureReason?

    var hasDisplayableContent: Bool {
        statusText?.isEmpty == false
            || assistantPreview?.isEmpty == false
            || terminalOutput?.isEmpty == false
            || failureReason != nil
    }
}

struct CoordinatorMissionTemplateSummary: Codable, Equatable, Hashable {
    let id: String
    let displayName: String
    let iconName: String
    let accentColorHex: String?

    init(id: String, displayName: String, iconName: String, accentColorHex: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.iconName = iconName
        self.accentColorHex = accentColorHex
    }

    init(_ template: CoordinatorMissionTemplate) {
        self.init(
            id: template.id,
            displayName: template.displayName,
            iconName: template.iconName,
            accentColorHex: template.accentColorHex
        )
    }
}

struct CoordinatorMissionTemplate: Identifiable, Equatable, Hashable {
    enum Source: Equatable, Hashable {
        case builtIn(String)
        case custom(UUID)
    }

    static let scopedChange = CoordinatorMissionTemplate(
        source: .builtIn("scoped-change"),
        displayName: "Scoped Change",
        iconName: "scope",
        accentColorHex: "#0A84FF",
        tooltipText: "Wrap a new Mission in scoped Coordinator guidance",
        descriptionText: "Plan first, delegate mutable work into isolated worktrees, review results, and ask before irreversible actions.",
        template: """
        Run this as a scoped Coordinator change.

        1. Record a Mission Plan with `coordinator_chat op=mission_plan` before delegation. Use one user-level workstream unless the objective clearly needs more. Include `default_policy` and explicit `worktree_strategy` for each workstream.
        2. Decompose the user's objective into concrete DAG-lite nodes. Node titles must name user-specific deliverables or decisions, not generic phases such as "Plan", "Orchestrate", or "Review" unless this is only a smoke test.
        3. Attach workflow choices as node metadata with `workflow_name` / `workflow_id` or nested `workflow`. Include `completion_evidence` for each nontrivial node.
        4. Deeply inspect the existing code and produce a short plan before delegating.
        5. Delegate mutable work only into isolated worktrees.
        6. Keep workstreams focused on user-level outcomes, not raw session mechanics.
        7. Review delegated results, ask me before irreversible actions, then coordinate any needed fixes.

        User objective:
        $MISSION
        """
    )

    static let deepPlanOrchestrateReview = CoordinatorMissionTemplate(
        source: .builtIn("deep-plan-orchestrate-review"),
        displayName: "Deep Plan -> Orchestrate -> Review",
        iconName: "text.book.closed.fill",
        accentColorHex: "#32ADE6",
        tooltipText: "Plan deeply, then implement and review through delegated workflows",
        descriptionText: "Use Deep Plan first, pause on Needs you, then run Orchestrate and Review with explicit worktree boundaries.",
        template: """
        Run this as a staged Coordinator Mission.

        Mission Plan:
        1. Record the plan with `coordinator_chat op=mission_plan` before starting children. Include `default_policy` and `worktree_strategy` for each workstream.
        2. Decompose the user's objective into concrete deliverable nodes. Use workflow metadata for "Deep Plan", "Orchestrate", and "Review"; do not make those words the whole node title unless this is only a smoke test.
        3. Include `completion_evidence` on each nontrivial node, and make review nodes depend on the implementation or verification nodes they review.
        4. Use workstreams such as "Discovery", "Implementation", and "Quality" only when each maps to distinct user-level work.
        5. Update each workstream with `primary_session_id`, `related_session_ids`, and `worktree_strategy.worktree_id` as children are launched or bound.

        Stage 1 - Deep Plan:
        1. Start exactly one delegated child with workflow_name="Deep Plan" for the user's objective.
        2. If the Deep Plan child asks the user a question, needs approval, or reaches any Needs you state, stop and report that the child needs the user. Do not answer for the user.
        3. Wait for the Deep Plan child to finish after the user resolves any checkpoint.
        4. Summarize the resulting plan and ask me whether to proceed, revise, or stop before mutable implementation.

        Stage 2 - Orchestrate:
        1. Only after I proceed, start exactly one delegated child with workflow_name="Orchestrate".
        2. If implementation or validation may edit files, create or bind an explicit isolated child worktree before starting Orchestrate.
        3. Wait for Orchestrate to finish and capture its worktree, branch, diff summary, and validation status.

        Stage 3 - Review:
        1. Start exactly one separate delegated child with workflow_name="Review" to inspect the Orchestrate result.
        2. Bind Review to the same child worktree when Orchestrate created or used one.
        3. If Review finds must-fix issues, coordinate fixes in the same worktree and repeat Review once.
        4. Finish with a concise status summary and ask before commit, push, merge, or any irreversible action.

        User objective:
        $MISSION
        """
    )

    let source: Source
    let displayName: String
    let iconName: String
    let accentColorHex: String?
    let tooltipText: String?
    let descriptionText: String?
    let template: String

    var id: String {
        switch source {
        case let .builtIn(id):
            "builtin-\(id)"
        case let .custom(id):
            "custom-\(id.uuidString)"
        }
    }

    var isBuiltIn: Bool {
        if case .builtIn = source { true } else { false }
    }

    var isCustom: Bool {
        if case .custom = source { true } else { false }
    }

    var customID: UUID? {
        if case let .custom(id) = source { id } else { nil }
    }

    func wrap(_ text: String) -> String {
        Self.wrap(template: template, missionText: text)
    }

    static func stripYAMLFrontmatter(_ text: String) -> String {
        var body = text
        if body.hasPrefix("---") {
            let searchRange = body.index(body.startIndex, offsetBy: 3) ..< body.endIndex
            if let closingRange = body.range(of: "\n---", range: searchRange) {
                body = String(body[closingRange.upperBound...])
                    .trimmingCharacters(in: .newlines)
            }
        }
        return body
    }

    static func wrap(template: String, missionText: String) -> String {
        let mission = missionText.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = stripYAMLFrontmatter(template)
        if body.contains("$MISSION") {
            return body.replacingOccurrences(of: "$MISSION", with: mission)
        }
        if body.contains("$ARGUMENTS") {
            return body.replacingOccurrences(of: "$ARGUMENTS", with: mission)
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return mission }
        return "\(trimmedBody)\n\n\(mission)"
    }
}

struct CoordinatorModeCoordinatorRail: Equatable {
    static let empty = CoordinatorModeCoordinatorRail(
        state: .chooseCoordinator,
        coordinatorSessionID: nil,
        coordinatorTabID: nil,
        selectionSource: nil,
        title: nil,
        availableCoordinators: [],
        isLiveInCurrentWindow: false,
        isPersistedOnly: false,
        isPinned: false,
        childCounts: .empty,
        missionTemplate: nil,
        missionPlan: nil,
        openAgentChatRoute: nil,
        statusReport: nil,
        isComposerEnabled: false,
        isComposerSendEnabled: false
    )

    enum State: Equatable {
        case selected
        case chooseCoordinator
    }

    enum SelectionSource: String, Equatable {
        case userSelected
        case orchestrateWorkflow
        case mcpLineageRoot
        case demoRuntime
    }

    let state: State
    let coordinatorSessionID: UUID?
    let coordinatorTabID: UUID?
    let selectionSource: SelectionSource?
    let title: String?
    let availableCoordinators: [CoordinatorModeCoordinatorOption]
    let isLiveInCurrentWindow: Bool
    let isPersistedOnly: Bool
    let isPinned: Bool
    let childCounts: CoordinatorModeCoordinatorChildCounts
    let missionTemplate: CoordinatorMissionTemplateSummary?
    let missionPlan: CoordinatorMissionPlan?
    let openAgentChatRoute: AgentSessionDeepLinkRoute?
    let statusReport: CoordinatorModeSessionStatusReport?
    let isComposerEnabled: Bool
    let isComposerSendEnabled: Bool

    init(
        state: State,
        coordinatorSessionID: UUID?,
        coordinatorTabID: UUID?,
        selectionSource: SelectionSource?,
        title: String?,
        availableCoordinators: [CoordinatorModeCoordinatorOption],
        isLiveInCurrentWindow: Bool,
        isPersistedOnly: Bool,
        isPinned: Bool,
        childCounts: CoordinatorModeCoordinatorChildCounts,
        missionTemplate: CoordinatorMissionTemplateSummary? = nil,
        missionPlan: CoordinatorMissionPlan? = nil,
        openAgentChatRoute: AgentSessionDeepLinkRoute?,
        statusReport: CoordinatorModeSessionStatusReport?,
        isComposerEnabled: Bool,
        isComposerSendEnabled: Bool
    ) {
        self.state = state
        self.coordinatorSessionID = coordinatorSessionID
        self.coordinatorTabID = coordinatorTabID
        self.selectionSource = selectionSource
        self.title = title
        self.availableCoordinators = availableCoordinators
        self.isLiveInCurrentWindow = isLiveInCurrentWindow
        self.isPersistedOnly = isPersistedOnly
        self.isPinned = isPinned
        self.childCounts = childCounts
        self.missionTemplate = missionTemplate
        self.missionPlan = missionPlan
        self.openAgentChatRoute = openAgentChatRoute
        self.statusReport = statusReport
        self.isComposerEnabled = isComposerEnabled
        self.isComposerSendEnabled = isComposerSendEnabled
    }
}

struct CoordinatorModeCoordinatorChildCounts: Equatable {
    static let empty = CoordinatorModeCoordinatorChildCounts(total: 0, needsYou: 0, working: 0, blocked: 0, review: 0, done: 0)

    let total: Int
    let needsYou: Int
    let working: Int
    let blocked: Int
    let review: Int
    let done: Int
}

struct CoordinatorModeCoordinatorOption: Identifiable, Equatable {
    var id: UUID {
        sessionID
    }

    let sessionID: UUID
    let tabID: UUID?
    let workspaceID: UUID?
    let title: String
    let selectionSource: CoordinatorModeCoordinatorRail.SelectionSource
    let isSelected: Bool
    let isLiveInCurrentWindow: Bool
    let isPinned: Bool
    let isPersistedOnly: Bool
    let childCounts: CoordinatorModeCoordinatorChildCounts
    let missionTemplate: CoordinatorMissionTemplateSummary?
    let missionPlan: CoordinatorMissionPlan?
    let runState: AgentSessionRunState?
    let updatedAt: Date
    let lastActivityAt: Date

    init(
        sessionID: UUID,
        tabID: UUID?,
        workspaceID: UUID?,
        title: String,
        selectionSource: CoordinatorModeCoordinatorRail.SelectionSource,
        isSelected: Bool,
        isLiveInCurrentWindow: Bool,
        isPinned: Bool,
        isPersistedOnly: Bool,
        childCounts: CoordinatorModeCoordinatorChildCounts,
        missionTemplate: CoordinatorMissionTemplateSummary? = nil,
        missionPlan: CoordinatorMissionPlan? = nil,
        runState: AgentSessionRunState?,
        updatedAt: Date,
        lastActivityAt: Date
    ) {
        self.sessionID = sessionID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.title = title
        self.selectionSource = selectionSource
        self.isSelected = isSelected
        self.isLiveInCurrentWindow = isLiveInCurrentWindow
        self.isPinned = isPinned
        self.isPersistedOnly = isPersistedOnly
        self.childCounts = childCounts
        self.missionTemplate = missionTemplate
        self.missionPlan = missionPlan
        self.runState = runState
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
    }
}

struct CoordinatorModeRailTranscriptEntry: Identifiable, Equatable {
    enum Role: String, Equatable {
        case user
        case coordinator
        case event
    }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
    let action: CoordinatorModeCoordinatorAction?
    let checkpoint: CoordinatorModeConversationCheckpoint?

    init(
        id: UUID,
        role: Role,
        text: String,
        createdAt: Date,
        action: CoordinatorModeCoordinatorAction?,
        checkpoint: CoordinatorModeConversationCheckpoint? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.action = action
        self.checkpoint = checkpoint
    }
}

struct CoordinatorModeConversationCheckpoint: Equatable {
    enum Kind: String, Equatable {
        case safeContinuationReady = "safe_continuation_ready"
        case needsClarification = "needs_clarification"
        case reviewSuggested = "review_suggested"
        case reviewRequired = "review_required"
        case blocked
        case approvalRequired = "approval_required"
    }

    static let markerPrefix = "COORDINATOR_CHECKPOINT:"

    let kind: Kind

    var interactionID: UUID {
        switch kind {
        case .safeContinuationReady:
            Self.deterministicID(1)
        case .needsClarification:
            Self.deterministicID(2)
        case .reviewSuggested:
            Self.deterministicID(3)
        case .reviewRequired:
            Self.deterministicID(4)
        case .blocked:
            Self.deterministicID(5)
        case .approvalRequired:
            Self.deterministicID(6)
        }
    }

    private static func deterministicID(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0x1F, 0x7D, 0xE6, 0xE3, 0x1F, 0x56, 0x46, 0xD4, 0xA3, 0xDF, 0xBB, 0x74, 0x01, 0x95, 0xD0, suffix))
    }

    var displayName: String {
        switch kind {
        case .safeContinuationReady:
            "Ready for next step"
        case .needsClarification:
            "Needs direction"
        case .reviewSuggested:
            "Review suggested"
        case .reviewRequired:
            "Review required"
        case .blocked:
            "Blocked"
        case .approvalRequired:
            "Approval required"
        }
    }
}

enum CoordinatorModeConversationCheckpointParser {
    static func parse(_ text: String) -> (visibleText: String, checkpoint: CoordinatorModeConversationCheckpoint?) {
        var checkpoint: CoordinatorModeConversationCheckpoint?
        let visibleLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { substring -> String? in
                let line = String(substring)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix(CoordinatorModeConversationCheckpoint.markerPrefix) else {
                    return line
                }

                let rawKind = String(trimmed.dropFirst(CoordinatorModeConversationCheckpoint.markerPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let kind = CoordinatorModeConversationCheckpoint.Kind(rawValue: rawKind) {
                    checkpoint = CoordinatorModeConversationCheckpoint(kind: kind)
                }
                return nil
            }

        return (
            visibleText: visibleLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            checkpoint: checkpoint
        )
    }
}

struct CoordinatorModeCoordinatorAction: Equatable {
    enum Verb: String, Equatable {
        case delegate
        case collect
        case cancel
    }

    enum Phase: String, Equatable {
        case pending
        case resolved
        case failed
    }

    let ownerCoordinatorSessionID: UUID
    let ownerTitle: String
    let targetSessionID: UUID?
    let targetTitle: String
    let verb: Verb
    let phase: Phase
    let statusGroup: CoordinatorModeStatusGroup?
    let workflow: CoordinatorModeWorkflowDisplaySummary?
    let workstream: CoordinatorModeRow.Workstream?
}

struct CoordinatorModePendingInteractionSummary: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let kind: AgentRunMCPSnapshot.Interaction.Kind
    let responseType: AgentRunMCPSnapshot.Interaction.ResponseType
    let title: String?
    let prompt: String?
    let context: String?
    let options: [AgentRunMCPSnapshot.Interaction.Option]
    let fields: [AgentRunMCPSnapshot.Interaction.Field]
    let details: [AgentRunMCPSnapshot.Interaction.Detail]
    let openAgentChatRoute: AgentSessionDeepLinkRoute?
}

struct CoordinatorModeMCPAwareness: Equatable {
    static let off = CoordinatorModeMCPAwareness(
        state: .off,
        connectedClientCount: 0,
        idleClientCount: 0,
        activeClientCount: 0,
        inFlightToolCallCount: 0,
        recentToolCalls: []
    )

    enum State: Equatable {
        case off
        case empty
        case idle
        case active
    }

    struct RecentToolCall: Identifiable, Equatable {
        var id: String {
            "\(ordinal)-\(timestamp.timeIntervalSince1970)-\(clientName)-\(toolName)"
        }

        let ordinal: Int
        let timestamp: Date
        let toolName: String
        let clientName: String
    }

    let state: State
    let connectedClientCount: Int
    let idleClientCount: Int
    let activeClientCount: Int
    let inFlightToolCallCount: Int
    let recentToolCalls: [RecentToolCall]
}
