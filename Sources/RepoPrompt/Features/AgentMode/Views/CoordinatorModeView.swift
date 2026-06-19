import SwiftUI

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
    @State private var filterText = ""
    @State private var coordinatorDirectiveDraft = ""
    @State private var isSubmittingCoordinatorDirective = false

    var body: some View {
        GeometryReader { proxy in
            let snapshot = viewModel.snapshot
            let sections = filteredSections(from: snapshot)
            let selectedRow = selectedRow(in: sections)
            let useList = presentationMode == .list || proxy.size.width < 760
            let showRail = proxy.size.width >= 900
            let showInspector = proxy.size.width >= 1120 && selectedRow != nil

            VStack(spacing: 0) {
                header(snapshot: snapshot, forceList: useList && presentationMode == .board)

                Divider()

                HStack(spacing: 0) {
                    if showRail {
                        coordinatorRail(snapshot.coordinatorRail)
                            .frame(width: 260)
                        Divider()
                    }

                    Group {
                        if snapshot.isEmpty {
                            emptyState(snapshot: snapshot)
                        } else if useList {
                            listView(sections: sections)
                        } else {
                            boardView(sections: sections)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showInspector, let selectedRow {
                        Divider()
                        inspector(row: selectedRow)
                            .frame(width: 300)
                    }
                }

                Divider()
                mcpFooter(snapshot.mcpAwareness)
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

    private func header(snapshot: CoordinatorModeSnapshot, forceList: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coordinator")
                        .font(CoordinatorTypography.headerTitle)
                    Text("Read-only mission control for this workspace")
                        .font(CoordinatorTypography.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                countPill("Total", snapshot.counts.totalRows, color: .secondary)
                countPill("Needs you", snapshot.counts.needsYou, color: .orange)
                countPill("Blocked", snapshot.counts.blocked, color: .red)
                countPill("Working", snapshot.counts.working, color: .blue)
                countPill("Stale", snapshot.counts.stalePersistedOnly, color: .secondary)
            }

            HStack(spacing: 10) {
                Picker("Presentation", selection: $presentationMode) {
                    ForEach(PresentationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Picker("Sort", selection: $viewModel.sortMode) {
                    ForEach(CoordinatorModeSortMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(width: 160)

                TextField("Filter sessions", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                if forceList {
                    Label("Board falls back to List at narrow widths", systemImage: "rectangle.split.2x1")
                        .font(CoordinatorTypography.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func coordinatorRail(_ rail: CoordinatorModeCoordinatorRail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Coordinator rail", systemImage: "person.2.wave.2")
                .font(CoordinatorTypography.sectionTitle)

            switch rail.state {
            case .selected:
                VStack(alignment: .leading, spacing: 8) {
                    Text(rail.title ?? "Agent Session")
                        .font(CoordinatorTypography.cardTitle)
                        .lineLimit(2)
                    if let source = rail.selectionSource {
                        Text(source.displayName)
                            .font(CoordinatorTypography.micro)
                            .foregroundStyle(.secondary)
                    }
                    statusChip(
                        rail.isLiveInCurrentWindow ? "Live in this window" : "Persisted only",
                        color: rail.isLiveInCurrentWindow ? .green : .secondary
                    )
                    openAgentChatButton(route: rail.openAgentChatRoute, title: "Open in Agent Mode")
                }
            case .chooseCoordinator:
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Coordinator selected")
                        .font(CoordinatorTypography.cardTitle)
                    Text("The board still shows workspace sessions. Coordinator identity can be selected or auto-detected by structured lineage in later layers.")
                        .font(CoordinatorTypography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            if rail.isComposerEnabled {
                coordinatorComposer(rail)
            } else {
                coordinatorComposerFallback(rail)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(CoordinatorStyle.panelFillOpacity))
    }

    private func boardView(sections: [CoordinatorModeStatusSection]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(sections, id: \.group) { section in
                    boardColumn(section: section)
                        .frame(width: 245)
                }
            }
            .padding(16)
        }
    }

    private func boardColumn(section: CoordinatorModeStatusSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(section.group.displayName)
                    .font(CoordinatorTypography.sectionTitle)
                Spacer()
                Text("\(section.rows.count)")
                    .font(CoordinatorTypography.chip)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            if section.rows.isEmpty {
                Text("No sessions")
                    .font(CoordinatorTypography.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .coordinatorCardBackground(cornerRadius: 10, fillOpacity: CoordinatorStyle.groupedFillOpacity)
            } else {
                ForEach(section.rows) { row in
                    sessionCard(row)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(section.group.columnTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func sessionCard(_ row: CoordinatorModeRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(row.title)
                    .font(CoordinatorTypography.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if row.isCoordinator {
                    Image(systemName: "crown")
                        .foregroundStyle(.yellow)
                }
            }

            rowMetadata(row)

            if let pending = row.pendingInteraction {
                pendingSummary(pending)
            }

            if row.isPersistedOnly {
                statusChip("Persisted only", color: .secondary)
            }

            openAgentChatButton(route: row.openAgentChatRoute, title: "Open in Agent Mode")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinatorCardBackground(cornerRadius: 12, isSelected: row.id == selectedRowID)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRowID = row.id
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coordinator session \(row.title)")
    }

    private func listView(sections: [CoordinatorModeStatusSection]) -> some View {
        List(selection: $selectedRowID) {
            ForEach(sections, id: \.group) { section in
                Section("\(section.group.displayName) (\(section.rows.count))") {
                    ForEach(section.rows) { row in
                        listRow(row)
                            .tag(row.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func listRow(_ row: CoordinatorModeRow) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(row.statusGroup.accentColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(CoordinatorTypography.cardTitle)
                        .lineLimit(1)
                    if row.isCoordinator {
                        Label("Coordinator", systemImage: "crown")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.yellow)
                    }
                    if row.isPersistedOnly {
                        Text("stale")
                            .font(CoordinatorTypography.microMedium)
                            .foregroundStyle(.secondary)
                    }
                }
                rowMetadata(row)
            }
            Spacer()
            openAgentChatButton(route: row.openAgentChatRoute, title: "Open")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(row.id == selectedRowID ? CoordinatorStyle.selectedFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(row.id == selectedRowID ? CoordinatorStyle.selectedBorder : Color.clear, lineWidth: 1)
        )
        .listRowBackground(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRowID = row.id
        }
    }

    private func inspector(row: CoordinatorModeRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label("Inspector", systemImage: "sidebar.right")
                        .font(CoordinatorTypography.sectionTitle)
                    Spacer()
                    Button {
                        selectedRowID = nil
                    } label: {
                        Label("Hide Inspector", systemImage: "sidebar.right")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide Inspector")
                    .accessibilityLabel("Hide Inspector")
                }

                Text(row.title)
                    .font(CoordinatorTypography.inspectorTitle)
                    .lineLimit(3)

                inspectorGroup("Status") {
                    keyValue("Group", row.statusGroup.displayName)
                    keyValue("Run state", row.runState.displayName)
                    keyValue("Updated", row.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    keyValue("Source", row.isPersistedOnly ? "Persisted metadata" : "Current window live state")
                }

                inspectorGroup("Session") {
                    keyValue("Provider", row.providerName ?? "Unknown")
                    keyValue("Model", row.modelName ?? "Unknown")
                    keyValue("Children", "\(row.childSessionIDs.count)")
                    keyValue("MCP originated", row.isMCPOriginated ? "Yes" : "No")
                    if let workstream = row.workstream {
                        keyValue("Workstream", workstream.label)
                        if let branch = workstream.branch {
                            keyValue("Branch", branch)
                        }
                    }
                }

                if let merge = row.mergeAttention {
                    inspectorGroup("Merge attention") {
                        keyValue("Status", merge.status.rawValue)
                        keyValue("Conflicts", "\(merge.conflictFileCount)")
                    }
                }

                if let pending = row.pendingInteraction {
                    inspectorGroup("Pending interaction") {
                        keyValue("Kind", pending.kind.displayLabel)
                        if let title = pending.title {
                            keyValue("Title", title)
                        }
                        if let prompt = pending.prompt {
                            Text(prompt)
                                .font(CoordinatorTypography.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(pending.details, id: \.label) { detail in
                            keyValue(detail.label, detail.value)
                        }
                    }
                }

                openAgentChatButton(route: row.openAgentChatRoute, title: "Open in Agent Mode")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(CoordinatorStyle.panelFillOpacity))
    }

    private func coordinatorComposer(_ rail: CoordinatorModeCoordinatorRail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Directive", systemImage: "paperplane")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear Chat") {
                    viewModel.clearCoordinatorRailTranscript()
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(viewModel.railTranscriptEntries.isEmpty)
            }

            if viewModel.railTranscriptEntries.isEmpty {
                Text("Accepted directives appear here. Coordinator responses and child-session effects refresh through the board.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.railTranscriptEntries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.role.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if !rail.isComposerSendEnabled {
                Text("Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Message the Coordinator", text: $coordinatorDirectiveDraft, axis: .vertical)
                .lineLimit(2 ... 5)
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmittingCoordinatorDirective || !rail.isComposerSendEnabled)
                .onSubmit {
                    submitCoordinatorDirective()
                }

            HStack {
                if let notice = viewModel.composerNotice, !notice.isEmpty {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(isSubmittingCoordinatorDirective ? "Sending…" : "Send") {
                    submitCoordinatorDirective()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSubmitCoordinatorDirective)
            }
        }
    }

    private func coordinatorComposerFallback(_ rail: CoordinatorModeCoordinatorRail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Coordinator composer unavailable", systemImage: "lock")
                .font(.subheadline.weight(.semibold))
            Text("The scoped composer is enabled only for a Coordinator with live state in this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if rail.openAgentChatRoute != nil {
                openAgentChatButton(route: rail.openAgentChatRoute, title: "Open agent chat")
            }
        }
    }

    private var canSubmitCoordinatorDirective: Bool {
        viewModel.snapshot.coordinatorRail.isComposerSendEnabled
            && !isSubmittingCoordinatorDirective
            && !coordinatorDirectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitCoordinatorDirective() {
        let draft = coordinatorDirectiveDraft
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isSubmittingCoordinatorDirective
        else { return }
        isSubmittingCoordinatorDirective = true
        Task { @MainActor in
            let result = await viewModel.submitCoordinatorDirective(draft)
            if result == .accepted {
                coordinatorDirectiveDraft = ""
            }
            isSubmittingCoordinatorDirective = false
        }
    }

    private func mcpFooter(_ awareness: CoordinatorModeMCPAwareness) -> some View {
        HStack(spacing: 10) {
            Label(awareness.state.displayName, systemImage: awareness.state.systemImage)
                .font(CoordinatorTypography.bodyMedium)
            Text("Clients: \(awareness.connectedClientCount) connected, \(awareness.activeClientCount) active, \(awareness.idleClientCount) idle")
                .font(CoordinatorTypography.body)
                .foregroundStyle(.secondary)
            Text("In flight: \(awareness.inFlightToolCallCount)")
                .font(CoordinatorTypography.body)
                .foregroundStyle(.secondary)
            Spacer()
            if let recent = awareness.recentToolCalls.first {
                Text("Recent: \(recent.clientName) → \(recent.toolName)")
                    .font(CoordinatorTypography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No recent Coordinator MCP calls")
                    .font(CoordinatorTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(CoordinatorStyle.panelFillOpacity))
    }

    private func emptyState(snapshot: CoordinatorModeSnapshot) -> some View {
        VStack(spacing: 10) {
            Image(systemName: snapshot.workspaceID == nil ? "folder.badge.questionmark" : "rectangle.3.group.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(snapshot.workspaceID == nil ? "Open a workspace" : "No agent sessions yet")
                .font(CoordinatorTypography.headerTitle)
            Text("Coordinator mode renders active-workspace Agent Mode sessions when they exist.")
                .font(CoordinatorTypography.sectionTitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowMetadata(_ row: CoordinatorModeRow) -> some View {
        HStack(spacing: 6) {
            statusChip(row.runState.displayName, color: row.statusGroup.accentColor)
            if let providerName = row.providerName {
                Text(providerName)
                    .font(CoordinatorTypography.body)
                    .foregroundStyle(.secondary)
            }
            if let workstream = row.workstream {
                Text(workstream.label)
                    .font(CoordinatorTypography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func pendingSummary(_ pending: CoordinatorModePendingInteractionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(pending.title ?? pending.kind.displayLabel, systemImage: "exclamationmark.bubble")
                .font(CoordinatorTypography.bodySemibold)
                .foregroundStyle(.orange)
            if let prompt = pending.prompt {
                Text(prompt)
                    .font(CoordinatorTypography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func openAgentChatButton(route: AgentSessionDeepLinkRoute?, title: String) -> some View {
        Group {
            if let route {
                Button(title) {
                    onOpenAgentChat(route)
                }
                .buttonStyle(.link)
                .font(CoordinatorTypography.bodyMedium)
            } else {
                Text("Agent chat unavailable")
                    .font(CoordinatorTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func countPill(_ label: String, _ value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(CoordinatorTypography.countValue)
            Text(label)
                .font(CoordinatorTypography.micro)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func statusChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(CoordinatorTypography.chip)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }

    private func inspectorGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(CoordinatorTypography.cardTitle)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .coordinatorCardBackground(cornerRadius: 10, fillOpacity: CoordinatorStyle.groupedFillOpacity)
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(CoordinatorTypography.body)
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

private enum CoordinatorTypography {
    static let headerTitle = Font.system(size: 13, weight: .semibold)
    static let sectionTitle = Font.system(size: 12, weight: .semibold)
    static let inspectorTitle = Font.system(size: 14, weight: .semibold)
    static let cardTitle = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 11)
    static let bodyMedium = Font.system(size: 11, weight: .medium)
    static let bodySemibold = Font.system(size: 11, weight: .semibold)
    static let micro = Font.system(size: 10)
    static let microMedium = Font.system(size: 10, weight: .medium)
    static let chip = Font.system(size: 10, weight: .medium)
    static let countValue = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
}

private enum CoordinatorStyle {
    static let cardFillOpacity = 0.35
    static let panelFillOpacity = 0.35
    static let groupedFillOpacity = 0.55

    static var hairline: Color {
        Color.secondary.opacity(0.15)
    }

    static var selectedFill: Color {
        Color.accentColor.opacity(0.15)
    }

    static var selectedBorder: Color {
        Color.accentColor.opacity(0.25)
    }
}

private extension View {
    func coordinatorCardBackground(
        cornerRadius: CGFloat,
        isSelected: Bool = false,
        fillOpacity: Double = CoordinatorStyle.cardFillOpacity
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isSelected ? CoordinatorStyle.selectedFill : Color(nsColor: .controlBackgroundColor).opacity(fillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(isSelected ? CoordinatorStyle.selectedBorder : CoordinatorStyle.hairline, lineWidth: 1)
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

private extension CoordinatorModeRailTranscriptEntry.Role {
    var displayName: String {
        switch self {
        case .user: "You"
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

    var columnTint: Color {
        accentColor.opacity(self == .idle || self == .done ? 0.055 : 0.075)
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
                    openAgentChatRoute: nil,
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
