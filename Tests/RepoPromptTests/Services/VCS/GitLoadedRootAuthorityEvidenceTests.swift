import Foundation
@testable import RepoPrompt
import XCTest

final class GitLoadedRootAuthorityEvidenceTests: XCTestCase {
    func testLazyPrefixCollectorCrossesLegacyTenThousandBoundaryAndFindsLateControl() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let late = fixture.root.appendingPathComponent("late/.gitignore")
        try FileManager.default.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "late-control\n".write(to: late, atomically: true, encoding: .utf8)

        let beyondLimit = LazyPrefixCandidateSource(root: fixture.root, logicalNoiseCount: 10001, lateControl: late)
        let baseline = LazyPrefixCandidateSource(root: fixture.root, logicalNoiseCount: 0, lateControl: late)
        let streamed = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            candidateSource: beyondLimit
        )
        let expected = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            candidateSource: baseline
        )

        XCTAssertEqual(streamed.recordCount, 1)
        XCTAssertEqual(streamed.ignoreControlDigest, expected.ignoreControlDigest)
        XCTAssertEqual(streamed.attributeControlDigest, expected.attributeControlDigest)
        XCTAssertEqual(beyondLimit.emittedNoiseCount, 10001)
    }

    func testRepositoryUnderDotGitNamedAncestorStillEnumeratesDescendantControls() async throws {
        let fixture = try AuthorityEvidenceFixture(rootAncestorComponents: [".git", "ancestor"])
        defer { fixture.cleanup() }
        let control = fixture.root.appendingPathComponent("Sources/.gitignore")
        try FileManager.default.createDirectory(
            at: control.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "*.generated\n".write(to: control, atomically: true, encoding: .utf8)

        let evidence = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix("")
        )

        XCTAssertEqual(evidence.recordCount, 1)
        XCTAssertGreaterThan(evidence.pathPayloadByteCount, 0)
    }

    func testPrefixControlReaderSerializesConcurrentConsumers() async throws {
        let store = try GitPrefixControlEvidenceManifestStore()
        let writer = try store.makeWriter(rootPrefixBytes: Data())
        let recordCount = 64
        for index in 0 ..< recordCount {
            try await writer.append(GitPrefixControlEvidenceRecord(
                repositoryRelativePathBytes: Data(String(format: "controls/%03d/.gitignore", index).utf8),
                kind: .gitignore,
                content: GitWorkspaceAuthorityContentIdentity(
                    exists: true,
                    sha256: String(repeating: "a", count: 64),
                    byteCount: index
                )
            ))
        }
        var lease: GitPrefixControlEvidenceManifestLease? = try await writer.finish()
        let paths: [Data]
        let validationState: GitPrefixControlEvidenceReaderValidationState
        do {
            let reader = try XCTUnwrap(lease).makeReader()
            paths = try await withThrowingTaskGroup(of: Data?.self) { group in
                for _ in 0 ... recordCount {
                    group.addTask { try await reader.next()?.repositoryRelativePathBytes }
                }
                var values: [Data] = []
                for try await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            validationState = await reader.validationState
        }

        XCTAssertEqual(paths.count, recordCount)
        XCTAssertEqual(Set(paths).count, recordCount)
        XCTAssertEqual(validationState, .verified)
        lease = nil
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
    }

    func testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded() async throws {
        try await exerciseLargeLogicalStream(recordCount: 100_000)
    }

    func testMillionLogicalCandidatesAndTreeRecordsStayByteBoundedWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RPCE_RUN_MILLION_RECORD_GIT_AUTHORITY_TESTS"] == "1",
            "Set RPCE_RUN_MILLION_RECORD_GIT_AUTHORITY_TESTS=1 for the required slow lane"
        )
        try await exerciseLargeLogicalStream(recordCount: 1_000_000)
    }

    func testCorruptionCancellationAndResourceFailureCleanArtifacts() async throws {
        let header = try inventoryHeader()

        do {
            let store = try WorkspaceRootReusableInventoryManifestStore()
            let writer = try store.makeWriter(header: header)
            try await writer.append(inventoryRecord(path: "A.swift"))
            var lease: WorkspaceRootReusableInventoryManifestLease? = try await writer.finish()
            let handle = try FileHandle(forWritingTo: XCTUnwrap(lease).fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x7F]))
            try handle.close()
            XCTAssertThrowsError(try lease?.makeReader())
            lease = nil
            XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        }

        do {
            let store = try WorkspaceRootReusableInventoryManifestStore()
            let policy = WorkspaceRootReusableInventoryResourcePolicy(
                maximumBufferedRecordBytes: 512,
                maximumRecordsPerBatch: 2,
                maximumRecordByteCount: 1024,
                maximumOpenRuns: 2,
                minimumFreeDiskBytes: 0,
                maximumAggregateArtifactBytes: 64 * 1024 * 1024
            )
            let writer = try store.makeWriter(header: header, resourcePolicy: policy)
            for index in 0 ..< 8 {
                try await writer.append(inventoryRecord(path: String(format: "cancel-%07d.swift", index)))
            }
            XCTAssertTrue(containsSpillRun(in: store.directoryURL), "cancellation must begin after a spill run exists")
            let task = Task {
                for index in 8 ..< 1_000_000 {
                    try await writer.append(self.inventoryRecord(path: String(format: "cancel-%07d.swift", index)))
                    await Task.yield()
                }
            }
            await Task.yield()
            task.cancel()
            do {
                try await task.value
                XCTFail("Expected deterministic cancellation")
            } catch is CancellationError {}
            await writer.cancel()
            try store.cleanup()
            XCTAssertTrue(store.activeArtifactURLs.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
        }

        do {
            let store = try WorkspaceRootReusableInventoryManifestStore()
            let policy = WorkspaceRootReusableInventoryResourcePolicy(
                maximumBufferedRecordBytes: 256,
                maximumRecordsPerBatch: 2,
                maximumRecordByteCount: 1024,
                maximumOpenRuns: 2,
                minimumFreeDiskBytes: 0,
                maximumAggregateArtifactBytes: 512
            )
            let writer = try store.makeWriter(header: header, resourcePolicy: policy)
            do {
                for index in 0 ..< 32 {
                    try await writer.append(inventoryRecord(path: "resource-\(index).swift"))
                }
                _ = try await writer.finish()
                XCTFail("Expected aggregate byte admission failure")
            } catch let error as WorkspaceRootReusableInventoryManifestError {
                XCTAssertEqual(error, .resourceAdmission)
            }
            await writer.cancel()
            try store.cleanup()
            XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        }
    }

    func testArtifactBudgetIncludesPendingReservationsAndFailsClosed() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let sourceAuthority = GitWorkspaceStateAuthority()
        let sourceCoordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: sourceAuthority),
            authority: sourceAuthority
        )
        guard case .admitted = await sourceCoordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: ["A.swift"]
        ) else { return XCTFail("Expected source snapshot admission") }
        let sourceLease: GitWorkspaceAuthorityLease
        switch await sourceAuthority.currentLease(
            for: GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout),
            prefix: try GitRepositoryRelativeRootPrefix("")
        ) {
        case let .success(value): sourceLease = value
        case let .failure(reason): return XCTFail("Missing source authority: \(reason)")
        }
        let currentReusable = await sourceAuthority.currentReusableSnapshot(capturedUsing: sourceLease)
        let reusable = try XCTUnwrap(currentReusable)
        let artifactBytes = reusable.artifactByteCount
        XCTAssertGreaterThan(artifactBytes, 0)

        let authority = GitWorkspaceStateAuthority(
            reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits(
                maximumSnapshotCount: 4,
                maximumSnapshotsPerRepository: 4,
                maximumEstimatedBytes: 8 * 1024 * 1024,
                maximumArtifactBytes: artifactBytes
            )
        )
        let lease = try await authority.install(sourceLease.snapshot)
        let firstObservation = try await authority.retainMetadataObservation(for: fixture.layout)
        let preparedFirst = await authority.prepareReusableSnapshotAdmission(
            reusable,
            capturedUsing: lease,
            observationToken: firstObservation
        )
        let first = try XCTUnwrap(preparedFirst)
        var counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingReusableSnapshotAdmissionCount, 1)
        XCTAssertEqual(counters.pendingReusableSnapshotArtifactBytes, artifactBytes)
        XCTAssertEqual(counters.reusableSnapshotArtifactBytes, 0)
        XCTAssertEqual(counters.reusableSnapshotArtifactBudgetRejectionCount, 0)

        let rejectedObservation = try await authority.retainMetadataObservation(for: fixture.layout)
        let rejected = await authority.prepareReusableSnapshotAdmission(
            reusable,
            capturedUsing: lease,
            observationToken: rejectedObservation
        )
        XCTAssertNil(rejected)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingReusableSnapshotAdmissionCount, 1)
        XCTAssertEqual(counters.pendingReusableSnapshotArtifactBytes, artifactBytes)
        XCTAssertEqual(counters.reusableSnapshotArtifactBudgetRejectionCount, 1)

        let admittedReceipt = await authority.admitPreparedReusableSnapshot(first)
        let receipt = try XCTUnwrap(admittedReceipt)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingReusableSnapshotAdmissionCount, 0)
        XCTAssertEqual(counters.pendingReusableSnapshotArtifactBytes, 0)
        XCTAssertEqual(counters.reusableSnapshotArtifactBytes, artifactBytes)
        XCTAssertLessThanOrEqual(counters.reusableSnapshotArtifactBytes, artifactBytes)
        await authority.revokeReusableSnapshotAdmission(receipt)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.reusableSnapshotArtifactBytes, 0)
    }

    func testStaleCatalogBatchFailsClosedAndLeavesNoReusableAdmission() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let result = await coordinator.observeStreamedAuthoritativeFullLoad(
            rootURL: fixture.root,
            catalogBatchEvidenceProvider: { _ in .stale(.loadedRootWatcherStale) }
        )
        XCTAssertEqual(
            result,
            .failed(.init(stage: .catalogClassification, cause: .loadedRootWatcherStale))
        )
        let snapshot = await authority.snapshotForTesting()
        XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
        XCTAssertEqual(snapshot.reusableSnapshotAliasCount, 0)
        XCTAssertEqual(snapshot.reusableSnapshotEstimatedBytes, 0)
        XCTAssertEqual(snapshot.reusableSnapshotArtifactBytes, 0)
    }

    private func exerciseLargeLogicalStream(recordCount: Int) async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let late = fixture.root.appendingPathComponent("late/.gitattributes")
        try FileManager.default.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "*.swift text\n".write(to: late, atomically: true, encoding: .utf8)
        let source = LazyPrefixCandidateSource(root: fixture.root, logicalNoiseCount: recordCount, lateControl: late)
        let controls = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            candidateSource: source
        )
        XCTAssertEqual(source.emittedNoiseCount, recordCount)
        XCTAssertEqual(controls.recordCount, 1)

        let store = try WorkspaceRootReusableInventoryManifestStore()
        let policy = WorkspaceRootReusableInventoryResourcePolicy(
            maximumBufferedRecordBytes: 1024 * 1024,
            maximumRecordsPerBatch: 4096,
            maximumRecordByteCount: 1024 * 1024,
            maximumOpenRuns: 4,
            minimumFreeDiskBytes: 0,
            maximumAggregateArtifactBytes: 4 * 1024 * 1024 * 1024
        )
        let writer = try store.makeWriter(header: inventoryHeader(), resourcePolicy: policy)
        let oid = String(repeating: "1", count: 40)
        var parser = try GitLoadedRootTreeInventoryStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("")
        ) { record in
            guard let mode = String(data: record.modeBytes, encoding: .utf8),
                  let oidString = String(data: record.objectIDBytes, encoding: .utf8)
            else { throw GitWorktreeInitializationError.malformedOutput("test metadata") }
            try await writer.append(WorkspaceRootReusableInventoryManifestRecord(
                rootRelativePathBytes: record.repositoryRelativePathBytes,
                mode: mode,
                kind: record.kind,
                objectID: GitObjectID(objectFormat: .sha1, lowercaseHex: oidString),
                catalogProjection: .searchableRegularFile
            ))
        }
        for index in 0 ..< recordCount {
            let path = String(format: "f%07d.swift", index)
            let frame = Data("100644 blob \(oid)\t\(path)\0".utf8)
            if index == 0 {
                for byte in frame {
                    try await parser.consume(Data([byte]))
                }
            } else {
                try await parser.consume(frame)
            }
        }
        try await parser.finish()
        var lease: WorkspaceRootReusableInventoryManifestLease? = try await writer.finish()
        var observed = 0
        do {
            let completed = try XCTUnwrap(lease)
            XCTAssertEqual(completed.footer.totalRecordCount, UInt64(recordCount))
            XCTAssertEqual(completed.footer.searchableRegularFileCount, UInt64(recordCount))
            XCTAssertGreaterThan(completed.statistics.initialRunCount, policy.maximumOpenRuns)
            XCTAssertGreaterThan(completed.statistics.mergePassCount, 1)
            XCTAssertLessThanOrEqual(completed.statistics.peakBufferedRecordBytes, policy.maximumBufferedRecordBytes)
            XCTAssertLessThanOrEqual(completed.statistics.peakResidentScheduledRunCount, policy.maximumOpenRuns)
            XCTAssertLessThanOrEqual(completed.artifactByteCount, policy.maximumAggregateArtifactBytes ?? .max)
            XCTAssertGreaterThanOrEqual(completed.statistics.peakWorkspaceByteCount, completed.artifactByteCount)
            XCTAssertGreaterThanOrEqual(
                completed.statistics.peakAggregateArtifactByteCount,
                completed.statistics.peakWorkspaceByteCount
            )
            XCTAssertLessThanOrEqual(
                completed.statistics.peakWorkspaceByteCount,
                policy.maximumAggregateArtifactBytes ?? .max
            )
            XCTAssertLessThanOrEqual(
                completed.statistics.peakAggregateArtifactByteCount,
                policy.maximumAggregateArtifactBytes ?? .max
            )
            let reader = try completed.makeReader()
            while try reader.next() != nil {
                observed += 1
            }
            XCTAssertEqual(reader.validationState, .verified)
        }
        XCTAssertEqual(observed, recordCount)
        lease = nil
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
    }

    private func containsSpillRun(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix("run.") { return true }
        }
        return false
    }

    private func inventoryHeader() throws -> WorkspaceRootReusableInventoryManifestHeader {
        let oid = try GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: "2", count: 40))
        return try WorkspaceRootReusableInventoryManifestHeader(
            compatibilityDomain: WorkspaceRootReusableSnapshot.manifestCompatibilityDomain,
            compatibilityDigest: Data(repeating: 3, count: 32),
            treeOID: oid,
            objectFormat: .sha1,
            repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""),
            commandFormat: GitLoadedRootTreeInventorySpool.commandFormat,
            rawStandardOutputDigest: Data(repeating: 4, count: 32),
            catalogPolicyDigest: Data(repeating: 5, count: 32)
        )
    }

    private func inventoryRecord(path: String) throws -> WorkspaceRootReusableInventoryManifestRecord {
        try WorkspaceRootReusableInventoryManifestRecord(
            rootRelativePath: path,
            mode: "100644",
            kind: .blob,
            objectID: GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: "1", count: 40)),
            catalogProjection: .searchableRegularFile
        )
    }
}

