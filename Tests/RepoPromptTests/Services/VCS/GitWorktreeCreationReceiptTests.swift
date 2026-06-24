import CoreServices
import Darwin
@testable import RepoPrompt
import XCTest

final class GitWorktreeCreationReceiptTests: XCTestCase {
    func testWitnessCoverageRejectsZeroAndSinceNowJournalCuts() {
        func coverage(start: UInt64, end: UInt64) -> GitWorktreeCreationWitnessCoverage {
            GitWorktreeCreationWitnessCoverage(
                startedAtUptimeNanoseconds: 1,
                endedAtUptimeNanoseconds: 2,
                startEventID: start,
                endEventID: end,
                destinationRelativePaths: [],
                affectedDestinationRelativeDirectories: [],
                streamStartedBeforeMutation: true,
                streamEndedAfterInitialization: true,
                hadGap: false,
                hadDrop: false,
                overflowed: false
            )
        }

        XCTAssertFalse(coverage(start: 0, end: 0).provesCreationInterval)
        XCTAssertFalse(coverage(start: UInt64.max, end: UInt64.max).provesCreationInterval)
        XCTAssertTrue(coverage(start: 10, end: 11).provesCreationInterval)
    }

    func testSubdirectoryReceiptPlansOnlyCorrespondingPhysicalRoot() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        try fixture.write("Subdir/Inside.swift", "let inside = true\n")
        try fixture.git(["add", "Subdir/Inside.swift"])
        try fixture.git(["commit", "-m", "subdirectory root"])

