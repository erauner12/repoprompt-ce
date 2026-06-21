import Foundation

struct CoordinatorModeSnapshotProjector {
    struct Input {
        var workspaceID: UUID?
        var windowID: Int?
        var persistedSessions: [PersistedSession]
        var liveSessions: [LiveSession]
        var mcpSnapshotsBySessionID: [UUID: AgentRunMCPSnapshot]
        var dashboard: MCPService.DashboardSnapshot?
        var coordinatorDetectionSessions: [CoordinatorDetectionSession]
        var selectedCoordinatorID: UUID?
        var sortMode: CoordinatorModeSortMode
        var resolvableTabIDs: Set<UUID>
        var demoCoordinatorSessionIDs: Set<UUID>
        var coordinatorInternalSessionIDs: Set<UUID>

        init(
            workspaceID: UUID?,
            windowID: Int?,
            persistedSessions: [PersistedSession] = [],
            liveSessions: [LiveSession] = [],
            mcpSnapshotsBySessionID: [UUID: AgentRunMCPSnapshot] = [:],
            dashboard: MCPService.DashboardSnapshot? = nil,
            coordinatorDetectionSessions: [CoordinatorDetectionSession] = [],
            selectedCoordinatorID: UUID? = nil,
            sortMode: CoordinatorModeSortMode = .lastUpdated,
            resolvableTabIDs: Set<UUID> = [],
            demoCoordinatorSessionIDs: Set<UUID> = [],
            coordinatorInternalSessionIDs: Set<UUID> = []
        ) {
            self.workspaceID = workspaceID
            self.windowID = windowID
            self.persistedSessions = persistedSessions
            self.liveSessions = liveSessions
            self.mcpSnapshotsBySessionID = mcpSnapshotsBySessionID
            self.dashboard = dashboard
            self.coordinatorDetectionSessions = coordinatorDetectionSessions
            self.selectedCoordinatorID = selectedCoordinatorID
            self.sortMode = sortMode
            self.resolvableTabIDs = resolvableTabIDs
            self.demoCoordinatorSessionIDs = demoCoordinatorSessionIDs
            self.coordinatorInternalSessionIDs = coordinatorInternalSessionIDs
        }
    }

