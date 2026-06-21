@testable import RepoPrompt
import XCTest

final class WorkspaceFileContextStoreExactCapabilityTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testExactCatalogCapabilityRequiresRootIdentityKindAndCatalogMembership() async throws {
        let workspace = try temporaryRoots.makeRoot(suiteName: "ExactCatalogCapability")
        let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
        let cataloged = gitDataRoot.appendingPathComponent("repos/repo-key/snapshot/MAP.txt")
        let ignored = gitDataRoot.appendingPathComponent("ignored.txt")
        try FileSystemTestSupport.write("ignored.txt\n", to: gitDataRoot.appendingPathComponent(".gitignore"))
        try FileSystemTestSupport.write("map", to: cataloged)
        try FileSystemTestSupport.write("must not materialize", to: ignored)

        let store = WorkspaceFileContextStore()
        let loaded = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let exactRootValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let exactRoot = try XCTUnwrap(exactRootValue)

        XCTAssertEqual(exactRoot.id, loaded.id)
        let wrongKindRoot = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .primaryWorkspace
        )
        let wrongPathRoot = await store.exactRootRef(
            path: workspace.path,
            kind: .workspaceGitData
        )
        XCTAssertNil(wrongKindRoot)
        XCTAssertNil(wrongPathRoot)

        let recordValue = await store.exactCatalogFile(
            absolutePath: cataloged.path,
            expectedRoot: exactRoot,
            expectedKind: .workspaceGitData
        )
        let record = try XCTUnwrap(recordValue)
        let content = await store.readExactCatalogFile(record, expectedRoot: exactRoot)
        XCTAssertEqual(content, "map")

        let ignoredRecord = await store.exactCatalogFile(
            absolutePath: ignored.path,
            expectedRoot: exactRoot,
            expectedKind: .workspaceGitData
        )
        XCTAssertNil(
            ignoredRecord,
            "An on-disk ignored file must not be materialized by the exact capability"
        )

        let forgedRoot = WorkspaceRootRef(
            id: UUID(),
            name: exactRoot.name,
            fullPath: exactRoot.fullPath
        )
        let forgedRecord = await store.exactCatalogFile(
            absolutePath: cataloged.path,
            expectedRoot: forgedRoot,
            expectedKind: .workspaceGitData
        )
        let forgedContent = await store.readExactCatalogFile(record, expectedRoot: forgedRoot)
        XCTAssertNil(forgedRecord)
        XCTAssertNil(forgedContent)
    }

    func testExactCatalogCapabilityRejectsStaleRootLifetime() async throws {
        let workspace = try temporaryRoots.makeRoot(suiteName: "ExactCatalogLifetime")
        let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
        let artifact = gitDataRoot.appendingPathComponent("repos/repo-key/snapshot/MAP.txt")
        try FileSystemTestSupport.write("map", to: artifact)

        let store = WorkspaceFileContextStore()
        let first = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let frozenRootValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let frozenRoot = try XCTUnwrap(frozenRootValue)
        let frozenFileValue = await store.exactCatalogFile(
            absolutePath: artifact.path,
            expectedRoot: frozenRoot,
            expectedKind: .workspaceGitData
        )
        let frozenFile = try XCTUnwrap(frozenFileValue)

        await store.unloadRoot(id: first.id)
        let second = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)

        XCTAssertNotEqual(second.id, frozenRoot.id)
        let staleRecord = await store.exactCatalogFile(
            absolutePath: artifact.path,
            expectedRoot: frozenRoot,
            expectedKind: .workspaceGitData
        )
        let staleContent = await store.readExactCatalogFile(
            frozenFile,
            expectedRoot: frozenRoot
        )
        XCTAssertNil(staleRecord)
        XCTAssertNil(staleContent)
    }
}
