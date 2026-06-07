import Foundation

struct MCPRemoteTargetWindowCandidate: Equatable {
    var windowID: Int
    var workspaceID: UUID
    var workspaceName: String
    var rootPaths: [String]
    var contextIDs: Set<UUID>

    init(
        windowID: Int,
        workspaceID: UUID,
        workspaceName: String,
        rootPaths: [String],
        contextIDs: Set<UUID> = []
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.rootPaths = rootPaths
        self.contextIDs = contextIDs
    }
}

struct MCPRemoteDefaultTargetResolution: Equatable {
    var windowID: Int
    var workspaceID: UUID
    var workspaceName: String
    var rootPaths: [String]
    var didOpenWindow: Bool
}

enum MCPRemoteDefaultTargetResolutionError: Error, Equatable, LocalizedError {
    case missingDefaultTarget
    case underspecifiedDefaultTarget
    case requestedWindowUnavailable(Int, guidance: String)
    case staleDefaultTarget(guidance: String)
    case openingNotAllowed(guidance: String)
    case openFailed(guidance: String)

    var errorDescription: String? {
        switch self {
        case .missingDefaultTarget:
            "Network MCP has no default workspace target configured. Choose a default workspace in Settings before connecting remote MCP clients."
        case .underspecifiedDefaultTarget:
            "Network MCP default workspace target is incomplete. Re-save the target from Settings so RepoPrompt can verify its workspace or roots."
        case let .requestedWindowUnavailable(windowID, guidance):
            "Window \(windowID) is not a valid Network MCP default target. \(guidance)"
        case let .staleDefaultTarget(guidance):
            "Network MCP default workspace target is stale. \(guidance)"
        case let .openingNotAllowed(guidance):
            "Network MCP default workspace target is not open. \(guidance)"
        case let .openFailed(guidance):
            "Network MCP could not open the configured default workspace. \(guidance)"
        }
    }
}

struct MCPRemoteDefaultTargetResolver {
    typealias SettingsProvider = () async -> NetworkMCPSettingsSnapshot
    typealias WindowProvider = () async -> [MCPRemoteTargetWindowCandidate]
    typealias WindowOpener = (NetworkMCPDefaultTargetMetadata) async -> MCPRemoteTargetWindowCandidate?

    private let settingsProvider: SettingsProvider
    private let windowProvider: WindowProvider
    private let windowOpener: WindowOpener?

    init(
        settingsProvider: @escaping SettingsProvider = {
            await MainActor.run { GlobalSettingsStore.shared.networkMCPSettingsSnapshot() }
        },
        windowProvider: @escaping WindowProvider = {
            await MainActor.run {
                WindowStatesManager.shared.allWindows.compactMap { window in
                    guard let workspace = window.workspaceManager.activeWorkspace else { return nil }
                    let contextIDs = Set(workspace.composeTabs.map(\.id)).union(workspace.stashedTabs.map(\.tab.id))
                    return MCPRemoteTargetWindowCandidate(
                        windowID: window.windowID,
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        rootPaths: workspace.repoPaths,
                        contextIDs: contextIDs
                    )
                }
            }
        },
        windowOpener: WindowOpener? = nil
    ) {
        self.settingsProvider = settingsProvider
        self.windowProvider = windowProvider
        self.windowOpener = windowOpener
    }

