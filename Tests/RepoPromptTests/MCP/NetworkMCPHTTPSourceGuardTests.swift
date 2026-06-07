import Foundation
@testable import RepoPrompt
import XCTest

final class NetworkMCPHTTPSourceGuardTests: XCTestCase {
    func testObsoleteLocalDirectJSONTransportFileIsRemoved() throws {
        let obsoleteTransportURL = try RepoRoot.url()
            .appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/HTTP/MCPStreamableHTTPTransport.swift")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: obsoleteTransportURL.path),
            "Network MCP should route through the upstream SDK StatefulHTTPServerTransport, not the removed local direct-JSON transport."
        )
    }

    func testHTTPConnectionManagerPreservesSDKSharedHandlerRegistrationPath() throws {
        let managerSource = try String(
            contentsOf: RepoRoot.url()
                .appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/HTTP/MCPHTTPConnectionManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(managerSource.contains("private let transport: MCP.StatefulHTTPServerTransport"))
        XCTAssertTrue(managerSource.contains("parentManager.registerHandlers(for: server, connectionID: connectionID)"))
        XCTAssertTrue(managerSource.contains("server.start(transport: transport)"))
        XCTAssertTrue(managerSource.contains("func handle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse"))
        XCTAssertTrue(managerSource.contains("transport.handleRequest(request)"))
        XCTAssertTrue(managerSource.contains("transport.send(data)"))
        XCTAssertFalse(managerSource.contains("transport.closed()"))
        XCTAssertFalse(managerSource.contains("GET SSE is not supported"))
        XCTAssertFalse(managerSource.contains("ServiceRegistry.services"))
        XCTAssertFalse(managerSource.contains("toolDef.callAsFunction"))
    }
}
