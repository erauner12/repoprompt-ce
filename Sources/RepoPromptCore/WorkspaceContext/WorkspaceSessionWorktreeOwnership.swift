import Foundation

package struct WorkspaceSessionWorktreeOwnershipToken: Hashable {
    let ownerID: UUID
    let generation: UInt64
}

package struct WorkspaceSessionWorktreeOwnedRoot: Hashable {
    package let rootID: UUID
    let lifetimeID: UUID
    package let standardizedPhysicalPath: String
}

package struct WorkspaceSessionWorktreeOwnershipPreparation {
    let token: WorkspaceSessionWorktreeOwnershipToken
    let bindingFingerprint: String
    package let roots: [WorkspaceSessionWorktreeOwnedRoot]
    package let reusesInstalledOwnership: Bool
}

package enum WorkspaceSessionWorktreeOwnershipError: LocalizedError, Equatable {
    case staleUpdate
    case unavailableRoot(String)
    case invalidRootKind(String)

    package var errorDescription: String? {
        switch self {
        case .staleUpdate:
            "The Agent session worktree ownership changed while it was being prepared."
        case let .unavailableRoot(path):
            "The Agent session worktree root is unavailable: \(path)"
        case let .invalidRootKind(path):
            "The requested Agent worktree path is already loaded with incompatible ownership: \(path)"
        }
    }
}
