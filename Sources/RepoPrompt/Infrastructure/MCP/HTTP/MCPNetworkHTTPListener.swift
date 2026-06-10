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
    private var childChannelRegistry: MCPNetworkHTTPChildChannelRegistry?

    init(configuration: Configuration, logger: Logger? = nil, requestHandler: @escaping RequestHandler) {
        self.configuration = configuration
        self.requestHandler = requestHandler
        self.logger = logger ?? Logger(label: "com.repoprompt.mcp.http.listener")
    }

    func start() async throws {
        guard channel == nil else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let childChannelRegistry = MCPNetworkHTTPChildChannelRegistry()
        self.group = group
        self.childChannelRegistry = childChannelRegistry

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [requestHandler, logger, childChannelRegistry] channel in
                childChannelRegistry.register(channel)
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPNetworkHTTPChannelHandler(
                        requestHandler: requestHandler,
                        logger: logger,
                        childChannelRegistry: childChannelRegistry
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
            self.childChannelRegistry = nil
            self.group = nil
            try? await childChannelRegistry.closeAll()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        let channel = channel
        let group = group
        let childChannelRegistry = childChannelRegistry
        self.channel = nil
        self.group = nil
        self.childChannelRegistry = nil

        if let channel {
            try? await channel.close().get()
        }
        if let childChannelRegistry {
            try? await childChannelRegistry.closeAll()
        }
        if let group {
            try? await group.shutdownGracefully()
        }
    }

    func boundPort() -> Int? {
        channel?.localAddress?.port
    }
}

private final class MCPNetworkHTTPChildChannelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]

    func register(_ channel: Channel) {
        lock.lock()
        channels[ObjectIdentifier(channel as AnyObject)] = channel
        lock.unlock()
    }

    func remove(_ channel: Channel) {
        lock.lock()
        channels.removeValue(forKey: ObjectIdentifier(channel as AnyObject))
        lock.unlock()
    }

    func closeAll() async throws {
        let snapshot: [Channel]
        lock.lock()
        snapshot = Array(channels.values)
        lock.unlock()

        for channel in snapshot {
            try? await channel.close().get()
        }
    }
}