    func resolve(
        requestedWindowID: Int? = nil
    ) async throws -> MCPRemoteDefaultTargetResolution {
        let snapshot = await settingsProvider()
        guard let target = snapshot.defaultTarget else {
            throw MCPRemoteDefaultTargetResolutionError.missingDefaultTarget
        }
        try validateConfiguredTarget(target)

        let candidates = await (windowProvider()).sorted { lhs, rhs in
            if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
            if lhs.workspaceName.localizedCaseInsensitiveCompare(rhs.workspaceName) != .orderedSame {
                return lhs.workspaceName.localizedCaseInsensitiveCompare(rhs.workspaceName) == .orderedAscending
            }
            return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
        }
        let matches = candidates.filter { matchesTarget($0, target: target) }

        if let requestedWindowID {
            guard let match = matches.first(where: { $0.windowID == requestedWindowID }) else {
                throw MCPRemoteDefaultTargetResolutionError.requestedWindowUnavailable(
                    requestedWindowID,
                    guidance: guidance(for: target)
                )
            }
            return resolution(from: match, didOpenWindow: false)
        }

        if let match = matches.first {
            return resolution(from: match, didOpenWindow: false)
        }

        if hasStaleCandidate(candidates, target: target) {
            throw MCPRemoteDefaultTargetResolutionError.staleDefaultTarget(guidance: guidance(for: target))
        }

        guard target.openIfNeeded == true else {
            throw MCPRemoteDefaultTargetResolutionError.openingNotAllowed(guidance: guidance(for: target))
        }
        guard let windowOpener else {
            throw MCPRemoteDefaultTargetResolutionError.openFailed(
                guidance: "No window opener is available for this Network MCP session. Open the configured workspace in RepoPrompt or disable open-if-needed."
            )
        }
        guard let opened = await windowOpener(target), matchesTarget(opened, target: target) else {
            throw MCPRemoteDefaultTargetResolutionError.openFailed(guidance: guidance(for: target))
        }
        return resolution(from: opened, didOpenWindow: true)
    }

    private func validateConfiguredTarget(_ target: NetworkMCPDefaultTargetMetadata) throws {
        guard !WorkspaceRootSetKey(paths: target.rootPaths).isEmpty else {
            throw MCPRemoteDefaultTargetResolutionError.underspecifiedDefaultTarget
        }
        if let contextID = target.contextID,
           UUID(uuidString: contextID) == nil
        {
            throw MCPRemoteDefaultTargetResolutionError.underspecifiedDefaultTarget
        }
    }

    private func hasStaleCandidate(
        _ candidates: [MCPRemoteTargetWindowCandidate],
        target: NetworkMCPDefaultTargetMetadata
    ) -> Bool {
        let targetRoots = WorkspaceRootSetKey(paths: target.rootPaths)
        return candidates.contains { candidate in
            if let workspaceID = target.workspaceID, candidate.workspaceID == workspaceID {
                return true
            }
            if !targetRoots.isEmpty, WorkspaceRootSetKey(paths: candidate.rootPaths) == targetRoots {
                return true
            }
            return false
        }
    }

    private func matchesTarget(
        _ candidate: MCPRemoteTargetWindowCandidate,
        target: NetworkMCPDefaultTargetMetadata
    ) -> Bool {
        if let workspaceID = target.workspaceID, candidate.workspaceID != workspaceID {
            return false
        }

        let targetRoots = WorkspaceRootSetKey(paths: target.rootPaths)
        if !targetRoots.isEmpty {
            guard WorkspaceRootSetKey(paths: candidate.rootPaths) == targetRoots else { return false }
        }

        if let contextIDString = target.contextID,
           let contextID = UUID(uuidString: contextIDString),
           !candidate.contextIDs.isEmpty,
           !candidate.contextIDs.contains(contextID)
        {
            return false
        }

        return true
    }

    private func resolution(
        from candidate: MCPRemoteTargetWindowCandidate,
        didOpenWindow: Bool
    ) -> MCPRemoteDefaultTargetResolution {
        MCPRemoteDefaultTargetResolution(
            windowID: candidate.windowID,
            workspaceID: candidate.workspaceID,
            workspaceName: candidate.workspaceName,
            rootPaths: WorkspaceRootSetKey(paths: candidate.rootPaths).normalizedPaths,
            didOpenWindow: didOpenWindow
        )
    }

    private func guidance(for target: NetworkMCPDefaultTargetMetadata) -> String {
        var parts: [String] = []
        if let name = target.displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Target: \(name).")
        }
        if let workspaceID = target.workspaceID {
            parts.append("Workspace ID: \(workspaceID.uuidString).")
        }
        let roots = WorkspaceRootSetKey(paths: target.rootPaths).normalizedPaths
        if !roots.isEmpty {
            parts.append("Expected roots: \(roots.joined(separator: ", ")).")
        }
        parts.append("Open or re-save the Network MCP default workspace target in Settings.")
        return parts.joined(separator: " ")
    }
}
