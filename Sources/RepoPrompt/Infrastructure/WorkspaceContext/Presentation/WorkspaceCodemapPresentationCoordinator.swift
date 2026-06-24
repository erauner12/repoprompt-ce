import Foundation

struct WorkspaceCodemapPresentationRequestPolicy: Equatable {
    static let `default` = Self()

    let maximumReadinessRounds: Int
    let initialBackoffMilliseconds: Int
    let maximumBackoffMilliseconds: Int
    let maximumTotalWait: Duration
    let maximumCandidateCountPerRoot: Int
    let maximumCandidateDemandCount: Int

    init(
        maximumReadinessRounds: Int = 6,
        initialBackoffMilliseconds: Int = 50,
        maximumBackoffMilliseconds: Int = 400,
        maximumTotalWait: Duration = .seconds(2),
        maximumCandidateCountPerRoot: Int = 8192,
        maximumCandidateDemandCount: Int = 1024
    ) {
        precondition(maximumReadinessRounds > 0)
        precondition(initialBackoffMilliseconds > 0)
        precondition(maximumBackoffMilliseconds >= initialBackoffMilliseconds)
        precondition(maximumTotalWait >= .zero)
        precondition(maximumCandidateCountPerRoot > 0)
        precondition(maximumCandidateDemandCount > 0)
        self.maximumReadinessRounds = maximumReadinessRounds
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.maximumTotalWait = maximumTotalWait
        self.maximumCandidateCountPerRoot = maximumCandidateCountPerRoot
        self.maximumCandidateDemandCount = maximumCandidateDemandCount
    }
}

struct WorkspaceCodemapPresentationWaiter {
    let sleep: @Sendable (Duration) async throws -> Void

    static let production = Self { duration in
        try await Task.sleep(for: duration)
    }
}

private actor WorkspaceCodemapOperationPresentationOwnership {
    struct Resources {
        let tickets: [WorkspaceCodemapArtifactDemandTicket]
        let bundles: [WorkspaceCodemapFrozenPresentationBundle]
    }

    private var ticketsByRetainID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
    private var bundlesByID: [
        WorkspaceCodemapFrozenPresentationBundleID: WorkspaceCodemapFrozenPresentationBundle
    ] = [:]
    private var bundleIDsInAcquisitionOrder: [WorkspaceCodemapFrozenPresentationBundleID] = []

    func record(_ ownedResult: WorkspaceCodemapArtifactDemandOwnedResult) {
        switch ownedResult.ownership {
        case let .created(ticket), let .joined(ticket):
            ticketsByRetainID[ticket.retainID] = ticket
        case .notAcquired:
            break
        }
    }

    func record(_ bundle: WorkspaceCodemapFrozenPresentationBundle) {
        if bundlesByID[bundle.id] == nil {
            bundleIDsInAcquisitionOrder.append(bundle.id)
        }
        bundlesByID[bundle.id] = bundle
    }

    func tickets() -> [WorkspaceCodemapArtifactDemandTicket] {
        ticketsByRetainID.values.sorted { $0.retainID.uuidString < $1.retainID.uuidString }
    }

    func owns(_ ticket: WorkspaceCodemapArtifactDemandTicket) -> Bool {
        ticketsByRetainID[ticket.retainID] == ticket
    }

    func replaceConsumed(
        _ oldTicket: WorkspaceCodemapArtifactDemandTicket,
        with result: WorkspaceCodemapArtifactDemandResult
    ) {
        ticketsByRetainID.removeValue(forKey: oldTicket.retainID)
        let replacement: WorkspaceCodemapArtifactDemandTicket? = switch result {
        case let .pending(ticket): ticket
        case let .ready(ready): ready.ticket
        case .unavailable: nil
        }
        if let replacement {
            ticketsByRetainID[replacement.retainID] = replacement
        }
    }

    func drain() -> Resources {
        let resources = Resources(
            tickets: ticketsByRetainID.values.sorted { $0.retainID.uuidString < $1.retainID.uuidString },
            bundles: bundleIDsInAcquisitionOrder.compactMap { bundlesByID[$0] }
        )
        ticketsByRetainID.removeAll()
        bundlesByID.removeAll()
        bundleIDsInAcquisitionOrder.removeAll()
        return resources
    }
}

struct WorkspaceCodemapPresentationCoordinator {
    private struct AutomaticPreparation {
        let candidates: [WorkspaceCodemapOperationPresentationCandidate]
        let issues: [WorkspaceCodemapOperationIssue]
        let coverage: WorkspaceCodemapOperationPresentationCoverage?
        let receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt?
    }

    private struct DemandBatch {
        let resultsByFileID: [UUID: WorkspaceCodemapArtifactDemandResult]
    }

    let store: WorkspaceFileContextStore
    let policy: WorkspaceCodemapPresentationRequestPolicy
    let waiter: WorkspaceCodemapPresentationWaiter
    let beforePublicationRevalidation: @Sendable (
        WorkspaceCodemapOperationPresentationPublicationReceipt
    ) async -> Void
    let structureAttemptDidBegin: @Sendable (Int) -> Void

    init(
        store: WorkspaceFileContextStore,
        policy: WorkspaceCodemapPresentationRequestPolicy = .default,
        waiter: WorkspaceCodemapPresentationWaiter = .production,
        beforePublicationRevalidation: @escaping @Sendable (
            WorkspaceCodemapOperationPresentationPublicationReceipt
        ) async -> Void = { _ in },
        structureAttemptDidBegin: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.store = store
        self.policy = policy
        self.waiter = waiter
        self.beforePublicationRevalidation = beforePublicationRevalidation
        self.structureAttemptDidBegin = structureAttemptDidBegin
    }

