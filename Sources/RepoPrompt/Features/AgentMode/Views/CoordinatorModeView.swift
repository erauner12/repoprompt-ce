import AppKit
import SwiftUI

struct CoordinatorModeView: View {
    private enum InspectorTarget {
        case row(CoordinatorModeRow)
    }

    private struct MissionPlanReadinessProjection {
        let nodesByID: [UUID: CoordinatorMissionPlanNode]
        let dependencySatisfactionByNodeID: [UUID: Bool]
        let readyNodeIDs: Set<UUID>
        let runningNodeCount: Int
        let maxConcurrent: Int

        init(plan: CoordinatorMissionPlan) {
            let indexedNodes = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0) })
            let dependencySatisfaction = Dictionary(uniqueKeysWithValues: plan.nodes.map { node in
                (node.id, node.dependsOn.allSatisfy { indexedNodes[$0]?.status == .completed })
            })
            nodesByID = indexedNodes
            dependencySatisfactionByNodeID = dependencySatisfaction
            readyNodeIDs = Set(plan.nodes.compactMap { node in
                guard node.status == .pending,
                      dependencySatisfaction[node.id] == true
                else { return nil }
                return node.id
            })
            runningNodeCount = plan.nodes.count { $0.status == .running }
            maxConcurrent = plan.policySnapshot?.maxConcurrent ?? CoordinatorMissionPolicySnapshot.defaultMaxConcurrent
        }

        var capacityAvailable: Bool {
            runningNodeCount < maxConcurrent
        }

        var readyCount: Int {
            readyNodeIDs.count
        }

        var waitingCount: Int {
            dependencySatisfactionByNodeID.count { nodeID, dependenciesSatisfied in
                nodesByID[nodeID]?.status == .pending && !dependenciesSatisfied
            }
        }

        var completedCount: Int {
            nodesByID.values.count { $0.status == .completed }
        }

        func dependenciesSatisfied(for node: CoordinatorMissionPlanNode) -> Bool {
            dependencySatisfactionByNodeID[node.id] == true
        }

        func isReady(_ node: CoordinatorMissionPlanNode) -> Bool {
            readyNodeIDs.contains(node.id)
        }

        func isHeldByCap(_ node: CoordinatorMissionPlanNode) -> Bool {
            isReady(node) && node.executionPolicy.usesStartCapacity && !capacityAvailable
        }
    }

    private struct MissionPlanDependencyBand: Identifiable {
        let kind: MissionPlanDependencyBandKind
        var nodes: [CoordinatorMissionPlanNode]

        var id: String {
            kind.rawValue
        }
    }

    private struct DecisionQueueTag: Hashable {
        let title: String
        let systemImage: String
    }

    private enum MissionPlanDependencyBandKind: String, CaseIterable {
        case running
        case ready
        case waiting
        case blocked
        case done

        var title: String {
            switch self {
            case .running: "Running now"
            case .ready: "Ready next"
            case .waiting: "Waiting on dependencies"
            case .blocked: "Blocked"
            case .done: "Done"
            }
        }

        var systemImage: String {
            switch self {
            case .running: "circle.dotted"
            case .ready: "play.circle.fill"
            case .waiting: "hourglass"
            case .blocked: "exclamationmark.triangle.fill"
            case .done: "checkmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .running: .blue
            case .ready: .green
            case .waiting: .secondary
            case .blocked: .red
            case .done: .green
            }
        }
    }

    private enum ChildDirectiveAvailability {
        case ready(status: String)
        case openToReply(AgentSessionDeepLinkRoute)
        case blocked(status: String, notice: String)

        var canEdit: Bool {
            if case .ready = self { true } else { false }
        }

        var canAct: Bool {
            switch self {
            case .ready, .openToReply: true
            case .blocked: false
            }
        }

        var status: String {
            switch self {
            case let .ready(status), let .blocked(status, _):
                status
            case .openToReply:
                "Open"
            }
        }

        var title: String {
            switch self {
            case .openToReply:
                "Open Agent"
            case .ready, .blocked:
                "Reply to this session"
            }
        }

        func notice(for row: CoordinatorModeRow) -> String? {
            switch self {
            case .ready:
                "Send a follow-up to \(row.title)"
            case .openToReply:
                "Open this session in Agent Mode."
            case let .blocked(_, notice):
                notice
            }
        }

        var iconName: String {
            switch self {
            case .openToReply:
                "arrow.up.forward.app"
            case .ready, .blocked:
                "arrowshape.turn.up.left.fill"
            }
        }
    }

    @ObservedObject var viewModel: CoordinatorModeViewModel
    let agentModeVM: AgentModeViewModel?
    let promptManager: PromptViewModel?
    let workspaceSearchService: WorkspaceSearchService?
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let rootsStore: AgentWorkspaceRootsSidebarStore?
    let apiSettingsVM: APISettingsViewModel?
    let currentTabID: UUID?
    let onManageWorkspaces: (() -> Void)?
    let onOpenAgentChat: (AgentSessionDeepLinkRoute) -> Void

    @State private var selectedRowID: UUID?
    @State private var selectedPlanNodeID: UUID?
    @State private var hoveredRowID: UUID?
    @State private var hoveredPlanNodeID: UUID?
    @State private var filterText = ""
    @State private var coordinatorDirectiveDraft = ""
    @State private var missionPlanRevisionDraft = ""
    @State private var coordinatorCheckpointDrafts: [UUID: [String: AgentAskUserDraft]] = [:]
    @State private var coordinatorCheckpointQuestionIndex: [UUID: Int] = [:]
    @State private var coordinatorOwnedCheckpointDrafts: [String: [String: AgentAskUserDraft]] = [:]
    @State private var coordinatorOwnedCheckpointQuestionIndex: [String: Int] = [:]
    @State private var childDirectiveDraft = ""
    @State private var childDirectiveNotice: String?
    @State private var isSubmittingCoordinatorDirective = false
    @State private var isSubmittingChildDirective = false
    @State private var isStoppingCoordinatorMission = false
    @State private var coordinatorTextFieldResetTrigger = false
    @State private var coordinatorTextFieldHeight = ResizableTextField.height(forPresetIndex: 0, preset: .normal)
    @State private var coordinatorComposerChromeOcclusion: CGFloat = 0
    @State private var missionPlanComposerChromeOcclusion: CGFloat = 0
    @State private var missionPlanComposerTextFieldResetTrigger = false
    @State private var missionPlanComposerTextFieldHeight = ResizableTextField.height(forPresetIndex: 0, preset: .normal)
    @State private var isSubmittingMissionPlanRevision = false
    @State private var isCoordinatorToolsPopoverPresented = false
    @State private var coordinatorToolsRevision = 0
    @State private var isChildComposerExpanded = false
    @State private var isCoordinatorRailVisible = true
    @State private var isInspectorVisible = true
    @State private var isMissionPlanPaneVisible = true
    @State private var isSortMenuOpen = false
    @State private var areArchivedMissionsExpanded = false
    @State private var copiedMissionReceiptPlanID: UUID?
    @State private var coordinatorColumnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var isCoordinatorComposerFocused: Bool
    @FocusState private var isMissionPlanComposerFocused: Bool
    @FocusState private var isChildComposerFocused: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    private var visualMetrics: CoordinatorVisualMetrics {
        CoordinatorVisualMetrics(fontPreset: fontScale.preset)
    }

    var body: some View {
        GeometryReader { proxy in
            let snapshot = viewModel.snapshot
            let sections = filteredSections(from: snapshot)
            let selectedRow = selectedRow(in: sections)
            let inspectorTarget = inspectorTarget(snapshot: snapshot, sections: sections, selectedRow: selectedRow)
            let metrics = visualMetrics
            let forceList = proxy.size.width < 540 && snapshot.boardScope == .allAgents
            let useList = forceList
            let railIsAvailable = proxy.size.width >= metrics.railAvailableWidth
            let inspectorIsAvailable = proxy.size.width >= 1200
            coordinatorShell(
                snapshot: snapshot,
                sections: sections,
                selectedRow: selectedRow,
                inspectorTarget: inspectorTarget,
                useList: useList,
                forceList: forceList,
                railIsAvailable: railIsAvailable,
                inspectorIsAvailable: inspectorIsAvailable,
                metrics: metrics
            )
        }
        .background(CoordinatorTheme.Palette.windowBackground)
        .onAppear {
            viewModel.setVisible(true)
        }
        .onDisappear {
            viewModel.setVisible(false)
        }
        .onChange(of: viewModel.snapshot) { _, _ in
            reconcileSelection()
            reconcilePlanSelection()
        }
        .onChange(of: selectedRowID) { _, _ in
            resetChildDirectiveComposer()
        }
    }

    private func coordinatorShell(
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection],
        selectedRow _: CoordinatorModeRow?,
        inspectorTarget: InspectorTarget?,
        useList: Bool,
        forceList: Bool,
        railIsAvailable: Bool,
        inspectorIsAvailable _: Bool,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        Group {
            if railIsAvailable {
                NavigationSplitView(columnVisibility: $coordinatorColumnVisibility) {
                    coordinatorShellRail(snapshot: snapshot, metrics: metrics)
                        .navigationSplitViewColumnWidth(
                            min: coordinatorRailColumnWidth(metrics: metrics),
                            ideal: coordinatorRailColumnWidth(metrics: metrics),
                            max: coordinatorRailColumnWidth(metrics: metrics)
                        )
                } detail: {
                    coordinatorShellDetail(
                        snapshot: snapshot,
                        sections: sections,
                        inspectorTarget: inspectorTarget,
                        useList: useList,
                        forceList: forceList,
                        metrics: metrics
                    )
                }
            } else {
                coordinatorShellDetail(
                    snapshot: snapshot,
                    sections: sections,
                    inspectorTarget: inspectorTarget,
                    useList: useList,
                    forceList: forceList,
                    metrics: metrics
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CoordinatorTheme.Palette.windowBackground)
    }

    private func coordinatorRailColumnWidth(metrics: CoordinatorVisualMetrics) -> CGFloat {
        isCoordinatorRailVisible ? metrics.railWidth : metrics.collapsedRailWidth
    }

    private func coordinatorShellRail(
        snapshot: CoordinatorModeSnapshot,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        Group {
            if isCoordinatorRailVisible {
                coordinatorHistorySidebar(snapshot: snapshot, metrics: metrics)
            } else {
                collapsedCoordinatorRailRestore(metrics: metrics)
            }
        }
        .frame(width: coordinatorRailColumnWidth(metrics: metrics))
        .frame(maxHeight: .infinity)
    }

    private func coordinatorShellDetail(
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection],
        inspectorTarget: InspectorTarget?,
        useList: Bool,
        forceList: Bool,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(spacing: 0) {
            coordinatorCenterContent(
                snapshot: snapshot,
                sections: sections,
                useList: useList,
                forceList: forceList,
                metrics: metrics
            )
            .frame(minWidth: metrics.centerChatMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            .background(CoordinatorTheme.Palette.windowBackground)
            .clipped()

            if shouldShowRightMissionPlan(for: snapshot) {
                rightWorkPanel(
                    snapshot: snapshot,
                    inspectorTarget: inspectorTarget,
                    metrics: metrics
                )
                .frame(width: metrics.rightWorkPanelWidth)
                .frame(maxHeight: .infinity)
                .background(CoordinatorTheme.Palette.windowBackground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CoordinatorTheme.Palette.windowBackground)
    }

    private func shouldShowRightMissionPlan(for snapshot: CoordinatorModeSnapshot) -> Bool {
        viewModel.railDestination == .mission
            && snapshot.coordinatorRail.state == .selected
            && snapshot.coordinatorRail.missionPlan != nil
            && isMissionPlanPaneVisible
    }

    private func coordinatorCenterContent(
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection],
        useList: Bool,
        forceList: Bool,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        Group {
            switch viewModel.railDestination {
            case .mission:
                if snapshot.coordinatorRail.state == .chooseCoordinator {
                    coordinatorDraftCenter(rail: snapshot.coordinatorRail, metrics: metrics)
                } else {
                    coordinatorConversation(snapshot.coordinatorRail, metrics: metrics)
                }
            case .board:
                coordinatorBoardContent(
                    snapshot: snapshot,
                    sections: sections,
                    useList: useList,
                    forceList: forceList,
                    metrics: metrics
                )
            case .decisions:
                coordinatorDecisionsPanel(snapshot: snapshot, sections: sections, metrics: metrics)
            }
        }
    }

    private func rightWorkPanel(
        snapshot: CoordinatorModeSnapshot,
        inspectorTarget: InspectorTarget?,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(spacing: 0) {
            missionPlanPaneHeader(rail: snapshot.coordinatorRail, metrics: metrics)

            missionPlanView(
                rail: snapshot.coordinatorRail,
                childCounts: snapshot.coordinatorRail.childCounts,
                metrics: metrics
            )
            .frame(maxHeight: inspectorTarget == nil || !isInspectorVisible ? .infinity : metrics.rightBoardHeight)

            if CoordinatorMissionPresentationPolicy.shouldShowPlanRevisionComposer(
                for: snapshot.coordinatorRail.missionPlan
            ) {
                Divider()
                    .opacity(0.28)
                missionPlanFooterComposer(rail: snapshot.coordinatorRail, metrics: metrics)
                    .padding(metrics.outerPadding)
            }

            if let inspectorTarget, isInspectorVisible {
                Divider()
                    .opacity(0.28)
                inspector(target: inspectorTarget, metrics: metrics)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let inspectorTarget {
                collapsedInspectorHandle(target: inspectorTarget, metrics: metrics)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(CoordinatorTheme.Palette.windowBackground)
        .animation(.easeInOut(duration: 0.22), value: isInspectorVisible)
        .coordinatorFlushRegion(edge: .leading)
    }

    private func missionPlanPaneHeader(
        rail: CoordinatorModeCoordinatorRail,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(spacing: metrics.controlSpacing) {
            Label("Mission Plan", systemImage: "list.clipboard")
                .font(metrics.bodySemibold)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            if let status = rail.missionPlan?.status {
                statusChip(status.displayName, color: status.tint, metrics: metrics)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isMissionPlanPaneVisible = false
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: metrics.smallIconSize, weight: .medium))
                    .frame(width: metrics.titlebarButtonSize, height: metrics.titlebarButtonSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .hoverTooltip("Collapse Mission Plan")
            .accessibilityLabel("Collapse Mission Plan")
        }
        .padding(.horizontal, metrics.outerPadding)
        .padding(.vertical, metrics.headerPadding)
        .background(CoordinatorTheme.Palette.elevatedPanelBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CoordinatorTheme.Palette.hairline)
                .frame(height: 0.5)
        }
    }

    private func coordinatorDraftCenter(
        rail: CoordinatorModeCoordinatorRail,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                coordinatorMissionDraftSurface(metrics: metrics)
                    .padding(metrics.outerPadding)
                    .frame(maxWidth: metrics.draftSurfaceMaxWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .opacity(0.28)

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                coordinatorComposer(rail, metrics: metrics)
                    .padding(.horizontal, metrics.cardPadding)
                    .padding(.top, metrics.cardPadding)
            }
            .background(CoordinatorTheme.Palette.windowBackground)
        }
        .background(CoordinatorTheme.Palette.windowBackground)
    }

    private func coordinatorBoardContent(
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection],
        useList: Bool,
        forceList: Bool,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                boardControls(
                    mcpAwareness: snapshot.mcpAwareness,
                    forceList: forceList,
                    metrics: metrics
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, metrics.outerPadding)
            .padding(.vertical, metrics.headerPadding)
            .background(CoordinatorTheme.Palette.elevatedPanelBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CoordinatorTheme.Palette.hairline)
                    .frame(height: 0.5)
            }

            Group {
                if snapshot.isEmpty {
                    emptyState(snapshot: snapshot, metrics: metrics)
                } else if useList {
                    listView(sections: sections, metrics: metrics)
                } else {
                    boardView(
                        sections: sections,
                        boardScope: snapshot.boardScope,
                        metrics: metrics
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CoordinatorTheme.Palette.windowBackground)
    }

    private func coordinatorDecisionsPanel(
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection],
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let pendingDecisionAttentionCount = coordinatorPendingDecisionAttentionCount(snapshot)
        return VStack(spacing: 0) {
            HStack(spacing: metrics.controlSpacing) {
                Label("Decisions", systemImage: "checklist.checked")
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                statusChip(
                    pendingDecisionAttentionCount == 0 ? "No pending attention" : "\(pendingDecisionAttentionCount) pending",
                    color: pendingDecisionAttentionCount == 0 ? .secondary : Color.accentColor,
                    metrics: metrics
                )
            }
            .padding(.horizontal, metrics.outerPadding)
            .padding(.vertical, metrics.headerPadding)
            .background(CoordinatorTheme.Palette.elevatedPanelBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CoordinatorTheme.Palette.hairline)
                    .frame(height: 0.5)
            }

            Group {
                if snapshot.decisionQueue.isEmpty {
                    coordinatorDecisionsEmptyState(metrics: metrics)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: metrics.listRowSpacing) {
                            ForEach(snapshot.decisionQueue) { item in
                                coordinatorDecisionQueueCard(
                                    item,
                                    snapshot: snapshot,
                                    sections: sections,
                                    metrics: metrics
                                )
                            }
                        }
                        .padding(metrics.outerPadding)
                        .frame(maxWidth: 760, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CoordinatorTheme.Palette.windowBackground)
    }

    private func coordinatorDecisionsEmptyState(metrics: CoordinatorVisualMetrics) -> some View {
        VStack(spacing: metrics.cardInnerSpacing) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: metrics.emptyStateIconSize, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No decisions waiting")
                .font(metrics.inspectorTitle)
                .foregroundStyle(.primary)
            Text("When a Mission checkpoint or Agent session needs you, it will appear here.")
                .font(metrics.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(metrics.outerPadding)
    }

    private func coordinatorDecisionQueueCard(
        _ item: CoordinatorModeDecisionQueueItem,
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection],
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let tags = coordinatorDecisionTags(for: item, snapshot: snapshot, sections: sections)
        return Button {
            openDecisionQueueItem(item)
        } label: {
            HStack(alignment: .center, spacing: metrics.controlSpacing) {
                VStack(alignment: .leading, spacing: metrics.smallSpacing) {
                    HStack(spacing: metrics.smallSpacing) {
                        statusChip(item.source.displayLabel, color: item.source.tint, metrics: metrics)
                        Spacer(minLength: 0)
                    }

                    Text(item.title)
                        .font(metrics.cardTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(coordinatorDecisionDetailText(for: item))
                        .font(metrics.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !tags.isEmpty {
                        HStack(spacing: metrics.smallSpacing) {
                            ForEach(tags, id: \.self) { tag in
                                coordinatorDecisionTag(tag, metrics: metrics)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: metrics.microIconSize, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: metrics.titlebarButtonSize, height: metrics.titlebarButtonSize)
            }
            .padding(metrics.sessionCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinatorCardBackground(cornerRadius: metrics.cardCornerRadius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Decision: \(item.title)")
    }

    private func coordinatorDecisionTag(_ tag: DecisionQueueTag, metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.miniPillIconSpacing) {
            Image(systemName: tag.systemImage)
                .font(.system(size: metrics.microIconSize, weight: .semibold))
            Text(tag.title)
                .font(metrics.microMedium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, metrics.miniPillHorizontalPadding)
        .padding(.vertical, metrics.miniPillVerticalPadding)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5))
    }

    private func coordinatorDecisionTags(
        for item: CoordinatorModeDecisionQueueItem,
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection]
    ) -> [DecisionQueueTag] {
        var tags: [DecisionQueueTag] = []
        if let coordinatorSessionID = item.coordinatorSessionID,
           let title = coordinatorTitle(for: coordinatorSessionID, snapshot: snapshot)
        {
            tags.append(DecisionQueueTag(title: title, systemImage: "rectangle.3.group.bubble"))
        }
        if let sessionID = item.sessionID,
           sessionID != item.coordinatorSessionID,
           let title = coordinatorRowTitle(for: sessionID, sections: sections)
        {
            tags.append(DecisionQueueTag(title: title, systemImage: "person.crop.circle"))
        }
        return tags
    }

    private func coordinatorDecisionDetailText(for item: CoordinatorModeDecisionQueueItem) -> String {
        let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty { return detail }
        switch item.source {
        case .planApproval:
            return "Review the Mission checkpoint before work continues."
        case .followThroughBoundary:
            return "A held Mission step is waiting for your checkpoint."
        case .interaction:
            return "An Agent session is waiting for your reply."
        case .review:
            return "Review output is ready to inspect."
        case .blockedUserAction:
            return "A blocked Mission node needs your decision."
        }
    }

    private func coordinatorTitle(for sessionID: UUID, snapshot: CoordinatorModeSnapshot) -> String? {
        if snapshot.coordinatorRail.coordinatorSessionID == sessionID,
           let title = snapshot.coordinatorRail.title
        {
            return title
        }
        return snapshot.coordinatorRail.availableCoordinators.first { $0.sessionID == sessionID }?.title
    }

    private func coordinatorRowTitle(for sessionID: UUID, sections: [CoordinatorModeStatusSection]) -> String? {
        sections.flatMap(\.rows).first { $0.sessionID == sessionID }?.title
    }

    private func openDecisionQueueItem(_ item: CoordinatorModeDecisionQueueItem) {
        switch item.source {
        case .planApproval, .followThroughBoundary, .blockedUserAction:
            openDecisionMissionTarget(item)
        case .interaction, .review:
            if item.sessionID == item.coordinatorSessionID {
                openDecisionMissionTarget(item)
            } else if let route = item.openAgentChatRoute {
                onOpenAgentChat(route)
            } else {
                openDecisionMissionTarget(item)
            }
        }
    }

    private func openDecisionMissionTarget(_ item: CoordinatorModeDecisionQueueItem) {
        guard let coordinatorSessionID = item.coordinatorSessionID else {
            if let route = item.openAgentChatRoute {
                onOpenAgentChat(route)
            }
            return
        }
        selectedPlanNodeID = item.nodeID
        isMissionPlanPaneVisible = true
        viewModel.selectCoordinator(sessionID: coordinatorSessionID)
    }

    private func boardControls(
        mcpAwareness: CoordinatorModeMCPAwareness,
        forceList: Bool,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(spacing: metrics.controlSpacing) {
            Label("Agent Board", systemImage: "rectangle.3.group.bubble")
                .font(metrics.bodySemibold)
                .foregroundStyle(.primary)

            sortPicker(metrics: metrics)

            if forceList {
                forceListLabel(metrics: metrics)
            }

            Spacer(minLength: 0)

            if shouldShowMCPAwarenessChip(mcpAwareness) {
                mcpAwarenessChip(mcpAwareness, metrics: metrics)
            }
        }
    }

    private func shouldShowMCPAwarenessChip(_ awareness: CoordinatorModeMCPAwareness) -> Bool {
        awareness.state != .empty
            || awareness.connectedClientCount > 0
            || awareness.activeClientCount > 0
            || awareness.idleClientCount > 0
            || awareness.inFlightToolCallCount > 0
    }

    private func mcpAwarenessChip(_ awareness: CoordinatorModeMCPAwareness, metrics: CoordinatorVisualMetrics) -> some View {
        let statusText = compactMCPStatusText(for: awareness)
        return CoordinatorStatusPlate(
            title: statusText,
            tint: awareness.state.statusTint,
            font: metrics.bodyMedium,
            dotSize: metrics.composerStatusDotSize,
            horizontalPadding: metrics.headerControlHorizontalPadding,
            verticalPadding: 0,
            systemImage: awareness.state.systemImage
        )
        .frame(height: metrics.headerControlHeight)
        .hoverTooltip(mcpAwarenessTooltip(for: awareness))
        .accessibilityLabel(mcpAwarenessTooltip(for: awareness))
    }

    private func compactMCPStatusText(for awareness: CoordinatorModeMCPAwareness) -> String {
        if awareness.inFlightToolCallCount > 0 {
            return "\(awareness.state.displayName) · \(awareness.inFlightToolCallCount) in flight"
        }
        if awareness.connectedClientCount > 0 {
            return "\(awareness.state.displayName) · \(awareness.connectedClientCount) clients"
        }
        return awareness.state.displayName
    }

    private func mcpAwarenessTooltip(for awareness: CoordinatorModeMCPAwareness) -> String {
        var parts = [
            awareness.state.displayName,
            "Clients: \(awareness.connectedClientCount) connected, \(awareness.activeClientCount) active, \(awareness.idleClientCount) idle",
            "In flight: \(awareness.inFlightToolCallCount)"
        ]
        if let recent = awareness.recentToolCalls.first {
            parts.append("Recent: \(recent.clientName) -> \(recent.toolName)")
        } else {
            parts.append("No recent Coordinator MCP calls")
        }
        return parts.joined(separator: "\n")
    }

    private func headerSegmentButton(
        title: String,
        isSelected: Bool,
        metrics: CoordinatorVisualMetrics,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(metrics.bodySemibold)
                .lineLimit(1)
                .minimumScaleFactor(0.84)
                .frame(maxWidth: .infinity)
                .frame(height: metrics.headerSegmentHeight)
                .padding(.horizontal, metrics.headerSegmentHorizontalPadding)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func automationModePicker(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.headerSegmentSpacing) {
            headerSegmentButton(
                title: "Step",
                isSelected: viewModel.missionPaceSelection == .step,
                metrics: metrics
            ) {
                viewModel.setExecutionPace(.step)
            }

            headerSegmentButton(
                title: "Auto",
                isSelected: viewModel.missionPaceSelection == .auto,
                metrics: metrics
            ) {
                viewModel.setExecutionPace(.auto)
            }
        }
        .padding(metrics.headerControlInset)
        .frame(width: metrics.automationModeControlWidth, height: metrics.headerControlHeight)
        .coordinatorHeaderControlBackground()
        .accessibilityLabel("Director automation mode")
    }

    private func sortPicker(metrics: CoordinatorVisualMetrics) -> some View {
        Button {
            isSortMenuOpen.toggle()
        } label: {
            HStack(spacing: metrics.smallSpacing) {
                Text("Sort")
                    .font(metrics.bodyMedium)
                    .foregroundStyle(.secondary)

                Text(viewModel.sortMode.displayName)
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: metrics.microIconSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, metrics.headerControlHorizontalPadding)
            .frame(width: metrics.sortControlWidth, height: metrics.headerControlHeight)
            .coordinatorHeaderControlBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort")
        .popover(isPresented: $isSortMenuOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            sortMenuContent(metrics: metrics)
        }
    }

    private func sortMenuContent(metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            ForEach(CoordinatorModeSortMode.allCases, id: \.self) { mode in
                Button {
                    viewModel.sortMode = mode
                    isSortMenuOpen = false
                } label: {
                    HStack(spacing: metrics.smallSpacing) {
                        Text(mode.displayName)
                            .font(metrics.bodyMedium)
                            .foregroundStyle(.primary)
                        Spacer(minLength: metrics.controlSpacing)
                        if viewModel.sortMode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: metrics.microIconSize, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, metrics.headerControlHorizontalPadding)
                    .frame(width: metrics.sortControlWidth, height: metrics.headerControlHeight)
                    .background(
                        Capsule(style: .continuous)
                            .fill(viewModel.sortMode == mode ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(metrics.headerControlInset)
    }

    private func forceListLabel(metrics: CoordinatorVisualMetrics) -> some View {
        Label("Agent Board falls back to List at narrow widths", systemImage: "rectangle.split.2x1")
            .font(metrics.body)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func planMetadataChips(plan: CoordinatorMissionPlan?, metrics: CoordinatorVisualMetrics) -> some View {
        if let plan {
            statusChip("r\(plan.revision)", color: .secondary, metrics: metrics)
            statusChip(plan.status.displayName, color: plan.status.tint, metrics: metrics)
            statusChip(plan.approvalState.displayName, color: plan.approvalState.tint, metrics: metrics)
        }
    }

    private func filterSearchBox(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.searchElementSpacing) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AgentModeSurfaceTheme.Palette.searchIcon)
                .font(.system(size: metrics.searchIconSize))

            TextField("Search", text: $filterText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(metrics.searchFont)
                .foregroundColor(Color(NSColor.labelColor))
                .onKeyPress(.escape) {
                    if !filterText.isEmpty {
                        filterText = ""
                        return .handled
                    }
                    return .ignored
                }

            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: metrics.searchClearIconSize))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Director filter")
            }
        }
        .padding(.horizontal, metrics.searchHorizontalPadding)
        .padding(.vertical, metrics.searchVerticalPadding)
        .frame(minHeight: metrics.searchControlHeight)
        .coordinatorSearchControlBackground(cornerRadius: metrics.searchCornerRadius)
    }

    private func coordinatorRail(
        snapshot: CoordinatorModeSnapshot,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let rail = snapshot.coordinatorRail

        return VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            coordinatorRailHistoryContent(snapshot: snapshot, metrics: metrics)
                .frame(maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)
            coordinatorConversation(rail, metrics: metrics)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, metrics.sidebarHorizontalPadding)
        .padding(.vertical, metrics.sidebarVerticalPadding)
        .coordinatorAgentSidebarColumn(edge: .trailing)
    }

    private func coordinatorHistorySidebar(
        snapshot: CoordinatorModeSnapshot,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            coordinatorRailHistoryContent(snapshot: snapshot, metrics: metrics)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, metrics.sidebarHorizontalPadding)
        .padding(.vertical, metrics.sidebarVerticalPadding)
        .coordinatorAgentSidebarColumn(edge: .trailing)
    }

    private func coordinatorRailHistoryContent(
        snapshot: CoordinatorModeSnapshot,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(spacing: 0) {
            filterSearchBox(metrics: metrics)
                .padding(.bottom, metrics.sidebarVerticalPadding)

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    coordinatorNavigationPanel(snapshot: snapshot, metrics: metrics)
                    coordinatorMissionsPanel(snapshot.coordinatorRail, metrics: metrics)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, metrics.sidebarVerticalPadding)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity)

            Divider()
                .opacity(0.45)
                .padding(.top, metrics.tightSpacing)
            coordinatorRailFooter(metrics: metrics)
        }
        .frame(maxWidth: .infinity)
    }

    private func collapsedCoordinatorRailRestore(metrics: CoordinatorVisualMetrics) -> some View {
        VStack(spacing: 0) {
            Button {
                toggleCoordinatorRail()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: metrics.smallIconSize, weight: .medium))
                    .frame(width: metrics.titlebarButtonSize, height: metrics.titlebarButtonSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .hoverTooltip("Show Director Rail")
            .accessibilityLabel("Show Director Rail")
            .padding(.top, metrics.outerPadding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinatorAgentSidebarColumn(edge: .trailing)
    }

    private func coordinatorNavigationPanel(
        snapshot: CoordinatorModeSnapshot,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let pendingDecisionAttentionCount = coordinatorPendingDecisionAttentionCount(snapshot)
        return VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            coordinatorNavigationButton(
                title: "Agent Board",
                subtitle: "Live delegated Agents across Director Missions",
                systemImage: "rectangle.3.group.bubble",
                badgeCount: snapshot.counts.liveRows,
                destination: .board,
                metrics: metrics
            ) {
                viewModel.showBoardDestination()
            }

            coordinatorNavigationButton(
                title: "Decisions",
                subtitle: pendingDecisionAttentionCount == 0 ? "No pending attention" : "\(pendingDecisionAttentionCount) pending attention",
                systemImage: "checklist.checked",
                badgeCount: pendingDecisionAttentionCount == 0 ? nil : pendingDecisionAttentionCount,
                destination: .decisions,
                metrics: metrics
            ) {
                viewModel.showDecisionsDestination()
            }
        }
        .accessibilityLabel("Director navigation")
    }

    private func coordinatorPendingDecisionAttentionCount(_ snapshot: CoordinatorModeSnapshot) -> Int {
        snapshot.decisionQueue.count
    }

    private func coordinatorNavigationButton(
        title: String,
        subtitle: String,
        systemImage: String,
        badgeCount: Int?,
        destination: CoordinatorModeViewModel.RailDestination,
        metrics: CoordinatorVisualMetrics,
        action: @escaping () -> Void
    ) -> some View {
        let isSelected = viewModel.railDestination == destination

        return Button {
            action()
        } label: {
            coordinatorSidebarNavigationRow(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                tint: title == "Agent Board" || isSelected ? Color.accentColor : .secondary,
                badgeCount: badgeCount,
                metrics: metrics
            )
        }
        .buttonStyle(.plain)
        .coordinatorSidebarRowBackground(cornerRadius: metrics.sidebarRowCornerRadius, isSelected: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func coordinatorSidebarNavigationRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        badgeCount: Int?,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(spacing: metrics.smallSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.smallIconSize, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: metrics.titlebarButtonSize, height: metrics.titlebarButtonSize)

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                Text(title)
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                Text(subtitle)
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let badgeCount {
                coordinatorNavigationCountBadge(badgeCount, tint: tint, metrics: metrics)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, metrics.pendingPadding)
        .padding(.vertical, metrics.smallSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func coordinatorNavigationCountBadge(_ count: Int, tint: Color, metrics: CoordinatorVisualMetrics) -> some View {
        Text("\(count)")
            .font(metrics.microMedium)
            .foregroundStyle(tint)
            .monospacedDigit()
            .frame(minWidth: metrics.navigationBadgeSize, minHeight: metrics.navigationBadgeSize)
            .padding(.horizontal, count > 9 ? 4 : 0)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.12)))
            .overlay(Capsule(style: .continuous).stroke(tint.opacity(0.24), lineWidth: 0.5))
            .accessibilityLabel("\(count)")
    }

    private func coordinatorRailFooter(metrics: CoordinatorVisualMetrics) -> some View {
        coordinatorWorkspaceFooter(metrics: metrics)
            .padding(.top, metrics.sidebarVerticalPadding)
    }

    @ViewBuilder
    private func coordinatorWorkspaceFooter(metrics _: CoordinatorVisualMetrics) -> some View {
        if let rootsStore,
           let promptManager,
           let apiSettingsVM,
           let agentModeVM,
           let onManageWorkspaces
        {
            AgentWorkspaceRootsSectionView(
                rootsStore: rootsStore,
                promptManager: promptManager,
                apiSettingsVM: apiSettingsVM,
                onManageWorkspaces: onManageWorkspaces,
                worktreeIndicatorsByLogicalRootPath: currentTabID.map { agentModeVM.worktreeIndicatorsByLogicalRootPath(forTabID: $0) } ?? [:],
                worktreeMergeAttentionsByLogicalRootPath: currentTabID.map { agentModeVM.worktreeMergeAttentionsByLogicalRootPath(forTabID: $0) } ?? [:],
                branchSwitchActions: AgentWorkspaceBranchSwitchActions(
                    loadOptions: { row in
                        try await promptManager.gitViewModel.loadGitBranchSwitchOptions(forRootPath: row.fullPath)
                    },
                    preflight: { row, branchName in
                        try await promptManager.gitViewModel.preflightGitBranchSwitch(
                            branchName: branchName,
                            forRootPath: row.fullPath
                        )
                    },
                    switchBranch: { row, preflight in
                        try await agentModeVM.switchGitBranchFromWorkspaceRoot(
                            row,
                            preflight: preflight,
                            gitViewModel: promptManager.gitViewModel,
                            currentTabID: currentTabID
                        )
                    },
                    isAgentRunActive: {
                        agentModeVM.isAgentRunActive(tabID: currentTabID)
                    }
                )
            )
        }
    }

    private func coordinatorMissionsPanel(
        _ rail: CoordinatorModeCoordinatorRail,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let primaryOptions = rail.availableCoordinators.filter {
            !$0.isPersistedOnly || $0.isSelected || $0.isPinned
        }
        let archivedOptions = rail.availableCoordinators.filter {
            $0.isPersistedOnly && !$0.isSelected && !$0.isPinned
        }

        return VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
            HStack(spacing: metrics.smallSpacing) {
                Label("Missions", systemImage: "rectangle.3.group.bubble")
                    .font(metrics.cardTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            coordinatorNewMissionRow(rail, metrics: metrics)

            if primaryOptions.isEmpty {
                Text("No active missions.")
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, metrics.pendingPadding)
                    .padding(.vertical, metrics.smallSpacing)
            } else {
                coordinatorMissionRows(primaryOptions, metrics: metrics)
            }

            if !archivedOptions.isEmpty {
                Divider()
                    .padding(.vertical, metrics.tightSpacing)
                archivedMissionsDisclosure(
                    options: archivedOptions,
                    metrics: metrics
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func coordinatorMissionRows(
        _ options: [CoordinatorModeCoordinatorOption],
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let rows = VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            ForEach(options) { option in
                coordinatorMissionRow(option, metrics: metrics)
            }
        }

        rows
    }

    private func archivedMissionsDisclosure(
        options: [CoordinatorModeCoordinatorOption],
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    areArchivedMissionsExpanded.toggle()
                }
            } label: {
                HStack(spacing: metrics.smallSpacing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: metrics.microIconSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(areArchivedMissionsExpanded ? 90 : 0))
                    Image(systemName: "archivebox")
                        .font(.system(size: metrics.smallIconSize, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Archived Missions")
                        .font(metrics.bodySemibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(options.count)")
                        .font(metrics.microMedium)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, metrics.pendingPadding)
                .padding(.vertical, metrics.smallSpacing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(areArchivedMissionsExpanded ? "Hide archived missions" : "Show archived missions")

            if areArchivedMissionsExpanded {
                coordinatorMissionRows(options, metrics: metrics)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func coordinatorNewMissionRow(
        _ rail: CoordinatorModeCoordinatorRail,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        Button {
            viewModel.startNewCoordinatorRun()
            isMissionPlanPaneVisible = true
        } label: {
            HStack(alignment: .center, spacing: metrics.smallSpacing) {
                Image(systemName: rail.state == .chooseCoordinator ? "plus.circle.fill" : "plus.bubble")
                    .font(.system(size: metrics.smallIconSize, weight: .semibold))
                    .foregroundStyle(rail.state == .chooseCoordinator ? Color.accentColor : .secondary)
                    .frame(width: metrics.titlebarButtonSize, height: metrics.titlebarButtonSize)

                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    Text("Draft a new Mission")
                        .font(metrics.bodySemibold)
                        .lineLimit(1)
                    Text("Start from a blank prompt")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: metrics.smallSpacing)

                statusChip("Ready", color: .secondary, metrics: metrics)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, metrics.pendingPadding)
            .padding(.vertical, metrics.smallSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .coordinatorSidebarRowBackground(cornerRadius: metrics.sidebarRowCornerRadius, isSelected: rail.state == .chooseCoordinator)
        .hoverTooltip("Prepare a fresh mission")
        .accessibilityAction {
            viewModel.startNewCoordinatorRun()
            isMissionPlanPaneVisible = true
        }
    }

    private func coordinatorMissionRow(
        _ option: CoordinatorModeCoordinatorOption,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let status = coordinatorMissionStatus(for: option)

        return Button {
            viewModel.selectCoordinator(sessionID: option.sessionID)
            isMissionPlanPaneVisible = true
        } label: {
            HStack(alignment: .center, spacing: metrics.smallSpacing) {
                Image(systemName: option.isSelected ? "checkmark.circle.fill" : "bubble.left.and.bubble.right")
                    .font(.system(size: metrics.smallIconSize, weight: .semibold))
                    .foregroundStyle(option.isSelected ? Color.accentColor : .secondary)
                    .frame(width: metrics.titlebarButtonSize, height: metrics.titlebarButtonSize)

                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    Text(option.title)
                        .font(metrics.bodySemibold)
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(option.selectionSource.displayName)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: metrics.smallSpacing)

                if option.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: metrics.microIconSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if let status {
                    coordinatorMissionStatusPill(status, metrics: metrics)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, metrics.pendingPadding)
            .padding(.vertical, metrics.smallSpacing)
            .frame(minHeight: metrics.coordinatorMissionRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .coordinatorSidebarRowBackground(cornerRadius: metrics.sidebarRowCornerRadius, isSelected: option.isSelected)
        .contextMenu {
            Button(option.isPinned ? "Unpin" : "Pin") {
                viewModel.togglePinnedCoordinator(option)
            }
            .disabled(option.tabID == nil)
        }
        .hoverTooltip("Switch mission to \(option.title)")
        .accessibilityAction {
            viewModel.selectCoordinator(sessionID: option.sessionID)
            isMissionPlanPaneVisible = true
        }
    }

    private func coordinatorMissionStatusPill(
        _ status: (text: String, color: Color),
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(spacing: metrics.miniPillIconSpacing) {
            Circle()
                .fill(status.color.opacity(0.9))
                .frame(width: metrics.composerStatusDotSize, height: metrics.composerStatusDotSize)
            Text(status.text)
                .font(metrics.microMedium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.miniPillHorizontalPadding)
        .padding(.vertical, metrics.miniPillVerticalPadding)
        .background(Capsule(style: .continuous).fill(status.color.opacity(0.10)))
        .overlay(Capsule(style: .continuous).stroke(status.color.opacity(0.18), lineWidth: 0.5))
    }

    private func coordinatorMissionStatus(for option: CoordinatorModeCoordinatorOption) -> (text: String, color: Color)? {
        if let missionPlan = option.missionPlan,
           missionPlan.status.isTerminal
        {
            return (missionPlan.status.displayName, missionPlan.status.tint)
        }
        if let runState = option.runState, runState.isActive {
            return (runState.coordinatorMissionDisplayName, .blue)
        }
        if option.isLiveInCurrentWindow,
           CoordinatorMissionPresentationPolicy.shouldShowLiveBadge(for: option.missionPlan)
        {
            return ("Live", .green)
        }
        return nil
    }

    private enum SidebarTitlebarControlPlacement {
        case leading
        case trailing
    }

    private func coordinatorSidebarTitlebarLane(
        metrics: CoordinatorVisualMetrics,
        controlPlacement: SidebarTitlebarControlPlacement,
        @ViewBuilder title: () -> some View,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(spacing: metrics.smallSpacing) {
            if controlPlacement == .leading {
                control()
            }

            title()

            Spacer(minLength: 0)

            if controlPlacement == .trailing {
                control()
            }
        }
        .frame(height: metrics.railTitlebarLaneHeight)
    }

    private func coordinatorRailTitlebarLane(metrics: CoordinatorVisualMetrics) -> some View {
        coordinatorSidebarTitlebarLane(metrics: metrics, controlPlacement: .trailing) {
            coordinatorNewChatToolbarButton(metrics: metrics)
        } control: {
            CoordinatorRailToggleButton(isRailVisible: true, metrics: metrics) {
                toggleCoordinatorRail()
            }
        }
    }

    private func coordinatorNewChatToolbarButton(metrics: CoordinatorVisualMetrics) -> some View {
        Button {
            viewModel.startNewCoordinatorRun()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: metrics.smallIconSize, weight: .medium))
                .frame(width: metrics.titlebarButtonSize, height: metrics.titlebarButtonSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .hoverTooltip("New Mission")
        .accessibilityLabel("New Mission")
    }

    private func toggleCoordinatorRail() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCoordinatorRailVisible.toggle()
        }
    }

    private func boardView(
        sections: [CoordinatorModeStatusSection],
        boardScope: CoordinatorModeBoardScope,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let visibleSections = visibleBoardSections(from: sections, boardScope: boardScope)

        return GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if visibleSections.isEmpty {
                        Text(isFilteringAllAgentsBoard ? "No matching sessions" : "No sessions")
                            .font(metrics.bodyMedium)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                clearSelectedRow()
                            }
                    } else {
                        HStack(alignment: .top, spacing: metrics.boardColumnSpacing) {
                            ForEach(visibleSections, id: \.group) { section in
                                boardColumn(
                                    section: section,
                                    boardScope: boardScope,
                                    metrics: metrics,
                                    minHeight: max(proxy.size.height - (metrics.outerPadding * 2), metrics.boardColumnMinHeight)
                                )
                                .frame(width: boardColumnWidth(for: visibleSections, availableWidth: proxy.size.width, metrics: metrics))
                            }
                        }
                    }
                }
                .padding(metrics.outerPadding)
                .frame(
                    minWidth: proxy.size.width,
                    minHeight: proxy.size.height,
                    alignment: .topLeading
                )
                .animation(.easeInOut(duration: 0.22), value: boardAnimationKey(for: visibleSections))
            }
        }
    }

    private func missionPlanView(
        rail: CoordinatorModeCoordinatorRail,
        childCounts: CoordinatorModeCoordinatorChildCounts,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    if let plan = rail.missionPlan {
                        missionPlanSummary(plan, childCounts: childCounts, metrics: metrics)

                        if plan.workstreams.isEmpty, plan.nodes.isEmpty {
                            missionPlanEmptyState(
                                title: "No workstreams yet",
                                subtitle: "Workstreams appear once a Mission Plan is recorded.",
                                metrics: metrics
                            )
                        } else if plan.nodes.isEmpty {
                            ForEach(Array(plan.workstreams.enumerated()), id: \.element.id) { offset, workstream in
                                missionPlanWorkstreamOutline(
                                    workstream,
                                    partIndex: offset + 1,
                                    partTotal: plan.workstreams.count,
                                    metrics: metrics
                                )
                            }
                        } else {
                            missionPlanNodeOutline(plan, metrics: metrics)
                        }
                    } else {
                        missionPlanEmptyState(
                            title: "No Mission Plan yet",
                            subtitle: "When a Mission Plan is recorded, workstreams and task steps appear here.",
                            metrics: metrics
                        )
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height - metrics.outerPadding * 2, alignment: .center)
                    }
                }
                .padding(metrics.outerPadding)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .background(CoordinatorTheme.Palette.windowBackground)
        }
    }

    private func missionPlanFooterComposer(
        rail: CoordinatorModeCoordinatorRail,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let placeholder = missionPlanFooterComposerPlaceholder(rail)
        let canEdit = canEditMissionPlanRevision(rail)
        let canSubmit = canSubmitMissionPlanRevision(rail)

        return VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            HStack(spacing: metrics.tightSpacing) {
                Image(systemName: "pencil.line")
                    .font(.system(size: metrics.microIconSize, weight: .semibold))
                Text("✎ PLAN")
                    .font(metrics.microMedium)
                    .tracking(0.4)
            }
            .foregroundStyle(canEdit ? Color.accentColor : .secondary)

            ComposerChrome(
                bottomOcclusion: $missionPlanComposerChromeOcclusion,
                mainContentHeight: max(missionPlanComposerTextFieldHeight, metrics.composerTextMinHeight),
                highlightColor: canSubmit ? Color.accentColor : nil,
                bubbleVerticalPaddingOverride: metrics.coordinatorComposerChromeVerticalPadding,
                bubbleInnerSpacingOverride: metrics.coordinatorComposerChromeInnerSpacing,
                controlStripHeightOverride: metrics.composerControlStripHeight,
                bubbleStroke: AgentModeSurfaceTheme.Palette.composerBubbleStroke,
                bubbleShadow: AgentModeSurfaceTheme.Palette.composerShadow,
                bubbleShadowRadius: 7,
                main: {
                    ResizableTextField(
                        text: $missionPlanRevisionDraft,
                        placeholder: placeholder,
                        onReturn: submitMissionPlanRevision,
                        resetTrigger: $missionPlanComposerTextFieldResetTrigger,
                        features: coordinatorComposerFeatures(),
                        onHeightChange: { newHeight in
                            missionPlanComposerTextFieldHeight = newHeight
                        }
                    )
                    .frame(height: max(missionPlanComposerTextFieldHeight, metrics.composerTextMinHeight))
                    .disabled(!canEdit)
                    .focused($isMissionPlanComposerFocused)
                    .overlay(
                        Text(placeholder)
                            .font(metrics.body)
                            .foregroundStyle(.secondary)
                            .opacity(missionPlanRevisionDraft.isEmpty ? 1 : 0)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false),
                        alignment: .topLeading
                    )
                },
                strip: {
                    HStack(spacing: metrics.smallSpacing) {
                        Text("Plan revision")
                            .font(metrics.microMedium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: metrics.smallSpacing)

                        Button {
                            submitMissionPlanRevision()
                        } label: {
                            Image(systemName: isSubmittingMissionPlanRevision ? "hourglass" : "paperplane.fill")
                                .font(.system(size: metrics.composerSendIconSize, weight: .semibold))
                                .frame(width: metrics.sendButtonSize, height: metrics.sendButtonSize)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary.opacity(0.55))
                        .disabled(!canSubmit)
                        .hoverTooltip(isSubmittingMissionPlanRevision ? "Sending" : "Revise plan")
                    }
                    .frame(height: metrics.composerControlStripHeight)
                    .padding(.horizontal, metrics.composerControlHorizontalPadding)
                }
            )
        }
    }

    private func missionPlanFooterComposerPlaceholder(_ rail: CoordinatorModeCoordinatorRail) -> String {
        guard let plan = rail.missionPlan else {
            return "Approve the plan first to revise it…"
        }
        if plan.approvalState == .awaitingApproval {
            return "Approve the plan first to revise it…"
        }
        return "Revise the plan — add, remove, or change a pending step…"
    }

    private func canEditMissionPlanRevision(_ rail: CoordinatorModeCoordinatorRail) -> Bool {
        guard rail.state == .selected,
              let plan = rail.missionPlan,
              rail.isComposerEnabled,
              rail.isComposerSendEnabled,
              CoordinatorMissionPresentationPolicy.shouldShowPlanRevisionComposer(for: plan),
              plan.approvalState != .awaitingApproval
        else { return false }
        return !isSubmittingMissionPlanRevision
    }

    private func canSubmitMissionPlanRevision(_ rail: CoordinatorModeCoordinatorRail) -> Bool {
        canEditMissionPlanRevision(rail)
            && !missionPlanRevisionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitMissionPlanRevision() {
        let rail = viewModel.snapshot.coordinatorRail
        let draft = missionPlanRevisionDraft
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              canSubmitMissionPlanRevision(rail),
              viewModel.queuePlanRevisionDecisionAfterAcceptedDirective()
        else { return }

        isSubmittingMissionPlanRevision = true
        isMissionPlanComposerFocused = true
        Task { @MainActor in
            let result = await viewModel.submitCoordinatorDirective(draft)
            if result == .accepted {
                missionPlanRevisionDraft = ""
            }
            isSubmittingMissionPlanRevision = false
            isMissionPlanComposerFocused = true
        }
    }

    private func coordinatorMissionDraftSurface(metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                Text("Draft a new Mission")
                    .font(metrics.inspectorTitle)
                    .foregroundStyle(.primary)
                Text("Choose how closely the Director should stop, then describe the work in your own words.")
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Describe the mission below — your words choose the plan’s shape; the Director announces what it read, and you approve before anything runs.")
                .font(metrics.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            coordinatorDraftNoPlanStrip(metrics: metrics)

            VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    Label("Mission Policy", systemImage: "shield.lefthalf.filled")
                        .font(metrics.sectionTitle)
                    Text("Policy controls when the Director stops to ask; your directive still chooses the mission shape.")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: metrics.controlSpacing), count: 2), spacing: metrics.controlSpacing) {
                    ForEach(CoordinatorMissionPolicySnapshot.builtInPolicies.prefix(4)) { policy in
                        coordinatorDraftPolicyCard(policy, metrics: metrics)
                    }
                }

                coordinatorDraftPolicySummary(coordinatorEffectivePolicySnapshot(viewModel.snapshot.coordinatorRail), metrics: metrics)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func coordinatorDraftNoPlanStrip(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(alignment: .center, spacing: metrics.smallSpacing) {
            Image(systemName: "list.clipboard")
                .font(.system(size: metrics.smallIconSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("No plan yet — a plan will be drafted after your first directive.")
                .font(metrics.bodySemibold)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: metrics.controlSpacing)
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.14), lineWidth: 0.75)
        )
    }

    private func coordinatorConversationNoPlanStrip(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(alignment: .center, spacing: metrics.smallSpacing) {
            Image(systemName: "list.clipboard")
                .font(.system(size: metrics.smallIconSize, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                Text("No Mission Plan yet")
                    .font(metrics.bodySemibold)
                Text("Keep working in this conversation. The Mission Plan pane appears after the Director records a plan.")
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: metrics.controlSpacing)
            statusChip("No plan", color: .secondary, metrics: metrics)
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 0.75)
        )
    }

    private func coordinatorDraftPolicyCard(_ policy: CoordinatorMissionPolicySnapshot, metrics: CoordinatorVisualMetrics) -> some View {
        let isSelected = viewModel.selectedMissionPolicy.id == policy.id
        let tint = coordinatorPolicyTint(policy)
        let shape = RoundedRectangle(cornerRadius: CoordinatorTheme.Radius.card, style: .continuous)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: coordinatorPolicyIcon(policy))
                    .font(.system(size: metrics.smallIconSize, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(policy.name)
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: metrics.smallIconSize, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text(coordinatorPolicyHumanSentence(policy))
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                viewModel.selectedMissionPolicy = policy
                coordinatorDirectiveDraft = coordinatorPolicyTryText(policy)
                isCoordinatorComposerFocused = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: metrics.microIconSize, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("Try: \(coordinatorPolicyTryText(policy))")
                        .font(metrics.microMedium)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(
            shape.fill(
                isSelected
                    ? AgentModeSurfaceTheme.Palette.selectedWorkflowCardFill(Color.accentColor)
                    : AgentModeSurfaceTheme.Palette.workflowCardFill
            )
        )
        .overlay(
            shape.stroke(
                isSelected
                    ? AgentModeSurfaceTheme.Palette.selectedWorkflowCardStroke(Color.accentColor)
                    : AgentModeSurfaceTheme.Palette.workflowCardStroke,
                lineWidth: isSelected ? 1 : 0.5
            )
        )
        .contentShape(shape)
        .onTapGesture {
            viewModel.selectedMissionPolicy = policy
        }
    }

    private func coordinatorDraftPolicySummary(_ policy: CoordinatorMissionPolicySnapshot, metrics: CoordinatorVisualMetrics) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
            Text("\(coordinatorPolicyPaceText(policy)) · questions: \(coordinatorPolicyQuestionsText(policy)) · close: per drafted shape · always asks: \(coordinatorPolicyAlwaysAsksText(policy))")
                .font(metrics.microMedium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: metrics.controlSpacing)
            Text("Edit a copy")
                .font(metrics.microMedium)
                .foregroundStyle(.tertiary)
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(AgentModeSurfaceTheme.Palette.workflowCardFill)
        )
    }

    private func coordinatorPolicyHumanSentence(_ policy: CoordinatorMissionPolicySnapshot) -> String {
        switch policy.id {
        case "hands-off": "Approve once; it decides, logged."
        case "careful-writes": "Every step and every write stops for you."
        case "read-only": "Can’t write, so it can run — closes with a report."
        default: "Pauses at every step; decisions come to you."
        }
    }

    private func coordinatorPolicyTryText(_ policy: CoordinatorMissionPolicySnapshot) -> String {
        switch policy.id {
        case "hands-off": "overnight perf hunt — it decides, you read the receipt"
        case "careful-writes": "a PRD in slices — parallel chains, then a dependent slice after they consolidate"
        case "read-only": "investigation — and the directive names an issue, so watch the close-conflict note"
        default: "full supervision on a cross-repo change (2 PRs)"
        }
    }

    private func coordinatorPolicyPaceText(_ policy: CoordinatorMissionPolicySnapshot) -> String {
        policy.defaultPace == .auto ? "Auto" : "Step"
    }

    private func coordinatorPolicyAlwaysAsksText(_ policy: CoordinatorMissionPolicySnapshot) -> String {
        switch policy.id {
        case "careful-writes", "read-only": "plan, writes, merges"
        default: "plan, merges"
        }
    }

    private func coordinatorPolicyQuestionsText(_ policy: CoordinatorMissionPolicySnapshot) -> String {
        switch policy.resolvedAutonomy(for: .childAsk) {
        case .ask: "me"
        case .auto: "director"
        }
    }

    private func coordinatorPolicyIcon(_ policy: CoordinatorMissionPolicySnapshot) -> String {
        switch policy.id {
        case "hands-off": "forward.end.fill"
        case "careful-writes": "pencil.and.outline"
        case "read-only": "lock.doc"
        default: "shield.lefthalf.filled"
        }
    }

    private func coordinatorPolicyTint(_: CoordinatorMissionPolicySnapshot) -> Color {
        .secondary
    }

    private func missionPlanSummary(
        _ plan: CoordinatorMissionPlan,
        childCounts: CoordinatorModeCoordinatorChildCounts,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            HStack(spacing: metrics.smallSpacing) {
                Label("Mission Plan", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(metrics.sectionTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: metrics.controlSpacing)
                statusChip("r\(plan.revision)", color: .secondary, metrics: metrics)
                statusChip(plan.status.displayName, color: plan.status.tint, metrics: metrics)
            }

            if let objective = plan.objective {
                Text(objective)
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            missionStatusStrip(plan, childCounts: childCounts, metrics: metrics)
                .padding(.top, metrics.tightSpacing)

            missionIdleReadyLine(plan, metrics: metrics)

            missionShapePolicyDisclosure(plan, metrics: metrics)

            if plan.predecessorMissionID != nil || plan.predecessorTitle != nil || plan.predecessorSummary != nil {
                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    HStack(spacing: metrics.tightSpacing) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(metrics.micro)
                            .foregroundStyle(Color.accentColor)
                        Text("Follow-up to")
                            .font(metrics.microMedium)
                            .foregroundStyle(Color.accentColor)
                        Text(plan.predecessorTitle ?? plan.predecessorMissionID?.uuidString.prefix(8).description ?? "prior Mission")
                            .font(metrics.microMedium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    if let predecessorSummary = plan.predecessorSummary {
                        Text(predecessorSummary)
                            .font(metrics.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, metrics.tightSpacing)
            }
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12), lineWidth: 0.75)
        )
    }

    private func missionStatusStrip(
        _ plan: CoordinatorMissionPlan,
        childCounts _: CoordinatorModeCoordinatorChildCounts? = nil,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let projection = MissionPlanReadinessProjection(plan: plan)
        let blockedNodeCount = plan.nodes.count { $0.status == .blocked }
        let isOverCap = plan.policySnapshot.map { projection.runningNodeCount > $0.maxConcurrent } ?? false
        let readinessText: String = if plan.status.isTerminal {
            plan.nodes.isEmpty
                ? "no nodes"
                : "\(plan.nodes.count { $0.status.isTerminal })/\(plan.nodes.count) done"
        } else {
            [
                plan.policySnapshot.map { "running \(projection.runningNodeCount)/\($0.maxConcurrent)" } ?? "running \(projection.runningNodeCount)",
                "\(projection.readyCount) ready",
                "\(projection.waitingCount) waiting",
                blockedNodeCount > 0 ? "\(blockedNodeCount) blocked" : nil
            ]
            .compactMap(\.self)
            .joined(separator: " · ")
        }
        let readinessTint: Color = if isOverCap || blockedNodeCount > 0 {
            .red
        } else if plan.status == .completed {
            .green
        } else if plan.status == .stopped {
            .orange
        } else if projection.runningNodeCount > 0 {
            .blue
        } else {
            .secondary
        }
        let primaryStatus = CoordinatorMissionPresentationPolicy.primaryStatus(for: plan)
        let statusTitle: String = switch primaryStatus {
        case let .mission(status):
            status.displayName
        case let .approval(approval):
            approval.displayName
        }
        let statusTint: Color = switch primaryStatus {
        case let .mission(status):
            status.tint
        case .approval(.awaitingApproval):
            .red
        case .approval(.revisionRequested):
            .purple
        case .approval(.notRequired), .approval(.approved):
            .secondary
        }
        let userDecisionCount = plan.decisions.count(where: { $0.actor == .user })

        return HStack(spacing: metrics.smallSpacing) {
            Label("Mission", systemImage: "waveform.path.ecg")
                .font(metrics.microMedium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            statusChip(statusTitle, color: statusTint, metrics: metrics)
                .layoutPriority(3)
            Text(readinessText)
                .font(metrics.microMedium)
                .foregroundStyle(readinessTint)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(2)
            if userDecisionCount > 0 {
                statusChip("needs you \(userDecisionCount)", color: .red, metrics: metrics)
                    .layoutPriority(3)
            }
            if let policySnapshot = plan.policySnapshot {
                statusChip(coordinatorPolicyDisplayTitle(policySnapshot), color: .secondary, metrics: metrics)
                    .hoverTooltip(coordinatorPolicyEditDiffs(policySnapshot).isEmpty ? "Mission Policy · \(policySnapshot.name)" : coordinatorPolicyEditDiffs(policySnapshot).joined(separator: "\n"))
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.pendingPadding)
        .padding(.vertical, metrics.smallSpacing)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private func missionIdleReadyLine(_ plan: CoordinatorMissionPlan, metrics: CoordinatorVisualMetrics) -> some View {
        let projection = MissionPlanReadinessProjection(plan: plan)
        if plan.status == .running,
           projection.runningNodeCount == 0,
           projection.readyCount > 0
        {
            Label("Idle with \(projection.readyCount) ready node\(projection.readyCount == 1 ? "" : "s") — next launch is eligible unless the Director is paused elsewhere.", systemImage: "pause.circle")
                .font(metrics.micro)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func missionShapePolicyDisclosure(
        _ plan: CoordinatorMissionPlan,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        if plan.shapeSummary != nil || plan.policySnapshot != nil {
            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                if let shapeSummary = plan.shapeSummary {
                    HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                        Label("Shape · \(shapeSummary.displayName)", systemImage: "square.stack.3d.up")
                            .font(metrics.microMedium)
                            .foregroundStyle(.secondary)
                        Text(shapeSummary.id)
                            .font(metrics.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let reason = shapeSummary.reason {
                        Text(reason)
                            .font(metrics.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let namedClose = shapeSummary.namedClose {
                        Text("Close as: \(namedClose)")
                            .font(metrics.micro)
                            .foregroundStyle(.secondary)
                    }
                }

                if let policySnapshot = plan.policySnapshot {
                    HStack(spacing: metrics.smallSpacing) {
                        statusChip(coordinatorPolicyDisplayTitle(policySnapshot), color: .secondary, metrics: metrics)
                            .hoverTooltip(coordinatorPolicyEditDiffs(policySnapshot).isEmpty ? "Mission Policy · \(policySnapshot.name)" : coordinatorPolicyEditDiffs(policySnapshot).joined(separator: "\n"))
                        statusChip("cap \(policySnapshot.maxConcurrent)", color: .secondary, metrics: metrics)
                        statusChip(policySnapshot.defaultPace.rawValue, color: .secondary, metrics: metrics)
                    }
                    if let definitionOfDone = policySnapshot.definitionOfDone {
                        Label("Done: \(definitionOfDone)", systemImage: "checkmark.seal")
                            .font(metrics.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, metrics.pendingPadding)
            .padding(.vertical, metrics.smallSpacing)
            .background(
                RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.16))
            )
        }
    }

    private func missionPlanNodeOutline(_ plan: CoordinatorMissionPlan, metrics: CoordinatorVisualMetrics) -> some View {
        let projection = MissionPlanReadinessProjection(plan: plan)
        let nodesByWorkstream = Dictionary(grouping: plan.nodes, by: \.workstreamID)
        let knownWorkstreamIDs = Set(plan.workstreams.map(\.id))
        let orphanNodes = plan.nodes.filter { !knownWorkstreamIDs.contains($0.workstreamID) }
        let partTotal = plan.workstreams.count + (orphanNodes.isEmpty ? 0 : 1)

        return VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            ForEach(Array(plan.workstreams.enumerated()), id: \.element.id) { offset, workstream in
                missionPlanWorkstreamSection(
                    workstream: workstream,
                    nodes: nodesByWorkstream[workstream.id] ?? [],
                    plan: plan,
                    projection: projection,
                    partIndex: offset + 1,
                    partTotal: partTotal,
                    metrics: metrics
                )
            }

            if !orphanNodes.isEmpty {
                missionPlanWorkstreamSection(
                    workstream: nil,
                    nodes: orphanNodes,
                    plan: plan,
                    projection: projection,
                    partIndex: partTotal,
                    partTotal: partTotal,
                    metrics: metrics
                )
            }
        }
    }

    private func missionPlanWorkstreamOutline(
        _ workstream: CoordinatorMissionWorkstreamSummary,
        partIndex: Int,
        partTotal: Int,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            missionPlanWorkstreamHeader(
                workstream: workstream,
                nodes: [],
                partIndex: partIndex,
                partTotal: partTotal,
                metrics: metrics
            )
            Text("No nodes recorded yet.")
                .font(metrics.body)
                .foregroundStyle(.tertiary)
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinatorCardBackground(cornerRadius: metrics.cardCornerRadius)
    }

    private func missionPlanWorkstreamSection(
        workstream: CoordinatorMissionWorkstreamSummary?,
        nodes: [CoordinatorMissionPlanNode],
        plan: CoordinatorMissionPlan,
        projection: MissionPlanReadinessProjection,
        partIndex: Int,
        partTotal: Int,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            if let workstream {
                missionPlanWorkstreamHeader(
                    workstream: workstream,
                    nodes: nodes,
                    partIndex: partIndex,
                    partTotal: partTotal,
                    metrics: metrics
                )
            } else {
                missionPlanUnassignedHeader(
                    nodes: nodes,
                    partIndex: partIndex,
                    partTotal: partTotal,
                    metrics: metrics
                )
            }

            if nodes.isEmpty {
                Text("No nodes recorded yet.")
                    .font(metrics.body)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, metrics.tightSpacing)
            } else {
                ForEach(missionPlanDependencyBands(nodes: nodes, projection: projection)) { band in
                    missionPlanDependencyBandSection(
                        band,
                        workstream: workstream,
                        plan: plan,
                        projection: projection,
                        metrics: metrics
                    )
                }
            }
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinatorCardBackground(cornerRadius: metrics.cardCornerRadius)
    }

    private func missionPlanDependencyBands(
        nodes: [CoordinatorMissionPlanNode],
        projection: MissionPlanReadinessProjection
    ) -> [MissionPlanDependencyBand] {
        var nodesByKind: [MissionPlanDependencyBandKind: [CoordinatorMissionPlanNode]] = [:]
        for node in nodes {
            nodesByKind[missionPlanDependencyBandKind(for: node, projection: projection), default: []].append(node)
        }
        return MissionPlanDependencyBandKind.allCases.compactMap { kind in
            guard let bandNodes = nodesByKind[kind], !bandNodes.isEmpty else { return nil }
            return MissionPlanDependencyBand(kind: kind, nodes: bandNodes)
        }
    }

    private func missionPlanDependencyBandKind(
        for node: CoordinatorMissionPlanNode,
        projection: MissionPlanReadinessProjection
    ) -> MissionPlanDependencyBandKind {
        switch node.status {
        case .running:
            .running
        case .completed, .skipped, .cancelled:
            .done
        case .blocked:
            .blocked
        case .pending:
            projection.isReady(node) ? .ready : .waiting
        }
    }

    private func missionPlanDependencyBandSection(
        _ band: MissionPlanDependencyBand,
        workstream: CoordinatorMissionWorkstreamSummary?,
        plan: CoordinatorMissionPlan,
        projection: MissionPlanReadinessProjection,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                Label(band.kind.title, systemImage: band.kind.systemImage)
                    .font(metrics.microMedium)
                    .foregroundStyle(band.kind.tint)
                    .lineLimit(1)
                Text("\(band.nodes.count) node\(band.nodes.count == 1 ? "" : "s")")
                    .font(metrics.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: metrics.controlSpacing)
                if band.kind == .ready,
                   !projection.capacityAvailable,
                   band.nodes.contains(where: \.executionPolicy.usesStartCapacity)
                {
                    statusChip("held by cap", color: .orange, metrics: metrics)
                }
            }

            HStack(alignment: .top, spacing: metrics.smallSpacing) {
                Rectangle()
                    .fill(band.kind.tint.opacity(0.20))
                    .frame(width: 2)
                    .padding(.vertical, metrics.tightSpacing)
                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    ForEach(band.nodes) { node in
                        missionPlanNodeRow(
                            node,
                            workstream: workstream,
                            plan: plan,
                            projection: projection,
                            metrics: metrics
                        )
                    }
                }
            }
        }
    }

    private func missionPlanWorkstreamHeader(
        workstream: CoordinatorMissionWorkstreamSummary,
        nodes: [CoordinatorMissionPlanNode],
        partIndex: Int,
        partTotal: Int,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                Text("Part \(partIndex) · \(workstream.title)")
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let role = workstream.role {
                    Text(role)
                        .font(metrics.microMedium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: metrics.controlSpacing)
                statusChip("\(missionPlanCompletedNodeCount(nodes))/\(nodes.count) done", color: missionPlanCompletedNodeCount(nodes) == nodes.count && !nodes.isEmpty ? .green : .secondary, metrics: metrics)
                statusChip("\(partIndex)/\(partTotal)", color: .secondary, metrics: metrics)
                statusChip(workstream.defaultPolicy.displayName, color: .secondary, metrics: metrics)
                statusChip(workstream.worktreeStrategy.mode.displayName, color: .secondary, metrics: metrics)
            }

            HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                if let primarySessionID = workstream.primarySessionID {
                    statusChip("Primary \(primarySessionID.uuidString.prefix(8))", color: .green, metrics: metrics)
                }
                if let baseRef = workstream.worktreeStrategy.baseRef {
                    statusChip("Base \(baseRef)", color: .secondary, metrics: metrics)
                }
                if !workstream.purpose.isEmpty {
                    Text(workstream.purpose)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func missionPlanUnassignedHeader(
        nodes: [CoordinatorMissionPlanNode],
        partIndex: Int,
        partTotal: Int,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
            Label("Part \(partIndex) · Unassigned nodes", systemImage: "questionmark.square.dashed")
                .font(metrics.bodySemibold)
                .foregroundStyle(.secondary)
            Spacer(minLength: metrics.controlSpacing)
            statusChip("\(missionPlanCompletedNodeCount(nodes))/\(nodes.count) done", color: missionPlanCompletedNodeCount(nodes) == nodes.count && !nodes.isEmpty ? .green : .secondary, metrics: metrics)
            statusChip("\(partIndex)/\(partTotal)", color: .secondary, metrics: metrics)
        }
    }

    private func missionPlanCompletedNodeCount(_ nodes: [CoordinatorMissionPlanNode]) -> Int {
        nodes.count { $0.status == .completed }
    }

    private func missionPlanNodeRow(
        _ node: CoordinatorMissionPlanNode,
        workstream: CoordinatorMissionWorkstreamSummary?,
        plan: CoordinatorMissionPlan,
        projection: MissionPlanReadinessProjection,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                Image(systemName: node.status.systemImage)
                    .font(.system(size: metrics.smallIconSize, weight: .semibold))
                    .foregroundStyle(node.status.tint)
                    .frame(width: metrics.smallIconSize)
                Text(node.title)
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: metrics.controlSpacing)
                statusChip(
                    missionPlanNodeEligibilityText(node, plan: plan, projection: projection),
                    color: missionPlanNodeEligibilityTint(node, projection: projection),
                    metrics: metrics
                )
            }

            missionPlanNodeEligibilityLine(node, plan: plan, projection: projection, metrics: metrics)

            HStack(spacing: metrics.smallSpacing) {
                if let workflowHint = node.workflowHint {
                    workflowBadge(workflowHint, metrics: metrics)
                }
                statusChip(missionPlanNodeRouteLabel(node, workstream: workstream), color: missionPlanNodeRouteTint(node, workstream: workstream), metrics: metrics)
                statusChip(node.executionPolicy.displayName, color: .secondary, metrics: metrics)
                if let role = node.role {
                    statusChip(role, color: .secondary, metrics: metrics)
                }
                if let boundSessionID = node.boundSessionID {
                    statusChip("Bound \(shortID(boundSessionID))", color: .green, metrics: metrics)
                }
                if node.boundInteractionID != nil {
                    statusChip("Interaction", color: .orange, metrics: metrics)
                }
            }

            if let detail = node.detail {
                Text(detail)
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let doneCriteria = node.doneCriteria {
                Label("Done when: \(doneCriteria)", systemImage: "checkmark.seal")
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let completionEvidence = node.completionEvidence {
                Label("Evidence: \(completionEvidence)", systemImage: "doc.text.magnifyingglass")
                    .font(metrics.micro)
                    .foregroundStyle(node.status == .completed ? .green : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(metrics.listRowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinatorCardBackground(
            cornerRadius: metrics.cardCornerRadius,
            isSelected: node.id == selectedPlanNodeID,
            isHovered: node.id == hoveredPlanNodeID,
            fillOpacity: CoordinatorStyle.listRowFillOpacity,
            strokeOpacity: 0.08
        )
        .selectedCoordinatorObjectIndicator(isSelected: node.id == selectedPlanNodeID, cornerRadius: metrics.cardCornerRadius)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPlanNodeID = node.id
        }
        .onHover { hovering in
            hoveredPlanNodeID = hovering ? node.id : (hoveredPlanNodeID == node.id ? nil : hoveredPlanNodeID)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan node \(node.title)")
    }

    private func missionPlanNodeEligibilityText(
        _ node: CoordinatorMissionPlanNode,
        plan: CoordinatorMissionPlan,
        projection: MissionPlanReadinessProjection
    ) -> String {
        switch node.status {
        case .completed:
            return "Done"
        case .running:
            return "Running"
        case .blocked:
            return "Blocked"
        case .skipped:
            return "Skipped"
        case .cancelled:
            return "Cancelled"
        case .pending:
            if projection.isHeldByCap(node) {
                return "Ready · held by cap"
            }
            if projection.isReady(node) {
                return "Ready"
            }
            return missionPlanDependencySummary(node, plan: plan, projection: projection)
        }
    }

    private func missionPlanNodeEligibilityTint(
        _ node: CoordinatorMissionPlanNode,
        projection: MissionPlanReadinessProjection
    ) -> Color {
        switch node.status {
        case .completed:
            return .green
        case .running:
            return .blue
        case .blocked, .cancelled:
            return .red
        case .skipped:
            return .orange
        case .pending:
            if projection.isHeldByCap(node) { return .orange }
            return projection.isReady(node) ? .green : .secondary
        }
    }

    private func missionPlanNodeEligibilityLine(
        _ node: CoordinatorMissionPlanNode,
        plan: CoordinatorMissionPlan,
        projection: MissionPlanReadinessProjection,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        Label(
            missionPlanNodeEligibilityDetail(node, plan: plan, projection: projection),
            systemImage: projection.isHeldByCap(node) ? "pause.circle" : node.status.systemImage
        )
        .font(metrics.micro)
        .foregroundStyle(missionPlanNodeEligibilityTint(node, projection: projection))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func missionPlanNodeEligibilityDetail(
        _ node: CoordinatorMissionPlanNode,
        plan: CoordinatorMissionPlan,
        projection: MissionPlanReadinessProjection
    ) -> String {
        switch node.status {
        case .completed:
            return "Done"
        case .running:
            return "Running"
        case .blocked:
            return projection.dependenciesSatisfied(for: node) ? "Blocked · dependencies clear" : missionPlanDependencySummary(node, plan: plan, projection: projection)
        case .skipped:
            return "Skipped"
        case .cancelled:
            return "Cancelled"
        case .pending:
            if projection.isHeldByCap(node) {
                return "Ready · held by cap (running \(projection.runningNodeCount)/\(projection.maxConcurrent))"
            }
            if projection.isReady(node) {
                return "Ready"
            }
            return missionPlanDependencySummary(node, plan: plan, projection: projection)
        }
    }

    private func missionPlanDependencySummary(
        _ node: CoordinatorMissionPlanNode,
        plan: CoordinatorMissionPlan,
        projection: MissionPlanReadinessProjection
    ) -> String {
        guard !node.dependsOn.isEmpty else {
            return projection.dependenciesSatisfied(for: node) ? "Ready" : "Waiting"
        }
        let parts = node.dependsOn.prefix(3).map { dependencyID in
            let title = dependencyTitle(dependencyID, in: plan)
            let marker = projection.nodesByID[dependencyID]?.status == .completed ? "✓" : "…"
            return "\(title) \(marker)"
        }
        let suffix = node.dependsOn.count > parts.count ? " · +\(node.dependsOn.count - parts.count)" : ""
        return "Waiting on \(parts.joined(separator: " · "))\(suffix)"
    }

    private func missionPlanNodeRouteLabel(
        _ node: CoordinatorMissionPlanNode,
        workstream: CoordinatorMissionWorkstreamSummary?
    ) -> String {
        if let boundSessionID = node.boundSessionID, boundSessionID == workstream?.primarySessionID {
            return "Reuse primary"
        }
        switch node.executionPolicy {
        case .steerPrimary:
            return "Reuse primary"
        case .freshWorktree:
            return "Fresh worktree"
        case .freshReadOnlyChild:
            return "Read-only child"
        case .freshSiblingOnSameWorktree:
            return "Fresh sibling"
        case .coordinatorOnly:
            return "Director"
        case .planCritique:
            return "Critique"
        case .askUser:
            return "Needs you"
        }
    }

    private func missionPlanNodeRouteTint(
        _ node: CoordinatorMissionPlanNode,
        workstream: CoordinatorMissionWorkstreamSummary?
    ) -> Color {
        if let boundSessionID = node.boundSessionID, boundSessionID == workstream?.primarySessionID {
            return .green
        }
        switch node.executionPolicy {
        case .steerPrimary:
            return .green
        case .freshWorktree, .freshReadOnlyChild, .freshSiblingOnSameWorktree, .planCritique, .coordinatorOnly:
            return .secondary
        case .askUser:
            return .orange
        }
    }

    private func missionPlanEmptyState(title: String, subtitle: String, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(spacing: metrics.controlSpacing) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: metrics.emptyStateIconSize, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(metrics.headerTitle)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(metrics.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(metrics.outerPadding)
    }

    private func boardColumnWidth(
        for sections: [CoordinatorModeStatusSection],
        availableWidth: CGFloat,
        metrics: CoordinatorVisualMetrics
    ) -> CGFloat {
        let count = max(CGFloat(sections.count), 1)
        guard sections.count <= 3 else { return metrics.boardColumnWidth }
        let horizontalPadding = metrics.outerPadding * 2
        let columnSpacing = metrics.boardColumnSpacing * max(count - 1, 0)
        let usableWidth = max(availableWidth - horizontalPadding - columnSpacing, 0)
        let fittedWidth = floor(usableWidth / count)
        return max(metrics.boardColumnCompactWidth, fittedWidth)
    }

    private func visibleBoardSections(
        from sections: [CoordinatorModeStatusSection],
        boardScope: CoordinatorModeBoardScope
    ) -> [CoordinatorModeStatusSection] {
        switch boardScope {
        case .allAgents:
            return sections
        case .coordinatorFleet:
            let defaultGroups: Set<CoordinatorModeStatusGroup> = [.needsYou, .working, .done]
            return sections.filter { section in
                !section.rows.isEmpty || defaultGroups.contains(section.group)
            }
        }
    }

    private func boardAnimationKey(for sections: [CoordinatorModeStatusSection]) -> [String] {
        sections.flatMap { section in
            section.rows.map { "\(section.group.rawValue):\($0.id.uuidString)" }
        }
    }

    private func boardColumn(
        section: CoordinatorModeStatusSection,
        boardScope: CoordinatorModeBoardScope,
        metrics: CoordinatorVisualMetrics,
        minHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.columnSpacing) {
            HStack(spacing: metrics.smallSpacing) {
                Circle()
                    .fill(section.group.accentColor.opacity(section.rows.isEmpty ? 0.55 : 0.9))
                    .frame(width: metrics.statusDotSize, height: metrics.statusDotSize)

                Text(section.group.displayName)
                    .font(metrics.sectionTitle)
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(section.rows.count)")
                    .font(metrics.chip)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, metrics.miniPillHorizontalPadding)
                    .padding(.vertical, metrics.miniPillVerticalPadding)
                    .background(Capsule().fill(section.group.accentColor.opacity(section.rows.isEmpty ? 0.05 : 0.10)))
                    .overlay(
                        Capsule().stroke(section.group.accentColor.opacity(section.rows.isEmpty ? 0.08 : 0.16), lineWidth: 0.5)
                    )
            }
            .padding(.bottom, metrics.tightSpacing)

            if section.rows.isEmpty {
                Text("No sessions")
                    .font(metrics.micro)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, metrics.emptyColumnPadding)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        clearSelectedRow()
                    }
            } else {
                ForEach(section.rows) { row in
                    sessionCard(row, boardScope: boardScope, metrics: metrics)
                }
            }

            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    clearSelectedRow()
                }
        }
        .padding(metrics.columnPadding)
        .frame(minHeight: minHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: metrics.columnCornerRadius, style: .continuous)
                .fill(section.group.columnTint(isEmpty: section.rows.isEmpty))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.columnCornerRadius, style: .continuous)
                .stroke(section.group.laneStroke(isEmpty: section.rows.isEmpty), lineWidth: 0.75)
        )
    }

    private func sessionCard(
        _ row: CoordinatorModeRow,
        boardScope: CoordinatorModeBoardScope,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.sessionCardInnerSpacing) {
            HStack(alignment: .top) {
                if let worktree = row.workstream {
                    worktreeMarker(worktree, metrics: metrics)
                        .padding(.top, 3)
                }

                Text(row.title)
                    .font(metrics.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: metrics.controlSpacing)
            }

            rowMetadata(row, boardScope: boardScope, metrics: metrics)

            if let nextAction = row.workstreamSummary?.nextAction {
                workstreamNextActionHint(nextAction, metrics: metrics)
            }
        }
        .padding(metrics.sessionCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinatorCardBackground(
            cornerRadius: metrics.cardCornerRadius,
            isSelected: row.id == selectedRowID,
            isHovered: row.id == hoveredRowID
        )
        .selectedCoordinatorObjectIndicator(isSelected: row.id == selectedRowID, cornerRadius: metrics.cardCornerRadius)
        .overlay(alignment: .leading) {
            selectedParentEmphasis(row, metrics: metrics)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRowID = row.id
            isInspectorVisible = true
        }
        .onHover { hovering in
            hoveredRowID = hovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delegated session \(row.title)")
    }

    private func listView(sections: [CoordinatorModeStatusSection], metrics: CoordinatorVisualMetrics) -> some View {
        let rows = sortedListRows(from: sections)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: metrics.listRowSpacing) {
                if rows.isEmpty {
                    Text("No matching sessions")
                        .font(metrics.bodyMedium)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(metrics.outerPadding)
                } else {
                    ForEach(rows) { row in
                        listRow(row, metrics: metrics)
                    }
                }
            }
            .padding(metrics.outerPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func sortedListRows(from sections: [CoordinatorModeStatusSection]) -> [CoordinatorModeRow] {
        sections.flatMap(\.rows).sorted { lhs, rhs in
            switch viewModel.sortMode {
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
            let titleCompare = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleCompare != .orderedSame { return titleCompare == .orderedAscending }
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
    }

    private func listRow(_ row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.listColumnSpacing) {
            statusChip(row.runState.displayName, color: row.statusGroup.accentColor, metrics: metrics)
                .frame(width: metrics.listStateColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                Text(row.title)
                    .font(metrics.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let parentCoordinator = row.parentCoordinator {
                    parentCoordinatorBadge(parentCoordinator, metrics: metrics)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if let identity = listIdentityText(for: row) {
                Text(identity)
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: metrics.listIdentityColumnWidth, alignment: .leading)
            } else {
                Color.clear
                    .frame(width: metrics.listIdentityColumnWidth)
            }

            worktreeListCell(for: row, metrics: metrics)
                .frame(width: metrics.listWorkstreamColumnWidth, alignment: .leading)

            Text(row.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(metrics.body)
                .foregroundStyle(.tertiary)
                .frame(width: metrics.listUpdatedColumnWidth, alignment: .trailing)

            openAgentChatButton(route: row.openAgentChatRoute, title: "Open", metrics: metrics)
                .frame(width: metrics.listOpenColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, metrics.listRowVerticalPadding)
        .padding(.horizontal, metrics.listRowHorizontalPadding)
        .coordinatorCardBackground(
            cornerRadius: metrics.cardCornerRadius,
            isSelected: row.id == selectedRowID,
            isHovered: row.id == hoveredRowID,
            fillOpacity: CoordinatorStyle.listRowFillOpacity,
            strokeOpacity: 0.08
        )
        .selectedCoordinatorObjectIndicator(isSelected: row.id == selectedRowID, cornerRadius: metrics.cardCornerRadius)
        .overlay(alignment: .leading) {
            selectedParentEmphasis(row, metrics: metrics)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRowID = row.id
            isInspectorVisible = true
        }
        .onHover { hovering in
            hoveredRowID = hovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
        }
    }

    private func listIdentityText(for row: CoordinatorModeRow) -> String? {
        var parts: [String] = []
        if let providerName = row.providerName {
            parts.append(providerName)
        }
        if let modelName = row.modelName, modelName != row.providerName {
            parts.append(modelName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func listWorkstreamText(for row: CoordinatorModeRow) -> String {
        guard let workstream = row.workstream else {
            return row.isPersistedOnly ? "Persisted" : "Current window"
        }
        if let branch = workstream.branch, branch != workstream.label {
            return "\(workstream.label) · \(branch)"
        }
        return workstream.label
    }

    private func worktreeListCell(for row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        Group {
            if let worktree = row.workstream {
                worktreeLabel(worktree, metrics: metrics)
            } else {
                Text(listWorkstreamText(for: row))
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func inspector(target: InspectorTarget, metrics: CoordinatorVisualMetrics) -> some View {
        switch target {
        case let .row(row):
            inspector(row: row, metrics: metrics)
        }
    }

    private func inspector(row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(spacing: 0) {
            inspectorSheetHandle(isExpanded: true, metrics: metrics) {
                isInspectorVisible = false
            }
            .padding(.top, metrics.tightSpacing)

            inspectorHeader(row: row, metrics: metrics)
                .padding(.horizontal, metrics.outerPadding)
                .padding(.top, metrics.controlSpacing)
                .padding(.bottom, metrics.controlSpacing)

            Divider()
                .opacity(0.28)

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    if let workstream = row.workstreamSummary {
                        workstreamInspector(workstream, row: row, metrics: metrics)
                    }

                    inspectorGroup("Status", metrics: metrics) {
                        keyValue("Group", row.statusGroup.displayName, metrics: metrics)
                        keyValue("Run state", row.runState.displayName, metrics: metrics)
                        if let report = row.statusReport {
                            keyValue("Snapshot state", report.status.displayLabel, metrics: metrics)
                            if let statusText = report.statusText {
                                keyValue("Status text", statusText, metrics: metrics)
                            }
                            if let failureReason = report.failureReason {
                                keyValue("Failure reason", failureReason.displayLabel, metrics: metrics)
                            }
                        }
                        keyValue("Updated", row.updatedAt.formatted(date: .abbreviated, time: .shortened), metrics: metrics)
                        keyValue("Source", row.isPersistedOnly ? "Persisted metadata" : "Current window live state", metrics: metrics)
                    }

                    inspectorGroup("Session", metrics: metrics) {
                        keyValue("Origin", row.origin.displayName, metrics: metrics)
                        keyValue("Provider", row.providerName ?? "Unknown", metrics: metrics)
                        keyValue("Model", row.modelName ?? "Unknown", metrics: metrics)
                        keyValue("Children", "\(row.childSessionIDs.count)", metrics: metrics)
                        keyValue("MCP originated", row.isMCPOriginated ? "Yes" : "No", metrics: metrics)
                        if let parentCoordinator = row.parentCoordinator {
                            keyValue("Director", parentCoordinator.title, metrics: metrics)
                        }
                        if let workflow = row.workflow {
                            keyValue("Workflow", workflow.displayName, metrics: metrics)
                        }
                    }

                    if let merge = row.mergeAttention {
                        inspectorGroup("Merge attention", metrics: metrics) {
                            keyValue("Status", merge.status.rawValue, metrics: metrics)
                            keyValue("Conflicts", "\(merge.conflictFileCount)", metrics: metrics)
                        }
                    }

                    if let pending = row.pendingInteraction {
                        inspectorGroup("Pending interaction", metrics: metrics) {
                            keyValue("Kind", pending.kind.displayLabel, metrics: metrics)
                            if let title = pending.title {
                                keyValue("Title", title, metrics: metrics)
                            }
                            if let prompt = pending.prompt {
                                Text(prompt)
                                    .font(metrics.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(pending.details, id: \.label) { detail in
                                keyValue(detail.label, detail.value, metrics: metrics)
                            }
                        }
                    }

                    if let assistantPreview = row.statusReport?.assistantPreview {
                        inspectorGroup("Recent assistant output", metrics: metrics) {
                            Text(assistantPreview)
                                .font(metrics.body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let terminalOutput = row.statusReport?.terminalOutput {
                        inspectorGroup("Terminal output", metrics: metrics) {
                            Text(terminalOutput)
                                .font(metrics.body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(metrics.outerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .opacity(0.28)

            inspectorChildComposer(row: row, metrics: metrics)
                .padding(metrics.outerPadding)
        }
    }

    private func planNodeInspector(
        node: CoordinatorMissionPlanNode,
        workstream: CoordinatorMissionWorkstreamSummary?,
        plan: CoordinatorMissionPlan,
        boundRow: CoordinatorModeRow?,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let nodeEvents = plan.events
            .filter { $0.nodeID == node.id }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.timestamp > rhs.timestamp
            }
        let routingDecisions = plan.routingDecisions
            .filter { decision in
                decision.nodeID == node.id
                    || (decision.nodeID == nil && decision.workstreamID == node.workstreamID)
                    || (node.boundSessionID != nil && decision.sessionID == node.boundSessionID)
            }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.timestamp > rhs.timestamp
            }
        let workflowMismatch = missionPlanWorkflowMismatch(node: node, boundRow: boundRow)

        return VStack(spacing: 0) {
            inspectorSheetHandle(isExpanded: true, metrics: metrics) {
                isInspectorVisible = false
            }
            .padding(.top, metrics.tightSpacing)

            planNodeInspectorHeader(node: node, boundRow: boundRow, metrics: metrics)
                .padding(.horizontal, metrics.outerPadding)
                .padding(.top, metrics.controlSpacing)
                .padding(.bottom, metrics.controlSpacing)

            Divider()
                .opacity(0.28)

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    inspectorGroup("Plan Node", metrics: metrics) {
                        keyValue("Status", node.status.displayName, metrics: metrics)
                        if let workflowHint = node.workflowHint {
                            keyValue("Workflow", workflowHint.name, metrics: metrics)
                        }
                        keyValue("Policy", node.executionPolicy.displayName, metrics: metrics)
                        if let role = node.role {
                            keyValue("Role", role, metrics: metrics)
                        }
                        if let detail = node.detail {
                            Text(detail)
                                .font(metrics.body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let doneCriteria = node.doneCriteria {
                            keyValue("Done criteria", doneCriteria, metrics: metrics)
                        }
                        if let completionEvidence = node.completionEvidence {
                            keyValue("Completion evidence", completionEvidence, metrics: metrics)
                        }
                    }

                    if let workstream {
                        inspectorGroup("Workstream", metrics: metrics) {
                            keyValue("Title", workstream.title, metrics: metrics)
                            if !workstream.purpose.isEmpty {
                                keyValue("Purpose", workstream.purpose, metrics: metrics)
                            }
                            if let role = workstream.role {
                                keyValue("Role", role, metrics: metrics)
                            }
                            keyValue("Default policy", workstream.defaultPolicy.displayName, metrics: metrics)
                            keyValue("Worktree strategy", workstream.worktreeStrategy.mode.displayName, metrics: metrics)
                            if let baseRef = workstream.worktreeStrategy.baseRef {
                                keyValue("Worktree base", baseRef, metrics: metrics)
                            }
                            if let baseReason = workstream.worktreeStrategy.baseReason {
                                keyValue("Base reason", baseReason, metrics: metrics)
                            }
                            if let reason = workstream.worktreeStrategy.reason {
                                keyValue("Strategy reason", reason, metrics: metrics)
                            }
                            if let worktreeID = workstream.worktreeID {
                                keyValue("Declared worktree", worktreeID, metrics: metrics)
                            }
                        }
                    }

                    inspectorGroup("Links", metrics: metrics) {
                        if node.dependsOn.isEmpty {
                            keyValue("Dependencies", "None", metrics: metrics)
                        } else {
                            ForEach(node.dependsOn, id: \.self) { dependencyID in
                                keyValue("Depends on", dependencyTitle(dependencyID, in: plan), metrics: metrics)
                            }
                        }
                        if let sessionID = node.boundSessionID {
                            keyValue("Bound session", shortID(sessionID), metrics: metrics)
                        }
                        if let interactionID = node.boundInteractionID {
                            keyValue("Interaction", shortID(interactionID), metrics: metrics)
                        }
                    }

                    if let boundRow {
                        inspectorGroup("Bound Session", metrics: metrics) {
                            keyValue("Title", boundRow.title, metrics: metrics)
                            keyValue("Run state", boundRow.runState.displayName, metrics: metrics)
                            if let workflow = boundRow.workflow {
                                keyValue("Workflow", workflow.displayName, metrics: metrics)
                            }
                            if let worktree = boundRow.workstream {
                                keyValue("Worktree", metrics: metrics) {
                                    worktreeLabel(worktree, metrics: metrics)
                                }
                                if let branch = worktree.branch {
                                    keyValue("Branch", branch, metrics: metrics)
                                }
                            }
                        }
                    }

                    if let workflowMismatch {
                        inspectorGroup("Workflow Mismatch", metrics: metrics) {
                            Label(workflowMismatch, systemImage: "exclamationmark.triangle.fill")
                                .font(metrics.body)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !routingDecisions.isEmpty {
                        inspectorGroup("Routing Decisions", metrics: metrics) {
                            ForEach(routingDecisions.prefix(5)) { decision in
                                routingDecisionRow(decision, metrics: metrics)
                            }
                        }
                    }

                    if !nodeEvents.isEmpty {
                        inspectorGroup("Recent Events", metrics: metrics) {
                            ForEach(nodeEvents.prefix(5)) { event in
                                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                                    HStack(spacing: metrics.smallSpacing) {
                                        Text(event.kind.displayName)
                                            .font(metrics.bodyMedium)
                                        Spacer(minLength: metrics.controlSpacing)
                                        Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                                            .font(metrics.micro)
                                            .foregroundStyle(.tertiary)
                                    }
                                    if let summary = event.summary {
                                        Text(summary)
                                            .font(metrics.body)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, metrics.tightSpacing)
                            }
                        }
                    }
                }
                .padding(metrics.outerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func routingDecisionRow(
        _ decision: CoordinatorMissionRoutingDecision,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            HStack(spacing: metrics.smallSpacing) {
                Text(decision.decision.displayName)
                    .font(metrics.bodyMedium)
                Spacer(minLength: metrics.controlSpacing)
                Text(decision.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(metrics.micro)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: metrics.smallSpacing) {
                statusChip(decision.operation.displayName, color: .secondary, metrics: metrics)
                if let workflowName = decision.workflowName {
                    statusChip(workflowName, color: .secondary, metrics: metrics)
                }
                if let modelID = decision.modelID {
                    statusChip(modelID, color: .secondary, metrics: metrics)
                }
            }
            Text(decision.reason)
                .font(metrics.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let contextSummary = decision.contextSummary {
                Text(contextSummary)
                    .font(metrics.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, metrics.tightSpacing)
    }

    private func inspectorHeader(row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.controlSpacing) {
            HStack(spacing: metrics.controlSpacing) {
                Text("Inspector")
                    .font(metrics.bodyMedium)
                    .coordinatorSidebarHeaderPill(cornerRadius: metrics.headerPillCornerRadius)

                Spacer(minLength: metrics.controlSpacing)

                inspectorOpenAgentButton(route: row.openAgentChatRoute, metrics: metrics)
            }

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                Text(row.title)
                    .font(metrics.inspectorTitle)
                    .lineLimit(3)

                HStack(spacing: metrics.smallSpacing) {
                    Text(inspectorObjectSubtitle(for: row))
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let workflow = row.workflow {
                        workflowBadge(workflow, metrics: metrics)
                    }
                }
            }
        }
    }

    private func planNodeInspectorHeader(
        node: CoordinatorMissionPlanNode,
        boundRow: CoordinatorModeRow?,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.controlSpacing) {
            HStack(spacing: metrics.controlSpacing) {
                Text("Plan Inspector")
                    .font(metrics.bodyMedium)
                    .coordinatorSidebarHeaderPill(cornerRadius: metrics.headerPillCornerRadius)

                Spacer(minLength: metrics.controlSpacing)

                if let boundRow {
                    inspectorOpenAgentButton(route: boundRow.openAgentChatRoute, metrics: metrics)
                }
            }

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                Text(node.title)
                    .font(metrics.inspectorTitle)
                    .lineLimit(3)

                HStack(spacing: metrics.smallSpacing) {
                    Label(node.status.displayName, systemImage: node.status.systemImage)
                        .font(metrics.micro)
                        .foregroundStyle(node.status.tint)
                    if let workflowHint = node.workflowHint {
                        workflowBadge(workflowHint, metrics: metrics)
                    }
                    statusChip(node.executionPolicy.displayName, color: .secondary, metrics: metrics)
                }
            }
        }
    }

    private func collapsedInspectorHandle(target _: InspectorTarget, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.28)

            inspectorSheetHandle(isExpanded: false, metrics: metrics) {
                isInspectorVisible = true
            }
        }
        .background(.regularMaterial)
    }

    private func inspectorSheetHandle(
        isExpanded: Bool,
        metrics: CoordinatorVisualMetrics,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: metrics.inspectorHandleWidth, height: metrics.inspectorHandleHeight)
                .frame(maxWidth: .infinity)
                .padding(.vertical, metrics.inspectorHandleVerticalPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip(isExpanded ? "Hide Inspector" : "Show Inspector")
        .accessibilityLabel(isExpanded ? "Hide Inspector" : "Show Inspector")
    }

    private func coordinatorConversation(_ rail: CoordinatorModeCoordinatorRail, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: metrics.controlSpacing) {
                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    Text(coordinatorConversationTitle(rail))
                        .font(metrics.inspectorTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(coordinatorConversationSubtitle(rail))
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: metrics.controlSpacing)
                if rail.missionPlan != nil, !isMissionPlanPaneVisible {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isMissionPlanPaneVisible = true
                        }
                    } label: {
                        Label("Mission Plan", systemImage: "sidebar.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.link)
                    .font(metrics.microMedium)
                    .hoverTooltip("Show the Mission Plan pane.")
                }
            }
            .padding(.horizontal, metrics.outerPadding)
            .padding(.vertical, metrics.headerPadding)
            .background(CoordinatorTheme.Palette.windowBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CoordinatorTheme.Palette.hairline)
                    .frame(height: 0.5)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
                    switch CoordinatorMissionPresentationPolicy.conversationMode(for: rail.missionPlan) {
                    case .noPlan:
                        if rail.state == .selected {
                            coordinatorConversationNoPlanStrip(metrics: metrics)
                        }
                    case .planReference:
                        if let missionPlan = rail.missionPlan {
                            coordinatorMissionPlanReferenceCard(
                                missionPlan,
                                missionTemplate: rail.missionTemplate,
                                metrics: metrics
                            )
                        }
                    case let .terminalSummary(status):
                        if let missionPlan = rail.missionPlan {
                            coordinatorTerminalMissionSummaryCard(missionPlan, status: status, metrics: metrics)
                        }
                    }

                    if rail.missionPlan?.status.isTerminal == true {
                        coordinatorTerminalTranscriptDisclosure(
                            planID: rail.missionPlan?.id,
                            entries: viewModel.railTranscriptEntries,
                            metrics: metrics
                        )
                    } else if viewModel.railTranscriptEntries.isEmpty, rail.missionPlan == nil {
                        coordinatorEmptyConversation(rail, metrics: metrics)
                    } else {
                        ForEach(viewModel.railTranscriptEntries) { entry in
                            coordinatorConversationEntry(entry, metrics: metrics)
                        }
                    }
                }
                .padding(.horizontal, metrics.cardPadding)
                .padding(.vertical, metrics.smallSpacing)
            }
            .frame(minHeight: metrics.conversationMinHeight)

            coordinatorContinuationControls(rail, metrics: metrics)

            Divider()
                .opacity(0.45)

            coordinatorComposer(rail, metrics: metrics)
                .padding(metrics.cardPadding)
                .background(CoordinatorTheme.Palette.panelBackground)
        }
        .background(CoordinatorTheme.Palette.windowBackground)
    }

    private func coordinatorConversationTitle(_ rail: CoordinatorModeCoordinatorRail) -> String {
        if let title = rail.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let objective = rail.missionPlan?.objective?.trimmingCharacters(in: .whitespacesAndNewlines), !objective.isEmpty {
            return objective
        }
        return "New Mission"
    }

    private func coordinatorConversationSubtitle(_ rail: CoordinatorModeCoordinatorRail) -> String {
        var parts: [String] = []
        if let status = rail.missionPlan?.status.displayName {
            parts.append(status)
        } else if rail.state == .chooseCoordinator {
            parts.append("Draft Mission")
        }
        if let source = rail.selectionSource?.displayName {
            parts.append(source)
        }
        if rail.childCounts.total > 0 {
            parts.append("\(rail.childCounts.total) delegated")
        }
        if rail.isPinned {
            parts.append("Pinned")
        }
        if rail.isPersistedOnly {
            parts.append("Archived")
        } else if rail.isLiveInCurrentWindow,
                  CoordinatorMissionPresentationPolicy.shouldShowLiveBadge(for: rail.missionPlan)
        {
            parts.append("Live")
        }
        return parts.isEmpty ? "Director Mission" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func coordinatorContinuationControls(
        _ rail: CoordinatorModeCoordinatorRail,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        switch activeCoordinatorCheckpoint(for: rail) {
        case let .pendingInteraction(pendingInteraction):
            if let pending = coordinatorPendingAskUserState(for: pendingInteraction) {
                coordinatorCompactCheckpointCard(
                    pending: pending,
                    badgeTitle: "Director question",
                    badgeSystemImage: "questionmark.bubble.fill",
                    accentColor: Color.accentColor,
                    submitLabel: "Submit",
                    showsSkipControls: true,
                    metrics: metrics,
                    onDraftChange: { questionID, draft in
                        var drafts = coordinatorCheckpointDrafts[pending.interaction.id] ?? pending.interaction.emptyDrafts()
                        drafts[questionID] = draft
                        coordinatorCheckpointDrafts[pending.interaction.id] = drafts
                    },
                    onQuestionIndexChange: { index in
                        coordinatorCheckpointQuestionIndex[pending.interaction.id] = index
                    },
                    onSubmit: {
                        submitCoordinatorStructuredInteractionResponse(pendingInteraction)
                    },
                    onSkipAll: {
                        submitCoordinatorStructuredInteractionSkip(pendingInteraction, pending: pending)
                    },
                    onUserActivity: {}
                )
                .disabled(isSubmittingCoordinatorDirective)
                .padding(.horizontal, metrics.cardPadding)
                .padding(.vertical, metrics.smallSpacing)
            }
        case .planApproval:
            coordinatorDirectorCheckpointTriadCard(
                badgeTitle: "Mission checkpoint · Plan approval",
                badgeSystemImage: "flag.checkered",
                title: "Approve the Mission Plan",
                context: "Approving starts the plan the Director inferred from your directive. Revise if the shape or scope is off.",
                accentColor: Color.accentColor,
                proceedDescription: "Approve the current plan and let the Director continue.",
                reviseDescription: "Keep the Mission paused and use the composer to change the plan first.",
                stopDescription: "End this Mission here and record the stop decision.",
                metrics: metrics,
                onProceed: {
                    submitCoordinatorContinuation(.proceed)
                },
                onRevise: {
                    reviseCoordinatorPlanApprovalCheckpoint()
                },
                onStop: {
                    submitCoordinatorContinuation(.stopHere)
                }
            )
            .disabled(isSubmittingCoordinatorDirective)
            .padding(.horizontal, metrics.cardPadding)
            .padding(.vertical, metrics.smallSpacing)
        case let .stepBoundary(event):
            coordinatorDirectorCheckpointTriadCard(
                badgeTitle: "Mission checkpoint · Step",
                badgeSystemImage: "pause.circle.fill",
                title: event.stepCheckpointTitle,
                context: event.stepCheckpointContext,
                accentColor: Color.accentColor,
                proceedDescription: "Continue from this checkpoint.",
                reviseDescription: "Keep the Mission paused and use the composer to revise instructions first.",
                stopDescription: "End this Mission here and record the stop decision.",
                metrics: metrics,
                onProceed: {
                    submitPendingFollowThroughEvent(event)
                },
                onRevise: {
                    reviseCoordinatorFollowThroughCheckpoint(event)
                },
                onStop: {
                    resolvePendingFollowThroughEvent(event) {
                        stopCoordinatorMission()
                    }
                }
            )
            .disabled(isSubmittingCoordinatorDirective)
            .padding(.horizontal, metrics.cardPadding)
            .padding(.vertical, metrics.smallSpacing)
        case nil:
            EmptyView()
        }
    }

    private enum CoordinatorCheckpointPresentation {
        case pendingInteraction(CoordinatorModePendingInteractionSummary)
        case planApproval
        case stepBoundary(CoordinatorFollowThroughEvent)
    }

    private func activeCoordinatorCheckpoint(
        for rail: CoordinatorModeCoordinatorRail
    ) -> CoordinatorCheckpointPresentation? {
        if let pendingInteraction = rail.pendingInteraction {
            return .pendingInteraction(pendingInteraction)
        }

        guard rail.state == .selected,
              rail.isComposerSendEnabled,
              !isSubmittingCoordinatorDirective
        else { return nil }

        if let missionPlan = rail.missionPlan,
           shouldShowPlanApprovalCheckpoint(missionPlan)
        {
            return .planApproval
        }

        if let event = viewModel.activePendingFollowThroughEvent() {
            return .stepBoundary(event)
        }

        return nil
    }

    private func shouldShowPlanApprovalCheckpoint(_ missionPlan: CoordinatorMissionPlan) -> Bool {
        missionPlan.approvalState == .awaitingApproval
            && !missionPlan.nodes.isEmpty
            && missionPlan.status != .stopped
            && missionPlan.status != .completed
    }

    private func coordinatorMissionPlanReferenceCard(
        _ plan: CoordinatorMissionPlan,
        missionTemplate: CoordinatorMissionTemplateSummary?,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(alignment: .top, spacing: metrics.smallSpacing) {
            Image(systemName: "list.clipboard")
                .font(.system(size: metrics.smallIconSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: metrics.smallIconSize)

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                HStack(spacing: metrics.smallSpacing) {
                    Text("Mission Plan")
                        .font(metrics.bodySemibold)
                        .foregroundStyle(.primary)
                    Text("r\(plan.revision)")
                        .font(metrics.microMedium)
                        .foregroundStyle(.secondary)
                    if let missionTemplate {
                        coordinatorMissionTemplateBadge(missionTemplate, metrics: metrics)
                    }
                }
                if let objective = plan.objective?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !objective.isEmpty
                {
                    Text(objective)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: metrics.smallSpacing)

            Button {
                viewModel.showMissionDestination()
                isMissionPlanPaneVisible = true
                selectedPlanNodeID = nil
            } label: {
                Label("View", systemImage: "sidebar.right")
                    .font(metrics.microMedium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .hoverTooltip("Show the full Mission Plan in the plan pane.")
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.10), lineWidth: 0.75)
        )
    }

    private func coordinatorTerminalMissionSummaryCard(
        _ plan: CoordinatorMissionPlan,
        status: CoordinatorMissionPlanStatus,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let userCount = plan.decisions.count(where: { $0.actor == .user })
        let directorCount = plan.decisions.count(where: { $0.actor == .director })
        let title = plan.objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionTitle = status == .completed ? "Receipt" : "Mission Plan"

        return VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                Label(status == .completed ? "Mission complete" : "Mission stopped", systemImage: status == .completed ? "checkmark.seal.fill" : "stop.circle.fill")
                    .font(metrics.bodySemibold)
                    .foregroundStyle(status.tint)
                Spacer(minLength: metrics.smallSpacing)
                Button {
                    viewModel.showMissionDestination()
                    isMissionPlanPaneVisible = true
                    selectedPlanNodeID = nil
                } label: {
                    Label(actionTitle, systemImage: "doc.text.magnifyingglass")
                        .font(metrics.microMedium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .hoverTooltip("Show the full Mission Plan and receipt details in the plan pane.")
            }

            if let title, !title.isEmpty {
                Text(title)
                    .font(metrics.body)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: metrics.smallSpacing) {
                statusChip("Needed you · \(userCount)", color: .green, metrics: metrics)
                statusChip("Decided itself · \(directorCount)", color: .secondary, metrics: metrics)
            }
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(status.tint.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(status.tint.opacity(0.18), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private func coordinatorTerminalTranscriptDisclosure(
        planID: UUID?,
        entries: [CoordinatorModeRailTranscriptEntry],
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        if !entries.isEmpty {
            CoordinatorTerminalTranscriptDisclosure(
                entries: entries,
                metrics: metrics,
                isDisabled: planID == nil
            ) { entry in
                coordinatorConversationEntry(entry, metrics: metrics)
            }
        }
    }

    private func coordinatorMissionPlanCard(
        _ plan: CoordinatorMissionPlan,
        missionTemplate: CoordinatorMissionTemplateSummary?,
        childCounts: CoordinatorModeCoordinatorChildCounts,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            HStack(spacing: metrics.smallSpacing) {
                Label("Mission Plan", systemImage: "list.clipboard")
                    .font(metrics.microMedium)
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: metrics.smallSpacing)
                if let missionTemplate {
                    coordinatorMissionTemplateBadge(missionTemplate, metrics: metrics)
                }
                Text("r\(plan.revision)")
                    .font(metrics.microMedium)
                    .foregroundStyle(.secondary)
            }

            if let objective = plan.objective {
                Text(objective)
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            missionStatusStrip(plan, childCounts: childCounts, metrics: metrics)

            missionShapePolicyDisclosure(plan, metrics: metrics)

            if !plan.workstreams.isEmpty {
                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    ForEach(plan.workstreams.prefix(4)) { workstream in
                        HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                            Text(workstream.title)
                                .font(metrics.bodyMedium)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                            if let role = workstream.role {
                                Text(role)
                                    .font(metrics.microMedium)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(workstream.defaultPolicy.displayName)
                                .font(metrics.microMedium)
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, metrics.miniPillHorizontalPadding)
                                .padding(.vertical, metrics.miniPillVerticalPadding)
                                .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                            Text(workstream.worktreeStrategy.mode.displayName)
                                .font(metrics.microMedium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !workstream.purpose.isEmpty {
                            Text(workstream.purpose)
                                .font(metrics.micro)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if plan.workstreams.count > 4 {
                        Text("+ \(plan.workstreams.count - 4) more workstreams")
                            .font(metrics.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            missionLedgerPreview(plan, metrics: metrics)

            if plan.status == .completed {
                completedMissionReceipt(plan, metrics: metrics)
            }
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func missionLedgerPreview(
        _ plan: CoordinatorMissionPlan,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        if !plan.decisions.isEmpty || !plan.evidence.isEmpty {
            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                if !plan.decisions.isEmpty {
                    ledgerSectionHeader("Decision ledger", systemImage: "checklist.checked", metrics: metrics)
                    ForEach(plan.decisions.sorted { $0.timestamp > $1.timestamp }.prefix(4)) { decision in
                        decisionLedgerRow(decision, metrics: metrics)
                    }
                }
                if !plan.evidence.isEmpty {
                    ledgerSectionHeader("Evidence", systemImage: "doc.text.magnifyingglass", metrics: metrics)
                        .padding(.top, plan.decisions.isEmpty ? 0 : metrics.tightSpacing)
                    ForEach(plan.evidence.sorted { $0.timestamp > $1.timestamp }.prefix(4)) { evidence in
                        evidenceLedgerRow(evidence, metrics: metrics)
                    }
                }
            }
            .padding(.top, metrics.tightSpacing)
        }
    }

    private func ledgerSectionHeader(
        _ title: String,
        systemImage: String,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(metrics.microMedium)
            .foregroundStyle(.secondary)
    }

    private func decisionLedgerRow(
        _ decision: CoordinatorMissionDecisionRecord,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            HStack(spacing: metrics.smallSpacing) {
                statusChip(decision.actor == .user ? "Actor · you" : "Actor · Director", color: decision.actor == .user ? .green : .secondary, metrics: metrics)
                statusChip("Kind · \(decision.decisionClass)", color: .secondary, metrics: metrics)
                statusChip(decision.overruledDecisionID == nil ? "Status · recorded" : "Status · correction", color: decision.overruledDecisionID == nil ? .secondary : .orange, metrics: metrics)
            }
            Text(decision.label)
                .font(metrics.bodySemibold)
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(2)
            if let reason = decision.reason {
                Text(reason)
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if decision.actor == .director {
                HStack(spacing: metrics.smallSpacing) {
                    Text("Auto decision · contestable")
                        .font(metrics.micro)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: metrics.smallSpacing)
                    Button {} label: {
                        Label("Overrule", systemImage: "arrow.uturn.backward.circle")
                            .font(metrics.microMedium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(true)
                    .hoverTooltip("Overrule steering is not wired yet; reply to the Director with the correction and reason.")
                }
            }
        }
    }

    private func evidenceLedgerRow(
        _ evidence: CoordinatorMissionEvidenceRecord,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            HStack(spacing: metrics.smallSpacing) {
                statusChip("Verdict · \(evidence.verdict.rawValue)", color: evidence.verdict == .meets ? .green : .orange, metrics: metrics)
                if let source = evidenceSourceSummary(evidence.source) {
                    statusChip("Source · \(source)", color: .secondary, metrics: metrics)
                }
            }
            Text(evidence.summary)
                .font(metrics.bodySemibold)
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(2)
            if let judgedOn = evidenceJudgedOnSummary(evidence) {
                Text(judgedOn)
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let judgmentBundle = evidence.judgmentBundle {
                judgmentBundleDisclosure(judgmentBundle, metrics: metrics)
            }
        }
    }

    private func judgmentBundleDisclosure(
        _ bundle: CoordinatorMissionJudgmentBundle,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            Label("Judgment bundle · not transcript", systemImage: "doc.text.magnifyingglass")
                .font(metrics.microMedium)
                .foregroundStyle(.secondary)
            Text(judgmentBundleFramingText(bundle.transcriptFraming))
                .font(metrics.micro)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let doneCriteria = bundle.doneCriteria {
                Label("Done criteria: \(doneCriteria)", systemImage: "checkmark.seal")
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let structuredEvidence = bundle.structuredEvidence {
                Label(structuredEvidence, systemImage: "list.bullet.clipboard")
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let diffStats = bundle.diffStats {
                Label(diffStatsSummary(diffStats), systemImage: "plusminus")
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let probeAnswer = bundle.probeAnswer,
               let probeSummary = probeAnswerSummary(probeAnswer)
            {
                Label(probeSummary, systemImage: "bubble.left.and.text.bubble.right")
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, metrics.smallSpacing)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 2)
        }
    }

    private func judgmentBundleFramingText(_ framing: String) -> String {
        if framing == CoordinatorMissionJudgmentBundle.notTranscriptFraming {
            return "Structured evidence summary; not a transcript excerpt."
        }
        return "Framing: \(framing). Not a transcript excerpt."
    }

    private func diffStatsSummary(_ stats: CoordinatorMissionDiffStats) -> String {
        var parts: [String] = []
        if let filesChanged = stats.filesChanged {
            parts.append("\(filesChanged) files")
        }
        if let insertions = stats.insertions {
            parts.append("+\(insertions)")
        }
        if let deletions = stats.deletions {
            parts.append("-\(deletions)")
        }
        if let summary = stats.summary {
            parts.append(summary)
        }
        return parts.isEmpty ? "Diff stats recorded" : "Diff: \(parts.joined(separator: ", "))"
    }

    private func probeAnswerSummary(_ answer: CoordinatorMissionProbeAnswerSummary) -> String? {
        let source = answer.source ?? answer.answerID
        let body = answer.answer
        switch (source, body) {
        case let (source?, body?):
            return "Probe \(source): \(body)"
        case let (source?, nil):
            return "Probe \(source) recorded"
        case let (nil, body?):
            return "Probe answer: \(body)"
        case (nil, nil):
            return nil
        }
    }

    private func evidenceSourceSummary(_ source: CoordinatorMissionEvidenceSource?) -> String? {
        guard let source else { return nil }
        if let summary = source.summary {
            return summary
        }
        if let operation = source.operation {
            return operation.displayName
        }
        return source.kind
    }

    private func evidenceJudgedOnSummary(_ evidence: CoordinatorMissionEvidenceRecord) -> String? {
        if let structuredEvidence = evidence.judgmentBundle?.structuredEvidence {
            return "Judged on: \(structuredEvidence)"
        }
        if let doneCriteria = evidence.judgmentBundle?.doneCriteria {
            return "Judged on: \(doneCriteria)"
        }
        return evidence.source?.summary.map { "Judged on: \($0)" }
    }

    private func coordinatorGroundingPinnedSummary(_ policy: CoordinatorMissionPolicySnapshot) -> String {
        var parts: [String] = []
        if !policy.pinnedSkillIDs.isEmpty {
            parts.append("skills: \(policy.pinnedSkillIDs.joined(separator: ", "))")
        }
        if !policy.pinnedContextIDs.isEmpty {
            parts.append("context: \(policy.pinnedContextIDs.joined(separator: ", "))")
        }
        return "Pinned " + parts.joined(separator: " · ")
    }

    private func completedMissionReceipt(
        _ plan: CoordinatorMissionPlan,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let projection = CoordinatorMissionReceiptProjection(plan: plan)

        return VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            completedMissionReceiptHeader(projection: projection, planID: plan.id, metrics: metrics)
            completedMissionReceiptOverview(projection, metrics: metrics)
            completedMissionReceiptPolicy(projection.policy, metrics: metrics)
            completedMissionReceiptDecisions(projection.decisionCounts, metrics: metrics)
            completedMissionReceiptEvidence(projection.evidence, metrics: metrics)
            completedMissionReceiptSpend(metrics: metrics)
        }
        .padding(metrics.tightSpacing)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.green.opacity(0.18), lineWidth: 0.75)
        )
    }

    private func completedMissionReceiptHeader(
        projection: CoordinatorMissionReceiptProjection,
        planID: UUID,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let isCopied = copiedMissionReceiptPlanID == planID
        let tint = isCopied ? Color.green : Color.accentColor

        return HStack(spacing: metrics.smallSpacing) {
            Label("Completed Mission receipt", systemImage: "checkmark.seal.fill")
                .font(metrics.microMedium)
                .foregroundStyle(.green)
            Spacer(minLength: metrics.smallSpacing)
            Button {
                copyCompletedMissionReceiptMarkdown(projection.markdown, planID: planID)
            } label: {
                Label(isCopied ? "Copied" : "Copy Markdown", systemImage: isCopied ? "checkmark" : "doc.on.clipboard")
                    .font(metrics.microMedium)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tint)
            .padding(.horizontal, metrics.miniPillHorizontalPadding)
            .padding(.vertical, metrics.miniPillVerticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.24), lineWidth: 0.8)
            )
            .hoverTooltip("Copy Mission receipt as Markdown")
        }
    }

    @ViewBuilder
    private func completedMissionReceiptOverview(
        _ projection: CoordinatorMissionReceiptProjection,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        Text(projection.title)
            .font(metrics.cardTitle)
            .foregroundStyle(.primary)
            .lineLimit(2)

        if let objective = projection.objective {
            Text(objective)
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }

        if let summary = projection.summary {
            Text(summary)
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func completedMissionReceiptPolicy(
        _ policy: CoordinatorMissionReceiptProjection.PolicySummary?,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        if let policy {
            VStack(alignment: .leading, spacing: metrics.smallSpacing) {
                Text("Policy")
                    .font(metrics.microMedium)
                    .foregroundStyle(.secondary)
                HStack(spacing: metrics.smallSpacing) {
                    statusChip(policy.name, color: .secondary, metrics: metrics)
                    statusChip(policy.pace, color: .secondary, metrics: metrics)
                    statusChip("Max \(policy.maxConcurrent)", color: .secondary, metrics: metrics)
                }
                if !policy.askClasses.isEmpty {
                    Text("Asks: \(policy.askClasses.joined(separator: ", "))")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let definitionOfDone = policy.definitionOfDone {
                    Text("Done: \(definitionOfDone)")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let standingGuidance = policy.standingGuidance {
                    Text("Guidance: \(standingGuidance)")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func completedMissionReceiptDecisions(
        _ decisionCounts: CoordinatorMissionReceiptProjection.DecisionCounts,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            Text("Decisions")
                .font(metrics.microMedium)
                .foregroundStyle(.secondary)
            HStack(spacing: metrics.smallSpacing) {
                statusChip("\(decisionCounts.total) total", color: .green, metrics: metrics)
                statusChip("\(decisionCounts.user) user", color: .green, metrics: metrics)
                statusChip("\(decisionCounts.director) Director", color: .secondary, metrics: metrics)
            }
            if !decisionCounts.byClass.isEmpty {
                Text(decisionCounts.byClass.map { "\($0.name) \($0.count)" }.joined(separator: " · "))
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func completedMissionReceiptEvidence(
        _ evidenceSummaries: [CoordinatorMissionReceiptProjection.EvidenceSummary],
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            Text("Evidence")
                .font(metrics.microMedium)
                .foregroundStyle(.secondary)
            if evidenceSummaries.isEmpty {
                Text("No evidence recorded for this Mission.")
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(evidenceSummaries.enumerated()), id: \.offset) { _, evidence in
                    completedMissionReceiptEvidenceRow(evidence, metrics: metrics)
                }
            }
        }
    }

    private func completedMissionReceiptEvidenceRow(
        _ evidence: CoordinatorMissionReceiptProjection.EvidenceSummary,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
            statusChip(evidence.verdict, color: evidence.verdict == "meets" ? .green : .orange, metrics: metrics)
            Text(evidence.summary)
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func completedMissionReceiptSpend(metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            Text("Spend")
                .font(metrics.microMedium)
                .foregroundStyle(.secondary)
            Text(CoordinatorMissionReceiptProjection.spendReserveCopy)
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func copyCompletedMissionReceiptMarkdown(_ markdown: String, planID: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copiedMissionReceiptPlanID = planID
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                guard copiedMissionReceiptPlanID == planID else { return }
                copiedMissionReceiptPlanID = nil
            }
        }
    }

    private func coordinatorMissionTemplateBadge(
        _ template: CoordinatorMissionTemplateSummary,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let accentColor = template.accentColorHex.flatMap { Color(hex: $0) } ?? Color.accentColor
        return Label(template.displayName, systemImage: template.iconName)
            .font(metrics.microMedium)
            .foregroundStyle(accentColor)
            .lineLimit(1)
            .padding(.horizontal, metrics.miniPillHorizontalPadding)
            .padding(.vertical, metrics.miniPillVerticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(accentColor.opacity(0.12))
            )
    }

    private static let planApprovalCheckpointDraftKey = "plan_approval"
    private static let planApprovalCheckpointID = UUID(
        uuid: (0x1F, 0x7D, 0xE6, 0xE3, 0x1F, 0x56, 0x46, 0xD4, 0xA3, 0xDF, 0xBB, 0x74, 0x01, 0x95, 0xD0, 0x06)
    )

    private func coordinatorPlanApprovalCheckpointState() -> AgentAskUserPendingState? {
        let options = [
            AgentAskUserOption(
                label: "Proceed",
                description: "Approve the current plan and let the Director run the next safe step."
            ),
            AgentAskUserOption(
                label: "Revise",
                description: "Keep the Mission paused and use the composer to add plan changes or nuance."
            ),
            AgentAskUserOption(
                label: "Stop",
                description: "End this Mission here and record the stop decision."
            )
        ]
        let interaction = AgentAskUserInteraction(
            id: Self.planApprovalCheckpointID,
            title: "Approval required",
            context: "Choose how the Director should continue from this checkpoint.",
            questions: [
                AgentAskUserQuestion(
                    id: "decision",
                    header: "Director decision",
                    question: "What should happen next?",
                    options: options,
                    allowsMultiple: false,
                    allowsCustom: false
                )
            ]
        )
        let key = Self.planApprovalCheckpointDraftKey
        return AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: coordinatorOwnedCheckpointDrafts[key] ?? interaction.emptyDrafts(),
            currentQuestionIndex: coordinatorOwnedCheckpointQuestionIndex[key] ?? 0
        )
    }

    private func coordinatorFollowThroughCheckpointState(
        for event: CoordinatorFollowThroughEvent
    ) -> AgentAskUserPendingState? {
        let options = [
            AgentAskUserOption(
                label: "Proceed",
                description: "Resume the Director with this observed boundary."
            ),
            AgentAskUserOption(
                label: "Revise",
                description: "Edit the plan or instruction before continuing."
            ),
            AgentAskUserOption(
                label: "Stop",
                description: "End this Mission here."
            )
        ]
        let interaction = AgentAskUserInteraction(
            id: event.stepCheckpointID,
            title: event.stepCheckpointTitle,
            context: event.stepCheckpointContext,
            questions: [
                AgentAskUserQuestion(
                    id: "decision",
                    header: "Director decision",
                    question: "What should happen next?",
                    options: options,
                    allowsMultiple: false,
                    allowsCustom: false
                )
            ]
        )
        return AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: coordinatorOwnedCheckpointDrafts[event.id] ?? interaction.emptyDrafts(),
            currentQuestionIndex: coordinatorOwnedCheckpointQuestionIndex[event.id] ?? 0
        )
    }

    private func submitCoordinatorPlanApprovalCheckpoint() {
        guard let pending = coordinatorPlanApprovalCheckpointState(),
              pending.isComplete,
              let selected = pending.draftsByQuestionID["decision"]?.selectedOptionLabels.first
        else { return }
        coordinatorOwnedCheckpointDrafts[Self.planApprovalCheckpointDraftKey] = nil
        coordinatorOwnedCheckpointQuestionIndex[Self.planApprovalCheckpointDraftKey] = nil
        switch selected {
        case "Proceed":
            submitCoordinatorContinuation(.proceed)
        case "Revise":
            reviseCoordinatorPlanApprovalCheckpoint()
        case "Gather evidence":
            submitCoordinatorContinuation(.runLightweightDiscovery)
        case "Deepen plan":
            submitCoordinatorContinuation(.runDeepPlan)
        case "Get independent critique":
            submitCoordinatorContinuation(.runDesignCritique)
        case "Start smaller":
            submitCoordinatorContinuation(.startSmaller)
        case "Stop":
            submitCoordinatorContinuation(.stopHere)
        default:
            break
        }
    }

    private func submitCoordinatorFollowThroughCheckpoint(_ event: CoordinatorFollowThroughEvent) {
        guard let pending = coordinatorFollowThroughCheckpointState(for: event),
              pending.isComplete,
              let selected = pending.draftsByQuestionID["decision"]?.selectedOptionLabels.first
        else { return }
        coordinatorOwnedCheckpointDrafts[event.id] = nil
        coordinatorOwnedCheckpointQuestionIndex[event.id] = nil
        switch selected {
        case "Proceed", "Continue":
            submitPendingFollowThroughEvent(event)
        case "Revise":
            reviseCoordinatorFollowThroughCheckpoint(event)
        case "Stop":
            resolvePendingFollowThroughEvent(event) {
                stopCoordinatorMission()
            }
        default:
            break
        }
    }

    private func reviseCoordinatorPlanApprovalCheckpoint() {
        coordinatorOwnedCheckpointDrafts[Self.planApprovalCheckpointDraftKey] = nil
        coordinatorOwnedCheckpointQuestionIndex[Self.planApprovalCheckpointDraftKey] = nil
        let rail = viewModel.snapshot.coordinatorRail
        if isMissionPlanPaneVisible,
           rail.missionPlan != nil,
           canEditMissionPlanRevision(rail)
        {
            if missionPlanRevisionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missionPlanRevisionDraft = "Revise the plan: "
            }
            isMissionPlanComposerFocused = true
            return
        }
        viewModel.queuePlanRevisionDecisionAfterAcceptedDirective()
        if coordinatorDirectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            coordinatorDirectiveDraft = "Revise the plan: "
        }
        isCoordinatorComposerFocused = true
    }

    private func reviseCoordinatorFollowThroughCheckpoint(_ event: CoordinatorFollowThroughEvent) {
        coordinatorOwnedCheckpointDrafts[event.id] = nil
        coordinatorOwnedCheckpointQuestionIndex[event.id] = nil
        viewModel.queueFollowThroughRevisionDecisionAfterAcceptedDirective(event)
        if coordinatorDirectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            coordinatorDirectiveDraft = "Revise before processing this observed boundary:\n\n\(event.stepCheckpointContext)\n\n"
        }
        isCoordinatorComposerFocused = true
    }

    private func coordinatorEmptyConversation(
        _ rail: CoordinatorModeCoordinatorRail,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            Text("Ask the Director what to do next.")
                .font(metrics.bodyMedium)
                .foregroundStyle(.primary.opacity(0.82))
            Text("Delegated sessions will appear on the board as this conversation creates work.")
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func coordinatorConversationEntry(
        _ entry: CoordinatorModeRailTranscriptEntry,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        if let ledger = entry.ledger {
            coordinatorLedgerConversationEntry(ledger, createdAt: entry.createdAt, metrics: metrics)
        } else if let action = entry.action {
            coordinatorActionConversationEntry(action, metrics: metrics)
        } else {
            let isUser = entry.role == .user
            HStack(alignment: .top) {
                if isUser {
                    Spacer(minLength: metrics.controlSpacing)
                }

                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    HStack(spacing: metrics.smallSpacing) {
                        if !isUser {
                            Image(systemName: entry.role.systemImage)
                                .font(.system(size: metrics.microIconSize, weight: .medium))
                        }
                        Text(entry.role.displayName)
                            .font(metrics.microMedium)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(entry.role.labelColor)

                    coordinatorConversationBody(entry, metrics: metrics)
                }
                .padding(metrics.pendingPadding)
                .frame(maxWidth: isUser ? metrics.userBubbleMaxWidth : .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                        .fill(entry.role.bubbleFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                        .stroke(entry.role.bubbleStroke, lineWidth: 0.5)
                )

                if !isUser {
                    Spacer(minLength: metrics.controlSpacing)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    private func coordinatorActionConversationEntry(
        _ action: CoordinatorModeCoordinatorAction,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let targetRow = action.targetSessionID.flatMap { coordinatorRow(for: $0) }
        let statusGroup = targetRow?.statusGroup ?? action.statusGroup
        let statusColor = statusGroup?.accentColor ?? action.phase.tint
        let statusText = statusGroup?.displayName ?? action.phase.displayName
        let workflow = targetRow?.workflow ?? action.workflow
        let workstream = targetRow?.workstream ?? action.workstream

        return HStack(alignment: .top, spacing: metrics.smallSpacing) {
            Image(systemName: action.verb.systemImage)
                .font(.system(size: metrics.microIconSize, weight: .semibold))
                .foregroundStyle(action.verb.tint)
                .frame(width: metrics.titlebarIconSize, height: metrics.titlebarIconSize)

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                HStack(spacing: metrics.smallSpacing) {
                    Text(action.verb.displayName)
                        .font(metrics.microMedium)
                        .foregroundStyle(action.verb.tint)
                    if let workflow {
                        workflowBadge(workflow, metrics: metrics)
                    }
                    if let workstream {
                        worktreeLabel(workstream, metrics: metrics)
                    }
                    Text(action.ownerTitle)
                        .font(metrics.microMedium)
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(1)
                }

                Text(action.targetTitle)
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: metrics.smallSpacing)

            HStack(spacing: metrics.miniPillIconSpacing) {
                Circle()
                    .fill(statusColor.opacity(0.9))
                    .frame(width: metrics.composerStatusDotSize, height: metrics.composerStatusDotSize)
                Text(statusText)
                    .font(metrics.microMedium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, metrics.miniPillHorizontalPadding)
            .padding(.vertical, metrics.miniPillVerticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.28))
            )
        }
        .padding(.horizontal, metrics.pendingPadding)
        .padding(.vertical, metrics.pendingPadding * 0.82)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(action.verb.tint.opacity(0.14), lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectDelegatedActionTarget(targetRow)
        }
        .hoverTooltip(targetRow == nil ? "Delegated session is no longer visible on the board" : "Show delegated session in inspector")
    }

    @ViewBuilder
    private func coordinatorLedgerConversationEntry(
        _ payload: CoordinatorModeLedgerEntryPayload,
        createdAt: Date,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        switch payload {
        case let .evidence(evidence):
            coordinatorLedgerCard(
                title: "Evidence",
                systemImage: evidence.verdict == .meets ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                tint: evidence.verdict == .meets ? .green : .orange,
                createdAt: createdAt,
                metrics: metrics
            ) {
                evidenceLedgerRow(evidence, metrics: metrics)
            }
        case let .decision(decision):
            coordinatorLedgerCard(
                title: "Decision",
                systemImage: decision.actor == .director ? "gearshape.fill" : "person.crop.circle.badge.checkmark",
                tint: decision.actor == .director ? .secondary : .green,
                createdAt: createdAt,
                metrics: metrics
            ) {
                decisionLedgerRow(decision, metrics: metrics)
            }
        case let .routing(decision):
            coordinatorRoutingKickoffLine(decision, createdAt: createdAt, metrics: metrics)
        case let .planEvent(event):
            coordinatorPlanEventMarker(event, createdAt: createdAt, metrics: metrics)
        case let .grounding(policy, shape):
            coordinatorGroundingCard(policy: policy, shape: shape, createdAt: createdAt, metrics: metrics)
        case let .wrapUp(userCount, directorCount):
            coordinatorWrapUpStatCard(userCount: userCount, directorCount: directorCount, createdAt: createdAt, metrics: metrics)
        }
    }

    private func coordinatorLedgerCard(
        title: String,
        systemImage: String,
        tint: Color,
        createdAt: Date,
        metrics: CoordinatorVisualMetrics,
        @ViewBuilder content: () -> some View
    ) -> some View {
        coordinatorControlPlaneCard(
            title: title,
            systemImage: systemImage,
            tint: tint,
            trailingText: createdAt.formatted(date: .omitted, time: .shortened),
            metrics: metrics,
            content: content
        )
    }

    private func coordinatorControlPlaneCard(
        title: String,
        systemImage: String,
        tint: Color,
        trailingText: String?,
        metrics: CoordinatorVisualMetrics,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: metrics.smallSpacing) {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.5))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                    Label(title, systemImage: systemImage)
                        .font(metrics.microMedium)
                        .foregroundStyle(tint)
                    Spacer(minLength: metrics.smallSpacing)
                    if let trailingText {
                        Text(trailingText)
                            .font(metrics.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
                content()
            }
        }
        .padding(metrics.smallSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 0.75)
        )
    }

    private func coordinatorRoutingKickoffLine(
        _ decision: CoordinatorMissionRoutingDecision,
        createdAt: Date,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let targetRow = decision.sessionID.flatMap { coordinatorRow(for: $0) }
        let workflowName = targetRow?.workflow?.displayName ?? decision.workflowName
        let worktreeName = targetRow?.workstream?.branch ?? targetRow?.workstream?.label ?? decision.worktreeID

        return coordinatorControlPlaneCard(
            title: "Delegated session",
            systemImage: "arrow.triangle.branch",
            tint: .secondary,
            trailingText: createdAt.formatted(date: .omitted, time: .shortened),
            metrics: metrics
        ) {
            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                HStack(spacing: metrics.smallSpacing) {
                    statusChip("Route · \(decision.decision.displayName)", color: .secondary, metrics: metrics)
                    statusChip(decision.operation.displayName, color: .secondary, metrics: metrics)
                    if let workflowName {
                        statusChip("Workflow · \(workflowName)", color: .secondary, metrics: metrics)
                    }
                    if let worktreeName {
                        statusChip("Worktree · \(worktreeName)", color: .secondary, metrics: metrics)
                    }
                }
                Text(decision.reason)
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                if let contextSummary = decision.contextSummary {
                    Text(contextSummary)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectDelegatedActionTarget(targetRow)
        }
        .hoverTooltip(targetRow == nil ? "Delegated session is no longer visible on the board" : "Show delegated session in inspector")
    }

    private func coordinatorPlanEventMarker(
        _ event: CoordinatorMissionPlanEvent,
        createdAt: Date,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(alignment: .top, spacing: metrics.smallSpacing) {
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.28))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                    Label("Plan", systemImage: "flag.checkered")
                        .font(metrics.microMedium)
                        .foregroundStyle(.secondary)
                    Text(event.kind.displayName)
                        .font(metrics.microMedium)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: metrics.smallSpacing)
                    Text(createdAt.formatted(date: .omitted, time: .shortened))
                        .font(metrics.micro)
                        .foregroundStyle(.tertiary)
                }

                if let summary = event.summary {
                    Text(summary)
                        .font(metrics.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, metrics.smallSpacing)
        .padding(.vertical, metrics.tightSpacing * 0.65)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.08))
        )
    }

    private func coordinatorGroundingCard(
        policy: CoordinatorMissionPolicySnapshot?,
        shape: CoordinatorMissionShapeSummary?,
        createdAt: Date,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        coordinatorLedgerCard(
            title: "Mission context",
            systemImage: "pin.fill",
            tint: .secondary,
            createdAt: createdAt,
            metrics: metrics
        ) {
            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                HStack(spacing: metrics.smallSpacing) {
                    if let shape {
                        statusChip("Shape · \(shape.displayName)", color: .secondary, metrics: metrics)
                    }
                    if let namedClose = shape?.namedClose {
                        statusChip("Close · \(namedClose)", color: .secondary, metrics: metrics)
                    }
                    if let policy {
                        statusChip(coordinatorPolicyDisplayTitle(policy), color: .secondary, metrics: metrics)
                            .hoverTooltip(coordinatorPolicyEditDiffs(policy).isEmpty ? "Mission Policy · \(policy.name)" : coordinatorPolicyEditDiffs(policy).joined(separator: "\n"))
                        statusChip("Cap · \(policy.maxConcurrent)", color: .secondary, metrics: metrics)
                        statusChip("Pace · \(policy.defaultPace.rawValue)", color: .secondary, metrics: metrics)
                    }
                }
                if let reason = shape?.reason {
                    Text(reason)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let definitionOfDone = policy?.definitionOfDone {
                    Label("Done: \(definitionOfDone)", systemImage: "checkmark.seal")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let standingGuidance = policy?.standingGuidance {
                    Label(standingGuidance, systemImage: "quote.bubble")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let policy, !policy.pinnedSkillIDs.isEmpty || !policy.pinnedContextIDs.isEmpty {
                    Text(coordinatorGroundingPinnedSummary(policy))
                        .font(metrics.micro)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func coordinatorWrapUpStatCard(
        userCount: Int,
        directorCount: Int,
        createdAt: Date,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        coordinatorLedgerCard(
            title: "Mission receipt",
            systemImage: "checkmark.seal.fill",
            tint: .green,
            createdAt: createdAt,
            metrics: metrics
        ) {
            HStack(spacing: metrics.smallSpacing) {
                statusChip("Needed you · \(userCount)", color: .green, metrics: metrics)
                statusChip("Decided itself · \(directorCount)", color: .secondary, metrics: metrics)
                Spacer(minLength: metrics.smallSpacing)
                Button {
                    viewModel.showMissionDestination()
                    isMissionPlanPaneVisible = true
                    selectedPlanNodeID = nil
                } label: {
                    Label("Receipt", systemImage: "doc.text.magnifyingglass")
                        .font(metrics.microMedium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .hoverTooltip("Show the completed Mission receipt in the plan pane.")
            }
        }
    }

    private func coordinatorRow(for sessionID: UUID) -> CoordinatorModeRow? {
        for section in viewModel.snapshot.groups {
            if let row = section.rows.first(where: { $0.sessionID == sessionID }) {
                return row
            }
        }
        return nil
    }

    @ViewBuilder
    private func coordinatorConversationBody(
        _ entry: CoordinatorModeRailTranscriptEntry,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        if entry.role == .user {
            Text(entry.text)
                .font(metrics.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MarkdownTextView(
                text: entry.text,
                isMarkdown: true,
                allowInteraction: true,
                forceTextColor: entry.role == .event ? .secondary : nil
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func coordinatorPendingChildInteractionCard(
        row: CoordinatorModeRow,
        pending: CoordinatorModePendingInteractionSummary,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            HStack(spacing: metrics.smallSpacing) {
                Label("Child needs you", systemImage: "questionmark.bubble.fill")
                    .font(metrics.microMedium)
                    .foregroundStyle(CoordinatorModeStatusGroup.needsYou.accentColor)
                Spacer(minLength: metrics.smallSpacing)
                if let workflow = row.workflow {
                    workflowBadge(workflow, metrics: metrics)
                }
            }

            Text(row.title)
                .font(metrics.bodySemibold)
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(2)

            if let title = pending.title, !title.isEmpty {
                Text(title)
                    .font(metrics.microMedium)
                    .foregroundStyle(.secondary)
            }

            if let prompt = pending.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(metrics.body)
                    .foregroundStyle(.primary.opacity(0.84))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !pending.details.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pending.details, id: \.label) { detail in
                        Text("\(detail.label): \(detail.value)")
                            .font(metrics.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 2)
            }

            Text("Your next message will be sent to this child session, then the Director can continue from the result.")
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(CoordinatorModeStatusGroup.needsYou.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(CoordinatorModeStatusGroup.needsYou.accentColor.opacity(0.22), lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectDelegatedActionTarget(row)
        }
        .hoverTooltip("Show child session in inspector")
    }

    private func coordinatorStructuredPendingChildInteractionCard(
        row: CoordinatorModeRow,
        pending: AgentAskUserPendingState,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        coordinatorCompactCheckpointCard(
            pending: pending,
            badgeTitle: "Child needs you",
            badgeSystemImage: "questionmark.bubble.fill",
            accentColor: CoordinatorModeStatusGroup.needsYou.accentColor,
            submitLabel: "Submit",
            showsSkipControls: true,
            metrics: metrics,
            onDraftChange: { questionID, draft in
                var drafts = coordinatorCheckpointDrafts[pending.interaction.id] ?? pending.interaction.emptyDrafts()
                drafts[questionID] = draft
                coordinatorCheckpointDrafts[pending.interaction.id] = drafts
            },
            onQuestionIndexChange: { index in
                coordinatorCheckpointQuestionIndex[pending.interaction.id] = index
            },
            onSubmit: {
                submitPendingChildStructuredInteractionResponse(to: row)
            },
            onSkipAll: {
                submitPendingChildStructuredInteractionSkip(to: row, pending: pending)
            },
            onUserActivity: {}
        )
        .disabled(isSubmittingCoordinatorDirective)
    }

    private func coordinatorDirectorCheckpointTriadCard(
        badgeTitle: String,
        badgeSystemImage: String,
        title: String,
        context: String,
        accentColor: Color,
        proceedDescription: String,
        reviseDescription: String,
        stopDescription: String,
        metrics: CoordinatorVisualMetrics,
        onProceed: @escaping () -> Void,
        onRevise: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: metrics.smallSpacing) {
            Capsule(style: .continuous)
                .fill(accentColor.opacity(0.55))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                    Label(badgeTitle, systemImage: badgeSystemImage)
                        .font(metrics.microMedium)
                        .foregroundStyle(accentColor)
                }

                Text(title)
                    .font(metrics.bodySemibold)
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(2)

                if let context = trimmedNonEmpty(context) {
                    Text(context)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 4) {
                    coordinatorDirectorCheckpointActionButton(
                        label: "Proceed",
                        systemImage: "play.fill",
                        description: proceedDescription,
                        accentColor: accentColor,
                        metrics: metrics,
                        action: onProceed
                    )
                    coordinatorDirectorCheckpointActionButton(
                        label: "Revise",
                        systemImage: "square.and.pencil",
                        description: reviseDescription,
                        accentColor: accentColor,
                        metrics: metrics,
                        action: onRevise
                    )
                    coordinatorDirectorCheckpointActionButton(
                        label: "Stop",
                        systemImage: "stop.fill",
                        description: stopDescription,
                        accentColor: .red,
                        metrics: metrics,
                        action: onStop
                    )
                }
            }
        }
        .padding(metrics.smallSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColor.opacity(0.18), lineWidth: 0.75)
        )
    }

    private func coordinatorDirectorCheckpointActionButton(
        label: String,
        systemImage: String,
        description: String,
        accentColor: Color,
        metrics: CoordinatorVisualMetrics,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: metrics.miniPillIconSpacing) {
                    Image(systemName: systemImage)
                        .font(metrics.microMedium)
                        .foregroundStyle(accentColor)
                    Text(label)
                        .font(metrics.microMedium)
                        .foregroundStyle(.primary.opacity(0.92))
                    Spacer(minLength: 0)
                }

                Text(description)
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, metrics.smallSpacing)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(accentColor.opacity(0.16), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }

    private func coordinatorCompactCheckpointCard(
        pending: AgentAskUserPendingState,
        badgeTitle: String,
        badgeSystemImage: String,
        accentColor: Color,
        submitLabel: String,
        showsSkipControls: Bool,
        metrics: CoordinatorVisualMetrics,
        onDraftChange: @escaping (_ questionID: String, _ draft: AgentAskUserDraft) -> Void,
        onQuestionIndexChange: @escaping (_ index: Int) -> Void,
        onSubmit: @escaping () -> Void,
        onSkipAll: @escaping () -> Void,
        onUserActivity: @escaping () -> Void
    ) -> some View {
        let questionCount = pending.interaction.questions.count
        let currentIndex = pending.currentQuestionIndex
        let currentQuestion = pending.currentQuestion
        let currentDraft = currentQuestion.flatMap { pending.draftsByQuestionID[$0.id] } ?? AgentAskUserDraft()
        let canMoveForward = currentQuestion.map { question in
            let answer = question.answer(from: currentDraft)
            return answer.skipped || !answer.answers.isEmpty
        } ?? false

        return HStack(alignment: .top, spacing: metrics.smallSpacing) {
            Capsule(style: .continuous)
                .fill(accentColor.opacity(0.55))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: metrics.smallSpacing) {
                    Label(badgeTitle, systemImage: badgeSystemImage)
                        .font(metrics.microMedium)
                        .foregroundStyle(accentColor)
                    Spacer(minLength: metrics.smallSpacing)
                    Text("Question \(min(currentIndex + 1, questionCount)) of \(questionCount)")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                }

                if let title = trimmedNonEmpty(pending.interaction.title) {
                    Text(title)
                        .font(metrics.bodySemibold)
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(2)
                }

                if let context = trimmedNonEmpty(pending.interaction.context) {
                    Text(context)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let question = currentQuestion {
                    coordinatorCompactCheckpointQuestion(
                        question,
                        draft: currentDraft,
                        accentColor: accentColor,
                        metrics: metrics,
                        onDraftChange: { draft in
                            onDraftChange(question.id, draft)
                            onUserActivity()
                        },
                        onSubmit: onSubmit
                    )
                }

                HStack(spacing: metrics.smallSpacing) {
                    if showsSkipControls {
                        Button("Skip all") {
                            onSkipAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)

                        if let question = currentQuestion {
                            Button(currentDraft.skipped ? "Answer" : "Skip") {
                                if currentDraft.skipped {
                                    onDraftChange(question.id, AgentAskUserDraft())
                                } else {
                                    onDraftChange(question.id, AgentAskUserDraft(skipped: true))
                                    if currentIndex < questionCount - 1 {
                                        onQuestionIndexChange(currentIndex + 1)
                                    }
                                }
                                onUserActivity()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Spacer(minLength: metrics.smallSpacing)

                    Button("Back") {
                        onQuestionIndexChange(currentIndex - 1)
                        onUserActivity()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(currentIndex <= 0)

                    if currentIndex >= questionCount - 1 {
                        Button(submitLabel) {
                            onSubmit()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!pending.isComplete)
                        .keyboardShortcut(.return, modifiers: .shift)
                    } else {
                        Button("Next") {
                            onQuestionIndexChange(currentIndex + 1)
                            onUserActivity()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canMoveForward)
                    }
                }
                .font(metrics.microMedium)
            }
        }
        .padding(metrics.smallSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColor.opacity(0.18), lineWidth: 0.75)
        )
    }

    private func coordinatorCompactCheckpointQuestion(
        _ question: AgentAskUserQuestion,
        draft: AgentAskUserDraft,
        accentColor: Color,
        metrics: CoordinatorVisualMetrics,
        onDraftChange: @escaping (AgentAskUserDraft) -> Void,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            if let header = trimmedNonEmpty(question.header) {
                Text(header)
                    .font(metrics.microMedium)
                    .foregroundStyle(.secondary)
            }

            Text(question.question)
                .font(metrics.body)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let context = trimmedNonEmpty(question.context) {
                Text(context)
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !question.options.isEmpty {
                VStack(spacing: 4) {
                    ForEach(question.options, id: \.label) { option in
                        coordinatorCompactCheckpointOptionRow(
                            option: option,
                            question: question,
                            draft: draft,
                            accentColor: accentColor,
                            metrics: metrics,
                            onDraftChange: onDraftChange
                        )
                    }
                }
            }

            if question.allowsCustom {
                TextField(
                    question.options.isEmpty ? "Type your response..." : "Other...",
                    text: Binding(
                        get: { draft.customResponse },
                        set: { value in
                            var updated = draft
                            updated.customResponse = value
                            updated.skipped = false
                            if !question.allowsMultiple, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                updated.selectedOptionLabels = []
                            }
                            onDraftChange(updated)
                        }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1 ... 3)
                .disabled(draft.skipped)
                .onSubmit {
                    onSubmit()
                }
            }

            if draft.skipped {
                Label("Skipped", systemImage: "forward.fill")
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(metrics.smallSpacing)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accentColor.opacity(0.14), lineWidth: 0.8)
        )
    }

    private func coordinatorCompactCheckpointOptionRow(
        option: AgentAskUserOption,
        question: AgentAskUserQuestion,
        draft: AgentAskUserDraft,
        accentColor: Color,
        metrics: CoordinatorVisualMetrics,
        onDraftChange: @escaping (AgentAskUserDraft) -> Void
    ) -> some View {
        let isSelected = draft.selectedOptionLabels.contains(option.label)

        return Button {
            guard !draft.skipped else { return }
            var updated = draft
            if question.allowsMultiple {
                var selected = Set(updated.selectedOptionLabels)
                if selected.contains(option.label) {
                    selected.remove(option.label)
                } else {
                    selected.insert(option.label)
                }
                updated.selectedOptionLabels = question.optionLabels.filter { selected.contains($0) }
            } else {
                updated.selectedOptionLabels = isSelected ? [] : [option.label]
                updated.customResponse = ""
            }
            updated.skipped = false
            onDraftChange(updated)
        } label: {
            HStack(alignment: .top, spacing: metrics.smallSpacing) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(metrics.microMedium)
                    .foregroundStyle(isSelected ? accentColor : .secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(metrics.microMedium)
                        .foregroundStyle(.primary.opacity(draft.skipped ? 0.45 : 0.9))
                    if let description = trimmedNonEmpty(option.description) {
                        Text(description)
                            .font(metrics.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: metrics.smallSpacing)
            }
            .padding(.horizontal, metrics.smallSpacing)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor).opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? accentColor.opacity(0.38) : Color.white.opacity(0.04), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .disabled(draft.skipped)
    }

    private func coordinatorPendingAskUserState(for row: CoordinatorModeRow) -> AgentAskUserPendingState? {
        guard let pending = row.pendingInteraction else { return nil }
        return coordinatorPendingAskUserState(for: pending)
    }

    private func coordinatorPendingAskUserState(for pending: CoordinatorModePendingInteractionSummary) -> AgentAskUserPendingState? {
        guard pending.kind == .question || pending.kind == .userInput,
              !pending.fields.isEmpty
        else { return nil }
        let questions = pending.fields.map { field in
            AgentAskUserQuestion(
                id: field.id,
                header: field.header,
                question: field.prompt,
                context: field.context,
                options: field.options.map { AgentAskUserOption(label: $0.label, description: $0.description) },
                allowsMultiple: field.allowsMultiple ?? false,
                allowsCustom: field.allowsCustom ?? field.allowsOther
            )
        }
        let interaction = AgentAskUserInteraction(
            id: pending.id,
            title: pending.title,
            context: pending.context,
            questions: questions
        )
        return AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: coordinatorCheckpointDrafts[pending.id] ?? interaction.emptyDrafts(),
            currentQuestionIndex: coordinatorCheckpointQuestionIndex[pending.id] ?? 0
        )
    }

    private func submitCoordinatorStructuredInteractionResponse(_ pendingInteraction: CoordinatorModePendingInteractionSummary) {
        guard let pending = coordinatorPendingAskUserState(for: pendingInteraction),
              pending.isComplete
        else { return }
        let answers = pending.interaction.questions.reduce(into: [String: AgentAskUserAnswer]()) { partialResult, question in
            partialResult[question.id] = question.answer(from: pending.draftsByQuestionID[question.id] ?? AgentAskUserDraft())
        }
        let displayText = coordinatorStructuredAnswerDisplayText(pending: pending, answers: answers)
        let submission = CoordinatorModeViewModel.ChildInteractionResponseSubmission(
            text: nil,
            skip: false,
            answersByQuestionID: answers,
            displayText: displayText
        )
        Task {
            await viewModel.submitCoordinatorPendingInteractionResponse(submission, pending: pendingInteraction)
            await MainActor.run {
                coordinatorCheckpointDrafts[pending.interaction.id] = nil
                coordinatorCheckpointQuestionIndex[pending.interaction.id] = nil
            }
        }
    }

    private func submitCoordinatorStructuredInteractionSkip(
        _ pendingInteraction: CoordinatorModePendingInteractionSummary,
        pending: AgentAskUserPendingState
    ) {
        let displayText = "Skipped \(pending.interaction.title ?? "Director question")"
        let submission = CoordinatorModeViewModel.ChildInteractionResponseSubmission(
            text: nil,
            skip: true,
            answersByQuestionID: [:],
            displayText: displayText
        )
        Task {
            await viewModel.submitCoordinatorPendingInteractionResponse(submission, pending: pendingInteraction)
            await MainActor.run {
                coordinatorCheckpointDrafts[pending.interaction.id] = nil
                coordinatorCheckpointQuestionIndex[pending.interaction.id] = nil
            }
        }
    }

    private func submitPendingChildStructuredInteractionResponse(to row: CoordinatorModeRow) {
        guard let pending = coordinatorPendingAskUserState(for: row),
              pending.isComplete
        else { return }
        let answers = pending.interaction.questions.reduce(into: [String: AgentAskUserAnswer]()) { partialResult, question in
            partialResult[question.id] = question.answer(from: pending.draftsByQuestionID[question.id] ?? AgentAskUserDraft())
        }
        let displayText = coordinatorStructuredAnswerDisplayText(pending: pending, answers: answers)
        let submission = CoordinatorModeViewModel.ChildInteractionResponseSubmission(
            text: nil,
            skip: false,
            answersByQuestionID: answers,
            displayText: displayText
        )
        submitPendingChildInteractionResponse(submission, to: row, clearStructuredDraftsFor: pending.interaction.id)
    }

    private func submitPendingChildStructuredInteractionSkip(to row: CoordinatorModeRow, pending: AgentAskUserPendingState) {
        let displayText = "Skipped \(pending.interaction.title ?? "child checkpoint")"
        let submission = CoordinatorModeViewModel.ChildInteractionResponseSubmission(
            text: nil,
            skip: true,
            answersByQuestionID: [:],
            displayText: displayText
        )
        submitPendingChildInteractionResponse(submission, to: row, clearStructuredDraftsFor: pending.interaction.id)
    }

    private func coordinatorStructuredAnswerDisplayText(
        pending: AgentAskUserPendingState,
        answers: [String: AgentAskUserAnswer]
    ) -> String {
        pending.interaction.questions.map { question in
            let answer = answers[question.id] ?? question.answer(from: AgentAskUserDraft())
            let answerText = if answer.skipped {
                "Skipped"
            } else {
                answer.answers.joined(separator: ", ")
            }
            let title = question.header ?? question.question
            return "\(title): \(answerText)"
        }
        .joined(separator: "\n")
    }

    private func coordinatorComposer(_ rail: CoordinatorModeCoordinatorRail, metrics: CoordinatorVisualMetrics) -> some View {
        let pendingChildRow = viewModel.activePendingChildInteractionRow()
        let pendingChildStructuredState = pendingChildRow.flatMap { coordinatorPendingAskUserState(for: $0) }
        let placeholder = coordinatorComposerPlaceholder(rail, pendingChildRow: pendingChildRow)

        return VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            if let pendingChildRow, let pendingChildStructuredState {
                coordinatorStructuredPendingChildInteractionCard(
                    row: pendingChildRow,
                    pending: pendingChildStructuredState,
                    metrics: metrics
                )
            } else if let pendingChildRow, let pending = pendingChildRow.pendingInteraction {
                coordinatorPendingChildInteractionCard(row: pendingChildRow, pending: pending, metrics: metrics)
            } else if rail.state == .selected, !rail.isComposerSendEnabled, viewModel.currentRailActivityText == nil {
                coordinatorComposerNotice("Director is working. You can send the next message when it reaches a turn boundary.", metrics: metrics)
            } else if let notice = viewModel.composerNotice, !notice.isEmpty {
                coordinatorComposerNotice(notice, metrics: metrics)
            }

            if pendingChildStructuredState == nil {
                ComposerChrome(
                    bottomOcclusion: $coordinatorComposerChromeOcclusion,
                    mainContentHeight: max(coordinatorTextFieldHeight, metrics.composerTextMinHeight),
                    highlightColor: canSubmitCoordinatorDirective ? Color.accentColor : nil,
                    bubbleVerticalPaddingOverride: metrics.coordinatorComposerChromeVerticalPadding,
                    bubbleInnerSpacingOverride: metrics.coordinatorComposerChromeInnerSpacing,
                    controlStripHeightOverride: metrics.composerControlStripHeight,
                    bubbleStroke: AgentModeSurfaceTheme.Palette.composerBubbleStroke,
                    bubbleShadow: AgentModeSurfaceTheme.Palette.composerShadow,
                    bubbleShadowRadius: 7,
                    main: {
                        ResizableTextField(
                            text: $coordinatorDirectiveDraft,
                            placeholder: placeholder,
                            onReturn: submitCoordinatorDirective,
                            resetTrigger: $coordinatorTextFieldResetTrigger,
                            features: coordinatorComposerFeatures(),
                            onHeightChange: { newHeight in
                                coordinatorTextFieldHeight = newHeight
                            }
                        )
                        .frame(height: max(coordinatorTextFieldHeight, metrics.composerTextMinHeight))
                        .disabled(!canEditCoordinatorDirective(rail))
                        .focused($isCoordinatorComposerFocused)
                        .overlay(
                            Text(placeholder)
                                .font(metrics.body)
                                .foregroundStyle(.secondary)
                                .opacity(coordinatorDirectiveDraft.isEmpty ? 1 : 0)
                                .padding(.leading, 5)
                                .padding(.top, 8)
                                .allowsHitTesting(false),
                            alignment: .topLeading
                        )
                    },
                    strip: {
                        coordinatorComposerControlStrip(rail, metrics: metrics)
                    }
                )
            }

            Spacer()
                .frame(height: metrics.composerFooterHeight)
        }
    }

    private func coordinatorComposerPlaceholder(
        _ rail: CoordinatorModeCoordinatorRail,
        pendingChildRow: CoordinatorModeRow?
    ) -> String {
        if pendingChildRow != nil {
            return "Answer the child question..."
        }
        switch rail.state {
        case .chooseCoordinator:
            return "Describe the Mission, then press Enter…"
        case .selected:
            if let plan = rail.missionPlan {
                switch plan.status {
                case .completed:
                    return "Start a follow-up Mission..."
                case .stopped:
                    return "Restart or revise this Mission..."
                case .draft:
                    return "Revise the Mission Plan..."
                case .approved, .running, .blocked:
                    return "Message the Director..."
                }
            }
            return rail.isLiveInCurrentWindow ? "Message the live Director..." : "Message the Director..."
        }
    }

    private func coordinatorComposerControlStrip(_ rail: CoordinatorModeCoordinatorRail, metrics: CoordinatorVisualMetrics) -> some View {
        let pendingChildRow = viewModel.activePendingChildInteractionRow()
        let isChildReply = pendingChildRow != nil

        return HStack(spacing: metrics.smallSpacing) {
            if !isChildReply {
                coordinatorComposerAutomationModeToggle(metrics: metrics)
                coordinatorComposerChildAskToggle(metrics: metrics)
                coordinatorComposerToolsButton(metrics: metrics)
            }

            Spacer(minLength: metrics.smallSpacing)

            let policyEcho = coordinatorComposerPolicyEcho(rail)
            Text(isChildReply ? "Child needs your reply" : policyEcho.text)
                .font(metrics.microMedium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(1)
                .hoverTooltip(isChildReply ? "Answer the child question." : policyEcho.tooltip)

            HStack(spacing: metrics.tightSpacing) {
                if !isChildReply, viewModel.canStopSelectedCoordinatorMission || isStoppingCoordinatorMission {
                    coordinatorComposerStopButton(metrics: metrics)
                }

                Button {
                    submitCoordinatorDirective()
                } label: {
                    Image(systemName: isSubmittingCoordinatorDirective ? "hourglass" : "paperplane.fill")
                        .font(.system(size: metrics.composerSendIconSize, weight: .semibold))
                        .frame(width: metrics.sendButtonSize, height: metrics.sendButtonSize)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSubmitCoordinatorDirective ? Color.accentColor : Color.secondary.opacity(0.55))
                .disabled(!canSubmitCoordinatorDirective)
                .hoverTooltip(isSubmittingCoordinatorDirective ? "Sending" : (isChildReply ? "Answer child" : "Send"))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: metrics.composerControlStripHeight)
        .padding(.horizontal, metrics.composerControlHorizontalPadding)
    }

    private func coordinatorComposerPolicyEcho(_ rail: CoordinatorModeCoordinatorRail) -> (text: String, tooltip: String) {
        let policy = coordinatorEffectivePolicySnapshot(rail)
        let diffs = coordinatorPolicyEditDiffs(policy)
        if diffs.isEmpty {
            return (
                "Policy · \(policy.name) · always asks: \(coordinatorPolicyAlwaysAsksText(policy).replacingOccurrences(of: ", ", with: " · "))",
                "Mission Policy · \(policy.name)"
            )
        }
        return (
            "Policy · \(policy.name) · edited",
            diffs.joined(separator: "\n")
        )
    }

    private func coordinatorEffectivePolicySnapshot(_ rail: CoordinatorModeCoordinatorRail) -> CoordinatorMissionPolicySnapshot {
        if let policySnapshot = rail.missionPlan?.policySnapshot {
            return policySnapshot
        }
        var policySnapshot = viewModel.selectedMissionPolicy
        policySnapshot.defaultPace = viewModel.missionPaceSelection
        policySnapshot.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = viewModel.childAskSelection
        return policySnapshot
    }

    private func coordinatorPolicyEditDiffs(_ policy: CoordinatorMissionPolicySnapshot) -> [String] {
        guard let base = CoordinatorMissionPolicySnapshot.builtInPolicies.first(where: { $0.id == policy.id }) else { return [] }
        var diffs: [String] = []
        if base.defaultPace != policy.defaultPace {
            diffs.append("pace → \(coordinatorPaceDisplayName(policy.defaultPace))")
        }
        let baseChildAsk = base.resolvedAutonomy(for: .childAsk)
        let childAsk = policy.resolvedAutonomy(for: .childAsk)
        if baseChildAsk != childAsk {
            diffs.append("questions → \(coordinatorChildAskDisplayName(childAsk))")
        }
        return diffs
    }

    private func coordinatorPolicyDisplayTitle(_ policy: CoordinatorMissionPolicySnapshot) -> String {
        let suffix = coordinatorPolicyEditDiffs(policy).isEmpty ? "" : " · edited"
        return "Policy · \(policy.name)\(suffix)"
    }

    private func coordinatorPaceDisplayName(_ pace: CoordinatorMissionPolicyPace) -> String {
        switch pace {
        case .step:
            "Step"
        case .auto:
            "Auto"
        }
    }

    private func coordinatorChildAskDisplayName(_ mode: CoordinatorMissionAutonomyMode) -> String {
        switch mode {
        case .ask:
            "Me"
        case .auto:
            "Director"
        }
    }

    private func coordinatorComposerStopButton(metrics: CoordinatorVisualMetrics) -> some View {
        Button {
            stopCoordinatorMission()
        } label: {
            Image(systemName: isStoppingCoordinatorMission ? "hourglass" : "stop.circle.fill")
                .font(.system(size: metrics.composerSendIconSize, weight: .semibold))
                .frame(width: metrics.sendButtonSize, height: metrics.sendButtonSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.red.opacity(viewModel.canStopSelectedCoordinatorMission ? 0.95 : 0.45))
        .disabled(!viewModel.canStopSelectedCoordinatorMission || isStoppingCoordinatorMission)
        .hoverTooltip("Stop the selected Mission and cancel its live linked sessions without archiving or deleting them.")
    }

    private func coordinatorComposerFeatures() -> ResizableTextFieldFeatures {
        guard let agentModeVM else {
            return .plain
        }
        let props = agentModeVM.makeComposerProps()
        return .agentInputBar(
            fileTagStore: promptManager?.fileManager.workspaceFileContextStore,
            fileTagSearchService: workspaceSearchService,
            fileTagSelectionCoordinator: selectionCoordinator,
            fileTagLookupContextIdentity: AnyHashable(props.fileTagLookupContextIdentity),
            fileTagLookupContextProvider: { [tabID = props.currentTabID] in
                guard let tabID else {
                    return .visibleWorkspace
                }
                return await agentModeVM.agentWorkspaceLookupContext(tabID: tabID)
            },
            fileMentionPickerConfiguration: globalSettings.fileMentionPickerConfiguration(),
            onFileTagCommitted: { _ in },
            slashSkillSuggestionsProvider: { query in
                await agentModeVM.slashSkillSuggestions(for: query)
            }
        )
    }

    private func coordinatorComposerToolsButton(metrics: CoordinatorVisualMetrics) -> some View {
        let props = agentModeVM?.makeComposerProps()
        let isAvailable = props?.hasAvailableAgentProviders == true
            && (props?.selectedAgent == .codexExec || props?.selectedAgent.usesClaudeTooling == true)

        return Button {
            guard isAvailable else { return }
            isCoordinatorToolsPopoverPresented.toggle()
        } label: {
            HStack(spacing: metrics.miniPillIconSpacing) {
                Image(systemName: "server.rack")
                    .font(.system(size: metrics.microIconSize, weight: .medium))
                Text("MCP/Tools")
                    .font(metrics.microMedium)
                    .lineLimit(1)
            }
            .padding(.horizontal, metrics.miniPillHorizontalPadding)
            .padding(.vertical, metrics.miniPillVerticalPadding)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                Capsule(style: .continuous)
                    .fill(isCoordinatorToolsPopoverPresented ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor).opacity(0.22))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAvailable ? (isCoordinatorToolsPopoverPresented ? Color.accentColor : Color.secondary) : Color.secondary.opacity(0.55))
        .disabled(!isAvailable)
        .hoverTooltip(isAvailable ? "Configure MCP and tool settings for Missions. Type / to insert a skill." : "MCP and tool settings are unavailable for this agent.")
        .popover(isPresented: $isCoordinatorToolsPopoverPresented, arrowEdge: .bottom) {
            coordinatorComposerToolsPopover(metrics: metrics)
                .id(coordinatorToolsRevision)
        }
    }

    @ViewBuilder
    private func coordinatorComposerToolsPopover(metrics: CoordinatorVisualMetrics) -> some View {
        if let props = agentModeVM?.makeComposerProps(), props.selectedAgent == .codexExec {
            coordinatorCodexToolsPopoverContent(props, metrics: metrics)
        } else if let props = agentModeVM?.makeComposerProps(), props.selectedAgent.usesClaudeTooling {
            coordinatorClaudeToolsPopoverContent(props, metrics: metrics)
        } else {
            Text("MCP tool settings are unavailable for this agent.")
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(width: 300)
        }
    }

    @ViewBuilder
    private func coordinatorCodexToolsPopoverContent(_ props: AgentComposerProps, metrics: CoordinatorVisualMetrics) -> some View {
        if let agentModeVM, let codexTools = props.providerControls?.codexTools {
            Form {
                if props.runState.isActive {
                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(metrics.micro)
                            Text("Tool settings are locked during an active run")
                                .font(metrics.micro)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Toggle("Bash", isOn: Binding(
                        get: { codexTools.bashToolEnabled },
                        set: { newValue in
                            agentModeVM.setCodexBashToolEnabled(newValue)
                            coordinatorToolsRevision += 1
                        }
                    ))

                    Toggle("Search", isOn: Binding(
                        get: { codexTools.searchToolEnabled },
                        set: { newValue in
                            agentModeVM.setCodexSearchToolEnabled(newValue)
                            coordinatorToolsRevision += 1
                        }
                    ))

                    Toggle("Goals", isOn: Binding(
                        get: { codexTools.goalSupportEnabled },
                        set: { newValue in
                            agentModeVM.setCodexGoalSupportEnabled(newValue)
                            coordinatorToolsRevision += 1
                        }
                    ))
                } header: {
                    Text("Tools")
                }

                Section {
                    if codexTools.mcpServerEntries.isEmpty {
                        Text("No servers in ~/.codex/config.toml")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(codexTools.mcpServerEntries, id: \.normalizedName) { entry in
                            let isRepoPromptServer = entry.normalizedName.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
                            Toggle(
                                isOn: Binding(
                                    get: {
                                        codexTools.mcpServerStatesByNormalizedName[normalizedServerToggleKey(entry.normalizedName)] ?? isRepoPromptServer
                                    },
                                    set: { newValue in
                                        agentModeVM.setCodexMCPServerEnabled(normalizedName: entry.normalizedName, enabled: newValue)
                                        coordinatorToolsRevision += 1
                                    }
                                )
                            ) {
                                HStack(spacing: 4) {
                                    Text(entry.normalizedName)
                                    if isRepoPromptServer {
                                        Text("(required)")
                                            .font(metrics.micro)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .disabled(isRepoPromptServer)
                        }
                    }
                } header: {
                    Text("MCP Servers")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 310)
            .disabled(props.runState.isActive)
        } else {
            Text("Codex tool settings are unavailable until an agent provider is active.")
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(width: 310)
        }
    }

    @ViewBuilder
    private func coordinatorClaudeToolsPopoverContent(_ props: AgentComposerProps, metrics: CoordinatorVisualMetrics) -> some View {
        if let agentModeVM, let claudeTools = props.providerControls?.claudeTools {
            Form {
                ClaudeToolSettingsActiveRunNotice(
                    isVisible: props.selectedAgent.usesClaudeTooling && props.runState.isActive,
                    fontPreset: fontScale.preset
                )

                Section {
                    Toggle("Bash", isOn: Binding(
                        get: { claudeTools.bashToolEnabled },
                        set: { newValue in
                            agentModeVM.setClaudeBashToolEnabled(newValue)
                            coordinatorToolsRevision += 1
                        }
                    ))
                } header: {
                    Text("Tools")
                }

                Section {
                    Toggle("RepoPrompt Only", isOn: Binding(
                        get: { claudeTools.mcpStrictModeEnabled },
                        set: { newValue in
                            agentModeVM.setClaudeMCPStrictModeEnabled(newValue)
                            coordinatorToolsRevision += 1
                        }
                    ))
                } header: {
                    Text("MCP Servers")
                } footer: {
                    Text(
                        claudeTools.mcpStrictModeEnabled
                            ? "Only RepoPrompt MCP is active. Other MCP servers are ignored."
                            : "Other MCP servers from your Claude config will also be loaded."
                    )
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Lazy Tool Loading", isOn: Binding(
                        get: { claudeTools.toolSearchEnabled },
                        set: { newValue in
                            agentModeVM.setClaudeToolSearchEnabled(newValue)
                            coordinatorToolsRevision += 1
                        }
                    ))
                } header: {
                    Text("Tool Search")
                } footer: {
                    Text(
                        claudeTools.toolSearchEnabled
                            ? "Claude searches for each tool before using it. Uses less context but adds latency."
                            : "All tools are preloaded into context. Faster but uses more tokens."
                    )
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Picker(selection: Binding(
                        get: { claudeTools.agentModePromptDelivery },
                        set: { newValue in
                            agentModeVM.setClaudeAgentModePromptDelivery(newValue)
                            coordinatorToolsRevision += 1
                        }
                    )) {
                        ForEach(ClaudeAgentToolPreferences.AgentModePromptDelivery.allCases, id: \.rawValue) { delivery in
                            Text(delivery.displayName).tag(delivery)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } header: {
                    Text("Sys Prompt Packaging")
                } footer: {
                    Text(claudeTools.agentModePromptDelivery.detailText)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 300)
        } else {
            Text("Claude tool settings are unavailable until an agent provider is active.")
                .font(metrics.micro)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(width: 300)
        }
    }

    private func normalizedServerToggleKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func coordinatorComposerAutomationModeToggle(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.composerSegmentedPillSpacing) {
            coordinatorComposerAutomationModeButton(
                title: "Step",
                isSelected: viewModel.missionPaceSelection == .step,
                metrics: metrics
            ) {
                viewModel.setExecutionPace(.step)
            }

            coordinatorComposerAutomationModeButton(
                title: "Auto",
                isSelected: viewModel.missionPaceSelection == .auto,
                metrics: metrics
            ) {
                viewModel.setExecutionPace(.auto)
            }
        }
        .padding(metrics.composerToggleInset)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(CoordinatorStyle.hairline.opacity(0.7), lineWidth: 0.5)
        )
        .accessibilityLabel("Director chat automation mode")
    }

    private func coordinatorComposerChildAskToggle(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.composerSegmentedPillSpacing) {
            coordinatorComposerAutomationModeButton(
                title: "Me",
                isSelected: viewModel.childAskSelection == .ask,
                metrics: metrics
            ) {
                viewModel.setChildAskSelection(.ask)
            }

            coordinatorComposerAutomationModeButton(
                title: "Director",
                isSelected: viewModel.childAskSelection == .auto,
                metrics: metrics
            ) {
                viewModel.setChildAskSelection(.auto)
            }
        }
        .padding(metrics.composerToggleInset)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(CoordinatorStyle.hairline.opacity(0.7), lineWidth: 0.5)
        )
        .accessibilityLabel("Director child question routing")
        .hoverTooltip("Who answers delegated workers' questions. Me pauses for you; Director answers from mission context.")
    }

    private func coordinatorComposerAutomationModeButton(
        title: String,
        isSelected: Bool,
        metrics: CoordinatorVisualMetrics,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(metrics.microMedium)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .padding(.horizontal, metrics.miniPillHorizontalPadding)
                .padding(.vertical, metrics.miniPillVerticalPadding)
                .frame(minWidth: metrics.composerAutomationModeSegmentMinWidth)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.28) : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func coordinatorComposerStatusText(_ rail: CoordinatorModeCoordinatorRail) -> String {
        if isSubmittingCoordinatorDirective {
            return "Sending"
        }
        if let activityText = viewModel.currentRailActivityText, !activityText.isEmpty {
            return activityText
        }
        if let plan = rail.missionPlan {
            switch plan.status {
            case .completed:
                return "Mission complete"
            case .stopped:
                return "Mission stopped"
            case .blocked:
                return "Blocked"
            case .draft, .approved, .running:
                break
            }
        }
        if rail.state == .chooseCoordinator {
            return "Fresh Mission"
        }
        if rail.isComposerSendEnabled {
            return rail.isLiveInCurrentWindow ? "Live" : "Ready"
        }
        return "Director working"
    }

    private func inspectorChildComposer(row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        let availability = childDirectiveAvailability(for: row)
        let isExpanded = isChildComposerExpanded || isSubmittingChildDirective || !childDirectiveDraft.isEmpty

        return Group {
            if case .openToReply = availability {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: metrics.smallSpacing) {
                    if isExpanded, let notice = childDirectiveNotice ?? availability.notice(for: row), !notice.isEmpty {
                        coordinatorComposerNotice(notice, metrics: metrics)
                    }

                    if isExpanded {
                        inspectorExpandedChildComposer(row: row, availability: availability, metrics: metrics)
                    } else {
                        inspectorCollapsedChildComposer(row: row, availability: availability, metrics: metrics)
                    }
                }
            }
        }
    }

    private func inspectorCollapsedChildComposer(
        row: CoordinatorModeRow,
        availability: ChildDirectiveAvailability,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        Button {
            switch availability {
            case .ready:
                isChildComposerExpanded = true
                isChildComposerFocused = true
            case let .openToReply(route):
                onOpenAgentChat(route)
            case .blocked:
                return
            }
        } label: {
            HStack(spacing: metrics.controlSpacing) {
                Image(systemName: availability.iconName)
                    .font(.system(size: metrics.smallIconSize, weight: .semibold))
                    .foregroundStyle(availability.canAct ? Color.accentColor : Color.secondary.opacity(0.7))

                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    Text(availability.title)
                        .font(metrics.bodyMedium)
                        .foregroundStyle(availability.canAct ? .primary : .secondary)
                    Text(availability.notice(for: row) ?? "")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: metrics.controlSpacing)

                HStack(spacing: metrics.miniPillIconSpacing) {
                    Circle()
                        .fill(availability.canAct ? Color.green.opacity(0.82) : Color.secondary.opacity(0.55))
                        .frame(width: metrics.composerStatusDotSize, height: metrics.composerStatusDotSize)
                    Text(availability.status)
                        .font(metrics.microMedium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, metrics.composerHorizontalPadding)
            .padding(.vertical, metrics.childComposerCollapsedVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!availability.canAct)
        .background(
            RoundedRectangle(cornerRadius: metrics.composerCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.composerCornerRadius, style: .continuous)
                .stroke(CoordinatorStyle.hairline.opacity(1.08), lineWidth: 1)
        )
        .hoverTooltip(availability.notice(for: row) ?? "Reply to \(row.title)")
    }

    private func inspectorExpandedChildComposer(
        row: CoordinatorModeRow,
        availability: ChildDirectiveAvailability,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(alignment: .bottom, spacing: metrics.smallSpacing) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: metrics.smallIconSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(height: metrics.childComposerTextMinHeight)

            TextField("Reply to \(row.title)...", text: $childDirectiveDraft, axis: .vertical)
                .lineLimit(1 ... 3)
                .textFieldStyle(.plain)
                .font(metrics.body)
                .disabled(!availability.canEdit)
                .focused($isChildComposerFocused)
                .onSubmit {
                    submitChildDirective(to: row)
                }
                .frame(minHeight: metrics.childComposerTextMinHeight, alignment: .center)

            if childDirectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSubmittingChildDirective {
                Button {
                    isChildComposerExpanded = false
                    isChildComposerFocused = false
                    childDirectiveNotice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: metrics.microIconSize, weight: .semibold))
                        .frame(width: metrics.sendButtonSize, height: metrics.sendButtonSize)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary.opacity(0.68))
                .hoverTooltip("Collapse")
            }

            Button {
                submitChildDirective(to: row)
            } label: {
                Image(systemName: isSubmittingChildDirective ? "hourglass" : "paperplane.fill")
                    .font(.system(size: metrics.composerSendIconSize, weight: .semibold))
                    .frame(width: metrics.sendButtonSize, height: metrics.sendButtonSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSubmitChildDirective(to: row) ? Color.accentColor : Color.secondary.opacity(0.55))
            .disabled(!canSubmitChildDirective(to: row))
            .hoverTooltip(isSubmittingChildDirective ? "Sending" : "Reply")
        }
        .padding(.horizontal, metrics.composerHorizontalPadding)
        .padding(.vertical, metrics.childComposerExpandedVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: metrics.composerCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.composerCornerRadius, style: .continuous)
                .stroke(canSubmitChildDirective(to: row) ? Color.accentColor.opacity(0.48) : CoordinatorStyle.hairline.opacity(1.2), lineWidth: 1)
        )
        .onAppear {
            guard availability.canEdit else { return }
            isChildComposerFocused = true
        }
    }

    private func childDirectiveAvailability(for row: CoordinatorModeRow) -> ChildDirectiveAvailability {
        guard row.tabID != nil, !row.isPersistedOnly else {
            if let route = row.openAgentChatRoute {
                return .openToReply(route)
            }
            return .blocked(status: "Unavailable", notice: "This session is not live in the current window.")
        }
        guard row.runState != .running else {
            return .blocked(status: "Working", notice: "Waiting for this session to reach a turn boundary.")
        }
        return .ready(status: row.runState.displayName)
    }

    private func coordinatorComposerNotice(_ text: String, metrics: CoordinatorVisualMetrics) -> some View {
        Text(text)
            .font(metrics.micro)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canSubmitCoordinatorDirective: Bool {
        let pendingChildRow = viewModel.activePendingChildInteractionRow()
        return (
            viewModel.snapshot.coordinatorRail.isComposerSendEnabled
                || viewModel.snapshot.coordinatorRail.state == .chooseCoordinator
                || pendingChildRow != nil
        )
            && !isSubmittingCoordinatorDirective
            && !coordinatorDirectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canEditCoordinatorDirective(_ rail: CoordinatorModeCoordinatorRail) -> Bool {
        viewModel.activePendingChildInteractionRow() != nil || rail.state == .chooseCoordinator || rail.isComposerEnabled
    }

    private func canSubmitChildDirective(to row: CoordinatorModeRow) -> Bool {
        childDirectiveAvailability(for: row).canEdit
            && !isSubmittingChildDirective
            && !childDirectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitCoordinatorDirective() {
        let draft = coordinatorDirectiveDraft
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              canSubmitCoordinatorDirective
        else { return }
        if let pendingChildRow = viewModel.activePendingChildInteractionRow() {
            submitPendingChildInteractionResponse(draft, to: pendingChildRow)
            return
        }
        coordinatorDirectiveDraft = ""
        isSubmittingCoordinatorDirective = true
        isCoordinatorComposerFocused = true
        Task { @MainActor in
            let result = await viewModel.submitCoordinatorDirective(draft)
            if result != .accepted, coordinatorDirectiveDraft.isEmpty {
                coordinatorDirectiveDraft = draft
            }
            isSubmittingCoordinatorDirective = false
            isCoordinatorComposerFocused = true
        }
    }

    private func submitPendingChildInteractionResponse(_ draft: String, to row: CoordinatorModeRow) {
        submitPendingChildInteractionResponse(.text(draft), to: row, fallbackDraft: draft, clearStructuredDraftsFor: nil)
    }

    private func submitPendingChildInteractionResponse(
        _ submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission,
        to row: CoordinatorModeRow,
        fallbackDraft: String = "",
        clearStructuredDraftsFor interactionID: UUID?
    ) {
        coordinatorDirectiveDraft = ""
        isSubmittingCoordinatorDirective = true
        isCoordinatorComposerFocused = true
        Task { @MainActor in
            let result = await viewModel.submitPendingChildInteractionResponse(submission, to: row)
            if result == .accepted, let interactionID {
                coordinatorCheckpointDrafts[interactionID] = nil
                coordinatorCheckpointQuestionIndex[interactionID] = nil
            } else if result != .accepted, coordinatorDirectiveDraft.isEmpty {
                coordinatorDirectiveDraft = fallbackDraft
            }
            isSubmittingCoordinatorDirective = false
            isCoordinatorComposerFocused = true
        }
    }

    private func submitCoordinatorContinuation(_ action: CoordinatorModeViewModel.ContinuationAction) {
        guard viewModel.snapshot.coordinatorRail.state == .selected,
              viewModel.snapshot.coordinatorRail.isComposerSendEnabled,
              !isSubmittingCoordinatorDirective
        else { return }
        coordinatorDirectiveDraft = ""
        isSubmittingCoordinatorDirective = true
        isCoordinatorComposerFocused = true
        Task { @MainActor in
            _ = await viewModel.submitCoordinatorContinuation(action)
            isSubmittingCoordinatorDirective = false
            isCoordinatorComposerFocused = true
        }
    }

    private func submitPendingFollowThroughEvent(_ event: CoordinatorFollowThroughEvent) {
        guard viewModel.snapshot.coordinatorRail.state == .selected,
              viewModel.snapshot.coordinatorRail.isComposerSendEnabled,
              !isSubmittingCoordinatorDirective
        else { return }
        coordinatorDirectiveDraft = ""
        isSubmittingCoordinatorDirective = true
        isCoordinatorComposerFocused = true
        Task { @MainActor in
            _ = await viewModel.submitPendingFollowThroughEvent(event)
            isSubmittingCoordinatorDirective = false
            isCoordinatorComposerFocused = true
        }
    }

    private func resolvePendingFollowThroughEvent(
        _ event: CoordinatorFollowThroughEvent,
        then continuation: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            await viewModel.resolvePendingFollowThroughEvent(event)
            continuation()
        }
    }

    private func stopCoordinatorMission() {
        guard viewModel.canStopSelectedCoordinatorMission, !isStoppingCoordinatorMission else { return }
        isStoppingCoordinatorMission = true
        Task { @MainActor in
            _ = await viewModel.stopSelectedCoordinatorMission()
            isStoppingCoordinatorMission = false
            isCoordinatorComposerFocused = true
        }
    }

    private func submitChildDirective(to row: CoordinatorModeRow) {
        let draft = childDirectiveDraft
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              canSubmitChildDirective(to: row)
        else { return }
        childDirectiveDraft = ""
        childDirectiveNotice = nil
        isSubmittingChildDirective = true
        isChildComposerFocused = true
        Task { @MainActor in
            let result = await viewModel.submitChildDirective(draft, to: row)
            if result != .accepted, childDirectiveDraft.isEmpty {
                childDirectiveDraft = draft
            }
            if case let .rejected(message) = result {
                childDirectiveNotice = message.isEmpty ? nil : message
            }
            isSubmittingChildDirective = false
            isChildComposerFocused = true
        }
    }

    private func resetChildDirectiveComposer() {
        childDirectiveDraft = ""
        childDirectiveNotice = nil
        isSubmittingChildDirective = false
        isChildComposerExpanded = false
    }

    private func selectDelegatedActionTarget(_ row: CoordinatorModeRow?) {
        guard let row else { return }
        if isFilteringAllAgentsBoard,
           !filteredSections(from: viewModel.snapshot).flatMap(\.rows).contains(where: { $0.id == row.id })
        {
            filterText = ""
        }
        selectedRowID = row.id
        isInspectorVisible = true
    }

    private func clearSelectedRow() {
        selectedRowID = nil
        isInspectorVisible = false
    }

    private func inspectorObjectSubtitle(for row: CoordinatorModeRow) -> String {
        var parts = [row.runState.displayName]
        if let providerName = row.providerName {
            parts.append(providerName)
        }
        parts.append(row.isMCPOriginated ? "MCP originated" : "App originated")
        return parts.joined(separator: " · ")
    }

    private func emptyState(snapshot: CoordinatorModeSnapshot, metrics: CoordinatorVisualMetrics) -> some View {
        let isAllAgents = snapshot.boardScope == .allAgents
        return VStack(spacing: metrics.columnSpacing) {
            Image(systemName: snapshot.workspaceID == nil ? "folder.badge.questionmark" : "rectangle.3.group.bubble")
                .font(.system(size: metrics.emptyStateIconSize))
                .foregroundStyle(.secondary)
            Text(snapshot.workspaceID == nil ? "Open a workspace" : (isAllAgents ? "No active delegated work yet" : "No delegated work yet"))
                .font(metrics.headerTitle)
            Text(isAllAgents ? "The Agent Board shows live delegated work across Director Missions." : "The board shows delegated work from the selected Mission.")
                .font(metrics.sectionTitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowMetadata(
        _ row: CoordinatorModeRow,
        boardScope: CoordinatorModeBoardScope,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let showsParentCoordinator = boardScope == .allAgents && row.parentCoordinator != nil
        if row.workflow != nil || showsParentCoordinator || row.origin == .directAgent {
            HStack(spacing: metrics.smallSpacing) {
                if let workflow = row.workflow {
                    workflowBadge(workflow, metrics: metrics)
                }
                if showsParentCoordinator, let parentCoordinator = row.parentCoordinator {
                    parentCoordinatorBadge(parentCoordinator, metrics: metrics)
                } else if row.origin == .directAgent {
                    directAgentBadge(metrics: metrics)
                }
            }
        }
    }

    private func parentCoordinatorBadge(
        _ parentCoordinator: CoordinatorModeRow.ParentCoordinator,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(spacing: metrics.miniPillIconSpacing) {
            Image(systemName: "rectangle.3.group.bubble")
                .font(.system(size: metrics.microIconSize, weight: .semibold))
            Text(parentCoordinator.title)
                .font(metrics.microMedium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, metrics.miniPillHorizontalPadding)
        .padding(.vertical, metrics.miniPillVerticalPadding)
        .background(Capsule().fill(Color.secondary.opacity(parentCoordinator.isSelected ? 0.14 : 0.08)))
        .overlay(Capsule().stroke(Color.secondary.opacity(parentCoordinator.isSelected ? 0.24 : 0.16), lineWidth: 0.5))
    }

    private func directAgentBadge(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.miniPillIconSpacing) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: metrics.microIconSize, weight: .semibold))
            Text("Direct")
                .font(metrics.microMedium)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, metrics.miniPillHorizontalPadding)
        .padding(.vertical, metrics.miniPillVerticalPadding)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5))
    }

    @ViewBuilder
    private func selectedParentEmphasis(_ row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        if row.parentCoordinator?.isSelected == true {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.secondary.opacity(0.34))
                .frame(width: 2)
                .padding(.vertical, metrics.smallSpacing)
                .padding(.leading, 1)
        }
    }

    private func workflowBadge(_ workflow: CoordinatorModeWorkflowDisplaySummary, metrics: CoordinatorVisualMetrics) -> some View {
        let tint = workflowTint(workflow)
        return HStack(spacing: metrics.miniPillIconSpacing) {
            Image(systemName: workflow.iconName)
                .font(.system(size: metrics.microIconSize, weight: .semibold))
            Text(workflow.displayName)
                .font(metrics.microMedium)
                .lineLimit(1)
        }
        .foregroundStyle(tint.opacity(0.9))
        .padding(.horizontal, metrics.miniPillHorizontalPadding)
        .padding(.vertical, metrics.miniPillVerticalPadding)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().stroke(tint.opacity(0.2), lineWidth: 0.5))
    }

    private func workflowTint(_: CoordinatorModeWorkflowDisplaySummary) -> Color {
        .secondary
    }

    private func workflowBadge(_ workflowHint: CoordinatorMissionPlanNodeWorkflowHint, metrics: CoordinatorVisualMetrics) -> some View {
        let tint = workflowTint(workflowHint)
        return HStack(spacing: metrics.miniPillIconSpacing) {
            Image(systemName: workflowIconName(workflowHint))
                .font(.system(size: metrics.microIconSize, weight: .semibold))
            Text(workflowHint.name)
                .font(metrics.microMedium)
                .lineLimit(1)
        }
        .foregroundStyle(tint.opacity(0.9))
        .padding(.horizontal, metrics.miniPillHorizontalPadding)
        .padding(.vertical, metrics.miniPillVerticalPadding)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().stroke(tint.opacity(0.2), lineWidth: 0.5))
    }

    private func missionPlanWorkflowMismatch(
        node: CoordinatorMissionPlanNode,
        boundRow: CoordinatorModeRow?
    ) -> String? {
        guard let plannedWorkflow = node.workflowHint,
              let boundRow
        else { return nil }
        if let workflow = boundRow.workflow,
           workflowHint(plannedWorkflow, matches: workflow)
        {
            return nil
        }
        let actual = boundRow.workflow?.displayName ?? "none"
        return "Planned workflow \(plannedWorkflow.name) does not match bound session workflow \(actual). Use agent_run with the node workflow, or revise the Mission Plan."
    }

    private func workflowHint(
        _ planned: CoordinatorMissionPlanNodeWorkflowHint,
        matches actual: CoordinatorModeWorkflowDisplaySummary
    ) -> Bool {
        let actualKeys = [
            actual.id,
            actual.displayName
        ].map(normalizedWorkflowComparisonKey)
        let plannedKeys = [
            planned.id,
            planned.name
        ].compactMap(\.self).map(normalizedWorkflowComparisonKey)
        return !Set(actualKeys).isDisjoint(with: plannedKeys)
    }

    private func normalizedWorkflowComparisonKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func workflowIconName(_ workflowHint: CoordinatorMissionPlanNodeWorkflowHint) -> String {
        if let iconName = workflowHint.iconName {
            return iconName
        }
        return builtInWorkflow(for: workflowHint)?.iconName ?? "arrow.triangle.branch"
    }

    private func workflowTint(_: CoordinatorMissionPlanNodeWorkflowHint) -> Color {
        .secondary
    }

    private func builtInWorkflow(for workflowHint: CoordinatorMissionPlanNodeWorkflowHint) -> AgentWorkflow? {
        AgentWorkflow.allCases.first { workflow in
            workflowHint.id == workflow.definition.id
                || workflowHint.id == workflow.rawValue
                || workflowHint.name.caseInsensitiveCompare(workflow.displayName) == .orderedSame
        }
    }

    private func worktreeLabel(_ worktree: CoordinatorModeRow.Workstream, metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.miniPillIconSpacing) {
            worktreeMarker(worktree, metrics: metrics)
            Text(worktree.branch ?? worktree.label)
                .font(metrics.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .hoverTooltip(worktreeTooltip(worktree))
        .accessibilityLabel("Worktree \(worktree.label)")
    }

    private func worktreeMarker(_ worktree: CoordinatorModeRow.Workstream, metrics _: CoordinatorVisualMetrics) -> some View {
        Circle()
            .fill(worktreeTint(worktree))
            .frame(width: 7, height: 7)
            .overlay(
                Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }

    private func worktreeTint(_ worktree: CoordinatorModeRow.Workstream) -> Color {
        if let hex = worktree.colorHex, let color = Color(hex: hex) {
            return color
        }
        return .secondary
    }

    private func worktreeTooltip(_ worktree: CoordinatorModeRow.Workstream) -> String {
        var parts = ["Worktree \(worktree.label)"]
        if let branch = worktree.branch, branch != worktree.label {
            parts.append("branch \(branch)")
        }
        return parts.joined(separator: " · ")
    }

    private func workstreamNextActionHint(
        _ action: CoordinatorModeRow.WorkstreamSummary.NextAction,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(spacing: metrics.smallSpacing) {
            Image(systemName: action.kind.systemImage)
                .font(.system(size: metrics.microIconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: metrics.titlebarIconSize, height: metrics.titlebarIconSize)

            Text(action.title)
                .font(metrics.microMedium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.top, metrics.tightSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workstreamInspector(
        _ summary: CoordinatorModeRow.WorkstreamSummary,
        row: CoordinatorModeRow,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        inspectorGroup("Workstream", metrics: metrics) {
            HStack(spacing: metrics.smallSpacing) {
                Image(systemName: summary.phase.systemImage)
                    .font(.system(size: metrics.smallIconSize, weight: .semibold))
                    .foregroundStyle(summary.phase.tint)
                Text(summary.phase.displayName)
                    .font(metrics.bodySemibold)
                Spacer(minLength: metrics.controlSpacing)
                if let action = summary.nextAction {
                    statusChip(action.title, color: summary.phase.tint, metrics: metrics)
                }
            }

            keyValue("Objective", summary.objective, metrics: metrics)
            if let parentCoordinator = row.parentCoordinator {
                keyValue("Director", parentCoordinator.title, metrics: metrics)
            }
            if let declared = summary.declaredWorkstream {
                if !declared.purpose.isEmpty {
                    keyValue("Purpose", declared.purpose, metrics: metrics)
                }
                if let role = declared.role {
                    keyValue("Role", role, metrics: metrics)
                }
                keyValue("Policy", declared.defaultPolicy.displayName, metrics: metrics)
                keyValue("Worktree strategy", declared.worktreeStrategy.mode.displayName, metrics: metrics)
                if let baseRef = declared.worktreeStrategy.baseRef {
                    keyValue("Worktree base", baseRef, metrics: metrics)
                }
                if let baseReason = declared.worktreeStrategy.baseReason {
                    keyValue("Base reason", baseReason, metrics: metrics)
                }
                if let reason = declared.worktreeStrategy.reason {
                    keyValue("Strategy reason", reason, metrics: metrics)
                }
                if !declared.relatedSessionIDs.isEmpty {
                    keyValue("Linked sessions", "\(declared.linkedSessionIDs.count)", metrics: metrics)
                }
                if let worktreeID = declared.worktreeID {
                    keyValue("Declared worktree", worktreeID, metrics: metrics)
                }
            }
            if let workflow = summary.workflow {
                keyValue("Workflow", workflow.displayName, metrics: metrics)
            }
            if let worktree = summary.worktree {
                keyValue("Worktree", metrics: metrics) {
                    worktreeLabel(worktree, metrics: metrics)
                }
                if let branch = worktree.branch {
                    keyValue("Branch", branch, metrics: metrics)
                }
            }
            if let action = summary.nextAction, let detail = action.detail {
                Text(detail)
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func openAgentChatButton(route: AgentSessionDeepLinkRoute?, title: String, metrics: CoordinatorVisualMetrics) -> some View {
        Group {
            if let route {
                Button(title) {
                    onOpenAgentChat(route)
                }
                .buttonStyle(.link)
                .font(metrics.bodyMedium)
            } else {
                Text("Agent chat unavailable")
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func inspectorOpenAgentButton(route: AgentSessionDeepLinkRoute?, metrics: CoordinatorVisualMetrics) -> some View {
        if let route {
            Button {
                onOpenAgentChat(route)
            } label: {
                Label("Open Agent", systemImage: "arrow.up.forward.app")
                    .font(metrics.bodyMedium)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, metrics.controlHorizontalPadding)
                    .padding(.vertical, metrics.controlVerticalPadding)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.accentColor.opacity(0.24), lineWidth: 0.8)
            )
            .hoverTooltip("Open this session in Agent Mode")
        } else {
            Label("Unavailable", systemImage: "arrow.up.forward.app")
                .font(metrics.bodyMedium)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .padding(.horizontal, metrics.controlHorizontalPadding)
                .padding(.vertical, metrics.controlVerticalPadding)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.22))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(CoordinatorStyle.hairline.opacity(1.1), lineWidth: 0.8)
                )
        }
    }

    private func statusChip(_ text: String, color: Color, metrics: CoordinatorVisualMetrics) -> some View {
        CoordinatorPill(
            title: text,
            tint: color,
            font: metrics.chip,
            horizontalPadding: metrics.miniPillHorizontalPadding,
            verticalPadding: metrics.miniPillVerticalPadding
        )
    }

    private func inspectorGroup(
        _ title: String,
        metrics: CoordinatorVisualMetrics,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            Text(title)
                .font(metrics.cardTitle)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .coordinatorCardBackground(cornerRadius: metrics.cardCornerRadius, fillOpacity: CoordinatorStyle.groupedFillOpacity)
    }

    private func keyValue(_ key: String, _ value: String, metrics: CoordinatorVisualMetrics) -> some View {
        keyValue(key, metrics: metrics) {
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func keyValue(_ key: String, metrics: CoordinatorVisualMetrics, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer(minLength: metrics.controlSpacing)
            value()
        }
        .font(metrics.body)
    }

    private func filteredSections(from snapshot: CoordinatorModeSnapshot) -> [CoordinatorModeStatusSection] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.boardScope == .allAgents, !query.isEmpty else { return snapshot.groups }
        return snapshot.groups.map { section in
            CoordinatorModeStatusSection(
                group: section.group,
                rows: section.rows.filter { row in
                    row.title.localizedCaseInsensitiveContains(query)
                        || row.providerName?.localizedCaseInsensitiveContains(query) == true
                        || row.modelName?.localizedCaseInsensitiveContains(query) == true
                        || row.workstream?.label.localizedCaseInsensitiveContains(query) == true
                        || row.workstreamSummary?.objective.localizedCaseInsensitiveContains(query) == true
                        || row.workstreamSummary?.nextAction?.title.localizedCaseInsensitiveContains(query) == true
                }
            )
        }
    }

    private var isFilteringAllAgentsBoard: Bool {
        viewModel.snapshot.boardScope == .allAgents && !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectedRow(in sections: [CoordinatorModeStatusSection]) -> CoordinatorModeRow? {
        guard let selectedRowID else { return nil }
        return sections.flatMap(\.rows).first { $0.id == selectedRowID }
    }

    private func inspectorTarget(
        snapshot _: CoordinatorModeSnapshot,
        sections _: [CoordinatorModeStatusSection],
        selectedRow: CoordinatorModeRow?
    ) -> InspectorTarget? {
        selectedRow.map(InspectorTarget.row)
    }

    private func selectedPlanNode(
        in plan: CoordinatorMissionPlan?,
        sections: [CoordinatorModeStatusSection]
    ) -> (node: CoordinatorMissionPlanNode, workstream: CoordinatorMissionWorkstreamSummary?, plan: CoordinatorMissionPlan, boundRow: CoordinatorModeRow?)? {
        guard let plan, let selectedPlanNodeID else { return nil }
        guard let node = plan.nodes.first(where: { $0.id == selectedPlanNodeID }) else { return nil }
        let workstream = plan.workstreams.first { $0.id == node.workstreamID }
        let rows = sections.flatMap(\.rows)
        let boundRow = node.boundSessionID.flatMap { sessionID in
            rows.first { $0.sessionID == sessionID }
        }
        return (node, workstream, plan, boundRow)
    }

    private func reconcileSelection() {
        let allRows = filteredSections(from: viewModel.snapshot).flatMap(\.rows)
        if let selectedRowID, allRows.contains(where: { $0.id == selectedRowID }) {
            return
        }
        selectedRowID = allRows.first?.id
    }

    private func reconcilePlanSelection() {
        guard let selectedPlanNodeID else { return }
        let nodeIDs = Set(viewModel.snapshot.coordinatorRail.missionPlan?.nodes.map(\.id) ?? [])
        if !nodeIDs.contains(selectedPlanNodeID) {
            self.selectedPlanNodeID = nil
        }
    }

    private func dependencyTitle(_ id: UUID, in plan: CoordinatorMissionPlan) -> String {
        if let node = plan.nodes.first(where: { $0.id == id }) {
            return node.title
        }
        return shortID(id)
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}

private struct CoordinatorTerminalTranscriptDisclosure<EntryContent: View>: View {
    let entries: [CoordinatorModeRailTranscriptEntry]
    let metrics: CoordinatorVisualMetrics
    let isDisabled: Bool
    private let entryContent: (CoordinatorModeRailTranscriptEntry) -> EntryContent

    @State private var isExpanded = false

    init(
        entries: [CoordinatorModeRailTranscriptEntry],
        metrics: CoordinatorVisualMetrics,
        isDisabled: Bool,
        @ViewBuilder entryContent: @escaping (CoordinatorModeRailTranscriptEntry) -> EntryContent
    ) {
        self.entries = entries
        self.metrics = metrics
        self.isDisabled = isDisabled
        self.entryContent = entryContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: metrics.smallSpacing) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: metrics.microIconSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: metrics.microIconSize)
                    Label("Transcript · \(entries.count)", systemImage: "text.bubble")
                        .font(metrics.microMedium)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: metrics.smallSpacing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            if isExpanded {
                VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
                    ForEach(entries) { entry in
                        entryContent(entry)
                    }
                }
                .padding(.top, metrics.tightSpacing)
            }
        }
        .padding(metrics.pendingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 0.75)
        )
    }
}

private struct CoordinatorRailToggleButton: View {
    let isRailVisible: Bool
    let metrics: CoordinatorVisualMetrics
    var systemImage = "sidebar.left"
    var visibleAccessibilityLabel = "Hide Coordinator Rail"
    var hiddenAccessibilityLabel = "Show Coordinator Rail"
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.titlebarIconSize, weight: .medium))
                .foregroundStyle(.primary.opacity(isHovering ? 0.95 : 0.68))
                .frame(width: metrics.titlebarButtonSize, height: metrics.titlebarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: metrics.titlebarButtonCornerRadius, style: .continuous)
                .fill(titlebarButtonFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.titlebarButtonCornerRadius, style: .continuous)
                .stroke(CoordinatorStyle.hairline.opacity(isHovering ? 1 : 0), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .hoverTooltip(isRailVisible ? visibleAccessibilityLabel : hiddenAccessibilityLabel)
        .accessibilityLabel(isRailVisible ? visibleAccessibilityLabel : hiddenAccessibilityLabel)
    }

    private var titlebarButtonFill: Color {
        isHovering ? Color.primary.opacity(0.08) : Color.clear
    }
}

private struct CoordinatorVisualMetrics {
    let fontPreset: FontScalePreset

    var headerTitle: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold)
    }

    var sectionTitle: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold)
    }

    var inspectorTitle: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 14, weight: .semibold)
    }

    var cardTitle: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold)
    }

    var body: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 11)
    }

    var bodyMedium: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium)
    }

    var bodySemibold: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold)
    }

    var micro: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 10)
    }

    var microMedium: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium)
    }

    var chip: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium)
    }

    var searchFont: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 13)
    }

    var railAvailableWidth: CGFloat {
        fontPreset.scaledClamped(1040, min: 1040, max: 1180)
    }

    var railWidth: CGFloat {
        AgentSidebarSizing.idealWidth(for: fontPreset)
    }

    var collapsedRailWidth: CGFloat {
        fontPreset.scaledClamped(42, min: 38, max: 48)
    }

    var centerChatMinWidth: CGFloat {
        fontPreset.scaledClamped(500, min: 460, max: 620)
    }

    var rightWorkPanelWidth: CGFloat {
        fontPreset.scaledClamped(600, min: 560, max: 720)
    }

    var draftSurfaceMaxWidth: CGFloat {
        fontPreset.scaledClamped(880, min: 780, max: 960)
    }

    var rightBoardHeight: CGFloat {
        fontPreset.scaledClamped(430, min: 380, max: 560)
    }

    var inspectorWidth: CGFloat {
        fontPreset.scaledClamped(300, min: 300, max: 360)
    }

    var inspectorHandleWidth: CGFloat {
        fontPreset.scaledClamped(46, min: 40, max: 58)
    }

    var inspectorHandleHeight: CGFloat {
        fontPreset.scaledClamped(4, min: 3, max: 5)
    }

    var inspectorHandleVerticalPadding: CGFloat {
        fontPreset.scaledClamped(7, min: 6, max: 10)
    }

    var boardColumnWidth: CGFloat {
        fontPreset.scaledClamped(206, min: 196, max: 248)
    }

    var boardColumnCompactWidth: CGFloat {
        fontPreset.scaledClamped(150, min: 140, max: 170)
    }

    var boardColumnMinHeight: CGFloat {
        fontPreset.scaledClamped(360, min: 360, max: 480)
    }

    var controlWidth: CGFloat {
        fontPreset.scaledClamped(160, min: 160, max: 190)
    }

    var scopeControlWidth: CGFloat {
        fontPreset.scaledClamped(210, min: 210, max: 250)
    }

    var sortControlWidth: CGFloat {
        fontPreset.scaledClamped(190, min: 190, max: 230)
    }

    var reviewGateControlWidth: CGFloat {
        fontPreset.scaledClamped(188, min: 188, max: 228)
    }

    var automationModeControlWidth: CGFloat {
        fontPreset.scaledClamped(178, min: 178, max: 214)
    }

    var composerToggleInset: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    var composerSegmentedPillSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    var composerAutomationModeSegmentMinWidth: CGFloat {
        fontPreset.scaledClamped(46, min: 42, max: 56)
    }

    var headerControlHeight: CGFloat {
        fontPreset.scaledClamped(34, min: 34, max: 42)
    }

    var headerControlInset: CGFloat {
        fontPreset.scaledClamped(4, max: 5)
    }

    var headerSegmentHeight: CGFloat {
        max(headerControlHeight - (headerControlInset * 2), 26)
    }

    var headerSegmentSpacing: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    var headerSegmentHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    var headerControlHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
    }

    var searchWidth: CGFloat {
        fontPreset.scaledClamped(240, min: 240, max: 300)
    }

    var bottomSearchMaxWidth: CGFloat {
        fontPreset.scaledClamped(360, min: 360, max: 460)
    }

    var outerPadding: CGFloat {
        fontPreset.scaledClamped(16, max: 22)
    }

    var headerPadding: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
    }

    var sidebarHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    var sidebarVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    var railTitlebarLaneHeight: CGFloat {
        fontPreset.scaledClamped(34, min: 34, max: 42)
    }

    var titlebarButtonSize: CGFloat {
        fontPreset.scaledClamped(28, min: 28, max: 34)
    }

    var titlebarButtonCornerRadius: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    var titlebarIconSize: CGFloat {
        fontPreset.scaledClamped(15, max: 18)
    }

    var sectionSpacing: CGFloat {
        fontPreset.scaledClamped(14, max: 18)
    }

    var boardColumnSpacing: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
    }

    var columnSpacing: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    var controlSpacing: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    var controlHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    var controlVerticalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    var smallSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    var tightSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    var cardInnerSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    var sessionCardInnerSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    var cardPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    var sessionCardPadding: CGFloat {
        fontPreset.scaledClamped(9, max: 12)
    }

    var emptyColumnPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 12)
    }

    var columnPadding: CGFloat {
        fontPreset.scaledClamped(9, max: 12)
    }

    var pendingPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    var coordinatorMissionRowHeight: CGFloat {
        fontPreset.scaledClamped(42, min: 42, max: 50)
    }

    var navigationBadgeSize: CGFloat {
        fontPreset.scaledClamped(20, min: 20, max: 26)
    }

    var footerVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    var miniPillHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(7, max: 10)
    }

    var miniPillVerticalPadding: CGFloat {
        fontPreset.scaledClamped(3, max: 5)
    }

    var listRowVerticalPadding: CGFloat {
        fontPreset.scaledClamped(7, max: 9)
    }

    var listRowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    var listRowSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    var listColumnSpacing: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
    }

    var listStateColumnWidth: CGFloat {
        fontPreset.scaledClamped(92, min: 92, max: 118)
    }

    var listIdentityColumnWidth: CGFloat {
        fontPreset.scaledClamped(150, min: 150, max: 210)
    }

    var listWorkstreamColumnWidth: CGFloat {
        fontPreset.scaledClamped(150, min: 150, max: 220)
    }

    var listUpdatedColumnWidth: CGFloat {
        fontPreset.scaledClamped(72, min: 72, max: 92)
    }

    var listOpenColumnWidth: CGFloat {
        fontPreset.scaledClamped(54, min: 54, max: 68)
    }

    var cardCornerRadius: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    var headerPillCornerRadius: CGFloat {
        fontPreset.scaledClamped(16, max: 20)
    }

    var columnCornerRadius: CGFloat {
        fontPreset.scaledClamped(14, max: 18)
    }

    var pendingCornerRadius: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    var sidebarRowCornerRadius: CGFloat {
        fontPreset.scaledClamped(16, max: 20)
    }

    var searchCornerRadius: CGFloat {
        fontPreset.scaledClamped(16, max: 20)
    }

    var searchElementSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    var searchHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    var searchVerticalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
    }

    var searchControlHeight: CGFloat {
        fontPreset.scaledClamped(30, min: 30, max: 40)
    }

    var searchIconSize: CGFloat {
        fontPreset.scaledClamped(14, max: 18)
    }

    var searchClearIconSize: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
    }

    var statusDotSize: CGFloat {
        fontPreset.scaledClamped(8, max: 10)
    }

    var smallIconSize: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
    }

    var microIconSize: CGFloat {
        fontPreset.scaledClamped(10, max: 13)
    }

    var sendButtonSize: CGFloat {
        fontPreset.scaledClamped(28, min: 28, max: 34)
    }

    var composerSendIconSize: CGFloat {
        fontPreset.scaledClamped(14, max: 18)
    }

    var composerTextMinHeight: CGFloat {
        fontPreset.scaledClamped(38, min: 36, max: 48)
    }

    var composerControlStripHeight: CGFloat {
        fontPreset.scaledClamped(40, min: 40, max: 48)
    }

    var composerFooterHeight: CGFloat {
        fontPreset.scaledClamped(28, min: 24, max: 32)
    }

    var childComposerTextMinHeight: CGFloat {
        fontPreset.scaledClamped(30, min: 30, max: 38)
    }

    var coordinatorComposerChromeVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 8)
    }

    var coordinatorComposerChromeInnerSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 2)
    }

    var composerHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
    }

    var composerVerticalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    var childComposerCollapsedVerticalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 13)
    }

    var childComposerExpandedVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    var composerControlHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    var composerStatusDotSize: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    var miniPillIconSpacing: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    var conversationMinHeight: CGFloat {
        fontPreset.scaledClamped(220, min: 220, max: 300)
    }

    var userBubbleMaxWidth: CGFloat {
        fontPreset.scaledClamped(300, min: 300, max: 360)
    }

    var composerCornerRadius: CGFloat {
        fontPreset.scaledClamped(18, min: 18, max: 22)
    }

    var emptyStateIconSize: CGFloat {
        fontPreset.scaledClamped(32, max: 40)
    }
}

private enum CoordinatorStyle {
    static let cardFillOpacity = CoordinatorTheme.Opacity.cardFill
    static let groupedFillOpacity = CoordinatorTheme.Opacity.groupedFill
    static let railCardFillOpacity = CoordinatorTheme.Opacity.railCardFill
    static let emptyColumnFillOpacity = CoordinatorTheme.Opacity.emptyColumnFill
    static let listRowFillOpacity = CoordinatorTheme.Opacity.listRowFill

    static var hairline: Color {
        CoordinatorTheme.Palette.hairline
    }

    static var panelSeam: Color {
        CoordinatorTheme.Palette.seam
    }

    static var floatingPanelStroke: Color {
        CoordinatorTheme.Palette.strongHairline
    }

    static var floatingPanelShadow: Color {
        CoordinatorTheme.Palette.shadow
    }

    static let floatingPanelCornerRadius: CGFloat = CoordinatorTheme.Radius.panel
    static let floatingPanelInset: CGFloat = 8

    static var selectedFill: Color {
        CoordinatorTheme.Palette.selectedFill()
    }

    static var selectedBorder: Color {
        CoordinatorTheme.Palette.selectedStroke()
    }

    static var hoverBorder: Color {
        CoordinatorTheme.Palette.hoverStroke()
    }
}

private enum CoordinatorSidebarPanelEdge {
    case leading
    case trailing

    var alignment: Alignment {
        switch self {
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

private extension View {
    func coordinatorFlushRegion(edge: CoordinatorSidebarPanelEdge) -> some View {
        background(CoordinatorTheme.Palette.panelBackground.opacity(0.96))
            .overlay(alignment: edge.alignment) {
                Rectangle()
                    .fill(CoordinatorStyle.panelSeam)
                    .frame(width: 0.5)
            }
    }

    func coordinatorAgentSidebarColumn(edge: CoordinatorSidebarPanelEdge) -> some View {
        background(
            AgentModeSurfaceTheme.Palette.sidebarBackground
                .ignoresSafeArea(.container, edges: .top)
        )
        .overlay(alignment: edge.alignment) {
            Rectangle()
                .fill(AgentModeSurfaceTheme.Palette.sidebarSeparator)
                .frame(width: 0.5)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    func coordinatorSidebarPanel(edge: CoordinatorSidebarPanelEdge) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: CoordinatorStyle.floatingPanelCornerRadius,
            style: .continuous
        )

        return padding(CoordinatorStyle.floatingPanelInset)
            .background(
                CoordinatorTheme.Palette.panelBackground
                    .clipShape(shape)
            )
            .overlay {
                shape
                    .strokeBorder(CoordinatorStyle.floatingPanelStroke, lineWidth: 0.75)
            }
            .overlay(alignment: edge.alignment) {
                Rectangle()
                    .fill(CoordinatorStyle.panelSeam.opacity(0.55))
                    .frame(width: 0.5)
                    .padding(.vertical, CoordinatorStyle.floatingPanelCornerRadius)
            }
            .clipShape(shape)
            .shadow(color: CoordinatorStyle.floatingPanelShadow, radius: 12, x: 0, y: 4)
    }

    func coordinatorSidebarHeaderPill(cornerRadius: CGFloat) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(CoordinatorTheme.Palette.elevatedPanelBackground.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(CoordinatorStyle.hairline, lineWidth: 0.5)
            )
    }

    func coordinatorHeaderControlBackground() -> some View {
        background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.22))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(CoordinatorTheme.Palette.strongHairline, lineWidth: CoordinatorTheme.Stroke.hairline)
        )
        .clipShape(Capsule(style: .continuous))
    }

    func coordinatorSearchControlBackground(cornerRadius: CGFloat) -> some View {
        background(Color.clear)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AgentModeSurfaceTheme.Palette.searchStroke, lineWidth: 0.5)
            )
    }

    func coordinatorCardBackground(
        cornerRadius: CGFloat,
        isSelected: Bool = false,
        isHovered: Bool = false,
        fillOpacity: Double = CoordinatorStyle.cardFillOpacity,
        strokeOpacity: Double = 0.15
    ) -> some View {
        let neutralFill = fillOpacity > 0
            ? CoordinatorTheme.Palette.panelBackground.opacity(fillOpacity)
            : Color.clear
        let resolvedFill = isSelected
            ? CoordinatorStyle.selectedFill
            : (isHovered ? CoordinatorTheme.Palette.elevatedPanelBackground.opacity(0.86) : neutralFill)
        let neutralStroke = fillOpacity > 0 && strokeOpacity > 0
            ? Color.secondary.opacity(strokeOpacity)
            : Color.clear
        let resolvedStroke = isSelected
            ? CoordinatorStyle.selectedBorder
            : (isHovered ? CoordinatorStyle.hoverBorder : neutralStroke)

        return background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(resolvedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(resolvedStroke, lineWidth: 1)
        )
    }

    func coordinatorSidebarRowBackground(cornerRadius: CGFloat, isSelected: Bool) -> some View {
        background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(AgentModeSurfaceTheme.Palette.selectedSidebarRowFill)
                }
            }
        )
    }

    func selectedCoordinatorObjectIndicator(isSelected: Bool, cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(isSelected ? 0.72 : 0), lineWidth: 1.6)
        )
        .shadow(color: Color.accentColor.opacity(isSelected ? 0.28 : 0), radius: isSelected ? 8 : 0)
    }
}

