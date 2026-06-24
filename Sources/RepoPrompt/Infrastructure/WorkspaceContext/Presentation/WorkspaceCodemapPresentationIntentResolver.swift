import Foundation

enum WorkspaceCodemapPresentationIntentResolver {
    static func plan(
        codeMapUsage: CodeMapUsage,
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile
    ) async -> WorkspaceCodemapOperationPresentationPlan {
        guard codeMapUsage != .none,
              codeMapUsage != .auto || selection.codemapAutoEnabled
        else {
            return WorkspaceCodemapOperationPresentationPlan(intent: .none, preflightIssues: [])
        }

        let roots = await store.rootRefs(scope: rootScope)
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        var sourceFilesByID: [UUID: WorkspaceFileRecord] = [:]
        let selectedRequests = selection.selectedPaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let selectedResults = await store.lookupPaths(selectedRequests)
        for path in selection.selectedPaths {
            let result: WorkspacePathLookupResult? = if let batched = selectedResults[path] {
                batched
            } else {
                await store.lookupPath(path, profile: profile, rootScope: rootScope)
            }
            guard let result else { continue }
            if let file = result.file {
                sourceFilesByID[file.id] = file
            } else if let folder = result.folder {
                let prefix = folder.standardizedRelativePath
                for file in await store.files(inRoot: folder.rootID)
                    where prefix.isEmpty
                    || file.standardizedRelativePath == prefix
                    || file.standardizedRelativePath.hasPrefix(prefix + "/")
                {
                    sourceFilesByID[file.id] = file
                }
            }
        }
        for path in selection.slices.keys.sorted(by: utf8Precedes) {
            if let file = await store.lookupPath(path, profile: profile, rootScope: rootScope)?.file {
                sourceFilesByID[file.id] = file
            }
        }

        let requestedFiles: [WorkspaceFileRecord]
        let completeRootSet: Bool
        if codeMapUsage == .complete {
            completeRootSet = true
            var completeFiles: [WorkspaceFileRecord] = []
            for root in roots {
                await completeFiles.append(contentsOf: store.files(inRoot: root.id).filter { file in
                    let fileExtension = (file.name as NSString).pathExtension.lowercased()
                    return !fileExtension.isEmpty
                        && SyntaxManager.supportsCodeMap(fileExtension: fileExtension)
                })
            }
            requestedFiles = completeFiles
        } else {
            completeRootSet = false
            requestedFiles = Array(sourceFilesByID.values)
        }

        let orderedFiles = requestedFiles.sorted { lhs, rhs in
            let lhsRoot = rootsByID[lhs.rootID]?.standardizedFullPath ?? ""
            let rhsRoot = rootsByID[rhs.rootID]?.standardizedFullPath ?? ""
            if lhsRoot != rhsRoot { return lhsRoot.utf8.lexicographicallyPrecedes(rhsRoot.utf8) }
            if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
                return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(
                    rhs.standardizedRelativePath.utf8
                )
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let gitRootIDs = Set(roots.compactMap { root in
            isInsideGitWorktree(URL(fileURLWithPath: root.standardizedFullPath)) ? root.id : nil
        })
        var eligibleFileIDs: [UUID] = []
        var issues: [WorkspaceCodemapOperationIssue] = []
        for file in orderedFiles {
            if gitRootIDs.contains(file.rootID) {
                eligibleFileIDs.append(file.id)
            } else {
                issues.append(.unavailable(fileID: file.id, reason: .gitTerminal(.nonGit)))
            }
        }
        let intent: WorkspaceCodemapOperationPresentationIntent = if codeMapUsage == .auto {
            .automatic(sourceFileIDs: eligibleFileIDs)
        } else {
            .exact(fileIDs: eligibleFileIDs, completeRootSet: completeRootSet)
        }
        return WorkspaceCodemapOperationPresentationPlan(intent: intent, preflightIssues: issues)
    }

    static func merging(
        _ presentation: WorkspaceCodemapOperationPresentation,
        preflightIssues: [WorkspaceCodemapOperationIssue]
    ) -> WorkspaceCodemapOperationPresentation {
        guard !preflightIssues.isEmpty else { return presentation }
        let issues = presentation.issues + preflightIssues
        let coverage: WorkspaceCodemapOperationPresentationCoverage = switch presentation.coverage {
        case .complete:
            presentation.orderedEntries.isEmpty ? .unavailable(issues) : .partial(issues)
        case .partial:
            .partial(issues)
        case .pending:
            .pending(issues)
        case .unavailable:
            .unavailable(issues)
        }
        return WorkspaceCodemapOperationPresentation(
            id: presentation.id,
            orderedEntries: presentation.orderedEntries,
            coverage: coverage,
            issues: issues,
            publicationReceipt: presentation.publicationReceipt
        )
    }

    private static func isInsideGitWorktree(_ rootURL: URL) -> Bool {
        var candidate = rootURL.standardizedFileURL
        while true {
            if GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: candidate) != nil { return true }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { return false }
            candidate = parent
        }
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
