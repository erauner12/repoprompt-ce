import Foundation

struct NetworkMCPRemoteConfigExport: Equatable {
    var endpointURL: String
    var authorizationHeaderTemplate: String
    var openClawJSON: String
    var genericJSON: String
    var environmentSnippet: String
    var setupNotes: String
}

actor MCPConfigExportService {
    static let shared = MCPConfigExportService()

    static var discoveryConfigFileName: String {
        #if DEBUG
            return "discovery_debug.json"
        #else
            return "discovery.json"
        #endif
    }

    private init() {}

    nonisolated static func streamableHTTPRemoteConfig(
        settings: NetworkMCPSettingsSnapshot,
        hostOverride: String? = nil,
        serverName: String = RepoPromptMCPServerConfiguration.defaultServerName,
        envVariableName: String = "REPOPROMPT_MCP_TOKEN"
    ) -> NetworkMCPRemoteConfigExport {
        let host = normalizedExportHost(hostOverride) ?? exportHost(forBindAddress: settings.bindAddress)
        let endpointURL = "http://\(host):\(settings.port)/mcp"
        let authorizationTemplate = "Bearer ${\(envVariableName)}"
        let openClawPayload: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "transport": "streamable-http",
                    "url": endpointURL,
                    "headers": [
                        "Authorization": authorizationTemplate
                    ]
                ]
            ]
        ]
        let genericPayload: [String: Any] = [
            "name": serverName,
            "transport": "streamable-http",
            "url": endpointURL,
            "headers": [
                "Authorization": authorizationTemplate
            ]
        ]
        let targetSummary = settings.defaultTarget?.displayName ?? "Not configured"
        let rootCount = settings.defaultTarget?.rootPaths.count ?? 0
        let environmentSnippet = """
        # Store the bearer token outside MCP config files.
        # Paste the token copied from RepoPrompt Settings into your shell, secret manager, or OpenClaw secret UI.
        export \(envVariableName)="<paste RepoPrompt Network MCP token>"
        """
        let setupNotes = [
            "Network MCP endpoint: \(endpointURL)",
            "Default workspace target: \(targetSummary) (\(rootCount) root\(rootCount == 1 ? "" : "s"))",
            "Non-loopback LAN clients require approval in RepoPrompt the first time they connect.",
            "Streamable HTTP uses `POST /mcp` for client messages, same-endpoint `GET /mcp` SSE for attached session streams, and `DELETE /mcp` for session termination.",
            "Long-running `context_builder` and `oracle_send` calls use the SDK Streamable HTTP SSE transport; keep the client session open for the tool result instead of relying on a separate job-control flow.",
            "Use existing `export_response: true` options when you need durable response artifacts.",
            "Remote clients use the existing RepoPrompt MCP tool catalog after bearer authentication, remote-client approval, and default-target routing. High-impact/mutating tools still rely on the existing tool behavior, approvals, and workspace routing; configure the default target carefully.",
            "Do not expose or port-forward this HTTP endpoint; use it only on loopback or trusted private LANs."
        ].joined(separator: "\n")
        return NetworkMCPRemoteConfigExport(
            endpointURL: endpointURL,
            authorizationHeaderTemplate: authorizationTemplate,
            openClawJSON: prettyPrintedJSONObject(openClawPayload),
            genericJSON: prettyPrintedJSONObject(genericPayload),
            environmentSnippet: environmentSnippet,
            setupNotes: setupNotes
        )
    }

    private nonisolated static func exportHost(forBindAddress bindAddress: String) -> String {
        let trimmed = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "0.0.0.0", "::":
            return "<your-mac-lan-ip>"
        case "127.0.0.1":
            return "127.0.0.1"
        case "::1":
            return "[::1]"
        default:
            if trimmed.contains(":"), !trimmed.hasPrefix("[") {
                return "[\(trimmed)]"
            }
            return trimmed.isEmpty ? "127.0.0.1" : trimmed
        }
    }

    private nonisolated static func normalizedExportHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":"), !trimmed.hasPrefix("[") {
            return "[\(trimmed)]"
        }
        return trimmed
    }

    private nonisolated static func prettyPrintedJSONObject(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    @discardableResult
    func prepareConfigFile() async throws -> URL {
        let configJSON = try RepoPromptMCPServerConfiguration.repoPrompt.prettyPrintedWrappedSettingsJSON()
        let fm = FileManager.default
        let baseDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RepoPrompt/MCP", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let configURL = baseDir.appendingPathComponent(Self.discoveryConfigFileName, isDirectory: false)
        try configJSON.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    func writeTempFile(prefix: String, contents: String) async throws -> URL {
        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent("RepoPromptDiscover", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let fileURL = baseDir.appendingPathComponent("\(prefix)-\(UUID().uuidString).txt")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func cleanupConfigFile(_ url: URL) {
        // Retain the config on disk for reuse between runs. No-op cleanup.
    }

    /// Prepares an empty MCP config file for use by ClaudeCodeProvider.
    /// This prevents the CLI from using the user's default MCP config, which may include RepoPrompt.
    @discardableResult
    func prepareEmptyConfigFile() async throws -> URL {
        let emptyConfigJSON = "{\n  \"mcpServers\": {}\n}"
        let fm = FileManager.default
        let baseDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RepoPrompt/MCP", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let configURL = baseDir.appendingPathComponent("empty-config.json", isDirectory: false)
        try emptyConfigJSON.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }
}