        let logicalRoot = fixture.root.appendingPathComponent("Subdir", isDirectory: true)
        let prefix = try GitRepositoryRelativeRootPrefix("Subdir")
        let authority = GitWorkspaceStateAuthority.shared
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: logicalRoot,
            authoritativeRelativeFilePaths: ["Inside.swift"]
        ) else { return XCTFail("Expected prefix-scoped reusable snapshot") }

        let initializationContext = GitWorktreeInitializationContext(
            agentSessionID: fixture.agentSessionID,
            correlationID: fixture.correlationID,
            logicalRootPath: logicalRoot.path,
            expectedOwnerBindingGeneration: fixture.expectedOwnerBindingGeneration,
            repositoryRelativeRootPrefix: prefix,
            observeReceipt: true
        )
        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: initializationContext
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        let physicalRoot = URL(fileURLWithPath: result.descriptor.path, isDirectory: true)
            .appendingPathComponent(prefix.value, isDirectory: true)
            .standardizedFileURL.path
        let binding = AgentSessionWorktreeBinding(
            id: "subdir-binding",
            repositoryID: result.descriptor.repository.repositoryID,
            repoKey: result.descriptor.repository.repoKey,
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: result.descriptor.worktreeID,
            worktreeRootPath: physicalRoot,
            source: "test"
        )
        let startupContext = fixture.startupContext()
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: physicalRoot,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        ).validated(
            matching: binding,
            sessionID: fixture.agentSessionID,
            startupContext: startupContext
        )
        XCTAssertNil(hint.validationFallbackReason)

        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: logicalRoot.path)
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
        WorktreeStartupInstrumentation.resetForTesting()
        let preparation = try await materializer.prepare(
            sessionID: fixture.agentSessionID,
            bindings: [binding],
            startupContext: startupContext,
            initializationHintsByBindingID: [binding.id: hint]
        )
        XCTAssertEqual(
            preparation.ownership.materializationHintObservationsByPhysicalRootPath[physicalRoot],
            .eligible(receipt.parentSnapshotIdentity)
        )
        XCTAssertEqual(WorktreeStartupInstrumentation.snapshot().shadow.inventoryMatches, 1)
        await materializer.abort(preparation)
        await store.unloadRoot(id: logicalRecord.id)
    }

    func testReceiptKeepsReusableParentWhenRequestedTargetTreeDiffers() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        try fixture.write("Tracked.swift", "let value = 2\n")
        try fixture.git(["add", "Tracked.swift"])
        try fixture.git(["commit", "-m", "new parent snapshot"])

        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case let .admitted(snapshotIdentity) = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else { return XCTFail("Expected reusable parent snapshot") }

        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(baseRef: "HEAD~1"),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        XCTAssertEqual(receipt.parentSnapshotIdentity, snapshotIdentity)
        XCTAssertNotEqual(receipt.parentCompatibilityKey.treeOID, receipt.resolvedBaseTreeOID)
        XCTAssertEqual(receipt.targetAuthorityAfter.treeOID, receipt.resolvedBaseTreeOID)
        XCTAssertNil(receipt.fallbackReason())

        let binding = fixture.binding(for: result.descriptor)
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: binding.worktreeRootPath,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        ).validated(
            matching: binding,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext()
        )
        let evaluator = WorkspaceRootMaterializationHintEvaluator(gitService: git, authority: authority)
        let eligibility = await evaluator.observe(hint, observationEnabled: true)
        XCTAssertEqual(eligibility, .eligible(snapshotIdentity))
    }

    func testSameRepositoryLinkedWorktreeReceiptIsEligibleAndCarriesExactScope() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)

        let observed = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        )
        guard case let .admitted(snapshotIdentity) = observed else {
            return XCTFail("Expected reusable parent snapshot, got \(observed)")
        }

        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        XCTAssertEqual(receipt.parentSnapshotIdentity, snapshotIdentity)
        XCTAssertEqual(receipt.parentCompatibilityKey.treeOID, receipt.resolvedBaseTreeOID)
        XCTAssertEqual(receipt.parentCompatibilityKey, WorkspaceRootSeedCompatibilityKey(authority: receipt.parentAuthorityBefore))
        XCTAssertEqual(receipt.parentCompatibilityKey, WorkspaceRootSeedCompatibilityKey(authority: receipt.targetAuthorityAfter))
        XCTAssertEqual(receipt.repositoryRelativeRootPrefix.value, "")
        XCTAssertEqual(receipt.worktree.worktreeID, result.descriptor.worktreeID)
        XCTAssertEqual(receipt.targetLayout.workTreeRoot.standardizedFileURL.path, result.descriptor.path)
        XCTAssertEqual(receipt.exactCopiedRelativePaths, ["secret.txt"])
        XCTAssertTrue(receipt.witnessCoverage.provesCreationInterval)
        XCTAssertNil(receipt.fallbackReason())

        let binding = fixture.binding(for: result.descriptor)
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: binding.worktreeRootPath,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        ).validated(
            matching: binding,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext()
        )
        let evaluator = WorkspaceRootMaterializationHintEvaluator(gitService: git, authority: authority)
        let eligibility = await evaluator.observe(hint, observationEnabled: true)
        XCTAssertEqual(eligibility, .eligible(snapshotIdentity))
    }

    func testLoadedRootAdmissionRaceRevokesProvisionalAliasAndCoverage() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let previousObserve = defaults.object(forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
        let previousServe = defaults.object(forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
        defaults.set(false, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
        defaults.set(false, forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
        defer {
            if let previousObserve {
                defaults.set(previousObserve, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            } else {
                defaults.removeObject(forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            }
            if let previousServe {
                defaults.set(previousServe, forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
            } else {
                defaults.removeObject(forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
            }
        }

        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: fixture.root.path)
        try await store.startWatchingRoot(id: logicalRecord.id)
        let authority = GitWorkspaceStateAuthority.shared
        let coordinator = WorkspaceRootReusableSnapshotCoordinator.shared
        let baselineCache = await authority.snapshotForTesting()
        let monitor = await authority.metadataMonitorForTesting()
        let baselineCoverage = await monitor.snapshotForTesting()
        addTeardownBlock {
            await coordinator.setPreparedAdmissionHandlerForTesting(nil)
            await store.stopWatchingRoot(id: logicalRecord.id)
            await store.unloadRoot(id: logicalRecord.id)
        }

        await coordinator.setPreparedAdmissionHandlerForTesting {
            _ = try? await store.acceptWatcherPayloadForTesting(
                rootID: logicalRecord.id,
                events: [(
                    absolutePath: fixture.root.appendingPathComponent("Tracked.swift").path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 9001
                )],
                scheduleDrain: false
            )
        }
        let admission = try await store.admitReusableSnapshotForLoadedRoot(
            rootID: logicalRecord.id,
            expectedStandardizedPath: logicalRecord.standardizedFullPath
        )
        await coordinator.setPreparedAdmissionHandlerForTesting(nil)

        XCTAssertEqual(
            admission,
            .failed(.init(stage: .preparedAdmissionCurrentness, cause: .loadedRootWatcherStale))
        )
        let cache = await authority.snapshotForTesting()
        let coverage = await monitor.snapshotForTesting()
        XCTAssertEqual(cache.reusableSnapshotCount, baselineCache.reusableSnapshotCount)
        XCTAssertEqual(cache.reusableSnapshotAliasCount, baselineCache.reusableSnapshotAliasCount)
        XCTAssertEqual(cache.reusableSnapshotEstimatedBytes, baselineCache.reusableSnapshotEstimatedBytes)
        XCTAssertEqual(coverage.retainTokenCount, baselineCoverage.retainTokenCount)
        XCTAssertEqual(coverage.retainedRepositoryCount, baselineCoverage.retainedRepositoryCount)
    }

    func testLoadedRootAdmissionCurrentnessClassifiesOwnerStaleness() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: fixture.root.path)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator.shared
        await coordinator.setPreparedAdmissionHandlerForTesting {
            await store.unloadRoot(id: logicalRecord.id)
        }

        let admission = try await store.admitReusableSnapshotForLoadedRoot(
            rootID: logicalRecord.id,
            expectedStandardizedPath: logicalRecord.standardizedFullPath
        )
        await coordinator.setPreparedAdmissionHandlerForTesting(nil)

        XCTAssertEqual(
            admission,
            .failed(.init(stage: .preparedAdmissionCurrentness, cause: .loadedRootOwnerStale))
        )
    }

    func testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: fixture.root.path)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator.shared
        await coordinator.setPreparedAdmissionHandlerForTesting {
            await store.replayObservedFileSystemDeltas(
                rootID: logicalRecord.id,
                deltas: [.fileModified("Tracked.swift", Date())]
            )
        }
        addTeardownBlock {
            await coordinator.setPreparedAdmissionHandlerForTesting(nil)
            await store.unloadRoot(id: logicalRecord.id)
        }

        let admission = try await store.admitReusableSnapshotForLoadedRoot(
            rootID: logicalRecord.id,
            expectedStandardizedPath: logicalRecord.standardizedFullPath
        )
        await coordinator.setPreparedAdmissionHandlerForTesting(nil)

        XCTAssertEqual(
            admission,
            .failed(.init(stage: .preparedAdmissionCurrentness, cause: .loadedRootCatalogStale))
        )
    }

    func testReceiptFallbackRestartAndConcurrentBindingIsolationMatrix() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else {
            return XCTFail("Expected reusable parent snapshot")
        }
        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        let binding = fixture.binding(for: result.descriptor)
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: binding.worktreeRootPath,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        )

        XCTAssertEqual(
            receipt.fallbackReason(nowUptimeNanoseconds: receipt.expiresAtUptimeNanoseconds &+ 1),
            .expiredReceipt
        )
        let evaluator = WorkspaceRootMaterializationHintEvaluator(gitService: git, authority: authority)
        let missingReceipt = await evaluator.observe(nil, observationEnabled: true)
        let disabledObservation = await evaluator.observe(hint, observationEnabled: false)
        XCTAssertEqual(missingReceipt, .fallback(.noReceipt))
        XCTAssertEqual(disabledObservation, .observationDisabled)

        let restartedAuthority = GitWorkspaceStateAuthority()
        let restartedEvaluator = WorkspaceRootMaterializationHintEvaluator(
            gitService: GitService(workspaceStateAuthority: restartedAuthority),
            authority: restartedAuthority
        )
        let restartFallback = await restartedEvaluator.observe(hint, observationEnabled: true)
        XCTAssertEqual(restartFallback, .fallback(.baseEvicted))

        let otherSessionBinding = AgentSessionWorktreeBinding(
            id: "other-binding",
            repositoryID: "other-repository",
            repoKey: "other-repository-key",
            logicalRootPath: binding.logicalRootPath,
            worktreeID: "other-worktree",
            worktreeRootPath: fixture.sandbox.appendingPathComponent("other-target").path,
            source: "test"
        )
        let isolatedHint = hint.validated(
            matching: otherSessionBinding,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext()
        )
        XCTAssertEqual(isolatedHint.validationFallbackReason, .compatibilityMismatch)
        let isolatedFallback = await evaluator.observe(isolatedHint, observationEnabled: true)
        XCTAssertEqual(isolatedFallback, .fallback(.compatibilityMismatch))

        let incompatibleIdentity = WorkspaceRootReusableSnapshotIdentity(
            sha256: receipt.parentSnapshotIdentity.sha256,
            searchABI: GitWorkspaceSearchABIIdentity(
                matcherSchemaVersion: 999,
                projectedKeySchemaVersion: 1,
                comparatorSchemaVersion: 1,
                pathNormalizationSchemaVersion: 1
            )
        )
        let incompatibleSnapshot = await authority.reusableSnapshot(
            identity: incompatibleIdentity,
            expectedCompatibilityKey: receipt.parentCompatibilityKey
        )
        XCTAssertNil(incompatibleSnapshot)
    }

    func testReceiptDataIsNotPersistedWithBindingSchema() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else {
            return XCTFail("Expected reusable parent snapshot")
        }
        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        let binding = fixture.binding(for: result.descriptor)
        let encoded = try JSONEncoder().encode(binding)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let decoded = try JSONDecoder().decode(AgentSessionWorktreeBinding.self, from: encoded)

        XCTAssertEqual(decoded, binding)
        XCTAssertFalse(json.contains(receipt.id.uuidString))
        XCTAssertFalse(json.contains(receipt.correlationID.uuidString))
        XCTAssertFalse(json.contains(receipt.parentSnapshotIdentity.sha256))
        XCTAssertFalse(json.contains("secret.txt"))
        XCTAssertFalse(json.contains("witnessCoverage"))
        XCTAssertFalse(json.contains("initializationReceipt"))
    }

    func testConcurrentSameRepositoryCreationsKeepReceiptsSessionIsolated() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else {
            return XCTFail("Expected reusable parent snapshot")
        }
        let firstCorrelation = UUID()
        let secondCorrelation = UUID()
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        async let first = try git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext(
                agentSessionID: firstSessionID,
                correlationID: firstCorrelation
            )
        )
        async let second = try git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext(
                agentSessionID: secondSessionID,
                correlationID: secondCorrelation
            )
        )
        let (firstResult, secondResult) = try await (first, second)
        let firstReceipt = try XCTUnwrap(firstResult.initializationReceipt)
        let secondReceipt = try XCTUnwrap(secondResult.initializationReceipt)
        XCTAssertEqual(firstReceipt.correlationID, firstCorrelation)
        XCTAssertEqual(secondReceipt.correlationID, secondCorrelation)
        XCTAssertNotEqual(firstReceipt.id, secondReceipt.id)
        XCTAssertNotEqual(firstReceipt.actualTargetPath, secondReceipt.actualTargetPath)
        XCTAssertEqual(firstReceipt.parentSnapshotIdentity, secondReceipt.parentSnapshotIdentity)

        let firstBinding = fixture.binding(for: firstResult.descriptor)
        let secondBinding = fixture.binding(for: secondResult.descriptor)
        let firstHint = WorkspaceRootMaterializationHint(
            bindingID: firstBinding.id,
            standardizedTargetPath: firstBinding.worktreeRootPath,
            creationReceipt: firstReceipt,
            correlationID: firstCorrelation
        )
        XCTAssertNil(firstHint.validated(
            matching: firstBinding,
            sessionID: firstSessionID,
            startupContext: fixture.startupContext(
                agentSessionID: firstSessionID,
                correlationID: firstCorrelation
            )
        ).validationFallbackReason)
        XCTAssertEqual(
            firstHint.validated(
                matching: secondBinding,
                sessionID: firstSessionID,
                startupContext: fixture.startupContext(
                    agentSessionID: firstSessionID,
                    correlationID: firstCorrelation
                )
            ).validationFallbackReason,
            .compatibilityMismatch
        )
    }

    func testRootNeutralSnapshotExcludesTargetStateAndEvictsWithinBounds() async throws {
        let first = try ReceiptFixture()
        let second = try ReceiptFixture()
        defer {
            first.cleanup()
            second.cleanup()
        }
        let authority = GitWorkspaceStateAuthority(
            reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits(
                maximumSnapshotCount: 1,
                maximumSnapshotsPerRepository: 1,
                maximumEstimatedBytes: 8 * 1024 * 1024
            )
        )
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case let .admitted(firstIdentity) = await coordinator.observeAuthoritativeFullLoad(
            rootURL: first.root,
            authoritativeRelativeFilePaths: first.authoritativeRelativeFilePaths
        ) else {
            return XCTFail("Expected first reusable snapshot")
        }
        let firstLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: first.root))
        let firstLease: GitWorkspaceAuthorityLease
        switch try await authority.currentLease(
            for: GitWorkspaceAuthorityRepositoryKey(layout: firstLayout),
            prefix: GitRepositoryRelativeRootPrefix("")
        ) {
        case let .success(value): firstLease = value
        case let .failure(reason): return XCTFail("Missing first authority lease: \(reason)")
        }
        let capturedFirstSnapshot = await authority.currentReusableSnapshot(capturedUsing: firstLease)
        let firstSnapshot = try XCTUnwrap(capturedFirstSnapshot)
        XCTAssertTrue(firstSnapshot.searchBase.relativePaths.allSatisfy { !$0.hasPrefix("/") })
        XCTAssertFalse(firstSnapshot.searchBase.relativePaths.contains { $0.contains(first.root.path) })
        XCTAssertFalse(firstSnapshot.inventory.entries.contains { $0.relativePath.contains(first.root.path) })
        XCTAssertTrue(firstSnapshot.hasValidContentAddress())

        let secondAdmission = await coordinator.observeAuthoritativeFullLoad(
            rootURL: second.root,
            authoritativeRelativeFilePaths: second.authoritativeRelativeFilePaths
        )
        XCTAssertEqual(
            secondAdmission,
            .failed(.init(stage: .admissionCommit, cause: .admissionRejected)),
            "bounded cache must not evict active observed coverage"
        )
        let cache = await authority.snapshotForTesting()
        XCTAssertEqual(cache.reusableSnapshotCount, 1)
        XCTAssertLessThanOrEqual(cache.reusableSnapshotEstimatedBytes, 8 * 1024 * 1024)
        let retainedFirstSnapshot = await authority.reusableSnapshot(
            identity: firstIdentity,
            expectedCompatibilityKey: firstSnapshot.compatibilityKey
        )
        XCTAssertNotNil(retainedFirstSnapshot)
    }

    func testRepeatedAuthorityObservationReplacesAliasAndMetadataRetain() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)

        for iteration in 0 ..< 70 {
            guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
                rootURL: fixture.root,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
            ) else {
                return XCTFail("Repeated unchanged observation failed at iteration \(iteration)")
            }
        }

        let cache = await authority.snapshotForTesting()
        let monitor = await authority.metadataMonitorForTesting()
        let coverage = await monitor.snapshotForTesting()
        XCTAssertEqual(cache.reusableSnapshotCount, 1)
        XCTAssertEqual(cache.reusableSnapshotAliasCount, 1)
        XCTAssertEqual(coverage.retainedRepositoryCount, 1)
        XCTAssertEqual(coverage.retainTokenCount, 1)
    }

    func testMetadataCoverageReplacementIsTransactionalExactAndReleasesObsoletePaths() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let externalA = fixture.sandbox.appendingPathComponent("external-a-ignore")
        let externalB = fixture.sandbox.appendingPathComponent("external-b-ignore")
        try "a\n".write(to: externalA, atomically: true, encoding: .utf8)
        try "b\n".write(to: externalB, atomically: true, encoding: .utf8)

        let discovery = try await authority.retainMetadataObservation(
            for: layout,
            additionalAuthorityPaths: [externalA]
        )
        let monitor = await authority.metadataMonitorForTesting()
        let discoveryCoverage = await monitor.snapshotForTesting()
        let replacement = try await authority.retainMetadataObservation(
            for: layout,
            additionalAuthorityPaths: [externalB]
        )
        let replacementCoverage = await monitor.snapshotForTesting()
        XCTAssertEqual(replacementCoverage.sourceCount, discoveryCoverage.sourceCount + 1)

        let watermark = monitor.acceptedWatermark(for: GitWorkspaceAuthorityRepositoryKey(layout: layout))
        let exactReplacementIsCurrent = await authority.metadataObservationIsCurrent(
            replacement,
            for: layout,
            additionalAuthorityPaths: [externalB],
            expectedAcceptedWatermark: watermark
        )
        let mismatchedReplacementIsCurrent = await authority.metadataObservationIsCurrent(
            replacement,
            for: layout,
            additionalAuthorityPaths: [externalA],
            expectedAcceptedWatermark: watermark
        )
        XCTAssertTrue(exactReplacementIsCurrent)
        XCTAssertFalse(mismatchedReplacementIsCurrent)

        await authority.releaseMetadataObservation(discovery)
        let releasedDiscoveryCoverage = await monitor.snapshotForTesting()
        XCTAssertEqual(releasedDiscoveryCoverage.sourceCount, discoveryCoverage.sourceCount)
        XCTAssertEqual(releasedDiscoveryCoverage.retainTokenCount, 1)
        await authority.releaseMetadataObservation(replacement)
        let finalCoverage = await monitor.snapshotForTesting()
        XCTAssertEqual(finalCoverage.retainTokenCount, 0)
    }

    func testCommonRepositoryMutationFencesNewLinkedWorktreeAuthorityCollection() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let created = try await git.createWorktree(request: fixture.createRequest(), at: fixture.root)
        let sourceLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let targetLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(
            atWorkTreeRoot: URL(fileURLWithPath: created.path)
        ))
        let token = await authority.beginMutation(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: sourceLayout),
            kind: .worktreeCreate
        )
        let targetScope = try GitWorkspaceAuthorityScopeKey(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: targetLayout),
            repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix("")
        )
        switch await authority.beginCollection(scopeKey: targetScope) {
        case .success:
            XCTFail("new linked-worktree repository key escaped the common-directory mutation fence")
        case let .failure(reason):
            XCTAssertEqual(reason, .mutationInProgress)
        }
        do {
            _ = try await git.generationFencedAuthoritySnapshot(
                layout: targetLayout,
                prefix: GitRepositoryRelativeRootPrefix("")
            )
            XCTFail("generation-fenced collection unexpectedly crossed an active mutation")
        } catch let reason as GitWorkspaceAuthorityUnavailableReason {
            XCTAssertEqual(reason, .mutationInProgress)
        }
        await authority.finishMutation(token, outcome: .succeeded)
        let captured = try await git.generationFencedAuthoritySnapshot(
            layout: targetLayout,
            prefix: GitRepositoryRelativeRootPrefix("")
        )
        XCTAssertEqual(captured.repositoryKey, targetScope.repositoryKey)
        switch await authority.currentLease(
            for: targetScope.repositoryKey,
            prefix: targetScope.repositoryRelativeRootPrefix
        ) {
        case .success:
            XCTFail("ephemeral target proof remained published after observation retirement")
        case let .failure(reason):
            XCTAssertEqual(reason, .monitorCoverageUnavailable)
        }
    }

    func testCreationWitnessRecordsParentAndGlobalGapFlagsBeforePathFiltering() {
        let destination = "/tmp/receipt-witness-\(UUID().uuidString)"
        let recorder = WorkspaceRootCreationReceiptCoordinator.Recorder(destinationPath: destination)
        let gapFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        let dropFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        recorder.accept(path: "/tmp", flags: gapFlags, eventID: 40)
        recorder.accept(path: "/", flags: dropFlags, eventID: 41)
        let snapshot = recorder.snapshot()
        XCTAssertTrue(snapshot.hadGap)
        XCTAssertTrue(snapshot.hadDrop)
        XCTAssertEqual(snapshot.latestEventID, 41)
        XCTAssertTrue(snapshot.paths.isEmpty)
    }

    func testReceiptReplayFailsAcrossSessionLogicalRootAndOwnerGeneration() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority.shared
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else { return XCTFail("Expected reusable parent snapshot") }
        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        let binding = fixture.binding(for: result.descriptor)
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: binding.worktreeRootPath,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        )

        XCTAssertEqual(hint.validated(
            matching: binding,
            sessionID: UUID(),
            startupContext: fixture.startupContext()
        ).validationFallbackReason, .compatibilityMismatch)
        XCTAssertEqual(hint.validated(
            matching: binding,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext(correlationID: UUID())
        ).validationFallbackReason, .compatibilityMismatch)
        let differentLogicalRoot = AgentSessionWorktreeBinding(
            id: binding.id,
            repositoryID: binding.repositoryID,
            repoKey: binding.repoKey,
            logicalRootPath: fixture.sandbox.path,
            logicalRootName: binding.logicalRootName,
            worktreeID: binding.worktreeID,
            worktreeRootPath: binding.worktreeRootPath,
            worktreeName: binding.worktreeName,
            branch: binding.branch,
            head: binding.head,
            visualLabel: binding.visualLabel,
            visualColorHex: binding.visualColorHex,
            boundAt: binding.boundAt,
            source: binding.source
        )
        XCTAssertEqual(hint.validated(
            matching: differentLogicalRoot,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext()
        ).validationFallbackReason, .compatibilityMismatch)

        let store = WorkspaceFileContextStore()
        let warmup = try await store.prepareSessionWorktreeOwnership(
            ownerID: fixture.agentSessionID,
            bindingFingerprint: "prior-owner-generation",
            physicalRootPaths: []
        )
        _ = try await store.commitSessionWorktreeOwnership(warmup)
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
        let preparation = try await materializer.prepare(
            sessionID: fixture.agentSessionID,
            bindings: [binding],
            startupContext: fixture.startupContext(),
            initializationHintsByBindingID: [binding.id: hint]
        )
        XCTAssertEqual(
            preparation.ownership.materializationHintObservationsByPhysicalRootPath[result.descriptor.path],
            .fallback(.ownerSuperseded)
        )
        let diagnostics = await store.readSearchRootDiagnosticsSnapshot()
        XCTAssertEqual(diagnostics.first { $0.rootPath == result.descriptor.path }?.crawlCount, 1)
        await materializer.abort(preparation)
    }

    func testExternalAndIncludeCopySkippedDestinationsNeverReceiveReusableReceipt() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)

        let externalRequest = GitWorktreeCreateRequest(
            path: fixture.sandbox.appendingPathComponent("external-child"),
            branch: "external-\(UUID().uuidString)",
            baseRef: "HEAD",
            allowExternalPath: true,
            appManagedContainer: fixture.worktrees,
            mainWorktreeRoot: fixture.root,
            knownWorktreeRoots: [fixture.root],
            copyWorktreeIncludeFiles: true
        )
        let externalResult = try await git.createWorktreeWithResult(
            request: externalRequest,
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        XCTAssertNil(externalResult.initializationReceipt)
        XCTAssertEqual(externalResult.initializationFallbackReason, .unsupportedDestination)

        let skippedBase = fixture.createRequest()
        let skippedRequest = GitWorktreeCreateRequest(
            path: skippedBase.path,
            branch: skippedBase.branch,
            baseRef: skippedBase.baseRef,
            appManagedContainer: skippedBase.appManagedContainer,
            mainWorktreeRoot: skippedBase.mainWorktreeRoot,
            knownWorktreeRoots: skippedBase.knownWorktreeRoots,
            copyWorktreeIncludeFiles: false
        )
        let skippedResult = try await git.createWorktreeWithResult(
            request: skippedRequest,
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        XCTAssertNil(skippedResult.initializationReceipt)
        XCTAssertEqual(skippedResult.initializationFallbackReason, .includeCopyFailure)
    }

    func testReusableSnapshotCurrentnessFailuresRetainEveryStage() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let cases: [(failureCall: Int, stage: WorkspaceRootReusableSnapshotCoordinator.ObservationFailureStage)] = [
            (1, .initialCurrentness),
            (2, .discoveryObservation),
            (3, .discoveryAuthorityCapture),
            (4, .replacementObservation),
            (5, .collection),
            (7, .capturedAuthority),
            (9, .treeInventory),
            (10, .admissionPreparation),
            (11, .preparedAdmissionCurrentness),
            (13, .committedAdmissionCurrentness)
        ]

        for testCase in cases {
            let authority = GitWorkspaceStateAuthority()
            let coordinator = WorkspaceRootReusableSnapshotCoordinator(
                gitService: GitService(workspaceStateAuthority: authority),
                authority: authority
            )
            let currentness = CurrentnessFailureGate(failureCall: testCase.failureCall)
            let result = await coordinator.observeAuthoritativeFullLoad(
                rootURL: fixture.root,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths,
                currentnessValidator: { await currentness.validation() }
            )

            XCTAssertEqual(
                result,
                .failed(.init(stage: testCase.stage, cause: .staleCurrentness)),
                "currentness call \(testCase.failureCall)"
            )
            let snapshot = await authority.snapshotForTesting()
            XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
        }
    }

    func testReusableSnapshotCurrentnessPreservesLoadedRootCauseMatrix() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let causes: [WorkspaceRootReusableSnapshotCoordinator.ObservationFailureCause] = [
            .loadedRootOwnerStale,
            .loadedRootCatalogStale,
            .loadedRootWatcherStale
        ]

        for cause in causes {
            let authority = GitWorkspaceStateAuthority()
            let coordinator = WorkspaceRootReusableSnapshotCoordinator(
                gitService: GitService(workspaceStateAuthority: authority),
                authority: authority
            )
            let currentness = CurrentnessFailureGate(failureCall: 11, failureCause: cause)
            let result = await coordinator.observeAuthoritativeFullLoad(
                rootURL: fixture.root,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths,
                currentnessValidator: { await currentness.validation() }
            )

            XCTAssertEqual(
                result,
                .failed(.init(stage: .preparedAdmissionCurrentness, cause: cause))
            )
            let snapshot = await authority.snapshotForTesting()
            XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
        }
    }

    func testReusableSnapshotPreparedCurrentnessCancellationIsNotStaleness() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let currentness = CurrentnessFailureGate(failureCall: 11, cancelOnFailure: true)

        let result = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths,
            currentnessValidator: { await currentness.validation() }
        )

        XCTAssertEqual(
            result,
            .failed(.init(stage: .preparedAdmissionCurrentness, cause: .cancelled))
        )
        let snapshot = await authority.snapshotForTesting()
        XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
    }

    func testReusableSnapshotPreparedAuthorityInvalidationRetainsStageAndReason() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let tokenBox = MutationTokenBox()
        await coordinator.setPreparedAdmissionHandlerForTesting {
            let token = await authority.beginMutation(
                repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
                kind: .other
            )
            await tokenBox.set(token)
        }
        defer { Task { await coordinator.setPreparedAdmissionHandlerForTesting(nil) } }

        let result = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        )
        if let token = await tokenBox.take() {
            await authority.finishMutation(token, outcome: .cancelled)
        }

        XCTAssertEqual(
            result,
            .authorityUnavailable(
                stage: .preparedAdmissionCurrentness,
                reason: .invalidatedDuringCollection
            )
        )
        let snapshot = await authority.snapshotForTesting()
        XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
    }

    func testReusableSnapshotCancellationIsPathFreeAndTyped() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let task = Task {
            await coordinator.observeAuthoritativeFullLoad(
                rootURL: fixture.root,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
            )
        }
        task.cancel()

        let result = await task.value
        XCTAssertEqual(
            result,
            .failed(.init(stage: .initialCurrentness, cause: .cancelled))
        )
    }

    func testNonGitObservationDoesNotInvokeGit() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("NonGitRootSeedIsolation-\(UUID().uuidString)", isDirectory: true)
        let marker = sandbox.appendingPathComponent("git-invoked")
        let executable = sandbox.appendingPathComponent("fake-git")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 99\n".write(to: executable, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(executable.path, 0o755), 0)

        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(gitExecutableURL: executable, workspaceStateAuthority: authority),
            authority: authority
        )
        let observation = await coordinator.observeAuthoritativeFullLoad(
            rootURL: sandbox,
            authoritativeRelativeFilePaths: []
        )
        XCTAssertEqual(observation, .nonGit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

private actor CurrentnessFailureGate {
    private let failureCall: Int
    private let failureCause: WorkspaceRootReusableSnapshotCoordinator.ObservationFailureCause
    private let cancelOnFailure: Bool
    private var callCount = 0

    init(
        failureCall: Int,
        failureCause: WorkspaceRootReusableSnapshotCoordinator.ObservationFailureCause = .staleCurrentness,
        cancelOnFailure: Bool = false
    ) {
        self.failureCall = failureCall
        self.failureCause = failureCause
        self.cancelOnFailure = cancelOnFailure
    }

    func validation() -> WorkspaceRootReusableSnapshotCoordinator.CurrentnessValidation {
        callCount += 1
        guard callCount == failureCall else { return .current }
        if cancelOnFailure {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return .current
        }
        return .stale(failureCause)
    }
}

private actor MutationTokenBox {
    private var token: GitWorkspaceMutationToken?

    func set(_ token: GitWorkspaceMutationToken) {
        self.token = token
    }

    func take() -> GitWorkspaceMutationToken? {
        defer { token = nil }
        return token
    }
}

private struct ReceiptFixture {
    let sandbox: URL
    let root: URL
    let worktrees: URL
    let correlationID = UUID()
    let agentSessionID = UUID()
    let expectedOwnerBindingGeneration: UInt64 = 1

    var authoritativeRelativeFilePaths: Set<String> {
        [".gitignore", ".worktreeinclude", "Tracked.swift"]
    }

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeCreationReceiptTests-\(UUID().uuidString)", isDirectory: true)
        root = sandbox.appendingPathComponent("repo", isDirectory: true)
        worktrees = sandbox.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        try git(["init"])
        try git(["config", "user.name", "RepoPrompt Test"])
        try git(["config", "user.email", "repoprompt@example.test"])
        try git(["config", "commit.gpgSign", "false"])
        try write("Tracked.swift", "let value = 1\n")
        try write(".gitignore", "secret.txt\n")
        try write(".worktreeinclude", "secret.txt\n")
        try write("secret.txt", "ephemeral secret\n")
        try git(["add", "Tracked.swift", ".gitignore", ".worktreeinclude"])
        try git(["commit", "-m", "base"])
    }

    func initializationContext(
        agentSessionID: UUID? = nil,
        correlationID: UUID? = nil,
        expectedOwnerBindingGeneration: UInt64? = nil
    ) -> GitWorktreeInitializationContext {
        GitWorktreeInitializationContext(
            agentSessionID: agentSessionID ?? self.agentSessionID,
            correlationID: correlationID ?? self.correlationID,
            logicalRootPath: root.path,
            expectedOwnerBindingGeneration: expectedOwnerBindingGeneration
                ?? self.expectedOwnerBindingGeneration,
            repositoryRelativeRootPrefix: try! GitRepositoryRelativeRootPrefix(""),
            observeReceipt: true
        )
    }

    func startupContext(
        agentSessionID: UUID? = nil,
        correlationID: UUID? = nil
    ) -> WorktreeStartupContext {
        WorktreeStartupContext(
            agentSessionID: agentSessionID ?? self.agentSessionID,
            correlationID: correlationID ?? self.correlationID,
            flags: WorktreeStartupFeatureFlags(observeDiffSeededWorktreeStartup: true)
        )
    }

    func createRequest(baseRef: String = "HEAD") -> GitWorktreeCreateRequest {
        let target = worktrees.appendingPathComponent("child-\(UUID().uuidString)", isDirectory: true)
        return GitWorktreeCreateRequest(
            path: target,
            branch: "receipt-\(UUID().uuidString)",
            baseRef: baseRef,
            appManagedContainer: worktrees,
            mainWorktreeRoot: root,
            knownWorktreeRoots: [root],
            copyWorktreeIncludeFiles: true
        )
    }

    func binding(for descriptor: GitWorktreeDescriptor) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(UUID().uuidString)",
            repositoryID: descriptor.repository.repositoryID,
            repoKey: descriptor.repository.repoKey,
            logicalRootPath: root.path,
            logicalRootName: root.lastPathComponent,
            worktreeID: descriptor.worktreeID,
            worktreeRootPath: descriptor.path,
            worktreeName: descriptor.name,
            branch: descriptor.branch,
            head: descriptor.head,
            source: "test"
        )
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitWorktreeCreationReceiptTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }
}
