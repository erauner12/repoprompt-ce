import Foundation

extension WorkspaceCodemapSnapshotBundle {
    func renderedCodemap(for file: WorkspaceFileRecord, displayPath: String) -> RenderedCodemap? {
        guard let api = snapshot(for: file)?.fileAPI else { return nil }
        let text = api.getFullAPIDescription(displayPath: displayPath)
        guard !text.isEmpty else { return nil }
        return RenderedCodemap(
            text: text,
            tokenCount: TokenCalculationService.estimateTokens(for: text)
        )
    }
}

enum WorkspaceSearchCatalogAccess: Equatable {
    case available(WorkspaceSearchCatalogSnapshot)
    case unavailable(WorkspaceLookupRootScopeAvailability)
}

enum WorkspaceExactPathLookupKind: Hashable {
    case file
    case folder
    case either
}

struct WorkspaceFolderExpansionResult: Equatable {
    let files: [WorkspaceFileRecord]
    let handled: Bool
    let displayPath: String?
    let issue: PathResolutionIssue?
}

final class WorkspaceSearchCatalogGenerationLease: @unchecked Sendable {
    private let retainedObjects: [AnyObject]

    init(retaining retainedObjects: [AnyObject]) {
        self.retainedObjects = retainedObjects
    }
}

struct WorkspaceSearchCatalogSnapshot: Equatable {
    let generation: UInt64
    let rootScope: WorkspaceLookupRootScope
    let roots: [WorkspaceRootRecord]
    let files: [WorkspaceFileRecord]
    let entries: [WorkspaceSearchCatalogEntry]
    let rootPathIndexes: [WorkspaceSearchRootPathIndex]
    let diagnostics: WorkspaceCatalogDiagnostics
    private let generationLease: WorkspaceSearchCatalogGenerationLease?

    init(
        generation: UInt64,
        rootScope: WorkspaceLookupRootScope,
        roots: [WorkspaceRootRecord],
        files: [WorkspaceFileRecord],
        entries: [WorkspaceSearchCatalogEntry],
        rootPathIndexes: [WorkspaceSearchRootPathIndex] = [],
        diagnostics: WorkspaceCatalogDiagnostics,
        generationLease: WorkspaceSearchCatalogGenerationLease? = nil
    ) {
        self.generation = generation
        self.rootScope = rootScope
        self.roots = roots
        self.files = files
        self.entries = entries
        self.rootPathIndexes = rootPathIndexes
        self.diagnostics = diagnostics
        self.generationLease = generationLease
    }

    func recordsOnlyProjection() -> WorkspaceSearchCatalogSnapshot {
        guard !rootPathIndexes.isEmpty else { return self }
        return WorkspaceSearchCatalogSnapshot(
            generation: generation,
            rootScope: rootScope,
            roots: roots,
            files: files,
            entries: entries,
            diagnostics: diagnostics,
            generationLease: generationLease
        )
    }

    static func == (lhs: WorkspaceSearchCatalogSnapshot, rhs: WorkspaceSearchCatalogSnapshot) -> Bool {
        lhs.generation == rhs.generation
            && lhs.rootScope == rhs.rootScope
            && lhs.roots == rhs.roots
            && lhs.files == rhs.files
            && lhs.entries == rhs.entries
            && lhs.diagnostics == rhs.diagnostics
    }
}

struct WorkspaceDirectFolderChildrenSnapshot: Equatable {
    let generation: UInt64
    let root: WorkspaceRootRecord
    let folder: WorkspaceFolderRecord
    let childFolders: [WorkspaceFolderRecord]
    let childFiles: [WorkspaceFileRecord]

    var isEmpty: Bool {
        childFolders.isEmpty && childFiles.isEmpty
    }
}

struct WorkspaceExternalReadableFile: Equatable, Hashable {
    let absolutePath: String
    let displayPath: String
}

enum WorkspaceReadableFileHandle: Equatable {
    case workspace(WorkspaceFileRecord)
    case external(WorkspaceExternalReadableFile)
}

struct WorkspaceFileSystemDeltaEvent: Equatable {
    let rootID: UUID
    let rootPath: String
    let delta: FileSystemDelta
}

struct WorkspaceIngressBarrierSample: Equatable {
    let rootID: UUID
    let rootPath: String
    let pendingRawEventCountBeforeFlush: Int
    let acceptedWatcherWatermark: UInt64
    let publishedServicePublicationSequence: UInt64
    let appliedServicePublicationSequence: UInt64
    let appliedWatcherWatermark: UInt64
}

struct WorkspaceAppliedIndexRootSnapshot: Equatable {
    let root: WorkspaceRootRecord
    let generation: UInt64
    let files: [WorkspaceFileRecord]
    let folders: [WorkspaceFolderRecord]
}

struct WorkspaceSliceRebasePathState: Equatable {
    let rootID: UUID
    let rootLifetimeID: UUID
    let rootKind: WorkspaceRootKind
    let appliedIndexGeneration: UInt64
}

struct WorkspaceSliceRebaseSourceSnapshot: Equatable {
    let rootID: UUID
    let rootLifetimeID: UUID
    let fileID: UUID
    let relativePath: String
    let fullPath: String
    let text: String
    let modificationTime: Double
}

struct WorkspaceAppliedIndexBatchEvent: Equatable {
    let rootID: UUID
    let rootPath: String
    let generation: UInt64
    let rootLifetimeID: UUID?
    let modifiedFileSourceSnapshotsByID: [UUID: WorkspaceSliceRebaseSourceSnapshot]
    let upsertedFiles: [WorkspaceFileRecord]
    let upsertedFolders: [WorkspaceFolderRecord]
    let removedFileIDs: [UUID]
    let removedFolderIDs: [UUID]
    let removedFilePaths: [String]
    let removedFolderPaths: [String]
    let modifiedFileIDs: [UUID]
    let modifiedFolderIDs: [UUID]
    let requiresFullResync: Bool
    let isRootUnload: Bool

    init(
        rootID: UUID,
        rootPath: String,
        generation: UInt64,
        rootLifetimeID: UUID? = nil,
        modifiedFileSourceSnapshotsByID: [UUID: WorkspaceSliceRebaseSourceSnapshot] = [:],
        upsertedFiles: [WorkspaceFileRecord] = [],
        upsertedFolders: [WorkspaceFolderRecord] = [],
        removedFileIDs: [UUID] = [],
        removedFolderIDs: [UUID] = [],
        removedFilePaths: [String] = [],
        removedFolderPaths: [String] = [],
        modifiedFileIDs: [UUID] = [],
        modifiedFolderIDs: [UUID] = [],
        requiresFullResync: Bool = false,
        isRootUnload: Bool = false
    ) {
        self.rootID = rootID
        self.rootPath = rootPath
        self.generation = generation
        self.rootLifetimeID = rootLifetimeID
        self.modifiedFileSourceSnapshotsByID = modifiedFileSourceSnapshotsByID
        self.upsertedFiles = upsertedFiles
        self.upsertedFolders = upsertedFolders
        self.removedFileIDs = removedFileIDs
        self.removedFolderIDs = removedFolderIDs
        self.removedFilePaths = removedFilePaths
        self.removedFolderPaths = removedFolderPaths
        self.modifiedFileIDs = modifiedFileIDs
        self.modifiedFolderIDs = modifiedFolderIDs
        self.requiresFullResync = requiresFullResync
        self.isRootUnload = isRootUnload
    }
}