private extension CoordinatorModeDecisionQueueItem.Source {
    var displayLabel: String {
        switch self {
        case .planApproval:
            "Plan"
        case .followThroughBoundary:
            "Checkpoint"
        case .interaction:
            "Ask"
        case .review:
            "Review"
        case .blockedUserAction:
            "Blocked"
        }
    }

    var tint: Color {
        switch self {
        case .planApproval:
            Color.accentColor
        case .followThroughBoundary, .interaction:
            .orange
        case .review:
            .purple
        case .blockedUserAction:
            .red
        }
    }
}

private extension CoordinatorModeSortMode {
    var displayName: String {
        switch self {
        case .lastUpdated: "Last updated"
        case .name: "Name"
        case .priority: "Priority"
        }
    }
}

private extension CoordinatorModeBoardScope {
    var displayName: String {
        switch self {
        case .coordinatorFleet: "Missions"
        case .allAgents: "Agent Board"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .coordinatorFleet: "Show selected Mission"
        case .allAgents: "Show all active delegated work across Missions"
        }
    }
}

private extension CoordinatorModeRowOrigin {
    var displayName: String {
        switch self {
        case .coordinatorFleet: "Director Mission"
        case .directAgent: "Direct Agent Mode"
        }
    }
}

private extension CoordinatorModeRow.WorkstreamSummary.Phase {
    var displayName: String {
        switch self {
        case .delegated: "Delegated"
        case .running: "Running"
        case .needsUser: "Needs you"
        case .review: "Review"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .delegated: "arrow.up.forward.circle.fill"
        case .running: "circle.dotted"
        case .needsUser: "person.crop.circle.badge.exclamationmark"
        case .review: "arrow.triangle.merge"
        case .blocked: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .delegated, .running: .blue
        case .needsUser: .orange
        case .review: .purple
        case .blocked: .red
        case .done: .green
        }
    }
}

