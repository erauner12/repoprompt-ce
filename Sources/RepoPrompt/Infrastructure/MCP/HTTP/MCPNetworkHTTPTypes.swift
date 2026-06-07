import Foundation
import MCP

struct MCPStreamableHTTPRequest: Equatable {
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

struct MCPStreamableHTTPResponse {
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

    static func fromSDK(_ response: MCP.HTTPResponse) -> MCPStreamableHTTPResponse {
        switch response {
        case let .stream(stream, headers):
            MCPStreamableHTTPResponse(statusCode: response.statusCode, headers: headers, body: .stream(stream))
        default:
            MCPStreamableHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: response.bodyData)
        }
    }

    static func accepted(headers: [String: String] = [:]) -> MCPStreamableHTTPResponse {
        MCPStreamableHTTPResponse(statusCode: 202, headers: headers)
    }

    static func ok(headers: [String: String] = [:], body: Data? = nil) -> MCPStreamableHTTPResponse {
        MCPStreamableHTTPResponse(statusCode: 200, headers: headers, body: body)
    }

    static func json(_ data: Data, headers: [String: String] = [:]) -> MCPStreamableHTTPResponse {
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json"
        return MCPStreamableHTTPResponse(statusCode: 200, headers: responseHeaders, body: data)
    }

    static func error(
        statusCode: Int,
        message: String,
        code: Int = -32600,
        sessionID: String? = nil,
        extraHeaders: [String: String] = [:],
        id: Any? = nil
    ) -> MCPStreamableHTTPResponse {
        error(statusCode: statusCode, bodyObject: errorObject(message: message, code: code, id: id), sessionID: sessionID, extraHeaders: extraHeaders)
    }

    static func batchError(statusCode: Int, message: String, code: Int, sessionID: String? = nil, ids: [Any?]) -> MCPStreamableHTTPResponse {
        let bodyObject = ids.map { errorObject(message: message, code: code, id: $0) }
        return error(statusCode: statusCode, bodyObject: bodyObject, sessionID: sessionID)
    }

    private static func error(statusCode: Int, bodyObject: Any, sessionID: String?, extraHeaders: [String: String] = [:]) -> MCPStreamableHTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = "application/json"
        if let sessionID {
            headers[MCPStreamableHTTPHeader.sessionID] = sessionID
        }
        let body = try? JSONSerialization.data(withJSONObject: bodyObject, options: [])
        return MCPStreamableHTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private static func errorObject(message: String, code: Int, id: Any?) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
            "id": id ?? NSNull()
        ]
    }
}

enum MCPStreamableHTTPHeader {
    static let sessionID = "MCP-Session-Id"
    static let authorization = "Authorization"
    static let contentType = "Content-Type"
    static let allow = "Allow"
}
