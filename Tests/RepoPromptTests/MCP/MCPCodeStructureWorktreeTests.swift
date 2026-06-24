import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

private extension ToolResultDTOs.CodeStructureReplyDTO {
    var fileCount: Int { summary.returnedFiles }

    var content: String {
        files.map(\.content).joined(separator: "\n")
    }

    var pendingPaths: [String]? {
        issuePaths { $0.retryable }
    }

    var unmappedPaths: [String]? {
        issuePaths { issue in
            guard !issue.retryable else { return false }
            switch issue.code {
            case "path_not_found", "outside_root_scope", "unsupported_file",
                 "artifact_unavailable", "git_root_unavailable":
                return true
            default:
                return false
            }
        }
    }

    private func issuePaths(
        matching predicate: (ToolResultDTOs.CodeStructureReplyDTO.IssueDTO) -> Bool
    ) -> [String]? {
        let paths = issues.compactMap { issue -> String? in
            guard predicate(issue) else { return nil }
            return issue.path
        }
        return paths.isEmpty ? nil : paths
    }
}

@MainActor
final class MCPCodeStructureWorktreeTests: XCTestCase {
    func testSeedModernResultUsesLogicalPathWithoutPhysicalLeakage() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logical = try repositories.makeRepository(
            named: "logical",
            files: ["Sources/App.swift": "struct CanonicalOnly {}\n"]
        )
        let physical = try repositories.makeRepository(
            named: "physical-secret",
            files: [
                "Sources/App.swift": "protocol AppProtocol { func run() }\nstruct WorktreeApp: AppProtocol { func run() {} }\n"
            ]
        )
        defer { repositories.cleanup() }
        let window = try await makeWindow(root: logical)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logical.path
        )
        let physicalRoot = try await store.loadRoot(path: physical.path, kind: .sessionWorktree)
        let projection = makeProjection(
            logicalRoot: logicalRoot,
            physicalRoot: physicalRoot,
            worktreeID: "logical-result"
        )
        let context = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let file = try await fileRecord(
            at: physical.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: context
        )

        XCTAssertEqual(dto.status, "ready")
        XCTAssertEqual(dto.files.count, 1)
        let renderedFile = try XCTUnwrap(dto.files.first)
        XCTAssertTrue(renderedFile.path.hasSuffix("Sources/App.swift"), renderedFile.path)
        XCTAssertEqual(renderedFile.role, "seed")
        XCTAssertEqual(renderedFile.depth, 0)
        XCTAssertTrue(renderedFile.content.contains("WorktreeApp"), renderedFile.content)
        XCTAssertFalse(renderedFile.content.contains("CanonicalOnly"), renderedFile.content)
        XCTAssertFalse(renderedFile.content.contains(physical.standardizedFileURL.path), renderedFile.content)
        XCTAssertEqual(dto.summary.codemapContentTokens, renderedFile.tokens)
        let mapping = try XCTUnwrap(dto.worktreeScope?.rootMappings.first)
        XCTAssertEqual(mapping.effectiveRootPath, "session-bound")
        XCTAssertEqual(mapping.worktreeID, "logical-result")
        XCTAssertFalse(mapping.logicalRootPath.contains(physical.standardizedFileURL.path))
    }

    func testNonGitRootReturnsTypedUnavailableWithoutLegacySnapshotBuild() async throws {
        let root = try makeTemporaryRoot(name: "NonGit")
        let fileURL = root.appendingPathComponent("Sources/App.swift")
        try write("struct PlainFile {}\n", to: fileURL)
        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        _ = try await fileRecord(at: fileURL, store: store, rootScope: .visibleWorkspace)

        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "code-structure-zero-git",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.getCodeStructure })
        let requestIdentity = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(8001),
            connectionID: connectionID.uuidString,
            connectionGeneration: 1,
            appInvocationID: UUID().uuidString,
            requestOrdinal: 1
        )
        MCPToolWorkCountDiagnostics.resetForTesting()

        let value = try await MCPRequestTimelineContext.$current.withValue(requestIdentity) {
            try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool([
                    "scope": .string("paths"),
                    "paths": .array([.string(fileURL.path)]),
                    "limits": .object(["wait_ms": .int(2000)])
                ])
            }
        }

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "unavailable")
        XCTAssertTrue(object["files"]?.arrayValue?.isEmpty == true)
        let issueCodes = object["issues"]?.arrayValue?.compactMap {
            $0.objectValue?["code"]?.stringValue
        }
        XCTAssertTrue(issueCodes?.contains("git_root_unavailable") == true)
        let invocations = MCPToolWorkCountDiagnostics.debugSnapshots().git
        XCTAssertEqual(invocations.count, 1)
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation.operation, MCPWindowToolName.getCodeStructure)
        XCTAssertEqual(invocation.commandCount, 0, invocation.commands.joined(separator: "\n"))
        XCTAssertEqual(invocation.outcome, "success")
        XCTAssertEqual(invocation.requestIdentity, requestIdentity)

        let repeatedRequestIdentity = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(8002),
            connectionID: connectionID.uuidString,
            connectionGeneration: 1,
            appInvocationID: UUID().uuidString,
            requestOrdinal: 2
        )
        let repeatedValue = try await MCPRequestTimelineContext.$current.withValue(repeatedRequestIdentity) {
            try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool([
                    "scope": .string("paths"),
                    "paths": .array([.string(fileURL.path)]),
                    "limits": .object(["wait_ms": .int(2000)])
                ])
            }
        }
        let repeatedObject = try XCTUnwrap(repeatedValue.objectValue)
        XCTAssertEqual(repeatedObject["status"]?.stringValue, "unavailable")
        XCTAssertTrue(repeatedObject["issues"]?.arrayValue?.contains {
            $0.objectValue?["code"]?.stringValue == "git_root_unavailable"
        } == true)
        let repeatedInvocations = MCPToolWorkCountDiagnostics.debugSnapshots().git
        XCTAssertEqual(repeatedInvocations.count, 2)
        XCTAssertEqual(repeatedInvocations.map(\.commandCount), [0, 0])
        XCTAssertEqual(repeatedInvocations.map(\.requestIdentity), [requestIdentity, repeatedRequestIdentity])
    }

    func testStrictTokenBudgetNeverAdmitsOversizedFirstEntry() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Large.swift": (0 ..< 80).map {
                    "struct Type\($0) { func method\($0)() -> String { \"\($0)\" } }"
                }.joined(separator: "\n")
            ]
        )
        defer { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let file = try await fileRecord(
            at: root.appendingPathComponent("Sources/Large.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let primed = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumCodemapTokens: 6_000, waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(primed.status, "ready")
        XCTAssertTrue(primed.content.contains("Type0"), primed.content)

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumCodemapTokens: 1, waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(dto.status, "budget")
        XCTAssertTrue(dto.files.isEmpty)
        XCTAssertEqual(dto.summary.codemapContentTokens, 0)
        XCTAssertTrue(dto.issues.contains { $0.code == "token_limit" })
    }

    func testSeedDemandBudgetRejectsExpandedSeedsBeforeDemand() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": "struct One {}\n",
                "Sources/Two.swift": "struct Two {}\n"
            ]
        )
        defer { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        XCTAssertEqual(files.count, 2)

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(maximumFiles: 1),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(dto.status, "budget")
        XCTAssertTrue(dto.files.isEmpty)
        XCTAssertEqual(dto.summary.resolvedSeeds, 0)
        let issue = try XCTUnwrap(dto.issues.first { $0.phase == "seed_demand" })
        XCTAssertEqual(issue.code, "hard_budget_exceeded")
        XCTAssertEqual(issue.attempted, 2)
        XCTAssertEqual(issue.limit, 1)
    }


    func testSeedOrderingAndOutputAreDeterministic() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Zeta.swift": "struct Zeta { func zeta() {} }\n",
                "Sources/Alpha.swift": "struct Alpha { func alpha() {} }\n"
            ]
        )
        defer { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        XCTAssertEqual(files.count, 2)
        let tickets = try await files.asyncMap { try await readyTicket(store: store, fileID: $0.id) }
        defer {
            Task {
                for ticket in tickets {
                    _ = await store.cancelCodemapArtifactDemand(ticket)
                }
            }
        }

        let first = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: Array(files.reversed()),
            request: request(waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        let second = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.status, "ready")
        XCTAssertEqual(first.files.count, 2)
        XCTAssertTrue(first.files[0].path.hasSuffix("Sources/Alpha.swift"), first.files[0].path)
        XCTAssertTrue(first.files[1].path.hasSuffix("Sources/Zeta.swift"), first.files[1].path)
    }

    func testResidentForwardAndReverseExpansionUseRootLocalBoundedTraversal() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target { func targetMethod() {} }\n"
            ]
        )
        defer { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let sourceTicket = try await readyTicket(store: store, fileID: source.id)
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        defer {
            Task {
                _ = await store.cancelCodemapArtifactDemand(sourceTicket)
                _ = await store.cancelCodemapArtifactDemand(targetTicket)
            }
        }

        let forward = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [source],
            request: request(direction: .referencedDefinitions, maximumDepth: 2, waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(forward.status, "partial")
        XCTAssertEqual(forward.files.map(\.role), ["seed", "related"])
        XCTAssertEqual(forward.files.map(\.depth), [0, 1])
        XCTAssertTrue(forward.files[1].reachedBy.contains("referenced_definitions"))

        let reverse = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [target],
            request: request(direction: .referrers, maximumDepth: 2, waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(reverse.status, "partial")
        XCTAssertEqual(reverse.files.map(\.role), ["seed", "related"])
        XCTAssertEqual(reverse.files.map(\.depth), [0, 1])
        XCTAssertTrue(reverse.files[1].reachedBy.contains("referrers"))
    }

    func testStoreCanScanSessionWorktreeRoot() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let worktreeRootURL = try repositories.makeRepository(
            named: "direct-scan-worktree",
            files: [
                "App.swift": "struct DirectSessionWorktreeType {\n    func directMethod() {}\n}\n"
            ]
        )
        defer { repositories.cleanup() }

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let content = try await store.readContent(rootID: root.id, relativePath: "App.swift", workloadClass: .codemap)
        XCTAssertTrue(content?.contains("DirectSessionWorktreeType") == true)
        let loadedFile = await store.file(rootID: root.id, relativePath: "App.swift")
        let file = try XCTUnwrap(loadedFile)
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(
                for: .exact(fileIDs: [file.id], completeRootSet: false),
                rootScope: .allLoaded
            )
        XCTAssertEqual(presentation.coverage, .complete)
        let rendered = try XCTUnwrap(presentation.orderedEntries.first)
        XCTAssertTrue(rendered.text.contains("DirectSessionWorktreeType"), rendered.text)
    }

    func testMissingWorktreeSnapshotReturnsPendingThenRendersRefreshedLogicalPath() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: [
                "Sources/App.swift": "struct CanonicalOnlyType {\n    func canonicalMethod() {}\n}\n"
            ]
        )
        let worktreeRootURL = try repositories.makeRepository(
            named: "worktree",
            files: [
                "Sources/App.swift": "struct WorktreeOnlyType {\n    func worktreeMethod() {}\n}\n"
            ]
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "worktree")
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let file = try await fileRecord(
            at: worktreeRootURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )

        let pendingDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10, waitMilliseconds: 0),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        if pendingDTO.status == "pending" {
            XCTAssertEqual(pendingDTO.fileCount, 0)
            XCTAssertEqual(pendingDTO.pendingPaths, ["Sources/App.swift"])
            XCTAssertNil(pendingDTO.unmappedPaths)
        } else {
            XCTAssertEqual(pendingDTO.status, "ready")
        }
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let refreshedDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10, waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(refreshedDTO.status, "ready")
        XCTAssertEqual(refreshedDTO.fileCount, 1)
        XCTAssertTrue(refreshedDTO.content.contains("WorktreeOnlyType"), refreshedDTO.content)
        XCTAssertFalse(refreshedDTO.content.contains("CanonicalOnlyType"), refreshedDTO.content)
        XCTAssertTrue(refreshedDTO.content.contains("Sources/App.swift"), refreshedDTO.content)
        XCTAssertFalse(refreshedDTO.content.contains(worktreeRoot.standardizedFullPath), refreshedDTO.content)
        XCTAssertNil(refreshedDTO.pendingPaths)
        let mapping = try XCTUnwrap(refreshedDTO.worktreeScope?.rootMappings.first)
        XCTAssertEqual(mapping.effectiveRootPath, "session-bound")
    }

    func testSwitchingCodeStructureScopeFromWorktreeAToBDoesNotReuseA() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: ["Sources/App.swift": "struct CanonicalSwitchType {}\n"]
        )
        let worktreeAURL = try repositories.makeRepository(
            named: "switch-a",
            files: ["Sources/App.swift": "struct WorktreeAType {\n    func branchAMethod() {}\n}\n"]
        )
        let worktreeBURL = try repositories.makeRepository(
            named: "switch-b",
            files: ["Sources/App.swift": "struct WorktreeBType {\n    func branchBMethod() {}\n}\n"]
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let logicalRef = WorkspaceRootRef(
            id: logicalRoot.id,
            name: logicalRoot.name,
            fullPath: logicalRoot.standardizedFullPath
        )
        let sessionID = UUID()
        let materializedA = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [makeBinding(
                logicalRoot: logicalRef,
                physicalRoot: WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: worktreeAURL.path),
                worktreeID: "A"
            )]
        )
        let projectionA = try XCTUnwrap(materializedA)
        let fileA = try await fileRecord(
            at: worktreeAURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projectionA.lookupRootScope
        )
        let ticketA = try await readyTicket(store: store, fileID: fileA.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticketA) } }
        let dtoA = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA],
            request: request(maximumFiles: 10, waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionA.lookupRootScope, bindingProjection: projectionA)
        )
        XCTAssertEqual(dtoA.status, "ready")
        XCTAssertTrue(dtoA.content.contains("WorktreeAType"), dtoA.content)

        let materializedB = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [makeBinding(
                logicalRoot: logicalRef,
                physicalRoot: WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: worktreeBURL.path),
                worktreeID: "B"
            )]
        )
        let projectionB = try XCTUnwrap(materializedB)
        let fileB = try await fileRecord(
            at: worktreeBURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projectionB.lookupRootScope
        )
        let ticketB = try await readyTicket(store: store, fileID: fileB.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticketB) } }
        let dtoB = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA, fileB],
            request: request(maximumFiles: 10, waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionB.lookupRootScope, bindingProjection: projectionB)
        )

        XCTAssertEqual(dtoB.status, "ready")
        XCTAssertEqual(dtoB.fileCount, 1)
        XCTAssertTrue(dtoB.content.contains("WorktreeBType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("WorktreeAType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("CanonicalSwitchType"), dtoB.content)
        XCTAssertEqual(dtoB.worktreeScope?.rootMappings.first?.worktreeID, "B")
    }

    func testDeletedMaterializedWorktreeFailsClosedInsteadOfReturningCachedStructure() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: [
                "Sources/App.swift": "struct CanonicalDeletedType {\n    func canonicalMethod() {}\n}\n"
            ]
        )
        let worktreeRootURL = try repositories.makeRepository(
            named: "deleted-worktree",
            files: [
                "Sources/App.swift": "struct CachedDeletedWorktreeType {\n    func cachedMethod() {}\n}\n"
            ]
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "deleted")
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let file = try await fileRecord(
            at: worktreeRootURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let primed = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10, waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(primed.status, "ready")
        XCTAssertTrue(primed.content.contains("CachedDeletedWorktreeType"), primed.content)
        try FileManager.default.removeItem(at: worktreeRootURL)

        let unavailable = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10, waitMilliseconds: 12_000),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(unavailable.status, "unavailable")
        XCTAssertTrue(unavailable.files.isEmpty)
        XCTAssertTrue(unavailable.issues.contains { $0.code == "git_root_unavailable" })
        XCTAssertFalse(unavailable.issues.contains { $0.message.contains(worktreeRootURL.standardizedFileURL.path) })

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [worktreeRootURL.standardizedFileURL.path])
        )
    }

    func testTargetedSelfHealingIsBoundedByMaxResults() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: Dictionary(uniqueKeysWithValues: (1 ... 3).map { index in
                (
                    "Sources/File\(index).swift",
                    "struct BoundedType\(index) {\n    func boundedMethod\(index)() {}\n}\n"
                )
            })
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        XCTAssertEqual(files.count, 3)

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(maximumFiles: 1, waitMilliseconds: 0),
            includePathNotFoundIssue: false,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(dto.status, "budget")
        XCTAssertEqual(dto.fileCount, 0)
        XCTAssertNil(dto.pendingPaths)
        XCTAssertNil(dto.unmappedPaths)
        XCTAssertEqual(dto.summary.requestedSeeds, 3)
        XCTAssertEqual(dto.summary.resolvedSeeds, 0)
        let issue = try XCTUnwrap(dto.issues.first { $0.phase == "seed_demand" })
        XCTAssertEqual(issue.code, "hard_budget_exceeded")
        XCTAssertEqual(issue.attempted, 3)
        XCTAssertEqual(issue.limit, 1)
    }

    func testUnavailableWorktreeReturnsTypedIssueBeforeCanonicalRead() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: ["Sources/App.swift": "struct CanonicalUnavailableType {}\n"]
        )
        defer { repositories.cleanup() }
        let missingWorktreeURL = logicalRootURL.deletingLastPathComponent()
            .appendingPathComponent("Missing-\(UUID().uuidString)", isDirectory: true)

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let logicalRef = WorkspaceRootRef(id: logicalRoot.id, name: logicalRoot.name, fullPath: logicalRoot.standardizedFullPath)
        let missingRef = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: missingWorktreeURL.path)
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRef,
                    physicalRoot: missingRef,
                    binding: makeBinding(logicalRoot: logicalRef, physicalRoot: missingRef, worktreeID: "missing")
                )
            ],
            visibleLogicalRoots: [logicalRef]
        )

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        )
        XCTAssertEqual(dto.status, "unavailable")
        XCTAssertTrue(dto.files.isEmpty)
        XCTAssertEqual(dto.issues.map(\.code), ["git_root_unavailable"])
        XCTAssertFalse(dto.issues.contains { $0.message.contains(logicalRootURL.standardizedFileURL.path) })
        XCTAssertFalse(dto.issues.contains { $0.message.contains(missingWorktreeURL.standardizedFileURL.path) })

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [missingWorktreeURL.standardizedFileURL.path])
        )
    }

    private func request(
        direction: WorkspaceCodemapStructureTraversalDirection? = nil,
        maximumDepth: Int = 0,
        maximumFiles: Int = 10,
        maximumCodemapTokens: Int = 6000,
        waitMilliseconds: Int = 2000
    ) -> MCPServerViewModel.CodeStructureRequest {
        .init(
            direction: direction,
            maximumDepth: maximumDepth,
            maximumFiles: maximumFiles,
            maximumEdges: 500,
            maximumCodemapTokens: maximumCodemapTokens,
            waitMilliseconds: waitMilliseconds
        )
    }


    private func readyTicket(
        store: WorkspaceFileContextStore,
        fileID: UUID
    ) async throws -> WorkspaceCodemapArtifactDemandTicket {
        var result = await store.requestCodemapArtifact(forFileID: fileID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline {
            switch result {
            case let .ready(ready):
                return ready.ticket
            case let .pending(ticket):
                try await Task.sleep(for: .milliseconds(25))
                result = await store.codemapArtifactDemandStatus(ticket)
            case let .unavailable(reason):
                XCTFail("Expected ready codemap demand, got \(reason)")
                throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 2)
            }
        }
        XCTFail("Timed out waiting for ready codemap demand")
        throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 3)
    }

    private func makeWindow(root: URL) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Code Structure Worktree \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpCodeStructureWorktreeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )
        return window
    }

    private func makeProjection(
        logicalRoot: WorkspaceRootRecord,
        physicalRoot: WorkspaceRootRecord,
        worktreeID: String
    ) -> WorkspaceRootBindingProjection {
        let logicalRef = WorkspaceRootRef(
            id: logicalRoot.id,
            name: logicalRoot.name,
            fullPath: logicalRoot.standardizedFullPath
        )
        let physicalRef = WorkspaceRootRef(
            id: physicalRoot.id,
            name: logicalRoot.name,
            fullPath: physicalRoot.standardizedFullPath
        )
        return WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRef,
                    physicalRoot: physicalRef,
                    binding: makeBinding(logicalRoot: logicalRef, physicalRoot: physicalRef, worktreeID: worktreeID)
                )
            ],
            visibleLogicalRoots: [logicalRef]
        )
    }

    private func makeBinding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef,
        worktreeID: String
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(worktreeID)",
            repositoryID: "repo-\(worktreeID)",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: worktreeID,
            worktreeRootPath: physicalRoot.standardizedFullPath,
            worktreeName: URL(fileURLWithPath: physicalRoot.standardizedFullPath).lastPathComponent,
            branch: "feature/\(worktreeID)",
            source: "test"
        )
    }

    private func fileRecord(
        at url: URL,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) async throws -> WorkspaceFileRecord {
        let result = await store.lookupPath(url.path, profile: .mcpRead, rootScope: rootScope)
        return try XCTUnwrap(result?.file)
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPCodeStructureWorktreeTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

#if DEBUG
    private actor AsyncGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }

            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(underestimatedCount)
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
