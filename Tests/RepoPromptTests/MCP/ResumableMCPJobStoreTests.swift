import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class ResumableMCPJobStoreTests: XCTestCase {
    private let tool = "context_builder"
    private let windowID = 42

    func testRegisterPollCompleteAndExpire() async throws {
        let store = makeStore(terminalTTL: 0.05)
        let registration = await store.register(
            tool: tool,
            windowID: windowID,
            statusText: "Queued",
            stage: "starting"
        )

        XCTAssertFalse(registration.reusedExistingJob)
        XCTAssertEqual(registration.snapshot.status, .queued)
        XCTAssertEqual(registration.snapshot.kind, MCPResumableJobSnapshot.envelopeKind)
        XCTAssertNotNil(registration.snapshot.expiresAt)
        XCTAssertNotNil(registration.snapshot.expiresInSeconds())

        let polled = await store.poll(jobID: registration.jobID, tool: tool, windowID: windowID)
        XCTAssertEqual(polled.status, .queued)
        XCTAssertEqual(polled.stage, "starting")

        let completed = await store.complete(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            result: .object(["ok": .bool(true)]),
            statusText: "Complete"
        )
        XCTAssertEqual(completed.status, .completed)
        XCTAssertTrue(completed.resultAvailable)
        XCTAssertEqual(completed.result?.objectValue?["ok"]?.boolValue, true)

        try await Task.sleep(nanoseconds: 90_000_000)
        let expired = await store.poll(jobID: registration.jobID, tool: tool, windowID: windowID)
        XCTAssertEqual(expired.status, .expired)
        XCTAssertNil(expired.result)
    }

    func testWaitTimeoutDoesNotFailJobAndCarriesRequestedEffectiveMetadata() async {
        let store = makeStore()
        let registration = await store.register(tool: tool, windowID: windowID)

        let timedOut = await store.wait(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            requestedTimeoutSeconds: 5,
            effectiveTimeoutSeconds: 0.01
        )

        XCTAssertEqual(timedOut.status, .queued)
        XCTAssertEqual(timedOut.wait?.result, .timedOut)
        XCTAssertEqual(timedOut.wait?.requestedSeconds, 5)
        XCTAssertEqual(timedOut.wait?.effectiveSeconds, 0.01)

        let polled = await store.poll(jobID: registration.jobID, tool: tool, windowID: windowID)
        XCTAssertEqual(polled.status, .queued)
        XCTAssertNil(polled.error)
    }

    func testTerminalCompletionWakesWaiters() async throws {
        let store = makeStore()
        let registration = await store.register(tool: tool, windowID: windowID)
        let waitTask = Task {
            await store.wait(
                jobID: registration.jobID,
                tool: tool,
                windowID: windowID,
                requestedTimeoutSeconds: 2,
                effectiveTimeoutSeconds: 2
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        let parkedWaiterCount = await store.test_waiterCount(jobID: registration.jobID)
        XCTAssertEqual(parkedWaiterCount, 1)
        await store.complete(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            result: .object(["answer": .string("done")])
        )

        let snapshot = await waitTask.value
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertEqual(snapshot.wait?.result, .snapshotReady)
        XCTAssertEqual(snapshot.result?.objectValue?["answer"]?.stringValue, "done")
        let remainingWaiterCount = await store.test_waiterCount(jobID: registration.jobID)
        XCTAssertEqual(remainingWaiterCount, 0)
    }

    func testCancelRequestsWorkerCancellationAndAllowsCancelledTerminalTransition() async {
        let store = makeStore()
        let registration = await store.register(tool: tool, windowID: windowID)
        let workerStarted = XCTestExpectation(description: "worker started")
        let workerCancelled = XCTestExpectation(description: "worker cancelled")
        let worker = Task<Void, Never> {
            workerStarted.fulfill()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            workerCancelled.fulfill()
        }
        await store.attachWorkerTask(jobID: registration.jobID, tool: tool, windowID: windowID, task: worker)
        await fulfillment(of: [workerStarted], timeout: 1)

        let cancelling = await store.cancel(jobID: registration.jobID, tool: tool, windowID: windowID)
        XCTAssertEqual(cancelling.status, .cancelling)
        XCTAssertEqual(cancelling.pollAfterSeconds, 0.5)

        let lateProgress = await store.updateProgress(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            statusText: "Late progress"
        )
        XCTAssertEqual(lateProgress.status, .cancelling)
        XCTAssertEqual(lateProgress.statusText, "Late progress")
        await fulfillment(of: [workerCancelled], timeout: 1)

        let cancelled = await store.markCancelled(jobID: registration.jobID, tool: tool, windowID: windowID)
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    func testExpiredTombstonesAreRetainedTemporarilyAndThenPruned() async throws {
        let store = makeStore(activeTTL: 0.02, tombstoneTTL: 0.04)
        let registration = await store.register(tool: tool, windowID: windowID)

        try await Task.sleep(nanoseconds: 30_000_000)
        let expired = await store.poll(jobID: registration.jobID, tool: tool, windowID: windowID)
        XCTAssertEqual(expired.status, .expired)
        let retainedTombstoneCount = await store.test_tombstoneCount()
        XCTAssertEqual(retainedTombstoneCount, 1)

        try await Task.sleep(nanoseconds: 70_000_000)
        let notFound = await store.poll(jobID: registration.jobID, tool: tool, windowID: windowID)
        XCTAssertEqual(notFound.status, .notFound)
        let prunedTombstoneCount = await store.test_tombstoneCount()
        XCTAssertEqual(prunedTombstoneCount, 0)
    }

    func testWaiterTaskCancellationDoesNotCancelJob() async throws {
        let store = makeStore()
        let registration = await store.register(tool: tool, windowID: windowID)
        let waitTask = Task {
            await store.wait(
                jobID: registration.jobID,
                tool: tool,
                windowID: windowID,
                requestedTimeoutSeconds: 5,
                effectiveTimeoutSeconds: 5
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        let parkedWaiterCount = await store.test_waiterCount(jobID: registration.jobID)
        XCTAssertEqual(parkedWaiterCount, 1)
        waitTask.cancel()

        let snapshot = await waitTask.value
        XCTAssertEqual(snapshot.wait?.result, .cancelled)
        XCTAssertEqual(snapshot.status, .queued)
        let remainingWaiterCount = await store.test_waiterCount(jobID: registration.jobID)
        XCTAssertEqual(remainingWaiterCount, 0)

        let polled = await store.poll(jobID: registration.jobID, tool: tool, windowID: windowID)
        XCTAssertEqual(polled.status, .queued)
    }

    func testPollHintsAndRelativeExpiryAreInEnvelopeValue() async throws {
        let now = Date()
        let store = makeStore(activeTTL: 10, pollAfterSeconds: 0.25)
        let registration = await store.register(tool: tool, windowID: windowID, now: now)
        let object = registration.snapshot.toValue(now: now).objectValue

        XCTAssertEqual(object?["kind"]?.stringValue, MCPResumableJobSnapshot.envelopeKind)
        XCTAssertEqual(object?["poll_after_seconds"]?.doubleValue, 0.25)
        let expiresIn = try XCTUnwrap(object?["expires_in_seconds"]?.doubleValue)
        XCTAssertGreaterThan(expiresIn, 9.9)
        XCTAssertLessThanOrEqual(expiresIn, 10.0)
        XCTAssertEqual(object?["server_instance_id"]?.stringValue, "test-server")
    }

    func testCompletedEnvelopeNestsExistingResultShapeUnchanged() async throws {
        let now = Date()
        let store = makeStore()
        let registration = await store.register(tool: tool, windowID: windowID, now: now)
        let existingResult: Value = .object([
            "context_id": .string("tab-1"),
            "status": .string("completed"),
            "prompt": .string("Final prompt"),
            "selection": .string("Selection summary"),
            "file_count": .int(2),
            "total_tokens": .int(123)
        ])

        let completed = await store.complete(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            result: existingResult,
            now: now
        )
        let object = try XCTUnwrap(completed.toValue(now: now).objectValue)
        let nested = try XCTUnwrap(object["result"]?.objectValue)

        XCTAssertEqual(object["kind"]?.stringValue, MCPResumableJobSnapshot.envelopeKind)
        XCTAssertEqual(object["result_available"]?.boolValue, true)
        XCTAssertEqual(nested["context_id"]?.stringValue, "tab-1")
        XCTAssertEqual(nested["status"]?.stringValue, "completed")
        XCTAssertEqual(nested["prompt"]?.stringValue, "Final prompt")
        XCTAssertEqual(nested["selection"]?.stringValue, "Selection summary")
        XCTAssertEqual(nested["file_count"]?.intValue, 2)
        XCTAssertEqual(nested["total_tokens"]?.intValue, 123)
    }

    func testStartIdempotencyIsScopedByToolAndWindow() async {
        let store = makeStore()
        let first = await store.register(tool: tool, windowID: windowID, clientRequestID: "request-1")
        let duplicate = await store.register(tool: tool, windowID: windowID, clientRequestID: "request-1")
        let differentWindow = await store.register(tool: tool, windowID: windowID + 1, clientRequestID: "request-1")
        let differentTool = await store.register(tool: "oracle_send", windowID: windowID, clientRequestID: "request-1")

        XCTAssertFalse(first.reusedExistingJob)
        XCTAssertTrue(duplicate.reusedExistingJob)
        XCTAssertEqual(first.jobID, duplicate.jobID)
        XCTAssertNotEqual(first.jobID, differentWindow.jobID)
        XCTAssertNotEqual(first.jobID, differentTool.jobID)
    }

    func testExpiredWaitReturnsExpiredMetadataAndRecoveryStatusText() async throws {
        let store = makeStore(activeTTL: 0.02, tombstoneTTL: 1)
        let registration = await store.register(tool: tool, windowID: windowID)

        try await Task.sleep(nanoseconds: 30_000_000)
        let expired = await store.wait(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            requestedTimeoutSeconds: 1,
            effectiveTimeoutSeconds: 0.01
        )

        XCTAssertEqual(expired.status, .expired)
        XCTAssertEqual(expired.wait?.result, .expired)
        XCTAssertTrue(expired.statusText?.contains("Start a new job") == true, expired.statusText ?? "")
        XCTAssertNil(expired.result)
    }

    func testWrongWindowControlOperationsFailClosedWithoutAffectingOriginalJob() async {
        let store = makeStore()
        let registration = await store.register(tool: tool, windowID: windowID)

        let wrongWindowWait = await store.wait(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID + 1,
            requestedTimeoutSeconds: 0,
            effectiveTimeoutSeconds: 0
        )
        XCTAssertEqual(wrongWindowWait.status, .notFound)
        XCTAssertEqual(wrongWindowWait.wait?.result, .snapshotReady)

        let wrongWindowCancel = await store.cancel(jobID: registration.jobID, tool: tool, windowID: windowID + 1)
        XCTAssertEqual(wrongWindowCancel.status, .notFound)

        let original = await store.poll(jobID: registration.jobID, tool: tool, windowID: windowID)
        XCTAssertEqual(original.status, .queued)
        XCTAssertNil(original.error)
    }

    func testMismatchedServerInstanceReportsRestartEvenWhenJobIDIsUnknown() async {
        let store = makeStore()
        let restarted = await store.poll(
            jobID: UUID(),
            tool: tool,
            windowID: windowID,
            serverInstanceID: "old-server"
        )

        XCTAssertEqual(restarted.status, .serverRestarted)
        XCTAssertEqual(restarted.serverInstanceID, "test-server")
        XCTAssertTrue(restarted.statusText?.contains("does not match") == true, restarted.statusText ?? "")
    }

    func testMissingJobWaitReturnsNotFoundSnapshotReadyMetadata() async {
        let store = makeStore()
        let missing = await store.wait(
            jobID: UUID(),
            tool: tool,
            windowID: windowID,
            requestedTimeoutSeconds: 1,
            effectiveTimeoutSeconds: 0.01
        )

        XCTAssertEqual(missing.status, .notFound)
        XCTAssertEqual(missing.wait?.result, .snapshotReady)
    }

    func testToolOrWindowMismatchFailsClosedAndServerInstanceMismatchReportsRestart() async {
        let store = makeStore()
        let registration = await store.register(tool: tool, windowID: windowID)

        let wrongTool = await store.poll(jobID: registration.jobID, tool: "oracle_send", windowID: windowID)
        XCTAssertEqual(wrongTool.status, .notFound)

        let wrongWindow = await store.poll(jobID: registration.jobID, tool: tool, windowID: windowID + 1)
        XCTAssertEqual(wrongWindow.status, .notFound)

        let restarted = await store.poll(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            serverInstanceID: "previous-server"
        )
        XCTAssertEqual(restarted.status, .serverRestarted)
        XCTAssertEqual(restarted.serverInstanceID, "test-server")

        let correct = await store.poll(jobID: registration.jobID, tool: tool, windowID: windowID, serverInstanceID: "test-server")
        XCTAssertEqual(correct.status, .queued)
    }

    func testTerminalStateDoesNotRegress() async {
        let store = makeStore()
        let registration = await store.register(tool: tool, windowID: windowID)
        await store.complete(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            result: .object(["value": .string("final")])
        )

        let progress = await store.updateProgress(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            statusText: "Still running"
        )
        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.result?.objectValue?["value"]?.stringValue, "final")

        let failed = await store.fail(
            jobID: registration.jobID,
            tool: tool,
            windowID: windowID,
            errorType: "late_error",
            message: "late"
        )
        XCTAssertEqual(failed.status, .completed)
        XCTAssertNil(failed.error)
    }

    private func makeStore(
        activeTTL: TimeInterval = 60,
        terminalTTL: TimeInterval = 60,
        tombstoneTTL: TimeInterval = 60,
        pollAfterSeconds: TimeInterval = 1
    ) -> MCPResumableJobStore {
        MCPResumableJobStore(
            serverInstanceID: "test-server",
            configuration: MCPResumableJobStore.Configuration(
                activeTTL: activeTTL,
                terminalTTL: terminalTTL,
                expiredTombstoneTTL: tombstoneTTL,
                defaultPollAfterSeconds: pollAfterSeconds,
                cancellingPollAfterSeconds: 0.5,
                terminalPollAfterSeconds: 0
            )
        )
    }
}

private extension MCPResumableJobSnapshot {
    var kind: String {
        MCPResumableJobSnapshot.envelopeKind
    }
}