private extension CoordinatorModeRow.WorkstreamSummary.NextActionKind {
    var systemImage: String {
        switch self {
        case .waitForChild: "hourglass"
        case .respondToChild: "arrowshape.turn.up.left.fill"
        case .inspectOutput: "doc.text.magnifyingglass"
        case .approveNextStep: "arrow.right.circle"
        case .inspectBlocker: "exclamationmark.triangle"
        }
    }
}

private extension CoordinatorModeCoordinatorRail.SelectionSource {
    var displayName: String {
        switch self {
        case .userSelected: "User selected"
        case .orchestrateWorkflow: "Orchestrate workflow"
        case .mcpLineageRoot: "MCP lineage root"
        case .demoRuntime: "Demo runtime"
        }
    }
}

private extension AgentSessionRunState {
    var coordinatorMissionDisplayName: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .waitingForUser: "Needs you"
        case .waitingForQuestion: "Question"
        case .waitingForApproval: "Approval"
        case .completed: "Done"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

private extension CoordinatorModeRailTranscriptEntry.Role {
    var displayName: String {
        switch self {
        case .user: "You"
        case .coordinator: "Director"
        case .event: "Update"
        }
    }

    var systemImage: String {
        switch self {
        case .user: "person.fill"
        case .coordinator: "sparkles"
        case .event: "arrow.triangle.branch"
        }
    }