    func presentation(
        for intent: WorkspaceCodemapOperationPresentationIntent,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:]
    ) async throws -> WorkspaceCodemapOperationPresentation {
        try await withPresentation(
            for: intent,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        ) { $0 }
    }

    func withPresentation<Value>(
        for intent: WorkspaceCodemapOperationPresentationIntent,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:],
        operation: (WorkspaceCodemapOperationPresentation) async throws -> Value
    ) async throws -> Value {
        guard intent != .none else {
            try Task.checkCancellation()
            let value = try await operation(.empty)
            try Task.checkCancellation()
            return value
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: policy.maximumTotalWait)
        var lastStaleReason: WorkspaceCodemapOperationPublicationStaleReason?

        for attempt in 0 ... 1 {
            try Task.checkCancellation()
            let ownership = WorkspaceCodemapOperationPresentationOwnership()
            do {
                let result = try await makePresentation(
                    intent: intent,
                    rootScope: rootScope,
                    logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                    ownership: ownership,
                    clock: clock,
                    deadline: deadline
                )
                if let reason = retryableStaleReason(in: result.issues) {
                    lastStaleReason = reason
                    await release(ownership)
                    if attempt == 0, clock.now < deadline { continue }
                    let value = try await operation(incompletePublication(reason: reason))
                    try Task.checkCancellation()
                    return value
                }
                let value = try await operation(result)
                try Task.checkCancellation()
                if let receipt = result.publicationReceipt {
                    await beforePublicationRevalidation(receipt)
                    try Task.checkCancellation()
                    let disposition = await store.revalidateCodemapOperationPresentationForPublication(
                        receipt,
                        rootScope: rootScope
                    )
                    switch disposition {
                    case .current:
                        await release(ownership)
                        return value
                    case let .stale(reason):
                        lastStaleReason = reason
                        await release(ownership)
                        if attempt == 0, clock.now < deadline { continue }
                        let fallbackValue = try await operation(incompletePublication(reason: reason))
                        try Task.checkCancellation()
                        return fallbackValue
                    }
                }
                await release(ownership)
                return value
            } catch {
                await release(ownership)
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw error
            }
        }
        let value = try await operation(incompletePublication(reason: lastStaleReason ?? .rootScope))
        try Task.checkCancellation()
        return value
    }

    private func makePresentation(
        intent: WorkspaceCodemapOperationPresentationIntent,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String],
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> WorkspaceCodemapOperationPresentation {
        let candidates: [WorkspaceCodemapOperationPresentationCandidate]
        var issues: [WorkspaceCodemapOperationIssue]
        let completeRootSet: Bool
        let completeRootCatalogs: [WorkspaceCodemapOperationCompleteRootCatalogReceipt]
        let automaticReceipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt?

        switch intent {
        case .none:
            return .empty
        case let .exact(fileIDs, isCompleteRootSet):
            let collection = await store.codemapOperationPresentationCandidates(
                forFileIDs: fileIDs,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                includeCompleteRootCatalogs: isCompleteRootSet
            )
            candidates = collection.candidates
            issues = collection.issues.map(WorkspaceCodemapOperationIssue.candidate)
            completeRootSet = isCompleteRootSet
            completeRootCatalogs = collection.completeRootCatalogs
            automaticReceipt = nil
        case let .automatic(sourceFileIDs):
            let preparation = try await prepareAutomaticCandidates(
                sourceFileIDs: sourceFileIDs,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                ownership: ownership,
                clock: clock,
                deadline: deadline
            )
            if let coverage = preparation.coverage {
                return WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: coverage,
                    issues: preparation.issues,
                    publicationReceipt: nil
                )
            }
            candidates = preparation.candidates
            issues = preparation.issues
            completeRootSet = false
            completeRootCatalogs = []
            automaticReceipt = preparation.receipt
        }

        guard !candidates.isEmpty else {
            let coverage: WorkspaceCodemapOperationPresentationCoverage = issues.isEmpty
                ? .complete
                : .unavailable(issues)
            let receipt: WorkspaceCodemapOperationPresentationPublicationReceipt? = if let automaticReceipt {
                WorkspaceCodemapOperationPresentationPublicationReceipt(
                    requestID: UUID(),
                    rootScope: rootScope,
                    logicalRootDisplayNamesByRootID: [:],
                    completeRootSet: completeRootSet,
                    completeRootCatalogs: completeRootCatalogs,
                    candidates: [],
                    demandTickets: [],
                    bundles: [],
                    automaticReceipt: automaticReceipt
                )
            } else {
                nil
            }
            return WorkspaceCodemapOperationPresentation(
                orderedEntries: [],
                coverage: coverage,
                issues: issues,
                publicationReceipt: receipt
            )
        }

        let demandBatch = try await demand(
            fileIDs: candidates.map(\.fileID),
            priority: .demand,
            ownership: ownership,
            clock: clock,
            deadline: deadline
        )
        var requestsByRoot: [WorkspaceCodemapRootEpoch: [WorkspaceCodemapPresentationRequest]] = [:]
        for candidate in candidates {
            guard let result = demandBatch.resultsByFileID[candidate.fileID] else {
                issues.append(.unavailable(fileID: candidate.fileID, reason: .registrationFailed))
                continue
            }
            switch result {
            case let .ready(ready):
                guard ready.ticket.rootEpoch == candidate.rootEpoch else {
                    issues.append(.unavailable(fileID: candidate.fileID, reason: .staleCurrentness))
                    continue
                }
                requestsByRoot[candidate.rootEpoch, default: []].append(
                    WorkspaceCodemapPresentationRequest(
                        ticket: ready.ticket,
                        logicalPath: candidate.logicalPath
                    )
                )
            case let .pending(ticket):
                issues.append(.pending(fileID: candidate.fileID, ticket: ticket))
            case let .unavailable(reason):
                issues.append(.unavailable(fileID: candidate.fileID, reason: reason))
            }
        }

        var renderedEntries: [WorkspaceCodemapOperationRenderedEntry] = []
        var bundleReceipts: [WorkspaceCodemapOperationPresentationBundleReceipt] = []
        for rootEpoch in requestsByRoot.keys.sorted(by: rootEpochPrecedes) {
            try Task.checkCancellation()
            let requests = requestsByRoot[rootEpoch] ?? []
            switch await store.freezeCodemapPresentation(requests) {
            case let .unavailable(reason):
                issues.append(.freezeUnavailable(rootEpoch: rootEpoch, reason: reason))
            case let .ready(bundle):
                await ownership.record(bundle)
                switch await store.renderCodemapPresentation(bundle) {
                case let .unavailable(reason):
                    issues.append(.renderUnavailable(rootEpoch: rootEpoch, reason: reason))
                case let .ready(rendered):
                    bundleReceipts.append(WorkspaceCodemapOperationPresentationBundleReceipt(
                        bundleID: bundle.id,
                        rootEpoch: bundle.rootEpoch,
                        entries: bundle.entries
                    ))
                    renderedEntries.append(contentsOf: rendered.map { entry in
                        WorkspaceCodemapOperationRenderedEntry(
                            bundleID: bundle.id,
                            fileID: entry.ticket.fileID,
                            rootEpoch: entry.ticket.rootEpoch,
                            artifactKey: entry.artifactKey,
                            logicalPath: entry.logicalPath,
                            text: entry.text,
                            tokenCount: entry.tokenCount
                        )
                    })
                }
            }
        }
        renderedEntries.sort(by: renderedEntryPrecedes)
        issues.sort { stableIssueKey($0) < stableIssueKey($1) }
        let coverage = coverage(for: renderedEntries, issues: issues)
        let receipt: WorkspaceCodemapOperationPresentationPublicationReceipt?
        if renderedEntries.isEmpty, automaticReceipt == nil {
            receipt = nil
        } else {
            let candidatesByFileID = Dictionary(
                uniqueKeysWithValues: candidates.map { ($0.fileID, $0) }
            )
            let publishedCandidates = renderedEntries.compactMap { candidatesByFileID[$0.fileID] }
            let validatedLogicalRootDisplayNames = Dictionary(
                publishedCandidates.map { ($0.rootEpoch.rootID, $0.logicalPath.rootDisplayName) },
                uniquingKeysWith: { current, _ in current }
            )
            let demandTickets = publicationTickets(
                from: bundleReceipts,
                publishedFileIDs: Set(renderedEntries.map(\.fileID))
            )
            receipt = WorkspaceCodemapOperationPresentationPublicationReceipt(
                requestID: UUID(),
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: validatedLogicalRootDisplayNames,
                completeRootSet: completeRootSet,
                completeRootCatalogs: completeRootCatalogs,
                candidates: publishedCandidates,
                demandTickets: demandTickets,
                bundles: bundleReceipts,
                automaticReceipt: automaticReceipt
            )
        }
        return WorkspaceCodemapOperationPresentation(
            orderedEntries: renderedEntries,
            coverage: coverage,
            issues: issues,
            publicationReceipt: receipt
        )
    }

    private func prepareAutomaticCandidates(
        sourceFileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String],
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> AutomaticPreparation {
        let sourceCollection = await store.codemapOperationPresentationCandidates(
            forFileIDs: sourceFileIDs,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        var issues = sourceCollection.issues.map(WorkspaceCodemapOperationIssue.candidate)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceCollection.candidates.map(\.fileID),
            rootScope: rootScope
        )
        guard !identities.isEmpty else {
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage
                .unavailable(.noReadySources)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(
                candidates: [],
                issues: issues,
                coverage: .unavailable(issues),
                receipt: nil
            )
        }
        let sourceLimit = await store.automaticCodemapSelectionSourceDemandLimit()
        guard identities.count <= sourceLimit else {
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.budget(
                .sourceLimit(attempted: identities.count, limit: sourceLimit)
            )
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(
                candidates: [],
                issues: issues,
                coverage: .unavailable(issues),
                receipt: nil
            )
        }

        let sourceDemand = try await demand(
            fileIDs: identities.map(\.fileID),
            priority: .demand,
            ownership: ownership,
            clock: clock,
            deadline: deadline
        )
        var readySources: [WorkspaceCodemapAutomaticSelectionSourceIdentity] = []
        var pendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        var partialReasons: [WorkspaceCodemapAutomaticSelectionPartialReason] = []
        for source in identities {
            guard let result = sourceDemand.resultsByFileID[source.fileID] else { continue }
            switch result {
            case .ready:
                readySources.append(source)
            case let .pending(ticket):
                pendingReasons.append(.sourceDemand(source, ticket))
                partialReasons.append(.sourceDemandTimedOut(source))
            case .unavailable(.busy):
                pendingReasons.append(.sourceBusy(source, attempts: policy.maximumReadinessRounds))
                partialReasons.append(.sourceDemandTimedOut(source))
            case let .unavailable(reason):
                partialReasons.append(.source(.unavailable(source, reason)))
            }
        }
        guard !readySources.isEmpty else {
            pendingReasons.sort { stableIssueKey($0) < stableIssueKey($1) }
            partialReasons.sort { stableIssueKey($0) < stableIssueKey($1) }
            let automaticCoverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage = pendingReasons.isEmpty
                ? .unavailable(.noReadySources)
                : .pending(pendingReasons)
            issues.append(.automatic(automaticCoverage))
            let coverage: WorkspaceCodemapOperationPresentationCoverage = pendingReasons.isEmpty
                ? .unavailable(issues)
                : .pending(issues)
            return AutomaticPreparation(candidates: [], issues: issues, coverage: coverage, receipt: nil)
        }

        var planDisposition: WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition = .pending([])
        for round in 0 ..< policy.maximumReadinessRounds {
            try Task.checkCancellation()
            planDisposition = await store.planAutomaticCodemapSelectionCandidates(
                sources: readySources,
                rootScope: rootScope,
                maximumCandidateCountPerRoot: policy.maximumCandidateCountPerRoot,
                maximumCandidateDemandCount: policy.maximumCandidateDemandCount
            )
            guard case .pending = planDisposition,
                  round + 1 < policy.maximumReadinessRounds,
                  clock.now < deadline
            else { break }
            try await wait(round: round, suggestedMilliseconds: [], clock: clock, deadline: deadline)
        }
        let plan: WorkspaceCodemapAutomaticSelectionCandidatePlan
        switch planDisposition {
        case let .ready(value):
            plan = value
            partialReasons.append(contentsOf: value.partialReasons)
        case let .pending(reasons):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.pending(reasons)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        case let .unavailable(reason):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.unavailable(reason)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .unavailable(issues), receipt: nil)
        case let .stale(reason):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.stale(reason)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .unavailable(issues), receipt: nil)
        case let .budget(reason):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.budget(reason)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .unavailable(issues), receipt: nil)
        }

        let candidateDemand = try await demand(
            fileIDs: plan.candidates.map(\.identity.fileID),
            priority: .background,
            ownership: ownership,
            clock: clock,
            deadline: deadline
        )
        var candidatePending: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        for candidate in plan.candidates {
            let fileID = candidate.identity.fileID
            guard let result = candidateDemand.resultsByFileID[fileID] else { continue }
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: candidate.identity.rootID,
                rootLifetimeID: candidate.identity.rootLifetimeID
            )
            switch result {
            case .ready:
                break
            case let .pending(ticket):
                candidatePending.append(.candidateDemand(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    ticket: ticket
                ))
            case .unavailable(.busy):
                candidatePending.append(.candidateBusy(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    attempts: policy.maximumReadinessRounds
                ))
            case let .unavailable(reason):
                partialReasons.append(.candidateTerminal(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    reason: reason
                ))
            }
        }
        guard candidatePending.isEmpty else {
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.pending(candidatePending)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        }

        var selection = try await store.resolveAutomaticCodemapSelection(
            sources: readySources,
            rootScope: rootScope
        )
        for round in 1 ..< policy.maximumReadinessRounds {
            let shouldRetry = switch selection.aggregateCoverage {
            case .busy, .pending: true
            case .complete, .partial, .unavailable, .stale, .budget: false
            }
            guard shouldRetry, clock.now < deadline else { break }
            try await wait(round: round, suggestedMilliseconds: [], clock: clock, deadline: deadline)
            selection = try await store.resolveAutomaticCodemapSelection(
                sources: readySources,
                rootScope: rootScope
            )
        }
        if !partialReasons.isEmpty {
            partialReasons.sort { stableIssueKey($0) < stableIssueKey($1) }
            switch selection.aggregateCoverage {
            case .complete:
                selection = WorkspaceCodemapAutomaticSelectionResult(
                    roots: selection.roots,
                    aggregateCoverage: .partial(partialReasons),
                    publicationReceipt: selection.publicationReceipt
                )
            case let .partial(existing):
                selection = WorkspaceCodemapAutomaticSelectionResult(
                    roots: selection.roots,
                    aggregateCoverage: .partial(existing + partialReasons),
                    publicationReceipt: selection.publicationReceipt
                )
            case .pending, .unavailable, .stale, .busy, .budget:
                break
            }
        }
        switch selection.aggregateCoverage {
        case .complete:
            break
        case .partial:
            issues.append(.automatic(selection.aggregateCoverage))
        case .pending:
            issues.append(.automatic(selection.aggregateCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        case .unavailable, .stale, .busy, .budget:
            issues.append(.automatic(selection.aggregateCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .unavailable(issues), receipt: nil)
        }
        let collection = await store.codemapOperationPresentationCandidates(
            forFileIDs: selection.targets.map(\.fileID),
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        issues.append(contentsOf: collection.issues.map(WorkspaceCodemapOperationIssue.candidate))
        return AutomaticPreparation(
            candidates: collection.candidates,
            issues: issues,
            coverage: nil,
            receipt: selection.publicationReceipt
        )
    }

    private func demand(
        fileIDs: [UUID],
        priority: CodeMapArtifactBuildPriority,
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> DemandBatch {
        var orderedFileIDs: [UUID] = []
        var seen = Set<UUID>()
        for fileID in fileIDs where seen.insert(fileID).inserted {
            orderedFileIDs.append(fileID)
        }
        var results: [UUID: WorkspaceCodemapArtifactDemandResult] = [:]
        var ticketsByFileID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
        for fileID in orderedFileIDs {
            try Task.checkCancellation()
            let ownedResult = await store.requestCodemapArtifactWithOwnership(
                forFileID: fileID,
                priority: priority
            )
            await ownership.record(ownedResult)
            results[fileID] = ownedResult.result
            ticketsByFileID[fileID] = ticket(from: ownedResult.result)
        }

        for round in 0 ..< policy.maximumReadinessRounds {
            try Task.checkCancellation()
            var hasPending = false
            var retryAfter: [Int] = []
            for fileID in orderedFileIDs {
                guard let current = results[fileID] else { continue }
                switch current {
                case let .pending(ticket):
                    let refreshed = await store.codemapArtifactDemandStatus(ticket)
                    results[fileID] = refreshed
                    if case .pending = refreshed { hasPending = true }
                    if case let .unavailable(.busy(milliseconds)) = refreshed {
                        hasPending = true
                        if let milliseconds { retryAfter.append(milliseconds) }
                    }
                case let .unavailable(.busy(milliseconds)):
                    hasPending = true
                    if let milliseconds { retryAfter.append(milliseconds) }
                case .ready, .unavailable:
                    break
                }
            }
            guard hasPending,
                  round + 1 < policy.maximumReadinessRounds,
                  clock.now < deadline
            else { break }
            try await wait(
                round: round,
                suggestedMilliseconds: retryAfter,
                clock: clock,
                deadline: deadline
            )
            for fileID in orderedFileIDs {
                guard case .unavailable(.busy) = results[fileID] else { continue }
                if let existingTicket = ticketsByFileID[fileID],
                   await ownership.owns(existingTicket)
                {
                    let retried = await store.retryBusyCodemapArtifactDemand(
                        existingTicket,
                        priority: priority
                    )
                    let oldStatus = await store.codemapArtifactDemandStatus(existingTicket)
                    if case .unavailable(.staleCurrentness) = oldStatus {
                        await ownership.replaceConsumed(existingTicket, with: retried)
                        ticketsByFileID[fileID] = ticket(from: retried)
                    }
                    results[fileID] = retried
                } else {
                    let ownedResult = await store.requestCodemapArtifactWithOwnership(
                        forFileID: fileID,
                        priority: priority
                    )
                    await ownership.record(ownedResult)
                    results[fileID] = ownedResult.result
                    ticketsByFileID[fileID] = ticket(from: ownedResult.result)
                }
            }
        }
        return DemandBatch(resultsByFileID: results)
    }

    private func ticket(
        from result: WorkspaceCodemapArtifactDemandResult
    ) -> WorkspaceCodemapArtifactDemandTicket? {
        switch result {
        case let .pending(ticket): ticket
        case let .ready(ready): ready.ticket
        case .unavailable: nil
        }
    }

    private func publicationTickets(
        from bundles: [WorkspaceCodemapOperationPresentationBundleReceipt],
        publishedFileIDs: Set<UUID>
    ) -> [WorkspaceCodemapArtifactDemandTicket] {
        var seenRetainIDs = Set<UUID>()
        return bundles
            .flatMap(\.entries)
            .filter { publishedFileIDs.contains($0.ticket.fileID) }
            .sorted { lhs, rhs in
                if lhs.logicalPath.displayPath != rhs.logicalPath.displayPath {
                    return lhs.logicalPath.displayPath.utf8.lexicographicallyPrecedes(
                        rhs.logicalPath.displayPath.utf8
                    )
                }
                if lhs.ticket.fileID != rhs.ticket.fileID {
                    return lhs.ticket.fileID.uuidString < rhs.ticket.fileID.uuidString
                }
                return lhs.ticket.retainID.uuidString < rhs.ticket.retainID.uuidString
            }
            .compactMap { entry in
                seenRetainIDs.insert(entry.ticket.retainID).inserted ? entry.ticket : nil
            }
    }

    private func wait(
        round: Int,
        suggestedMilliseconds: [Int],
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        try Task.checkCancellation()
        let exponential = policy.initialBackoffMilliseconds << min(round, 3)
        let suggested = suggestedMilliseconds.max() ?? exponential
        let milliseconds = min(
            policy.maximumBackoffMilliseconds,
            max(policy.initialBackoffMilliseconds, suggested)
        )
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return }
        try await waiter.sleep(min(.milliseconds(milliseconds), remaining))
        try Task.checkCancellation()
    }

    private func release(_ ownership: WorkspaceCodemapOperationPresentationOwnership) async {
        let resources = await ownership.drain()
        for bundle in resources.bundles {
            _ = await store.releaseCodemapPresentation(bundle)
        }
        for ticket in resources.tickets {
            _ = await store.cancelCodemapArtifactDemand(ticket)
        }
    }

    private func coverage(
        for renderedEntries: [WorkspaceCodemapOperationRenderedEntry],
        issues: [WorkspaceCodemapOperationIssue]
    ) -> WorkspaceCodemapOperationPresentationCoverage {
        guard !issues.isEmpty else { return .complete }
        if !renderedEntries.isEmpty { return .partial(issues) }
        if issues.contains(where: { issue in
            if case .pending = issue { return true }
            if case let .automatic(coverage) = issue, case .pending = coverage { return true }
            return false
        }) {
            return .pending(issues)
        }
        return .unavailable(issues)
    }

    private func incompletePublication(
        reason: WorkspaceCodemapOperationPublicationStaleReason
    ) -> WorkspaceCodemapOperationPresentation {
        let issue = WorkspaceCodemapOperationIssue.publicationStale(reason)
        return WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .unavailable([issue]),
            issues: [issue],
            publicationReceipt: nil
        )
    }

    private func retryableStaleReason(
        in issues: [WorkspaceCodemapOperationIssue]
    ) -> WorkspaceCodemapOperationPublicationStaleReason? {
        for issue in issues {
            switch issue {
            case let .unavailable(fileID, .staleCurrentness):
                return .catalog(fileID: fileID)
            case let .freezeUnavailable(rootEpoch, reason):
                switch reason {
                case .staleCurrentness, .handleRevoked, .logicalPathMismatch:
                    return .rootEpoch(rootEpoch)
                case .emptyRequest, .entryLimitExceeded, .retainedBundleLimitExceeded,
                     .duplicateFileID, .mixedRootEpoch, .pending, .demandUnavailable:
                    break
                }
            case let .renderUnavailable(rootEpoch, reason):
                switch reason {
                case .bundleNotRetained, .bundleMetadataMismatch, .staleCurrentness, .handleRevoked:
                    return .rootEpoch(rootEpoch)
                case .noRenderableCodemap:
                    break
                }
            case let .automatic(.stale(reason)):
                return .automatic(reason)
            case let .publicationStale(reason):
                return reason
            case .coordinationUnavailable, .cancelled, .candidate, .pending, .unavailable, .automatic:
                break
            }
        }
        return nil
    }

    private func rootEpochPrecedes(
        _ lhs: WorkspaceCodemapRootEpoch,
        _ rhs: WorkspaceCodemapRootEpoch
    ) -> Bool {
        if lhs.rootID != rhs.rootID { return lhs.rootID.uuidString < rhs.rootID.uuidString }
        return lhs.rootLifetimeID.uuidString < rhs.rootLifetimeID.uuidString
    }

    private func renderedEntryPrecedes(
        _ lhs: WorkspaceCodemapOperationRenderedEntry,
        _ rhs: WorkspaceCodemapOperationRenderedEntry
    ) -> Bool {
        if lhs.logicalPath.displayPath != rhs.logicalPath.displayPath {
            return lhs.logicalPath.displayPath < rhs.logicalPath.displayPath
        }
        return lhs.fileID.uuidString < rhs.fileID.uuidString
    }

    private func stableIssueKey(_ value: some Any) -> String {
        String(reflecting: value)
    }
}

private struct WorkspaceCodemapStructureAttempt {
    let presentation: WorkspaceCodemapStructurePresentation
    let receipt: WorkspaceCodemapStructurePublicationReceipt?
    let staleReason: WorkspaceCodemapStructurePublicationStaleReason?
}

extension WorkspaceCodemapPresentationCoordinator {
    func structurePresentation(
        seedFileIDs: [UUID],
        direction: WorkspaceCodemapStructureTraversalDirection?,
        traversalLimits: WorkspaceCodemapStructureTraversalLimits,
        outputLimits: WorkspaceCodemapStructureOutputLimits,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:]
    ) async throws -> WorkspaceCodemapStructurePresentation {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: policy.maximumTotalWait)
        var lastStaleReason: WorkspaceCodemapStructurePublicationStaleReason?

        for attemptIndex in 0 ... 1 {
            try Task.checkCancellation()
            structureAttemptDidBegin(attemptIndex)
            let ownership = WorkspaceCodemapOperationPresentationOwnership()
            do {
                let attempt = try await makeStructureAttempt(
                    seedFileIDs: seedFileIDs,
                    direction: direction,
                    traversalLimits: traversalLimits,
                    outputLimits: outputLimits,
                    rootScope: rootScope,
                    logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                    ownership: ownership,
                    clock: clock,
                    deadline: deadline
                )
                if let staleReason = attempt.staleReason {
                    lastStaleReason = staleReason
                    await release(ownership)
                    if attemptIndex == 0, clock.now < deadline { continue }
                    return .stale(staleReason, requestedSeedCount: seedFileIDs.count)
                }
                guard let receipt = attempt.receipt else {
                    await release(ownership)
                    if attemptIndex > 0, let lastStaleReason {
                        return .stale(lastStaleReason, requestedSeedCount: seedFileIDs.count)
                    }
                    return attempt.presentation
                }
                await beforePublicationRevalidation(receipt.presentation)
                switch await store.revalidateCodemapStructureForPublication(
                    receipt,
                    rootScope: rootScope
                ) {
                case .current:
                    await release(ownership)
                    return attempt.presentation
                case let .stale(reason):
                    lastStaleReason = reason
                    await release(ownership)
                    if attemptIndex == 0, clock.now < deadline { continue }
                    return .stale(reason, requestedSeedCount: seedFileIDs.count)
                }
            } catch {
                await release(ownership)
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw error
            }
        }
        return .stale(lastStaleReason ?? .output, requestedSeedCount: seedFileIDs.count)
    }

    private func makeStructureAttempt(
        seedFileIDs: [UUID],
        direction: WorkspaceCodemapStructureTraversalDirection?,
        traversalLimits: WorkspaceCodemapStructureTraversalLimits,
        outputLimits: WorkspaceCodemapStructureOutputLimits,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String],
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> WorkspaceCodemapStructureAttempt {
        let seedCollection = await store.codemapOperationPresentationCandidates(
            forFileIDs: seedFileIDs,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        var issues = seedCollection.issues.map(WorkspaceCodemapStructureIssue.candidate)
        let seedCountsByRoot = Dictionary(
            grouping: seedCollection.candidates,
            by: \.rootEpoch
        ).mapValues(\.count)
        if let overRootLimit = seedCountsByRoot.values.max(),
           overRootLimit > policy.maximumCandidateCountPerRoot
        {
            issues.append(.seedDemandLimit(
                attempted: overRootLimit,
                limit: policy.maximumCandidateCountPerRoot
            ))
            return WorkspaceCodemapStructureAttempt(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: .budget,
                    entries: [],
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                receipt: nil,
                staleReason: nil
            )
        }
        let seedDemandLimit = min(
            policy.maximumCandidateDemandCount,
            outputLimits.maximumFileCount
        )
        guard seedCollection.candidates.count <= seedDemandLimit else {
            issues.append(.seedDemandLimit(
                attempted: seedCollection.candidates.count,
                limit: seedDemandLimit
            ))
            return WorkspaceCodemapStructureAttempt(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: .budget,
                    entries: [],
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                receipt: nil,
                staleReason: nil
            )
        }
        if let firstCandidate = seedCollection.candidates.first,
           outputLimits.maximumCodemapTokenCount == 0
        {
            issues.append(.tokenLimit(
                path: firstCandidate.logicalPath.displayPath,
                attempted: 1,
                limit: 0
            ))
            return WorkspaceCodemapStructureAttempt(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: .budget,
                    entries: [],
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                receipt: nil,
                staleReason: nil
            )
        }
        let seedDemand = try await demand(
            fileIDs: seedCollection.candidates.map(\.fileID),
            priority: .demand,
            ownership: ownership,
            clock: clock,
            deadline: deadline
        )
        var readyTicketsByFileID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
        var graphSeeds: [WorkspaceCodemapStoreSelectionGraphSourceIdentity] = []
        for candidate in seedCollection.candidates {
            guard let result = seedDemand.resultsByFileID[candidate.fileID] else {
                issues.append(.artifactUnavailable(
                    fileID: candidate.fileID,
                    reason: .registrationFailed
                ))
                continue
            }
            switch result {
            case let .ready(ready):
                readyTicketsByFileID[candidate.fileID] = ready.ticket
                graphSeeds.append(.init(ticket: ready.ticket))
            case let .pending(ticket):
                issues.append(.artifactPending(fileID: candidate.fileID, ticket: ticket))
            case .unavailable(.cancelled):
                throw CancellationError()
            case .unavailable(.staleCurrentness):
                let ticket = await ownership.tickets().first {
                    $0.fileID == candidate.fileID
                }
                let reason: WorkspaceCodemapStructurePublicationStaleReason = if let ticket {
                    .presentation(.demand(ticket))
                } else {
                    .presentation(.catalog(fileID: candidate.fileID))
                }
                return WorkspaceCodemapStructureAttempt(
                    presentation: emptyStructurePresentation(
                        outcome: .stale,
                        issues: [],
                        requestedSeedCount: seedFileIDs.count,
                        resolvedSeedCount: graphSeeds.count
                    ),
                    receipt: nil,
                    staleReason: reason
                )
            case let .unavailable(reason):
                issues.append(.artifactUnavailable(fileID: candidate.fileID, reason: reason))
            }
        }

        guard !graphSeeds.isEmpty else {
            let outcome: WorkspaceCodemapStructureOutcome = issues.contains(where: {
                if case .artifactPending = $0 { return true }
                return false
            }) ? .pending : .unavailable
            return WorkspaceCodemapStructureAttempt(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: outcome,
                    entries: [],
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                receipt: nil,
                staleReason: nil
            )
        }

        var provenanceByFileID: [UUID: (depth: Int, reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>)] =
            Dictionary(uniqueKeysWithValues: graphSeeds.map { ($0.ticket.fileID, (0, [])) })
        var traversalReceipt: WorkspaceCodemapStructureTraversalPublicationReceipt?
        var examinedEdgeCount = 0
        var traversalBudgetHit = false

        if let direction {
            var disposition = await store.queryCodemapStructureGraph(
                WorkspaceCodemapStructureTraversalQuery(
                    seeds: graphSeeds,
                    direction: direction,
                    limits: traversalLimits
                )
            )
            for round in 0 ..< policy.maximumReadinessRounds {
                guard case .pending = disposition,
                      round + 1 < policy.maximumReadinessRounds,
                      clock.now < deadline
                else { break }
                try await wait(round: round, suggestedMilliseconds: [], clock: clock, deadline: deadline)
                disposition = await store.queryCodemapStructureGraph(
                    WorkspaceCodemapStructureTraversalQuery(
                        seeds: graphSeeds,
                        direction: direction,
                        limits: traversalLimits
                    )
                )
            }

            var traversalResult: WorkspaceCodemapStructureTraversalResult?
            switch disposition {
            case let .readyPartial(result):
                traversalResult = result
            case let .budget(result, reason):
                traversalResult = result
                traversalBudgetHit = true
                issues.append(.traversalBudget(reason))
            case let .pending(reason):
                issues.append(.traversalPending(reason))
            case let .unavailable(reason):
                issues.append(.traversalUnavailable(reason))
            case let .stale(reason):
                return WorkspaceCodemapStructureAttempt(
                    presentation: emptyStructurePresentation(
                        outcome: .stale,
                        issues: [.traversalStale(reason)],
                        requestedSeedCount: seedFileIDs.count,
                        resolvedSeedCount: graphSeeds.count
                    ),
                    receipt: nil,
                    staleReason: .traversal(reason)
                )
            case .cancelled:
                throw CancellationError()
            }

            if let traversalResult {
                traversalReceipt = traversalResult.publicationReceipt
                examinedEdgeCount = traversalResult.examinedEdgeCount
                issues.append(
                    contentsOf: traversalResult.partialReasons
                        .sorted { stableIssueKey($0) < stableIssueKey($1) }
                        .map(WorkspaceCodemapStructureIssue.traversalPartial)
                )
                provenanceByFileID = Dictionary(uniqueKeysWithValues: traversalResult.nodes.map {
                    ($0.fileID, ($0.depth, $0.reachedBy))
                })

                let targetIDs = traversalResult.nodes.filter { $0.depth > 0 }.map(\.fileID)
                if !targetIDs.isEmpty {
                    let targetDemand = try await demand(
                        fileIDs: targetIDs,
                        priority: .background,
                        ownership: ownership,
                        clock: clock,
                        deadline: deadline
                    )
                    for fileID in targetIDs {
                        guard let result = targetDemand.resultsByFileID[fileID] else { continue }
                        switch result {
                        case let .ready(ready):
                            readyTicketsByFileID[fileID] = ready.ticket
                        case let .pending(ticket):
                            issues.append(.artifactPending(fileID: fileID, ticket: ticket))
                        case .unavailable(.cancelled):
                            throw CancellationError()
                        case .unavailable(.staleCurrentness):
                            let ticket = await ownership.tickets().first { $0.fileID == fileID }
                            let reason: WorkspaceCodemapStructurePublicationStaleReason = if let ticket {
                                .presentation(.demand(ticket))
                            } else {
                                .presentation(.catalog(fileID: fileID))
                            }
                            return WorkspaceCodemapStructureAttempt(
                                presentation: emptyStructurePresentation(
                                    outcome: .stale,
                                    issues: [],
                                    requestedSeedCount: seedFileIDs.count,
                                    resolvedSeedCount: graphSeeds.count
                                ),
                                receipt: nil,
                                staleReason: reason
                            )
                        case let .unavailable(reason):
                            issues.append(.artifactUnavailable(fileID: fileID, reason: reason))
                        }
                    }

                    let revalidated = await store.queryCodemapStructureGraph(
                        WorkspaceCodemapStructureTraversalQuery(
                            seeds: graphSeeds,
                            direction: direction,
                            limits: traversalLimits
                        )
                    )
                    switch revalidated {
                    case let .readyPartial(result):
                        traversalReceipt = result.publicationReceipt
                        examinedEdgeCount = result.examinedEdgeCount
                        provenanceByFileID = Dictionary(uniqueKeysWithValues: result.nodes.map {
                            ($0.fileID, ($0.depth, $0.reachedBy))
                        })
                    case let .budget(result?, reason):
                        traversalBudgetHit = true
                        issues.append(.traversalBudget(reason))
                        traversalReceipt = result.publicationReceipt
                        examinedEdgeCount = result.examinedEdgeCount
                        provenanceByFileID = Dictionary(uniqueKeysWithValues: result.nodes.map {
                            ($0.fileID, ($0.depth, $0.reachedBy))
                        })
                    case let .stale(reason):
                        return WorkspaceCodemapStructureAttempt(
                            presentation: emptyStructurePresentation(
                                outcome: .stale,
                                issues: [.traversalStale(reason)],
                                requestedSeedCount: seedFileIDs.count,
                                resolvedSeedCount: graphSeeds.count
                            ),
                            receipt: nil,
                            staleReason: .traversal(reason)
                        )
                    case .cancelled:
                        throw CancellationError()
                    case let .pending(reason):
                        issues.append(.traversalPending(reason))
                    case let .unavailable(reason):
                        issues.append(.traversalUnavailable(reason))
                    case let .budget(nil, reason):
                        traversalBudgetHit = true
                        issues.append(.traversalBudget(reason))
                    }
                }
            }
        }

        let seedSet = Set(graphSeeds.map(\.ticket.fileID))
        let candidateCollection = await store.codemapOperationPresentationCandidates(
            forFileIDs: Array(provenanceByFileID.keys),
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        issues.append(contentsOf: candidateCollection.issues.map(WorkspaceCodemapStructureIssue.candidate))
        var orderedCandidates = candidateCollection.candidates.filter {
            readyTicketsByFileID[$0.fileID] != nil
        }
        orderedCandidates.sort { lhs, rhs in
            let lhsSeed = seedSet.contains(lhs.fileID)
            let rhsSeed = seedSet.contains(rhs.fileID)
            if lhsSeed != rhsSeed { return lhsSeed }
            let lhsDepth = provenanceByFileID[lhs.fileID]?.depth ?? .max
            let rhsDepth = provenanceByFileID[rhs.fileID]?.depth ?? .max
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            if lhs.logicalPath.displayPath != rhs.logicalPath.displayPath {
                return lhs.logicalPath.displayPath.utf8.lexicographicallyPrecedes(
                    rhs.logicalPath.displayPath.utf8
                )
            }
            return lhs.fileID.uuidString < rhs.fileID.uuidString
        }
        if orderedCandidates.count > outputLimits.maximumFileCount {
            issues.append(.fileLimit(
                attempted: orderedCandidates.count,
                limit: outputLimits.maximumFileCount
            ))
            orderedCandidates = Array(orderedCandidates.prefix(outputLimits.maximumFileCount))
        }

        var requestsByRoot: [WorkspaceCodemapRootEpoch: [WorkspaceCodemapPresentationRequest]] = [:]
        for candidate in orderedCandidates {
            guard let ticket = readyTicketsByFileID[candidate.fileID] else { continue }
            requestsByRoot[candidate.rootEpoch, default: []].append(
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: candidate.logicalPath)
            )
        }
        var renderedByFileID: [UUID: WorkspaceCodemapOperationRenderedEntry] = [:]
        var bundleReceipts: [WorkspaceCodemapOperationPresentationBundleReceipt] = []
        for rootEpoch in requestsByRoot.keys.sorted(by: rootEpochPrecedes) {
            try Task.checkCancellation()
            switch await store.freezeCodemapPresentation(requestsByRoot[rootEpoch] ?? []) {
            case let .unavailable(reason):
                issues.append(.freezeUnavailable(rootEpoch: rootEpoch, reason: reason))
            case let .ready(bundle):
                await ownership.record(bundle)
                switch await store.renderCodemapPresentation(bundle) {
                case let .unavailable(reason):
                    issues.append(.renderUnavailable(rootEpoch: rootEpoch, reason: reason))
                case let .ready(rendered):
                    bundleReceipts.append(.init(
                        bundleID: bundle.id,
                        rootEpoch: bundle.rootEpoch,
                        entries: bundle.entries
                    ))
                    for entry in rendered {
                        renderedByFileID[entry.ticket.fileID] = WorkspaceCodemapOperationRenderedEntry(
                            bundleID: bundle.id,
                            fileID: entry.ticket.fileID,
                            rootEpoch: entry.ticket.rootEpoch,
                            artifactKey: entry.artifactKey,
                            logicalPath: entry.logicalPath,
                            text: entry.text,
                            tokenCount: entry.tokenCount
                        )
                    }
                }
            }
        }

        let separatorTokens = TokenCalculationService.estimateTokens(for: "\n\n")
        var structureEntries: [WorkspaceCodemapStructureRenderedEntry] = []
        var usedTokens = 0
        for candidate in orderedCandidates {
            guard let entry = renderedByFileID[candidate.fileID] else { continue }
            let cost = entry.tokenCount + (structureEntries.isEmpty ? 0 : separatorTokens)
            let (attempted, overflow) = usedTokens.addingReportingOverflow(cost)
            guard !overflow, attempted <= outputLimits.maximumCodemapTokenCount else {
                issues.append(.tokenLimit(
                    path: candidate.logicalPath.displayPath,
                    attempted: overflow ? .max : attempted,
                    limit: outputLimits.maximumCodemapTokenCount
                ))
                break
            }
            usedTokens = attempted
            let provenance = provenanceByFileID[candidate.fileID] ?? (0, [])
            structureEntries.append(.init(
                entry: entry,
                isSeed: seedSet.contains(candidate.fileID),
                depth: provenance.depth,
                reachedBy: provenance.reachedBy
            ))
        }

        let outputFileIDs = structureEntries.map(\.entry.fileID)
        let outputSet = Set(outputFileIDs)
        let receiptCandidates = orderedCandidates.filter { outputSet.contains($0.fileID) }
        let validatedLogicalRootDisplayNames = Dictionary(
            receiptCandidates.map { ($0.rootEpoch.rootID, $0.logicalPath.rootDisplayName) },
            uniquingKeysWith: { current, _ in current }
        )
        let publishedBundleReceipts = bundleReceipts.compactMap { bundle -> WorkspaceCodemapOperationPresentationBundleReceipt? in
            let publishedEntries = bundle.entries.filter { outputSet.contains($0.ticket.fileID) }
            guard !publishedEntries.isEmpty else { return nil }
            return WorkspaceCodemapOperationPresentationBundleReceipt(
                bundleID: bundle.bundleID,
                rootEpoch: bundle.rootEpoch,
                entries: publishedEntries
            )
        }
        let presentationReceipt = WorkspaceCodemapOperationPresentationPublicationReceipt(
            requestID: UUID(),
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: validatedLogicalRootDisplayNames,
            completeRootSet: false,
            completeRootCatalogs: [],
            candidates: receiptCandidates,
            demandTickets: publicationTickets(
                from: publishedBundleReceipts,
                publishedFileIDs: outputSet
            ),
            bundles: publishedBundleReceipts,
            automaticReceipt: nil
        )
        let receipt = WorkspaceCodemapStructurePublicationReceipt(
            presentation: presentationReceipt,
            traversal: traversalReceipt,
            outputFileIDs: outputFileIDs
        )
        issues.sort { stableIssueKey($0) < stableIssueKey($1) }
        let budgetHit = traversalBudgetHit || issues.contains(where: {
            switch $0 {
            case .fileLimit, .seedDemandLimit, .tokenLimit, .traversalBudget: true
            default: false
            }
        })
        let outcome: WorkspaceCodemapStructureOutcome = if budgetHit {
            .budget
        } else if issues.isEmpty {
            .ready
        } else if !structureEntries.isEmpty {
            .partial
        } else if issues.contains(where: {
            switch $0 {
            case .artifactPending, .traversalPending: true
            default: false
            }
        }) {
            .pending
        } else {
            .unavailable
        }
        return WorkspaceCodemapStructureAttempt(
            presentation: WorkspaceCodemapStructurePresentation(
                outcome: outcome,
                entries: structureEntries,
                issues: issues,
                requestedSeedCount: seedFileIDs.count,
                resolvedSeedCount: graphSeeds.count,
                examinedEdgeCount: examinedEdgeCount,
                codemapTokenCount: usedTokens
            ),
            receipt: receipt,
            staleReason: nil
        )
    }

    private func emptyStructurePresentation(
        outcome: WorkspaceCodemapStructureOutcome,
        issues: [WorkspaceCodemapStructureIssue],
        requestedSeedCount: Int,
        resolvedSeedCount: Int
    ) -> WorkspaceCodemapStructurePresentation {
        WorkspaceCodemapStructurePresentation(
            outcome: outcome,
            entries: [],
            issues: issues,
            requestedSeedCount: requestedSeedCount,
            resolvedSeedCount: resolvedSeedCount,
            examinedEdgeCount: 0,
            codemapTokenCount: 0
        )
    }
}
