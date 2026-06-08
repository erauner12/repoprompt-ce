import Foundation
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

actor MCPNetworkHTTPListener {
    typealias RequestHandler = @Sendable (MCPNetworkHTTPRequest) async -> MCPNetworkHTTPResponse

    struct Configuration: Equatable {
        var bindAddress: String
        var port: Int

        init(bindAddress: String, port: Int) {
            self.bindAddress = bindAddress
            self.port = port
        }
    }

    private let configuration: Configuration
    private let requestHandler: RequestHandler
    private let logger: Logger
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    init(configuration: Configuration, logger: Logger? = nil, requestHandler: @escaping RequestHandler) {
        self.configuration = configuration
        self.requestHandler = requestHandler
        self.logger = logger ?? Logger(label: "com.repoprompt.mcp.http.listener")
    }

    func start() async throws {
        guard channel == nil else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [requestHandler, logger] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPNetworkHTTPChannelHandler(
                        requestHandler: requestHandler,
                        logger: logger
                    ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: false)

        do {
            channel = try await bootstrap.bind(host: configuration.bindAddress, port: configuration.port).get()
            logger.notice("Network MCP HTTP listener bound to \(configuration.bindAddress):\(configuration.port)")
        } catch {
            self.group = nil
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        let channel = channel
        let group = group
        self.channel = nil
        self.group = nil

        if let channel {
            try? await channel.close().get()
        }
        if let group {
            try? await group.shutdownGracefully()
        }
    }

    func boundPort() -> Int? {
        channel?.localAddress?.port
    }
}

private final class MCPNetworkHTTPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let requestHandler: MCPNetworkHTTPListener.RequestHandler
    private let logger: Logger
    private var currentHead: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()
    private let maxBodyBytes = 8 * 1024 * 1024
    private var activeStreamTask: Task<Void, Never>?
    private var activeStreamTaskID = 0
    private var closingForActiveStreamRequest = false
    private var bodyTooLarge = false

    init(requestHandler: @escaping MCPNetworkHTTPListener.RequestHandler, logger: Logger) {
        self.requestHandler = requestHandler
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if closingForActiveStreamRequest {
            return
        }

        switch unwrapInboundIn(data) {
        case let .head(head):
            guard activeStreamTask == nil else {
                logger.warning("Network MCP HTTP channel received another request while a stream response is active; closing channel")
                closingForActiveStreamRequest = true
                context.close(promise: nil)
                return
            }
            currentHead = head
            bodyBuffer.clear()
            bodyTooLarge = false
        case var .body(part):
            guard !bodyTooLarge else { return }
            if bodyBuffer.readableBytes + part.readableBytes <= maxBodyBytes {
                bodyBuffer.writeBuffer(&part)
            } else {
                bodyTooLarge = true
                bodyBuffer.clear()
            }
        case .end:
            guard let head = currentHead else {
                writeResponse(.error(statusCode: 400, message: "Missing HTTP request head"), context: context)
                return
            }
            guard !bodyTooLarge else {
                currentHead = nil
                bodyBuffer.clear()
                bodyTooLarge = false
                writeResponse(.error(statusCode: 413, message: "HTTP request body exceeds maximum size"), context: context)
                return
            }
            guard !head.hasDuplicateSensitiveMCPHeaders else {
                currentHead = nil
                bodyBuffer.clear()
                writeResponse(.error(statusCode: 400, message: "Duplicate security-sensitive HTTP header"), context: context)
                return
            }
            let body = Data(bodyBuffer.readBytes(length: bodyBuffer.readableBytes) ?? [])
            currentHead = nil
            bodyBuffer.clear()
            let request = makeRequest(head: head, body: body, context: context)
            Task { [requestHandler] in
                let response = await requestHandler(request)
                context.eventLoop.execute { [weak self] in
                    self?.writeResponse(response, context: context)
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closingForActiveStreamRequest = false
        cancelActiveStreamTask()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("Network MCP HTTP channel error: \(String(describing: error))")
        cancelActiveStreamTask()
        context.close(promise: nil)
    }

    private func makeRequest(head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) -> MCPNetworkHTTPRequest {
        var headers: [String: String] = [:]
        var seenHeaderNames: Set<String> = []
        var duplicateHeaderNames: Set<String> = []
        for header in head.headers {
            let lowercasedName = header.name.lowercased()
            if !seenHeaderNames.insert(lowercasedName).inserted {
                duplicateHeaderNames.insert(lowercasedName)
            }
            headers[header.name] = header.value
        }
        let path = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? head.uri
        return MCPNetworkHTTPRequest(
            method: head.method.rawValue,
            path: path,
            headers: headers,
            body: body,
            remoteAddress: context.channel.remoteAddress?.ipAddress ?? context.channel.remoteAddress?.description ?? "unknown",
            duplicateHeaderNames: duplicateHeaderNames
        )
    }

    private func writeResponse(_ response: MCPNetworkHTTPResponse, context: ChannelHandlerContext) {
        switch response.body {
        case .none, .data:
            writeFiniteResponse(response, context: context)
        case let .stream(stream):
            writeStreamingResponse(response, stream: stream, context: context)
        }
    }

    private func writeFiniteResponse(_ response: MCPNetworkHTTPResponse, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.replaceOrAdd(name: name, value: value)
        }
        let finiteBody = response.bodyData
        if let finiteBody {
            headers.replaceOrAdd(name: "Content-Length", value: String(finiteBody.count))
        } else {
            headers.replaceOrAdd(name: "Content-Length", value: "0")
        }
        if headers["Connection"].isEmpty {
            headers.replaceOrAdd(name: "Connection", value: "keep-alive")
        }

        let status = HTTPResponseStatus(statusCode: response.statusCode)
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        if let finiteBody, !finiteBody.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: finiteBody.count)
            buffer.writeBytes(finiteBody)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func writeStreamingResponse(
        _ response: MCPNetworkHTTPResponse,
        stream: AsyncThrowingStream<Data, Error>,
        context: ChannelHandlerContext
    ) {
        cancelActiveStreamTask()
        activeStreamTaskID += 1
        let taskID = activeStreamTaskID

        var headers = HTTPHeaders()
        for (name, value) in response.headers where name.lowercased() != "content-length" {
            headers.replaceOrAdd(name: name, value: value)
        }
        if headers["Transfer-Encoding"].isEmpty {
            headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        }

        let status = HTTPResponseStatus(statusCode: response.statusCode)
        context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))))
            .whenFailure { [weak self] error in
                self?.logger.warning("Network MCP HTTP stream head write failed: \(String(describing: error))")
                self?.cancelActiveStreamTask()
            }

        activeStreamTask = Task { [weak self, weak context] in
            do {
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard let self, let context else { return }
                    let writeSucceeded = await writeStreamChunk(chunk, taskID: taskID, context: context)
                    guard writeSucceeded else { return }
                }
                guard !Task.isCancelled, let self, let context else { return }
                await finishStream(taskID: taskID, context: context)
            } catch is CancellationError {
                // Channel teardown owns cancellation; do not write after cancellation.
            } catch {
                guard let self, let context else { return }
                await closeStreamAfterError(error, taskID: taskID, context: context)
            }
        }
    }

    private func writeStreamChunk(_ chunk: Data, taskID: Int, context: ChannelHandlerContext) async -> Bool {
        await withCheckedContinuation { continuation in
            context.eventLoop.execute { [weak self, weak context] in
                guard let self, let context, activeStreamTaskID == taskID, context.channel.isActive else {
                    continuation.resume(returning: false)
                    return
                }
                var buffer = context.channel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer)))).whenComplete { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: true)
                    case let .failure(error):
                        self.logger.warning("Network MCP HTTP stream write failed: \(String(describing: error))")
                        self.cancelActiveStreamTask()
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    private func finishStream(taskID: Int, context: ChannelHandlerContext) async {
        await withCheckedContinuation { continuation in
            context.eventLoop.execute { [weak self, weak context] in
                guard let self, let context, activeStreamTaskID == taskID, context.channel.isActive else {
                    continuation.resume()
                    return
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                    if self.activeStreamTaskID == taskID {
                        self.activeStreamTask = nil
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func closeStreamAfterError(_ error: Error, taskID: Int, context: ChannelHandlerContext) async {
        await withCheckedContinuation { continuation in
            context.eventLoop.execute { [weak self, weak context] in
                guard let self, let context, activeStreamTaskID == taskID else {
                    continuation.resume()
                    return
                }
                logger.warning("Network MCP HTTP stream failed: \(String(describing: error))")
                activeStreamTask = nil
                context.close().whenComplete { _ in
                    continuation.resume()
                }
            }
        }
    }

    private func cancelActiveStreamTask() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeStreamTaskID += 1
    }
}

private extension HTTPRequestHead {
    var hasDuplicateSensitiveMCPHeaders: Bool {
        hasDuplicateHeader(MCPNetworkHTTPHeader.authorization) || hasDuplicateHeader(MCPNetworkHTTPHeader.sessionID)
    }

    func hasDuplicateHeader(_ name: String) -> Bool {
        headers[name].count > 1
    }
}

private extension EventLoopGroup {
    func shutdownGracefully() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
