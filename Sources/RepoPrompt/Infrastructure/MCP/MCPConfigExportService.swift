import Darwin
import Foundation
import RepoPromptShared

struct NetworkMCPRemoteConfigExport: Equatable {
    var endpointURL: String
    var authorizationHeaderTemplate: String
    var openClawJSON: String
    var genericJSON: String
    var environmentSnippet: String
    var setupNotes: String
}

/// Owns one immutable launch configuration. Releasing the lease removes only
/// the unique file created for that launch; stable wrapper configs are not leased.
final class MCPConfigLease: @unchecked Sendable {
    fileprivate struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let fileType: mode_t
    }

    let url: URL

    private let fileManager: FileManager
    private let identity: FileIdentity
    private let lock = NSLock()
    private var isReleased = false

    fileprivate init(url: URL, fileManager: FileManager, identity: FileIdentity) {
        self.url = url
        self.fileManager = fileManager
        self.identity = identity
    }

    deinit {
        release()
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased else { return }
        guard let current = Self.identity(atPath: url.path) else {
            isReleased = true
            return
        }
        guard current == identity else {
            // The leased pathname was replaced; never remove the replacement.
            isReleased = true
            return
        }
        do {
            try fileManager.removeItem(at: url)
            isReleased = Self.identity(atPath: url.path) == nil
        } catch {
            // Keep the lease retryable after a transient removal failure.
            isReleased = false
        }
    }

    fileprivate static func identity(atPath path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            owner: info.st_uid,
            fileType: info.st_mode & mode_t(S_IFMT)
        )
    }
}

