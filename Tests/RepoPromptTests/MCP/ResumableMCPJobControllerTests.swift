import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class ResumableMCPJobControllerTests: XCTestCase {
    private let tool = "context_builder"
    private let windowID = 7

    func testOmittedOpParsesAsSynchronousCompatibilityPath() throws {
        let controller = makeController()

        let request = try controller.parseRequest(args: ["instructions": .string("do work")])

        XCTAssertTrue(request.isSynchronous)
        XCTAssertNil(request.operation)
    }

    func testControlOpsRejectBusinessArgumentsAndStartOnlyClientRequestID() throws {
        let controller = makeController()
        let jobID = UUID().uuidString

        XCTAssertThrowsError(try controller.parseRequest(args: [
            "op": .string("poll"),
            "job_id": .string(jobID),
            "instructions": .string("new instructions")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("business arguments"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("instructions"), error.localizedDescription)
        }

        XCTAssertThrowsError(try controller.parseRequest(args: [
            "op": .string("wait"),
            "job_id": .string(jobID),
            "client_request_id": .string("retry-key")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("client_request_id"), error.localizedDescription)
        }

        XCTAssertThrowsError(try controller.parseRequest(args: [
            "op": .string("poll"),
            "job_id": .string(jobID),
            "_unexpected": .string("not a declared routing arg")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("_unexpected"), error.localizedDescription)
        }
    }

    func testStartRejectsWaitOnlyTimeout() throws {
        let controller = makeController()

        XCTAssertThrowsError(try controller.parseRequest(args: [
            "op": .string("start"),
            "timeout": .double(1)
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("timeout is only supported with op=wait"), error.localizedDescription)
        }
    }

    func testOracleSendControlOpsRejectOracleBusinessArguments() throws {
        let controller = MCPResumableJobController(
            tool: "oracle_send",
            windowID: windowID,
            businessArgumentKeys: ["message", "mode", "chat_id", "new_chat", "model", "export_response"],
            store: makeStore()
        )
        let jobID = UUID().uuidString

        for businessKey in ["message", "mode", "chat_id", "new_chat", "model", "export_response"] {
            XCTAssertThrowsError(try controller.parseRequest(args: [
                "op": .string("wait"),
                "job_id": .string(jobID),
                "timeout": .double(0),
                businessKey: businessKey == "new_chat" || businessKey == "export_response" ? .bool(false) : .string("value")
            ]), "oracle_send op=wait should reject \(businessKey)") { error in
                XCTAssertTrue(error.localizedDescription.contains("business arguments"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(businessKey), error.localizedDescription)
            }
        }
    }

    func testWaitTimeoutIsCappedAndReturnedInWaitMetadata() async throws {
        let store = makeStore()
        let controller = makeController(
            store: store,
            configuration: .init(defaultWaitTimeoutSeconds: 0.01, maximumWaitTimeoutSeconds: 0.01)
        )
        let registration = await store.register(tool: tool, windowID: windowID)

        let snapshot = try await controller.wait(args: [
            "op": .string("wait"),
            "job_id": .string(registration.jobID.uuidString),
            "timeout": .double(10),
            "server_instance_id": .string("test-server")
        ])

        XCTAssertEqual(snapshot.status, .queued)
        XCTAssertEqual(snapshot.wait?.result, .timedOut)
        XCTAssertEqual(snapshot.wait?.requestedSeconds, 10)
        XCTAssertEqual(snapshot.wait?.effectiveSeconds, 0.01)
    }

    func testStartUsesClientRequestIDForIdempotencyAndDoesNotRelaunchWorker() async throws {
        let store = makeStore()
        let counter = WorkerCounter()
        let controller = makeController(store: store)
        let tool = tool
        let windowID = windowID
        let args: [String: Value] = [
            "op": .string("start"),
            "client_request_id": .string("same-request")
        ]

        let first = try await controller.start(args: args, stage: "starting") { jobID in
            await counter.increment()
            await store.complete(
                jobID: jobID,
                tool: tool,
                windowID: windowID,
                result: .object(["ok": .bool(true)])
            )
        }
        let duplicate = try await controller.start(args: args, stage: "starting") { _ in
            await counter.increment()
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        let workerLaunches = await counter.value
        XCTAssertEqual(first.jobID, duplicate.jobID)
        XCTAssertEqual(workerLaunches, 1)
    }

    private func makeController(
        store: MCPResumableJobStore? = nil,
        configuration: MCPResumableJobController.Configuration = .init()
    ) -> MCPResumableJobController {
        MCPResumableJobController(
            tool: tool,
            windowID: windowID,
            businessArgumentKeys: ["instructions", "message", "response_type", "export_response"],
            store: store ?? makeStore(),
            configuration: configuration
        )
    }

    private func makeStore() -> MCPResumableJobStore {
        MCPResumableJobStore(
            serverInstanceID: "test-server",
            configuration: MCPResumableJobStore.Configuration(
                activeTTL: 60,
                terminalTTL: 60,
                expiredTombstoneTTL: 60,
                defaultPollAfterSeconds: 1,
                cancellingPollAfterSeconds: 0.5,
                terminalPollAfterSeconds: 0
            )
        )
    }
}

private actor WorkerCounter {
    private var count = 0

    var value: Int {
        count
    }

    func increment() {
        count += 1
    }
}
