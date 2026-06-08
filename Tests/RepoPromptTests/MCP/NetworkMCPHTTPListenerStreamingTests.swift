import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class NetworkMCPHTTPListenerStreamingTests: XCTestCase {
    func testStreamingResponsePreservesHeadersAndWritesOpaqueChunkedSSE() async throws {
        let chunks = [
            Data("event: custom\r\ndata: one\n\n".utf8),
            Data(":keepalive\n\ndata: two\n\n".utf8)
        ]

        try await withListener(response: .streaming(headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache, no-transform",
            "Connection": "keep-alive",
            MCPNetworkHTTPHeader.sessionID: "session-stream",
            "X-Local-Header": "kept",
            "Content-Length": "999"
        ], chunks: chunks)) { port in
            let socket = try RawTCPSocket(port: port)
            try socket.sendHTTPRequest(path: "/mcp")

            var raw = Data()
            try socket.receive(into: &raw) { data in
                data.headerBodySplit != nil
            }
            let headerResponse = try RawHTTPResponse(raw)

            XCTAssertEqual(headerResponse.statusLine, "HTTP/1.1 200 OK")
            XCTAssertEqual(headerResponse.header("content-type"), "text/event-stream")
            XCTAssertEqual(headerResponse.header("cache-control"), "no-cache, no-transform")
            XCTAssertEqual(headerResponse.header("connection"), "keep-alive")
            XCTAssertEqual(headerResponse.header("mcp-session-id"), "session-stream")
            XCTAssertEqual(headerResponse.header("x-local-header"), "kept")
            XCTAssertNil(headerResponse.header("content-length"))
            XCTAssertEqual(headerResponse.header("transfer-encoding"), "chunked")

            try socket.receive(into: &raw) { data in
                guard let response = try? RawHTTPResponse(data) else { return false }
                return (try? response.decodedChunkedBody()) != nil
            }
            let completeResponse = try RawHTTPResponse(raw)

            XCTAssertEqual(try completeResponse.decodedChunkedBody(), chunks)
        }
    }

    func testFiniteResponseStillWritesContentLengthBodyAndEnd() async throws {
        let body = Data("finite".utf8)

        try await withListener(response: .finite(headers: ["Content-Type": "application/json"], body: body)) { port in
            let socket = try RawTCPSocket(port: port)
            try socket.sendHTTPRequest(path: "/mcp")

            var raw = Data()
            try socket.receive(into: &raw) { data in
                guard let response = try? RawHTTPResponse(data),
                      let contentLength = response.contentLength
                else { return false }
                return response.body.count >= contentLength
            }
            let response = try RawHTTPResponse(raw)

            XCTAssertEqual(response.statusLine, "HTTP/1.1 200 OK")
            XCTAssertEqual(response.header("content-type"), "application/json")
            XCTAssertEqual(response.header("content-length"), String(body.count))
            XCTAssertEqual(response.header("connection"), "keep-alive")
            XCTAssertNil(response.header("transfer-encoding"))
            XCTAssertEqual(response.body.prefix(body.count), body)
        }
    }

    func testPipelinedFiniteRequestClosesAfterDelayedFirstResponseWithoutHandlingSecondRequest() async throws {
        let responder = DelayedFirstFiniteResponder()
        let slowBody = Data("slow-response".utf8)

        try await withListener(requestHandler: { request in
            await responder.handle(request)
        }) { port in
            let socket = try RawTCPSocket(port: port)
            try socket.sendHTTPRequest(path: "/slow")
            try socket.sendHTTPRequest(path: "/fast")

            try await responder.waitUntilSlowRequestArrives()
            try await Task.sleep(nanoseconds: 100_000_000)
            var handledPaths = await responder.handledPaths
            XCTAssertEqual(handledPaths, ["/slow"], "Pipelined finite request should not be handled while the first response is in flight")

            await responder.finishSlowRequest()

            var raw = Data()
            try socket.receiveUntilEOF(into: &raw)
            let response = try RawHTTPResponse(raw)

            XCTAssertEqual(response.statusLine, "HTTP/1.1 200 OK")
            XCTAssertEqual(response.header("content-type"), "text/plain")
            XCTAssertEqual(response.header("content-length"), String(slowBody.count))
            XCTAssertEqual(response.body.prefix(slowBody.count), slowBody)
            XCTAssertEqual(raw.httpStatusLineCount, 1, "Only the delayed first response should be written before the connection closes")
            XCTAssertFalse(String(data: raw, encoding: .utf8)?.contains("fast-response") ?? false)

            handledPaths = await responder.handledPaths
            XCTAssertEqual(handledPaths, ["/slow"])
        }
    }

    func testOversizedBodyReturns413WithoutCallingRequestHandler() async throws {
        let counter = HandlerCallCounter()
        let oversizedBody = Data(repeating: 0x61, count: (8 * 1024 * 1024) + 1)

        try await withListener(requestHandler: { _ in
            await counter.increment()
            return MCPNetworkHTTPResponse(statusCode: 200)
        }) { port in
            let socket = try RawTCPSocket(port: port)
            try socket.sendHTTPPost(path: "/mcp", headers: [("Content-Type", "application/json")], body: oversizedBody)

            var raw = Data()
            try socket.receive(into: &raw) { data in
                guard let response = try? RawHTTPResponse(data),
                      let contentLength = response.contentLength
                else { return false }
                return response.body.count >= contentLength
            }
            let response = try RawHTTPResponse(raw)

            XCTAssertEqual(response.statusLine, "HTTP/1.1 413 Payload Too Large")
            let callCount = await counter.value
            XCTAssertEqual(callCount, 0)
        }
    }

    func testDuplicateSensitiveHeaderReturns400WithoutCallingRequestHandler() async throws {
        let counter = HandlerCallCounter()

        try await withListener(requestHandler: { _ in
            await counter.increment()
            return MCPNetworkHTTPResponse(statusCode: 200)
        }) { port in
            let socket = try RawTCPSocket(port: port)
            try socket.sendHTTPPost(
                path: "/mcp",
                headers: [
                    ("Authorization", "Bearer one"),
                    ("Authorization", "Bearer two"),
                    ("Content-Type", "application/json")
                ],
                body: Data("{}".utf8)
            )

            var raw = Data()
            try socket.receive(into: &raw) { data in
                guard let response = try? RawHTTPResponse(data),
                      let contentLength = response.contentLength
                else { return false }
                return response.body.count >= contentLength
            }
            let response = try RawHTTPResponse(raw)

            XCTAssertEqual(response.statusLine, "HTTP/1.1 400 Bad Request")
            let callCount = await counter.value
            XCTAssertEqual(callCount, 0)
        }
    }

    func testStreamErrorClosesChannelCleanlyAfterLastWrittenChunk() async throws {
        let chunk = Data("data: before-error\n\n".utf8)

        try await withListener(response: .failingStream(chunk: chunk)) { port in
            let socket = try RawTCPSocket(port: port)
            try socket.sendHTTPRequest(path: "/mcp")

            var raw = Data()
            try socket.receiveUntilEOF(into: &raw)
            let response = try RawHTTPResponse(raw)

            XCTAssertEqual(response.statusLine, "HTTP/1.1 200 OK")
            XCTAssertEqual(response.header("transfer-encoding"), "chunked")
            XCTAssertTrue(response.body.contains(chunk), "Expected stream chunk to pass through before the channel closed")
            XCTAssertNil(try? response.decodedChunkedBody(), "A stream error should close the channel instead of writing a normal terminal chunk")
        }
    }

    private enum ListenerResponse {
        case finite(headers: [String: String], body: Data)
        case streaming(headers: [String: String], chunks: [Data])
        case failingStream(chunk: Data)
    }

    private enum ListenerTestError: Error {
        case streamFailed
    }

    private actor HandlerCallCounter {
        private var count = 0

        func increment() {
            count += 1
        }

        var value: Int {
            count
        }
    }

    private actor DelayedFirstFiniteResponder {
        private var paths: [String] = []
        private var slowContinuation: CheckedContinuation<Void, Never>?

        var handledPaths: [String] {
            paths
        }

        func handle(_ request: MCPNetworkHTTPRequest) async -> MCPNetworkHTTPResponse {
            paths.append(request.path)
            if request.path == "/slow" {
                await withCheckedContinuation { continuation in
                    slowContinuation = continuation
                }
                return MCPNetworkHTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/plain"],
                    body: .data(Data("slow-response".utf8))
                )
            }

            return MCPNetworkHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/plain"],
                body: .data(Data("fast-response".utf8))
            )
        }

        func waitUntilSlowRequestArrives() async throws {
            let deadline = Date().addingTimeInterval(2)
            while slowContinuation == nil {
                if Date() >= deadline {
                    XCTFail("Timed out waiting for delayed first request")
                    return
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        func finishSlowRequest() {
            slowContinuation?.resume()
            slowContinuation = nil
        }
    }

    private func withListener(
        response: ListenerResponse,
        run: (Int) async throws -> Void
    ) async throws {
        try await withListener(requestHandler: { _ in
            switch response {
            case let .finite(headers, body):
                MCPNetworkHTTPResponse(statusCode: 200, headers: headers, body: .data(body))
            case let .streaming(headers, chunks):
                MCPNetworkHTTPResponse(statusCode: 200, headers: headers, body: .stream(AsyncThrowingStream { continuation in
                    Task {
                        for chunk in chunks {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    }
                }))
            case let .failingStream(chunk):
                MCPNetworkHTTPResponse(statusCode: 200, headers: [
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache, no-transform",
                    "Connection": "keep-alive"
                ], body: .stream(AsyncThrowingStream { continuation in
                    Task {
                        continuation.yield(chunk)
                        continuation.finish(throwing: ListenerTestError.streamFailed)
                    }
                }))
            }
        }, run: run)
    }

    private func withListener(
        requestHandler: @escaping MCPNetworkHTTPListener.RequestHandler,
        run: (Int) async throws -> Void
    ) async throws {
        let listener = MCPNetworkHTTPListener(configuration: .init(bindAddress: "127.0.0.1", port: 0), requestHandler: requestHandler)
        try await listener.start()
        guard let port = await listener.boundPort() else {
            await listener.stop()
            XCTFail("Expected listener to expose bound ephemeral port")
            return
        }

        do {
            try await run(port)
            await listener.stop()
        } catch {
            await listener.stop()
            throw error
        }
    }
}

private final class RawTCPSocket {
    private var fd: Int32

    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current() }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError.current() }
    }

    deinit {
        close()
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    func sendHTTPRequest(path: String) throws {
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n"
        try sendAll(Data(request.utf8))
    }

    func sendHTTPPost(path: String, headers: [(String, String)], body: Data) throws {
        var request = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers {
            request += "\(name): \(value)\r\n"
        }
        request += "\r\n"
        try sendAll(Data(request.utf8))
        try sendAll(body)
    }

    func receive(into data: inout Data, until isComplete: (Data) -> Bool) throws {
        while !isComplete(data) {
            let received = try receiveOnce()
            guard !received.isEmpty else { return }
            data.append(received)
        }
    }

    func receiveUntilEOF(into data: inout Data) throws {
        while true {
            let received = try receiveOnce()
            guard !received.isEmpty else { return }
            data.append(received)
        }
    }

    private func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let result = Darwin.send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
                guard result > 0 else { throw POSIXError.current() }
                sent += result
            }
        }
    }

    private func receiveOnce() throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        if count > 0 {
            return Data(buffer.prefix(count))
        }
        if count == 0 {
            return Data()
        }
        throw POSIXError.current()
    }
}