    var labelColor: Color {
        switch self {
        case .user: .secondary
        case .coordinator: .accentColor
        case .event: .secondary
        }
    }

    var bubbleFill: Color {
        switch self {
        case .user:
            Color.accentColor.opacity(0.16)
        case .coordinator:
            Color(nsColor: .windowBackgroundColor).opacity(0.72)
        case .event:
            Color(nsColor: .controlBackgroundColor).opacity(0.26)
        }
    }

    var bubbleStroke: Color {
        switch self {
        case .user:
            Color.accentColor.opacity(0.22)
        case .coordinator:
            Color.secondary.opacity(0.10)
        case .event:
            Color.secondary.opacity(0.08)
        }
    }
}

private extension CoordinatorModeCoordinatorAction.Verb {
    var displayName: String {
        switch self {
        case .delegate: "Delegated"
        case .collect: "Collected"
        case .cancel: "Cancelled"
        }
    }

    var systemImage: String {
        switch self {
        case .delegate: "arrow.up.forward.circle.fill"
        case .collect: "tray.and.arrow.down.fill"
        case .cancel: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .delegate: .blue
        case .collect: .teal
        case .cancel: .red
        }
    }
}

private extension CoordinatorModeCoordinatorAction.Phase {
    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .resolved: "Started"
        case .failed: "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .orange
        case .resolved: .blue
        case .failed: .red
        }
    }
}