private final class LazyPrefixCandidateSource: GitPrefixControlCandidateSource {
    private let root: URL
    private let logicalNoiseCount: Int
    private let lateControl: URL
    private var index = 0
    private(set) var emittedNoiseCount = 0

    init(root: URL, logicalNoiseCount: Int, lateControl: URL) {
        self.root = root
        self.logicalNoiseCount = logicalNoiseCount
        self.lateControl = lateControl
    }

    func nextCandidate() throws -> URL? {
        if index < logicalNoiseCount {
            defer { index += 1
                emittedNoiseCount += 1
            }
            return root.appendingPathComponent("logical-noise-\(index)")
        }
        if index == logicalNoiseCount {
            index += 1
            return lateControl
        }
        return nil
    }

    func skipDescendants() {}
}

private final class AuthorityEvidenceFixture {
    let root: URL
    let layout: GitRepositoryLayout
    private let cleanupRoot: URL

    init(makeCommit: Bool = false, rootAncestorComponents: [String] = []) throws {
        let cleanupRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rpce-loaded-root-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        self.cleanupRoot = cleanupRoot
        root = rootAncestorComponents.reduce(cleanupRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.git(["init", "-q"], at: root)
        try Self.git(["config", "user.email", "tests@example.invalid"], at: root)
        try Self.git(["config", "user.name", "RepoPrompt Tests"], at: root)
        if makeCommit {
            try "let value = 1\n".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            try Self.git(["add", "A.swift"], at: root)
            try Self.git(["commit", "-q", "-m", "fixture"], at: root)
        }
        layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: root))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: cleanupRoot)
    }

    private static func git(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitLoadedRootAuthorityEvidenceTests", code: Int(process.terminationStatus))
        }
    }
}
