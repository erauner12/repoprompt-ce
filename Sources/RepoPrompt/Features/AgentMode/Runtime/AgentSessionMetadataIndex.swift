import Foundation

struct AgentSessionMetadataIndex: Codable, Equatable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var generatedAt: Date
    var lastReconciledAt: Date?
    var entries: [AgentSessionMetadataRecord]
    var quarantinedFiles: [AgentSessionMetadataQuarantineRecord]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date = Date(),
        lastReconciledAt: Date? = nil,
        entries: [AgentSessionMetadataRecord] = [],
        quarantinedFiles: [AgentSessionMetadataQuarantineRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.lastReconciledAt = lastReconciledAt
        self.entries = entries
        self.quarantinedFiles = quarantinedFiles
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case lastReconciledAt
        case entries
        case quarantinedFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? -1
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        lastReconciledAt = try container.decodeIfPresent(Date.self, forKey: .lastReconciledAt)
        entries = try container.decodeIfPresent([AgentSessionMetadataRecord].self, forKey: .entries) ?? []
        quarantinedFiles = try container.decodeIfPresent([AgentSessionMetadataQuarantineRecord].self, forKey: .quarantinedFiles) ?? []
    }
}

struct AgentSessionMetadataRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var workspaceID: UUID?
    var composeTabID: UUID?
    var name: String
    var savedAt: Date
    var lastUserMessageAt: Date?
    var itemCount: Int
    var transcriptProjectionCounts: AgentTranscriptProjectionCounts?
    var hasUnknownConversationContent: Bool
    var agentKindRaw: String?
    var agentModelRaw: String?
    var agentReasoningEffortRaw: String?
    var lastRunStateRaw: String?
    var autoEditEnabled: Bool
    var parentSessionID: UUID?
    var isMCPOriginated: Bool
    var isCoordinatorRuntime: Bool
    var coordinatorMissionTemplate: CoordinatorMissionTemplateSummary?
    var coordinatorMissionPlan: CoordinatorMissionPlan?
    var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary]
    var activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary]
    var workflowSummary: AgentSessionWorkflowSummary?
    var serializationVersion: Int?
    var observedFileSize: Int64?
    var observedFileModificationDate: Date?
    var lastIndexedAt: Date

    var activityDate: Date {
        AgentSessionRestoreSupport.sidebarActivityDate(lastUserMessageAt: lastUserMessageAt, savedAt: savedAt)
    }

    init(
        id: UUID,
        filename: String,
        workspaceID: UUID?,
        composeTabID: UUID?,
        name: String,
        savedAt: Date,
        lastUserMessageAt: Date?,
        itemCount: Int,
        transcriptProjectionCounts: AgentTranscriptProjectionCounts?,
        hasUnknownConversationContent: Bool,
        agentKindRaw: String?,
        agentModelRaw: String?,
        agentReasoningEffortRaw: String?,
        lastRunStateRaw: String?,
        autoEditEnabled: Bool,
        parentSessionID: UUID?,
        isMCPOriginated: Bool,
        isCoordinatorRuntime: Bool = false,
        coordinatorMissionTemplate: CoordinatorMissionTemplateSummary? = nil,
        coordinatorMissionPlan: CoordinatorMissionPlan? = nil,
        worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary] = [],
        activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary] = [],
        workflowSummary: AgentSessionWorkflowSummary? = nil,
        serializationVersion: Int?,
        observedFileSize: Int64?,
        observedFileModificationDate: Date?,
        lastIndexedAt: Date
    ) {
        self.id = id
        self.filename = filename
        self.workspaceID = workspaceID
        self.composeTabID = composeTabID
        self.name = name
        self.savedAt = savedAt
        self.lastUserMessageAt = lastUserMessageAt
        self.itemCount = itemCount
        self.transcriptProjectionCounts = transcriptProjectionCounts
        self.hasUnknownConversationContent = hasUnknownConversationContent
        self.agentKindRaw = agentKindRaw
        self.agentModelRaw = agentModelRaw
        self.agentReasoningEffortRaw = agentReasoningEffortRaw
        self.lastRunStateRaw = lastRunStateRaw
        self.autoEditEnabled = autoEditEnabled
        self.parentSessionID = parentSessionID
        self.isMCPOriginated = isMCPOriginated
        self.isCoordinatorRuntime = isCoordinatorRuntime
        self.coordinatorMissionTemplate = coordinatorMissionTemplate
        self.coordinatorMissionPlan = coordinatorMissionPlan
        self.worktreeBindingSummaries = worktreeBindingSummaries
        self.activeWorktreeMergeSummaries = activeWorktreeMergeSummaries
        self.workflowSummary = workflowSummary
        self.serializationVersion = serializationVersion
        self.observedFileSize = observedFileSize
        self.observedFileModificationDate = observedFileModificationDate
        self.lastIndexedAt = lastIndexedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case workspaceID
        case composeTabID
        case name
        case savedAt
        case lastUserMessageAt
        case itemCount
        case transcriptProjectionCounts
        case hasUnknownConversationContent
        case agentKindRaw
        case agentModelRaw
        case agentReasoningEffortRaw
        case lastRunStateRaw
        case autoEditEnabled
        case parentSessionID
        case isMCPOriginated
        case isCoordinatorRuntime
        case coordinatorMissionTemplate
        case coordinatorMissionPlan
        case worktreeBindingSummaries
        case activeWorktreeMergeSummaries
        case workflowSummary
        case serializationVersion
        case observedFileSize
        case observedFileModificationDate
        case lastIndexedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        composeTabID = try container.decodeIfPresent(UUID.self, forKey: .composeTabID)
        name = try container.decode(String.self, forKey: .name)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        lastUserMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        transcriptProjectionCounts = try container.decodeIfPresent(AgentTranscriptProjectionCounts.self, forKey: .transcriptProjectionCounts)
        hasUnknownConversationContent = try container.decodeIfPresent(Bool.self, forKey: .hasUnknownConversationContent) ?? false
        agentKindRaw = try container.decodeIfPresent(String.self, forKey: .agentKindRaw)
        agentModelRaw = try container.decodeIfPresent(String.self, forKey: .agentModelRaw)
        agentReasoningEffortRaw = try container.decodeIfPresent(String.self, forKey: .agentReasoningEffortRaw)
        lastRunStateRaw = try container.decodeIfPresent(String.self, forKey: .lastRunStateRaw)
        autoEditEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoEditEnabled) ?? true
        parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
        isMCPOriginated = try container.decodeIfPresent(Bool.self, forKey: .isMCPOriginated) ?? false
        isCoordinatorRuntime = try container.decodeIfPresent(Bool.self, forKey: .isCoordinatorRuntime) ?? false
        coordinatorMissionTemplate = try container.decodeIfPresent(CoordinatorMissionTemplateSummary.self, forKey: .coordinatorMissionTemplate)
        coordinatorMissionPlan = try container.decodeIfPresent(CoordinatorMissionPlan.self, forKey: .coordinatorMissionPlan)
        worktreeBindingSummaries = try container.decodeIfPresent([AgentSessionWorktreeBindingSummary].self, forKey: .worktreeBindingSummaries) ?? []
        activeWorktreeMergeSummaries = try container.decodeIfPresent([AgentSessionWorktreeMergeSummary].self, forKey: .activeWorktreeMergeSummaries) ?? []
        workflowSummary = try container.decodeIfPresent(AgentSessionWorkflowSummary.self, forKey: .workflowSummary)
        serializationVersion = try container.decodeIfPresent(Int.self, forKey: .serializationVersion)
        observedFileSize = try container.decodeIfPresent(Int64.self, forKey: .observedFileSize)
        observedFileModificationDate = try container.decodeIfPresent(Date.self, forKey: .observedFileModificationDate)
        lastIndexedAt = try container.decodeIfPresent(Date.self, forKey: .lastIndexedAt) ?? savedAt
    }

    func sidebarEntry(tabID overrideTabID: UUID? = nil, displayName: String? = nil) -> AgentSessionIndexEntry? {
        guard let tabID = overrideTabID ?? composeTabID else { return nil }
        return AgentSessionIndexEntry(
            id: id,
            tabID: tabID,
            name: AgentSessionRestoreSupport.normalizedSessionTitle(displayName ?? name),
            lastUserMessageAt: lastUserMessageAt,
            savedAt: savedAt,
            lastRunStateRaw: lastRunStateRaw,
            itemCount: itemCount,
            agentKindRaw: agentKindRaw,
            agentModelRaw: agentModelRaw,
            agentReasoningEffortRaw: agentReasoningEffortRaw,
            autoEditEnabled: autoEditEnabled,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: hasUnknownConversationContent,
            isMCPOriginated: isMCPOriginated,
            isCoordinatorRuntime: isCoordinatorRuntime,
            coordinatorMissionTemplate: coordinatorMissionTemplate,
            coordinatorMissionPlan: coordinatorMissionPlan,
            worktreeBindingSummaries: worktreeBindingSummaries,
            activeWorktreeMergeSummaries: activeWorktreeMergeSummaries,
            workflowSummary: workflowSummary
        )
    }

    func agentSessionMeta(lastModifiedOverride: Date? = nil) -> AgentSessionMeta {
        AgentSessionMeta(
            id: id,
            composeTabID: composeTabID,
            name: AgentSessionRestoreSupport.normalizedSessionTitle(name),
            lastModified: lastModifiedOverride ?? observedFileModificationDate ?? savedAt,
            itemCount: itemCount,
            agentKind: agentKindRaw,
            agentModel: agentModelRaw,
            lastRunState: lastRunStateRaw,
            parentSessionID: parentSessionID,
            isMCPOriginated: isMCPOriginated,
            isCoordinatorRuntime: isCoordinatorRuntime,
            worktreeBindingSummaries: worktreeBindingSummaries,
            activeWorktreeMergeSummaries: activeWorktreeMergeSummaries
        )
    }

    func matchesIndexedSessionMetadata(_ other: AgentSessionMetadataRecord) -> Bool {
        id == other.id
            && filename == other.filename
            && workspaceID == other.workspaceID
            && composeTabID == other.composeTabID
            && name == other.name
            && savedAt == other.savedAt
            && lastUserMessageAt == other.lastUserMessageAt
            && itemCount == other.itemCount
            && transcriptProjectionCounts == other.transcriptProjectionCounts
            && hasUnknownConversationContent == other.hasUnknownConversationContent
            && agentKindRaw == other.agentKindRaw
            && agentModelRaw == other.agentModelRaw
            && agentReasoningEffortRaw == other.agentReasoningEffortRaw
            && lastRunStateRaw == other.lastRunStateRaw
            && autoEditEnabled == other.autoEditEnabled
            && parentSessionID == other.parentSessionID
            && isMCPOriginated == other.isMCPOriginated
            && isCoordinatorRuntime == other.isCoordinatorRuntime
            && coordinatorMissionTemplate == other.coordinatorMissionTemplate
            && coordinatorMissionPlan == other.coordinatorMissionPlan
            && worktreeBindingSummaries == other.worktreeBindingSummaries
            && activeWorktreeMergeSummaries == other.activeWorktreeMergeSummaries
            && workflowSummary == other.workflowSummary
            && serializationVersion == other.serializationVersion
            && observedFileSize == other.observedFileSize
            && observedFileModificationDate == other.observedFileModificationDate
    }

    static func record(
        from session: AgentSession,
        fileURL: URL,
        observedFileSize: Int64?,
        observedFileModificationDate: Date?,
        workflowSummaryOverride: AgentSessionWorkflowSummary? = nil,
        lastIndexedAt: Date = Date()
    ) -> AgentSessionMetadataRecord {
        AgentSessionMetadataRecord(
            id: session.id,
            filename: fileURL.lastPathComponent,
            workspaceID: session.workspaceID,
            composeTabID: session.composeTabID,
            name: AgentSessionRestoreSupport.normalizedSessionTitle(session.name),
            savedAt: session.savedAt,
            lastUserMessageAt: session.lastUserMessageAt,
            itemCount: session.effectiveItemCount,
            transcriptProjectionCounts: session.transcriptProjectionCounts,
            hasUnknownConversationContent: AgentSessionRestoreSupport.hasUnknownConversationContent(in: session),
            agentKindRaw: session.agentKind,
            agentModelRaw: session.agentModel,
            agentReasoningEffortRaw: session.agentReasoningEffort,
            lastRunStateRaw: session.lastRunState,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: session.parentSessionID,
            isMCPOriginated: session.isMCPOriginated,
            isCoordinatorRuntime: session.isCoordinatorRuntime,
            coordinatorMissionTemplate: session.coordinatorFollowThroughState?.missionTemplate,
            coordinatorMissionPlan: session.coordinatorFollowThroughState?.missionPlan,
            worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
            activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries,
            workflowSummary: workflowSummaryOverride ?? latestWorkflowSummary(in: session),
            serializationVersion: session.serializationVersion,
            observedFileSize: observedFileSize,
            observedFileModificationDate: observedFileModificationDate,
            lastIndexedAt: lastIndexedAt
        )
    }

    static func latestWorkflowSummary(in session: AgentSession) -> AgentSessionWorkflowSummary? {
        if let workflow = session.items.last(where: { $0.kind == .user })?.workflow {
            return AgentSessionWorkflowSummary(workflow)
        }
        if let workflow = session.transcript?.turns.last(where: { $0.request?.workflow != nil })?.request?.workflow {
            return AgentSessionWorkflowSummary(workflow)
        }
        return nil
    }
}

struct AgentSessionMetadataQuarantineRecord: Codable, Equatable {
    var filename: String
    var observedFileSize: Int64?
    var observedFileModificationDate: Date?
    var errorDescription: String
    var lastAttemptedAt: Date
}

extension [AgentSessionMetadataRecord] {
    func sortedForAgentSessionMetadataIndex() -> [AgentSessionMetadataRecord] {
        sorted { lhs, rhs in
            if lhs.activityDate != rhs.activityDate {
                return lhs.activityDate > rhs.activityDate
            }
            if lhs.savedAt != rhs.savedAt {
                return lhs.savedAt > rhs.savedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
