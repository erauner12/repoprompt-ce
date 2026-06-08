import Foundation

struct MCPApprovalPresentation: Equatable {
    enum Transport: Equatable {
        case localMCP
        case remoteHTTP
    }

    var clientID: String
    var transport: Transport
    var remoteAddress: String?
    var tokenFingerprint: String?
    var warning: String?

    init(
        clientID: String,
        transport: Transport = .localMCP,
        remoteAddress: String? = nil,
        tokenFingerprint: String? = nil,
        warning: String? = nil
    ) {
        self.clientID = clientID
        self.transport = transport
        self.remoteAddress = remoteAddress
        self.tokenFingerprint = tokenFingerprint
        self.warning = warning
    }

    static func local(clientID: String) -> MCPApprovalPresentation {
        MCPApprovalPresentation(clientID: clientID, transport: .localMCP)
    }
}

struct MCPRemoteClientApprovalRequest: Equatable {
    var clientDisplayName: String?
    var userAgent: String?
    var sourceAddress: String
    var tokenFingerprint: String

    init(
        clientDisplayName: String? = nil,
        userAgent: String? = nil,
        sourceAddress: String,
        tokenFingerprint: String
    ) {
        self.clientDisplayName = clientDisplayName
        self.userAgent = userAgent
        self.sourceAddress = sourceAddress
        self.tokenFingerprint = tokenFingerprint
    }

    var normalizedClientID: String {
        Self.normalizedClientID(clientDisplayName: clientDisplayName, userAgent: userAgent)
    }

    var displayName: String {
        normalizedNonEmpty(clientDisplayName)
            ?? normalizedNonEmpty(userAgent)
            ?? "Remote MCP client"
    }

    var hasStableClientIdentity: Bool {
        Self.stableClientID(clientDisplayName: clientDisplayName, userAgent: userAgent) != nil
    }

    var presentation: MCPApprovalPresentation {
        MCPApprovalPresentation(
            clientID: displayName,
            transport: .remoteHTTP,
            remoteAddress: MCPRemoteClientAddress(sourceAddress).normalizedHost,
            tokenFingerprint: tokenFingerprint,
            warning: "Only approve remote MCP clients you recognize on your local network. Do not expose this endpoint to the public internet."
        )
    }

    static func normalizedClientID(clientDisplayName: String?, userAgent: String?) -> String {
        stableClientID(clientDisplayName: clientDisplayName, userAgent: userAgent) ?? "remote-mcp-client"
    }

