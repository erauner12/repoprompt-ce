import Foundation

private final class GitWorkspaceAuthoritySynchronousState: @unchecked Sendable {
    private struct RepositoryState {
        let invalidationGeneration: UInt64
        let mutationDepth: Int
        let monitorCoverageUnavailable: Bool
        let publicationGenerations: [GitWorkspaceAuthorityScopeKey: UInt64]
    }

    private let lock = NSLock()
    private var repositories: [GitWorkspaceAuthorityRepositoryKey: RepositoryState] = [:]

    func update(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        invalidationGeneration: UInt64,
        mutationDepth: Int,
        monitorCoverageUnavailable: Bool,
        publicationGenerations: [GitWorkspaceAuthorityScopeKey: UInt64]
    ) {
        lock.lock()
        repositories[repositoryKey] = RepositoryState(
            invalidationGeneration: invalidationGeneration,
            mutationDepth: mutationDepth,
            monitorCoverageUnavailable: monitorCoverageUnavailable,
            publicationGenerations: publicationGenerations
        )
        lock.unlock()
    }

    func isCurrent(_ fence: GitWorkspacePendingInitializationAuthorityFence) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return matches(fence)
    }

    func withCurrentFences<T>(
        _ fences: [GitWorkspacePendingInitializationAuthorityFence],
        _ body: () -> T?
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard fences.allSatisfy(matches) else { return nil }
        return body()
    }

    private func matches(_ fence: GitWorkspacePendingInitializationAuthorityFence) -> Bool {
        guard let state = repositories[fence.repositoryKey] else { return false }
        return state.invalidationGeneration == fence.lease.invalidationGeneration
            && state.mutationDepth == 0
            && !state.monitorCoverageUnavailable
            && state.publicationGenerations[fence.lease.scopeKey] == fence.lease.authorityGeneration
    }
}

