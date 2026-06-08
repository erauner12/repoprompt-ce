import AppKit
import Darwin
import Foundation

@MainActor
final class NetworkMCPSettingsViewModel: ObservableObject {
    @Published private(set) var snapshot: NetworkMCPSettingsSnapshot
    @Published private(set) var listenerStatus: NetworkMCPHTTPListenerStatusSnapshot
    @Published var bindAddressText: String
    @Published var portText: String
    @Published var openDefaultTargetIfNeeded: Bool
    @Published private(set) var bindAddressOptions: [String]
    @Published private(set) var feedbackMessage: String?
    @Published private(set) var feedbackIsError = false

    private let settingsStore: GlobalSettingsStore
    private let tokenStore: MCPRemoteBearerTokenStore
    private let networkManager: ServerNetworkManager

    init(
        settingsStore: GlobalSettingsStore = .shared,
        tokenStore: MCPRemoteBearerTokenStore = MCPRemoteBearerTokenStore(),
        networkManager: ServerNetworkManager = .shared
    ) {
        self.settingsStore = settingsStore
        self.tokenStore = tokenStore
        self.networkManager = networkManager
        let snapshot = settingsStore.networkMCPSettingsSnapshot()
        self.snapshot = snapshot
        bindAddressText = snapshot.bindAddress
        portText = String(snapshot.port)
        openDefaultTargetIfNeeded = snapshot.defaultTarget?.openIfNeeded ?? false
        bindAddressOptions = Self.detectedBindAddressOptions()
        listenerStatus = NetworkMCPHTTPListenerStatusSnapshot(
            enabled: snapshot.enabled,
            isListening: false,
            bindAddress: snapshot.bindAddress,
            port: snapshot.port,
            activeSessionCount: 0,
            lastErrorDescription: nil
        )
    }

    var canEnable: Bool {
        snapshot.defaultTarget != nil && snapshot.token != nil
    }

    var isNonLoopbackBind: Bool {
        !MCPRemoteClientAddress(snapshot.bindAddress).isLoopback
    }

    var endpointPreview: String {
        MCPConfigExportService.streamableHTTPRemoteConfig(settings: snapshot).endpointURL
    }

    var targetSummary: String {
        guard let target = snapshot.defaultTarget else {
            return "No default workspace target configured."
        }
        let name = target.displayName ?? "Workspace"
        let rootCount = target.rootPaths.count
        let openText = target.openIfNeeded == true ? "May open if needed" : "Must already be open"
        return "\(name) · \(rootCount) root\(rootCount == 1 ? "" : "s") · \(openText)"
    }

    var tokenSummary: String {
        guard let token = snapshot.token else {
            return "No token generated."
        }
        let persistence = token.secureStoragePersistsAcrossLaunches == false ? " · ephemeral debug storage" : ""
        return "\(token.label) · \(token.fingerprint)\(persistence)"
    }

    func refresh() async {
        refreshSettingsSnapshot()
        listenerStatus = await networkManager.networkHTTPListenerStatus()
    }

    func selectBindAddress(_ address: String) {
        bindAddressText = address
    }

    func saveEndpointSettings() async {
        do {
            try settingsStore.setNetworkMCPBindAddress(bindAddressText)
            guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw NetworkMCPSettingsError.invalidPort(-1)
            }
            try settingsStore.setNetworkMCPPort(port)
            await networkManager.refreshHTTPListenerConfiguration()
            await refresh()
            showFeedback("Network MCP endpoint saved")
        } catch {
            await refresh()
            showFeedback(message(for: error), isError: true)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        do {
            let secureTokenFingerprint = if enabled,
                                            let token = try tokenStore.loadPrimaryToken(accessMode: .nonInteractive(reason: .networkMCPAuthentication))
            {
                MCPRemoteBearerTokenStore.fingerprint(for: token)
            } else {
                String?.none
            }
            try settingsStore.setNetworkMCPEnabled(
                enabled,
                secureTokenFingerprint: secureTokenFingerprint
            )
            await networkManager.refreshHTTPListenerConfiguration()
            await refresh()
            showFeedback(enabled ? "Network MCP enabled" : "Network MCP disabled")
        } catch {
            await refresh()
            showFeedback(message(for: error), isError: true)
        }
    }

    func setDefaultTarget(from windowState: WindowState) async {
        guard let workspace = windowState.workspaceManager.activeWorkspace,
              !workspace.isSystemWorkspace,
              !workspace.repoPaths.isEmpty
        else {
            showFeedback("Open a saved workspace with at least one root first", isError: true)
            return
        }
        let target = NetworkMCPDefaultTargetMetadata(
            workspaceID: workspace.id,
            contextID: workspace.activeComposeTabID?.uuidString,
            displayName: workspace.name,
            rootPaths: workspace.repoPaths,
            openIfNeeded: openDefaultTargetIfNeeded,
            updatedAt: Date()
        )
        settingsStore.setNetworkMCPDefaultTarget(target)
        await refresh()
        showFeedback("Default Network MCP target saved")
    }

    func updateDefaultTargetOpenIfNeeded(_ enabled: Bool) async {
        openDefaultTargetIfNeeded = enabled
        guard var target = snapshot.defaultTarget else { return }
        target.openIfNeeded = enabled
        target.updatedAt = Date()
        settingsStore.setNetworkMCPDefaultTarget(target)
        await refresh()
    }

