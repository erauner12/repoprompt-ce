import Foundation

enum WorkspaceLogicalRootIdentity {
    struct RootDescriptor {
        let physicalRootID: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
    }

    static func label(for rootEpoch: WorkspaceCodemapRootEpoch) -> String {
        "root@\(rootEpoch.rootID.uuidString.lowercased())+\(rootEpoch.rootLifetimeID.uuidString.lowercased())"
    }

    static func labels(for descriptors: [RootDescriptor]) -> [UUID: String] {
        let ordered = descriptors.sorted { lhs, rhs in
            let lhsLabel = label(for: lhs.rootEpoch)
            let rhsLabel = label(for: rhs.rootEpoch)
            if lhsLabel != rhsLabel {
                return lhsLabel.utf8.lexicographicallyPrecedes(rhsLabel.utf8)
            }
            return lhs.physicalRootID.uuidString < rhs.physicalRootID.uuidString
        }
        return Dictionary(
            uniqueKeysWithValues: ordered.map {
                ($0.physicalRootID, label(for: $0.rootEpoch))
            }
        )
    }
}

extension WorkspaceLookupContext {
    func logicalRootDisplayNamesByRootID(
        store: WorkspaceFileContextStore
    ) async -> [UUID: String] {
        let physicalRoots = await store.rootRefs(scope: rootScope)
        let rootEpochs = await store.codemapRootEpochs(scope: rootScope)
        return WorkspaceLogicalRootIdentity.labels(for: physicalRoots.compactMap { physicalRoot in
            guard let rootEpoch = rootEpochs[physicalRoot.id] else { return nil }
            return WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: physicalRoot.id,
                rootEpoch: rootEpoch
            )
        })
    }

    func logicalDisplayPath(
        for file: WorkspaceFileRecord,
        roots: [WorkspaceRootRef],
        rootDisplayNamesByRootID: [UUID: String],
        display: FilePathDisplay
    ) -> String? {
        guard roots.contains(where: { $0.id == file.rootID }),
              let rootLabel = rootDisplayNamesByRootID[file.rootID]
        else { return nil }
        let relativePath = file.standardizedRelativePath
        if display == .relative, roots.count == 1 {
            return relativePath
        }
        return relativePath.isEmpty ? rootLabel : "\(rootLabel)/\(relativePath)"
    }
}
