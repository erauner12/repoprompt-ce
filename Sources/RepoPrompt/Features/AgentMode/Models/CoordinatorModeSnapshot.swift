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

struct CoordinatorModeRow: Identifiable, Equatable {
    struct Workstream: Equatable {
        let label: String
        let branch: String?
        let colorHex: String?
    }

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
    let updatedAt: Date
    let priority: Int?
    let workstream: Workstream?
    let workflow: CoordinatorModeWorkflowDisplaySummary?
    let mergeAttention: MergeAttention?
    let pendingHumanReviewID: String?
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

struct CoordinatorModeCoordinatorRail: Equatable {
    static let empty = CoordinatorModeCoordinatorRail(
        state: .chooseCoordinator,
        coordinatorSessionID: nil,
        selectionSource: nil,
        title: nil,
        availableCoordinators: [],
        isLiveInCurrentWindow: false,
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
    let selectionSource: SelectionSource?
    let title: String?
    let availableCoordinators: [CoordinatorModeCoordinatorOption]
    let isLiveInCurrentWindow: Bool
    let openAgentChatRoute: AgentSessionDeepLinkRoute?
    let statusReport: CoordinatorModeSessionStatusReport?
    let isComposerEnabled: Bool
    let isComposerSendEnabled: Bool
}

struct CoordinatorModeCoordinatorOption: Identifiable, Equatable {
    var id: UUID {
        sessionID
    }

    let sessionID: UUID
    let title: String
    let selectionSource: CoordinatorModeCoordinatorRail.SelectionSource
    let isSelected: Bool
    let isLiveInCurrentWindow: Bool
    let runState: AgentSessionRunState?
    let updatedAt: Date
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
}

struct CoordinatorModePendingInteractionSummary: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let kind: AgentRunMCPSnapshot.Interaction.Kind
    let title: String?
    let prompt: String?
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