private final class MCPNetworkHTTPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let requestHandler: MCPNetworkHTTPListener.RequestHandler
    private let logger: Logger
    private let childChannelRegistry: MCPNetworkHTTPChildChannelRegistry
    private var currentHead: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()
    private let maxBodyBytes = 8 * 1024 * 1024
    private var activeRequestTask: Task<Void, Never>?
    private var activeRequestID = 0
    private var requestInFlight = false
    private var closeAfterInFlightRequest = false
    private var activeStreamTask: Task<Void, Never>?
    private var activeStreamTerminationHandler: (@Sendable () -> Void)?
    private var activeStreamTaskID = 0
    private var closingForActiveStreamRequest = false
    private var bodyTooLarge = false

    init(
        requestHandler: @escaping MCPNetworkHTTPListener.RequestHandler,
        logger: Logger,
        childChannelRegistry: MCPNetworkHTTPChildChannelRegistry
    ) {
        self.requestHandler = requestHandler
        self.logger = logger
        self.childChannelRegistry = childChannelRegistry
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if closingForActiveStreamRequest || closeAfterInFlightRequest {
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
            guard !requestInFlight else {
                logger.warning("Network MCP HTTP channel received a pipelined request while a response is in flight; closing after current response")
                closeAfterInFlightRequest = true
                currentHead = nil
                bodyBuffer.clear()
                bodyTooLarge = false
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
            let requestID = beginRequest()
            activeRequestTask = Task { [requestHandler] in
                let response = await requestHandler(request)
                context.eventLoop.execute { [weak self] in
                    self?.writeResponse(response, requestID: requestID, context: context)
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closingForActiveStreamRequest = false
        closeAfterInFlightRequest = false
        childChannelRegistry.remove(context.channel)
        cancelActiveRequestTask()
        cancelActiveStreamTask(notifyTermination: true)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("Network MCP HTTP channel error: \(String(describing: error))")
        cancelActiveRequestTask()
        cancelActiveStreamTask(notifyTermination: true)
        childChannelRegistry.remove(context.channel)
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

    private func beginRequest() -> Int {
        requestInFlight = true
        activeRequestID += 1
        return activeRequestID
    }

    private func writeResponse(_ response: MCPNetworkHTTPResponse, context: ChannelHandlerContext) {
        writeResponse(response, requestID: nil, context: context)
    }

    private func writeResponse(_ response: MCPNetworkHTTPResponse, requestID: Int?, context: ChannelHandlerContext) {
        if let requestID {
            guard activeRequestID == requestID, requestInFlight, context.channel.isActive else { return }
        }

        switch response.body {
        case .none, .data:
            writeFiniteResponse(response, requestID: requestID, context: context)
        case let .stream(stream, onTermination):
            writeStreamingResponse(response, stream: stream, onTermination: onTermination, requestID: requestID, context: context)
        }
    }

    private func writeFiniteResponse(_ response: MCPNetworkHTTPResponse, requestID: Int?, context: ChannelHandlerContext) {
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
        if closeAfterInFlightRequest {
            headers.replaceOrAdd(name: "Connection", value: "close")
        } else if headers["Connection"].isEmpty {
            headers.replaceOrAdd(name: "Connection", value: "keep-alive")
        }

        let status = HTTPResponseStatus(statusCode: response.statusCode)
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        if let finiteBody, !finiteBody.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: finiteBody.count)
            buffer.writeBytes(finiteBody)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { [weak self] _ in
            if let requestID {
                self?.completeRequest(requestID: requestID, context: context)
            }
        }
    }

    private func writeStreamingResponse(
        _ response: MCPNetworkHTTPResponse,
        stream: AsyncThrowingStream<Data, Error>,
        onTermination: (@Sendable () -> Void)?,
        requestID: Int?,
        context: ChannelHandlerContext
    ) {
        cancelActiveStreamTask(notifyTermination: true)
        activeStreamTerminationHandler = onTermination
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
                self?.cancelActiveStreamTask(notifyTermination: true)
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
                await finishStream(taskID: taskID, requestID: requestID, context: context)
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
                        self.cancelActiveStreamTask(notifyTermination: true)
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    private func finishStream(taskID: Int, requestID: Int?, context: ChannelHandlerContext) async {
        await withCheckedContinuation { continuation in
            context.eventLoop.execute { [weak self, weak context] in
                guard let self, let context, activeStreamTaskID == taskID, context.channel.isActive else {
                    continuation.resume()
                    return
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                    if self.activeStreamTaskID == taskID {
                        self.activeStreamTask = nil
                        self.activeStreamTerminationHandler = nil
                    }
                    if let requestID {
                        self.completeRequest(requestID: requestID, context: context)
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
                notifyActiveStreamTermination()
                context.close().whenComplete { _ in
                    continuation.resume()
                }
            }
        }
    }

    private func completeRequest(requestID: Int, context: ChannelHandlerContext) {
        guard activeRequestID == requestID else { return }
        activeRequestTask = nil
        requestInFlight = false
        if closeAfterInFlightRequest {
            context.close(promise: nil)
        }
    }

    private func cancelActiveRequestTask() {
        activeRequestTask?.cancel()
        activeRequestTask = nil
        activeRequestID += 1
        requestInFlight = false
    }

    private func cancelActiveStreamTask(notifyTermination: Bool) {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeStreamTaskID += 1
        if notifyTermination {
            notifyActiveStreamTermination()
        } else {
            activeStreamTerminationHandler = nil
        }
    }

    private func notifyActiveStreamTermination() {
        let handler = activeStreamTerminationHandler
        activeStreamTerminationHandler = nil
        handler?()
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
