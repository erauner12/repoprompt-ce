@testable import RepoPrompt
import XCTest

final class CoordinatorModeSnapshotProjectorTests: XCTestCase {
    private let projector = CoordinatorModeSnapshotProjector()

    func testCoordinatorIdentityUsesUserSelectionBeforeHighestRankedAutomaticCandidate() {
        let workspaceID = uuid(90)
        let userSelected = uuid(1)
        let orchestrateOld = uuid(2)
        let orchestrateNew = uuid(3)
        let mcpLineage = uuid(4)
        let childA = uuid(5)
        let childB = uuid(6)
        let childC = uuid(7)

        let snapshot = projector.project(input(
            workspaceID: workspaceID,
            persisted: [
                persisted(id: userSelected, tab: uuid(101), title: "Manual", updatedAt: date(10)),
                persisted(id: orchestrateOld, tab: uuid(102), title: "Old Orchestrate", updatedAt: date(20), workflow: .orchestrate),
                persisted(id: orchestrateNew, tab: uuid(103), title: "New Orchestrate", updatedAt: date(30), workflow: .orchestrate),
                persisted(id: mcpLineage, tab: uuid(104), title: "MCP Parent", updatedAt: date(40), isMCP: true),
                persisted(id: childA, tab: uuid(105), title: "Child A", updatedAt: date(11), parent: orchestrateOld),
                persisted(id: childB, tab: uuid(106), title: "Child B", updatedAt: date(12), parent: orchestrateNew),
                persisted(id: childC, tab: uuid(107), title: "Child C", updatedAt: date(13), parent: mcpLineage)
            ],
            selectedCoordinatorID: userSelected
        ))

        XCTAssertEqual(snapshot.coordinatorRail.coordinatorSessionID, userSelected)
        XCTAssertEqual(snapshot.coordinatorRail.selectionSource, .userSelected)
    }

    func testCoordinatorIdentityChoosesMostRecentHighestPrecedenceCandidateAndIgnoresPlainLineage() {
        let orchestrateOld = uuid(1)
        let orchestrateNew = uuid(2)
        let mcpLineage = uuid(3)
        let plainParent = uuid(4)

        let snapshot = projector.project(input(persisted: [
            persisted(id: orchestrateOld, tab: uuid(101), title: "Old Orchestrate", updatedAt: date(10), workflow: .orchestrate),
            persisted(id: orchestrateNew, tab: uuid(102), title: "New Orchestrate", updatedAt: date(20), workflow: .orchestrate),
            persisted(id: mcpLineage, tab: uuid(103), title: "MCP Parent", updatedAt: date(30), isMCP: true),
            persisted(id: plainParent, tab: uuid(104), title: "Plain Parent", updatedAt: date(40)),
            persisted(id: uuid(5), tab: uuid(105), title: "Old Child", updatedAt: date(11), parent: orchestrateOld),
            persisted(id: uuid(6), tab: uuid(106), title: "New Child", updatedAt: date(12), parent: orchestrateNew),
            persisted(id: uuid(7), tab: uuid(107), title: "MCP Child", updatedAt: date(13), parent: mcpLineage),
            persisted(id: uuid(8), tab: uuid(108), title: "Plain Child", updatedAt: date(14), parent: plainParent)
        ]))

        XCTAssertEqual(snapshot.coordinatorRail.coordinatorSessionID, orchestrateNew)
        XCTAssertEqual(snapshot.coordinatorRail.selectionSource, .orchestrateWorkflow)
    }

    func testCoordinatorIdentityFallsBackToMCPLineageAndRendersChooseStateWhenAbsent() {
        let mcpLineage = uuid(1)
        let mcpSnapshot = projector.project(input(persisted: [
            persisted(id: mcpLineage, tab: uuid(101), title: "MCP Parent", updatedAt: date(10), isMCP: true),
            persisted(id: uuid(2), tab: uuid(102), title: "Child", updatedAt: date(11), parent: mcpLineage)
        ]))
        XCTAssertEqual(mcpSnapshot.coordinatorRail.coordinatorSessionID, mcpLineage)
        XCTAssertEqual(mcpSnapshot.coordinatorRail.selectionSource, .mcpLineageRoot)

        let plainSnapshot = projector.project(input(persisted: [
            persisted(id: uuid(3), tab: uuid(103), title: "Plain Parent", updatedAt: date(10)),
            persisted(id: uuid(4), tab: uuid(104), title: "Plain Child", updatedAt: date(11), parent: uuid(3))
        ]))
        XCTAssertEqual(plainSnapshot.coordinatorRail.state, .chooseCoordinator)
        XCTAssertNil(plainSnapshot.coordinatorRail.coordinatorSessionID)
    }