private extension CoordinatorMissionPlanStatus {
    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .approved: "Approved"
        case .running: "Running"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .stopped: "Stopped"
        }
    }

    var tint: Color {
        switch self {
        case .draft: .secondary
        case .approved: .green
        case .running: .blue
        case .blocked: .red
        case .completed: .green
        case .stopped: .orange
        }
    }
}

private extension CoordinatorMissionPlanApprovalState {
    var displayName: String {
        switch self {
        case .notRequired: "No approval"
        case .awaitingApproval: "Awaiting approval"
        case .approved: "Approved"
        case .revisionRequested: "Revision requested"
        }
    }

    var tint: Color {
        switch self {
        case .notRequired: .secondary
        case .awaitingApproval: .orange
        case .approved: .green
        case .revisionRequested: .purple
        }
    }
}

private extension CoordinatorMissionExecutionPolicy {
    var usesStartCapacity: Bool {
        switch self {
        case .freshReadOnlyChild, .freshWorktree, .freshSiblingOnSameWorktree, .planCritique:
            true
        case .coordinatorOnly, .steerPrimary, .askUser:
            false
        }
    }
}

private extension CoordinatorMissionPlanNodeStatus {
    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .completed: "Completed"
        case .blocked: "Blocked"
        case .skipped: "Skipped"
        case .cancelled: "Cancelled"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "circle"
        case .running: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .skipped: "forward.end.circle"
        case .cancelled: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .secondary
        case .running: .blue
        case .completed: .green
        case .blocked: .red
        case .skipped: .orange
        case .cancelled: .red
        }
    }
}

