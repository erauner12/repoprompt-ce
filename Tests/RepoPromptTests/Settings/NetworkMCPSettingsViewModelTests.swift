import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class NetworkMCPSettingsViewModelTests: XCTestCase {
    func testInvalidEndpointPortDoesNotPersistDraftBindAddress() async throws {
        let store = makeSettingsStore()
        try store.setNetworkMCPEndpoint(bindAddress: "127.0.0.1", port: 4150)
        let listener = FakeNetworkMCPListenerManager()
        let viewModel = NetworkMCPSettingsViewModel(settingsStore: store, networkManager: listener)

        viewModel.bindAddressText = "0.0.0.0"
        viewModel.portText = "not-a-port"

        await viewModel.saveEndpointSettings()

        let snapshot = store.networkMCPSettingsSnapshot()
        XCTAssertEqual(snapshot.bindAddress, "127.0.0.1")
        XCTAssertEqual(snapshot.port, 4150)
        XCTAssertEqual(viewModel.feedbackMessage, "Port must be a number.")
        let refreshCount = await listener.getRefreshCount()
        XCTAssertEqual(refreshCount, 0)
    }

    func testSetEnabledTrueEnsuresListenerRunningInsteadOfPlainRefresh() async throws {
        let store = makeSettingsStore()
        let secureStore = FakeNetworkMCPSecurePlainStringStore()
        let tokenStore = MCPRemoteBearerTokenStore(secureStrings: secureStore)
        let token = "network-mcp-test-token"
        let metadata = try tokenStore.savePrimaryToken(token, accessMode: .nonInteractive(reason: .networkMCPAuthentication))
        store.setNetworkMCPTokenMetadata(metadata)
        store.setNetworkMCPDefaultTarget(NetworkMCPDefaultTargetMetadata(displayName: "Test", rootPaths: ["/repo"]))
        let listener = FakeNetworkMCPListenerManager()
        let viewModel = NetworkMCPSettingsViewModel(
            settingsStore: store,
            tokenStore: tokenStore,
            networkManager: listener
        )

        await viewModel.setEnabled(true)

        let snapshot = store.networkMCPSettingsSnapshot()
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(viewModel.feedbackMessage, "Network MCP enabled")
        let refreshCount = await listener.getRefreshCount()
        let ensureRunningAndRefreshCount = await listener.getEnsureRunningAndRefreshCount()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(ensureRunningAndRefreshCount, 1)
    }

    func testGenerateTokenEnsuresListenerWhenPersistedEnabledStateRecoversFromStaleSecureMaterial() async throws {
        let store = makeSettingsStore()
        let secureStore = FakeNetworkMCPSecurePlainStringStore()
        let tokenStore = MCPRemoteBearerTokenStore(secureStrings: secureStore)
        let originalMetadata = try tokenStore.savePrimaryToken(
            "original-network-mcp-token",
            accessMode: .nonInteractive(reason: .networkMCPAuthentication)
        )
        store.setNetworkMCPTokenMetadata(originalMetadata)
        store.setNetworkMCPDefaultTarget(NetworkMCPDefaultTargetMetadata(displayName: "Test", rootPaths: ["/repo"]))
        try store.setNetworkMCPEnabled(true, secureTokenFingerprint: originalMetadata.fingerprint)
        _ = try tokenStore.savePrimaryToken(
            "stale-token-material",
            accessMode: .nonInteractive(reason: .networkMCPAuthentication)
        )
        let listener = FakeNetworkMCPListenerManager()
        let viewModel = NetworkMCPSettingsViewModel(
            settingsStore: store,
            tokenStore: tokenStore,
            networkManager: listener
        )

        await viewModel.generateToken()

        let snapshot = store.networkMCPSettingsSnapshot()
        XCTAssertTrue(snapshot.enabled)
        XCTAssertNotEqual(snapshot.token?.fingerprint, originalMetadata.fingerprint)
        XCTAssertEqual(viewModel.feedbackMessage, "Token generated and copied")
        let refreshCount = await listener.getRefreshCount()
        let ensureRunningAndRefreshCount = await listener.getEnsureRunningAndRefreshCount()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(ensureRunningAndRefreshCount, 1)
    }

    func testRotateTokenEnsuresListenerWhenPersistedEnabled() async throws {
        let store = makeSettingsStore()
        let secureStore = FakeNetworkMCPSecurePlainStringStore()
        let tokenStore = MCPRemoteBearerTokenStore(secureStrings: secureStore)
        let metadata = try tokenStore.savePrimaryToken(
            "network-mcp-token",
            accessMode: .nonInteractive(reason: .networkMCPAuthentication)
        )
        store.setNetworkMCPTokenMetadata(metadata)
        store.setNetworkMCPDefaultTarget(NetworkMCPDefaultTargetMetadata(displayName: "Test", rootPaths: ["/repo"]))
        try store.setNetworkMCPEnabled(true, secureTokenFingerprint: metadata.fingerprint)
        let listener = FakeNetworkMCPListenerManager()
        let viewModel = NetworkMCPSettingsViewModel(
            settingsStore: store,
            tokenStore: tokenStore,
            networkManager: listener
        )

        await viewModel.rotateToken()

        let snapshot = store.networkMCPSettingsSnapshot()
        XCTAssertTrue(snapshot.enabled)
        XCTAssertNotEqual(snapshot.token?.fingerprint, metadata.fingerprint)
        XCTAssertEqual(viewModel.feedbackMessage, "Token rotated and copied")
        let refreshCount = await listener.getRefreshCount()
        let ensureRunningAndRefreshCount = await listener.getEnsureRunningAndRefreshCount()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(ensureRunningAndRefreshCount, 1)
    }

    func testGenerateTokenDoesNotStartListenerWhenPersistedDisabled() async {
        let store = makeSettingsStore()
        let secureStore = FakeNetworkMCPSecurePlainStringStore()
        let tokenStore = MCPRemoteBearerTokenStore(secureStrings: secureStore)
        store.setNetworkMCPDefaultTarget(NetworkMCPDefaultTargetMetadata(displayName: "Test", rootPaths: ["/repo"]))
        let listener = FakeNetworkMCPListenerManager()
        let viewModel = NetworkMCPSettingsViewModel(
            settingsStore: store,
            tokenStore: tokenStore,
            networkManager: listener
        )

        await viewModel.generateToken()

        let snapshot = store.networkMCPSettingsSnapshot()
        XCTAssertFalse(snapshot.enabled)
        XCTAssertNotNil(snapshot.token)
        XCTAssertEqual(viewModel.feedbackMessage, "Token generated and copied")
        let refreshCount = await listener.getRefreshCount()
        let ensureRunningAndRefreshCount = await listener.getEnsureRunningAndRefreshCount()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(ensureRunningAndRefreshCount, 0)
    }

    private func makeSettingsStore() -> GlobalSettingsStore {
        let suiteName = "NetworkMCPSettingsViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkMCPSettingsViewModelTests-\(UUID().uuidString).json")
        return GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
    }
}