private struct RawHTTPResponse {
    let statusLine: String
    let headers: [String: String]
    let body: Data

    var contentLength: Int? {
        header("content-length").flatMap(Int.init)
    }

    init(_ raw: Data) throws {
        guard let split = raw.headerBodySplit else { throw RawHTTPError.missingHeaderTerminator }
        let headData = raw[..<split.headerEnd]
        guard let head = String(data: headData, encoding: .utf8) else { throw RawHTTPError.invalidHeaderEncoding }
        var lines = head.components(separatedBy: "\r\n")
        statusLine = lines.removeFirst()
        var parsedHeaders: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            parsedHeaders[name] = value
        }
        headers = parsedHeaders
        body = Data(raw[split.bodyStart...])
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    func decodedChunkedBody() throws -> [Data] {
        let crlf = Data("\r\n".utf8)
        var chunks: [Data] = []
        var index = body.startIndex

        while true {
            guard let lineRange = body[index...].range(of: crlf) else { throw RawHTTPError.incompleteChunkedBody }
            guard let line = String(data: body[index ..< lineRange.lowerBound], encoding: .ascii),
                  let sizeText = line.split(separator: ";", maxSplits: 1).first,
                  let size = Int(sizeText, radix: 16)
            else { throw RawHTTPError.invalidChunkSize }
            index = lineRange.upperBound

            if size == 0 {
                guard body[index...].starts(with: crlf) else { throw RawHTTPError.incompleteChunkedBody }
                return chunks
            }

            let chunkEnd = index + size
            let crlfEnd = chunkEnd + crlf.count
            guard crlfEnd <= body.endIndex else { throw RawHTTPError.incompleteChunkedBody }
            chunks.append(Data(body[index ..< chunkEnd]))
            guard body[chunkEnd ..< crlfEnd].elementsEqual(crlf) else { throw RawHTTPError.invalidChunkTerminator }
            index = crlfEnd
        }
    }
}

private enum RawHTTPError: Error {
    case missingHeaderTerminator
    case invalidHeaderEncoding
    case incompleteChunkedBody
    case invalidChunkSize
    case invalidChunkTerminator
}

private extension POSIXError {
    static func current() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private extension Data {
    var headerBodySplit: (headerEnd: Index, bodyStart: Index)? {
        guard let range = range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return (range.lowerBound, range.upperBound)
    }

    var httpStatusLineCount: Int {
        guard let text = String(data: self, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "HTTP/1.1 ").count - 1
    }
}