    func clearDefaultTarget() async {
        if snapshot.enabled {
            try? settingsStore.setNetworkMCPEnabled(false, secureTokenFingerprint: nil)
        }
        settingsStore.setNetworkMCPDefaultTarget(nil)
        await networkManager.refreshHTTPListenerConfiguration()
        await refresh()
        showFeedback("Default target cleared")
    }

    func generateToken() async {
        saveNewToken(label: "Network MCP token", feedback: "Token generated and copied")
    }

    func rotateToken() async {
        saveNewToken(label: snapshot.token?.label ?? "Network MCP token", feedback: "Token rotated and copied")
    }

    func copyToken() async {
        do {
            guard let token = try tokenStore.loadPrimaryToken(accessMode: .interactive) else {
                showFeedback("No Network MCP token is available", isError: true)
                return
            }
            copyToPasteboard(token)
            showFeedback("Token copied")
        } catch {
            showFeedback("Could not copy token: \(error.localizedDescription)", isError: true)
        }
    }

    func deleteToken() async {
        do {
            try tokenStore.deletePrimaryToken(accessMode: .interactive)
            if snapshot.enabled {
                try settingsStore.setNetworkMCPEnabled(false, secureTokenMaterialAvailable: false)
            }
            settingsStore.setNetworkMCPTokenMetadata(nil)
            settingsStore.setNetworkMCPTrustedClients([])
            await networkManager.refreshHTTPListenerConfiguration()
            await refresh()
            showFeedback("Token deleted; trusted LAN clients revoked")
        } catch {
            showFeedback("Could not delete token: \(error.localizedDescription)", isError: true)
        }
    }

    func revokeTrustedClient(_ policy: NetworkMCPTrustedClientPolicy) async {
        let remaining = snapshot.trustedClients.filter { $0.id != policy.id }
        settingsStore.setNetworkMCPTrustedClients(remaining)
        await refresh()
        showFeedback("Trusted LAN client revoked")
    }

    func revokeAllTrustedClients() async {
        settingsStore.setNetworkMCPTrustedClients([])
        await refresh()
        showFeedback("Trusted LAN clients revoked")
    }

    func copyOpenClawConfig() {
        copyToPasteboard(MCPConfigExportService.streamableHTTPRemoteConfig(settings: snapshot).openClawJSON)
        showFeedback("OpenClaw config copied")
    }

    func copyGenericConfig() {
        copyToPasteboard(MCPConfigExportService.streamableHTTPRemoteConfig(settings: snapshot).genericJSON)
        showFeedback("Generic Streamable HTTP config copied")
    }

    func copyEnvironmentSnippet() {
        copyToPasteboard(MCPConfigExportService.streamableHTTPRemoteConfig(settings: snapshot).environmentSnippet)
        showFeedback("Environment snippet copied")
    }

    func copySetupNotes() {
        copyToPasteboard(MCPConfigExportService.streamableHTTPRemoteConfig(settings: snapshot).setupNotes)
        showFeedback("Setup notes copied")
    }

    private func saveNewToken(label: String, feedback: String) {
        do {
            let result = try tokenStore.generateAndSavePrimaryToken(label: label, accessMode: .interactive)
            settingsStore.setNetworkMCPTokenMetadata(result.metadata)
            settingsStore.setNetworkMCPTrustedClients([])
            copyToPasteboard(result.token)
            refreshSettingsSnapshot()
            showFeedback(feedback)
        } catch {
            showFeedback("Could not save token: \(error.localizedDescription)", isError: true)
        }
    }

    private func refreshSettingsSnapshot() {
        let latest = settingsStore.networkMCPSettingsSnapshot()
        snapshot = latest
        bindAddressText = latest.bindAddress
        portText = String(latest.port)
        openDefaultTargetIfNeeded = latest.defaultTarget?.openIfNeeded ?? openDefaultTargetIfNeeded
        bindAddressOptions = Self.detectedBindAddressOptions()
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func showFeedback(_ message: String, isError: Bool = false) {
        feedbackMessage = message
        feedbackIsError = isError
    }

    private func message(for error: Error) -> String {
        switch error {
        case NetworkMCPSettingsError.missingDefaultTarget:
            "Choose a default workspace target before enabling Network MCP."
        case NetworkMCPSettingsError.missingTokenMetadata:
            "Generate a bearer token before enabling Network MCP."
        case NetworkMCPSettingsError.missingSecureTokenMaterial:
            "Secure token material is unavailable; regenerate the token."
        case NetworkMCPSettingsError.secureTokenMetadataMismatch:
            "Secure token metadata is stale; regenerate the token."
        case let NetworkMCPSettingsError.invalidBindAddress(value):
            "Invalid bind address: \(value)"
        case let NetworkMCPSettingsError.invalidPort(port):
            port == -1 ? "Port must be a number." : "Invalid port: \(port). Use 1024–65535."
        default:
            error.localizedDescription
        }
    }

    private static func detectedBindAddressOptions() -> [String] {
        var values: [String] = ["127.0.0.1", "0.0.0.0"]
        values.append(contentsOf: detectedLANAddresses())
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func detectedLANAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(first) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let address = current.pointee.ifa_addr
            else { continue }

            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(
                address,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let value = String(cString: host)
            let normalized = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
            guard !normalized.isEmpty,
                  GlobalSettingsStore.isValidNetworkMCPBindAddress(normalized),
                  MCPRemoteClientAddress(normalized).isPrivateLANOrLinkLocal,
                  !MCPRemoteClientAddress(normalized).isLoopback
            else { continue }
            addresses.append(normalized)
        }
        return addresses.sorted()
    }
}