private actor FakeNetworkMCPListenerManager: NetworkMCPListenerManaging {
    private var refreshCount = 0
    private var ensureRunningAndRefreshCount = 0

    func networkHTTPListenerStatus() async -> NetworkMCPHTTPListenerStatusSnapshot {
        NetworkMCPHTTPListenerStatusSnapshot(
            enabled: false,
            isListening: false,
            bindAddress: "127.0.0.1",
            port: 4150,
            activeSessionCount: 0,
            lastErrorDescription: nil
        )
    }

    func getRefreshCount() -> Int {
        refreshCount
    }

    func getEnsureRunningAndRefreshCount() -> Int {
        ensureRunningAndRefreshCount
    }

    func refreshHTTPListenerConfiguration() async {
        refreshCount += 1
    }

    func ensureRunningAndRefreshHTTPListenerConfiguration() async {
        ensureRunningAndRefreshCount += 1
    }
}

private final class FakeNetworkMCPSecurePlainStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true
    private var plainValues: [String: String] = [:]

    func getPlainValue(for key: String, accessMode _: KeychainAccessMode) throws -> String? {
        plainValues[key]
    }

    func savePlainValue(_ value: String, for key: String, accessMode _: KeychainAccessMode) throws {
        plainValues[key] = value
    }

    func deletePlainValue(for key: String, accessMode _: KeychainAccessMode) throws {
        plainValues.removeValue(forKey: key)
    }
}