private extension CoordinatorMissionPlanEventKind {
    var displayName: String {
        switch self {
        case .created: "Created"
        case .revised: "Revised"
        case .approved: "Approved"
        case .nodeStarted: "Node started"
        case .nodeCompleted: "Node completed"
        case .nodeBlocked: "Node blocked"
        case .sessionBound: "Session bound"
        case .gateCleared: "Gate cleared"
        }
    }
}

private extension CoordinatorModeStatusGroup {
    var accentColor: Color {
        switch self {
        case .needsYou: .orange
        case .working: .blue
        case .blocked: .red
        case .review: .purple
        case .done: .green
        }
    }

    func columnTint(isEmpty: Bool) -> Color {
        accentColor.opacity(isEmpty ? 0.025 : (self == .done ? 0.055 : 0.075))
    }

    func laneStroke(isEmpty: Bool) -> Color {
        accentColor.opacity(isEmpty ? 0.07 : 0.16)
    }
}

private extension CoordinatorModeMCPAwareness.State {
    var statusTint: Color {
        switch self {
        case .off, .empty: CoordinatorTheme.Semantic.neutral.tint
        case .idle: CoordinatorTheme.Semantic.info.tint
        case .active: CoordinatorTheme.Semantic.success.tint
        }
    }

    var displayName: String {
        switch self {
        case .off: "MCP off"
        case .empty: "MCP idle"
        case .idle: "MCP connected"
        case .active: "MCP active"
        }
    }