/// Owns currentness and metadata observation for worktree bootstrap. Collection
/// is always bracketed by a scope-bound capture token and conditional install;
/// reusable snapshot storage/eviction is bounded and remains observation-only.
actor GitWorkspaceStateAuthority {
    static let shared = GitWorkspaceStateAuthority()

    #if DEBUG
        struct Snapshot: Equatable {
            let recordCount: Int
            let publishedScopeCount: Int
            let activeMutationCount: Int
            let metadataEventCount: Int
            let authorityGenerations: [GitWorkspaceAuthorityRepositoryKey: UInt64]
            let reusableSnapshotCount: Int
            let reusableSnapshotAliasCount: Int
            let reusableSnapshotEstimatedBytes: Int
            let reusableSnapshotArtifactBytes: UInt64
            let pendingReusableSnapshotAdmissionCount: Int
            let pendingReusableSnapshotArtifactBytes: UInt64
            let reusableSnapshotArtifactBudgetRejectionCount: UInt64
            let invalidationSubscriberCount: Int
        }
    #endif

    private struct Record {
        var invalidationGeneration: UInt64 = 0
        var mutationDepth: Int = 0
        var metadataEventCount: Int = 0
        var monitorCoverageUnavailable = false
        var snapshotsByScope: [GitWorkspaceAuthorityScopeKey: GitWorkspaceAuthoritySnapshot] = [:]
        var publicationGenerationByScope: [GitWorkspaceAuthorityScopeKey: UInt64] = [:]
        var acceptedWatermarkByScope: [GitWorkspaceAuthorityScopeKey: UInt64] = [:]
    }

    private struct ReusableSnapshotCacheEntry {
        let snapshot: WorkspaceRootReusableSnapshot
        var lastAccessOrdinal: UInt64
    }

    private struct ReusableSnapshotAlias {
        let admissionID: UUID
        let lease: GitWorkspaceAuthorityLease
        let snapshotIdentity: WorkspaceRootReusableSnapshotIdentity
        let observationToken: GitWorkspaceMetadataMonitor.RetainToken
    }

    struct PreparedReusableSnapshotAdmission: Hashable {
        fileprivate let id: UUID
    }

    struct ReusableSnapshotAdmissionReceipt: Hashable {
        fileprivate let id: UUID
        let snapshotIdentity: WorkspaceRootReusableSnapshotIdentity
    }

    private struct PendingReusableSnapshotAdmission {
        let snapshot: WorkspaceRootReusableSnapshot
        let lease: GitWorkspaceAuthorityLease
        let observationToken: GitWorkspaceMetadataMonitor.RetainToken
        let reservedArtifactBytes: UInt64
    }

    private let metadataMonitor: GitWorkspaceMetadataMonitor
    private nonisolated let synchronousState = GitWorkspaceAuthoritySynchronousState()
    private let reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits
    private var records: [GitWorkspaceAuthorityRepositoryKey: Record] = [:]
    private var activeMutations: [UUID: GitWorkspaceMutationToken] = [:]
    private var reusableSnapshotsByIdentity: [WorkspaceRootReusableSnapshotIdentity: ReusableSnapshotCacheEntry] = [:]
    private var reusableSnapshotAliasesByScope: [GitWorkspaceAuthorityScopeKey: ReusableSnapshotAlias] = [:]
    private var pendingReusableSnapshotAdmissions: [UUID: PendingReusableSnapshotAdmission] = [:]
    private var reusableSnapshotAccessOrdinal: UInt64 = 0
    private var reusableSnapshotEstimatedBytes = 0
    private var reusableSnapshotArtifactBytes: UInt64 = 0
    private var pendingReusableSnapshotArtifactBytes: UInt64 = 0
    private var reusableSnapshotArtifactBudgetRejectionCount: UInt64 = 0
    private var invalidationContinuations: [UUID: AsyncStream<GitWorkspaceAuthorityInvalidationEvent>.Continuation] = [:]

    init(
        metadataMonitor: GitWorkspaceMetadataMonitor = GitWorkspaceMetadataMonitor(),
        reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits = .production
    ) {
        precondition(reusableSnapshotCacheLimits.maximumSnapshotCount > 0)
        precondition(reusableSnapshotCacheLimits.maximumSnapshotsPerRepository > 0)
        precondition(reusableSnapshotCacheLimits.maximumEstimatedBytes > 0)
        precondition(reusableSnapshotCacheLimits.maximumArtifactBytes > 0)
        self.metadataMonitor = metadataMonitor
        self.reusableSnapshotCacheLimits = reusableSnapshotCacheLimits
    }

    func collectionMutationFenceReason(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey
    ) -> GitWorkspaceAuthorityUnavailableReason? {
        let record = records[repositoryKey]
        return hasActiveMutation(for: repositoryKey) || (record?.mutationDepth ?? 0) > 0
            ? .mutationInProgress
            : nil
    }

    func beginCollection(
        scopeKey: GitWorkspaceAuthorityScopeKey
    ) -> Result<GitWorkspaceAuthorityCaptureToken, GitWorkspaceAuthorityUnavailableReason> {
        let record = records[scopeKey.repositoryKey] ?? Record()
        guard !hasActiveMutation(for: scopeKey.repositoryKey),
              record.mutationDepth == 0
        else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        records[scopeKey.repositoryKey] = record
        updateSynchronousState(repositoryKey: scopeKey.repositoryKey, record: record)
        return .success(GitWorkspaceAuthorityCaptureToken(
            scopeKey: scopeKey,
            invalidationGeneration: record.invalidationGeneration,
            scopePublicationGeneration: record.publicationGenerationByScope[scopeKey] ?? 0,
            acceptedMetadataWatermark: metadataMonitor.acceptedWatermark(for: scopeKey.repositoryKey)
        ))
    }

    func collectAndInstall(
        scopeKey: GitWorkspaceAuthorityScopeKey,
        collector: @Sendable () async throws -> GitWorkspaceAuthoritySnapshot
    ) async throws -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let token: GitWorkspaceAuthorityCaptureToken
        switch beginCollection(scopeKey: scopeKey) {
        case let .success(value): token = value
        case let .failure(reason): return .failure(reason)
        }
        let snapshot = try await collector()
        return install(snapshot, capturedUsing: token)
    }

    @discardableResult
    func install(
        _ snapshot: GitWorkspaceAuthoritySnapshot,
        capturedUsing token: GitWorkspaceAuthorityCaptureToken
    ) -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: snapshot.repositoryKey,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix
        )
        guard scopeKey == token.scopeKey else { return .failure(.collectionScopeMismatch) }
        guard var record = records[scopeKey.repositoryKey] else {
            return .failure(.invalidatedDuringCollection)
        }
        guard !hasActiveMutation(for: scopeKey.repositoryKey),
              record.mutationDepth == 0
        else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        guard record.invalidationGeneration == token.invalidationGeneration,
              (record.publicationGenerationByScope[scopeKey] ?? 0) == token.scopePublicationGeneration,
              metadataMonitor.acceptedWatermark(for: scopeKey.repositoryKey) == token.acceptedMetadataWatermark
        else {
            return .failure(.invalidatedDuringCollection)
        }

        let lease = metadataMonitor.withCurrentAcceptedWatermark(
            for: scopeKey.repositoryKey,
            expected: token.acceptedMetadataWatermark
        ) {
            let publicationGeneration = token.scopePublicationGeneration &+ 1
            record.publicationGenerationByScope[scopeKey] = publicationGeneration
            record.snapshotsByScope[scopeKey] = snapshot
            record.acceptedWatermarkByScope[scopeKey] = token.acceptedMetadataWatermark
            records[scopeKey.repositoryKey] = record
            updateSynchronousState(repositoryKey: scopeKey.repositoryKey, record: record)
            return GitWorkspaceAuthorityLease(
                scopeKey: scopeKey,
                authorityGeneration: publicationGeneration,
                invalidationGeneration: record.invalidationGeneration,
                acceptedMetadataWatermark: token.acceptedMetadataWatermark,
                snapshot: snapshot
            )
        }
        guard let lease else { return .failure(.invalidatedDuringCollection) }
        return .success(lease)
    }

    /// Test/support convenience for an already collected immutable value. There
    /// is no suspension between token issue and conditional installation.
    @discardableResult
    func install(_ snapshot: GitWorkspaceAuthoritySnapshot) throws -> GitWorkspaceAuthorityLease {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: snapshot.repositoryKey,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix
        )
        let token: GitWorkspaceAuthorityCaptureToken
        switch beginCollection(scopeKey: scopeKey) {
        case let .success(value): token = value
        case let .failure(reason): throw reason
        }
        switch install(snapshot, capturedUsing: token) {
        case let .success(lease): return lease
        case let .failure(reason): throw reason
        }
    }

    func currentLease(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: repositoryKey,
            repositoryRelativeRootPrefix: prefix
        )
        guard let record = records[repositoryKey] else { return .failure(.noSnapshot) }
        guard !hasActiveMutation(for: scopeKey.repositoryKey),
              record.mutationDepth == 0
        else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        guard let snapshot = record.snapshotsByScope[scopeKey] else { return .failure(.metadataEventPending) }
        let watermark = metadataMonitor.acceptedWatermark(for: repositoryKey)
        guard record.acceptedWatermarkByScope[scopeKey] == watermark else {
            return .failure(.invalidatedDuringCollection)
        }
        return .success(GitWorkspaceAuthorityLease(
            scopeKey: scopeKey,
            authorityGeneration: record.publicationGenerationByScope[scopeKey] ?? 0,
            invalidationGeneration: record.invalidationGeneration,
            acceptedMetadataWatermark: watermark,
            snapshot: snapshot
        ))
    }

    func isCurrent(_ lease: GitWorkspaceAuthorityLease) -> Bool {
        guard let record = records[lease.repositoryKey] else { return false }
        return !hasActiveMutation(for: lease.repositoryKey)
            && record.mutationDepth == 0
            && !record.monitorCoverageUnavailable
            && record.invalidationGeneration == lease.invalidationGeneration
            && record.publicationGenerationByScope[lease.scopeKey] == lease.authorityGeneration
            && record.snapshotsByScope[lease.scopeKey] == lease.snapshot
            && record.acceptedWatermarkByScope[lease.scopeKey] == lease.acceptedMetadataWatermark
            && metadataMonitor.acceptedWatermark(for: lease.repositoryKey) == lease.acceptedMetadataWatermark
    }

    /// Retains no paths and performs no polling. Events are path-free wakeups;
    /// the accepted watermark and lease remain the authority for currentness.
    func invalidationEvents() -> AsyncStream<GitWorkspaceAuthorityInvalidationEvent> {
        let subscriptionID = UUID()
        return AsyncStream { continuation in
            invalidationContinuations[subscriptionID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeInvalidationContinuation(subscriptionID) }
            }
        }
    }

    func pendingInitializationFenceDecision(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) async -> GitWorkspacePendingAuthorityFenceDecision {
        if await pendingInitializationAuthorityFenceIsCurrent(fence) {
            return .current
        }
        guard !fence.revalidationUsed else { return .fallback }
        return .revalidationRequired(
            latestAcceptedMetadataWatermark: metadataMonitor.acceptedWatermark(for: fence.repositoryKey)
        )
    }

    func pendingInitializationAuthorityFenceIsCurrent(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) async -> Bool {
        guard fence.snapshot == fence.lease.snapshot,
              fence.acceptedMetadataWatermark == fence.lease.acceptedMetadataWatermark,
              fence.repositoryKey == GitWorkspaceAuthorityRepositoryKey(layout: fence.targetLayout),
              fence.repositoryRelativeRootPrefix == fence.lease.scopeKey.repositoryRelativeRootPrefix,
              fence.repositoryRelativeRootPrefix == fence.snapshot.repositoryRelativeRootPrefix,
              isCurrent(fence.lease),
              metadataMonitor.acceptedWatermarkIsCurrent(
                  for: fence.repositoryKey,
                  expected: fence.acceptedMetadataWatermark
              )
        else { return false }
        guard await metadataObservationIsCurrent(
            fence.metadataObservationToken,
            for: fence.targetLayout,
            additionalAuthorityPaths: fence.additionalAuthorityPaths,
            expectedAcceptedWatermark: fence.acceptedMetadataWatermark
        ) else { return false }
        // The monitor actor hop above is an await boundary. Reprove both actor
        // generation and callback-accepted watermark after resumption.
        return isCurrent(fence.lease)
            && metadataMonitor.acceptedWatermarkIsCurrent(
                for: fence.repositoryKey,
                expected: fence.acceptedMetadataWatermark
            )
    }

    nonisolated func pendingInitializationAuthorityFenceIsSynchronouslyCurrent(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) -> Bool {
        guard synchronousState.isCurrent(fence) else { return false }
        guard metadataMonitor.acceptedWatermarkIsCurrent(
            for: fence.repositoryKey,
            expected: fence.acceptedMetadataWatermark
        ) else { return false }
        // Recheck the actor-owned generation mirror after the watermark read so
        // mutation begin and metadata callback acceptance cannot straddle this proof.
        return synchronousState.isCurrent(fence)
    }

    /// Serializes the pending-to-published store commit with both mutation
    /// invalidation and callback-accepted Git metadata watermarks. An
    /// invalidation that wins the permit makes publication fail; one that
    /// arrives afterward is necessarily a published-root reconciliation.
    nonisolated func withPendingInitializationAuthorityPublicationPermit<T>(
        _ fences: [GitWorkspacePendingInitializationAuthorityFence],
        _ body: () -> T
    ) -> T? {
        var expectedWatermarks: [GitWorkspaceAuthorityRepositoryKey: UInt64] = [:]
        for fence in fences {
            if let existing = expectedWatermarks[fence.repositoryKey],
               existing != fence.acceptedMetadataWatermark
            {
                return nil
            }
            expectedWatermarks[fence.repositoryKey] = fence.acceptedMetadataWatermark
        }
        return synchronousState.withCurrentFences(fences) {
            metadataMonitor.withCurrentAcceptedWatermarks(expectedWatermarks, body)
        }
    }

    func releasePendingInitializationAuthorityFence(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) async {
        await retireEphemeralAuthorityLease(
            fence.lease,
            observationToken: fence.metadataObservationToken
        )
    }

    @discardableResult
    func admitReusableSnapshot(
        _ snapshot: WorkspaceRootReusableSnapshot,
        capturedUsing lease: GitWorkspaceAuthorityLease,
        observationToken: GitWorkspaceMetadataMonitor.RetainToken
    ) async -> Bool {
        guard let prepared = await prepareReusableSnapshotAdmission(
            snapshot,
            capturedUsing: lease,
            observationToken: observationToken
        ) else { return false }
        return await admitPreparedReusableSnapshot(prepared) != nil
    }

    func prepareReusableSnapshotAdmission(
        _ snapshot: WorkspaceRootReusableSnapshot,
        capturedUsing lease: GitWorkspaceAuthorityLease,
        observationToken: GitWorkspaceMetadataMonitor.RetainToken
    ) async -> PreparedReusableSnapshotAdmission? {
        guard isCurrent(lease),
              snapshot.hasValidContentAddress(),
              snapshot.compatibilityKey == WorkspaceRootSeedCompatibilityKey(authority: lease.snapshot),
              snapshot.estimatedByteCount <= reusableSnapshotCacheLimits.maximumEstimatedBytes
        else {
            await metadataMonitor.release(observationToken)
            return nil
        }

        let (retainedAndPendingBytes, retainedAndPendingOverflow) = reusableSnapshotArtifactBytes
            .addingReportingOverflow(pendingReusableSnapshotArtifactBytes)
        let (reservedTotal, reservationOverflow) = retainedAndPendingBytes
            .addingReportingOverflow(snapshot.artifactByteCount)
        guard !retainedAndPendingOverflow,
              !reservationOverflow,
              snapshot.artifactByteCount <= reusableSnapshotCacheLimits.maximumArtifactBytes,
              reservedTotal <= reusableSnapshotCacheLimits.maximumArtifactBytes
        else {
            reusableSnapshotArtifactBudgetRejectionCount &+= 1
            await metadataMonitor.release(observationToken)
            return nil
        }

        let prepared = PreparedReusableSnapshotAdmission(id: UUID())
        pendingReusableSnapshotArtifactBytes += snapshot.artifactByteCount
        pendingReusableSnapshotAdmissions[prepared.id] = PendingReusableSnapshotAdmission(
            snapshot: snapshot,
            lease: lease,
            observationToken: observationToken,
            reservedArtifactBytes: snapshot.artifactByteCount
        )
        return prepared
    }

    func preparedReusableSnapshotAdmissionIsCurrent(
        _ prepared: PreparedReusableSnapshotAdmission
    ) -> Bool {
        guard let pending = pendingReusableSnapshotAdmissions[prepared.id] else { return false }
        return isCurrent(pending.lease)
    }

    func cancelPreparedReusableSnapshotAdmission(
        _ prepared: PreparedReusableSnapshotAdmission
    ) async {
        guard let pending = takePendingReusableSnapshotAdmission(prepared) else { return }
        await metadataMonitor.release(pending.observationToken)
    }

    func admitPreparedReusableSnapshot(
        _ prepared: PreparedReusableSnapshotAdmission
    ) async -> ReusableSnapshotAdmissionReceipt? {
        guard let pending = takePendingReusableSnapshotAdmission(prepared) else { return nil }
        let snapshot = pending.snapshot
        let lease = pending.lease
        let observationToken = pending.observationToken
        guard isCurrent(lease),
              snapshot.hasValidContentAddress(),
              snapshot.compatibilityKey == WorkspaceRootSeedCompatibilityKey(authority: lease.snapshot)
        else {
            await metadataMonitor.release(observationToken)
            return nil
        }

        reusableSnapshotAccessOrdinal &+= 1
        if var existing = reusableSnapshotsByIdentity[snapshot.identity] {
            guard existing.snapshot.compatibilityKey == snapshot.compatibilityKey,
                  existing.snapshot.inventoryManifest.manifestDigest
                  == snapshot.inventoryManifest.manifestDigest,
                  existing.snapshot.inventoryManifest.footer == snapshot.inventoryManifest.footer,
                  existing.snapshot.hasValidContentAddress()
            else {
                await metadataMonitor.release(observationToken)
                return nil
            }
            existing.lastAccessOrdinal = reusableSnapshotAccessOrdinal
            reusableSnapshotsByIdentity[snapshot.identity] = existing
        } else {
            reusableSnapshotsByIdentity[snapshot.identity] = ReusableSnapshotCacheEntry(
                snapshot: snapshot,
                lastAccessOrdinal: reusableSnapshotAccessOrdinal
            )
            reusableSnapshotEstimatedBytes += snapshot.estimatedByteCount
            reusableSnapshotArtifactBytes += snapshot.artifactByteCount
        }

        let previous = reusableSnapshotAliasesByScope.updateValue(
            ReusableSnapshotAlias(
                admissionID: prepared.id,
                lease: lease,
                snapshotIdentity: snapshot.identity,
                observationToken: observationToken
            ),
            forKey: lease.scopeKey
        )
        let retained = await evictReusableSnapshotsIfNeeded()
        guard retained,
              reusableSnapshotsByIdentity[snapshot.identity] != nil
        else {
            if let previous {
                reusableSnapshotAliasesByScope[lease.scopeKey] = previous
            } else {
                reusableSnapshotAliasesByScope.removeValue(forKey: lease.scopeKey)
            }
            if reusableSnapshotAliasesByScope.values.contains(where: { $0.snapshotIdentity == snapshot.identity }) == false {
                removeUnaliasedReusableSnapshot(snapshot.identity)
            }
            await metadataMonitor.release(observationToken)
            return nil
        }
        if let previous {
            await metadataMonitor.release(previous.observationToken)
        }
        return ReusableSnapshotAdmissionReceipt(
            id: prepared.id,
            snapshotIdentity: snapshot.identity
        )
    }

    func reusableSnapshotAdmissionIsCurrent(
        _ receipt: ReusableSnapshotAdmissionReceipt
    ) -> Bool {
        guard let alias = reusableSnapshotAliasesByScope.values.first(where: { $0.admissionID == receipt.id }) else {
            return false
        }
        return alias.snapshotIdentity == receipt.snapshotIdentity && isCurrent(alias.lease)
    }

    func revokeReusableSnapshotAdmission(
        _ receipt: ReusableSnapshotAdmissionReceipt
    ) async {
        guard let (scopeKey, alias) = reusableSnapshotAliasesByScope.first(where: { $0.value.admissionID == receipt.id }) else {
            return
        }
        reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
        removeUnaliasedReusableSnapshot(receipt.snapshotIdentity)
        await metadataMonitor.release(alias.observationToken)
    }

    func revokeReusableSnapshotAdmissions(
        snapshotIdentity: WorkspaceRootReusableSnapshotIdentity
    ) async {
        let aliases = reusableSnapshotAliasesByScope.filter { $0.value.snapshotIdentity == snapshotIdentity }
        for (scopeKey, alias) in aliases {
            reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
            await metadataMonitor.release(alias.observationToken)
        }
        removeUnaliasedReusableSnapshot(snapshotIdentity)
    }

    func currentReusableSnapshot(
        capturedUsing lease: GitWorkspaceAuthorityLease
    ) async -> WorkspaceRootReusableSnapshot? {
        guard isCurrent(lease),
              let alias = reusableSnapshotAliasesByScope[lease.scopeKey],
              alias.lease == lease,
              var entry = reusableSnapshotsByIdentity[alias.snapshotIdentity],
              entry.snapshot.hasValidContentAddress(),
              entry.snapshot.compatibilityKey == WorkspaceRootSeedCompatibilityKey(authority: lease.snapshot)
        else {
            if let alias = reusableSnapshotAliasesByScope[lease.scopeKey],
               alias.lease == lease
            {
                reusableSnapshotAliasesByScope.removeValue(forKey: lease.scopeKey)
                await metadataMonitor.release(alias.observationToken)
            }
            return nil
        }
        reusableSnapshotAccessOrdinal &+= 1
        entry.lastAccessOrdinal = reusableSnapshotAccessOrdinal
        reusableSnapshotsByIdentity[alias.snapshotIdentity] = entry
        return entry.snapshot
    }

    func reusableSnapshot(
        compatibleWith snapshot: GitWorkspaceAuthoritySnapshot
    ) -> WorkspaceRootReusableSnapshot? {
        let key = WorkspaceRootSeedCompatibilityKey(authority: snapshot)
        guard let identity = reusableSnapshotsByIdentity.first(where: {
            $0.value.snapshot.compatibilityKey == key && $0.value.snapshot.hasValidContentAddress()
        })?.key else { return nil }
        reusableSnapshotAccessOrdinal &+= 1
        reusableSnapshotsByIdentity[identity]?.lastAccessOrdinal = reusableSnapshotAccessOrdinal
        return reusableSnapshotsByIdentity[identity]?.snapshot
    }

    func reusableSnapshot(
        identity: WorkspaceRootReusableSnapshotIdentity,
        expectedCompatibilityKey: WorkspaceRootSeedCompatibilityKey
    ) -> WorkspaceRootReusableSnapshot? {
        guard identity.searchABI == .current,
              var entry = reusableSnapshotsByIdentity[identity],
              entry.snapshot.compatibilityKey == expectedCompatibilityKey,
              entry.snapshot.hasValidContentAddress()
        else { return nil }
        reusableSnapshotAccessOrdinal &+= 1
        entry.lastAccessOrdinal = reusableSnapshotAccessOrdinal
        reusableSnapshotsByIdentity[identity] = entry
        return entry.snapshot
    }

    private func evictReusableSnapshotsIfNeeded() async -> Bool {
        while reusableSnapshotsByIdentity.count > reusableSnapshotCacheLimits.maximumSnapshotCount
            || reusableSnapshotEstimatedBytes > reusableSnapshotCacheLimits.maximumEstimatedBytes
            || reusableSnapshotArtifactBytes > reusableSnapshotCacheLimits.maximumArtifactBytes
            || repositorySnapshotCountExceedsLimit()
        {
            let pinnedIdentities = Set(reusableSnapshotAliasesByScope.values.map(\.snapshotIdentity))
            let overfullNamespaces = repositorySnapshotCounts()
                .filter { $0.value > reusableSnapshotCacheLimits.maximumSnapshotsPerRepository }
                .map(\.key)
            let candidates = reusableSnapshotsByIdentity.filter { identity, entry in
                !pinnedIdentities.contains(identity)
                    && (
                        overfullNamespaces.isEmpty
                            || overfullNamespaces.contains(entry.snapshot.compatibilityKey.repositoryNamespace)
                    )
            }
            guard let candidate = candidates.min(by: {
                $0.value.lastAccessOrdinal < $1.value.lastAccessOrdinal
            }) else { return false }
            removeUnaliasedReusableSnapshot(candidate.key)
        }
        return true
    }

    private func repositorySnapshotCountExceedsLimit() -> Bool {
        repositorySnapshotCounts().values.contains {
            $0 > reusableSnapshotCacheLimits.maximumSnapshotsPerRepository
        }
    }

    private func repositorySnapshotCounts() -> [GitBlobRepositoryNamespace: Int] {
        Dictionary(grouping: reusableSnapshotsByIdentity.values) {
            $0.snapshot.compatibilityKey.repositoryNamespace
        }.mapValues(\.count)
    }

    private func removeReusableSnapshot(_ identity: WorkspaceRootReusableSnapshotIdentity) async {
        guard let removed = reusableSnapshotsByIdentity.removeValue(forKey: identity) else { return }
        reusableSnapshotEstimatedBytes = max(0, reusableSnapshotEstimatedBytes - removed.snapshot.estimatedByteCount)
        reusableSnapshotArtifactBytes = reusableSnapshotArtifactBytes >= removed.snapshot.artifactByteCount
            ? reusableSnapshotArtifactBytes - removed.snapshot.artifactByteCount
            : 0
        let aliases = reusableSnapshotAliasesByScope.filter { $0.value.snapshotIdentity == identity }
        for (scopeKey, alias) in aliases {
            reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
            await metadataMonitor.release(alias.observationToken)
        }
    }

    private func removeUnaliasedReusableSnapshot(
        _ identity: WorkspaceRootReusableSnapshotIdentity
    ) {
        guard !reusableSnapshotAliasesByScope.values.contains(where: { $0.snapshotIdentity == identity }),
              let removed = reusableSnapshotsByIdentity.removeValue(forKey: identity)
        else { return }
        reusableSnapshotEstimatedBytes = max(
            0,
            reusableSnapshotEstimatedBytes - removed.snapshot.estimatedByteCount
        )
        reusableSnapshotArtifactBytes = reusableSnapshotArtifactBytes >= removed.snapshot.artifactByteCount
            ? reusableSnapshotArtifactBytes - removed.snapshot.artifactByteCount
            : 0
    }

    private func takePendingReusableSnapshotAdmission(
        _ prepared: PreparedReusableSnapshotAdmission
    ) -> PendingReusableSnapshotAdmission? {
        guard let pending = pendingReusableSnapshotAdmissions.removeValue(forKey: prepared.id) else { return nil }
        pendingReusableSnapshotArtifactBytes = pendingReusableSnapshotArtifactBytes >= pending.reservedArtifactBytes
            ? pendingReusableSnapshotArtifactBytes - pending.reservedArtifactBytes
            : 0
        return pending
    }

    func beginMutation(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        kind: GitWorkspaceMutationKind,
        correlationID: UUID? = nil
    ) async -> GitWorkspaceMutationToken {
        let affectedKeys = Set(records.keys.filter { Self.sameCommonDirectory($0, repositoryKey) })
            .union([repositoryKey])
        let token = GitWorkspaceMutationToken(
            id: UUID(),
            repositoryKey: repositoryKey,
            affectedRepositoryKeys: affectedKeys,
            kind: kind,
            correlationID: correlationID
        )
        for key in affectedKeys {
            var record = records[key] ?? Record()
            record.mutationDepth += 1
            record.invalidationGeneration &+= 1
            record.snapshotsByScope.removeAll(keepingCapacity: true)
            records[key] = record
            updateSynchronousState(repositoryKey: key, record: record)
            emitInvalidation(
                repositoryKey: key,
                record: record,
                kind: .mutationBegan(kind)
            )
        }
        await removeReusableSnapshotAliases(for: affectedKeys)
        activeMutations[token.id] = token
        return token
    }

    /// Completion balances mutation state exactly once. Invalidation occurs at
    /// begin, so a collection spanning even a failed/cancelled mutation cannot
    /// reinstall stale evidence.
    func finishMutation(
        _ token: GitWorkspaceMutationToken,
        outcome: GitWorkspaceMutationOutcome
    ) {
        guard activeMutations.removeValue(forKey: token.id) != nil else { return }
        for key in token.affectedRepositoryKeys {
            var record = records[key] ?? Record()
            record.mutationDepth = max(0, record.mutationDepth - 1)
            records[key] = record
            updateSynchronousState(repositoryKey: key, record: record)
            emitInvalidation(
                repositoryKey: key,
                record: record,
                kind: .mutationCompleted(token.kind, outcome)
            )
        }
    }

    func metadataDidChange(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        kinds: Set<GitWorkspaceMetadataEventKind>
    ) async {
        var record = records[repositoryKey] ?? Record()
        record.metadataEventCount &+= 1
        record.invalidationGeneration &+= 1
        record.snapshotsByScope.removeAll(keepingCapacity: true)
        if kinds.contains(.monitorGap) {
            record.monitorCoverageUnavailable = true
        }
        records[repositoryKey] = record
        updateSynchronousState(repositoryKey: repositoryKey, record: record)
        emitInvalidation(
            repositoryKey: repositoryKey,
            record: record,
            kind: .metadata(kinds)
        )
        await removeReusableSnapshotAliases(for: [repositoryKey])
    }

    private func removeReusableSnapshotAliases(
        for repositoryKeys: Set<GitWorkspaceAuthorityRepositoryKey>
    ) async {
        let aliases = reusableSnapshotAliasesByScope.filter {
            repositoryKeys.contains($0.key.repositoryKey)
        }
        for (scopeKey, alias) in aliases {
            reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
            await metadataMonitor.release(alias.observationToken)
        }
    }

    func retainMetadataObservation(
        for layout: GitRepositoryLayout,
        additionalAuthorityPaths: [URL] = []
    ) async throws -> GitWorkspaceMetadataMonitor.RetainToken {
        let key = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        let paths = Self.metadataPaths(for: layout) + additionalAuthorityPaths
        let token = try await metadataMonitor.retain(repositoryKey: key, paths: paths) { [weak self] kinds in
            Task { await self?.metadataDidChange(repositoryKey: key, kinds: kinds) }
        }
        var record = records[key] ?? Record()
        if record.monitorCoverageUnavailable {
            record.monitorCoverageUnavailable = false
            record.invalidationGeneration &+= 1
            record.snapshotsByScope.removeAll(keepingCapacity: true)
        }
        records[key] = record
        updateSynchronousState(repositoryKey: key, record: record)
        return token
    }

    func metadataObservationIsCurrent(
        _ token: GitWorkspaceMetadataMonitor.RetainToken,
        for layout: GitRepositoryLayout,
        additionalAuthorityPaths: [URL] = [],
        expectedAcceptedWatermark: UInt64
    ) async -> Bool {
        await metadataMonitor.coverageIsCurrent(
            token,
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            paths: Self.metadataPaths(for: layout) + additionalAuthorityPaths,
            expectedAcceptedWatermark: expectedAcceptedWatermark
        )
    }

    func retireEphemeralAuthorityLease(
        _ lease: GitWorkspaceAuthorityLease,
        observationToken: GitWorkspaceMetadataMonitor.RetainToken
    ) async {
        await metadataMonitor.release(observationToken)
        guard var record = records[lease.repositoryKey],
              record.publicationGenerationByScope[lease.scopeKey] == lease.authorityGeneration,
              record.snapshotsByScope[lease.scopeKey] == lease.snapshot
        else { return }
        record.monitorCoverageUnavailable = true
        record.invalidationGeneration &+= 1
        record.snapshotsByScope.removeAll(keepingCapacity: true)
        records[lease.repositoryKey] = record
        updateSynchronousState(repositoryKey: lease.repositoryKey, record: record)
        await removeReusableSnapshotAliases(for: [lease.repositoryKey])
    }

    func releaseMetadataObservation(_ token: GitWorkspaceMetadataMonitor.RetainToken) async {
        await metadataMonitor.release(token)
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            Snapshot(
                recordCount: records.count,
                publishedScopeCount: records.values.reduce(0) { $0 + $1.snapshotsByScope.count },
                activeMutationCount: activeMutations.count,
                metadataEventCount: records.values.reduce(0) { $0 + $1.metadataEventCount },
                authorityGenerations: records.mapValues(\.invalidationGeneration),
                reusableSnapshotCount: reusableSnapshotsByIdentity.count,
                reusableSnapshotAliasCount: reusableSnapshotAliasesByScope.count,
                reusableSnapshotEstimatedBytes: reusableSnapshotEstimatedBytes,
                reusableSnapshotArtifactBytes: reusableSnapshotArtifactBytes,
                pendingReusableSnapshotAdmissionCount: pendingReusableSnapshotAdmissions.count,
                pendingReusableSnapshotArtifactBytes: pendingReusableSnapshotArtifactBytes,
                reusableSnapshotArtifactBudgetRejectionCount: reusableSnapshotArtifactBudgetRejectionCount,
                invalidationSubscriberCount: invalidationContinuations.count
            )
        }

        func metadataMonitorForTesting() -> GitWorkspaceMetadataMonitor {
            metadataMonitor
        }
    #endif

    private func hasActiveMutation(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey
    ) -> Bool {
        activeMutations.values.contains { token in
            token.affectedRepositoryKeys.contains(where: {
                Self.sameCommonDirectory($0, repositoryKey)
            })
        }
    }

    private func emitInvalidation(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        record: Record,
        kind: GitWorkspaceAuthorityInvalidationKind
    ) {
        let event = GitWorkspaceAuthorityInvalidationEvent(
            repositoryKey: repositoryKey,
            invalidationGeneration: record.invalidationGeneration,
            acceptedMetadataWatermark: metadataMonitor.acceptedWatermark(for: repositoryKey),
            kind: kind
        )
        for continuation in invalidationContinuations.values {
            continuation.yield(event)
        }
    }

    private func updateSynchronousState(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        record: Record
    ) {
        synchronousState.update(
            repositoryKey: repositoryKey,
            invalidationGeneration: record.invalidationGeneration,
            mutationDepth: record.mutationDepth,
            monitorCoverageUnavailable: record.monitorCoverageUnavailable,
            publicationGenerations: record.publicationGenerationByScope
        )
    }

    private func removeInvalidationContinuation(_ id: UUID) {
        invalidationContinuations.removeValue(forKey: id)
    }

    private nonisolated static func sameCommonDirectory(
        _ lhs: GitWorkspaceAuthorityRepositoryKey,
        _ rhs: GitWorkspaceAuthorityRepositoryKey
    ) -> Bool {
        lhs.standardizedCommonDirectoryPath == rhs.standardizedCommonDirectoryPath
            && lhs.commonDirectoryDevice == rhs.commonDirectoryDevice
            && lhs.commonDirectoryInode == rhs.commonDirectoryInode
    }

    private nonisolated static func metadataPaths(for layout: GitRepositoryLayout) -> [URL] {
        [
            layout.dotGitPath,
            layout.gitDir.appendingPathComponent("HEAD"),
            layout.gitDir.appendingPathComponent("index"),
            layout.gitDir.appendingPathComponent("config.worktree"),
            layout.gitDir.appendingPathComponent("info/sparse-checkout"),
            layout.commonDir.appendingPathComponent("HEAD"),
            layout.commonDir.appendingPathComponent("packed-refs"),
            layout.commonDir.appendingPathComponent("refs", isDirectory: true),
            layout.commonDir.appendingPathComponent("config"),
            layout.commonDir.appendingPathComponent("info/exclude"),
            layout.commonDir.appendingPathComponent("info/attributes")
        ]
    }
}
