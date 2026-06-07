import Foundation
import MCP

actor MCPResumableJobStore {
    static let shared = MCPResumableJobStore()

    struct Configuration: Equatable {
        var activeTTL: TimeInterval = 60 * 60
        var terminalTTL: TimeInterval = 300
        var expiredTombstoneTTL: TimeInterval = 300
        var defaultPollAfterSeconds: TimeInterval = 1
        var cancellingPollAfterSeconds: TimeInterval = 0.5
        var terminalPollAfterSeconds: TimeInterval = 0
    }

    struct Registration: Equatable {
        let jobID: UUID
        let snapshot: MCPResumableJobSnapshot
        let reusedExistingJob: Bool
    }

    private struct Scope: Equatable, Hashable {
        let tool: String
        let windowID: Int?
    }

    private struct IdempotencyKey: Equatable, Hashable {
        let scope: Scope
        let clientRequestID: String
    }

    private struct Waiter {
        let id: UUID
        let requestedSeconds: TimeInterval?
        let effectiveSeconds: TimeInterval?
        let continuation: CheckedContinuation<MCPResumableJobSnapshot, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private struct ExpiredTombstone {
        let scope: Scope
        let snapshot: MCPResumableJobSnapshot
        let retainUntil: Date
        let expiryTask: Task<Void, Never>?
    }

    private struct Record {
        let jobID: UUID
        let scope: Scope
        let createdAt: Date
        let clientRequestID: String?
        var generation: UInt64
        var status: MCPResumableJobStatus
        var statusText: String?
        var stage: String?
        var progressMessage: String?
        var updatedAt: Date
        var expiresAt: Date
        var pollAfterSeconds: TimeInterval
        var result: Value?
        var error: MCPResumableJobError?
        var workerTask: Task<Void, Never>?
        var waiters: [Waiter]
        var expiryTask: Task<Void, Never>?
    }

    let serverInstanceID: String
    private let configuration: Configuration
    private var records: [UUID: Record] = [:]
    private var expiredTombstones: [UUID: ExpiredTombstone] = [:]
    private var idempotencyIndex: [IdempotencyKey: UUID] = [:]
    private var nextGeneration: UInt64 = 1

    init(
        serverInstanceID: String = UUID().uuidString,
        configuration: Configuration = Configuration()
    ) {
        self.serverInstanceID = serverInstanceID
        self.configuration = configuration
    }

    func register(
        tool: String,
        windowID: Int?,
        clientRequestID: String? = nil,
        statusText: String? = nil,
        stage: String? = nil,
        progressMessage: String? = nil,
        pollAfterSeconds: TimeInterval? = nil,
        now: Date = Date()
    ) -> Registration {
        let scope = Scope(tool: tool, windowID: windowID)
        let normalizedClientRequestID = normalized(clientRequestID)
        if let normalizedClientRequestID,
           let existingJobID = idempotencyIndex[IdempotencyKey(scope: scope, clientRequestID: normalizedClientRequestID)]
        {
            expireIfNeeded(jobID: existingJobID, now: now)
            if let existing = records[existingJobID] {
                return Registration(
                    jobID: existingJobID,
                    snapshot: snapshot(from: existing, now: now),
                    reusedExistingJob: true
                )
            }
        }

        let jobID = UUID()
        let generation = nextGeneration
        nextGeneration &+= 1
        let expiresAt = now.addingTimeInterval(configuration.activeTTL)
        let record = Record(
            jobID: jobID,
            scope: scope,
            createdAt: now,
            clientRequestID: normalizedClientRequestID,
            generation: generation,
            status: .queued,
            statusText: statusText,
            stage: stage,
            progressMessage: progressMessage,
            updatedAt: now,
            expiresAt: expiresAt,
            pollAfterSeconds: pollAfterSeconds ?? configuration.defaultPollAfterSeconds,
            result: nil,
            error: nil,
            workerTask: nil,
            waiters: [],
            expiryTask: nil
        )
        records[jobID] = record
        expiredTombstones.removeValue(forKey: jobID)
        if let normalizedClientRequestID {
            idempotencyIndex[IdempotencyKey(scope: scope, clientRequestID: normalizedClientRequestID)] = jobID
        }
        scheduleExpiry(jobID: jobID, generation: generation, delay: configuration.activeTTL)
        return Registration(jobID: jobID, snapshot: snapshot(from: record, now: now), reusedExistingJob: false)
    }

    @discardableResult
    func attachWorkerTask(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        task: Task<Void, Never>,
        serverInstanceID suppliedServerInstanceID: String? = nil,
        now: Date = Date()
    ) -> MCPResumableJobSnapshot {
        guard let loaded = load(jobID: jobID, tool: tool, windowID: windowID, suppliedServerInstanceID: suppliedServerInstanceID, now: now) else {
            task.cancel()
            return notFoundSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: now)
        }
        switch loaded {
        case let .synthetic(snapshot):
            task.cancel()
            return snapshot
        case var .record(record):
            guard !record.status.isTerminal else {
                task.cancel()
                return snapshot(from: record, now: now)
            }
            record.workerTask?.cancel()
            record.workerTask = task
            records[jobID] = record
            return snapshot(from: record, now: now)
        }
    }

    @discardableResult
    func updateProgress(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        status: MCPResumableJobStatus = .running,
        statusText: String? = nil,
        stage: String? = nil,
        progressMessage: String? = nil,
        pollAfterSeconds: TimeInterval? = nil,
        serverInstanceID suppliedServerInstanceID: String? = nil,
        now: Date = Date()
    ) -> MCPResumableJobSnapshot {
        guard let loaded = load(jobID: jobID, tool: tool, windowID: windowID, suppliedServerInstanceID: suppliedServerInstanceID, now: now) else {
            return notFoundSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: now)
        }
        switch loaded {
        case let .synthetic(snapshot):
            return snapshot
        case var .record(record):
            guard !record.status.isTerminal else { return snapshot(from: record, now: now) }
            guard !status.isTerminal else { return snapshot(from: record, now: now) }
            if record.status != .cancelling {
                record.status = status
            }
            record.statusText = statusText ?? record.statusText
            record.stage = stage ?? record.stage
            record.progressMessage = progressMessage ?? record.progressMessage
            record.updatedAt = now
            record.expiresAt = now.addingTimeInterval(configuration.activeTTL)
            record.pollAfterSeconds = pollAfterSeconds ?? record.pollAfterSeconds
            records[jobID] = record
            scheduleExpiry(jobID: jobID, generation: record.generation, delay: configuration.activeTTL)
            return snapshot(from: record, now: now)
        }
    }

    @discardableResult
    func complete(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        result: Value,
        statusText: String? = nil,
        stage: String? = nil,
        progressMessage: String? = nil,
        serverInstanceID suppliedServerInstanceID: String? = nil,
        now: Date = Date()
    ) -> MCPResumableJobSnapshot {
        transitionToTerminal(
            jobID: jobID,
            tool: tool,
            windowID: windowID,
            status: .completed,
            statusText: statusText,
            stage: stage,
            progressMessage: progressMessage,
            result: result,
            error: nil,
            suppliedServerInstanceID: suppliedServerInstanceID,
            now: now
        )
    }

    @discardableResult
    func fail(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        errorType: String,
        message: String,
        statusText: String? = nil,
        stage: String? = nil,
        serverInstanceID suppliedServerInstanceID: String? = nil,
        now: Date = Date()
    ) -> MCPResumableJobSnapshot {
        transitionToTerminal(
            jobID: jobID,
            tool: tool,
            windowID: windowID,
            status: .failed,
            statusText: statusText ?? message,
            stage: stage,
            progressMessage: nil,
            result: nil,
            error: MCPResumableJobError(type: errorType, message: message),
            suppliedServerInstanceID: suppliedServerInstanceID,
            now: now
        )
    }

    @discardableResult
    func markCancelled(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        statusText: String? = "Cancelled.",
        stage: String? = nil,
        serverInstanceID suppliedServerInstanceID: String? = nil,
        now: Date = Date()
    ) -> MCPResumableJobSnapshot {
        transitionToTerminal(
            jobID: jobID,
            tool: tool,
            windowID: windowID,
            status: .cancelled,
            statusText: statusText,
            stage: stage,
            progressMessage: nil,
            result: nil,
            error: nil,
            suppliedServerInstanceID: suppliedServerInstanceID,
            now: now
        )
    }

    func poll(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        serverInstanceID suppliedServerInstanceID: String? = nil,
        now: Date = Date()
    ) -> MCPResumableJobSnapshot {
        guard let loaded = load(jobID: jobID, tool: tool, windowID: windowID, suppliedServerInstanceID: suppliedServerInstanceID, now: now) else {
            return notFoundSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: now)
        }
        switch loaded {
        case let .synthetic(snapshot):
            return snapshot
        case let .record(record):
            return snapshot(from: record, now: now)
        }
    }

    func wait(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        requestedTimeoutSeconds: TimeInterval? = nil,
        effectiveTimeoutSeconds: TimeInterval? = nil,
        serverInstanceID suppliedServerInstanceID: String? = nil,
        now: Date = Date()
    ) async -> MCPResumableJobSnapshot {
        let effectiveSeconds = effectiveTimeoutSeconds ?? requestedTimeoutSeconds
        let waitMetadata = { (result: MCPResumableJobWaitMetadata.Result) in
            MCPResumableJobWaitMetadata(
                result: result,
                requestedSeconds: requestedTimeoutSeconds,
                effectiveSeconds: effectiveSeconds
            )
        }

        guard let loaded = load(jobID: jobID, tool: tool, windowID: windowID, suppliedServerInstanceID: suppliedServerInstanceID, now: now) else {
            return notFoundSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: now)
                .withWait(waitMetadata(.snapshotReady))
        }
        switch loaded {
        case let .synthetic(snapshot):
            let result: MCPResumableJobWaitMetadata.Result = snapshot.status == .expired ? .expired : .snapshotReady
            return snapshot.withWait(waitMetadata(result))
        case let .record(record):
            if record.status.isTerminal {
                return snapshot(from: record, now: now).withWait(waitMetadata(.snapshotReady))
            }
            if let effectiveSeconds, effectiveSeconds <= 0 {
                return snapshot(from: record, now: now).withWait(waitMetadata(.timedOut))
            }
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MCPResumableJobSnapshot, Never>) in
                let parkedAt = Date()
                guard let loaded = load(jobID: jobID, tool: tool, windowID: windowID, suppliedServerInstanceID: suppliedServerInstanceID, now: parkedAt) else {
                    continuation.resume(
                        returning: notFoundSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: parkedAt)
                            .withWait(waitMetadata(.snapshotReady))
                    )
                    return
                }
                switch loaded {
                case let .synthetic(snapshot):
                    let result: MCPResumableJobWaitMetadata.Result = snapshot.status == .expired ? .expired : .snapshotReady
                    continuation.resume(returning: snapshot.withWait(waitMetadata(result)))
                case var .record(record):
                    if record.status.isTerminal {
                        continuation.resume(returning: snapshot(from: record, now: parkedAt).withWait(waitMetadata(.snapshotReady)))
                        return
                    }
                    var timeoutTask: Task<Void, Never>?
                    if let effectiveSeconds {
                        timeoutTask = Task { [jobID, waiterID] in
                            do {
                                try await Task.sleep(nanoseconds: Self.nanoseconds(for: effectiveSeconds))
                                await self.timeoutWaiter(jobID: jobID, waiterID: waiterID)
                            } catch {
                                // Snapshot or cleanup woke this waiter first.
                            }
                        }
                    }
                    record.waiters.append(Waiter(
                        id: waiterID,
                        requestedSeconds: requestedTimeoutSeconds,
                        effectiveSeconds: effectiveSeconds,
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    ))
                    records[jobID] = record
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(jobID: jobID, waiterID: waiterID) }
        }
    }

    @discardableResult
    func cancel(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        statusText: String? = "Cancellation requested.",
        serverInstanceID suppliedServerInstanceID: String? = nil,
        now: Date = Date()
    ) -> MCPResumableJobSnapshot {
        guard let loaded = load(jobID: jobID, tool: tool, windowID: windowID, suppliedServerInstanceID: suppliedServerInstanceID, now: now) else {
            return notFoundSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: now)
        }
        switch loaded {
        case let .synthetic(snapshot):
            return snapshot
        case var .record(record):
            guard !record.status.isTerminal else { return snapshot(from: record, now: now) }
            record.status = .cancelling
            record.statusText = statusText
            record.updatedAt = now
            record.pollAfterSeconds = configuration.cancellingPollAfterSeconds
            records[jobID] = record
            record.workerTask?.cancel()
            return snapshot(from: record, now: now)
        }
    }

    func cleanup(jobID: UUID) {
        guard let record = records.removeValue(forKey: jobID) else { return }
        record.expiryTask?.cancel()
        record.workerTask?.cancel()
        removeIdempotencyIndex(for: record)
        let now = Date()
        let expired = expiredSnapshot(from: record, now: now)
        storeExpiredTombstone(jobID: jobID, scope: record.scope, snapshot: expired, now: now)
        resume(waiters: record.waiters, with: expired, waitResult: .expired)
    }

    private enum LoadedRecord {
        case record(Record)
        case synthetic(MCPResumableJobSnapshot)
    }

    private func load(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        suppliedServerInstanceID: String?,
        now: Date
    ) -> LoadedRecord? {
        if let suppliedServerInstanceID,
           suppliedServerInstanceID != serverInstanceID
        {
            return .synthetic(serverRestartedSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: now))
        }
        expireIfNeeded(jobID: jobID, now: now)
        let requestedScope = Scope(tool: tool, windowID: windowID)
        if let record = records[jobID] {
            guard record.scope == requestedScope else {
                return .synthetic(notFoundSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: now))
            }
            return .record(record)
        }
        if let tombstone = expiredTombstones[jobID] {
            if tombstone.retainUntil <= now {
                tombstone.expiryTask?.cancel()
                expiredTombstones.removeValue(forKey: jobID)
                return nil
            }
            guard tombstone.scope == requestedScope else {
                return .synthetic(notFoundSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: now))
            }
            return .synthetic(tombstone.snapshot)
        }
        return nil
    }

    private func transitionToTerminal(
        jobID: UUID,
        tool: String,
        windowID: Int?,
        status: MCPResumableJobStatus,
        statusText: String?,
        stage: String?,
        progressMessage: String?,
        result: Value?,
        error: MCPResumableJobError?,
        suppliedServerInstanceID: String?,
        now: Date
    ) -> MCPResumableJobSnapshot {
        guard let loaded = load(jobID: jobID, tool: tool, windowID: windowID, suppliedServerInstanceID: suppliedServerInstanceID, now: now) else {
            return notFoundSnapshot(jobID: jobID, tool: tool, windowID: windowID, now: now)
        }
        switch loaded {
        case let .synthetic(snapshot):
            return snapshot
        case var .record(record):
            guard !record.status.isTerminal else { return snapshot(from: record, now: now) }
            record.status = status
            record.statusText = statusText ?? record.statusText
            record.stage = stage ?? record.stage
            record.progressMessage = progressMessage ?? record.progressMessage
            record.updatedAt = now
            record.expiresAt = now.addingTimeInterval(configuration.terminalTTL)
            record.pollAfterSeconds = configuration.terminalPollAfterSeconds
            record.result = result
            record.error = error
            record.workerTask = nil
            let waiters = record.waiters
            record.waiters.removeAll()
            records[jobID] = record
            scheduleExpiry(jobID: jobID, generation: record.generation, delay: configuration.terminalTTL)
            let terminalSnapshot = snapshot(from: record, now: now)
            resume(waiters: waiters, with: terminalSnapshot, waitResult: .snapshotReady)
            return terminalSnapshot
        }
    }

    private func expireIfNeeded(jobID: UUID, now: Date) {
        guard let record = records[jobID], record.expiresAt <= now else { return }
        expire(jobID: jobID, generation: record.generation, now: now)
    }

    private func expire(jobID: UUID, generation: UInt64, now: Date = Date()) {
        guard let record = records[jobID], record.generation == generation else { return }
        records.removeValue(forKey: jobID)
        record.expiryTask?.cancel()
        record.workerTask?.cancel()
        removeIdempotencyIndex(for: record)
        let expired = expiredSnapshot(from: record, now: now)
        storeExpiredTombstone(jobID: jobID, scope: record.scope, snapshot: expired, now: now)
        resume(waiters: record.waiters, with: expired, waitResult: .expired)
    }

    private func scheduleExpiry(jobID: UUID, generation: UInt64, delay: TimeInterval) {
        guard var record = records[jobID] else { return }
        record.expiryTask?.cancel()
        record.expiryTask = Task { [jobID, generation] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
                await self.expire(jobID: jobID, generation: generation)
            } catch {
                // Expiry was rescheduled or record cleaned up.
            }
        }
        records[jobID] = record
    }

    private func storeExpiredTombstone(
        jobID: UUID,
        scope: Scope,
        snapshot: MCPResumableJobSnapshot,
        now: Date
    ) {
        expiredTombstones[jobID]?.expiryTask?.cancel()
        let tombstoneTTL = configuration.expiredTombstoneTTL
        let retainUntil = now.addingTimeInterval(tombstoneTTL)
        let expiryTask = Task { [jobID, retainUntil, tombstoneTTL] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: tombstoneTTL))
                await self.removeExpiredTombstone(jobID: jobID, retainUntil: retainUntil)
            } catch {
                // Tombstone was replaced or the store is going away.
            }
        }
        expiredTombstones[jobID] = ExpiredTombstone(
            scope: scope,
            snapshot: snapshot,
            retainUntil: retainUntil,
            expiryTask: expiryTask
        )
    }

    private func removeExpiredTombstone(jobID: UUID, retainUntil: Date) {
        guard let tombstone = expiredTombstones[jobID], tombstone.retainUntil == retainUntil else { return }
        tombstone.expiryTask?.cancel()
        expiredTombstones.removeValue(forKey: jobID)
    }

    private func timeoutWaiter(jobID: UUID, waiterID: UUID) {
        guard var record = records[jobID],
              let index = record.waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = record.waiters.remove(at: index)
        records[jobID] = record
        waiter.timeoutTask?.cancel()
        let current = snapshot(from: record, now: Date()).withWait(waitMetadata(for: waiter, result: .timedOut))
        waiter.continuation.resume(returning: current)
    }

    private func cancelWaiter(jobID: UUID, waiterID: UUID) {
        guard var record = records[jobID],
              let index = record.waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = record.waiters.remove(at: index)
        records[jobID] = record
        waiter.timeoutTask?.cancel()
        let current = snapshot(from: record, now: Date()).withWait(waitMetadata(for: waiter, result: .cancelled))
        waiter.continuation.resume(returning: current)
    }

    private func resume(
        waiters: [Waiter],
        with snapshot: MCPResumableJobSnapshot,
        waitResult: MCPResumableJobWaitMetadata.Result
    ) {
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: snapshot.withWait(waitMetadata(for: waiter, result: waitResult)))
        }
    }

    private func snapshot(from record: Record, now _: Date) -> MCPResumableJobSnapshot {
        MCPResumableJobSnapshot(
            jobID: record.jobID,
            serverInstanceID: serverInstanceID,
            tool: record.scope.tool,
            windowID: record.scope.windowID,
            status: record.status,
            statusText: record.statusText,
            stage: record.stage,
            progressMessage: record.progressMessage,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            expiresAt: record.expiresAt,
            pollAfterSeconds: record.pollAfterSeconds,
            result: record.result,
            error: record.error,
            wait: nil
        )
    }

    private func expiredSnapshot(from record: Record, now: Date) -> MCPResumableJobSnapshot {
        MCPResumableJobSnapshot(
            jobID: record.jobID,
            serverInstanceID: serverInstanceID,
            tool: record.scope.tool,
            windowID: record.scope.windowID,
            status: .expired,
            statusText: "This resumable job is no longer available. Start a new job.",
            stage: record.stage,
            progressMessage: record.progressMessage,
            createdAt: record.createdAt,
            updatedAt: now,
            expiresAt: nil,
            pollAfterSeconds: configuration.terminalPollAfterSeconds,
            result: nil,
            error: nil,
            wait: nil
        )
    }

    private func notFoundSnapshot(jobID: UUID, tool: String, windowID: Int?, now: Date) -> MCPResumableJobSnapshot {
        MCPResumableJobSnapshot(
            jobID: jobID,
            serverInstanceID: serverInstanceID,
            tool: tool,
            windowID: windowID,
            status: .notFound,
            statusText: "No matching resumable job was found for this tool and window.",
            stage: nil,
            progressMessage: nil,
            createdAt: now,
            updatedAt: now,
            expiresAt: nil,
            pollAfterSeconds: configuration.terminalPollAfterSeconds,
            result: nil,
            error: nil,
            wait: nil
        )
    }

    private func serverRestartedSnapshot(jobID: UUID, tool: String, windowID: Int?, now: Date) -> MCPResumableJobSnapshot {
        MCPResumableJobSnapshot(
            jobID: jobID,
            serverInstanceID: serverInstanceID,
            tool: tool,
            windowID: windowID,
            status: .serverRestarted,
            statusText: "The supplied server_instance_id does not match this RepoPrompt process. Start a new job.",
            stage: nil,
            progressMessage: nil,
            createdAt: now,
            updatedAt: now,
            expiresAt: nil,
            pollAfterSeconds: configuration.terminalPollAfterSeconds,
            result: nil,
            error: nil,
            wait: nil
        )
    }

    private func waitMetadata(
        for waiter: Waiter,
        result: MCPResumableJobWaitMetadata.Result
    ) -> MCPResumableJobWaitMetadata {
        MCPResumableJobWaitMetadata(
            result: result,
            requestedSeconds: waiter.requestedSeconds,
            effectiveSeconds: waiter.effectiveSeconds
        )
    }

    private func removeIdempotencyIndex(for record: Record) {
        guard let clientRequestID = record.clientRequestID else { return }
        idempotencyIndex.removeValue(forKey: IdempotencyKey(scope: record.scope, clientRequestID: clientRequestID))
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let capped = min(seconds, TimeInterval(UInt64.max) / 1_000_000_000)
        return UInt64(capped * 1_000_000_000)
    }
}

#if DEBUG
    extension MCPResumableJobStore {
        func test_waiterCount(jobID: UUID) -> Int {
            records[jobID]?.waiters.count ?? 0
        }

        func test_expire(jobID: UUID) {
            guard let generation = records[jobID]?.generation else { return }
            expire(jobID: jobID, generation: generation)
        }

        func test_tombstoneCount() -> Int {
            expiredTombstones.count
        }
    }
#endif