    var systemImage: String {
        switch self {
        case .off: "power"
        case .empty: "circle"
        case .idle: "network"
        case .active: "bolt.horizontal"
        }
    }
}

private extension AgentSessionRunState {
    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .waitingForUser: "Needs user"
        case .waitingForQuestion: "Question"
        case .waitingForApproval: "Approval"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

private extension CoordinatorFollowThroughEvent {
    var stepCheckpointID: UUID {
        childSessionID ?? coordinatorSessionID
    }

    var stepCheckpointTitle: String {
        switch kind {
        case .childTerminal:
            "Delegated work reached a boundary"
        case .gateCleared:
            "Director gate cleared"
        }
    }

    var stepCheckpointContext: String {
        var parts = [detail]
        if let childTitle {
            parts.append("Child session: \(childTitle)")
        }
        if let phase {
            parts.append("Observed phase: \(phase.displayName)")
        }
        return parts.joined(separator: "\n")
    }
}

private extension CoordinatorFollowThroughChildPhase {
    var displayName: String {
        switch self {
        case .delegated: "Delegated"
        case .running: "Running"
        case .needsUser: "Needs you"
        case .review: "Review"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }
}

#if DEBUG
    private struct CoordinatorModePreviewHarness: View {
        @StateObject private var viewModel = CoordinatorModeViewModel(inputProvider: { _, _ in .init(workspaceID: nil, windowID: nil) }, dashboardVisibilityHandler: { _ in })
        let snapshot: CoordinatorModeSnapshot
        var width: CGFloat = 1180
        var height: CGFloat = 720

