import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class NetworkMCPHTTPRoutingTests: XCTestCase {
    func testSessionlessNonInitializePostFailsClassifierGateWithoutCreatingSession() async throws {
        #if DEBUG
            let promptCounter = PromptCounter()
            try await withRoutingManager(approvalHandler: { _ in
                await promptCounter.increment()
                return .allow(alwaysAllow: false)
            }) { manager, token in
                let response = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    post(body: jsonData(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]), token: token)
                )

                XCTAssertEqual(response.statusCode, 400)
                let sessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCount, 0)
                let promptCount = await promptCounter.value
                XCTAssertEqual(promptCount, 0)
                XCTAssertTrue(try errorMessage(response).contains("Initial POST /mcp must be a single initialize request"))
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testSessionlessInitializeCreatesSDKSessionAndReturnsStreamingResponse() async throws {
        #if DEBUG
            try await withRoutingManager { manager, token in
                let response = await initialize(manager: manager, token: token)

                XCTAssertEqual(response.statusCode, 200, diagnostic(response))
                XCTAssertNotNil(response.headers[MCPNetworkHTTPHeader.sessionID])
                if case .stream = response.body {
                    // SDK initializes through request SSE; RepoPrompt preserves the stream opaquely.
                } else {
                    XCTFail("Expected initialize to route through SDK streaming transport")
                }
                let sessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCount, 1)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testDisabledSessionlessInitializeFailsClosedWithoutCreatingSession() async throws {
        #if DEBUG
            try await withRoutingManager { manager, token in
                await manager.setEnabled(false)

                let response = await initialize(manager: manager, token: token)

                XCTAssertEqual(response.statusCode, 503)
                XCTAssertTrue(try errorMessage(response).contains("MCP server is disabled"))
                let sessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCount, 0)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testDisabledExistingSessionRequestFailsClosedAndRemovesSession() async throws {
        #if DEBUG
            try await withRoutingManager { manager, token in
                let initializeResponse = await initialize(manager: manager, token: token)
                let sessionID = try XCTUnwrap(initializeResponse.headers[MCPNetworkHTTPHeader.sessionID])

                await manager.setEnabled(false)
                let response = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    get(sessionID: sessionID, token: token)
                )

                XCTAssertEqual(response.statusCode, 503)
                XCTAssertTrue(try errorMessage(response).contains("MCP server is disabled"))
                let sessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCount, 0)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testInvalidInitializeHeadersDoNotRetainGhostSessionOrPromptForApproval() async throws {
        #if DEBUG
            let promptCounter = PromptCounter()
            try await withRoutingManager(approvalHandler: { _ in
                await promptCounter.increment()
                return .allow(alwaysAllow: false)
            }) { manager, token in
                let response = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    post(
                        body: initializeBody(),
                        token: token,
                        headers: ["Accept": "application/json"]
                    )
                )

                XCTAssertGreaterThanOrEqual(response.statusCode, 400)
                XCTAssertTrue(try errorMessage(response).contains("Accept header"))
                let sessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCount, 0)
                let promptCount = await promptCounter.value
                XCTAssertEqual(promptCount, 0)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testDuplicateSensitiveInitializeHeaderFailsClosedWithoutCreatingSession() async throws {
        #if DEBUG
            try await withRoutingManager { manager, token in
                let response = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    post(body: initializeBody(), token: token, duplicateHeaderNames: [MCPNetworkHTTPHeader.authorization.lowercased()])
                )

                XCTAssertEqual(response.statusCode, 400)
                XCTAssertTrue(try errorMessage(response).contains("Duplicate security-sensitive HTTP header"))
                let sessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCount, 0)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testValidExistingSessionGetRoutesToSDKSSEStreamInsteadOf405() async throws {
        #if DEBUG
            try await withRoutingManager { manager, token in
                let initializeResponse = await initialize(manager: manager, token: token)
                let sessionID = try XCTUnwrap(initializeResponse.headers[MCPNetworkHTTPHeader.sessionID])

                let getResponse = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    get(sessionID: sessionID, token: token)
                )

                XCTAssertEqual(getResponse.statusCode, 200)
                XCTAssertEqual(getResponse.headers[MCPNetworkHTTPHeader.sessionID], sessionID)
                XCTAssertEqual(header(getResponse, "Content-Type"), "text/event-stream")
                if case .stream = getResponse.body {
                    // Valid existing-session GET now reaches StatefulHTTPServerTransport.
                } else {
                    XCTFail("Expected valid-session GET to return an SDK SSE stream")
                }
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testDeleteSuccessRemovesRepoPromptSessionMaps() async throws {
        #if DEBUG
            try await withRoutingManager { manager, token in
                let initializeResponse = await initialize(manager: manager, token: token)
                let sessionID = try XCTUnwrap(initializeResponse.headers[MCPNetworkHTTPHeader.sessionID])
                let initialSessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(initialSessionCount, 1)

                let deleteResponse = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    delete(sessionID: sessionID, token: token)
                )

                XCTAssertEqual(deleteResponse.statusCode, 200)
                let sessionCountAfterDelete = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCountAfterDelete, 0)

                let staleResponse = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    get(sessionID: sessionID, token: token)
                )
                XCTAssertEqual(staleResponse.statusCode, 404)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testUnknownSessionFailsClosedBeforeApprovalAndDoesNotReturn405ForGet() async throws {
        #if DEBUG
            let promptCounter = PromptCounter()
            try await withRoutingManager(approvalHandler: { _ in
                await promptCounter.increment()
                return .allow(alwaysAllow: false)
            }) { manager, token in
                let response = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    get(sessionID: "unknown-session", token: token)
                )

                XCTAssertEqual(response.statusCode, 404)
                let promptCount = await promptCounter.value
                XCTAssertEqual(promptCount, 0)
                XCTAssertTrue(try errorMessage(response).contains("Invalid or expired MCP-Session-Id"))
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testSessionlessGetAndDeleteFailBeforeApproval() async throws {
        #if DEBUG
            let promptCounter = PromptCounter()
            try await withRoutingManager(approvalHandler: { _ in
                await promptCounter.increment()
                return .allow(alwaysAllow: false)
            }) { manager, token in
                let getResponse = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    requestWithoutSession(method: "GET", token: token)
                )
                let deleteResponse = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    requestWithoutSession(method: "DELETE", token: token)
                )

                XCTAssertEqual(getResponse.statusCode, 400)
                XCTAssertEqual(deleteResponse.statusCode, 400)
                XCTAssertTrue(try errorMessage(getResponse).contains("Missing MCP-Session-Id"))
                XCTAssertTrue(try errorMessage(deleteResponse).contains("Missing MCP-Session-Id"))
                let promptCount = await promptCounter.value
                XCTAssertEqual(promptCount, 0)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testExistingSessionFromDifferentPrivateSourceRoutesToSDKSSEStream() async throws {
        #if DEBUG
            try await withRoutingManager { manager, token in
                let initializeResponse = await initialize(manager: manager, token: token)
                let sessionID = try XCTUnwrap(initializeResponse.headers[MCPNetworkHTTPHeader.sessionID])
                let initialSessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(initialSessionCount, 1)

                let response = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    get(sessionID: sessionID, token: token, remoteAddress: "10.42.0.17:54321")
                )

                XCTAssertEqual(response.statusCode, 200)
                XCTAssertEqual(response.headers[MCPNetworkHTTPHeader.sessionID], sessionID)
                XCTAssertEqual(header(response, "Content-Type"), "text/event-stream")
                let sessionCountAfterRoam = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCountAfterRoam, 1)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testExistingSessionFromPublicSourceFailsClosedAndRemovesSession() async throws {
        #if DEBUG
            try await withRoutingManager { manager, token in
                let initializeResponse = await initialize(manager: manager, token: token)
                let sessionID = try XCTUnwrap(initializeResponse.headers[MCPNetworkHTTPHeader.sessionID])
                let initialSessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(initialSessionCount, 1)

                let response = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    get(sessionID: sessionID, token: token, remoteAddress: "8.8.8.8:54321")
                )

                XCTAssertEqual(response.statusCode, 403)
                XCTAssertTrue(try errorMessage(response).contains("Remote MCP source is not private/LAN/link-local"))
                let sessionCountAfterPublicSource = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCountAfterPublicSource, 0)

                let staleResponse = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    get(sessionID: sessionID, token: token)
                )
                XCTAssertEqual(staleResponse.statusCode, 404)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    func testExistingSessionTokenFingerprintMismatchRemovesSession() async throws {
        #if DEBUG
            try await withRoutingManager { manager, token in
                let initializeResponse = await initialize(manager: manager, token: token)
                let sessionID = try XCTUnwrap(initializeResponse.headers[MCPNetworkHTTPHeader.sessionID])
                let initialSessionCount = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(initialSessionCount, 1)

                let rotatedToken = "rotated-token"
                await manager.debugSetNetworkMCPBearerTokenOverride(rotatedToken)
                let response = await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                    get(sessionID: sessionID, token: rotatedToken)
                )

                XCTAssertEqual(response.statusCode, 403)
                let sessionCountAfterMismatch = await manager.debugNetworkMCPHTTPSessionCount()
                XCTAssertEqual(sessionCountAfterMismatch, 0)
            }
        #else
            throw XCTSkip("Network MCP routing seams are DEBUG-only")
        #endif
    }

    #if DEBUG
        private actor PromptCounter {
            private var count = 0

            func increment() {
                count += 1
            }

            var value: Int {
                count
            }
        }

        private func withRoutingManager(
            approvalHandler: @escaping ServerNetworkManager.RemoteClientApprovalHandler = { _ in .allow(alwaysAllow: false) },
            operation: (ServerNetworkManager, String) async throws -> Void
        ) async throws {
            let manager = ServerNetworkManager()
            let token = "network-routing-token-\(UUID().uuidString)"
            await manager.debugSetNetworkMCPBearerTokenOverride(token)
            await manager.setRemoteClientApprovalHandler(approvalHandler)
            do {
                try await operation(manager, token)
                await manager.stop()
            } catch {
                await manager.stop()
                throw error
            }
        }

        private func initialize(manager: ServerNetworkManager, token: String) async -> MCPNetworkHTTPResponse {
            await manager.debugHandleNetworkHTTPRequestForNetworkMCPRoutingTest(
                post(body: initializeBody(), token: token)
            )
        }
    #endif

    private func post(
        body: Data,
        token: String,
        headers headerOverrides: [String: String] = [:],
        duplicateHeaderNames: Set<String> = []
    ) -> MCPNetworkHTTPRequest {
        var headers = [
            MCPNetworkHTTPHeader.authorization: "Bearer \(token)",
            MCPNetworkHTTPHeader.contentType: "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": "NetworkRoutingTest/1.0"
        ]
        for (key, value) in headerOverrides {
            headers[key] = value
        }
        return MCPNetworkHTTPRequest(
            method: "POST",
            path: "/mcp",
            headers: headers,
            body: body,
            remoteAddress: "127.0.0.1:54321",
            duplicateHeaderNames: duplicateHeaderNames
        )
    }

    private func get(sessionID: String, token: String, remoteAddress: String = "127.0.0.1:54321") -> MCPNetworkHTTPRequest {
        MCPNetworkHTTPRequest(
            method: "GET",
            path: "/mcp",
            headers: [
                MCPNetworkHTTPHeader.authorization: "Bearer \(token)",
                MCPNetworkHTTPHeader.sessionID: sessionID,
                "Accept": "text/event-stream",
                "User-Agent": "NetworkRoutingTest/1.0"
            ],
            remoteAddress: remoteAddress
        )
    }

    private func delete(sessionID: String, token: String) -> MCPNetworkHTTPRequest {
        MCPNetworkHTTPRequest(
            method: "DELETE",
            path: "/mcp",
            headers: [
                MCPNetworkHTTPHeader.authorization: "Bearer \(token)",
                MCPNetworkHTTPHeader.sessionID: sessionID,
                "User-Agent": "NetworkRoutingTest/1.0"
            ],
            remoteAddress: "127.0.0.1:54321"
        )
    }

    private func requestWithoutSession(method: String, token: String) -> MCPNetworkHTTPRequest {
        var headers = [
            MCPNetworkHTTPHeader.authorization: "Bearer \(token)",
            "User-Agent": "NetworkRoutingTest/1.0"
        ]
        if method == "GET" {
            headers["Accept"] = "text/event-stream"
        }
        return MCPNetworkHTTPRequest(
            method: method,
            path: "/mcp",
            headers: headers,
            remoteAddress: "127.0.0.1:54321"
        )
    }

    private func initializeBody() -> Data {
        jsonData([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": Version.latest,
                "capabilities": [:],
                "clientInfo": ["name": "NetworkRoutingTest", "version": "1.0"]
            ]
        ])
    }

    private func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func header(_ response: MCPNetworkHTTPResponse, _ name: String) -> String? {
        let lowercased = name.lowercased()
        return response.headers.first { $0.key.lowercased() == lowercased }?.value
    }

    private func diagnostic(_ response: MCPNetworkHTTPResponse) -> String {
        if let message = try? errorMessage(response) {
            return message
        }
        return "status=\(response.statusCode) headers=\(response.headers)"
    }

    private func errorMessage(_ response: MCPNetworkHTTPResponse) throws -> String {
        let body = try XCTUnwrap(response.bodyData)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        return try XCTUnwrap(error["message"] as? String)
    }
}
