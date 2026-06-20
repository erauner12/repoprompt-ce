#if DEBUG
    import Darwin
    import Foundation
    @testable import RepoPrompt

    enum WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration {
        static let fileURL = URL(fileURLWithPath: "/tmp/RepoPromptCE-file-search-index-run-config.json")

        static func values() -> [String: String] {
            guard let data = try? Data(contentsOf: fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return [:] }
            return object
        }
    }

    struct WorkspaceFileSearchIndexBenchmarkFixture {
        static let moduleCount = 64
        static let layerCount = 4
        static let filesPerLayer = 64
        static let seedFileCount = moduleCount * layerCount * filesPerLayer
        static let folderCount = 1 + moduleCount + moduleCount + moduleCount * layerCount
        static let firstScopedNeedleRelativePath = "Module-00/Sources/Layer-00/FirstScopedNeedle.swift"

        let containerURL: URL
        let visibleRootURL: URL
        let worktreeRootURL: URL

        var firstScopedNeedleURL: URL {
            worktreeRootURL.appendingPathComponent(Self.firstScopedNeedleRelativePath)
        }

        static func make() throws -> Self {
            let containerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPrompt-FileSearchIndexBenchmark-\(UUID().uuidString)", isDirectory: true)
            let visibleRootURL = containerURL.appendingPathComponent("VisibleRoot", isDirectory: true)
            let worktreeRootURL = containerURL.appendingPathComponent("SessionWorktree", isDirectory: true)
            try FileManager.default.createDirectory(at: visibleRootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: worktreeRootURL, withIntermediateDirectories: true)
            try fixtureContents.write(
                to: visibleRootURL.appendingPathComponent("VisibleNonMatching.swift"),
                options: []
            )

            for moduleIndex in 0 ..< moduleCount {
                for layerIndex in 0 ..< layerCount {
                    let layerURL = worktreeRootURL
                        .appendingPathComponent(String(format: "Module-%02d", moduleIndex), isDirectory: true)
                        .appendingPathComponent("Sources", isDirectory: true)
                        .appendingPathComponent(String(format: "Layer-%02d", layerIndex), isDirectory: true)
                    try FileManager.default.createDirectory(at: layerURL, withIntermediateDirectories: true)
                    for fileIndex in 0 ..< filesPerLayer {
                        let fileName = if moduleIndex == 0, layerIndex == 0, fileIndex == 0 {
                            "FirstScopedNeedle.swift"
                        } else {
                            String(format: "File-%02d.swift", fileIndex)
                        }
                        try fixtureContents.write(to: layerURL.appendingPathComponent(fileName), options: [])
                    }
                }
            }

            return Self(
                containerURL: containerURL,
                visibleRootURL: visibleRootURL,
                worktreeRootURL: worktreeRootURL
            )
        }

        func writeMutationFile(relativePath: String) throws -> URL {
            let url = worktreeRootURL.appendingPathComponent(relativePath)
            try Self.fixtureContents.write(to: url, options: [])
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: containerURL)
        }

        private static let fixtureContents = Data(
            "// RepoPrompt CE file-search benchmark fixture\nlet benchmarkValue = 1234567890\n".utf8
        )
    }

    struct WorkspaceFileSearchIndexBenchmarkCounters: Equatable {
        typealias FallbackReason = WorkspaceFileContextStore.RootCatalogShardFallbackReason

        let rootID: UUID?
        let lifetimeID: UUID?
        let topologyGeneration: UInt64?
        let crawl: Int
        let appliedGeneration: Int
        let shardBuild: Int
        let patch: Int
        let authoritative: Int
        let pathIndexBuild: Int
        let overlayPathIndexBuild: Int
        let fallback: Int
        let fallbackReasonDeltas: [FallbackReason: Int]
        let catalogRebuild: Int
        let catalogInvalidation: Int

        var fallbackReasonDeltaSum: Int {
            fallbackReasonDeltas.values.reduce(0, +)
        }

        var fallbackReasonDeltasAreNonnegative: Bool {
            fallbackReasonDeltas.values.allSatisfy { $0 >= 0 }
        }

        func fallbackDiagnosticDescription() -> String {
            let reasons = FallbackReason.allCases.compactMap { reason -> String? in
                guard let count = fallbackReasonDeltas[reason], count != 0 else { return nil }
                return "\(reason.rawValue)=\(count)"
            }.joined(separator: ", ")
            let renderedTopologyGeneration = topologyGeneration.map(String.init) ?? "none"
            return "rootID=\(rootID?.uuidString ?? "none"), lifetimeID=\(lifetimeID?.uuidString ?? "none"), "
                + "topology generation=\(renderedTopologyGeneration); fallback Δ=\(fallback); reasons=[\(reasons)]; "
                + "crawl=\(crawl) shard=\(shardBuild) patch=\(patch) authoritative=\(authoritative) "
                + "full=\(pathIndexBuild) overlay=\(overlayPathIndexBuild)"
        }
    }

    struct WorkspaceFileSearchIndexBenchmarkCounterMark {
        typealias FallbackReason = WorkspaceFileContextStore.RootCatalogShardFallbackReason

        let rootID: UUID?
        let lifetimeID: UUID?
        let topologyGeneration: UInt64?
        let crawl: Int
        let appliedGeneration: UInt64
        let shardBuild: Int
        let patch: Int
        let authoritative: Int
        let pathIndexBuild: Int
        let overlayPathIndexBuild: Int
        let fallback: Int
        let fallbackReasonCounts: [FallbackReason: Int]
        let catalogRebuild: Int
        let catalogInvalidation: Int

        static func capture(store: WorkspaceFileContextStore, rootID: UUID? = nil) async -> Self {
            let rootSnapshots = await store.readSearchRootDiagnosticsSnapshot()
            let work = await store.storeWorkDiagnosticsSnapshot()
            let rootSnapshot = rootID.flatMap { id in rootSnapshots.first { $0.rootID == id } }
            let shardSnapshot = rootID.flatMap { id in
                work.rootCatalogShards.roots.first { $0.rootID == id }
            }
            return Self(
                rootID: shardSnapshot?.rootID ?? rootID,
                lifetimeID: shardSnapshot?.lifetimeID,
                topologyGeneration: shardSnapshot?.publishedTopologyGeneration,
                crawl: rootSnapshot?.crawlCount ?? 0,
                appliedGeneration: rootSnapshot?.producedAppliedIndexGeneration ?? 0,
                shardBuild: shardSnapshot?.buildCount ?? 0,
                patch: shardSnapshot?.patchCount ?? 0,
                authoritative: shardSnapshot?.authoritativeRebuildCount ?? 0,
                pathIndexBuild: shardSnapshot?.pathIndexBuildCount ?? 0,
                overlayPathIndexBuild: shardSnapshot?.overlayPathIndexBuildCount ?? 0,
                fallback: shardSnapshot?.fallbackCount ?? 0,
                fallbackReasonCounts: shardSnapshot?.fallbackReasonCounts ?? [:],
                catalogRebuild: work.catalogRebuild.rebuildCount,
                catalogInvalidation: work.invalidations.count
            )
        }

        func delta(from before: Self) -> WorkspaceFileSearchIndexBenchmarkCounters {
            let fallbackReasonDeltas = Dictionary(uniqueKeysWithValues: FallbackReason.allCases.map { reason in
                (reason, (fallbackReasonCounts[reason] ?? 0) - (before.fallbackReasonCounts[reason] ?? 0))
            })
            return WorkspaceFileSearchIndexBenchmarkCounters(
                rootID: rootID ?? before.rootID,
                lifetimeID: lifetimeID ?? before.lifetimeID,
                topologyGeneration: topologyGeneration ?? before.topologyGeneration,
                crawl: crawl - before.crawl,
                appliedGeneration: Int(appliedGeneration) - Int(before.appliedGeneration),
                shardBuild: shardBuild - before.shardBuild,
                patch: patch - before.patch,
                authoritative: authoritative - before.authoritative,
                pathIndexBuild: pathIndexBuild - before.pathIndexBuild,
                overlayPathIndexBuild: overlayPathIndexBuild - before.overlayPathIndexBuild,
                fallback: fallback - before.fallback,
                fallbackReasonDeltas: fallbackReasonDeltas,
                catalogRebuild: catalogRebuild - before.catalogRebuild,
                catalogInvalidation: catalogInvalidation - before.catalogInvalidation
            )
        }
    }

    struct WorkspaceFileSearchIndexBenchmarkSample {
        let ordinal: Int
        let phase: String
        let totalWallMilliseconds: Double
        let preSearchMilliseconds: Double
        let searchMilliseconds: Double
        let counters: WorkspaceFileSearchIndexBenchmarkCounters
    }

    struct WorkspaceFileSearchIndexBenchmarkAggregate {
        let scenario: String
        let warmup: WorkspaceFileSearchIndexBenchmarkSample
        let measured: [WorkspaceFileSearchIndexBenchmarkSample]
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let stabilityRatio: Double
        let isStable: Bool

        init(
            scenario: String,
            warmup: WorkspaceFileSearchIndexBenchmarkSample,
            measured: [WorkspaceFileSearchIndexBenchmarkSample]
        ) {
            precondition(measured.count == 5)
            self.scenario = scenario
            self.warmup = warmup
            self.measured = measured
            let values = measured.map(\.totalWallMilliseconds)
            medianMilliseconds = Self.median(values)
            p95Milliseconds = Self.nearestRankP95(values)
            stabilityRatio = medianMilliseconds > 0
                ? (p95Milliseconds - medianMilliseconds) / medianMilliseconds
                : .infinity
            isStable = stabilityRatio <= 0.20
        }

        var rawMilliseconds: [Double] {
            measured.map(\.totalWallMilliseconds)
        }

        private static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let midpoint = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[midpoint - 1] + sorted[midpoint]) / 2
            }
            return sorted[midpoint]
        }

        private static func nearestRankP95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
            return sorted[min(sorted.count - 1, rank - 1)]
        }
    }

    struct WorkspaceFileSearchIndexBenchmarkEnvironment {
        let runLabel: String
        let attribution: String
        let commit: String
        let recordedAt: String
        let macOS: String
        let hardware: String
        let logicalCores: Int
        let memoryBytes: UInt64
        let swiftVersion: String
        let buildConfiguration: String
        let conductorState: String

        static func capture() -> Self {
            let environment = ProcessInfo.processInfo.environment
            let configuration = WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration.values()
            return Self(
                runLabel: environment["RP_CE_FILE_SEARCH_INDEX_RUN_LABEL"] ?? configuration["runLabel"] ?? "manual",
                attribution: environment["RP_CE_FILE_SEARCH_INDEX_ATTRIBUTION"] ?? configuration["attribution"] ?? "unspecified",
                commit: environment["RP_CE_FILE_SEARCH_INDEX_COMMIT"] ?? configuration["commit"] ?? "unspecified",
                recordedAt: ISO8601DateFormatter().string(from: Date()),
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                hardware: sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "unknown",
                logicalCores: ProcessInfo.processInfo.activeProcessorCount,
                memoryBytes: ProcessInfo.processInfo.physicalMemory,
                swiftVersion: environment["RP_CE_FILE_SEARCH_INDEX_SWIFT_VERSION"] ?? configuration["swiftVersion"] ?? "unspecified",
                buildConfiguration: "DEBUG SwiftPM",
                conductorState: environment["RP_CE_FILE_SEARCH_INDEX_CONDUCTOR_STATE"] ?? configuration["conductorState"] ?? "coordinated daemon"
            )
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return String(cString: value)
        }
    }

    struct WorkspaceFileSearchIndexBenchmarkRun {
        let environment: WorkspaceFileSearchIndexBenchmarkEnvironment
        let coldWorktree: WorkspaceFileSearchIndexBenchmarkAggregate
        let incrementalRebuild: WorkspaceFileSearchIndexBenchmarkAggregate

        static var reportURLFromEnvironment: URL? {
            let configuration = WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration.values()
            let path = ProcessInfo.processInfo.environment["RP_CE_FILE_SEARCH_INDEX_REPORT_PATH"]
                ?? configuration["reportPath"]
            guard let path, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }

        func consoleReport() throws -> String {
            let json = try jsonString()
            return [
                "REPOPROMPT_CE_FILE_SEARCH_INDEX_BENCHMARK_BEGIN",
                markdownBlock(),
                "REPOPROMPT_CE_FILE_SEARCH_INDEX_BENCHMARK_JSON=\(json)",
                "REPOPROMPT_CE_FILE_SEARCH_INDEX_BENCHMARK_END"
            ].joined(separator: "\n")
        }

        func appendMarkdown(to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n\n" + markdownBlock() + "\n").utf8))
            try handle.synchronize()
        }

        private func markdownBlock() -> String {
            [
                "## Run `\(environment.runLabel)`",
                "",
                "Recorded: \(environment.recordedAt)  ",
                "Commit: `\(environment.commit)`  ",
                "Attribution: \(environment.attribution)",
                "",
                "| Environment | macOS | Hardware/CPU | Logical cores | Memory GiB | Swift | Build configuration | Conductor state |",
                "| --- | --- | --- | ---: | ---: | --- | --- | --- |",
                "| env-001 | \(environment.macOS) | \(environment.hardware) | \(environment.logicalCores) | \(formatGiB(environment.memoryBytes)) | \(environment.swiftVersion) | \(environment.buildConfiguration) | \(environment.conductorState) |",
                "",
                "| Scenario | Raw measured samples ms | Median ms | Nearest-rank p95 ms | Stability |",
                "| --- | --- | ---: | ---: | --- |",
                aggregateRow(coldWorktree),
                aggregateRow(incrementalRebuild),
                "",
                "| Scenario | Crawl Δ | Applied generation Δ | Shard build Δ | Patch Δ | Authoritative Δ | Full path-index build Δ | Overlay build Δ | Fallback Δ | Catalog rebuild Δ | Catalog invalidation Δ |",
                "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
                counterRow(scenario: coldWorktree.scenario, counters: coldWorktree.measured.map(\.counters)),
                counterRow(scenario: incrementalRebuild.scenario, counters: incrementalRebuild.measured.map(\.counters)),
                "",
                "| Scenario | Phase | Sample | Total ms | Materialize/publish ms | Ready search ms |",
                "| --- | --- | ---: | ---: | ---: | ---: |",
                sampleRows(coldWorktree).joined(separator: "\n"),
                sampleRows(incrementalRebuild).joined(separator: "\n"),
                "",
                "<details><summary>Machine-readable paired result</summary>",
                "",
                "```json",
                (try? jsonString()) ?? "{}",
                "```",
                "</details>"
            ].joined(separator: "\n")
        }

        private func jsonString() throws -> String {
            let payload: [String: Any] = [
                "runLabel": environment.runLabel,
                "attribution": environment.attribution,
                "commit": environment.commit,
                "recordedAt": environment.recordedAt,
                "environment": [
                    "macOS": environment.macOS,
                    "hardware": environment.hardware,
                    "logicalCores": environment.logicalCores,
                    "memoryBytes": environment.memoryBytes,
                    "swiftVersion": environment.swiftVersion,
                    "buildConfiguration": environment.buildConfiguration,
                    "conductorState": environment.conductorState
                ],
                "scenarios": [aggregateDictionary(coldWorktree), aggregateDictionary(incrementalRebuild)],
                "correctnessStatus": "passed"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        private func aggregateDictionary(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [String: Any] {
            [
                "scenario": aggregate.scenario,
                "warmupSampleCount": 1,
                "measuredSampleCount": aggregate.measured.count,
                "rawMeasuredMilliseconds": aggregate.rawMilliseconds,
                "medianMilliseconds": aggregate.medianMilliseconds,
                "nearestRankP95Milliseconds": aggregate.p95Milliseconds,
                "stabilityRatio": aggregate.stabilityRatio,
                "stable": aggregate.isStable,
                "warmup": sampleDictionary(aggregate.warmup),
                "measured": aggregate.measured.map(sampleDictionary)
            ]
        }

        private func sampleDictionary(_ sample: WorkspaceFileSearchIndexBenchmarkSample) -> [String: Any] {
            [
                "ordinal": sample.ordinal,
                "phase": sample.phase,
                "totalWallMilliseconds": sample.totalWallMilliseconds,
                "materializeOrPublishMilliseconds": sample.preSearchMilliseconds,
                "readySearchMilliseconds": sample.searchMilliseconds,
                "counters": counterDictionary(sample.counters)
            ]
        }

        private func counterDictionary(_ counters: WorkspaceFileSearchIndexBenchmarkCounters) -> [String: Any] {
            [
                "crawlDelta": counters.crawl,
                "appliedGenerationDelta": counters.appliedGeneration,
                "shardBuildDelta": counters.shardBuild,
                "patchDelta": counters.patch,
                "authoritativeDelta": counters.authoritative,
                "fullPathIndexBuildDelta": counters.pathIndexBuild,
                "overlayPathIndexBuildDelta": counters.overlayPathIndexBuild,
                "fallbackDelta": counters.fallback,
                "catalogRebuildDelta": counters.catalogRebuild,
                "catalogInvalidationDelta": counters.catalogInvalidation
            ]
        }

        private func aggregateRow(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> String {
            let stability = aggregate.isStable ? "stable" : "unstable"
            return "| \(aggregate.scenario) | \(formatValues(aggregate.rawMilliseconds)) | \(formatMS(aggregate.medianMilliseconds)) | \(formatMS(aggregate.p95Milliseconds)) | \(stability) (\(formatPercent(aggregate.stabilityRatio))) |"
        }

        private func counterRow(
            scenario: String,
            counters: [WorkspaceFileSearchIndexBenchmarkCounters]
        ) -> String {
            "| \(scenario) | \(counterValues(counters, \.crawl)) | \(counterValues(counters, \.appliedGeneration)) | \(counterValues(counters, \.shardBuild)) | \(counterValues(counters, \.patch)) | \(counterValues(counters, \.authoritative)) | \(counterValues(counters, \.pathIndexBuild)) | \(counterValues(counters, \.overlayPathIndexBuild)) | \(counterValues(counters, \.fallback)) | \(counterValues(counters, \.catalogRebuild)) | \(counterValues(counters, \.catalogInvalidation)) |"
        }

        private func counterValues(
            _ counters: [WorkspaceFileSearchIndexBenchmarkCounters],
            _ keyPath: KeyPath<WorkspaceFileSearchIndexBenchmarkCounters, Int>
        ) -> String {
            counters.map { String($0[keyPath: keyPath]) }.joined(separator: "/")
        }

        private func sampleRows(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [String] {
            ([aggregate.warmup] + aggregate.measured).map { sample in
                "| \(aggregate.scenario) | \(sample.phase) | \(sample.ordinal) | \(formatMS(sample.totalWallMilliseconds)) | \(formatMS(sample.preSearchMilliseconds)) | \(formatMS(sample.searchMilliseconds)) |"
            }
        }

        private func formatValues(_ values: [Double]) -> String {
            values.map(formatMS).joined(separator: ", ")
        }

        private func formatMS(_ value: Double) -> String {
            String(format: "%.3f", value)
        }

        private func formatPercent(_ ratio: Double) -> String {
            String(format: "%.1f%%", ratio * 100)
        }

        private func formatGiB(_ bytes: UInt64) -> String {
            String(format: "%.1f", Double(bytes) / 1_073_741_824)
        }
    }

    func workspaceFileSearchIndexElapsedMilliseconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
#endif
