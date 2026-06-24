import Foundation

actor WorkspaceCodemapSelectionGraph {
    private let rootEpoch: WorkspaceCodemapRootEpoch
    private let policy: WorkspaceCodemapSelectionGraphRuntimePolicy
    private let admission: CodeMapSelectionGraphAdmission
    private let diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics

    private var observedKey: WorkspaceCodemapSelectionGraphRuntimeKey?
    private var observationSerial: UInt64 = 0
    private var nextOperationID: UInt64 = 0
    private var latestOperationID: UInt64?
    private var publishedShard: ImmutableShard?
    private var activeOperations: [UInt64: ActiveOperation] = [:]
    private var activeRebuildCount = 0
    private var reservedInputBindingCount = 0
    private var lastUnavailableReason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason?
    private var revokedReason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason?
    private var hasCurrentnessConflict = false

    private var publishedCount: UInt64 = 0
    private var emptyPublishedCount: UInt64 = 0
    private var actorBusyCount: UInt64 = 0
    private var processBusyCount: UInt64 = 0
    private var cancelledCount: UInt64 = 0
    private var budgetRejectedCount: UInt64 = 0
    private var invalidSnapshotCount: UInt64 = 0
    private var supersededPublicationCount: UInt64 = 0
    private var materializedQueryResultCount: UInt64 = 0

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        policy: WorkspaceCodemapSelectionGraphRuntimePolicy = .initial,
        admission: CodeMapSelectionGraphAdmission = .processWide,
        diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics = .none
    ) {
        self.rootEpoch = rootEpoch
        self.policy = policy
        self.admission = admission
        self.diagnostics = diagnostics
    }

    func waitForProcessAdmissionAvailability(bindingCount: Int) async {
        await admission.waitForAvailability(bindingCount: bindingCount)
    }

    func rebuild(
        from snapshot: WorkspaceCodemapLiveGraphSnapshot
    ) async -> WorkspaceCodemapSelectionGraphRuntimeRebuildDisposition {
        let key = WorkspaceCodemapSelectionGraphRuntimeKey(snapshot: snapshot)
        guard !Task.isCancelled else { return .cancelled(key) }
        guard snapshot.rootEpoch == rootEpoch else {
            return .rejected(key, .rootEpochMismatch)
        }
        if let revokedReason {
            return .rejected(key, .rootUnavailable(revokedReason))
        }
        if let current = observedKey {
            if key.contributionGeneration < current.contributionGeneration {
                return .rejected(
                    key,
                    .staleSnapshot(
                        received: key.contributionGeneration,
                        current: current.contributionGeneration
                    )
                )
            }
            if key.contributionGeneration == current.contributionGeneration {
                if key != current {
                    lastUnavailableReason = .invalidSnapshot
                    hasCurrentnessConflict = true
                    increment(&invalidSnapshotCount)
                    _ = advanceObservationSerial()
                    for operation in activeOperations.values {
                        operation.task.cancel()
                    }
                    return .rejected(key, .equalGenerationAuthorityConflict)
                }
                if hasCurrentnessConflict {
                    return .rejected(key, .equalGenerationAuthorityConflict)
                }
            }
        }

        if observedKey != key {
            observedKey = key
            lastUnavailableReason = nil
            hasCurrentnessConflict = false
            guard advanceObservationSerial() else {
                return .rejected(key, .rootUnavailable(.authorityRevoked))
            }
        }
        let operationObservationSerial = observationSerial

        guard snapshot.bindings.count <= policy.maximumInputBindingCount else {
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(
                key,
                .inputBindingLimit(
                    attempted: snapshot.bindings.count,
                    limit: policy.maximumInputBindingCount
                )
            )
        }

        guard activeRebuildCount < policy.maximumActiveRebuildCount else {
            let reason = WorkspaceCodemapSelectionGraphRuntimeBusyReason.actorActiveRebuildLimit
            lastUnavailableReason = .actorAdmissionRejected(reason)
            increment(&actorBusyCount)
            return .busy(key, reason)
        }
        let (nextReservedCount, reservedOverflow) = reservedInputBindingCount.addingReportingOverflow(
            snapshot.bindings.count
        )
        guard !reservedOverflow else {
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(key, .accountingOverflow)
        }
        guard nextReservedCount <= policy.maximumReservedBindingCount else {
            let reason = WorkspaceCodemapSelectionGraphRuntimeBusyReason.actorReservedBindingLimit
            lastUnavailableReason = .actorAdmissionRejected(reason)
            increment(&actorBusyCount)
            return .busy(key, reason)
        }

        let permit: CodeMapSelectionGraphAdmissionPermit
        do {
            permit = try admission.reserve(bindingCount: snapshot.bindings.count)
        } catch let CodeMapSelectionGraphAdmissionError.busy(reason) {
            lastUnavailableReason = .processAdmissionRejected(reason)
            increment(&processBusyCount)
            return .busy(key, .processAdmission(reason))
        } catch {
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(key, .accountingOverflow)
        }

        guard let operationID = issueOperationID() else {
            permit.close()
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(key, .accountingOverflow)
        }
        activeRebuildCount += 1
        reservedInputBindingCount = nextReservedCount
        latestOperationID = operationID
        if publishedShard?.key != key {
            lastUnavailableReason = .rebuilding
        }

        let sizePolicy = policy.graphSizePolicy
        let operationDiagnostics = diagnostics
        let task = Task.detached(priority: .utility) {
            operationDiagnostics.handle(.init(
                operationID: operationID,
                key: key,
                kind: .buildStarted
            ))
            let output = Self.buildShard(snapshot: snapshot, key: key, sizePolicy: sizePolicy)
            guard case .success = output else { return output }
            guard !Task.isCancelled else { return .cancelled }
            operationDiagnostics.handle(.init(
                operationID: operationID,
                key: key,
                kind: .beforePublication
            ))
            return Task.isCancelled ? .cancelled : output
        }
        activeOperations[operationID] = ActiveOperation(key: key, task: task)

        let output = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        activeOperations.removeValue(forKey: operationID)
        activeRebuildCount -= 1
        reservedInputBindingCount -= snapshot.bindings.count
        permit.close()

        if Task.isCancelled || output == .cancelled {
            if observedKey == key, publishedShard?.key != key {
                lastUnavailableReason = .cancelled
            }
            increment(&cancelledCount)
            return .cancelled(key)
        }

        guard revokedReason == nil,
              !hasCurrentnessConflict,
              operationObservationSerial == observationSerial,
              observedKey == key,
              latestOperationID == operationID
        else {
            increment(&supersededPublicationCount)
            return .superseded(key)
        }

        switch output {
        case let .success(shard):
            publishedShard = shard
            lastUnavailableReason = nil
            if shard.summary.isEmpty {
                increment(&emptyPublishedCount)
                return .publishedEmpty(shard.summary)
            }
            increment(&publishedCount)
            return .published(shard.summary)
        case let .rejected(reason):
            recordRejection(reason, key: key)
            return .rejected(key, reason)
        case .cancelled:
            increment(&cancelledCount)
            lastUnavailableReason = .cancelled
            return .cancelled(key)
        }
    }

    func query(
        _ query: WorkspaceCodemapSelectionGraphRuntimeQuery
    ) -> WorkspaceCodemapSelectionGraphRuntimeQueryDisposition {
        if let revokedReason {
            return .unavailable(.explicitRootUnavailable(revokedReason))
        }
        guard let observedKey else { return .unavailable(.notBuilt) }
        guard query.key == observedKey else {
            return .unavailable(.staleCurrentness(currentKey: observedKey))
        }
        guard !hasCurrentnessConflict else { return .unavailable(.invalidSnapshot) }
        if let shard = publishedShard, shard.key == observedKey {
            return queryShard(query, in: shard)
        }
        if activeOperations.values.contains(where: { $0.key == observedKey }) {
            return .unavailable(.rebuilding)
        }
        return .unavailable(lastUnavailableReason ?? .notBuilt)
    }

    func queryStructure(
        _ query: WorkspaceCodemapSelectionGraphRuntimeStructureQuery
    ) -> WorkspaceCodemapSelectionGraphRuntimeStructureDisposition {
        if Task.isCancelled { return .unavailable(.cancelled) }
        if let revokedReason {
            return .unavailable(.explicitRootUnavailable(revokedReason))
        }
        guard let observedKey else { return .unavailable(.notBuilt) }
        guard query.key == observedKey else {
            return .unavailable(.staleCurrentness(currentKey: observedKey))
        }
        guard !hasCurrentnessConflict else { return .unavailable(.invalidSnapshot) }
        if let shard = publishedShard, shard.key == observedKey {
            return queryStructureShard(query, in: shard)
        }
        if activeOperations.values.contains(where: { $0.key == observedKey }) {
            return .unavailable(.rebuilding)
        }
        return .unavailable(lastUnavailableReason ?? .notBuilt)
    }

    func fenceContributionsForPathInvalidation(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        guard rootEpoch == self.rootEpoch, revokedReason == nil else { return false }
        observedKey = nil
        publishedShard = nil
        latestOperationID = nil
        lastUnavailableReason = .rebuilding
        hasCurrentnessConflict = false
        advanceObservationSerial()
        for operation in activeOperations.values {
            operation.task.cancel()
        }
        return true
    }

    func invalidateCurrentness(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason
    ) -> Bool {
        guard rootEpoch == self.rootEpoch, revokedReason == nil else { return false }
        revokedReason = reason
        lastUnavailableReason = .explicitRootUnavailable(reason)
        advanceObservationSerial()
        for operation in activeOperations.values {
            operation.task.cancel()
        }
        return true
    }

    func accounting() -> WorkspaceCodemapSelectionGraphRuntimeAccounting {
        let unavailableReason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason? = if let revokedReason {
            .explicitRootUnavailable(revokedReason)
        } else if hasCurrentnessConflict {
            .invalidSnapshot
        } else if publishedShard?.key == observedKey {
            nil
        } else if let observedKey,
                  activeOperations.values.contains(where: { $0.key == observedKey })
        {
            .rebuilding
        } else {
            lastUnavailableReason
        }
        return WorkspaceCodemapSelectionGraphRuntimeAccounting(
            activeRebuildCount: activeRebuildCount,
            reservedInputBindingCount: reservedInputBindingCount,
            publishedSummary: publishedShard?.summary,
            currentObservedKey: observedKey,
            currentUnavailableReason: unavailableReason,
            publishedCount: publishedCount,
            emptyPublishedCount: emptyPublishedCount,
            actorBusyCount: actorBusyCount,
            processBusyCount: processBusyCount,
            cancelledCount: cancelledCount,
            budgetRejectedCount: budgetRejectedCount,
            invalidSnapshotCount: invalidSnapshotCount,
            supersededPublicationCount: supersededPublicationCount,
            materializedQueryResultCount: materializedQueryResultCount
        )
    }

    private func queryShard(
        _ query: WorkspaceCodemapSelectionGraphRuntimeQuery,
        in shard: ImmutableShard
    ) -> WorkspaceCodemapSelectionGraphRuntimeQueryDisposition {
        guard query.selectedSources.count <= policy.maximumSelectedSourceCountPerQuery else {
            return .unavailable(.budgetExceeded)
        }

        var generationsByFileID: [UUID: UInt64] = [:]
        for source in query.selectedSources {
            if let generation = generationsByFileID[source.fileID], generation != source.requestGeneration {
                return .unavailable(.invalidQuery)
            }
            generationsByFileID[source.fileID] = source.requestGeneration
        }
        let selectedSources = generationsByFileID.map {
            WorkspaceCodemapSelectionGraphRuntimeQuerySource(
                fileID: $0.key,
                requestGeneration: $0.value
            )
        }.sorted(by: querySourcePrecedes)
        guard selectedSources.count <= policy.maximumSelectedSourceCountPerQuery else {
            return .unavailable(.budgetExceeded)
        }

        var materializedByteCount = 128
        func reserveMaterializedBytes(_ byteCount: Int) -> Bool {
            let (next, overflow) = materializedByteCount.addingReportingOverflow(byteCount)
            guard !overflow, next <= query.outputBudget.maximumByteCount else { return false }
            materializedByteCount = next
            return true
        }
        let (selectedSourceBytes, selectedSourceByteOverflow) =
            selectedSources.count.multipliedReportingOverflow(by: 24)
        guard !selectedSourceByteOverflow,
              reserveMaterializedBytes(selectedSourceBytes)
        else {
            return .unavailable(.outputBudgetExceeded(.bytes))
        }

        let selectedFileIDs = Set(generationsByFileID.keys)
        var coverage: [WorkspaceCodemapSelectionGraphRuntimeSourceCoverage] = []
        var resolutions: [IndexedResolution] = []
        var targetIndices = Set<Int>()
        var failures: [IndexedFailure] = []

        for source in selectedSources {
            guard let sourceIndex = shard.nodeIndexByFileID[source.fileID] else {
                guard reserveMaterializedBytes(32) else {
                    return .unavailable(.outputBudgetExceeded(.bytes))
                }
                coverage.append(.init(source: source, state: .missing))
                continue
            }
            let sourceNode = shard.nodes[sourceIndex]
            guard sourceNode.requestGeneration == source.requestGeneration else {
                guard reserveMaterializedBytes(32) else {
                    return .unavailable(.outputBudgetExceeded(.bytes))
                }
                coverage.append(.init(source: source, state: .stale))
                continue
            }
            guard reserveMaterializedBytes(32) else {
                return .unavailable(.outputBudgetExceeded(.bytes))
            }
            coverage.append(.init(source: source, state: .covered))
            let sourceEndpoint = shard.endpoint(at: sourceIndex)

            for targetIndex in shard.adjacency[sourceIndex, default: []] {
                guard shard.nodes.indices.contains(targetIndex) else {
                    guard failures.count < policy.maximumReferenceFailureCountPerQuery else {
                        return .unavailable(.budgetExceeded)
                    }
                    guard failures.count < query.outputBudget.maximumReferenceFailureCount else {
                        return .unavailable(.outputBudgetExceeded(.referenceFailures))
                    }
                    guard reserveMaterializedBytes(64) else {
                        return .unavailable(.outputBudgetExceeded(.bytes))
                    }
                    failures.append(.init(
                        sourceIndex: sourceIndex,
                        record: .init(
                            source: sourceEndpoint,
                            referencedName: "",
                            failure: .staleTarget
                        )
                    ))
                    continue
                }
                let targetNode = shard.nodes[targetIndex]
                guard !selectedFileIDs.contains(targetNode.fileID) else { continue }
                if !targetIndices.contains(targetIndex) {
                    guard targetIndices.count < policy.maximumResolvedTargetCountPerQuery else {
                        return .unavailable(.budgetExceeded)
                    }
                    guard targetIndices.count < query.outputBudget.maximumResolvedTargetCount else {
                        return .unavailable(.outputBudgetExceeded(.resolvedTargets))
                    }
                    guard reserveMaterializedBytes(56) else {
                        return .unavailable(.outputBudgetExceeded(.bytes))
                    }
                    targetIndices.insert(targetIndex)
                }
                guard resolutions.count < query.outputBudget.maximumResolutionCount else {
                    return .unavailable(.outputBudgetExceeded(.resolutions))
                }
                guard reserveMaterializedBytes(112) else {
                    return .unavailable(.outputBudgetExceeded(.bytes))
                }
                resolutions.append(.init(
                    sourceIndex: sourceIndex,
                    targetIndex: targetIndex,
                    value: .init(source: sourceEndpoint, target: shard.endpoint(at: targetIndex))
                ))
            }
            for failure in shard.referenceFailures[sourceIndex, default: []] {
                guard failures.count < policy.maximumReferenceFailureCountPerQuery else {
                    return .unavailable(.budgetExceeded)
                }
                guard failures.count < query.outputBudget.maximumReferenceFailureCount else {
                    return .unavailable(.outputBudgetExceeded(.referenceFailures))
                }
                let (failureBytes, failureByteOverflow) =
                    failure.referencedName.utf8.count.addingReportingOverflow(64)
                guard !failureByteOverflow,
                      reserveMaterializedBytes(failureBytes)
                else {
                    return .unavailable(.outputBudgetExceeded(.bytes))
                }
                failures.append(.init(
                    sourceIndex: sourceIndex,
                    record: .init(
                        source: sourceEndpoint,
                        referencedName: failure.referencedName,
                        failure: failure.failure
                    )
                ))
            }
        }

        resolutions.sort {
            if $0.sourceIndex != $1.sourceIndex { return $0.sourceIndex < $1.sourceIndex }
            return $0.targetIndex < $1.targetIndex
        }
        failures.sort {
            if $0.sourceIndex != $1.sourceIndex { return $0.sourceIndex < $1.sourceIndex }
            return utf8Precedes($0.record.referencedName, $1.record.referencedName)
        }
        let targets = targetIndices.sorted().map(shard.endpoint(at:))
        increment(&materializedQueryResultCount)
        return .readyPartial(.init(
            key: shard.key,
            selectedSources: selectedSources,
            targets: targets,
            resolutions: resolutions.map(\.value),
            sourceCoverage: coverage,
            definitionUniverseCoverage: .partial(
                indexedNodes: shard.summary.nodeCount,
                candidateCount: .unknown
            ),
            referenceFailures: failures.map(\.record),
            publishedSummary: shard.summary,
            materializedByteCount: materializedByteCount
        ))
    }

    private func queryStructureShard(
        _ query: WorkspaceCodemapSelectionGraphRuntimeStructureQuery,
        in shard: ImmutableShard
    ) -> WorkspaceCodemapSelectionGraphRuntimeStructureDisposition {
        guard !query.seeds.isEmpty,
              query.seeds.count <= policy.maximumSelectedSourceCountPerQuery
        else { return .unavailable(.invalidQuery) }

        var generationsByFileID: [UUID: UInt64] = [:]
        for seed in query.seeds {
            if let generation = generationsByFileID[seed.fileID], generation != seed.requestGeneration {
                return .unavailable(.invalidQuery)
            }
            generationsByFileID[seed.fileID] = seed.requestGeneration
        }
        let seeds = generationsByFileID.map {
            WorkspaceCodemapSelectionGraphRuntimeQuerySource(
                fileID: $0.key,
                requestGeneration: $0.value
            )
        }.sorted(by: querySourcePrecedes)

        var seedIndices: [Int] = []
        for seed in seeds {
            guard let index = shard.nodeIndexByFileID[seed.fileID],
                  shard.nodes[index].requestGeneration == seed.requestGeneration
            else { return .unavailable(.invalidQuery) }
            seedIndices.append(index)
        }
        seedIndices.sort()

        var materializedByteCount = 128
        var visitsByIndex: [Int: TraversalVisit] = [:]
        var queue: [Int] = []
        var examinedEdges = Set<LocalEdge>()
        var failures: [IndexedFailure] = []

        func result() -> WorkspaceCodemapSelectionGraphRuntimeStructureResult {
            let nodes = visitsByIndex.map { index, visit in
                WorkspaceCodemapSelectionGraphRuntimeStructureNode(
                    endpoint: shard.endpoint(at: index),
                    depth: visit.depth,
                    reachedBy: visit.reachedBy
                )
            }.sorted {
                if $0.depth != $1.depth { return $0.depth < $1.depth }
                let lhsIndex = shard.nodeIndexByFileID[$0.endpoint.fileID] ?? .max
                let rhsIndex = shard.nodeIndexByFileID[$1.endpoint.fileID] ?? .max
                return lhsIndex < rhsIndex
            }
            let orderedFailures = failures.sorted {
                if $0.sourceIndex != $1.sourceIndex { return $0.sourceIndex < $1.sourceIndex }
                return utf8Precedes($0.record.referencedName, $1.record.referencedName)
            }
            return WorkspaceCodemapSelectionGraphRuntimeStructureResult(
                key: shard.key,
                seeds: seeds,
                nodes: nodes,
                examinedEdgeCount: examinedEdges.count,
                definitionUniverseCoverage: .partial(
                    indexedNodes: shard.summary.nodeCount,
                    candidateCount: .unknown
                ),
                referenceFailures: orderedFailures.map(\.record),
                publishedSummary: shard.summary,
                materializedByteCount: materializedByteCount
            )
        }

        func reserveBytes(_ count: Int) -> Bool {
            let (next, overflow) = materializedByteCount.addingReportingOverflow(count)
            guard !overflow, next <= query.limits.maximumByteCount else { return false }
            materializedByteCount = next
            return true
        }

        for index in seedIndices {
            guard visitsByIndex[index] == nil else { continue }
            guard visitsByIndex.count < query.limits.maximumNodeCount else {
                return .budget(result(), .nodes)
            }
            guard reserveBytes(64) else { return .budget(result(), .bytes) }
            visitsByIndex[index] = TraversalVisit(depth: 0, reachedBy: [])
            queue.append(index)
        }

        var cursor = 0
        while cursor < queue.count {
            if Task.isCancelled { return .unavailable(.cancelled) }
            let currentIndex = queue[cursor]
            cursor += 1
            guard let currentVisit = visitsByIndex[currentIndex],
                  currentVisit.depth < query.limits.maximumDepth
            else { continue }

            if query.direction != .referrers {
                for failure in shard.referenceFailures[currentIndex, default: []] {
                    let (bytes, overflow) = failure.referencedName.utf8.count.addingReportingOverflow(64)
                    guard !overflow, reserveBytes(bytes) else { return .budget(result(), .bytes) }
                    failures.append(.init(
                        sourceIndex: currentIndex,
                        record: .init(
                            source: shard.endpoint(at: currentIndex),
                            referencedName: failure.referencedName,
                            failure: failure.failure
                        )
                    ))
                }
            }

            var neighbors: [TraversalNeighbor] = []
            if query.direction != .referrers {
                neighbors.append(contentsOf: shard.adjacency[currentIndex, default: []].map {
                    TraversalNeighbor(
                        index: $0,
                        edge: LocalEdge(sourceIndex: currentIndex, targetIndex: $0),
                        direction: .referencedDefinitions
                    )
                })
            }
            if query.direction != .referencedDefinitions {
                neighbors.append(contentsOf: shard.reverseAdjacency[currentIndex, default: []].map {
                    TraversalNeighbor(
                        index: $0,
                        edge: LocalEdge(sourceIndex: $0, targetIndex: currentIndex),
                        direction: .referrers
                    )
                })
            }
            neighbors.sort {
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.direction.rawValue < $1.direction.rawValue
            }

            for neighbor in neighbors {
                guard shard.nodes.indices.contains(neighbor.index) else {
                    return .unavailable(.invalidSnapshot)
                }
                if examinedEdges.insert(neighbor.edge).inserted {
                    guard examinedEdges.count <= query.limits.maximumEdgeCount else {
                        examinedEdges.remove(neighbor.edge)
                        return .budget(result(), .edges)
                    }
                    guard reserveBytes(24) else {
                        examinedEdges.remove(neighbor.edge)
                        return .budget(result(), .bytes)
                    }
                }

                let nextDepth = currentVisit.depth + 1
                if var existing = visitsByIndex[neighbor.index] {
                    if existing.depth == nextDepth {
                        existing.reachedBy.insert(neighbor.direction)
                        visitsByIndex[neighbor.index] = existing
                    }
                    continue
                }
                guard visitsByIndex.count < query.limits.maximumNodeCount else {
                    return .budget(result(), .nodes)
                }
                guard reserveBytes(64) else { return .budget(result(), .bytes) }
                visitsByIndex[neighbor.index] = TraversalVisit(
                    depth: nextDepth,
                    reachedBy: [neighbor.direction]
                )
                queue.append(neighbor.index)
            }
        }

        increment(&materializedQueryResultCount)
        return .readyPartial(result())
    }

    private func recordRejection(
        _ reason: WorkspaceCodemapSelectionGraphRuntimeRejectionReason,
        key: WorkspaceCodemapSelectionGraphRuntimeKey
    ) {
        guard observedKey == key, publishedShard?.key != key else { return }
        switch reason {
        case .inputBindingLimit, .graphSize, .accountingOverflow:
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
        case .invalidSnapshot, .modelStore, .edge, .equalGenerationAuthorityConflict:
            lastUnavailableReason = .invalidSnapshot
            increment(&invalidSnapshotCount)
        case let .rootUnavailable(reason):
            lastUnavailableReason = .explicitRootUnavailable(reason)
        case .rootEpochMismatch, .staleSnapshot:
            break
        }
    }

    private func issueOperationID() -> UInt64? {
        guard nextOperationID < .max else { return nil }
        nextOperationID += 1
        return nextOperationID
    }

    @discardableResult
    private func advanceObservationSerial() -> Bool {
        guard observationSerial < .max else {
            if revokedReason == nil {
                revokedReason = .authorityRevoked
                lastUnavailableReason = .explicitRootUnavailable(.authorityRevoked)
            }
            for operation in activeOperations.values {
                operation.task.cancel()
            }
            return false
        }
        observationSerial += 1
        return true
    }

    private func increment(_ value: inout UInt64) {
        if value < .max {
            value += 1
        }
    }

    private static func buildShard(
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        key: WorkspaceCodemapSelectionGraphRuntimeKey,
        sizePolicy: WorkspaceCodemapSelectionGraphSizePolicy
    ) -> BuildOutput {
        do {
            try Task.checkCancellation()
            let bindings = try validatedSortedBindings(snapshot: snapshot, key: key)
            if bindings.isEmpty {
                let summary = WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
                    key: key,
                    nodeCount: 0,
                    uniqueEdgeCount: 0,
                    sizeAccounting: .zero,
                    isEmpty: true
                )
                return .success(.init(
                    key: key,
                    nodes: [],
                    nodeIndexByFileID: [:],
                    adjacency: [:],
                    reverseAdjacency: [:],
                    referenceFailures: [:],
                    summary: summary
                ))
            }

            guard let store = WorkspaceCodemapSelectionGraphModelStore.authorized(
                by: bindings[0],
                contributionGeneration: key.contributionGeneration,
                schemaVersion: key.schemaVersion,
                policyVersion: key.policyVersion,
                sizePolicy: sizePolicy
            ) else {
                return .rejected(.invalidSnapshot(.inconsistentCompletionAuthority))
            }

            var graphNodes: [WorkspaceCodemapSelectionGraphNode] = []
            for binding in bindings {
                try Task.checkCancellation()
                switch store.accept(binding) {
                case let .accepted(node, _):
                    graphNodes.append(node)
                case let .exactDuplicate(node, _):
                    graphNodes.append(node)
                case let .rejected(.sizeLimitExceeded(rejection)):
                    return .rejected(.graphSize(rejection))
                case let .rejected(rejection):
                    return .rejected(.modelStore(rejection))
                }
            }

            let nodes = graphNodes.map {
                ImmutableNode(fileID: $0.identity.fileID, requestGeneration: $0.identity.requestGeneration)
            }
            let indexByIdentity = Dictionary(uniqueKeysWithValues: graphNodes.indices.map {
                (graphNodes[$0].identity, $0)
            })
            let nodeIndexByFileID = Dictionary(uniqueKeysWithValues: nodes.indices.map {
                (nodes[$0].fileID, $0)
            })
            var lookupCache: [String: CachedLookup] = [:]
            var uniqueEdges = Set<LocalEdge>()
            var adjacency: [Int: [Int]] = [:]
            var reverseAdjacency: [Int: [Int]] = [:]
            var referenceFailures: [Int: [ImmutableReferenceFailure]] = [:]

            for sourceIndex in graphNodes.indices {
                let source = graphNodes[sourceIndex]
                for referencedName in source.references {
                    try Task.checkCancellation()
                    let lookup: CachedLookup
                    if let cached = lookupCache[referencedName] {
                        lookup = cached
                    } else {
                        switch store.definitionCandidates(named: referencedName, among: graphNodes) {
                        case let .candidates(candidates) where candidates.orderedCandidates.isEmpty:
                            lookup = .failure(.unresolvedDefinitionUniverse)
                        case let .candidates(candidates):
                            lookup = .targets(candidates.orderedCandidates)
                        case .candidateOverflow:
                            lookup = .failure(.candidateOverflow)
                        case .graphMismatch:
                            return .rejected(.invalidSnapshot(.inconsistentCompletionAuthority))
                        }
                        lookupCache[referencedName] = lookup
                    }

                    switch lookup {
                    case let .failure(failure):
                        referenceFailures[sourceIndex, default: []].append(.init(
                            referencedName: referencedName,
                            failure: failure
                        ))
                    case let .targets(targets):
                        for targetIdentity in targets {
                            try Task.checkCancellation()
                            guard let targetIndex = indexByIdentity[targetIdentity] else {
                                return .rejected(.invalidSnapshot(.inconsistentCompletionAuthority))
                            }
                            let localEdge = LocalEdge(sourceIndex: sourceIndex, targetIndex: targetIndex)
                            guard uniqueEdges.insert(localEdge).inserted else { continue }
                            switch store.makeEdge(source: source.identity, target: targetIdentity) {
                            case .edge:
                                adjacency[sourceIndex, default: []].append(targetIndex)
                                reverseAdjacency[targetIndex, default: []].append(sourceIndex)
                            case let .rejected(.sizeLimitExceeded(rejection)):
                                return .rejected(.graphSize(rejection))
                            case let .rejected(rejection):
                                return .rejected(.edge(rejection))
                            }
                        }
                    }
                }
            }
            for sourceIndex in Array(adjacency.keys) {
                adjacency[sourceIndex]?.sort()
            }
            for targetIndex in Array(reverseAdjacency.keys) {
                reverseAdjacency[targetIndex]?.sort()
            }
            for sourceIndex in Array(referenceFailures.keys) {
                referenceFailures[sourceIndex]?.sort {
                    utf8Precedes($0.referencedName, $1.referencedName)
                }
            }
            try Task.checkCancellation()

            let baseAccounting = WorkspaceCodemapSelectionGraphRuntimeSizeAccounting(store.accounting)
            let (reverseBytes, reverseByteOverflow) = UInt64(uniqueEdges.count)
                .multipliedReportingOverflow(by: 16)
            guard !reverseByteOverflow else {
                return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
            }
            let (totalBytes, totalByteOverflow) = baseAccounting.bytes.addingReportingOverflow(
                reverseBytes
            )
            guard !totalByteOverflow else {
                return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
            }
            guard totalBytes <= sizePolicy.maxBytes else {
                return .rejected(.graphSize(.limitExceeded(
                    dimension: .bytes,
                    attempted: totalBytes,
                    limit: sizePolicy.maxBytes
                )))
            }
            let accounting = WorkspaceCodemapSelectionGraphRuntimeSizeAccounting(
                nodes: baseAccounting.nodes,
                postings: baseAccounting.postings,
                edges: baseAccounting.edges,
                bytes: totalBytes
            )
            let summary = WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
                key: key,
                nodeCount: accounting.nodes,
                uniqueEdgeCount: accounting.edges,
                sizeAccounting: accounting,
                isEmpty: false
            )
            return .success(.init(
                key: key,
                nodes: nodes,
                nodeIndexByFileID: nodeIndexByFileID,
                adjacency: adjacency,
                reverseAdjacency: reverseAdjacency,
                referenceFailures: referenceFailures,
                summary: summary
            ))
        } catch is CancellationError {
            return .cancelled
        } catch let BuildValidationError.reason(reason) {
            return .rejected(.invalidSnapshot(reason))
        } catch {
            return .rejected(.accountingOverflow)
        }
    }

    private static func validatedSortedBindings(
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        key: WorkspaceCodemapSelectionGraphRuntimeKey
    ) throws -> [WorkspaceCodemapArtifactBinding] {
        var fileIDs = Set<UUID>()
        var relativePaths = Set<String>()
        for binding in snapshot.bindings {
            try Task.checkCancellation()
            guard binding.identity.rootID == key.rootEpoch.rootID,
                  binding.identity.rootLifetimeID == key.rootEpoch.rootLifetimeID
            else { throw BuildValidationError.reason(.bindingRootEpochMismatch) }
            guard fileIDs.insert(binding.identity.fileID).inserted else {
                throw BuildValidationError.reason(.duplicateFileID)
            }
            guard relativePaths.insert(binding.identity.standardizedRelativePath).inserted else {
                throw BuildValidationError.reason(.duplicateRelativePath)
            }
            switch binding.availability {
            case .pending:
                throw BuildValidationError.reason(.bindingNotResolved)
            case .unsupported:
                throw BuildValidationError.reason(.terminalBinding)
            case let .resolved(completion):
                guard completion.token.isFactoryValidated,
                      completion.sourceProof.isFactoryValidated,
                      completion.token.identity == binding.identity,
                      completion.sourceProof == completion.token.sourceExpectation
                else { throw BuildValidationError.reason(.inconsistentCompletionAuthority) }
                guard completion.sourceProof.sourceAuthority.rootEpoch == key.rootEpoch else {
                    throw BuildValidationError.reason(.bindingRootEpochMismatch)
                }
                guard completion.token.catalogGeneration == key.catalogGeneration else {
                    throw BuildValidationError.reason(.catalogGenerationMismatch)
                }
                guard completion.sourceProof.sourceAuthority.repositoryAuthority == key.repositoryAuthority else {
                    throw BuildValidationError.reason(.repositoryAuthorityMismatch)
                }
                switch completion.outcome {
                case .ready, .readyNoSymbols:
                    guard key.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion else {
                        throw BuildValidationError.reason(.contributionSchemaMismatch)
                    }
                    guard key.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion else {
                        throw BuildValidationError.reason(.contributionPolicyMismatch)
                    }
                case .oversize, .decodeFailed, .parseFailed:
                    throw BuildValidationError.reason(.terminalBinding)
                }
            }
        }
        return snapshot.bindings.sorted {
            if $0.identity.standardizedRelativePath != $1.identity.standardizedRelativePath {
                return utf8Precedes(
                    $0.identity.standardizedRelativePath,
                    $1.identity.standardizedRelativePath
                )
            }
            if $0.identity.fileID != $1.identity.fileID {
                return uuidPrecedes($0.identity.fileID, $1.identity.fileID)
            }
            return requestGeneration(of: $0) < requestGeneration(of: $1)
        }
    }
}