        var body: some View {
            CoordinatorModeView(
                viewModel: viewModel,
                agentModeVM: nil,
                promptManager: nil,
                workspaceSearchService: nil,
                selectionCoordinator: nil,
                rootsStore: nil,
                apiSettingsVM: nil,
                currentTabID: nil,
                onManageWorkspaces: nil,
                onOpenAgentChat: { _ in }
            )
            .onAppear {
                viewModel.testPublish(snapshot)
            }
            .frame(width: width, height: height)
        }
    }

    #Preview("Director Board") {
        CoordinatorModePreviewHarness(snapshot: .previewBoard)
    }

    #Preview("Director List Fallback") {
        CoordinatorModePreviewHarness(snapshot: .previewBoard, width: 700, height: 640)
    }

    #Preview("Director Empty") {
        CoordinatorModePreviewHarness(snapshot: .empty)
    }

    private extension CoordinatorModeSnapshot {
        static var previewBoard: CoordinatorModeSnapshot {
            let now = Date()
            let coordinatorID = UUID()
            let childID = UUID()
            let blockedID = UUID()
            let rows = [
                CoordinatorModeRow(
                    id: childID,
                    sessionID: childID,
                    tabID: nil,
                    title: "Read-only shell",
                    providerName: "claude",
                    modelName: "sonnet",
                    runState: .waitingForApproval,
                    statusGroup: .needsYou,
                    parentSessionID: coordinatorID,
                    parentCoordinator: .init(sessionID: coordinatorID, title: "Coordinate PR stack", isSelected: true),
                    childSessionIDs: [],
                    isMCPOriginated: false,
                    isPersistedOnly: false,
                    isCoordinator: false,
                    startedAt: nil,
                    updatedAt: now.addingTimeInterval(-120),
                    priority: 2,
                    workstream: .init(label: "coordinator/readonly-shell", branch: "coordinator/readonly-shell", colorHex: nil),
                    workstreamSummary: nil,
                    workflow: CoordinatorModeWorkflowDisplaySummary(AgentWorkflow.orchestrate.definition),
                    mergeAttention: nil,
                    pendingInteraction: nil,
                    openAgentChatRoute: nil,
                    statusReport: nil,
                    origin: .coordinatorFleet
                ),
                CoordinatorModeRow(
                    id: blockedID,
                    sessionID: blockedID,
                    tabID: nil,
                    title: "Composer follow-up",
                    providerName: "codex",
                    modelName: nil,
                    runState: .failed,
                    statusGroup: .blocked,
                    parentSessionID: coordinatorID,
                    parentCoordinator: .init(sessionID: coordinatorID, title: "Coordinate PR stack", isSelected: true),
                    childSessionIDs: [],
                    isMCPOriginated: false,
                    isPersistedOnly: true,
                    isCoordinator: false,
                    startedAt: nil,
                    updatedAt: now.addingTimeInterval(-3600),
                    priority: nil,
                    workstream: nil,
                    workstreamSummary: nil,
                    workflow: nil,
                    mergeAttention: nil,
                    pendingInteraction: nil,
                    openAgentChatRoute: nil,
                    statusReport: nil,
                    origin: .coordinatorFleet
                )
            ]
            let groups = CoordinatorModeStatusGroup.allCases.map { group in
                CoordinatorModeStatusSection(group: group, rows: rows.filter { $0.statusGroup == group })
            }
            return CoordinatorModeSnapshot(
                workspaceID: UUID(),
                sortMode: .lastUpdated,
                boardScope: .coordinatorFleet,
                counts: CoordinatorModeCounts(
                    totalRows: rows.count,
                    needsYou: 1,
                    blocked: 1,
                    working: 0,
                    review: 0,
                    done: 0,
                    stalePersistedOnly: 1,
                    liveRows: 1
                ),
                groups: groups,
                coordinatorRail: CoordinatorModeCoordinatorRail(
                    state: .selected,
                    coordinatorSessionID: coordinatorID,
                    coordinatorTabID: nil,
                    selectionSource: .mcpLineageRoot,
                    title: "Coordinate PR stack",
                    availableCoordinators: [],
                    isLiveInCurrentWindow: true,
                    isPersistedOnly: false,
                    isPinned: false,
                    childCounts: .empty,
                    missionTemplate: nil,
                    missionPlan: nil,
                    missionSummary: nil,
                    pendingInteraction: nil,
                    openAgentChatRoute: nil,
                    statusReport: CoordinatorModeSessionStatusReport(
                        status: .running,
                        statusText: "Dispatching delegated work…",
                        assistantPreview: "Starting delegated fleet…",
                        terminalOutput: nil,
                        failureReason: nil
                    ),
                    isComposerEnabled: true,
                    isComposerSendEnabled: false
                ),
                pendingInteractions: [],
                decisionQueue: [],
                mcpAwareness: CoordinatorModeMCPAwareness(
                    state: .active,
                    connectedClientCount: 2,
                    idleClientCount: 1,
                    activeClientCount: 1,
                    inFlightToolCallCount: 1,
                    recentToolCalls: [
                        .init(ordinal: 0, timestamp: now, toolName: "agent_run", clientName: "rpce-cli")
                    ]
                ),
                isEmpty: false
            )
        }
    }
#endif
