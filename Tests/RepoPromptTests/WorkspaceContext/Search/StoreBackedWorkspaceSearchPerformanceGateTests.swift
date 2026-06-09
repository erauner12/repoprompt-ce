import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class StoreBackedWorkspaceSearchPerformanceGateTests: XCTestCase {
        private static let metricOutputEnvironmentKey = "REPOPROMPT_CE_SEARCH_METRICS_OUTPUT"
        private static let metricOutputMarkerFileName = ".repoprompt-ce-search-metrics-output"
        private static let routineCorpusFileCount = 24
        private static let metricCorpusFileCounts = [24, 96]
        private static let metricRepetitionCount = 3
        private static let matchesPerFile = 2
        private static let cappedMatchCount = 5
        private static let kValues = [1, 6, 12]

        private var temporaryRoots: [URL] = []

        override func tearDownWithError() throws {
            EditFlowPerf.resetDebugCaptureForTesting()
            for root in temporaryRoots {
                try? FileManager.default.removeItem(at: root)
            }
            temporaryRoots.removeAll()
            try super.tearDownWithError()
        }

        func testWarmRepeatedSearchRegressionGatesAtSameStoreAndSeparateStoreK1K6K12() async throws {
            for topology in SearchTopology.allCases {
                for k in Self.kValues {
                    _ = try await runScenario(
                        topology: topology,
                        k: k,
                        fileCount: Self.routineCorpusFileCount,
                        verifyCancellationRecovery: topology == .sameStore
                    )
                }
            }
        }

        func testOptInSearchMetricsMatrixEmitsJSON() async throws {
            guard let outputURL = Self.metricOutputURL() else {
                throw XCTSkip("Set \(Self.metricOutputEnvironmentKey) to write opt-in CE search metrics.")
            }

            var metrics: [ScenarioMetrics] = []
            for fileCount in Self.metricCorpusFileCounts {
                for topology in SearchTopology.allCases {
                    for k in Self.kValues {
                        var samples: [ScenarioOutcome] = []
                        for _ in 0 ..< Self.metricRepetitionCount {
                            try await samples.append(runScenario(
                                topology: topology,
                                k: k,
                                fileCount: fileCount,
                                verifyCancellationRecovery: false
                            ))
                        }
                        metrics.append(ScenarioMetrics(
                            topology: topology,
                            k: k,
                            corpusFileCount: fileCount,
                            expectedCountPerSearch: fileCount * Self.matchesPerFile,
                            repetitionCount: samples.count,
                            coldCount: TimingSamples(samples.map(\.coldCountDurationMs)),
                            warmCapped: TimingSamples(samples.map(\.warmCappedDurationMs)),
                            warmCount: TimingSamples(samples.map(\.warmCountDurationMs)),
                            cacheLoadCount: samples.map(\.cacheLoadCount),
                            cacheAcceptedLoadCount: samples.map(\.cacheAcceptedLoadCount),
                            cacheHitCountAfterWarm: samples.map(\.cacheHitCountAfterWarm),
                            revisionLineIndexSamples: samples.map(\.revisionLineIndexSamples),
                            hashFallbackSamples: samples.map(\.hashFallbackSamples),
                            contentReadPermitSamples: samples.map(\.contentReadPermitSamples),
                            contentReadWorkerBodySamples: samples.map(\.contentReadWorkerBodySamples),
                            maximumActivePerLane: samples.map(\.maximumActivePerLane),
                            maximumQueuedPerLane: samples.map(\.maximumQueuedPerLane),
                            timingsUseAdmissionHooks: false,
                            sameStoreScopedBypassWhileBroadHeld: Self.proofStatus(
                                samples.map(\.sameStoreScopedBypassWhileBroadHeldProved)
                            ),
                            separateStoreBroadLaneIsolation: Self.proofStatus(
                                samples.map(\.separateStoreBroadLaneIsolationProved)
                            ),
                            correctnessPassed: samples.allSatisfy(\.correctnessPassed),
                            lanesIdle: samples.allSatisfy(\.lanesIdle),
                            readLimiterIdle: samples.allSatisfy(\.readLimiterIdle)
                        ))
                    }
                }
            }

            let report = SearchMetricReport(
                schemaVersion: 3,
                fixtureVersion: "ce-store-backed-search-v3",
                implementation: "ce",
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                scenarios: metrics
            )
            try emitMetrics(report, to: outputURL)
            print("CE_SEARCH_METRICS_PATH \(outputURL.path)")
        }

        private enum SearchTopology: String, Codable, CaseIterable {
            case sameStore = "same_store"
            case separateStores = "separate_stores"
        }

        private enum ProofStatus: String, Codable {
            case notApplicable = "not_applicable"
            case proved
            case failed
        }

        private struct Fixture {
            let store: WorkspaceFileContextStore
            let rootID: UUID
            let orderedFilePaths: [String]
            let orderedRelativePaths: [String]
        }

        private struct Measurement<Value> {
            let value: Value
            let milliseconds: Double
        }

        private struct ScenarioOutcome {
            let coldCountDurationMs: Double
            let warmCappedDurationMs: Double
            let warmCountDurationMs: Double
            let cacheLoadCount: Int
            let cacheAcceptedLoadCount: Int
            let cacheHitCountAfterWarm: Int
            let revisionLineIndexSamples: Int
            let hashFallbackSamples: Int
            let contentReadPermitSamples: Int
            let contentReadWorkerBodySamples: Int
            let maximumActivePerLane: Int
            let maximumQueuedPerLane: Int
            let sameStoreScopedBypassWhileBroadHeldProved: Bool?
            let separateStoreBroadLaneIsolationProved: Bool?
            let correctnessPassed: Bool
            let lanesIdle: Bool
            let readLimiterIdle: Bool
        }

        private struct SearchMetricReport: Codable {
            let schemaVersion: Int
            let fixtureVersion: String
            let implementation: String
            let generatedAt: String
            let scenarios: [ScenarioMetrics]
        }

        private struct ScenarioMetrics: Codable {
            let topology: SearchTopology
            let k: Int
            let corpusFileCount: Int
            let expectedCountPerSearch: Int
            let repetitionCount: Int
            let coldCount: TimingSamples
            let warmCapped: TimingSamples
            let warmCount: TimingSamples
            let cacheLoadCount: [Int]
            let cacheAcceptedLoadCount: [Int]
            let cacheHitCountAfterWarm: [Int]
            let revisionLineIndexSamples: [Int]
            let hashFallbackSamples: [Int]
            let contentReadPermitSamples: [Int]
            let contentReadWorkerBodySamples: [Int]
            let maximumActivePerLane: [Int]
            let maximumQueuedPerLane: [Int]
            let timingsUseAdmissionHooks: Bool
            let sameStoreScopedBypassWhileBroadHeld: ProofStatus
            let separateStoreBroadLaneIsolation: ProofStatus
            let correctnessPassed: Bool
            let lanesIdle: Bool
            let readLimiterIdle: Bool
        }

        private struct TimingSamples: Codable {
            let rawMilliseconds: [Double]
            let p50Milliseconds: Double
            let p95Milliseconds: Double

            init(_ rawMilliseconds: [Double]) {
                self.rawMilliseconds = rawMilliseconds
                p50Milliseconds = Self.percentile(0.50, samples: rawMilliseconds)
                p95Milliseconds = Self.percentile(0.95, samples: rawMilliseconds)
            }

            private static func percentile(_ percentile: Double, samples: [Double]) -> Double {
                guard !samples.isEmpty else { return 0 }
                let sorted = samples.sorted()
                let index = max(0, min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1))
                return sorted[index]
            }
        }

        private func runScenario(
            topology: SearchTopology,
            k: Int,
            fileCount: Int,
            verifyCancellationRecovery: Bool
        ) async throws -> ScenarioOutcome {
            guard fileCount > 8, Self.kValues.contains(k) else {
                throw PerformanceGateError.invalidScenario(fileCount: fileCount, k: k)
            }
            let fixtures = try await makeFixtures(
                storeCount: topology == .sameStore ? 1 : k,
                fileCount: fileCount,
                label: "\(topology.rawValue)-k\(k)"
            )
            let limiterBefore = await waitForContentReadLimiterIdle()
            XCTAssertTrue(limiterBefore.isIdle)

            let coldCount = try await measure {
                try await self.runConcurrentSearches(
                    fixtures: fixtures,
                    topology: topology,
                    k: k,
                    countOnly: true
                )
            }
            let coldCountCorrect = countResultsAreCorrect(
                coldCount.value,
                expectedResultCount: k,
                fileCount: fileCount
            )
            assertCountResults(coldCount.value, expectedResultCount: k, fileCount: fileCount)

            let cacheAfterCold = await cacheSnapshots(fixtures)
            let coldCacheCorrect = cacheAfterCold.allSatisfy { snapshot in
                snapshot.entryCount == fileCount
                    && snapshot.loadCount == fileCount
                    && snapshot.acceptedLoadCount == fileCount
                    && snapshot.latestRevision == UInt64(fileCount)
                    && snapshot.activeFlightCount == 0
                    && snapshot.waiterCount == 0
            }
            for snapshot in cacheAfterCold {
                XCTAssertEqual(snapshot.entryCount, fileCount)
                XCTAssertEqual(snapshot.loadCount, fileCount, "Each file fingerprint should create one cache load")
                XCTAssertEqual(snapshot.acceptedLoadCount, fileCount, "Each file fingerprint should decode once")
                XCTAssertEqual(snapshot.latestRevision, UInt64(fileCount))
                XCTAssertEqual(snapshot.activeFlightCount, 0)
                XCTAssertEqual(snapshot.waiterCount, 0)
            }
            let limiterAfterCold = await waitForContentReadLimiterIdle()
            assertBoundedIdleReadLimiter(limiterAfterCold)
            XCTAssertEqual(limiterAfterCold.overloadCount, limiterBefore.overloadCount)

            beginCapture(label: "ce-search-warm-\(topology.rawValue)-k\(k)-n\(fileCount)")
            let warmCapped = try await measure {
                try await self.runConcurrentSearches(
                    fixtures: fixtures,
                    topology: topology,
                    k: k,
                    countOnly: false
                )
            }
            let warmCount = try await measure {
                try await self.runConcurrentSearches(
                    fixtures: fixtures,
                    topology: topology,
                    k: k,
                    countOnly: true
                )
            }
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)

            let orderingCorrect = orderedCappedResultsAreCorrect(
                warmCapped.value,
                fixtures: fixtures,
                topology: topology,
                expectedResultCount: k
            )
            let warmCountCorrect = countResultsAreCorrect(
                warmCount.value,
                expectedResultCount: k,
                fileCount: fileCount
            )
            assertOrderedCappedResults(
                warmCapped.value,
                fixtures: fixtures,
                topology: topology,
                expectedResultCount: k
            )
            assertCountResults(warmCount.value, expectedResultCount: k, fileCount: fileCount)

            let cacheAfterWarm = await cacheSnapshots(fixtures)
            let warmCacheCorrect = cacheAfterWarm.map(\.loadCount) == cacheAfterCold.map(\.loadCount)
                && cacheAfterWarm.map(\.acceptedLoadCount) == cacheAfterCold.map(\.acceptedLoadCount)
                && cacheAfterWarm.map(\.latestRevision) == cacheAfterCold.map(\.latestRevision)
                && zip(cacheAfterWarm, cacheAfterCold).allSatisfy { $0.hitCount > $1.hitCount }
                && cacheAfterWarm.allSatisfy { $0.activeFlightCount == 0 && $0.waiterCount == 0 }
            XCTAssertEqual(cacheAfterWarm.map(\.loadCount), cacheAfterCold.map(\.loadCount))
            XCTAssertEqual(cacheAfterWarm.map(\.acceptedLoadCount), cacheAfterCold.map(\.acceptedLoadCount))
            XCTAssertEqual(cacheAfterWarm.map(\.latestRevision), cacheAfterCold.map(\.latestRevision))
            XCTAssertTrue(zip(cacheAfterWarm, cacheAfterCold).allSatisfy { $0.hitCount > $1.hitCount })
            XCTAssertTrue(cacheAfterWarm.allSatisfy { $0.activeFlightCount == 0 && $0.waiterCount == 0 })

            let hashFallbackSamples = sampleCount(
                capture,
                stage: EditFlowPerf.Stage.Search.lineIndexLookup,
                dimensionSubstring: "hash-fallback"
            )
            let revisionLineIndexSamples = sampleCount(
                capture,
                stage: EditFlowPerf.Stage.Search.lineIndexLookup,
                dimensionSubstring: "scanKind=revision"
            )
            let contentReadPermitSamples = sampleCount(
                capture,
                stage: EditFlowPerf.Stage.FileSystem.contentReadWorkerPermitWait
            )
            let contentReadWorkerBodySamples = sampleCount(
                capture,
                stage: EditFlowPerf.Stage.FileSystem.contentReadWorkerBody
            )
            XCTAssertEqual(hashFallbackSamples, 0)
            XCTAssertGreaterThan(revisionLineIndexSamples, 0)
            XCTAssertEqual(contentReadPermitSamples, 0, "Warm searches must not re-enter filesystem read admission")
            XCTAssertEqual(contentReadWorkerBodySamples, 0, "Warm searches must not reread or redecode file content")

            let sameStoreScopedBypassWhileBroadHeldProved: Bool?
            let separateStoreBroadLaneIsolationProved: Bool?
            switch topology {
            case .sameStore:
                sameStoreScopedBypassWhileBroadHeldProved = try await verifyScopedBypassWhileBroadSearchHeld(
                    fixture: fixtures[0],
                    k: k
                )
                separateStoreBroadLaneIsolationProved = nil
            case .separateStores:
                sameStoreScopedBypassWhileBroadHeldProved = nil
                separateStoreBroadLaneIsolationProved = try await verifySeparateStoreBroadLaneIsolation(fixtures)
            }
            let proofCache = await cacheSnapshots(fixtures)
            let proofCacheCorrect = proofCache.map(\.loadCount) == cacheAfterWarm.map(\.loadCount)
                && proofCache.map(\.acceptedLoadCount) == cacheAfterWarm.map(\.acceptedLoadCount)
                && proofCache.allSatisfy { $0.activeFlightCount == 0 && $0.waiterCount == 0 }
            XCTAssertEqual(proofCache.map(\.loadCount), cacheAfterWarm.map(\.loadCount))
            XCTAssertEqual(proofCache.map(\.acceptedLoadCount), cacheAfterWarm.map(\.acceptedLoadCount))
            XCTAssertTrue(proofCache.allSatisfy { $0.activeFlightCount == 0 && $0.waiterCount == 0 })

            var laneSnapshots = await searchLaneSnapshots(fixtures)
            var lanesCorrect = laneSnapshots.allSatisfy(\.isIdle)
                && laneSnapshots.allSatisfy { $0.maximumActivePermitCount <= 1 }
                && laneSnapshots.allSatisfy { $0.maximumWaiterCount == 0 }
            XCTAssertTrue(laneSnapshots.allSatisfy(\.isIdle))
            XCTAssertTrue(laneSnapshots.allSatisfy { $0.maximumActivePermitCount <= 1 })
            XCTAssertTrue(laneSnapshots.allSatisfy { $0.maximumWaiterCount == 0 })

            if verifyCancellationRecovery {
                try await verifyCancellationToIdleAndSubsequentSearchRead(fixtures[0], fileCount: fileCount)
                laneSnapshots = await searchLaneSnapshots(fixtures)
                XCTAssertTrue(laneSnapshots.allSatisfy(\.isIdle))
                XCTAssertTrue(laneSnapshots.allSatisfy { $0.maximumActivePermitCount <= 1 })
                XCTAssertTrue(laneSnapshots.allSatisfy { $0.maximumWaiterCount <= 1 })
                XCTAssertGreaterThanOrEqual(laneSnapshots[0].queuedCancellationCount, 1)
                lanesCorrect = laneSnapshots.allSatisfy(\.isIdle)
                    && laneSnapshots.allSatisfy { $0.maximumActivePermitCount <= 1 }
                    && laneSnapshots.allSatisfy { $0.maximumWaiterCount <= 1 }
                    && laneSnapshots[0].queuedCancellationCount >= 1
            }

            let limiterAfterWarm = await waitForContentReadLimiterIdle()
            assertBoundedIdleReadLimiter(limiterAfterWarm)
            XCTAssertEqual(limiterAfterWarm.overloadCount, limiterBefore.overloadCount)

            let topologyProofPassed: Bool = switch topology {
            case .sameStore:
                k == 1
                    ? sameStoreScopedBypassWhileBroadHeldProved == nil
                    : sameStoreScopedBypassWhileBroadHeldProved == true
            case .separateStores:
                k == 1
                    ? separateStoreBroadLaneIsolationProved == nil
                    : separateStoreBroadLaneIsolationProved == true
            }
            let telemetryCorrect = hashFallbackSamples == 0
                && revisionLineIndexSamples > 0
                && contentReadPermitSamples == 0
                && contentReadWorkerBodySamples == 0
            let readLimiterIdle = limiterBefore.isIdle
                && boundedIdleReadLimiter(limiterAfterCold)
                && boundedIdleReadLimiter(limiterAfterWarm)
                && limiterAfterCold.overloadCount == limiterBefore.overloadCount
                && limiterAfterWarm.overloadCount == limiterBefore.overloadCount
            let correctnessPassed = coldCountCorrect
                && coldCacheCorrect
                && orderingCorrect
                && warmCountCorrect
                && warmCacheCorrect
                && proofCacheCorrect
                && telemetryCorrect
                && topologyProofPassed
            guard correctnessPassed, lanesCorrect, readLimiterIdle else {
                throw PerformanceGateError.invariantFailed(
                    topology: topology.rawValue,
                    k: k,
                    fileCount: fileCount
                )
            }

            return ScenarioOutcome(
                coldCountDurationMs: coldCount.milliseconds,
                warmCappedDurationMs: warmCapped.milliseconds,
                warmCountDurationMs: warmCount.milliseconds,
                cacheLoadCount: cacheAfterWarm.reduce(0) { $0 + $1.loadCount },
                cacheAcceptedLoadCount: cacheAfterWarm.reduce(0) { $0 + $1.acceptedLoadCount },
                cacheHitCountAfterWarm: cacheAfterWarm.reduce(0) { $0 + $1.hitCount },
                revisionLineIndexSamples: revisionLineIndexSamples,
                hashFallbackSamples: hashFallbackSamples,
                contentReadPermitSamples: contentReadPermitSamples,
                contentReadWorkerBodySamples: contentReadWorkerBodySamples,
                maximumActivePerLane: laneSnapshots.map(\.maximumActivePermitCount).max() ?? 0,
                maximumQueuedPerLane: laneSnapshots.map(\.maximumWaiterCount).max() ?? 0,
                sameStoreScopedBypassWhileBroadHeldProved: sameStoreScopedBypassWhileBroadHeldProved,
                separateStoreBroadLaneIsolationProved: separateStoreBroadLaneIsolationProved,
                correctnessPassed: correctnessPassed,
                lanesIdle: lanesCorrect,
                readLimiterIdle: readLimiterIdle
            )
        }

        private func makeFixtures(storeCount: Int, fileCount: Int, label: String) async throws -> [Fixture] {
            var fixtures: [Fixture] = []
            fixtures.reserveCapacity(storeCount)
            for storeIndex in 0 ..< storeCount {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RepoPromptTests", isDirectory: true)
                    .appendingPathComponent("SearchGate-\(label)-s\(storeIndex)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                temporaryRoots.append(root)

                var orderedFilePaths: [String] = []
                var orderedRelativePaths: [String] = []
                for fileIndex in (0 ..< fileCount).reversed() {
                    let relativePath = String(format: "Sources/Group-%02d/File-%03d.swift", fileIndex % 4, fileIndex)
                    let file = root.appendingPathComponent(relativePath)
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let content = "let sharedNeedle = \(fileIndex)\n// sharedNeedle store \(storeIndex)\n"
                    try content.write(to: file, atomically: true, encoding: .utf8)
                    orderedFilePaths.append(file.path)
                    orderedRelativePaths.append(relativePath)
                }
                let ordered = zip(orderedFilePaths, orderedRelativePaths).sorted { $0.0 < $1.0 }
                let store = WorkspaceFileContextStore()
                let rootRecord = try await store.loadRoot(path: root.path)
                fixtures.append(Fixture(
                    store: store,
                    rootID: rootRecord.id,
                    orderedFilePaths: ordered.map(\.0),
                    orderedRelativePaths: ordered.map(\.1)
                ))
            }
            return fixtures
        }

        private func runConcurrentSearches(
            fixtures: [Fixture],
            topology: SearchTopology,
            k: Int,
            countOnly: Bool
        ) async throws -> [SearchResults] {
            let tasks: [Task<SearchResults, Error>] = (0 ..< k).map { requestIndex in
                let fixture = topology == .sameStore ? fixtures[0] : fixtures[requestIndex]
                return Task {
                    try await self.search(
                        fixture: fixture,
                        countOnly: countOnly,
                        scoped: topology == .sameStore && requestIndex > 0
                    )
                }
            }
            return try await collect(tasks)
        }

        private func verifyScopedBypassWhileBroadSearchHeld(
            fixture: Fixture,
            k: Int
        ) async throws -> Bool? {
            guard k > 1 else { return nil }

            let gate = SearchPermitGate()
            await fixture.store.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            let broadTask = Task {
                try await self.search(fixture: fixture, countOnly: false, scoped: false)
            }
            var scopedTasks: [Task<SearchResults, Error>] = []
            do {
                guard await gate.waitUntilStartedCount(1) else {
                    throw PerformanceGateError.sameStoreBroadSearchDidNotStart
                }
                scopedTasks = (1 ..< k).map { _ in
                    Task {
                        try await self.search(fixture: fixture, countOnly: false, scoped: true)
                    }
                }
                let scopedResults = try await collect(scopedTasks)
                let heldSnapshot = await fixture.store.searchLaneSnapshotForTesting()
                let scopedBypassProved = heldSnapshot.activePermitCount == 1
                    && heldSnapshot.waiterCount == 0
                await gate.release()
                let broadResult = try await broadTask.value
                await fixture.store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                let results = [broadResult] + scopedResults
                assertOrderedCappedResults(
                    results,
                    fixtures: [fixture],
                    topology: .sameStore,
                    expectedResultCount: k
                )
                return scopedBypassProved
                    && orderedCappedResultsAreCorrect(
                        results,
                        fixtures: [fixture],
                        topology: .sameStore,
                        expectedResultCount: k
                    )
            } catch {
                broadTask.cancel()
                scopedTasks.forEach { $0.cancel() }
                await gate.release()
                await drain([broadTask] + scopedTasks)
                await fixture.store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                throw error
            }
        }

        private func verifySeparateStoreBroadLaneIsolation(
            _ fixtures: [Fixture]
        ) async throws -> Bool? {
            guard fixtures.count > 1 else { return nil }

            let barrier = KWayIsolationBarrier(expectedCount: fixtures.count)
            for fixture in fixtures {
                await fixture.store.setSearchLanePermitAcquiredHandlerForTesting {
                    await barrier.arriveAndWaitForRelease()
                }
            }
            let tasks = fixtures.map { fixture in
                Task {
                    try await self.search(fixture: fixture, countOnly: false, scoped: false)
                }
            }
            let allLanesAcquired = await barrier.waitUntilAllArrived()
            await barrier.release()
            do {
                let results = try await collect(tasks)
                await clearSearchLaneHooks(fixtures)
                assertOrderedCappedResults(
                    results,
                    fixtures: fixtures,
                    topology: .separateStores,
                    expectedResultCount: fixtures.count
                )
                return allLanesAcquired
                    && orderedCappedResultsAreCorrect(
                        results,
                        fixtures: fixtures,
                        topology: .separateStores,
                        expectedResultCount: fixtures.count
                    )
            } catch {
                tasks.forEach { $0.cancel() }
                await barrier.release()
                await drain(tasks)
                await clearSearchLaneHooks(fixtures)
                throw error
            }
        }

        private func verifyCancellationToIdleAndSubsequentSearchRead(
            _ fixture: Fixture,
            fileCount: Int
        ) async throws {
            let gate = SearchPermitGate()
            await fixture.store.setSearchLanePermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            let first = Task { try await self.search(fixture: fixture, countOnly: true, scoped: false) }
            let firstStarted = await gate.waitUntilStartedCount(1)
            XCTAssertTrue(firstStarted)
            let cancelled = Task { try await self.search(fixture: fixture, countOnly: true, scoped: false) }
            let cancellationQueued = await waitForAdmissionWaiterCount(1, store: fixture.store)
            XCTAssertTrue(cancellationQueued)
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                XCTFail("Expected queued broad search cancellation")
            } catch is CancellationError {
                // Expected.
            }
            let cancellationRemoved = await waitForAdmissionWaiterCount(0, store: fixture.store)
            XCTAssertTrue(cancellationRemoved)

            let subsequent = Task { try await self.search(fixture: fixture, countOnly: true, scoped: false) }
            let subsequentQueued = await waitForAdmissionWaiterCount(1, store: fixture.store)
            XCTAssertTrue(subsequentQueued)
            await gate.release()
            do {
                try await assertCountResults([first.value], expectedResultCount: 1, fileCount: fileCount)
                try await assertCountResults([subsequent.value], expectedResultCount: 1, fileCount: fileCount)
            } catch {
                first.cancel()
                subsequent.cancel()
                await gate.release()
                await drain([first, subsequent])
                await fixture.store.setSearchLanePermitAcquiredHandlerForTesting(nil)
                throw error
            }
            await fixture.store.setSearchLanePermitAcquiredHandlerForTesting(nil)

            let content = try await fixture.store.readContent(
                rootID: fixture.rootID,
                relativePath: fixture.orderedRelativePaths[0],
                workloadClass: .interactiveRead
            )
            XCTAssertTrue(content?.contains("sharedNeedle") == true)
            let finalLane = await fixture.store.searchLaneSnapshotForTesting()
            let finalCache = await fixture.store.searchDecodedContentCacheSnapshotForTesting()
            XCTAssertTrue(finalLane.isIdle)
            XCTAssertEqual(finalCache.activeFlightCount, 0)
            XCTAssertEqual(finalCache.waiterCount, 0)
        }

        private func search(fixture: Fixture, countOnly: Bool, scoped: Bool) async throws -> SearchResults {
            try await StoreBackedWorkspaceSearch.search(
                pattern: "sharedNeedle",
                mode: .content,
                isRegex: false,
                caseInsensitive: false,
                maxPaths: Self.cappedMatchCount,
                maxMatches: Self.cappedMatchCount,
                paths: scoped ? fixture.orderedFilePaths : nil,
                countOnly: countOnly,
                rootScope: .visibleWorkspace,
                store: fixture.store,
                workspaceManager: nil
            )
        }

        private func collect(_ tasks: [Task<SearchResults, Error>]) async throws -> [SearchResults] {
            do {
                var results: [SearchResults] = []
                results.reserveCapacity(tasks.count)
                for task in tasks {
                    try await results.append(task.value)
                }
                return results
            } catch {
                tasks.forEach { $0.cancel() }
                await drain(tasks)
                throw error
            }
        }

        private func drain(_ tasks: [Task<SearchResults, Error>]) async {
            for task in tasks {
                _ = try? await task.value
            }
        }

        private func orderedCappedResultsAreCorrect(
            _ results: [SearchResults],
            fixtures: [Fixture],
            topology: SearchTopology,
            expectedResultCount: Int
        ) -> Bool {
            guard results.count == expectedResultCount else { return false }
            return results.enumerated().allSatisfy { index, result in
                let fixture = topology == .sameStore ? fixtures[0] : fixtures[index]
                let expectedPaths = [0, 0, 1, 1, 2].map { fixture.orderedFilePaths[$0] }
                return result.matches?.map(\.filePath) == expectedPaths
                    && result.matches?.map(\.lineNumber) == [0, 1, 0, 1, 0]
                    && result.matches?.count == Self.cappedMatchCount
            }
        }

        private func countResultsAreCorrect(
            _ results: [SearchResults],
            expectedResultCount: Int,
            fileCount: Int
        ) -> Bool {
            results.count == expectedResultCount && results.allSatisfy { result in
                result.totalCount == fileCount * Self.matchesPerFile
                    && result.contentFileCount == fileCount
                    && result.searchedFileCount == fileCount
                    && (result.matches ?? []).isEmpty
            }
        }

        private func assertOrderedCappedResults(
            _ results: [SearchResults],
            fixtures: [Fixture],
            topology: SearchTopology,
            expectedResultCount: Int
        ) {
            XCTAssertEqual(results.count, expectedResultCount)
            for (index, result) in results.enumerated() {
                let fixture = topology == .sameStore ? fixtures[0] : fixtures[index]
                let expectedPaths = [0, 0, 1, 1, 2].map { fixture.orderedFilePaths[$0] }
                XCTAssertEqual(result.matches?.map(\.filePath), expectedPaths)
                XCTAssertEqual(result.matches?.map(\.lineNumber), [0, 1, 0, 1, 0])
                XCTAssertEqual(result.matches?.count, Self.cappedMatchCount)
            }
        }

        private func assertCountResults(
            _ results: [SearchResults],
            expectedResultCount: Int,
            fileCount: Int
        ) {
            XCTAssertEqual(results.count, expectedResultCount)
            for result in results {
                XCTAssertEqual(result.totalCount, fileCount * Self.matchesPerFile)
                XCTAssertEqual(result.contentFileCount, fileCount)
                XCTAssertEqual(result.searchedFileCount, fileCount)
                XCTAssertTrue((result.matches ?? []).isEmpty)
            }
        }

        private func clearSearchLaneHooks(_ fixtures: [Fixture]) async {
            for fixture in fixtures {
                await fixture.store.setSearchLanePermitAcquiredHandlerForTesting(nil)
            }
        }

        private func cacheSnapshots(
            _ fixtures: [Fixture]
        ) async -> [WorkspaceSearchDecodedContentCache.Snapshot] {
            var snapshots: [WorkspaceSearchDecodedContentCache.Snapshot] = []
            snapshots.reserveCapacity(fixtures.count)
            for fixture in fixtures {
                let snapshot = await fixture.store.searchDecodedContentCacheSnapshotForTesting()
                snapshots.append(snapshot)
            }
            return snapshots
        }

        private func searchLaneSnapshots(
            _ fixtures: [Fixture]
        ) async -> [StoreBackedWorkspaceSearchLane.Snapshot] {
            var snapshots: [StoreBackedWorkspaceSearchLane.Snapshot] = []
            snapshots.reserveCapacity(fixtures.count)
            for fixture in fixtures {
                let snapshot = await fixture.store.searchLaneSnapshotForTesting()
                snapshots.append(snapshot)
            }
            return snapshots
        }

        private func waitForAdmissionWaiterCount(
            _ expectedCount: Int,
            store: WorkspaceFileContextStore,
            timeout: Duration = .seconds(2)
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await store.searchLaneSnapshotForTesting().waiterCount == expectedCount {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await store.searchLaneSnapshotForTesting().waiterCount == expectedCount
        }

        private func waitForContentReadLimiterIdle(
            timeout: Duration = .seconds(5)
        ) async -> ContentReadAsyncLimiter.Snapshot {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
                if snapshot.isIdle { return snapshot }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        }

        private func boundedIdleReadLimiter(_ snapshot: ContentReadAsyncLimiter.Snapshot) -> Bool {
            snapshot.isIdle
                && snapshot.activePermitCount <= snapshot.capacity
                && snapshot.queuedWaiterCount <= snapshot.maxQueuedWaiterCount
                && snapshot.ownerLaneCount == 0
        }

        private func assertBoundedIdleReadLimiter(_ snapshot: ContentReadAsyncLimiter.Snapshot) {
            XCTAssertTrue(boundedIdleReadLimiter(snapshot))
        }

        private func measure<Value>(
            _ operation: () async throws -> Value
        ) async rethrows -> Measurement<Value> {
            let clock = ContinuousClock()
            let start = clock.now
            let value = try await operation()
            let duration = start.duration(to: clock.now)
            return Measurement(value: value, milliseconds: Self.milliseconds(duration))
        }

        private static func proofStatus(_ values: [Bool?]) -> ProofStatus {
            let applicableValues = values.compactMap(\.self)
            guard !applicableValues.isEmpty else { return .notApplicable }
            return applicableValues.allSatisfy(\.self) ? .proved : .failed
        }

        private static func milliseconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds) * 1000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }

        private func beginCapture(label: String) {
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: 200_000) {
            case .started:
                return
            case .busy:
                XCTFail("A prior search performance capture remained active")
                _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                _ = EditFlowPerf.beginDebugCapture(label: label, maxSamples: 200_000)
            }
        }

        private func sampleCount(
            _ capture: EditFlowPerf.DebugCaptureSnapshot,
            stage: StaticString,
            dimensionSubstring: String? = nil
        ) -> Int {
            capture.stages
                .filter { $0.stageName == String(describing: stage) }
                .filter { row in
                    guard let dimensionSubstring else { return true }
                    return row.sanitizedDimensions.contains(dimensionSubstring)
                }
                .reduce(0) { $0 + $1.sampleCount }
        }

        private static func metricOutputURL() -> URL? {
            if let rawValue = ProcessInfo.processInfo.environment[metricOutputEnvironmentKey],
               !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if rawValue == "1" {
                    return URL(fileURLWithPath: "/tmp/repoprompt-ce-search-performance-matrix.json")
                }
                return URL(fileURLWithPath: rawValue).standardizedFileURL
            }
            guard let temporaryDirectory = ProcessInfo.processInfo.environment["TMPDIR"] else { return nil }
            let markerURL = URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
                .appendingPathComponent(metricOutputMarkerFileName)
            guard let markerValue = try? String(contentsOf: markerURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !markerValue.isEmpty
            else { return nil }
            return URL(fileURLWithPath: markerValue).standardizedFileURL
        }

        private func emitMetrics(_ report: SearchMetricReport, to outputURL: URL) throws {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        }
    }

    private enum PerformanceGateError: Error {
        case invalidScenario(fileCount: Int, k: Int)
        case invariantFailed(topology: String, k: Int, fileCount: Int)
        case sameStoreBroadSearchDidNotStart
    }

    private actor SearchPermitGate {
        private var startedCount = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            startedCount += 1
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStartedCount(
            _ expectedCount: Int,
            timeout: Duration = .seconds(2)
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while startedCount < expectedCount, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return startedCount >= expectedCount
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private actor KWayIsolationBarrier {
        private let expectedCount: Int
        private var arrivedCount = 0
        private var released = false

        init(expectedCount: Int) {
            self.expectedCount = expectedCount
        }

        func arriveAndWaitForRelease() async {
            arrivedCount += 1
            while !released {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        func waitUntilAllArrived(timeout: Duration = .seconds(2)) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while arrivedCount < expectedCount, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return arrivedCount == expectedCount
        }

        func release() {
            released = true
        }
    }
#endif