private struct ImmutableNode: Hashable {
    let fileID: UUID
    let requestGeneration: UInt64
}

private struct ImmutableReferenceFailure: Hashable {
    let referencedName: String
    let failure: WorkspaceCodemapSelectionGraphReferenceFailure
}

private struct ImmutableShard: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let nodes: [ImmutableNode]
    let nodeIndexByFileID: [UUID: Int]
    let adjacency: [Int: [Int]]
    let reverseAdjacency: [Int: [Int]]
    let referenceFailures: [Int: [ImmutableReferenceFailure]]
    let summary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary

    func endpoint(at index: Int) -> WorkspaceCodemapSelectionGraphRuntimeEndpoint {
        let node = nodes[index]
        return .init(rootEpoch: key.rootEpoch, fileID: node.fileID, requestGeneration: node.requestGeneration)
    }
}

private struct LocalEdge: Hashable {
    let sourceIndex: Int
    let targetIndex: Int
}

private struct TraversalVisit {
    let depth: Int
    var reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

private struct TraversalNeighbor {
    let index: Int
    let edge: LocalEdge
    let direction: WorkspaceCodemapStructureTraversalReachDirection
}

private enum CachedLookup {
    case targets([WorkspaceCodemapSelectionGraphNodeIdentity])
    case failure(WorkspaceCodemapSelectionGraphReferenceFailure)
}

private enum BuildOutput: Equatable {
    case success(ImmutableShard)
    case rejected(WorkspaceCodemapSelectionGraphRuntimeRejectionReason)
    case cancelled
}

private enum BuildValidationError: Error {
    case reason(WorkspaceCodemapSelectionGraphRuntimeValidationReason)
}

private struct ActiveOperation {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let task: Task<BuildOutput, Never>
}

private struct IndexedResolution {
    let sourceIndex: Int
    let targetIndex: Int
    let value: WorkspaceCodemapSelectionGraphRuntimeResolution
}

private struct IndexedFailure {
    let sourceIndex: Int
    let record: WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord
}

private func querySourcePrecedes(
    _ lhs: WorkspaceCodemapSelectionGraphRuntimeQuerySource,
    _ rhs: WorkspaceCodemapSelectionGraphRuntimeQuerySource
) -> Bool {
    if lhs.fileID != rhs.fileID { return uuidPrecedes(lhs.fileID, rhs.fileID) }
    return lhs.requestGeneration < rhs.requestGeneration
}

private func requestGeneration(of binding: WorkspaceCodemapArtifactBinding) -> UInt64 {
    switch binding.availability {
    case let .pending(token): token.requestGeneration
    case let .resolved(completion): completion.token.requestGeneration
    case .unsupported: 0
    }
}

private func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString.utf8.lexicographicallyPrecedes(rhs.uuidString.utf8)
}

private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
