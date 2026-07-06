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
        decisionQueue: [],
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
    let decisionQueue: [CoordinatorModeDecisionQueueItem]
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

    static let coordinatorProtocolDetailTerms = [
        "coordinator_chat op=mission_plan",
        "worktree_strategy.base_ref",
        "routing_decisions",
        "agent_run.start",
        "agent_explore.start",
        "approval_state",
        "worktree_base_ref"
    ]

    static let scopedChange = CoordinatorMissionTemplate(
        source: .builtIn("scoped-change"),
        displayName: "Scoped Change",
        iconName: "scope",
        accentColorHex: "#0A84FF",
        tooltipText: "Wrap a new Mission in scoped Coordinator guidance",
        descriptionText: "Plan first, delegate mutable work into isolated worktrees, review results, and ask before irreversible actions.",
        template: """
        Run this as a scoped Coordinator change.

        Prefer:
        - one visible plan before delegation
        - narrow read-only discovery before edits when the implementation surface is uncertain
        - one durable primary implementation lane in an isolated worktree
        - steering the same primary lane for related follow-up work instead of spawning fresh sessions
        - concrete deliverable names instead of generic phase names
        - independent Review before handoff, usually against the same task worktree
        - a concise final summary of changes, validation, and remaining risks

        Ask before irreversible actions such as commit, push, merge, or PR creation.

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

        Preferred shape:
        - Deep Plan or grounding first when the solution needs architectural context
        - Orchestrate implementation only after the plan is grounded and approved
        - one durable primary implementation lane in an isolated worktree
        - steering the primary lane for related implementation and fix-loop work
        - focused validation before review
        - independent Review on the implementation result, usually against the same task worktree
        - one fix loop if Review finds must-fix issues
        - a concise final summary of decisions, changes, validation, and remaining risks

        Pause for user input when scope, safety, or irreversible actions need confirmation.

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
        missionSummary: nil,
        pendingInteraction: nil,
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
    let missionSummary: CoordinatorModeMissionSummary?
    let pendingInteraction: CoordinatorModePendingInteractionSummary?
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
        missionSummary: CoordinatorModeMissionSummary? = nil,
        pendingInteraction: CoordinatorModePendingInteractionSummary? = nil,
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
        self.missionSummary = missionSummary
        self.pendingInteraction = pendingInteraction
        self.openAgentChatRoute = openAgentChatRoute
        self.statusReport = statusReport
        self.isComposerEnabled = isComposerEnabled
        self.isComposerSendEnabled = isComposerSendEnabled
    }
}

struct CoordinatorModeMissionSummary: Equatable {
    struct Shape: Equatable {
        let id: String
        let displayName: String
        let reason: String?
        let namedClose: String?
    }

    struct Policy: Equatable {
        let id: String
        let name: String
        let defaultPace: CoordinatorMissionPolicyPace
        let maxConcurrent: Int
    }

    struct Decisions: Equatable {
        let userCount: Int
        let directorCount: Int
        let recentLabels: [String]
    }

    struct Evidence: Equatable {
        let meetsCount: Int
        let shortCount: Int
        let recentSummaries: [String]
    }

    let shape: Shape?
    let policy: Policy?
    let askAutonomyClasses: [String]
    let decisions: Decisions
    let evidence: Evidence
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
    let missionSummary: CoordinatorModeMissionSummary?
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
        missionSummary: CoordinatorModeMissionSummary? = nil,
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
        self.missionSummary = missionSummary
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
    let ledger: CoordinatorModeLedgerEntryPayload?

    init(
        id: UUID,
        role: Role,
        text: String,
        createdAt: Date,
        action: CoordinatorModeCoordinatorAction?,
        ledger: CoordinatorModeLedgerEntryPayload? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.action = action
        self.ledger = ledger
    }
}

enum CoordinatorModeLedgerEntryPayload: Equatable {
    case decision(CoordinatorMissionDecisionRecord)
    case evidence(CoordinatorMissionEvidenceRecord)
    case routing(CoordinatorMissionRoutingDecision)
    case planEvent(CoordinatorMissionPlanEvent)
    case grounding(policy: CoordinatorMissionPolicySnapshot?, shape: CoordinatorMissionShapeSummary?)
    case wrapUp(userCount: Int, directorCount: Int)
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

struct CoordinatorModeDecisionQueueItem: Identifiable, Equatable {
    enum Source: String, Equatable {
        case planApproval
        case followThroughBoundary
        case interaction
        case review
        case blockedUserAction
    }

    let id: UUID
    let source: Source
    let coordinatorSessionID: UUID?
    let sessionID: UUID?
    let interactionID: UUID?
    let planID: UUID?
    let planRevision: Int?
    let nodeID: UUID?
    let title: String
    let detail: String?
    let waitingSince: Date
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