    func testComposerAvailabilityRequiresLiveCurrentWindowCoordinator() {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let coordinatorTab = uuid(101)
        let childTab = uuid(102)

        let liveSnapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: coordinatorTab, title: "Coordinator", updatedAt: date(10), isMCP: true),
                persisted(id: childID, tab: childTab, title: "Child", updatedAt: date(9), parent: coordinatorID)
            ],
            live: [
                live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator", updatedAt: date(11), state: .idle, isMCP: true)
            ]
        ))

        XCTAssertEqual(liveSnapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
        XCTAssertTrue(liveSnapshot.coordinatorRail.isLiveInCurrentWindow)
        XCTAssertTrue(liveSnapshot.coordinatorRail.isComposerEnabled)
        XCTAssertTrue(liveSnapshot.coordinatorRail.isComposerSendEnabled)

        let runningSnapshot = projector.project(input(
            persisted: [
                persisted(id: coordinatorID, tab: coordinatorTab, title: "Coordinator", updatedAt: date(10), isMCP: true),
                persisted(id: childID, tab: childTab, title: "Child", updatedAt: date(9), parent: coordinatorID)
            ],
            live: [
                live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator", updatedAt: date(12), state: .running, isMCP: true)
            ]
        ))
        XCTAssertTrue(runningSnapshot.coordinatorRail.isComposerEnabled)
        XCTAssertFalse(runningSnapshot.coordinatorRail.isComposerSendEnabled)

        let persistedOnlySnapshot = projector.project(input(persisted: [
            persisted(id: coordinatorID, tab: coordinatorTab, title: "Coordinator", updatedAt: date(10), isMCP: true),
            persisted(id: childID, tab: childTab, title: "Child", updatedAt: date(9), parent: coordinatorID)
        ]))

        XCTAssertEqual(persistedOnlySnapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
        XCTAssertFalse(persistedOnlySnapshot.coordinatorRail.isLiveInCurrentWindow)
        XCTAssertFalse(persistedOnlySnapshot.coordinatorRail.isComposerEnabled)
        XCTAssertFalse(persistedOnlySnapshot.coordinatorRail.isComposerSendEnabled)
        XCTAssertNotNil(persistedOnlySnapshot.coordinatorRail.openAgentChatRoute)
    }

    func testComposerFallbackWhenCoordinatorIsUnreachable() {
        let snapshot = projector.project(input(persisted: [
            persisted(id: uuid(1), tab: uuid(101), title: "Plain Parent", updatedAt: date(10)),
            persisted(id: uuid(2), tab: uuid(102), title: "Plain Child", updatedAt: date(9), parent: uuid(1))
        ]))

        XCTAssertEqual(snapshot.coordinatorRail.state, .chooseCoordinator)
        XCTAssertNil(snapshot.coordinatorRail.coordinatorSessionID)
        XCTAssertFalse(snapshot.coordinatorRail.isComposerEnabled)
        XCTAssertFalse(snapshot.coordinatorRail.isComposerSendEnabled)
        XCTAssertNil(snapshot.coordinatorRail.openAgentChatRoute)
    }

    func testGroupingCountsAndStaleActiveStatesDoNotCountAsLiveAttention() {
        let liveNeeds = live(id: uuid(1), tab: uuid(101), title: "Live Needs", updatedAt: date(50), state: .waitingForApproval)
        let liveWorking = live(id: uuid(2), tab: uuid(102), title: "Live Working", updatedAt: date(40), state: .running)
        let staleWaiting = persisted(id: uuid(3), tab: uuid(103), title: "Stale Waiting", updatedAt: date(30), state: .waitingForUser)
        let staleRunning = persisted(id: uuid(4), tab: uuid(104), title: "Stale Running", updatedAt: date(20), state: .running)
        let failed = persisted(id: uuid(5), tab: uuid(105), title: "Failed", updatedAt: date(10), state: .failed)
        let staleConflicted = persisted(
            id: uuid(6),
            tab: uuid(106),
            title: "Stale Conflict",
            updatedAt: date(8),
            merges: [mergeSummary(id: "stale-conflict", status: .conflicted, conflicts: 1, updatedAt: date(8))]
        )
        let completed = persisted(id: uuid(7), tab: uuid(107), title: "Done", updatedAt: date(5), state: .completed)

        let snapshot = projector.project(input(
            persisted: [staleWaiting, staleRunning, failed, staleConflicted, completed],
            live: [liveNeeds, liveWorking]
        ))

        XCTAssertEqual(snapshot.counts.totalRows, 7)
        XCTAssertEqual(snapshot.counts.liveRows, 2)
        XCTAssertEqual(snapshot.counts.needsYou, 1)
        XCTAssertEqual(snapshot.counts.working, 1)
        XCTAssertEqual(snapshot.counts.blocked, 0)
        XCTAssertEqual(snapshot.counts.stalePersistedOnly, 5)
        XCTAssertEqual(rows(in: snapshot, group: .needsYou).map(\.sessionID), [liveNeeds.sessionID])
        XCTAssertEqual(rows(in: snapshot, group: .working).map(\.sessionID), [liveWorking.sessionID])
        XCTAssertEqual(Set(rows(in: snapshot, group: .idle).map(\.sessionID)), [staleWaiting.id, staleRunning.id, failed.id, staleConflicted.id])
        XCTAssertEqual(rows(in: snapshot, group: .idle).first { $0.sessionID == staleConflicted.id }?.mergeAttention?.status, .conflicted)
        XCTAssertTrue(rows(in: snapshot, group: .blocked).isEmpty)
        XCTAssertEqual(rows(in: snapshot, group: .done).map(\.sessionID), [completed.id])
    }

    func testConflictedWorktreeMergeForcesBlockedAndProjectsMergeAttention() {
        let sessionID = uuid(1)
        let merge = mergeSummary(id: "merge-conflict", status: .conflicted, conflicts: 2, updatedAt: date(90))
        let conflicted = live(
            id: sessionID,
            tab: uuid(101),
            title: "Merge conflict",
            updatedAt: date(10),
            state: .idle,
            merges: [merge]
        )

        let snapshot = projector.project(input(live: [conflicted]))
        let row = rows(in: snapshot, group: .blocked).first

        XCTAssertEqual(snapshot.counts.blocked, 1)
        XCTAssertEqual(row?.sessionID, sessionID)
        XCTAssertEqual(row?.runState, .idle)
        XCTAssertEqual(row?.mergeAttention?.id, merge.id)
        XCTAssertEqual(row?.mergeAttention?.status, .conflicted)
        XCTAssertEqual(row?.mergeAttention?.conflictFileCount, 2)
    }

    func testCoordinatorDetectionUsesOffWindowPersistedMetadataWithoutRenderingChildren() {
        let coordinatorID = uuid(1)
        let offWindowChildID = uuid(2)
        let coordinator = live(
            id: coordinatorID,
            tab: uuid(101),
            title: "Coordinator",
            updatedAt: date(10),
            state: .idle,
            workflow: .orchestrate
        )

        let snapshot = projector.project(input(
            live: [coordinator],
            detection: [
                detection(id: coordinatorID, title: "Coordinator", updatedAt: date(10), workflow: .orchestrate),
                detection(id: offWindowChildID, title: "Off-window child", updatedAt: date(9), parent: coordinatorID)
            ]
        ))

        XCTAssertEqual(snapshot.coordinatorRail.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(snapshot.coordinatorRail.selectionSource, .orchestrateWorkflow)
        XCTAssertEqual(allRows(in: snapshot).map(\.sessionID), [coordinatorID])
        XCTAssertEqual(allRows(in: snapshot).first?.childSessionIDs, [])
    }

    func testSortingReordersOnlyWithinStatusGroups() {
        let lowPriorityRecent = live(id: uuid(1), tab: uuid(101), title: "Beta", updatedAt: date(30), state: .running, priority: 1)
        let highPriorityOld = live(id: uuid(2), tab: uuid(102), title: "Alpha", updatedAt: date(10), state: .running, priority: 10)
        let needsYou = live(id: uuid(3), tab: uuid(103), title: "Needs", updatedAt: date(20), state: .waitingForUser, priority: 100)

        let prioritySorted = projector.project(input(
            live: [lowPriorityRecent, highPriorityOld, needsYou],
            sort: .priority
        ))
        XCTAssertEqual(rows(in: prioritySorted, group: .working).map(\.sessionID), [highPriorityOld.sessionID, lowPriorityRecent.sessionID])
        XCTAssertEqual(rows(in: prioritySorted, group: .needsYou).map(\.sessionID), [needsYou.sessionID])

        let nameSorted = projector.project(input(
            live: [lowPriorityRecent, highPriorityOld, needsYou],
            sort: .name
        ))
        XCTAssertEqual(rows(in: nameSorted, group: .working).map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(rows(in: nameSorted, group: .needsYou).map(\.title), ["Needs"])
    }

    func testPrioritySortSinksNilPriorityAndBreaksTiesByRecencyThenTitle() {
        let nilPriorityRecent = live(id: uuid(1), tab: uuid(101), title: "Nil", updatedAt: date(100), state: .running)
        let priorityRecent = live(id: uuid(2), tab: uuid(102), title: "Zulu", updatedAt: date(30), state: .running, priority: 5)
        let priorityTitleBeta = live(id: uuid(3), tab: uuid(103), title: "Beta", updatedAt: date(20), state: .running, priority: 5)
        let priorityTitleAlpha = live(id: uuid(4), tab: uuid(104), title: "Alpha", updatedAt: date(20), state: .running, priority: 5)
        let lowerPriority = live(id: uuid(5), tab: uuid(105), title: "Lower", updatedAt: date(200), state: .running, priority: 1)

        let snapshot = projector.project(input(
            live: [nilPriorityRecent, priorityTitleBeta, lowerPriority, priorityRecent, priorityTitleAlpha],
            sort: .priority
        ))

        XCTAssertEqual(rows(in: snapshot, group: .working).map(\.sessionID), [
            priorityRecent.sessionID,
            priorityTitleAlpha.sessionID,
            priorityTitleBeta.sessionID,
            lowerPriority.sessionID,
            nilPriorityRecent.sessionID
        ])
    }

    func testWorkstreamLabelFallbackOrder() {
        let rows = allRows(in: projector.project(input(live: [
            live(id: uuid(1), tab: uuid(101), title: "Visual", updatedAt: date(50), state: .idle, bindings: [binding(visualLabel: "Visual", worktreeName: "Worktree", logicalRootName: "Root", branch: "branch", repoKey: "repo")]),
            live(id: uuid(2), tab: uuid(102), title: "Worktree", updatedAt: date(40), state: .idle, bindings: [binding(visualLabel: nil, worktreeName: "Worktree", logicalRootName: "Root", branch: "branch", repoKey: "repo")]),
            live(id: uuid(3), tab: uuid(103), title: "Root", updatedAt: date(30), state: .idle, bindings: [binding(visualLabel: nil, worktreeName: nil, logicalRootName: "Root", branch: "branch", repoKey: "repo")]),
            live(id: uuid(4), tab: uuid(104), title: "Branch", updatedAt: date(20), state: .idle, bindings: [binding(visualLabel: nil, worktreeName: nil, logicalRootName: nil, branch: "branch", repoKey: "repo")]),
            live(id: uuid(5), tab: uuid(105), title: "Repo", updatedAt: date(10), state: .idle, bindings: [binding(visualLabel: nil, worktreeName: nil, logicalRootName: nil, branch: nil, repoKey: "repo")])
        ])))

        XCTAssertEqual(rows.map { $0.workstream?.label }, ["Visual", "Worktree", "Root", "branch", "repo"])
    }

    func testPendingInteractionProjectsStructuredMCPDataAndNullableRouteOnly() {
        let sessionID = uuid(1)
        let tabID = uuid(101)
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: uuid(200),
            kind: .approval,
            responseType: .decision,
            title: "Approve edit?",
            prompt: "Allow apply_edits?",
            context: nil,
            allowsMultiple: nil,
            options: [],
            fields: [],
            details: [AgentRunMCPSnapshot.Interaction.Detail(label: "File", value: "Sources/App.swift", isCode: true)]
        )
        let snapshot = projector.project(input(
            live: [live(id: sessionID, tab: tabID, title: "Needs", updatedAt: date(10), state: .waitingForApproval)],
            mcpSnapshots: [sessionID: mcpSnapshot(sessionID: sessionID, tabID: tabID, interaction: interaction)],
            resolvableTabs: [tabID]
        ))

        let summary = snapshot.pendingInteractions.first
        XCTAssertEqual(summary?.id, interaction.id)
        XCTAssertEqual(summary?.kind, .approval)
        XCTAssertEqual(summary?.title, "Approve edit?")
        XCTAssertEqual(summary?.prompt, "Allow apply_edits?")
        XCTAssertEqual(summary?.details.first?.label, "File")
        XCTAssertNotNil(summary?.openAgentChatRoute)

        let missingRouteSnapshot = projector.project(input(
            live: [live(id: sessionID, tab: tabID, title: "Needs", updatedAt: date(10), state: .waitingForApproval)],
            mcpSnapshots: [sessionID: mcpSnapshot(sessionID: sessionID, tabID: tabID, interaction: interaction)],
            resolvableTabs: []
        ))
        XCTAssertNil(missingRouteSnapshot.pendingInteractions.first?.openAgentChatRoute)
    }

    func testPersistedOnlyRowDoesNotProjectPendingInteraction() {
        let sessionID = uuid(1)
        let tabID = uuid(101)
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: uuid(200),
            kind: .question,
            responseType: .text,
            title: "Need answer",
            prompt: "Continue?",
            context: nil,
            allowsMultiple: nil,
            options: [],
            fields: [],
            details: []
        )
        let snapshot = projector.project(input(
            persisted: [persisted(id: sessionID, tab: tabID, title: "Stale", updatedAt: date(10), state: .waitingForQuestion)],
            mcpSnapshots: [sessionID: mcpSnapshot(sessionID: sessionID, tabID: tabID, interaction: interaction)],
            resolvableTabs: [tabID]
        ))
        let row = allRows(in: snapshot).first

        XCTAssertTrue(snapshot.pendingInteractions.isEmpty)
        XCTAssertNil(row?.pendingInteraction)
        XCTAssertEqual(row?.statusGroup, .idle)
    }

    func testAssistantProseAndStreamingTextDoNotCreatePendingOrChangeFingerprint() {
        let sessionID = uuid(1)
        let tabID = uuid(101)
        let liveSession = live(id: sessionID, tab: tabID, title: "Mentions decision", updatedAt: date(10), state: .running)
        let first = projector.project(input(
            live: [liveSession],
            mcpSnapshots: [sessionID: mcpSnapshot(sessionID: sessionID, tabID: tabID, assistantPreview: "Please decide yes or no", interaction: nil)]
        ))
        let second = projector.project(input(
            live: [liveSession],
            mcpSnapshots: [sessionID: mcpSnapshot(sessionID: sessionID, tabID: tabID, assistantPreview: "Please decide yes or no. More streamed text.", interaction: nil)]
        ))

        XCTAssertTrue(first.pendingInteractions.isEmpty)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testPersistedOnlyRowsWithoutResolvableTabsDoNotCreateRoutes() {
        let sessionID = uuid(1)
        let tabID = uuid(101)
        let snapshot = projector.project(input(
            persisted: [persisted(id: sessionID, tab: tabID, title: "Archived", updatedAt: date(10), state: .running)],
            resolvableTabs: []
        ))

        let row = allRows(in: snapshot).first
        XCTAssertEqual(row?.sessionID, sessionID)
        XCTAssertEqual(row?.isPersistedOnly, true)
        XCTAssertNil(row?.openAgentChatRoute)
        XCTAssertEqual(row?.statusGroup, .idle)
    }

    func testMCPCompactProjectionCoversOffEmptyIdleAndActiveStates() {
        let off = projector.project(input(dashboard: dashboard(isRunning: false)))
        XCTAssertEqual(off.mcpAwareness.state, .off)

        let empty = projector.project(input(dashboard: dashboard(isRunning: true)))
        XCTAssertEqual(empty.mcpAwareness.state, .empty)
        XCTAssertEqual(empty.mcpAwareness.connectedClientCount, 0)
        XCTAssertTrue(empty.mcpAwareness.recentToolCalls.isEmpty)

        let historyOnly = projector.project(input(dashboard: dashboard(
            isRunning: true,
            recentToolCalls: [toolCall(name: "list_agents", client: "Codex", at: date(9))]
        )))
        XCTAssertEqual(historyOnly.mcpAwareness.state, .idle)
        XCTAssertEqual(historyOnly.mcpAwareness.connectedClientCount, 0)
        XCTAssertEqual(historyOnly.mcpAwareness.inFlightToolCallCount, 0)
        XCTAssertEqual(historyOnly.mcpAwareness.recentToolCalls.first?.toolName, "list_agents")

        let idle = projector.project(input(dashboard: dashboard(
            isRunning: true,
            connections: [connection(name: "Claude")],
            recentToolCalls: [toolCall(name: "read_file", client: "Claude", at: date(10))]
        )))
        XCTAssertEqual(idle.mcpAwareness.state, .idle)
        XCTAssertEqual(idle.mcpAwareness.connectedClientCount, 1)
        XCTAssertEqual(idle.mcpAwareness.idleClientCount, 1)
        XCTAssertEqual(idle.mcpAwareness.recentToolCalls.first?.toolName, "read_file")

        let active = projector.project(input(dashboard: dashboard(
            isRunning: true,
            connections: [connection(name: "Codex", inFlight: true, scopes: [ConnectionDashboardActiveToolScope(windowID: 7, toolName: "apply_edits", sequence: 1)])]
        )))
        XCTAssertEqual(active.mcpAwareness.state, .active)
        XCTAssertEqual(active.mcpAwareness.activeClientCount, 1)
        XCTAssertEqual(active.mcpAwareness.inFlightToolCallCount, 2)
    }

    private func input(
        workspaceID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000090"),
        persisted: [CoordinatorModeSnapshotProjector.PersistedSession] = [],
        live: [CoordinatorModeSnapshotProjector.LiveSession] = [],
        mcpSnapshots: [UUID: AgentRunMCPSnapshot] = [:],
        dashboard: MCPService.DashboardSnapshot? = nil,
        detection: [CoordinatorModeSnapshotProjector.CoordinatorDetectionSession] = [],
        selectedCoordinatorID: UUID? = nil,
        sort: CoordinatorModeSortMode = .lastUpdated,
        resolvableTabs: Set<UUID>? = nil
    ) -> CoordinatorModeSnapshotProjector.Input {
        let tabs = resolvableTabs ?? Set(persisted.map(\.tabID) + live.map(\.tabID))
        return CoordinatorModeSnapshotProjector.Input(
            workspaceID: workspaceID,
            windowID: 7,
            persistedSessions: persisted,
            liveSessions: live,
            mcpSnapshotsBySessionID: mcpSnapshots,
            dashboard: dashboard,
            coordinatorDetectionSessions: detection,
            selectedCoordinatorID: selectedCoordinatorID,
            sortMode: sort,
            resolvableTabIDs: tabs
        )
    }

    private func persisted(
        id: UUID,
        tab: UUID,
        title: String,
        updatedAt: Date,
        state: AgentSessionRunState? = .idle,
        parent: UUID? = nil,
        isMCP: Bool = false,
        workflow: CoordinatorModeSnapshotProjector.WorkflowKind? = nil,
        priority: Int? = nil,
        bindings: [AgentSessionWorktreeBindingSummary] = [],
        merges: [AgentSessionWorktreeMergeSummary] = []
    ) -> CoordinatorModeSnapshotProjector.PersistedSession {
        CoordinatorModeSnapshotProjector.PersistedSession(
            id: id,
            tabID: tab,
            title: title,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP,
            worktreeBindingSummaries: bindings,
            activeWorktreeMergeSummaries: merges,
            workflowKind: workflow,
            priority: priority
        )
    }

    private func live(
        id: UUID,
        tab: UUID,
        title: String,
        updatedAt: Date,
        state: AgentSessionRunState,
        parent: UUID? = nil,
        isMCP: Bool = false,
        workflow: CoordinatorModeSnapshotProjector.WorkflowKind? = nil,
        priority: Int? = nil,
        bindings: [AgentSessionWorktreeBindingSummary] = [],
        merges: [AgentSessionWorktreeMergeSummary] = []
    ) -> CoordinatorModeSnapshotProjector.LiveSession {
        CoordinatorModeSnapshotProjector.LiveSession(
            sessionID: id,
            tabID: tab,
            title: title,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP,
            worktreeBindingSummaries: bindings,
            activeWorktreeMergeSummaries: merges,
            workflowKind: workflow,
            priority: priority
        )
    }

    private func detection(
        id: UUID,
        title: String,
        updatedAt: Date,
        parent: UUID? = nil,
        isMCP: Bool = false,
        workflow: CoordinatorModeSnapshotProjector.WorkflowKind? = nil
    ) -> CoordinatorModeSnapshotProjector.CoordinatorDetectionSession {
        CoordinatorModeSnapshotProjector.CoordinatorDetectionSession(
            id: id,
            title: title,
            updatedAt: updatedAt,
            parentSessionID: parent,
            isMCPOriginated: isMCP,
            workflowKind: workflow
        )
    }

    private func binding(
        visualLabel: String? = "Visual",
        worktreeName: String? = "Worktree",
        logicalRootName: String? = "Root",
        branch: String? = "main",
        repoKey: String = "repo"
    ) -> AgentSessionWorktreeBindingSummary {
        AgentSessionWorktreeBindingSummary(
            id: UUID().uuidString,
            repositoryID: "repo-id",
            repoKey: repoKey,
            logicalRootPath: "/tmp/Repo",
            logicalRootName: logicalRootName,
            worktreeID: "wt-id",
            worktreeRootPath: "/tmp/Repo-wt",
            worktreeName: worktreeName,
            branch: branch,
            visualLabel: visualLabel,
            visualColorHex: "#abcdef",
            boundAt: date(0)
        )
    }

    private func mergeSummary(
        id: String,
        status: AgentSessionWorktreeMergeOperation.Status,
        conflicts: Int,
        updatedAt: Date
    ) -> AgentSessionWorktreeMergeSummary {
        AgentSessionWorktreeMergeSummary(
            id: id,
            status: status,
            sourceWorktreeID: "source",
            sourceLabel: "Source",
            sourceBranch: "feature",
            sourcePath: "/tmp/source",
            targetWorktreeID: "target",
            targetLabel: "Target",
            targetBranch: "main",
            targetPath: "/tmp/target",
            repositoryID: "repo-id",
            repoKey: "repo",
            conflictFileCount: conflicts,
            updatedAt: updatedAt
        )
    }

    private func mcpSnapshot(
        sessionID: UUID,
        tabID: UUID,
        assistantPreview: String? = nil,
        interaction: AgentRunMCPSnapshot.Interaction?
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: tabID,
            sessionName: "Session",
            agentRaw: nil,
            agentDisplayName: nil,
            modelRaw: nil,
            reasoningEffortRaw: nil,
            status: .running,
            statusText: nil,
            latestAssistantPreview: assistantPreview,
            interaction: interaction,
            transcriptItemCount: 10,
            updatedAt: date(20),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }

    private func dashboard(
        isRunning: Bool,
        connections: [MCPService.DashboardConnection] = [],
        recentToolCalls: [MCPService.ToolCallHistoryEntry] = []
    ) -> MCPService.DashboardSnapshot {
        MCPService.DashboardSnapshot(
            isRunning: isRunning,
            diagnostics: MCPDiagnostics(),
            connections: connections,
            recentToolCalls: recentToolCalls,
            alwaysAllowedClients: [],
            autoApproveAllClients: false
        )
    }

    private func connection(
        name: String,
        inFlight: Bool = false,
        scopes: [ConnectionDashboardActiveToolScope] = []
    ) -> MCPService.DashboardConnection {
        MCPService.DashboardConnection(
            id: UUID(),
            clientName: name,
            windowID: 7,
            transport: .filesystem,
            state: .ready,
            createdAt: date(0),
            lastToolCallAt: nil,
            totalToolCalls: 0,
            idleSeconds: inFlight ? nil : 5,
            hasInFlightCalls: inFlight,
            activeToolScope: scopes.first,
            activeToolScopes: scopes,
            sessionKey: nil
        )
    }

    private func toolCall(name: String, client: String, at: Date) -> MCPService.ToolCallHistoryEntry {
        MCPService.ToolCallHistoryEntry(timestamp: at, toolName: name, clientName: client)
    }

    private func rows(in snapshot: CoordinatorModeSnapshot, group: CoordinatorModeStatusGroup) -> [CoordinatorModeRow] {
        snapshot.groups.first { $0.group == group }?.rows ?? []
    }

    private func allRows(in snapshot: CoordinatorModeSnapshot) -> [CoordinatorModeRow] {
        snapshot.groups.flatMap(\.rows)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
