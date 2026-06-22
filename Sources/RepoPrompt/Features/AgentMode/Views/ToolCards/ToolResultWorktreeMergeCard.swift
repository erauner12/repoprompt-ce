import Foundation
import SwiftUI

// MARK: - Worktree Merge Tool Result Card

//
// Routed by `ToolCardRouter.resultView(for:)` whenever an Agent transcript
// shows a `manage_worktree` merge-op result. Decodes the structured
// `ManageWorktreeReplyDTO.merge` payload from `item.toolResultJSON` and surfaces
// the source-vs-target review packet: endpoints, preflight summary, conflict or
// stale reason, graph visualization, artifacts, and patch excerpt.

struct WorktreeMergeCardPresentation {
    let title: String
    let subtitle: String
    let detailText: String?
    let status: ToolCardStatus
}

enum WorktreeMergeCardPresentationBuilder {
    static func build(
        dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO?,
        op: String? = nil,
        toolIsError: Bool?
    ) -> WorktreeMergeCardPresentation {
        if toolIsError == true {
            return WorktreeMergeCardPresentation(
                title: "Review Packet",
                subtitle: "failed",
                detailText: nil,
                status: .failure
            )
        }
        guard let dto else {
            return WorktreeMergeCardPresentation(
                title: "Review Packet",
                subtitle: "manage_worktree",
                detailText: nil,
                status: .neutral
            )
        }
        return WorktreeMergeCardPresentation(
            title: title(dto: dto, op: op),
            subtitle: subtitle(dto: dto),
            detailText: detailText(dto: dto),
            status: status(dto: dto)
        )
    }

    private static func title(dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO, op: String?) -> String {
        let suffix: String? = switch (op ?? "").lowercased() {
        case "preview": "Preview"
        case "apply": "Apply"
        case "continue": "Continue"
        case "abort": "Abort"
        case "status": "Status"
        default: nil
        }
        guard let suffix else { return "Review Packet" }
        return "Review Packet • \(suffix)"
    }

    private static func subtitle(dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO) -> String {
        var parts: [String] = []
        let sourceLabel = dto.source?.label ?? dto.source?.branch
        let targetLabel = dto.target?.label ?? dto.target?.branch
        if let sourceLabel, let targetLabel {
            parts.append("\(sourceLabel) → \(targetLabel)")
        } else if let targetLabel {
            parts.append("→ \(targetLabel)")
        }
        parts.append(dto.status)
        if let summary = dto.summary {
            parts.append("\(summary.commits)c · \(summary.files)f · +\(summary.insertions) -\(summary.deletions)")
        }
        return parts.joined(separator: " • ")
    }

    private static func detailText(dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO) -> String? {
        if let error = dto.error, !error.isEmpty { return error }
        if let stale = dto.staleReason, !stale.isEmpty { return stale }
        if let conflicts = dto.conflictFiles, !conflicts.isEmpty {
            return "\(conflicts.count) conflicted file\(conflicts.count == 1 ? "" : "s")"
        }
        if let prediction = dto.preflight?.conflictPrediction,
           prediction.status == "conflicts",
           !prediction.files.isEmpty
        {
            return "Predicted conflicts in \(prediction.files.count) file\(prediction.files.count == 1 ? "" : "s")"
        }
        if let blockers = dto.preflight?.blockers, !blockers.isEmpty {
            return blockers.first?.message
        }
        if let next = dto.nextActions.first, !next.isEmpty {
            return next
        }
        return nil
    }

    private static func status(dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO) -> ToolCardStatus {
        switch dto.status {
        case "completed", "aborted":
            .success
        case "failed":
            .failure
        case "blocked", "conflicted", "stale", "awaiting_commit":
            .warning
        case "awaiting_approval", "applying":
            .neutral
        case "preview":
            dto.preflight?.blocked == true ? .warning : .success
        default:
            .neutral
        }
    }
}

struct ToolResultWorktreeMergeCard: View {
    let item: AgentChatItem
    @State private var isExpanded: Bool

    init(item: AgentChatItem) {
        self.item = item
        _isExpanded = State(initialValue: Self.shouldStartExpanded(item))
    }

    private var reply: ToolResultDTOs.ManageWorktreeReplyDTO? {
        ToolJSON.decode(ToolResultDTOs.ManageWorktreeReplyDTO.self, from: item.toolResultJSON)
    }

    private var presentation: WorktreeMergeCardPresentation {
        WorktreeMergeCardPresentationBuilder.build(dto: reply?.merge, op: reply?.op, toolIsError: item.toolIsError)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: presentation.title,
            detailText: presentation.detailText,
            subtitle: presentation.subtitle,
            status: presentation.status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item) || reply?.merge != nil,
            isExpanded: $isExpanded
        ) {
            if let merge = reply?.merge {
                WorktreeMergePreviewPacketView(merge: merge)
            } else {
                ToolMarkdownExpandedContent(item: item)
            }
        }
    }

    private static func shouldStartExpanded(_ item: AgentChatItem) -> Bool {
        guard let reply = ToolJSON.decode(ToolResultDTOs.ManageWorktreeReplyDTO.self, from: item.toolResultJSON),
              let merge = reply.merge
        else { return false }
        let op = reply.op.lowercased()
        let status = merge.status.lowercased()
        return ["preview", "status"].contains(op)
            || ["preview", "blocked", "awaiting_approval", "conflicted", "stale"].contains(status)
            || merge.artifacts != nil
    }
}