    static func stableClientID(clientDisplayName: String?, userAgent: String?) -> String? {
        if let key = MCPClientIdentity.storageKey(clientDisplayName) {
            return key
        }
        if let key = MCPClientIdentity.storageKey(userAgent) {
            return key
        }
        return nil
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct MCPRemoteClientAddress: Equatable {
    let rawValue: String
    let normalizedHost: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
        normalizedHost = Self.extractHost(from: rawValue)
    }

    var isLoopback: Bool {
        let host = normalizedHost.lowercased()
        if host == "localhost" || host == "::1" { return true }
        guard let bytes = Self.ipv4Bytes(host) else { return false }
        return bytes[0] == 127
    }

    var isPrivateLANOrLinkLocal: Bool {
        if isLoopback { return true }
        let host = normalizedHost.lowercased()
        if let bytes = Self.ipv4Bytes(host) {
            if bytes[0] == 10 { return true }
            if bytes[0] == 172, (16 ... 31).contains(bytes[1]) { return true }
            if bytes[0] == 192, bytes[1] == 168 { return true }
            if bytes[0] == 169, bytes[1] == 254 { return true }
            return false
        }

        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        let first = address.__u6_addr.__u6_addr8.0
        let second = address.__u6_addr.__u6_addr8.1
        // Unique local addresses fc00::/7 and link-local fe80::/10.
        if (first & 0xFE) == 0xFC { return true }
        if first == 0xFE, (second & 0xC0) == 0x80 { return true }
        return false
    }

    private static func extractHost(from rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }

        if let nioHost = extractNIOAddressDescriptionHost(from: value) {
            return stripIPv6ZoneIdentifier(nioHost)
        }

        if value.hasPrefix("[") {
            if let end = value.firstIndex(of: "]") {
                let start = value.index(after: value.startIndex)
                return stripIPv6ZoneIdentifier(String(value[start ..< end]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return stripIPv6ZoneIdentifier(String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if value.contains(":") {
            let colonCount = value.reduce(0) { $1 == ":" ? $0 + 1 : $0 }
            if colonCount == 1,
               let colon = value.firstIndex(of: ":"),
               value[value.index(after: colon)...].allSatisfy(\.isNumber)
            {
                value = String(value[..<colon])
            }
        }

        return stripIPv6ZoneIdentifier(value.trimmingCharacters(in: CharacterSet(charactersIn: "[] ").union(.whitespacesAndNewlines)))
    }

    private static func extractNIOAddressDescriptionHost(from value: String) -> String? {
        guard value.hasPrefix("IPv4(") || value.hasPrefix("IPv6(") else { return nil }
        guard let hostRange = value.range(of: "host:") else { return nil }
        let remainder = String(value[hostRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.hasPrefix("\"") {
            let afterQuote = remainder.index(after: remainder.startIndex)
            guard let closingQuote = remainder[afterQuote...].firstIndex(of: "\"") else { return nil }
            return String(remainder[afterQuote ..< closingQuote])
        }
        let terminators = CharacterSet(charactersIn: ",)").union(.whitespacesAndNewlines)
        let host = remainder.prefix { character in
            character.unicodeScalars.allSatisfy { !terminators.contains($0) }
        }
        let normalized = String(host).trimmingCharacters(in: CharacterSet(charactersIn: "[] ").union(.whitespacesAndNewlines))
        return normalized.isEmpty ? nil : normalized
    }

    private static func stripIPv6ZoneIdentifier(_ host: String) -> String {
        guard let percent = host.firstIndex(of: "%") else { return host }
        return String(host[..<percent])
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        let bigEndian = addr.s_addr.bigEndian
        return [
            UInt8((bigEndian >> 24) & 0xFF),
            UInt8((bigEndian >> 16) & 0xFF),
            UInt8((bigEndian >> 8) & 0xFF),
            UInt8(bigEndian & 0xFF)
        ]
    }
}

enum MCPRemoteClientApprovalFailure: Error, Equatable {
    case nonLANSourceAddress(String)
}

enum MCPRemoteClientApprovalResult: Equatable {
    case approved(alwaysAllow: Bool, trustedPolicy: NetworkMCPTrustedClientPolicy?)
    case denied
    case rejected(MCPRemoteClientApprovalFailure)
}

@MainActor
final class MCPRemoteClientApprovalManager {
    typealias UserApprovalHandler = (MCPRemoteClientApprovalRequest) async -> MCPRemoteClientApprovalDecision

    private struct QueuedApprovalRequest {
        var id: UUID
        var request: MCPRemoteClientApprovalRequest
        var continuation: CheckedContinuation<MCPRemoteClientApprovalDecision, Never>
    }

    private let settingsStore: GlobalSettingsStore
    private let now: () -> Date
    private let idGenerator: () -> UUID
    private let approvalTimeoutNanoseconds: UInt64?
    private let userApprovalHandler: UserApprovalHandler
    private var activeApprovalRequest: QueuedApprovalRequest?
    private var activeApprovalTask: Task<Void, Never>?
    private var activeApprovalTimeoutTask: Task<Void, Never>?
    private var queuedApprovalRequests: [QueuedApprovalRequest] = []

    convenience init(
        now: @escaping () -> Date = Date.init,
        idGenerator: @escaping () -> UUID = UUID.init,
        approvalTimeoutNanoseconds: UInt64? = 60_000_000_000,
        userApprovalHandler: @escaping UserApprovalHandler
    ) {
        self.init(
            settingsStore: GlobalSettingsStore.shared,
            now: now,
            idGenerator: idGenerator,
            approvalTimeoutNanoseconds: approvalTimeoutNanoseconds,
            userApprovalHandler: userApprovalHandler
        )
    }

    init(
        settingsStore: GlobalSettingsStore,
        now: @escaping () -> Date = Date.init,
        idGenerator: @escaping () -> UUID = UUID.init,
        approvalTimeoutNanoseconds: UInt64? = 60_000_000_000,
        userApprovalHandler: @escaping UserApprovalHandler
    ) {
        self.settingsStore = settingsStore
        self.now = now
        self.idGenerator = idGenerator
        self.approvalTimeoutNanoseconds = approvalTimeoutNanoseconds
        self.userApprovalHandler = userApprovalHandler
    }

    func evaluate(_ request: MCPRemoteClientApprovalRequest) async -> MCPRemoteClientApprovalResult {
        let address = MCPRemoteClientAddress(request.sourceAddress)
        if address.isLoopback {
            return .approved(alwaysAllow: false, trustedPolicy: nil)
        }
        guard address.isPrivateLANOrLinkLocal else {
            return .rejected(.nonLANSourceAddress(address.normalizedHost))
        }

        if let policy = matchingTrustedPolicy(for: request) {
            touchTrustedPolicy(policy, lastAddress: address.normalizedHost)
            return .approved(alwaysAllow: false, trustedPolicy: policy)
        }

        let decision = await queuedUserApprovalDecision(for: request)
        switch decision {
        case .deny:
            return .denied
        case let .allow(alwaysAllow):
            if alwaysAllow, request.hasStableClientIdentity {
                let policy = persistTrustedPolicy(for: request, lastAddress: address.normalizedHost)
                return .approved(alwaysAllow: true, trustedPolicy: policy)
            }
            return .approved(alwaysAllow: false, trustedPolicy: nil)
        }
    }

    private func queuedUserApprovalDecision(
        for request: MCPRemoteClientApprovalRequest
    ) async -> MCPRemoteClientApprovalDecision {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queuedApprovalRequests.append(QueuedApprovalRequest(
                    id: id,
                    request: request,
                    continuation: continuation
                ))
                processNextQueuedApprovalIfNeeded()
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelQueuedApproval(id: id)
            }
        }
    }

    private func processNextQueuedApprovalIfNeeded() {
        guard activeApprovalRequest == nil, !queuedApprovalRequests.isEmpty else { return }
        let next = queuedApprovalRequests.removeFirst()
        activeApprovalRequest = next
        activeApprovalTask = Task { @MainActor in
            let decision = await userApprovalHandler(next.request)
            completeActiveApproval(id: next.id, decision: decision)
        }
        if let approvalTimeoutNanoseconds {
            activeApprovalTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: approvalTimeoutNanoseconds)
                completeActiveApproval(id: next.id, decision: .deny)
            }
        }
    }

    private func cancelQueuedApproval(id: UUID) {
        if let index = queuedApprovalRequests.firstIndex(where: { $0.id == id }) {
            let queued = queuedApprovalRequests.remove(at: index)
            queued.continuation.resume(returning: .deny)
            return
        }
        if activeApprovalRequest?.id == id {
            completeActiveApproval(id: id, decision: .deny)
        }
    }

    private func completeActiveApproval(id: UUID, decision: MCPRemoteClientApprovalDecision) {
        guard let active = activeApprovalRequest, active.id == id else { return }
        activeApprovalTask?.cancel()
        activeApprovalTimeoutTask?.cancel()
        activeApprovalTask = nil
        activeApprovalTimeoutTask = nil
        activeApprovalRequest = nil
        active.continuation.resume(returning: decision)
        processNextQueuedApprovalIfNeeded()
    }

    private func matchingTrustedPolicy(for request: MCPRemoteClientApprovalRequest) -> NetworkMCPTrustedClientPolicy? {
        guard request.hasStableClientIdentity else { return nil }
        return settingsStore.networkMCPSettingsSnapshot().trustedClients.first { policy in
            policy.tokenFingerprint == request.tokenFingerprint
                && MCPClientIdentity.matches(policy.normalizedClientID, request.normalizedClientID)
        }
    }

    private func persistTrustedPolicy(
        for request: MCPRemoteClientApprovalRequest,
        lastAddress: String
    ) -> NetworkMCPTrustedClientPolicy {
        let timestamp = now()
        var policies = settingsStore.networkMCPSettingsSnapshot().trustedClients
        let storageKey = request.normalizedClientID
        let policy = NetworkMCPTrustedClientPolicy(
            id: idGenerator(),
            clientDisplayName: request.displayName,
            normalizedClientID: storageKey,
            tokenFingerprint: request.tokenFingerprint,
            lastAddress: lastAddress,
            createdAt: timestamp,
            lastUsedAt: timestamp
        )
        policies.removeAll {
            $0.tokenFingerprint == request.tokenFingerprint
                && MCPClientIdentity.matches($0.normalizedClientID, storageKey)
        }
        policies.append(policy)
        settingsStore.setNetworkMCPTrustedClients(policies)
        return policy
    }

    private func touchTrustedPolicy(_ policy: NetworkMCPTrustedClientPolicy, lastAddress: String) {
        var policies = settingsStore.networkMCPSettingsSnapshot().trustedClients
        guard let index = policies.firstIndex(where: { $0.id == policy.id }) else { return }
        policies[index].lastAddress = lastAddress
        policies[index].lastUsedAt = now()
        settingsStore.setNetworkMCPTrustedClients(policies)
    }
}

enum MCPRemoteClientApprovalDecision: Equatable {
    case allow(alwaysAllow: Bool)
    case deny
}
