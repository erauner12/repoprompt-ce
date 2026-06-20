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
    @State private var coordinatorSplitVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredSplitColumn: NavigationSplitViewColumn = .sidebar
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
            let useList = presentationMode == .list || proxy.size.width < 760
            let forceList = useList && presentationMode == .board
            let railIsAvailable = proxy.size.width >= 900
            if railIsAvailable {
                NavigationSplitView(
                    columnVisibility: $coordinatorSplitVisibility,
                    preferredCompactColumn: $preferredSplitColumn
                ) {
                    coordinatorRail(snapshot: snapshot, metrics: metrics)
                        .navigationSplitViewColumnWidth(
                            min: metrics.railWidth,
                            ideal: metrics.railWidth,
                            max: metrics.railWidth
                        )
                } detail: {
                    coordinatorDetailColumn(
                        snapshot: snapshot,
                        sections: sections,
                        selectedRow: selectedRow,
                        useList: useList,
                        forceList: forceList,
                        metrics: metrics
                    )
                }
            } else {
                coordinatorContent(
                    snapshot: snapshot,
                    sections: sections,
                    useList: useList,
                    forceList: forceList,
                    metrics: metrics
                )
            }
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
    }

    private func coordinatorDetailColumn(
        snapshot: CoordinatorModeSnapshot,
        sections: [CoordinatorModeStatusSection],
        selectedRow: CoordinatorModeRow?,
        useList: Bool,
        forceList: Bool,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        HStack(spacing: 0) {
            coordinatorContent(
                snapshot: snapshot,
                sections: sections,
                useList: useList,
                forceList: forceList,
                metrics: metrics,
                showRailToggle: coordinatorSplitVisibility == .detailOnly
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let selectedRow {
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
        showRailToggle: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            boardControls(forceList: forceList, metrics: metrics, showRailToggle: showRailToggle)
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
        showRailToggle: Bool
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
        }
    }

    private func presentationPicker(metrics: CoordinatorVisualMetrics) -> some View {
        Picker("View", selection: $presentationMode) {
            ForEach(PresentationMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: metrics.controlWidth)
        .accessibilityLabel("Presentation")
    }

    private func sortPicker(metrics: CoordinatorVisualMetrics) -> some View {
        Picker("Sort", selection: $viewModel.sortMode) {
            ForEach(CoordinatorModeSortMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .frame(width: metrics.controlWidth)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: metrics.searchCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.searchCornerRadius, style: .continuous)
                .stroke(CoordinatorStyle.hairline, lineWidth: 0.5)
        )
    }

    private func coordinatorRail(
        snapshot: CoordinatorModeSnapshot,
        metrics: CoordinatorVisualMetrics
    ) -> some View {
        let rail = snapshot.coordinatorRail

        return VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            coordinatorRailTitlebarLane(metrics: metrics)

            Group {
                switch rail.state {
                case .selected:
                    VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
                        Text(rail.title ?? "Agent Session")
                            .font(metrics.cardTitle)
                            .lineLimit(2)
                        if let source = rail.selectionSource {
                            Text(source.displayName)
                                .font(metrics.micro)
                                .foregroundStyle(.secondary)
                        }
                        statusChip(
                            rail.isLiveInCurrentWindow ? "Live in this window" : "Persisted only",
                            color: rail.isLiveInCurrentWindow ? .green : .secondary,
                            metrics: metrics
                        )
                        openAgentChatButton(route: rail.openAgentChatRoute, title: "Open in Agent Mode", metrics: metrics)
                    }
                case .chooseCoordinator:
                    VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
                        Text("No Coordinator selected")
                            .font(metrics.cardTitle)
                        Text("The board still shows workspace sessions. Coordinator identity can be selected or auto-detected by structured lineage in later layers.")
                            .font(metrics.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(metrics.cardPadding)
            .coordinatorCardBackground(
                cornerRadius: metrics.cardCornerRadius,
                fillOpacity: CoordinatorStyle.railCardFillOpacity,
                strokeOpacity: 0
            )

            VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
                Label("Read-only PR3 shell", systemImage: "lock")
                    .font(metrics.cardTitle)
                Text("Composer, approvals, retries, drag dispatch, and status mutation intentionally stay out of this surface.")
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(metrics.cardPadding)
            .coordinatorCardBackground(
                cornerRadius: metrics.cardCornerRadius,
                fillOpacity: CoordinatorStyle.railCardFillOpacity,
                strokeOpacity: 0
            )

            Spacer()
        }
        .padding(metrics.outerPadding)
        .coordinatorSidebarPanel(edge: .trailing)
    }

    private func coordinatorRailTitlebarLane(metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.smallSpacing) {
            CoordinatorRailToggleButton(isRailVisible: true, metrics: metrics) {
                toggleCoordinatorRail()
            }

            Label("Coordinator", systemImage: "rectangle.3.group.bubble")
                .font(metrics.bodyMedium)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(height: metrics.railTitlebarLaneHeight)
    }

    private func toggleCoordinatorRail() {
        withAnimation(.easeInOut(duration: 0.2)) {
            coordinatorSplitVisibility = coordinatorSplitVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    private func boardView(sections: [CoordinatorModeStatusSection], metrics: CoordinatorVisualMetrics) -> some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: metrics.boardColumnSpacing) {
                ForEach(sections, id: \.group) { section in
                    boardColumn(section: section, metrics: metrics)
                        .frame(width: metrics.boardColumnWidth)
                }
            }
            .padding(metrics.outerPadding)
        }
    }

    private func boardColumn(section: CoordinatorModeStatusSection, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.columnSpacing) {
            HStack {
                Text(section.group.displayName)
                    .font(metrics.sectionTitle)
                Spacer()
                Text("\(section.rows.count)")
                    .font(metrics.chip)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, metrics.miniPillHorizontalPadding)
                    .padding(.vertical, metrics.miniPillVerticalPadding)
                    .background(Capsule().fill(Color.secondary.opacity(0.08)))
                    .overlay(
                        Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
                    )
            }

            if section.rows.isEmpty {
                Text("No sessions")
                    .font(metrics.micro)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(metrics.emptyColumnPadding)
                    .coordinatorCardBackground(cornerRadius: metrics.cardCornerRadius, fillOpacity: CoordinatorStyle.emptyColumnFillOpacity)
            } else {
                ForEach(section.rows) { row in
                    sessionCard(row, metrics: metrics)
                }
            }
        }
        .padding(metrics.columnPadding)
        .background(
            RoundedRectangle(cornerRadius: metrics.columnCornerRadius, style: .continuous)
                .fill(section.group.columnTint(isEmpty: section.rows.isEmpty))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.columnCornerRadius, style: .continuous)
                .stroke(CoordinatorStyle.hairline, lineWidth: 0.5)
        )
    }

    private func sessionCard(_ row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardInnerSpacing) {
            HStack(alignment: .top) {
                Text(row.title)
                    .font(metrics.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: metrics.controlSpacing)
                if row.isCoordinator {
                    Image(systemName: "crown")
                        .font(.system(size: metrics.smallIconSize))
                        .foregroundStyle(.yellow.opacity(0.8))
                }
            }

            rowMetadata(row, metrics: metrics)

            if let pending = row.pendingInteraction {
                pendingSummary(pending, metrics: metrics)
            }

            if row.isPersistedOnly {
                statusChip("Persisted only", color: .secondary, metrics: metrics)
            }

            openAgentChatButton(route: row.openAgentChatRoute, title: "Open in Agent Mode", metrics: metrics)
        }
        .padding(metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinatorCardBackground(
            cornerRadius: metrics.cardCornerRadius,
            isSelected: row.id == selectedRowID,
            isHovered: row.id == hoveredRowID
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRowID = row.id
        }
        .onHover { hovering in
            hoveredRowID = hovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coordinator session \(row.title)")
    }

    private func listView(sections: [CoordinatorModeStatusSection], metrics: CoordinatorVisualMetrics) -> some View {
        List(selection: $selectedRowID) {
            ForEach(sections, id: \.group) { section in
                Section("\(section.group.displayName) (\(section.rows.count))") {
                    ForEach(section.rows) { row in
                        listRow(row, metrics: metrics)
                            .tag(row.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func listRow(_ row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.controlSpacing) {
            Circle()
                .fill(row.statusGroup.accentColor.opacity(0.65))
                .frame(width: metrics.statusDotSize, height: metrics.statusDotSize)
            VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                HStack(spacing: metrics.smallSpacing) {
                    Text(row.title)
                        .font(metrics.cardTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if row.isCoordinator {
                        Label("Coordinator", systemImage: "crown")
                            .labelStyle(.iconOnly)
                            .font(.system(size: metrics.smallIconSize))
                            .foregroundStyle(.yellow.opacity(0.8))
                    }
                    if row.isPersistedOnly {
                        Text("stale")
                            .font(metrics.microMedium)
                            .foregroundStyle(.secondary)
                    }
                }
                rowMetadata(row, metrics: metrics)
            }
            Spacer()
            openAgentChatButton(route: row.openAgentChatRoute, title: "Open", metrics: metrics)
        }
        .padding(.vertical, metrics.listRowVerticalPadding)
        .padding(.horizontal, metrics.listRowHorizontalPadding)
        .coordinatorCardBackground(
            cornerRadius: metrics.cardCornerRadius,
            isSelected: row.id == selectedRowID,
            isHovered: row.id == hoveredRowID,
            fillOpacity: 0
        )
        .listRowBackground(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRowID = row.id
        }
        .onHover { hovering in
            hoveredRowID = hovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
        }
    }

    private func inspector(row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    selectedRowID = nil
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverTooltip("Hide Inspector")
                .accessibilityLabel("Hide Inspector")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, metrics.outerPadding)
            .frame(height: metrics.railTitlebarLaneHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    HStack(spacing: metrics.controlSpacing) {
                        Label("Inspector", systemImage: "sidebar.right")
                            .font(metrics.bodyMedium)
                    }
                    .coordinatorSidebarHeaderPill(cornerRadius: metrics.headerPillCornerRadius)

                    VStack(alignment: .leading, spacing: metrics.tightSpacing) {
                        Text(row.title)
                            .font(metrics.inspectorTitle)
                            .lineLimit(3)

                        Text(inspectorObjectSubtitle(for: row))
                            .font(metrics.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.bottom, metrics.tightSpacing)

                    inspectorGroup("Status", metrics: metrics) {
                        keyValue("Group", row.statusGroup.displayName, metrics: metrics)
                        keyValue("Run state", row.runState.displayName, metrics: metrics)
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

                    openAgentChatButton(route: row.openAgentChatRoute, title: "Open in Agent Mode", metrics: metrics)
                }
                .padding(metrics.outerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .coordinatorSidebarPanel(edge: .leading)
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
            Text(snapshot.workspaceID == nil ? "Open a workspace" : "No agent sessions yet")
                .font(metrics.headerTitle)
            Text("Coordinator mode renders active-workspace Agent Mode sessions when they exist.")
                .font(metrics.sectionTitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowMetadata(_ row: CoordinatorModeRow, metrics: CoordinatorVisualMetrics) -> some View {
        HStack(spacing: metrics.smallSpacing) {
            statusChip(row.runState.displayName, color: row.statusGroup.accentColor, metrics: metrics)
            if let providerName = row.providerName {
                Text(providerName)
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
            }
            if let workstream = row.workstream {
                Text(workstream.label)
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func pendingSummary(_ pending: CoordinatorModePendingInteractionSummary, metrics: CoordinatorVisualMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightSpacing) {
            Label(pending.title ?? pending.kind.displayLabel, systemImage: "exclamationmark.bubble")
                .font(metrics.bodySemibold)
                .foregroundStyle(.orange.opacity(0.85))
            if let prompt = pending.prompt {
                Text(prompt)
                    .font(metrics.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(metrics.pendingPadding)
        .background(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pendingCornerRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.12), lineWidth: 1)
        )
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
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
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
        .hoverTooltip(isRailVisible ? "Hide Coordinator Rail" : "Show Coordinator Rail")
        .accessibilityLabel(isRailVisible ? "Hide Coordinator Rail" : "Show Coordinator Rail")
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

    var railWidth: CGFloat {
        fontPreset.scaledClamped(260, min: 260, max: 320)
    }

    var inspectorWidth: CGFloat {
        fontPreset.scaledClamped(300, min: 300, max: 360)
    }

    var boardColumnWidth: CGFloat {
        fontPreset.scaledClamped(245, min: 245, max: 300)
    }

    var controlWidth: CGFloat {
        fontPreset.scaledClamped(160, min: 160, max: 190)
    }

    var searchWidth: CGFloat {
        fontPreset.scaledClamped(220, min: 220, max: 280)
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

    var smallSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    var tightSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    var cardInnerSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    var cardPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    var emptyColumnPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 10)
    }

    var columnPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
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
        fontPreset.scaledClamped(4, max: 6)
    }

    var listRowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
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
        }
    }
}

private extension CoordinatorModeStatusGroup {
    var accentColor: Color {
        switch self {
        case .needsYou: .orange
        case .blocked: .red
        case .working: .blue
        case .done: .green
        case .idle: .secondary
        }
    }

    func columnTint(isEmpty: Bool) -> Color {
        accentColor.opacity(isEmpty ? 0.015 : (self == .idle || self == .done ? 0.04 : 0.055))
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
                    id: coordinatorID,
                    sessionID: coordinatorID,
                    tabID: nil,
                    title: "Coordinate PR stack",
                    providerName: "codex",
                    modelName: "gpt-5.1",
                    runState: .running,
                    statusGroup: .working,
                    parentSessionID: nil,
                    childSessionIDs: [childID, blockedID],
                    isMCPOriginated: true,
                    isPersistedOnly: false,
                    isCoordinator: true,
                    updatedAt: now,
                    priority: 3,
                    workstream: nil,
                    mergeAttention: nil,
                    pendingInteraction: nil,
                    openAgentChatRoute: nil
                ),
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
                    openAgentChatRoute: nil
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
                    openAgentChatRoute: nil
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
                    working: 1,
                    done: 0,
                    idle: 0,
                    stalePersistedOnly: 1,
                    liveRows: 2
                ),
                groups: groups,
                coordinatorRail: CoordinatorModeCoordinatorRail(
                    state: .selected,
                    coordinatorSessionID: coordinatorID,
                    selectionSource: .mcpLineageRoot,
                    title: "Coordinate PR stack",
                    isLiveInCurrentWindow: true,
                    openAgentChatRoute: nil
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