actor MCPConfigExportService {
    typealias ServerConfigRenderer = @Sendable () throws -> String

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let fileType: mode_t
        let permissions: mode_t
    }

    private enum DirectorySecurityError: Error {
        case invalidPath(String)
        case insecureDirectory(String)
    }

    static let shared = MCPConfigExportService()

    #if DEBUG
        static let identity = MCPFilesystemIdentity.repoPromptCE(.debug)
    #else
        static let identity = MCPFilesystemIdentity.repoPromptCE(.release)
    #endif

    static var discoveryConfigFileName: String {
        identity.stableWrapperConfigFileName
    }

    static var stableWrapperConfigURL: URL {
        identity.stableWrapperConfigURL()
    }

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
        case "127.0.0.1", "::1":
            return "127.0.0.1"
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

    private let identity: MCPFilesystemIdentity
    private let fileManager: FileManager
    private let configDirectoryURL: URL
    private let launchConfigDirectoryURL: URL
    private let directoryValidationRootURL: URL
    private let renderServerConfig: ServerConfigRenderer

    init(
        identity: MCPFilesystemIdentity = MCPConfigExportService.identity,
        fileManager: FileManager = .default,
        configDirectoryURL: URL? = nil,
        renderServerConfig: @escaping ServerConfigRenderer = {
            try RepoPromptMCPServerConfiguration.repoPrompt.prettyPrintedWrappedSettingsJSON()
        }
    ) {
        self.identity = identity
        self.fileManager = fileManager
        let resolvedConfigDirectoryURL = configDirectoryURL ?? identity.configDirectoryURL(fileManager: fileManager)
        self.configDirectoryURL = resolvedConfigDirectoryURL
        launchConfigDirectoryURL = resolvedConfigDirectoryURL
            .appendingPathComponent("LaunchConfigs", isDirectory: true)
        if configDirectoryURL == nil {
            directoryValidationRootURL = fileManager.homeDirectoryForCurrentUser
        } else if Self.isDescendant(resolvedConfigDirectoryURL, of: fileManager.temporaryDirectory) {
            directoryValidationRootURL = fileManager.temporaryDirectory
        } else {
            directoryValidationRootURL = resolvedConfigDirectoryURL.deletingLastPathComponent()
        }
        self.renderServerConfig = renderServerConfig
    }

    /// Writes the retained config referenced by the installed Claude wrapper.
    @discardableResult
    func prepareStableWrapperConfigFile() throws -> URL {
        let configJSON = try renderServerConfig()
        try prepareSecureDirectory(at: configDirectoryURL)
        let configURL = configDirectoryURL.appendingPathComponent(identity.stableWrapperConfigFileName, isDirectory: false)
        try configJSON.write(to: configURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return configURL
    }

    /// Creates a unique immutable config for one MCP-enabled process launch.
    func prepareLaunchConfig() throws -> MCPConfigLease {
        try makeLease(prefix: "discovery", contents: renderServerConfig())
    }

    /// Creates a unique empty config so a process cannot load the user's default MCP config.
    func prepareEmptyLaunchConfig() throws -> MCPConfigLease {
        try makeLease(
            prefix: "empty",
            contents: """
            {
              "mcpServers": {}
            }
            """
        )
    }

    func writeTempFile(prefix: String, contents: String) throws -> URL {
        let baseDir = fileManager.temporaryDirectory
            .appendingPathComponent("RepoPromptDiscover", isDirectory: true)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let fileURL = baseDir.appendingPathComponent("\(prefix)-\(UUID().uuidString).txt")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func prepareSecureDirectory(at targetURL: URL) throws {
        for directoryURL in try directoryComponents(to: targetURL) {
            if Self.directoryIdentity(atPath: directoryURL.path) == nil {
                do {
                    try fileManager.createDirectory(
                        at: directoryURL,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    guard Self.directoryIdentity(atPath: directoryURL.path) != nil else { throw error }
                }
            }
            try secureExistingDirectory(at: directoryURL)
        }
    }

    private func secureExistingDirectory(at url: URL) throws {
        guard let pathIdentity = Self.directoryIdentity(atPath: url.path),
              pathIdentity.fileType == mode_t(S_IFDIR),
              pathIdentity.owner == getuid()
        else {
            throw DirectorySecurityError.insecureDirectory(url.path)
        }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw DirectorySecurityError.insecureDirectory(url.path)
        }
        defer { Darwin.close(descriptor) }

        guard let descriptorIdentity = Self.directoryIdentity(forDescriptor: descriptor),
              descriptorIdentity == pathIdentity,
              fchmod(descriptor, mode_t(0o700)) == 0,
              let securedDescriptorIdentity = Self.directoryIdentity(forDescriptor: descriptor),
              securedDescriptorIdentity.fileType == mode_t(S_IFDIR),
              securedDescriptorIdentity.owner == getuid(),
              securedDescriptorIdentity.permissions == mode_t(0o700),
              securedDescriptorIdentity.device == pathIdentity.device,
              securedDescriptorIdentity.inode == pathIdentity.inode,
              Self.directoryIdentity(atPath: url.path) == securedDescriptorIdentity
        else {
            throw DirectorySecurityError.insecureDirectory(url.path)
        }
    }

    private func directoryComponents(to targetURL: URL) throws -> [URL] {
        let root = directoryValidationRootURL.standardizedFileURL
        let target = targetURL.standardizedFileURL
        let rootPath = root.path
        let targetPath = target.path
        guard targetPath != rootPath, targetPath.hasPrefix(rootPath + "/") else {
            throw DirectorySecurityError.invalidPath(targetPath)
        }

        var current = root
        return targetPath.dropFirst(rootPath.count + 1).split(separator: "/").map { component in
            current.appendPathComponent(String(component), isDirectory: true)
            return current
        }
    }

    private static func isDescendant(_ url: URL, of rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func directoryIdentity(atPath path: String) -> DirectoryIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return directoryIdentity(from: info)
    }

    private static func directoryIdentity(forDescriptor descriptor: Int32) -> DirectoryIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return directoryIdentity(from: info)
    }

    private static func directoryIdentity(from info: stat) -> DirectoryIdentity {
        DirectoryIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            owner: info.st_uid,
            fileType: info.st_mode & mode_t(S_IFMT),
            permissions: info.st_mode & mode_t(0o777)
        )
    }

    private func makeLease(prefix: String, contents: String) throws -> MCPConfigLease {
        try prepareSecureDirectory(at: launchConfigDirectoryURL)
        let flavor = identity.buildFlavor == .debug ? "D" : "R"
        let url = launchConfigDirectoryURL
            .appendingPathComponent("\(prefix)-\(flavor)-\(UUID().uuidString).json", isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        guard let createdIdentity = MCPConfigLease.identity(atPath: url.path),
              createdIdentity.owner == getuid(),
              createdIdentity.fileType == mode_t(S_IFREG)
        else {
            try? fileManager.removeItem(at: url)
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            guard MCPConfigLease.identity(atPath: url.path) == createdIdentity else {
                throw CocoaError(.fileWriteUnknown)
            }
            return MCPConfigLease(url: url, fileManager: fileManager, identity: createdIdentity)
        } catch {
            if MCPConfigLease.identity(atPath: url.path) == createdIdentity {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }
}
