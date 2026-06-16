import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceFileDecodeCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WorkspaceFileDecodeCache.shared.removeAllForTesting()
        WorkspaceFileDecodeCache.shared.resetBudgetForTesting()
    }

    override func tearDown() {
        WorkspaceFileDecodeCache.shared.removeAllForTesting()
        WorkspaceFileDecodeCache.shared.resetBudgetForTesting()
        super.tearDown()
    }

    func testCacheEvictsLeastRecentlyUsedEntryWhenCountBudgetExceeded() throws {
        WorkspaceFileDecodeCache.shared.setBudgetForTesting(maxEntryCount: 2, maxEstimatedCost: .max)
        let directory = try makeTemporaryDirectory()
        let firstURL = try writeWorkspace(named: "First", in: directory)
        let secondURL = try writeWorkspace(named: "Second", in: directory)
        let thirdURL = try writeWorkspace(named: "Third", in: directory)

        XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: firstURL).cacheHit)
        XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: secondURL).cacheHit)
        XCTAssertTrue(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: firstURL).cacheHit)

        XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: thirdURL).cacheHit)
        XCTAssertEqual(WorkspaceFileDecodeCache.shared.cachedEntryCountForTesting, 2)
        XCTAssertTrue(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: firstURL).cacheHit)
        XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: secondURL).cacheHit)
    }

    func testCacheEvictsLeastRecentlyUsedEntryWhenCostBudgetExceededButKeepsSingleOversizedEntry() throws {
        WorkspaceFileDecodeCache.shared.setBudgetForTesting(maxEntryCount: 8, maxEstimatedCost: 1)
        let directory = try makeTemporaryDirectory()
        let firstURL = try writeWorkspace(named: "First", in: directory)
        let secondURL = try writeWorkspace(named: "Second", in: directory)

        XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: firstURL).cacheHit)
        XCTAssertEqual(WorkspaceFileDecodeCache.shared.cachedEntryCountForTesting, 1)
        XCTAssertTrue(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: firstURL).cacheHit)

        XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: secondURL).cacheHit)
        XCTAssertEqual(WorkspaceFileDecodeCache.shared.cachedEntryCountForTesting, 1)
        XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: firstURL).cacheHit)
        XCTAssertEqual(WorkspaceFileDecodeCache.shared.cachedEntryCountForTesting, 1)
    }

    func testInvalidationRemovesAllEntriesForStandardizedPath() throws {
        WorkspaceFileDecodeCache.shared.setBudgetForTesting(maxEntryCount: 8, maxEstimatedCost: .max)
        let directory = try makeTemporaryDirectory()
        let fileURL = try writeWorkspace(named: "Standardized", in: directory)
        let nonStandardURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("unused")
            .appendingPathComponent("..")
            .appendingPathComponent(fileURL.lastPathComponent)

        XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: nonStandardURL).cacheHit)
        XCTAssertTrue(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: fileURL).cacheHit)

        WorkspaceFileDecodeCache.shared.invalidate(url: fileURL)

        XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: nonStandardURL).cacheHit)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFileDecodeCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeWorkspace(named name: String, in directory: URL) throws -> URL {
        let workspaceDirectory = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let fileURL = workspaceDirectory.appendingPathComponent("workspace.json")
        let workspace = WorkspaceModel(name: name, repoPaths: [])
        try JSONEncoder().encode(workspace).write(to: fileURL, options: .atomic)
        return fileURL
    }
}