    struct PersistedSession: Equatable {
        var id: UUID
        var tabID: UUID
        var title: String
        var updatedAt: Date
        var runState: AgentSessionRunState?
        var agentKind: String?
        var agentModel: String?
        var parentSessionID: UUID?
        var isMCPOriginated: Bool
        var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary]
        var activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary]
        var workflow: CoordinatorModeWorkflowDisplaySummary?
        var isCoordinatorInternal: Bool
        var priority: Int?

        init(
            id: UUID,
            tabID: UUID,
            title: String,
            updatedAt: Date,
            runState: AgentSessionRunState? = nil,
            agentKind: String? = nil,
            agentModel: String? = nil,
            parentSessionID: UUID? = nil,
            isMCPOriginated: Bool = false,
            worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary] = [],
            activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary] = [],
            workflow: CoordinatorModeWorkflowDisplaySummary? = nil,
            isCoordinatorInternal: Bool = false,
            priority: Int? = nil
        ) {
            self.id = id
            self.tabID = tabID
            self.title = title
            self.updatedAt = updatedAt
            self.runState = runState
            self.agentKind = agentKind
            self.agentModel = agentModel
            self.parentSessionID = parentSessionID
            self.isMCPOriginated = isMCPOriginated
            self.worktreeBindingSummaries = worktreeBindingSummaries
            self.activeWorktreeMergeSummaries = activeWorktreeMergeSummaries
            self.workflow = workflow
            self.isCoordinatorInternal = isCoordinatorInternal
            self.priority = priority
        }
    }

    struct LiveSession: Equatable {
        var sessionID: UUID
        var tabID: UUID
        var title: String
        var updatedAt: Date
        var runState: AgentSessionRunState
        var agentKind: String?
        var agentModel: String?
        var parentSessionID: UUID?
        var isMCPOriginated: Bool
        var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary]
        var activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary]
        var workflow: CoordinatorModeWorkflowDisplaySummary?
        var isCoordinatorInternal: Bool
        var priority: Int?

        init(
            sessionID: UUID,
            tabID: UUID,
            title: String,
            updatedAt: Date,
            runState: AgentSessionRunState,
            agentKind: String? = nil,
            agentModel: String? = nil,
            parentSessionID: UUID? = nil,
            isMCPOriginated: Bool = false,
            worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary] = [],
            activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary] = [],
            workflow: CoordinatorModeWorkflowDisplaySummary? = nil,
            isCoordinatorInternal: Bool = false,
            priority: Int? = nil
        ) {
            self.sessionID = sessionID
            self.tabID = tabID
            self.title = title
            self.updatedAt = updatedAt
            self.runState = runState
            self.agentKind = agentKind
            self.agentModel = agentModel
            self.parentSessionID = parentSessionID
            self.isMCPOriginated = isMCPOriginated
            self.worktreeBindingSummaries = worktreeBindingSummaries
            self.activeWorktreeMergeSummaries = activeWorktreeMergeSummaries
            self.workflow = workflow
            self.isCoordinatorInternal = isCoordinatorInternal
            self.priority = priority
        }
    }

    struct CoordinatorDetectionSession: Equatable {
        var id: UUID
        var title: String
        var updatedAt: Date
        var parentSessionID: UUID?
        var isMCPOriginated: Bool
        var workflow: CoordinatorModeWorkflowDisplaySummary?
        var isCoordinatorInternal: Bool

        init(
            id: UUID,
            title: String,
            updatedAt: Date,
            parentSessionID: UUID? = nil,
            isMCPOriginated: Bool = false,
            workflow: CoordinatorModeWorkflowDisplaySummary? = nil,
            isCoordinatorInternal: Bool = false
        ) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.parentSessionID = parentSessionID
            self.isMCPOriginated = isMCPOriginated
            self.workflow = workflow
            self.isCoordinatorInternal = isCoordinatorInternal
        }
    }

    func project(_ input: Input) -> CoordinatorModeSnapshot {
        let rowSeeds = mergedRowSeeds(from: input)
        let renderedChildrenByParent = childrenByParent(from: rowSeeds)
        let detectionSeeds = coordinatorDetectionSeeds(from: input, rowSeeds: rowSeeds)
        let coordinator = selectedCoordinator(from: detectionSeeds, input: input)
        let routeBuilder = RouteBuilder(
            workspaceID: input.workspaceID,
            windowID: input.windowID,
            resolvableTabIDs: input.resolvableTabIDs
        )

        let boardOwnerIDs = fleetOwnerIDs(
            childrenByParent: renderedChildrenByParent,
            demoCoordinatorSessionIDs: input.demoCoordinatorSessionIDs,
            selectedCoordinatorID: coordinator?.sessionID
        )
        let boardSeeds = delegatedFleetSeeds(
            from: rowSeeds,
            ownerIDs: boardOwnerIDs,
            demoCoordinatorSessionIDs: input.demoCoordinatorSessionIDs
        )
        let boardSeedIDs = Set(boardSeeds.map(\.id))
        let boardChildrenByParent = eligibleChildrenByParent(from: boardSeeds, visibleIDs: boardSeedIDs)
        let coordinatorTitlesByID = Dictionary(
            uniqueKeysWithValues: detectionSeeds
                .filter { input.demoCoordinatorSessionIDs.contains($0.id) }
                .map { ($0.id, $0.title) }
        )
        let boardRows = sortedRows(boardSeeds.map { seed in
            row(
                from: seed,
                childSessionIDs: Array(boardChildrenByParent[seed.id, default: []]).sorted { $0.uuidString < $1.uuidString },
                isCoordinator: false,
                parentCoordinator: parentCoordinator(
                    for: seed,
                    ownerIDs: boardOwnerIDs,
                    coordinatorTitlesByID: coordinatorTitlesByID,
                    selectedCoordinatorID: coordinator?.sessionID
                ),
                input: input,
                routeBuilder: routeBuilder
            )
        }, mode: input.sortMode)
        let allRows = sortedRows(rowSeeds.map { seed in
            row(
                from: seed,
                childSessionIDs: Array(renderedChildrenByParent[seed.id, default: []]).sorted { $0.uuidString < $1.uuidString },
                isCoordinator: seed.id == coordinator?.sessionID,
                parentCoordinator: nil,
                input: input,
                routeBuilder: routeBuilder
            )
        }, mode: input.sortMode)

        let groups = CoordinatorModeStatusGroup.allCases.map { group in
            CoordinatorModeStatusSection(group: group, rows: boardRows.filter { $0.statusGroup == group })
        }

        let rowsByID = Dictionary(uniqueKeysWithValues: allRows.map { ($0.sessionID, $0) })
        let coordinatorOptions = coordinatorOptions(
            from: detectionSeeds,
            selection: coordinator,
            rowsByID: rowsByID,
            input: input
        )
        let coordinatorRail = coordinatorRail(
            from: coordinator,
            availableCoordinators: coordinatorOptions,
            rowsByID: rowsByID
        )
        let pendingInteractions = boardRows.compactMap(\.pendingInteraction)

        return CoordinatorModeSnapshot(
            workspaceID: input.workspaceID,
            sortMode: input.sortMode,
            counts: counts(for: boardRows),
            groups: groups,
            coordinatorRail: coordinatorRail,
            pendingInteractions: pendingInteractions,
            mcpAwareness: mcpAwareness(from: input.dashboard),
            isEmpty: boardRows.isEmpty
        )
    }

    private struct RowSeed: Equatable {
        var id: UUID
        var tabID: UUID?
        var title: String
        var updatedAt: Date
        var runState: AgentSessionRunState
        var agentKind: String?
        var agentModel: String?
        var parentSessionID: UUID?
        var isMCPOriginated: Bool
        var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary]
        var activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary]
        var workflow: CoordinatorModeWorkflowDisplaySummary?
        var isCoordinatorInternal: Bool
        var priority: Int?
        var isPersistedOnly: Bool
    }

    private struct CoordinatorDetectionSeed: Equatable {
        var id: UUID
        var title: String
        var updatedAt: Date
        var parentSessionID: UUID?
        var isMCPOriginated: Bool
        var workflow: CoordinatorModeWorkflowDisplaySummary?
        var isCoordinatorInternal: Bool
    }

    private struct CoordinatorSelection: Equatable {
        var sessionID: UUID
        var source: CoordinatorModeCoordinatorRail.SelectionSource
    }

    private struct RouteBuilder {
        var workspaceID: UUID?
        var windowID: Int?
        var resolvableTabIDs: Set<UUID>

        func route(tabID: UUID?, sessionID: UUID) -> AgentSessionDeepLinkRoute? {
            guard let workspaceID, let tabID, resolvableTabIDs.contains(tabID) else { return nil }
            return AgentSessionDeepLinkRoute(windowID: windowID, workspaceID: workspaceID, tabID: tabID, sessionID: sessionID)
        }
    }

    private func mergedRowSeeds(from input: Input) -> [RowSeed] {
        var seedsByID: [UUID: RowSeed] = [:]

        for persisted in input.persistedSessions {
            seedsByID[persisted.id] = RowSeed(
                id: persisted.id,
                tabID: persisted.tabID,
                title: normalizedTitle(persisted.title),
                updatedAt: persisted.updatedAt,
                runState: persisted.runState ?? .idle,
                agentKind: persisted.agentKind,
                agentModel: persisted.agentModel,
                parentSessionID: persisted.parentSessionID,
                isMCPOriginated: persisted.isMCPOriginated,
                worktreeBindingSummaries: persisted.worktreeBindingSummaries,
                activeWorktreeMergeSummaries: persisted.activeWorktreeMergeSummaries,
                workflow: persisted.workflow,
                isCoordinatorInternal: persisted.isCoordinatorInternal || input.coordinatorInternalSessionIDs.contains(persisted.id),
                priority: persisted.priority,
                isPersistedOnly: true
            )
        }

        for live in input.liveSessions {
            let previous = seedsByID[live.sessionID]
            seedsByID[live.sessionID] = RowSeed(
                id: live.sessionID,
                tabID: live.tabID,
                title: normalizedTitle(live.title),
                updatedAt: live.updatedAt,
                runState: live.runState,
                agentKind: live.agentKind ?? previous?.agentKind,
                agentModel: live.agentModel ?? previous?.agentModel,
                parentSessionID: live.parentSessionID ?? previous?.parentSessionID,
                isMCPOriginated: live.isMCPOriginated || (previous?.isMCPOriginated ?? false),
                worktreeBindingSummaries: live.worktreeBindingSummaries.isEmpty ? previous?.worktreeBindingSummaries ?? [] : live.worktreeBindingSummaries,
                activeWorktreeMergeSummaries: live.activeWorktreeMergeSummaries.isEmpty ? previous?.activeWorktreeMergeSummaries ?? [] : live.activeWorktreeMergeSummaries,
                workflow: live.workflow,
                isCoordinatorInternal: live.isCoordinatorInternal || input.coordinatorInternalSessionIDs.contains(live.sessionID),
                priority: live.priority ?? previous?.priority,
                isPersistedOnly: false
            )
        }

        for snapshot in input.mcpSnapshotsBySessionID.values {
            let previous = seedsByID[snapshot.sessionID]
            seedsByID[snapshot.sessionID] = RowSeed(
                id: snapshot.sessionID,
                tabID: snapshot.tabID ?? previous?.tabID,
                title: normalizedTitle(snapshot.sessionName ?? previous?.title ?? "Agent Session"),
                updatedAt: max(snapshot.updatedAt, previous?.updatedAt ?? snapshot.updatedAt),
                runState: runState(from: snapshot),
                agentKind: snapshot.agentRaw ?? previous?.agentKind,
                agentModel: snapshot.modelRaw ?? previous?.agentModel,
                parentSessionID: snapshot.parentSessionID ?? previous?.parentSessionID,
                isMCPOriginated: true,
                worktreeBindingSummaries: snapshot.worktreeBindings.isEmpty
                    ? previous?.worktreeBindingSummaries ?? []
                    : snapshot.worktreeBindings.map(worktreeBindingSummary),
                activeWorktreeMergeSummaries: snapshot.activeWorktreeMerges.isEmpty
                    ? previous?.activeWorktreeMergeSummaries ?? []
                    : snapshot.activeWorktreeMerges,
                workflow: previous?.workflow,
                isCoordinatorInternal: previous?.isCoordinatorInternal ?? input.coordinatorInternalSessionIDs.contains(snapshot.sessionID),
                priority: previous?.priority,
                isPersistedOnly: false
            )
        }

        return seedsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            if lhs.title.localizedCaseInsensitiveCompare(rhs.title) != .orderedSame {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func row(
        from seed: RowSeed,
        childSessionIDs: [UUID],
        isCoordinator: Bool,
        parentCoordinator: CoordinatorModeRow.ParentCoordinator?,
        input: Input,
        routeBuilder: RouteBuilder
    ) -> CoordinatorModeRow {
        let route = routeBuilder.route(tabID: seed.tabID, sessionID: seed.id)
        let mcpSnapshot = seed.isPersistedOnly ? nil : input.mcpSnapshotsBySessionID[seed.id]
        let pendingInteraction = pendingInteractionSummary(
            snapshot: mcpSnapshot,
            route: route
        )
        return CoordinatorModeRow(
            id: seed.id,
            sessionID: seed.id,
            tabID: seed.tabID,
            title: seed.title,
            providerName: seed.agentKind,
            modelName: seed.agentModel,
            runState: seed.runState,
            statusGroup: statusGroup(for: seed),
            parentSessionID: seed.parentSessionID,
            parentCoordinator: parentCoordinator,
            childSessionIDs: childSessionIDs,
            isMCPOriginated: seed.isMCPOriginated,
            isPersistedOnly: seed.isPersistedOnly,
            isCoordinator: isCoordinator,
            updatedAt: seed.updatedAt,
            priority: seed.priority,
            workstream: workstream(from: seed.worktreeBindingSummaries.first),
            workflow: seed.workflow,
            mergeAttention: mergeAttention(from: seed.activeWorktreeMergeSummaries),
            pendingInteraction: pendingInteraction,
            openAgentChatRoute: route,
            statusReport: sessionStatusReport(snapshot: mcpSnapshot)
        )
    }

    private func runState(from snapshot: AgentRunMCPSnapshot) -> AgentSessionRunState {
        switch snapshot.status {
        case .running:
            .running
        case .waitingForInput:
            switch snapshot.interaction?.kind {
            case .some(.approval):
                .waitingForApproval
            case .some(.question), .some(.mcpElicitation):
                .waitingForQuestion
            case .some(.instruction), .some(.userInput), nil:
                .waitingForUser
            }
        case .completed:
            .completed
        case .cancelled:
            .cancelled
        case .failed, .expired:
            .failed
        }
    }

    private func worktreeBindingSummary(_ binding: AgentRunMCPSnapshot.WorktreeBinding) -> AgentSessionWorktreeBindingSummary {
        AgentSessionWorktreeBindingSummary(
            id: binding.id,
            repositoryID: binding.repositoryID,
            repoKey: binding.repoKey,
            logicalRootPath: binding.logicalRootPath,
            logicalRootName: binding.logicalRootName,
            worktreeID: binding.worktreeID,
            worktreeRootPath: binding.worktreeRootPath,
            worktreeName: binding.worktreeName,
            branch: binding.branch,
            visualLabel: binding.visualLabel,
            visualColorHex: binding.visualColorHex,
            boundAt: binding.boundAt
        )
    }

    private func statusGroup(for seed: RowSeed) -> CoordinatorModeStatusGroup {
        if !seed.isPersistedOnly, isNeedsYou(seed.runState) {
            return .needsYou
        }
        if !seed.isPersistedOnly,
           seed.runState == .failed || hasConflictedMerge(seed.activeWorktreeMergeSummaries)
        {
            return .blocked
        }
        if !seed.isPersistedOnly,
           seed.runState == .running || hasApplyingMerge(seed.activeWorktreeMergeSummaries)
        {
            return .working
        }
        if seed.runState == .completed || seed.runState == .cancelled, hasPendingReviewMerge(seed.activeWorktreeMergeSummaries) {
            return .review
        }
        return .done
    }

    private func isNeedsYou(_ state: AgentSessionRunState) -> Bool {
        switch state {
        case .waitingForUser, .waitingForQuestion, .waitingForApproval: true
        case .idle, .running, .completed, .cancelled, .failed: false
        }
    }

    private func hasConflictedMerge(_ summaries: [AgentSessionWorktreeMergeSummary]) -> Bool {
        summaries.contains { summary in
            summary.status == .conflicted || summary.conflictFileCount > 0
        }
    }

    private func hasApplyingMerge(_ summaries: [AgentSessionWorktreeMergeSummary]) -> Bool {
        summaries.contains { $0.status == .applying }
    }

    private func hasPendingReviewMerge(_ summaries: [AgentSessionWorktreeMergeSummary]) -> Bool {
        summaries.contains { summary in
            switch summary.status {
            case .previewed, .awaitingApproval, .awaitingCommit:
                true
            case .applying, .conflicted, .stale, .completed, .failed, .cancelled, .aborted:
                false
            }
        }
    }

    private func delegatedFleetSeeds(
        from seeds: [RowSeed],
        ownerIDs: [UUID: UUID],
        demoCoordinatorSessionIDs: Set<UUID>
    ) -> [RowSeed] {
        seeds.filter { seed in
            ownerIDs[seed.id] != nil
                && !demoCoordinatorSessionIDs.contains(seed.id)
                && !seed.isCoordinatorInternal
        }
    }

    private func fleetOwnerIDs(
        childrenByParent: [UUID: Set<UUID>],
        demoCoordinatorSessionIDs: Set<UUID>,
        selectedCoordinatorID: UUID?
    ) -> [UUID: UUID] {
        var ownerIDs: [UUID: UUID] = [:]
        let coordinatorIDs = demoCoordinatorSessionIDs.sorted { lhs, rhs in
            if lhs == selectedCoordinatorID { return true }
            if rhs == selectedCoordinatorID { return false }
            return lhs.uuidString < rhs.uuidString
        }
        for coordinatorID in coordinatorIDs {
            var stack = Array(childrenByParent[coordinatorID, default: []])
            while let sessionID = stack.popLast() {
                guard ownerIDs[sessionID] == nil, sessionID != coordinatorID else { continue }
                ownerIDs[sessionID] = coordinatorID
                stack.append(contentsOf: childrenByParent[sessionID, default: []])
            }
        }
        return ownerIDs
    }

    private func parentCoordinator(
        for seed: RowSeed,
        ownerIDs: [UUID: UUID],
        coordinatorTitlesByID: [UUID: String],
        selectedCoordinatorID: UUID?
    ) -> CoordinatorModeRow.ParentCoordinator? {
        guard let ownerID = ownerIDs[seed.id],
              let parentTitle = coordinatorTitlesByID[ownerID]
        else { return nil }
        return CoordinatorModeRow.ParentCoordinator(
            sessionID: ownerID,
            title: parentTitle,
            isSelected: ownerID == selectedCoordinatorID
        )
    }

    private func childrenByParent(from seeds: [RowSeed]) -> [UUID: Set<UUID>] {
        eligibleChildrenByParent(from: seeds, visibleIDs: Set(seeds.map(\.id)))
    }

    private func eligibleChildrenByParent(from seeds: [RowSeed], visibleIDs: Set<UUID>) -> [UUID: Set<UUID>] {
        var children: [UUID: Set<UUID>] = [:]
        for seed in seeds {
            guard let parentSessionID = seed.parentSessionID,
                  parentSessionID != seed.id,
                  visibleIDs.contains(parentSessionID)
            else { continue }
            children[parentSessionID, default: []].insert(seed.id)
        }
        return children
    }

    private func coordinatorDetectionSeeds(
        from input: Input,
        rowSeeds: [RowSeed]
    ) -> [CoordinatorDetectionSeed] {
        var seedsByID = Dictionary(uniqueKeysWithValues: rowSeeds.map { seed in
            (
                seed.id,
                CoordinatorDetectionSeed(
                    id: seed.id,
                    title: seed.title,
                    updatedAt: seed.updatedAt,
                    parentSessionID: seed.parentSessionID,
                    isMCPOriginated: seed.isMCPOriginated,
                    workflow: seed.workflow,
                    isCoordinatorInternal: seed.isCoordinatorInternal
                )
            )
        })

        for session in input.coordinatorDetectionSessions {
            let previous = seedsByID[session.id]
            seedsByID[session.id] = CoordinatorDetectionSeed(
                id: session.id,
                title: previous?.title ?? normalizedTitle(session.title),
                updatedAt: previous?.updatedAt ?? session.updatedAt,
                parentSessionID: session.parentSessionID ?? previous?.parentSessionID,
                isMCPOriginated: session.isMCPOriginated || (previous?.isMCPOriginated ?? false),
                workflow: session.workflow,
                isCoordinatorInternal: session.isCoordinatorInternal || (previous?.isCoordinatorInternal ?? false)
            )
        }

        return seedsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            if lhs.title.localizedCaseInsensitiveCompare(rhs.title) != .orderedSame {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func selectedCoordinator(
        from detectionSeeds: [CoordinatorDetectionSeed],
        input: Input
    ) -> CoordinatorSelection? {
        let demoCandidates = detectionSeeds.filter { input.demoCoordinatorSessionIDs.contains($0.id) }
        if let selectedCoordinatorID = input.selectedCoordinatorID,
           demoCandidates.contains(where: { $0.id == selectedCoordinatorID })
        {
            return CoordinatorSelection(sessionID: selectedCoordinatorID, source: .demoRuntime)
        }
        if let demoRuntime = mostRecentCandidate(from: demoCandidates) {
            return CoordinatorSelection(sessionID: demoRuntime.id, source: .demoRuntime)
        }

        return nil
    }

    private func mostRecentCandidate(from seeds: [CoordinatorDetectionSeed]) -> CoordinatorDetectionSeed? {
        seeds.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            if lhs.title.localizedCaseInsensitiveCompare(rhs.title) != .orderedSame {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    private func coordinatorOptions(
        from detectionSeeds: [CoordinatorDetectionSeed],
        selection: CoordinatorSelection?,
        rowsByID: [UUID: CoordinatorModeRow],
        input: Input
    ) -> [CoordinatorModeCoordinatorOption] {
        detectionSeeds
            .filter { input.demoCoordinatorSessionIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                if lhs.title.localizedCaseInsensitiveCompare(rhs.title) != .orderedSame {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { seed in
                let row = rowsByID[seed.id]
                return CoordinatorModeCoordinatorOption(
                    sessionID: seed.id,
                    title: row?.title ?? seed.title,
                    selectionSource: .demoRuntime,
                    isSelected: seed.id == selection?.sessionID,
                    isLiveInCurrentWindow: row.map { !$0.isPersistedOnly } ?? false,
                    updatedAt: row?.updatedAt ?? seed.updatedAt
                )
            }
    }

    private func coordinatorRail(
        from selection: CoordinatorSelection?,
        availableCoordinators: [CoordinatorModeCoordinatorOption],
        rowsByID: [UUID: CoordinatorModeRow]
    ) -> CoordinatorModeCoordinatorRail {
        guard let selection, let row = rowsByID[selection.sessionID] else {
            return .empty
        }
        let isLiveInCurrentWindow = !row.isPersistedOnly
        return CoordinatorModeCoordinatorRail(
            state: .selected,
            coordinatorSessionID: row.sessionID,
            selectionSource: selection.source,
            title: row.title,
            availableCoordinators: availableCoordinators,
            isLiveInCurrentWindow: isLiveInCurrentWindow,
            openAgentChatRoute: nil,
            statusReport: row.statusReport,
            isComposerEnabled: isLiveInCurrentWindow,
            isComposerSendEnabled: isLiveInCurrentWindow && !row.runState.isActive
        )
    }

    private func pendingInteractionSummary(
        snapshot: AgentRunMCPSnapshot?,
        route: AgentSessionDeepLinkRoute?
    ) -> CoordinatorModePendingInteractionSummary? {
        guard let snapshot, let interaction = snapshot.interaction else { return nil }
        return CoordinatorModePendingInteractionSummary(
            id: interaction.id,
            sessionID: snapshot.sessionID,
            kind: interaction.kind,
            title: interaction.title,
            prompt: interaction.prompt,
            details: interaction.details,
            openAgentChatRoute: route
        )
    }

    private func sessionStatusReport(snapshot: AgentRunMCPSnapshot?) -> CoordinatorModeSessionStatusReport? {
        guard let snapshot else { return nil }
        let statusText = normalizedOptionalText(snapshot.statusText)
        let assistantPreview = snapshot.status.isTerminal
            ? nil
            : normalizedOptionalText(snapshot.latestAssistantPreview)
        let terminalOutput = snapshot.status.isTerminal
            ? normalizedOptionalText(snapshot.latestAssistantPreview)
            : nil
        let report = CoordinatorModeSessionStatusReport(
            status: snapshot.status,
            statusText: statusText,
            assistantPreview: assistantPreview,
            terminalOutput: terminalOutput,
            failureReason: snapshot.failureReason
        )
        return report.hasDisplayableContent ? report : nil
    }

    private func normalizedOptionalText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func workstream(from binding: AgentSessionWorktreeBindingSummary?) -> CoordinatorModeRow.Workstream? {
        guard let binding else { return nil }
        let label = binding.visualLabel
            ?? binding.worktreeName
            ?? binding.logicalRootName
            ?? binding.branch
            ?? binding.repoKey
        return CoordinatorModeRow.Workstream(label: label, branch: binding.branch, colorHex: binding.visualColorHex)
    }

    private func mergeAttention(from summaries: [AgentSessionWorktreeMergeSummary]) -> CoordinatorModeRow.MergeAttention? {
        summaries
            .sorted { lhs, rhs in
                if lhs.status == .conflicted, rhs.status != .conflicted { return true }
                if lhs.status != .conflicted, rhs.status == .conflicted { return false }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
            .map {
                CoordinatorModeRow.MergeAttention(
                    id: $0.id,
                    status: $0.status,
                    conflictFileCount: $0.conflictFileCount,
                    updatedAt: $0.updatedAt
                )
            }
    }

    private func sortedRows(_ rows: [CoordinatorModeRow], mode: CoordinatorModeSortMode) -> [CoordinatorModeRow] {
        rows.sorted { lhs, rhs in
            switch mode {
            case .lastUpdated:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            case .name:
                let compare = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if compare != .orderedSame { return compare == .orderedAscending }
            case .priority:
                switch (lhs.priority, rhs.priority) {
                case let (lhsPriority?, rhsPriority?) where lhsPriority != rhsPriority:
                    return lhsPriority > rhsPriority
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                }
            }
            if lhs.title.localizedCaseInsensitiveCompare(rhs.title) != .orderedSame {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
    }

    private func counts(for rows: [CoordinatorModeRow]) -> CoordinatorModeCounts {
        CoordinatorModeCounts(
            totalRows: rows.count,
            needsYou: rows.count(where: { $0.statusGroup == .needsYou }),
            blocked: rows.count(where: { $0.statusGroup == .blocked }),
            working: rows.count(where: { $0.statusGroup == .working }),
            review: rows.count(where: { $0.statusGroup == .review }),
            done: rows.count(where: { $0.statusGroup == .done }),
            stalePersistedOnly: rows.filter(\.isPersistedOnly).count,
            liveRows: rows.count(where: { !$0.isPersistedOnly })
        )
    }

    private func mcpAwareness(from dashboard: MCPService.DashboardSnapshot?) -> CoordinatorModeMCPAwareness {
        guard let dashboard, dashboard.isRunning else { return .off }
        let recentCalls = recentToolCalls(from: dashboard)
        guard !dashboard.connections.isEmpty else {
            return CoordinatorModeMCPAwareness(
                state: recentCalls.isEmpty ? .empty : .idle,
                connectedClientCount: 0,
                idleClientCount: 0,
                activeClientCount: 0,
                inFlightToolCallCount: 0,
                recentToolCalls: recentCalls
            )
        }

        let activeClientCount = dashboard.connections.count(where: { $0.hasInFlightCalls || !$0.activeToolScopes.isEmpty })
        let inFlightToolCallCount = dashboard.connections.reduce(0) { total, connection in
            total + (connection.hasInFlightCalls ? 1 : 0) + connection.activeToolScopes.count
        }
        let idleClientCount = dashboard.connections.count - activeClientCount

        return CoordinatorModeMCPAwareness(
            state: activeClientCount > 0 ? .active : .idle,
            connectedClientCount: dashboard.connections.count,
            idleClientCount: idleClientCount,
            activeClientCount: activeClientCount,
            inFlightToolCallCount: inFlightToolCallCount,
            recentToolCalls: recentToolCalls(from: dashboard)
        )
    }

    private func recentToolCalls(from dashboard: MCPService.DashboardSnapshot) -> [CoordinatorModeMCPAwareness.RecentToolCall] {
        dashboard.recentToolCalls
            .sorted { lhs, rhs in lhs.timestamp > rhs.timestamp }
            .prefix(5)
            .enumerated()
            .map { index, entry in
                CoordinatorModeMCPAwareness.RecentToolCall(
                    ordinal: index,
                    timestamp: entry.timestamp,
                    toolName: entry.toolName,
                    clientName: entry.clientName
                )
            }
    }

    private func normalizedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Agent Session" : trimmed
    }
}

extension CoordinatorModeSnapshotProjector.CoordinatorDetectionSession {
    init(_ persisted: CoordinatorModeSnapshotProjector.PersistedSession) {
        self.init(
            id: persisted.id,
            title: persisted.title,
            updatedAt: persisted.updatedAt,
            parentSessionID: persisted.parentSessionID,
            isMCPOriginated: persisted.isMCPOriginated,
            workflow: persisted.workflow,
            isCoordinatorInternal: persisted.isCoordinatorInternal
        )
    }
}

extension CoordinatorModeSnapshotProjector.PersistedSession {
    init(entry: AgentSessionIndexEntry, updatedAt: Date? = nil) {
        self.init(
            id: entry.id,
            tabID: entry.tabID,
            title: entry.name,
            updatedAt: updatedAt ?? AgentSessionRestoreSupport.sidebarActivityDate(for: entry),
            runState: entry.lastRunStateRaw.flatMap(AgentSessionRunState.init(rawValue:)),
            agentKind: entry.agentKindRaw,
            agentModel: entry.agentModelRaw,
            parentSessionID: entry.parentSessionID,
            isMCPOriginated: entry.isMCPOriginated,
            worktreeBindingSummaries: entry.worktreeBindingSummaries,
            activeWorktreeMergeSummaries: entry.activeWorktreeMergeSummaries
        )
    }
}

extension CoordinatorModeWorkflowDisplaySummary {
    init(_ workflow: AgentWorkflowDefinition) {
        self.init(
            id: workflow.id,
            displayName: workflow.displayName,
            iconName: workflow.iconName,
            accentColorHex: workflow.accentColorHex
        )
    }
}