private struct WorktreeMergePreviewPacketView: View {
    let merge: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO

    @State private var diffExcerpt: String?
    @State private var didLoadDiffExcerpt = false

    private var artifacts: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.ArtifactsDTO? {
        merge.artifacts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if merge.source != nil || merge.target != nil {
                endpointsRow
            }

            if let visualization = merge.visualization?.text,
               !visualization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                visualizationBlock(visualization)
            }

            statusRow

            if let summary = merge.summary {
                summaryRow(summary)
            }

            if let blockers = merge.preflight?.blockers, !blockers.isEmpty {
                blockersBlock(blockers)
            }

            if let artifacts {
                artifactPathsBlock(artifacts)
            }

            diffExcerptBlock
        }
        .padding(.vertical, 4)
        .task(id: artifacts?.allPatchPath) {
            await loadDiffExcerptIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Packet")
                    .font(.headline)
                if let operationID = merge.operationID, !operationID.isEmpty {
                    Text("Operation \(operationID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
    }

    private var endpointsRow: some View {
        HStack(spacing: 8) {
            if let source = merge.source {
                endpointCapsule(endpoint: source, role: "source", tint: .blue)
            }
            if merge.source != nil, merge.target != nil {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let target = merge.target {
                endpointCapsule(endpoint: target, role: "target", tint: .orange)
            }
        }
    }

    private func endpointCapsule(
        endpoint: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.EndpointDTO,
        role: String,
        tint: Color
    ) -> some View {
        var pieces = [endpoint.label]
        if let branch = endpoint.branch, !branch.isEmpty, branch != endpoint.label {
            pieces.append(branch)
        }
        pieces.append(endpoint.shortHead)
        return VStack(alignment: .leading, spacing: 1) {
            Text(role.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
            Text(pieces.joined(separator: " · "))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .hoverTooltip(endpoint.path, .top)
    }

    private func visualizationBlock(_ visualization: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(visualization)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
        }
        .frame(maxHeight: 100)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            statusBadge

            if let prediction = merge.preflight?.conflictPrediction {
                preflightBadge(
                    text: predictionText(prediction),
                    tint: prediction.status == "conflicts" ? .orange : .green
                )
            }

            if let mergeBase = merge.mergeBase, !mergeBase.isEmpty {
                preflightBadge(
                    text: "merge-base \(String(mergeBase.prefix(7)))",
                    tint: .secondary
                )
            }

            Spacer()
        }
    }

    private var statusBadge: some View {
        let tint: Color = switch merge.status {
        case "preview", "completed", "aborted":
            .green
        case "failed":
            .red
        case "blocked", "conflicted", "stale", "awaiting_commit":
            .orange
        case "awaiting_approval", "applying":
            .purple
        default:
            .secondary
        }
        return preflightBadge(text: merge.status.replacingOccurrences(of: "_", with: " "), tint: tint)
    }

    private func predictionText(_ prediction: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.ConflictPredictionDTO) -> String {
        switch prediction.status {
        case "clean":
            "Predicted clean"
        case "conflicts":
            prediction.files.isEmpty ? "Predicted conflicts" : "Predicted conflicts (\(prediction.files.count))"
        default:
            "Prediction unavailable"
        }
    }

    private func preflightBadge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.10)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.75))
    }

    private func summaryRow(_ summary: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.SummaryDTO) -> some View {
        let parts = [
            "\(summary.commits) commit\(summary.commits == 1 ? "" : "s")",
            "\(summary.files) file\(summary.files == 1 ? "" : "s")",
            "+\(summary.insertions) -\(summary.deletions)"
        ]
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func blockersBlock(_ blockers: [ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.BlockerDTO]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Blockers")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
                Text("• \(blocker.message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    private func artifactPathsBlock(_ artifacts: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.ArtifactsDTO) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            artifactLine(label: "MAP", path: artifacts.mapPath)
            if let allPatch = artifacts.allPatchPath {
                artifactLine(label: "patch", path: allPatch)
            }
            artifactLine(label: "preview", path: artifacts.sidecarPath)
        }
    }

    private func artifactLine(label: String, path: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.8))
                .frame(width: 50, alignment: .leading)
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .hoverTooltip(path, .top)
    }

    @ViewBuilder
    private var diffExcerptBlock: some View {
        if let diff = diffExcerpt, !diff.isEmpty {
            UnifiedDiffView(diff: diff, largeBodyMaxHeight: 220)
        } else if artifacts?.allPatchPath != nil {
            Text("Diff excerpt unavailable. See artifact path above for full patch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func loadDiffExcerptIfNeeded() async {
        guard !didLoadDiffExcerpt else { return }
        didLoadDiffExcerpt = true
        guard let path = artifacts?.allPatchPath else { return }
        let excerpt = await Task.detached(priority: .utility) {
            Self.readDiffExcerpt(at: path)
        }.value
        diffExcerpt = excerpt
    }

    private static func readDiffExcerpt(at path: String, byteLimit: Int = 64 * 1024) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit),
              var text = String(data: data, encoding: .utf8)
        else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? NSNumber,
           size.intValue > byteLimit
        {
            text += "\n\n... diff excerpt truncated; open the patch artifact for the full diff."
        }
        return text
    }
}
