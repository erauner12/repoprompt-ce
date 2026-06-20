import AppKit
import SwiftUI

private struct CoordinatorSidebarMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = .sidebar
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.blendingMode = .withinWindow
        nsView.state = .active
        nsView.material = .sidebar
    }
}

struct CoordinatorModeView: View {
    enum PresentationMode: String, CaseIterable, Identifiable {
        case board
        case list

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .board: "Board"
            case .list: "List"
            }
        }
    }

    @ObservedObject var viewModel: CoordinatorModeViewModel
    let onOpenAgentChat: (AgentSessionDeepLinkRoute) -> Void

    @State private var presentationMode: PresentationMode = .board
    @State private var selectedRowID: UUID?
    @State private var hoveredRowID: UUID?
    @State private var filterText = ""
    @State private var coordinatorDirectiveDraft = ""
    @State private var childDirectiveDraft = ""
    @State private var childDirectiveNotice: String?
    @State private var isSubmittingCoordinatorDirective = false
    @State private var isSubmittingChildDirective = false
    @State private var isChildComposerExpanded = false
    @State private var isCoordinatorRailVisible = true
    @State private var isInspectorVisible = true
    @State private var isSortMenuOpen = false
    @FocusState private var isCoordinatorComposerFocused: Bool
    @FocusState private var isChildComposerFocused: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var visualMetrics: CoordinatorVisualMetrics {
        CoordinatorVisualMetrics(fontPreset: fontScale.preset)
    }

    var body: some View {
        GeometryReader { proxy in
            let snapshot = viewModel.snapshot
            let sections = filteredSections(from: snapshot)
            let selectedRow = selectedRow(in: sections)
            let metrics = visualMetrics
            let forceList = proxy.size.width < 540 && presentationMode == .board
            let useList = presentationMode == .list || forceList
            let railIsAvailable = proxy.size.width >= metrics.railAvailableWidth
            let inspectorIsAvailable = proxy.size.width >= 1200
            coordinatorShell(
                snapshot: snapshot,
                sections: sections,
                selectedRow: selectedRow,
                useList: useList,
                forceList: forceList,
                railIsAvailable: railIsAvailable,
                inspectorIsAvailable: inspectorIsAvailable,
                metrics: metrics
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.setVisible(true)
        }
        .onDisappear {
            viewModel.setVisible(false)
        }
        .onChange(of: viewModel.snapshot) { _, _ in
            reconcileSelection()
        }
        .onChange(of: selectedRowID) { _, _ in
            resetChildDirectiveComposer()
        }
    }

    private func coordinatorShell(
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection],
        selectedRow: CoordinatorModeRow?,
        useList: Bool,
        forceList: Bool,
        railIsAvailable: Bool,
        inspectorIsAvailable: Bool,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(spacing: 0) {
            if railIsAvailable, isCoordinatorRailVisible {
                coordinatorRail(snapshot: snapshot, metrics: metrics)
                    .frame(width: metrics.railWidth)
                    .frame(maxHeight: .infinity)
            }

            coordinatorContent(
                snapshot: snapshot,
                sections: sections,
                useList: useList,
                forceList: forceList,
                metrics: metrics,
                showRailToggle: railIsAvailable && !isCoordinatorRailVisible,
                showInspectorToggle: inspectorIsAvailable && selectedRow != nil && !isInspectorVisible
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorIsAvailable, isInspectorVisible, let selectedRow {
                inspector(row: selectedRow, metrics: metrics)
                    .frame(
                        minWidth: metrics.inspectorWidth,
                        idealWidth: metrics.inspectorWidth,
                        maxWidth: metrics.inspectorWidth,
                        maxHeight: .infinity
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coordinatorContent(
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection],
        useList: Bool,
        forceList: Bool,
        metrics: CoordinatorVisualMetrics,
        showRailToggle: Bool = false,
        showInspectorToggle: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            boardControls(
                forceList: forceList,
                metrics: metrics,
                showRailToggle: showRailToggle,
                showInspectorToggle: showInspectorToggle
            )
            .padding(.horizontal, metrics.outerPadding)
            .padding(.vertical, metrics.headerPadding)
            .background(.regularMaterial)

            Group {
                if snapshot.isEmpty {
                    emptyState(snapshot: snapshot, metrics: metrics)
                } else if useList {
                    listView(sections: sections, metrics: metrics)
                } else {
                    boardView(sections: sections, metrics: metrics)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            mcpFooter(snapshot.mcpAwareness, metrics: metrics)
        }
    }

    private func boardControls(
        forceList: Bool,
        metrics: CoordinatorVisualMetrics,
        showRailToggle: Bool,
        showInspectorToggle: Bool
    ) -> some View {
        HStack(spacing: metrics.controlSpacing) {
            if showRailToggle {
                CoordinatorRailToggleButton(isRailVisible: false, metrics: metrics) {
                    toggleCoordinatorRail()
                }
            }

            presentationPicker(metrics: metrics)
            sortPicker(metrics: metrics)
            filterSearchBox(metrics: metrics)
                .frame(width: metrics.searchWidth)

            if forceList {
                forceListLabel(metrics: metrics)
            }

            Spacer(minLength: 0)

            if showInspectorToggle {
                CoordinatorRailToggleButton(
                    isRailVisible: false,
                    metrics: metrics,
                    systemImage: "sidebar.right",
                    visibleAccessibilityLabel: "Hide Inspector",
                    hiddenAccessibilityLabel: "Show Inspector"
                ) {
                    isInspectorVisible = true
                }
            }
        }
    }

    private func presentationPicker(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.headerSegmentSpacing) {
            ForEach(PresentationMode.allCases) { mode in
                Button {
                    presentationMode = mode
                } label: {
                    Text(mode.displayName)
                        .font(metrics.bodySemibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(maxWidth: .infinity)
                        .frame(height: metrics.headerSegmentHeight)
                        .padding(.horizontal, metrics.headerSegmentHorizontalPadding)
                }
                .buttonStyle(.plain)
                .foregroundStyle(presentationMode == mode ? Color.accentColor : Color.secondary)
                .background(
                    Capsule(style: .continuous)
                        .fill(presentationMode == mode ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .accessibilityLabel(mode.displayName)
            }
        }
        .padding(metrics.headerControlInset)
        .frame(width: metrics.controlWidth, height: metrics.headerControlHeight)
        .coordinatorHeaderControlBackground()
        .accessibilityLabel("Presentation")
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
        Label("Board falls back to List at narrow widths", systemImage: "rectangle.split.2x1")
            .font(metrics.body)
            .foregroundStyle(.secondary)
    }

    private func filterSearchBox(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.searchElementSpacing) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(NSColor.labelColor).opacity(0.6))
                .font(.system(size: metrics.searchIconSize))

            TextField("Filter sessions", text: $filterText)
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
                .accessibilityLabel("Clear Coordinator filter")
            }
        }
        .padding(.horizontal, metrics.searchHorizontalPadding)
        .padding(.vertical, metrics.searchVerticalPadding)
        .frame(minHeight: metrics.searchControlHeight)
        .coordinatorHeaderControlBackground()
    }

    private func coordinatorRail(
        snapshot: CoordinatorModeSnapshot,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let rail = snapshot.coordinatorRail

        return VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            coordinatorRailTitlebarLane(metrics: metrics)

            coordinatorRailHeader(rail, metrics: metrics)
            coordinatorConversation(rail, metrics: metrics)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(metrics.outerPadding)
        .coordinatorSidebarPanel(edge: .trailing)
    }

    private func coordinatorRailHeader(
        _ rail: CoordinatorModeCoordinatorRail,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(alignment: .top, spacing: metrics.controlSpacing) {
            Image(systemName: "rectangle.3.group.bubble")
                .font(.system(size: metrics.smallIconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: metrics.titlebarButtonSize, height: metrics.titlebarButtonSize)

            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                Text(rail.title ?? "New Coordinator")
                    .font(metrics.cardTitle)
                    .lineLimit(2)

                HStack(spacing: metrics.smallSpacing) {
                    if let source = rail.selectionSource {
                        Text(source.displayName)
                            .font(metrics.micro)
                            .foregroundStyle(.secondary)
                    }
                    statusChip(
                        rail.isLiveInCurrentWindow ? "Live" : (rail.state == .chooseCoordinator ? "Ready" : "Persisted"),
                        color: rail.isLiveInCurrentWindow ? .green : .secondary,
                        metrics: metrics
                    )
                }
            }

            Spacer(minLength: 0)

            Button {
                viewModel.startNewCoordinatorRun()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: metrics.smallIconSize, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .hoverTooltip("New Coordinator chat")
        }
        .padding(metrics.cardPadding)
        .coordinatorCardBackground(
            cornerRadius: metrics.cardCornerRadius,
            fillOpacity: CoordinatorStyle.railCardFillOpacity,
            strokeOpacity: 0
        )
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
            Label("Coordinator", systemImage: "rectangle.3.group.bubble")
                .font(metrics.bodyMedium)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        } control: {
            CoordinatorRailToggleButton(isRailVisible: true, metrics: metrics) {
                toggleCoordinatorRail()
            }
        }
    }

    private func toggleCoordinatorRail() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCoordinatorRailVisible.toggle()
        }
    }

    private func boardView(sections: [CoordinatorModeStatusSection], metrics: CoordinatorVisualMetrics) -> some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: metrics.boardColumnSpacing) {
                    ForEach(sections, id: \.group) { section in
                        boardColumn(
                            section: section,
                            metrics: metrics,
                            minHeight: max(proxy.size.height - (metrics.outerPadding * 2), metrics.boardColumnMinHeight)
                        )
                        .frame(width: metrics.boardColumnWidth)
                    }
                }
                .padding(metrics.outerPadding)
                .frame(
                    minWidth: proxy.size.width,
                    minHeight: proxy.size.height,
                    alignment: .topLeading
                )
                .animation(.easeInOut(duration: 0.22), value: boardAnimationKey(for: sections))
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
            } else {
                ForEach(section.rows) { row in
                    sessionCard(row, metrics: metrics)
                }
            }

            Spacer(minLength: 0)
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

    private func sessionCard(_ row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.sessionCardInnerSpacing) {
            HStack(alignment: .top) {
                Text(row.title)
                    .font(metrics.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: metrics.controlSpacing)
            }

            rowMetadata(row, metrics: metrics)

            if row.isPersistedOnly {
                statusChip("Persisted only", color: .secondary, metrics: metrics)
            }
        }
        .padding(metrics.sessionCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinatorCardBackground(
            cornerRadius: metrics.cardCornerRadius,
            isSelected: row.id == selectedRowID,
            isHovered: row.id == hoveredRowID
        )
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

            Text(row.title)
                .font(metrics.cardTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
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

            Text(listWorkstreamText(for: row))
                .font(metrics.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
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

    private func inspector(row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(spacing: 0) {
            coordinatorSidebarTitlebarLane(metrics: metrics, controlPlacement: .leading) {
                EmptyView()
            } control: {
                CoordinatorRailToggleButton(
                    isRailVisible: true,
                    metrics: metrics,
                    systemImage: "sidebar.right",
                    visibleAccessibilityLabel: "Hide Inspector",
                    hiddenAccessibilityLabel: "Show Inspector"
                ) {
                    isInspectorVisible = false
                }
            }
            .padding(.horizontal, metrics.outerPadding)
            .padding(.top, metrics.outerPadding)

            inspectorHeader(row: row, metrics: metrics)
                .padding(.horizontal, metrics.outerPadding)
                .padding(.top, metrics.sectionSpacing)
                .padding(.bottom, metrics.controlSpacing)

            Divider()
                .opacity(0.28)

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
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
                        keyValue("Provider", row.providerName ?? "Unknown", metrics: metrics)
                        keyValue("Model", row.modelName ?? "Unknown", metrics: metrics)
                        keyValue("Children", "\(row.childSessionIDs.count)", metrics: metrics)
                        keyValue("MCP originated", row.isMCPOriginated ? "Yes" : "No", metrics: metrics)
                        if let workstream = row.workstream {
                            keyValue("Workstream", workstream.label, metrics: metrics)
                            if let branch = workstream.branch {
                                keyValue("Branch", branch, metrics: metrics)
                            }
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
        .coordinatorSidebarPanel(edge: .leading)
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

                Text(inspectorObjectSubtitle(for: row))
                    .font(metrics.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func coordinatorRailStatusReport(_ report: CoordinatorModeSessionStatusReport?, metrics: CoordinatorVisualMetrics) -> some View {
        if let report, report.hasDisplayableContent {
            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                Label("Coordinator status", systemImage: "waveform.path.ecg")
                    .font(metrics.microMedium)
                    .foregroundStyle(.secondary)
                if let statusText = report.statusText {
                    Text(statusText)
                        .font(metrics.micro)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failureReason = report.failureReason {
                    Text("Failure: \(failureReason.displayLabel)")
                        .font(metrics.microMedium)
                        .foregroundStyle(.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let assistantPreview = report.assistantPreview {
                    Text(assistantPreview)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let terminalOutput = report.terminalOutput {
                    Text(terminalOutput)
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(metrics.pendingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.65))
            )
        }
    }

    private func coordinatorConversation(_ rail: CoordinatorModeCoordinatorRail, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.smallSpacing) {
                Label("Conversation", systemImage: "bubble.left.and.text.bubble.right")
                    .font(metrics.cardTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    viewModel.clearCoordinatorRailTranscript()
                }
                .buttonStyle(.link)
                .font(metrics.micro)
                .disabled(viewModel.railTranscriptEntries.isEmpty)
            }
            .padding(.horizontal, metrics.cardPadding)
            .padding(.top, metrics.cardPadding)
            .padding(.bottom, metrics.smallSpacing)

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
                    if viewModel.railTranscriptEntries.isEmpty {
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

            Divider()
                .opacity(0.45)

            coordinatorComposer(rail, metrics: metrics)
                .padding(metrics.cardPadding)
        }
        .coordinatorCardBackground(
            cornerRadius: metrics.cardCornerRadius,
            fillOpacity: CoordinatorStyle.railCardFillOpacity,
            strokeOpacity: 0
        )
    }

    private func coordinatorEmptyConversation(
        _ rail: CoordinatorModeCoordinatorRail,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            Text(rail.state == .chooseCoordinator ? "Start a Coordinator chat." : "Ask the Coordinator what to do next.")
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
        if let action = entry.action {
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
        let statusColor = targetRow?.statusGroup.accentColor ?? action.phase.tint
        let statusText = targetRow?.statusGroup.displayName ?? action.phase.displayName

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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.30))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(action.verb.tint.opacity(0.16), lineWidth: 0.8)
        )
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

    private func coordinatorComposer(_ rail: CoordinatorModeCoordinatorRail, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            if rail.state == .selected, !rail.isComposerSendEnabled, viewModel.currentRailActivityText == nil {
                coordinatorComposerNotice("Coordinator is working. You can send the next message when it reaches a turn boundary.", metrics: metrics)
            } else if let notice = viewModel.composerNotice, !notice.isEmpty {
                coordinatorComposerNotice(notice, metrics: metrics)
            }

            VStack(alignment: .leading, spacing: 0) {
                TextField("Message Coordinator...", text: $coordinatorDirectiveDraft, axis: .vertical)
                    .lineLimit(2 ... 5)
                    .textFieldStyle(.plain)
                    .font(metrics.body)
                    .disabled(!canEditCoordinatorDirective(rail))
                    .focused($isCoordinatorComposerFocused)
                    .onSubmit {
                        submitCoordinatorDirective()
                    }
                    .frame(minHeight: metrics.composerTextMinHeight, alignment: .topLeading)
                    .padding(.horizontal, metrics.composerHorizontalPadding)
                    .padding(.vertical, metrics.composerVerticalPadding)

                Divider()
                    .opacity(0.42)

                coordinatorComposerControlStrip(rail, metrics: metrics)
            }
            .background(
                RoundedRectangle(cornerRadius: metrics.composerCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.composerCornerRadius, style: .continuous)
                    .stroke(canSubmitCoordinatorDirective ? Color.accentColor.opacity(0.48) : CoordinatorStyle.hairline.opacity(1.2), lineWidth: 1)
            )
        }
    }

    private func coordinatorComposerControlStrip(_ rail: CoordinatorModeCoordinatorRail, metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.smallSpacing) {
            HStack(spacing: metrics.miniPillIconSpacing) {
                Image(systemName: "sparkles")
                    .font(.system(size: metrics.microIconSize, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Coordinator")
                    .font(metrics.microMedium)
                    .foregroundStyle(.primary.opacity(0.82))
            }
            .padding(.horizontal, metrics.miniPillHorizontalPadding)
            .padding(.vertical, metrics.miniPillVerticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.32))
            )

            HStack(spacing: metrics.miniPillIconSpacing) {
                if isSubmittingCoordinatorDirective || viewModel.currentRailActivityText != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.58)
                } else {
                    Circle()
                        .fill(rail.isLiveInCurrentWindow ? Color.green.opacity(0.82) : Color.secondary.opacity(0.55))
                        .frame(width: metrics.composerStatusDotSize, height: metrics.composerStatusDotSize)
                }
                Text(coordinatorComposerStatusText(rail))
                    .font(metrics.microMedium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, metrics.miniPillHorizontalPadding)
            .padding(.vertical, metrics.miniPillVerticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.22))
            )

            Spacer(minLength: metrics.smallSpacing)

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
            .hoverTooltip(isSubmittingCoordinatorDirective ? "Sending" : "Send")
        }
        .frame(height: metrics.composerControlStripHeight)
        .padding(.horizontal, metrics.composerControlHorizontalPadding)
    }

    private func coordinatorComposerStatusText(_ rail: CoordinatorModeCoordinatorRail) -> String {
        if isSubmittingCoordinatorDirective {
            return "Sending"
        }
        if let activityText = viewModel.currentRailActivityText, !activityText.isEmpty {
            return activityText
        }
        if rail.state == .chooseCoordinator {
            return "New run"
        }
        if rail.isComposerSendEnabled {
            return rail.isLiveInCurrentWindow ? "Live" : "Ready"
        }
        return "Working"
    }

    private func inspectorChildComposer(row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        let availability = childDirectiveAvailability(for: row)
        let isExpanded = isChildComposerExpanded || isSubmittingChildDirective || !childDirectiveDraft.isEmpty

        return VStack(alignment: .leading, spacing: metrics.smallSpacing) {
            if isExpanded, let notice = availability.notice ?? childDirectiveNotice, !notice.isEmpty {
                coordinatorComposerNotice(notice, metrics: metrics)
            }

            if isExpanded {
                inspectorExpandedChildComposer(row: row, availability: availability, metrics: metrics)
            } else {
                inspectorCollapsedChildComposer(row: row, availability: availability, metrics: metrics)
            }
        }
    }

    private func inspectorCollapsedChildComposer(
        row: CoordinatorModeRow,
        availability: (canEdit: Bool, status: String, notice: String?),
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        Button {
            guard availability.canEdit else { return }
            isChildComposerExpanded = true
            isChildComposerFocused = true
        } label: {
            HStack(spacing: metrics.controlSpacing) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: metrics.smallIconSize, weight: .semibold))
                    .foregroundStyle(availability.canEdit ? Color.accentColor : Color.secondary.opacity(0.7))

                VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                    Text("Reply to this session")
                        .font(metrics.bodyMedium)
                        .foregroundStyle(availability.canEdit ? .primary : .secondary)
                    Text(availability.notice ?? "Send a follow-up to \(row.title)")
                        .font(metrics.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: metrics.controlSpacing)

                HStack(spacing: metrics.miniPillIconSpacing) {
                    Circle()
                        .fill(availability.canEdit ? Color.green.opacity(0.82) : Color.secondary.opacity(0.55))
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
        .disabled(!availability.canEdit)
        .background(
            RoundedRectangle(cornerRadius: metrics.composerCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.composerCornerRadius, style: .continuous)
                .stroke(CoordinatorStyle.hairline.opacity(1.08), lineWidth: 1)
        )
        .hoverTooltip(availability.notice ?? "Reply to \(row.title)")
    }

    private func inspectorExpandedChildComposer(
        row: CoordinatorModeRow,
        availability: (canEdit: Bool, status: String, notice: String?),
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

    private func childDirectiveAvailability(for row: CoordinatorModeRow) -> (canEdit: Bool, status: String, notice: String?) {
        guard row.tabID != nil, !row.isPersistedOnly else {
            return (false, "Unavailable", "This session is not live in the current window.")
        }
        guard row.runState != .running else {
            return (false, "Working", "Waiting for this session to reach a turn boundary.")
        }
        return (true, row.runState.displayName, nil)
    }

    private func coordinatorComposerNotice(_ text: String, metrics: CoordinatorVisualMetrics) -> some View {
        Text(text)
            .font(metrics.micro)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var canSubmitCoordinatorDirective: Bool {
        (
            viewModel.snapshot.coordinatorRail.isComposerSendEnabled
                || viewModel.snapshot.coordinatorRail.state == .chooseCoordinator
        )
            && !isSubmittingCoordinatorDirective
            && !coordinatorDirectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canEditCoordinatorDirective(_ rail: CoordinatorModeCoordinatorRail) -> Bool {
        rail.state == .chooseCoordinator || rail.isComposerEnabled
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

    private func inspectorObjectSubtitle(for row: CoordinatorModeRow) -> String {
        var parts = [row.runState.displayName]
        if let providerName = row.providerName {
            parts.append(providerName)
        }
        parts.append(row.isMCPOriginated ? "MCP originated" : "App originated")
        return parts.joined(separator: " · ")
    }

    private func mcpFooter(_ awareness: CoordinatorModeMCPAwareness, metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.controlSpacing) {
            Label(awareness.state.displayName, systemImage: awareness.state.systemImage)
                .font(metrics.bodyMedium)
            Text("Clients: \(awareness.connectedClientCount) connected, \(awareness.activeClientCount) active, \(awareness.idleClientCount) idle")
                .font(metrics.body)
                .foregroundStyle(.secondary)
            Text("In flight: \(awareness.inFlightToolCallCount)")
                .font(metrics.body)
                .foregroundStyle(.secondary)
            Spacer()
            if let recent = awareness.recentToolCalls.first {
                Text("Recent: \(recent.clientName) → \(recent.toolName)")
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No recent Coordinator MCP calls")
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, metrics.outerPadding)
        .padding(.vertical, metrics.footerVerticalPadding)
        .background(.regularMaterial)
    }

    private func emptyState(snapshot: CoordinatorModeSnapshot, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(spacing: metrics.columnSpacing) {
            Image(systemName: snapshot.workspaceID == nil ? "folder.badge.questionmark" : "rectangle.3.group.bubble")
                .font(.system(size: metrics.emptyStateIconSize))
                .foregroundStyle(.secondary)
            Text(snapshot.workspaceID == nil ? "Open a workspace" : "No delegated sessions yet")
                .font(metrics.headerTitle)
            Text("The board shows only descendants delegated by the current Coordinator runtime.")
                .font(metrics.sectionTitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowMetadata(_ row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.smallSpacing) {
            statusChip(row.runState.displayName, color: row.statusGroup.accentColor, metrics: metrics)
            if let identity = cardIdentityText(for: row) {
                Text(identity)
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func cardIdentityText(for row: CoordinatorModeRow) -> String? {
        var parts: [String] = []
        if let providerName = row.providerName {
            parts.append(providerName)
        }
        if let modelName = row.modelName, modelName != row.providerName {
            parts.append(modelName)
        }
        if let workstream = row.workstream {
            parts.append(workstream.label)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        Text(text)
            .font(metrics.chip)
            .padding(.horizontal, metrics.miniPillHorizontalPadding)
            .padding(.vertical, metrics.miniPillVerticalPadding)
            .background(Capsule().fill(color.opacity(CoordinatorStyle.statusChipFillOpacity)))
            .overlay(
                Capsule().stroke(color.opacity(CoordinatorStyle.statusChipStrokeOpacity), lineWidth: 0.5)
            )
            .foregroundStyle(.secondary)
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
        HStack(alignment: .top) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer(minLength: metrics.controlSpacing)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(metrics.body)
    }

    private func filteredSections(from snapshot: CoordinatorModeSnapshot) -> [CoordinatorModeStatusSection] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshot.groups }
        return snapshot.groups.map { section in
            CoordinatorModeStatusSection(
                group: section.group,
                rows: section.rows.filter { row in
                    row.title.localizedCaseInsensitiveContains(query)
                        || row.providerName?.localizedCaseInsensitiveContains(query) == true
                        || row.modelName?.localizedCaseInsensitiveContains(query) == true
                        || row.workstream?.label.localizedCaseInsensitiveContains(query) == true
                }
            )
        }
    }

    private func selectedRow(in sections: [CoordinatorModeStatusSection]) -> CoordinatorModeRow? {
        guard let selectedRowID else { return nil }
        return sections.flatMap(\.rows).first { $0.id == selectedRowID }
    }

    private func reconcileSelection() {
        let allRows = filteredSections(from: viewModel.snapshot).flatMap(\.rows)
        if let selectedRowID, allRows.contains(where: { $0.id == selectedRowID }) {
            return
        }
        selectedRowID = allRows.first?.id
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
        fontPreset.scaledClamped(340, min: 340, max: 420)
    }

    var inspectorWidth: CGFloat {
        fontPreset.scaledClamped(300, min: 300, max: 360)
    }

    var boardColumnWidth: CGFloat {
        fontPreset.scaledClamped(224, min: 224, max: 276)
    }

    var boardColumnMinHeight: CGFloat {
        fontPreset.scaledClamped(360, min: 360, max: 480)
    }

    var controlWidth: CGFloat {
        fontPreset.scaledClamped(160, min: 160, max: 190)
    }

    var sortControlWidth: CGFloat {
        fontPreset.scaledClamped(190, min: 190, max: 230)
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

    var outerPadding: CGFloat {
        fontPreset.scaledClamped(16, max: 22)
    }

    var headerPadding: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
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
        fontPreset.scaledClamped(54, min: 54, max: 72)
    }

    var composerControlStripHeight: CGFloat {
        fontPreset.scaledClamped(40, min: 40, max: 48)
    }

    var childComposerTextMinHeight: CGFloat {
        fontPreset.scaledClamped(30, min: 30, max: 38)
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
        fontPreset.scaledClamped(12, max: 16)
    }

    var emptyStateIconSize: CGFloat {
        fontPreset.scaledClamped(32, max: 40)
    }
}

private enum CoordinatorStyle {
    static let cardFillOpacity = 0.35
    static let groupedFillOpacity = 0.18
    static let railCardFillOpacity = 0.16
    static let emptyColumnFillOpacity = 0.12
    static let statusChipFillOpacity = 0.04
    static let statusChipStrokeOpacity = 0.07
    static let listRowFillOpacity = 0.10

    static var hairline: Color {
        Color.secondary.opacity(0.15)
    }

    static var panelSeam: Color {
        Color.secondary.opacity(0.10)
    }

    static var selectedFill: Color {
        Color.accentColor.opacity(0.15)
    }

    static var selectedBorder: Color {
        Color.accentColor.opacity(0.25)
    }

    static var hoverBorder: Color {
        Color.secondary.opacity(0.28)
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
    func coordinatorSidebarPanel(edge: CoordinatorSidebarPanelEdge) -> some View {
        background(
            CoordinatorSidebarMaterialView()
                .ignoresSafeArea(.container, edges: .top)
        )
        .overlay(alignment: edge.alignment) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(CoordinatorStyle.panelSeam)
                    .frame(width: 0.5, height: proxy.size.height + proxy.safeAreaInsets.top)
                    .offset(y: -proxy.safeAreaInsets.top)
            }
            .frame(width: 0.5)
        }
    }

    func coordinatorSidebarHeaderPill(cornerRadius: CGFloat) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.10))
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
                .stroke(Color.secondary.opacity(0.20), lineWidth: 0.75)
        )
        .clipShape(Capsule(style: .continuous))
    }

    func coordinatorCardBackground(
        cornerRadius: CGFloat,
        isSelected: Bool = false,
        isHovered: Bool = false,
        fillOpacity: Double = CoordinatorStyle.cardFillOpacity,
        strokeOpacity: Double = 0.15
    ) -> some View {
        let neutralFill = fillOpacity > 0
            ? Color(nsColor: .controlBackgroundColor).opacity(fillOpacity)
            : Color.clear
        let resolvedFill = isSelected
            ? CoordinatorStyle.selectedFill
            : (isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.18) : neutralFill)
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

private extension CoordinatorModeRailTranscriptEntry.Role {
    var displayName: String {
        switch self {
        case .user: "You"
        case .coordinator: "Coordinator"
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

#if DEBUG
    private struct CoordinatorModePreviewHarness: View {
        @StateObject private var viewModel = CoordinatorModeViewModel(inputProvider: { _, _ in .init(workspaceID: nil, windowID: nil) }, dashboardVisibilityHandler: { _ in })
        let snapshot: CoordinatorModeSnapshot
        var width: CGFloat = 1180
        var height: CGFloat = 720

        var body: some View {
            CoordinatorModeView(viewModel: viewModel, onOpenAgentChat: { _ in })
                .onAppear {
                    viewModel.testPublish(snapshot)
                }
                .frame(width: width, height: height)
        }
    }

    #Preview("Coordinator Board") {
        CoordinatorModePreviewHarness(snapshot: .previewBoard)
    }

    #Preview("Coordinator List Fallback") {
        CoordinatorModePreviewHarness(snapshot: .previewBoard, width: 700, height: 640)
    }

    #Preview("Coordinator Empty") {
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
                    childSessionIDs: [],
                    isMCPOriginated: false,
                    isPersistedOnly: false,
                    isCoordinator: false,
                    updatedAt: now.addingTimeInterval(-120),
                    priority: 2,
                    workstream: .init(label: "coordinator/readonly-shell", branch: "coordinator/readonly-shell", colorHex: nil),
                    mergeAttention: nil,
                    pendingInteraction: nil,
                    openAgentChatRoute: nil,
                    statusReport: nil
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
                    childSessionIDs: [],
                    isMCPOriginated: false,
                    isPersistedOnly: true,
                    isCoordinator: false,
                    updatedAt: now.addingTimeInterval(-3600),
                    priority: nil,
                    workstream: nil,
                    mergeAttention: nil,
                    pendingInteraction: nil,
                    openAgentChatRoute: nil,
                    statusReport: nil
                )
            ]
            let groups = CoordinatorModeStatusGroup.allCases.map { group in
                CoordinatorModeStatusSection(group: group, rows: rows.filter { $0.statusGroup == group })
            }
            return CoordinatorModeSnapshot(
                workspaceID: UUID(),
                sortMode: .lastUpdated,
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
                    selectionSource: .mcpLineageRoot,
                    title: "Coordinate PR stack",
                    isLiveInCurrentWindow: true,
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
