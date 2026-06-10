import Foundation
import Logging
import MCP
import RepoPromptShared

private extension Bundle {
    var networkMCPAppName: String {
        object(forInfoDictionaryKey: "CFBundleName") as? String ?? "RepoPrompt"
    }

    var networkMCPAppVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }
}

actor MCPHTTPConnectionManager: MCPServerConnection {
    private let connectionID: UUID
    private let sessionID: String
    private let sourceAddress: String
    private let initialClientName: String?
    private let server: MCP.Server
    private let transport: MCP.StatefulHTTPServerTransport
    private let parentManager: ServerNetworkManager
    private let logger: Logger

    nonisolated var isFilesystemBacked: Bool {
        false
    }

    nonisolated var connectionFolderURL: URL? {
        nil
    }

    nonisolated var capabilityToken: String? {
        sessionID
    }

    private var healthMonitoringTask: Task<Void, Never>?
    private var state: ConnectionStateSnapshot = .connecting
    private var lastActivityAt = Date()
    private var isClosing = false
    private var handshakeComplete = false
    private var standaloneGETStreamGeneration = 0
    private var standaloneGETStreamDetachedByAdapter = false
    private var lastStandaloneGETSSEEventID: String?

    init(
        connectionID: UUID,
        sessionID: String,
        sourceAddress: String,
        initialClientName: String?,
        codeMapsDisabled: Bool,
        transport: MCP.StatefulHTTPServerTransport,
        parentManager: ServerNetworkManager,
        logger: Logger? = nil
    ) {
        self.connectionID = connectionID
        self.sessionID = sessionID
        self.sourceAddress = sourceAddress
        self.initialClientName = initialClientName
        self.transport = transport
        self.parentManager = parentManager
        self.logger = logger ?? Logger(label: "com.repoprompt.mcp.http.connection")

        server = MCP.Server(
            name: Bundle.main.networkMCPAppName,
            version: Bundle.main.networkMCPAppVersion,
            instructions: RepoPromptMCPInstructions.text(for: .unknown, codeMapsDisabled: codeMapsDisabled),
            capabilities: MCP.Server.Capabilities(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: true)
            )
        )
    }

    func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws {
        do {
            await parentManager.registerHandlers(for: server, connectionID: connectionID)
            try await server.start(transport: transport) { [weak self] clientInfo, _ in
                guard let self else { throw MCPError.connectionClosed }
                let approved = await approvalHandler(clientInfo)
                if !approved {
                    throw MCPError.connectionClosed
                }
                await markHandshakeComplete()
            }
            await startHealthMonitoring()
            updateState(.ready)
        } catch {
            logger.error("MCPHTTPConnectionManager start failed from \(sourceAddress): \(String(describing: error))")
            updateState(.failed(error))
            await transport.disconnect()
            throw error
        }
    }

    func notifyToolListChanged() async {
        guard handshakeComplete, !isClosing else { return }
        do {
            try await server.notify(ToolListChangedNotification.message())
            lastActivityAt = Date()
        } catch {
            if isClosing { return }
            logger.error("Failed to notify HTTP MCP client of tool list change: \(String(describing: error))")
            await parentManager.removeConnection(connectionID)
        }
    }

    func stop() async {
        guard !isClosing else { return }
        isClosing = true
        healthMonitoringTask?.cancel()
        healthMonitoringTask = nil
        await server.stop()
        await transport.disconnect()
        updateState(.cancelled)
    }

    func abortForExecutionWatchdog() async {
        guard !isClosing else { return }
        isClosing = true
        healthMonitoringTask?.cancel()
        healthMonitoringTask = nil
        await transport.disconnect()
        updateState(.cancelled)
        Task { await server.stop() }
    }

    func terminate(reason: TerminationReason, message: String?) async {
        guard !isClosing else { return }
        mcpConnectionLog("Terminating HTTP MCP connection \(connectionID) with reason: \(reason.rawValue)")
        await stop()
    }

    func connectionState() -> ConnectionStateSnapshot {
        state
    }

    func isViableForRetention() -> Bool {
        !isClosing && (state == .ready || state == .connecting)
    }

    func secondsSinceLastActivity() async -> TimeInterval {
        Date().timeIntervalSince(lastActivityAt)
    }

    func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
        nil
    }

    func handle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        lastActivityAt = Date()
        return await transport.handleRequest(request)
    }

    func handle(_ request: MCPNetworkHTTPRequest) async -> MCPNetworkHTTPResponse {
        lastActivityAt = Date()
        var response = await MCPNetworkHTTPResponse.fromSDK(transport.handleRequest(request.sdkHTTPRequest()))
        if shouldRetryStaleStandaloneGET(response, for: request), let lastEventID = lastStandaloneGETSSEEventID {
            var resumeRequest = request
            resumeRequest.headers["Last-Event-ID"] = lastEventID
            let resumeResponse = await MCPNetworkHTTPResponse.fromSDK(transport.handleRequest(resumeRequest.sdkHTTPRequest()))
            if resumeResponse.statusCode != 409 {
                response = resumeResponse
            }
        }
        return wrapStandaloneGETStreamIfNeeded(response, for: request)
    }

    private func markHandshakeComplete() {
        handshakeComplete = true
    }

    private func shouldRetryStaleStandaloneGET(_ response: MCPNetworkHTTPResponse, for request: MCPNetworkHTTPRequest) -> Bool {
        guard request.method.uppercased() == "GET",
              request.header("Last-Event-ID") == nil,
              response.statusCode == 409,
              standaloneGETStreamDetachedByAdapter,
              lastStandaloneGETSSEEventID != nil
        else { return false }
        return true
    }

    private func wrapStandaloneGETStreamIfNeeded(
        _ response: MCPNetworkHTTPResponse,
        for request: MCPNetworkHTTPRequest
    ) -> MCPNetworkHTTPResponse {
        guard request.method.uppercased() == "GET",
              response.statusCode == 200,
              case let .stream(stream, _) = response.body
        else { return response }

        standaloneGETStreamGeneration &+= 1
        let generation = standaloneGETStreamGeneration
        standaloneGETStreamDetachedByAdapter = false

        let wrappedStream = AsyncThrowingStream<Data, Error> { [weak self] continuation in
            let task = Task { [weak self] in
                do {
                    for try await chunk in stream {
                        await self?.recordStandaloneGETSSEEventIDs(in: chunk, generation: generation)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        return MCPNetworkHTTPResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: .stream(wrappedStream, onTermination: { [weak self] in
                Task { await self?.markStandaloneGETStreamDetached(generation: generation) }
            })
        )
    }

    private func recordStandaloneGETSSEEventIDs(in chunk: Data, generation: Int) {
        guard generation == standaloneGETStreamGeneration,
              let text = String(data: chunk, encoding: .utf8)
        else { return }

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("id:") else { continue }
            let id = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty {
                lastStandaloneGETSSEEventID = String(id)
            }
        }
    }

    private func markStandaloneGETStreamDetached(generation: Int) {
        guard generation == standaloneGETStreamGeneration else { return }
        standaloneGETStreamDetachedByAdapter = true
    }

    private func updateState(_ newState: ConnectionStateSnapshot) {
        state = newState
    }

    private func startHealthMonitoring() async {
        healthMonitoringTask?.cancel()
        healthMonitoringTask = Task { [self] in
            let hardIdleSec = UserDefaults.standard.integer(forKey: "mcp.idleConnectionSeconds")
            while !Task.isCancelled {
                guard await parentManager.isRunning() else { break }
                if hardIdleSec > 0 {
                    let idle = await secondsSinceLastActivity()
                    if idle > TimeInterval(hardIdleSec) {
                        let hasInFlight = await parentManager.hasInFlightCalls(for: connectionID)
                        if !hasInFlight {
                            await parentManager.terminateConnection(
                                connectionID,
                                reason: .idleTimeout,
                                message: "HTTP MCP session idle for \(Int(idle))s"
                            )
                            break
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(30)) }
                catch { break }
            }
        }
    }

    func sendProgress(tool: String, kind: RepoPromptProgressKind, stage: String, message: String) async {
        // Route progress through the SDK transport so notifications reach an attached GET SSE stream
        // when present, or are stored by the transport for resumable replay.
        guard !isClosing, handshakeComplete else { return }
        let notification: RepoPromptControlNotification<RepoPromptProgressParams> = switch kind {
        case .stage:
            .stage(tool: tool, stage: stage, message: message)
        case .heartbeat:
            .heartbeat(tool: tool, stage: stage, message: message)
        }
        guard let data = notification.encodedJSONLine() else { return }
        do {
            try await transport.send(data)
            lastActivityAt = Date()
        } catch {
            // Progress is best-effort and should not fail the in-flight tool call.
        }
    }
}
