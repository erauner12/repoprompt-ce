import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class NetworkMCPHTTPAdapterTests: XCTestCase {
    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String

        func generateSessionID() -> String {
            sessionID
        }
    }

    func testSDKStatefulTransportAndSessionIDGeneratorAreAvailableAtCurrentPin() async throws {
        let generator = FixedSessionIDGenerator(sessionID: "fixed-session")
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: generator,
            validationPipeline: StandardValidationPipeline(validators: [
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator()
            ])
        )

        XCTAssertEqual(generator.generateSessionID(), "fixed-session")
        try await transport.connect()
        await transport.disconnect()
    }

    func testSDKValidationTypesAreAvailableAtCurrentPin() {
        let pipeline = StandardValidationPipeline(validators: [
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator()
        ])
        let request = MCP.HTTPRequest(
            method: "GET",
            headers: [
                "Accept": "text/event-stream",
                MCPStreamableHTTPHeader.sessionID: "session-1"
            ],
            path: "/mcp"
        )
        let context = HTTPValidationContext(httpMethod: "GET", sessionID: "session-1")

        XCTAssertNil(pipeline.validate(request, context: context))
    }

    func testRequestConvertsToSDKHTTPRequest() {
        let body = Data("{}".utf8)
        let request = MCPStreamableHTTPRequest(
            method: "POST",
            path: "/mcp",
            headers: ["Content-Type": "application/json"],
            body: body,
            remoteAddress: "192.168.1.10"
        )

        let sdkRequest = request.sdkHTTPRequest()

        XCTAssertEqual(sdkRequest.method, "POST")
        XCTAssertEqual(sdkRequest.path, "/mcp")
        XCTAssertEqual(sdkRequest.header("content-type"), "application/json")
        XCTAssertEqual(sdkRequest.body, body)
    }

    func testEmptyRequestBodyConvertsToNilSDKBody() {
        let request = MCPStreamableHTTPRequest(method: "GET", path: "/mcp")

        let sdkRequest = request.sdkHTTPRequest()

        XCTAssertEqual(sdkRequest.method, "GET")
        XCTAssertEqual(sdkRequest.path, "/mcp")
        XCTAssertNil(sdkRequest.body)
    }

    func testFiniteSDKResponseConversionPreservesStatusHeadersAndBody() {
        let body = Data(#"{"jsonrpc":"2.0","result":{}}"#.utf8)
        let sdkResponse = MCP.HTTPResponse.data(body, headers: ["Content-Type": "application/json"])

        let response = MCPStreamableHTTPResponse.fromSDK(sdkResponse)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json")
        XCTAssertEqual(response.bodyData, body)
    }

    func testSDKErrorResponseConversionKeepsJSONBodyAndSessionHeader() throws {
        let sdkResponse = MCP.HTTPResponse.error(
            statusCode: 400,
            .invalidRequest("Bad request"),
            sessionID: "session-1"
        )

        let response = MCPStreamableHTTPResponse.fromSDK(sdkResponse)

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(response.headers[MCPStreamableHTTPHeader.sessionID], "session-1")
        XCTAssertEqual(response.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(response.bodyData)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(object["error"])
    }

    func testSDKStreamResponseConversionPreservesOpaqueStreamBody() {
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data: {}\n\n".utf8))
        }
        let sdkResponse = MCP.HTTPResponse.stream(stream, headers: ["Content-Type": "text/event-stream"])

        let response = MCPStreamableHTTPResponse.fromSDK(sdkResponse)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/event-stream")
        XCTAssertNil(response.bodyData)
        if case .stream = response.body {
            // Stream body is intentionally preserved opaquely and not consumed by this adapter test.
        } else {
            XCTFail("Expected SDK stream response to convert to a stream body")
        }
    }
}
