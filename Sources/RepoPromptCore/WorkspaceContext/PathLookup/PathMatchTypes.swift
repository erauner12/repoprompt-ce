import Foundation

// MARK: - Path Match Result Types

/// Pure-value result coming from the background PathMatcher.
/// No actor references – therefore `Sendable` by default.
package struct PathMatchLocation {
    package let rootPath: String // absolute path of the owning repo root
    package let correctedPath: String // final relative path inside that root

    package init(rootPath: String, correctedPath: String) {
        self.rootPath = rootPath
        self.correctedPath = correctedPath
    }
}

// MARK: - Immutable Snapshot Types

package struct PathMatchCacheIdentity: Hashable {
    package let scopeID: UInt64
    package let snapshotID: UInt64

    package init(scopeID: UInt64, snapshotID: UInt64) {
        self.scopeID = scopeID
        self.snapshotID = snapshotID
    }
}

package enum PathLocateProfile: Hashable {
    case uiAssisted
    case mcpRead
    case mcpSelection
    case mcpSearchScope
    case moveSourceExact
    case createBestEffort
    case createRequireUnambiguous

    package var options: PathLocateOptions {
        switch self {
        case .uiAssisted:
            PathLocateOptions(
                exactMatchOnly: false,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: true,
                allowAbsoluteSuffixFallback: true,
                useSelectedRootBias: true
            )
        case .mcpRead, .mcpSelection, .mcpSearchScope:
            PathLocateOptions(
                exactMatchOnly: false,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: true,
                allowAbsoluteSuffixFallback: true,
                useSelectedRootBias: false
            )
        case .moveSourceExact:
            PathLocateOptions(
                exactMatchOnly: true,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: false,
                allowAbsoluteSuffixFallback: false,
                useSelectedRootBias: false
            )
        case .createBestEffort:
            PathLocateOptions(
                exactMatchOnly: false,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: true,
                allowAbsoluteSuffixFallback: false,
                useSelectedRootBias: true
            )
        case .createRequireUnambiguous:
            PathLocateOptions(
                exactMatchOnly: false,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: true,
                allowAbsoluteSuffixFallback: false,
                useSelectedRootBias: false
            )
        }
    }
}

package struct PathLocateOptions: Equatable {
    package let exactMatchOnly: Bool
    package let allowLeadingRootAliasTrim: Bool
    package let allowHeadTrimAliases: Bool
    package let allowAbsoluteSuffixFallback: Bool
    package let useSelectedRootBias: Bool

    package init(
        exactMatchOnly: Bool,
        allowLeadingRootAliasTrim: Bool,
        allowHeadTrimAliases: Bool,
        allowAbsoluteSuffixFallback: Bool,
        useSelectedRootBias: Bool
    ) {
        self.exactMatchOnly = exactMatchOnly
        self.allowLeadingRootAliasTrim = allowLeadingRootAliasTrim
        self.allowHeadTrimAliases = allowHeadTrimAliases
        self.allowAbsoluteSuffixFallback = allowAbsoluteSuffixFallback
        self.useSelectedRootBias = useSelectedRootBias
    }
}

/// Result of finding a path for file creation
package struct FileCreationResult {
    package let rootFolder: FolderRecord
    package let componentsToCreate: [String]

    package init(rootFolder: FolderRecord, componentsToCreate: [String]) {
        self.rootFolder = rootFolder
        self.componentsToCreate = componentsToCreate
    }
}

extension FileCreationResult: Equatable {
    package static func == (lhs: FileCreationResult, rhs: FileCreationResult) -> Bool {
        lhs.rootFolder.fullPath == rhs.rootFolder.fullPath &&
            lhs.componentsToCreate == rhs.componentsToCreate
    }
}

/// Controls how `resolveCreationPath` handles ties between candidate roots.
package enum CreationResolutionMode {
    /// Best-effort heuristic tie-breaking (current behavior): always returns a single winner.
    case bestEffort
    /// Report ambiguity: if multiple roots tie on structural signals, return `.ambiguous`.
    case requireUnambiguous
}

/// Result of path resolution for file creation with ambiguity detection.
package enum FileCreationResolution: Equatable {
    /// Unambiguous resolution to a single root.
    case unique(FileCreationResult)
    /// Multiple roots are equally valid candidates; caller should request disambiguation.
    case ambiguous(candidateRootPaths: [String])
}

/// Helper enum for handling heterogeneous file/folder collections
package enum AnyItem {
    case folder(FolderRecord)
    case file(FileRecord)

    package var name: String {
        switch self {
        case let .folder(f): f.name
        case let .file(f): f.name
        }
    }

    package var rootPath: String {
        switch self {
        case let .folder(f): f.rootPath
        case let .file(f): f.rootFolderPath
        }
    }

    package var relativePath: String {
        switch self {
        case let .folder(f): f.relativePath
        case let .file(f): f.relativePath
        }
    }
}
