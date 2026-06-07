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

    func handle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        lastActivityAt = Date()
        return await transport.handleRequest(request)
    }

    func handle(_ request: MCPNetworkHTTPRequest) async -> MCPNetworkHTTPResponse {
        let response = await handle(request.sdkHTTPRequest())
        return MCPNetworkHTTPResponse.fromSDK(response)
    }

    private func markHandshakeComplete() {
        handshakeComplete = true
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
