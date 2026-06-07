import Foundation
import MCP

struct MCPNetworkHTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var remoteAddress: String

    init(method: String, path: String, headers: [String: String] = [:], body: Data = Data(), remoteAddress: String = "127.0.0.1") {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        return headers.first { $0.key.lowercased() == lowercased }?.value
    }

    func sdkHTTPRequest() -> MCP.HTTPRequest {
        MCP.HTTPRequest(
            method: method,
            headers: headers,
            body: body.isEmpty ? nil : body,
            path: path
        )
    }
}

struct MCPNetworkHTTPResponse {
    enum Body {
        case none
        case data(Data)
        case stream(AsyncThrowingStream<Data, Swift.Error>)
    }

    var statusCode: Int
    var headers: [String: String]
    var body: Body

    init(statusCode: Int, headers: [String: String] = [:], body: Body = .none) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    init(statusCode: Int, headers: [String: String] = [:], body: Data?) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body.map(Body.data) ?? .none
    }

    var bodyData: Data? {
        if case let .data(data) = body { data } else { nil }
    }

    static func fromSDK(_ response: MCP.HTTPResponse) -> MCPNetworkHTTPResponse {
        switch response {
        case let .stream(stream, headers):
            MCPNetworkHTTPResponse(statusCode: response.statusCode, headers: headers, body: .stream(stream))
        default:
            MCPNetworkHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: response.bodyData)
        }
    }

    static func error(
        statusCode: Int,
        message: String,
        code: Int = -32600,
        sessionID: String? = nil,
        extraHeaders: [String: String] = [:],
        id: Any? = nil
    ) -> MCPNetworkHTTPResponse {
        error(statusCode: statusCode, bodyObject: errorObject(message: message, code: code, id: id), sessionID: sessionID, extraHeaders: extraHeaders)
    }

    private static func error(statusCode: Int, bodyObject: Any, sessionID: String?, extraHeaders: [String: String] = [:]) -> MCPNetworkHTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = "application/json"
        if let sessionID {
            headers[MCPNetworkHTTPHeader.sessionID] = sessionID
        }
        let body = try? JSONSerialization.data(withJSONObject: bodyObject, options: [])
        return MCPNetworkHTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private static func errorObject(message: String, code: Int, id: Any?) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
            "id": id ?? NSNull()
        ]
    }
}

enum MCPNetworkHTTPHeader {
    static let sessionID = "MCP-Session-Id"
    static let authorization = "Authorization"
    static let contentType = "Content-Type"
    static let allow = "Allow"
}
