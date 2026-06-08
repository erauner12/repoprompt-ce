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

    func refreshHTTPListenerConfiguration() async {
        refreshCount += 1
    }

    func ensureRunningAndRefreshHTTPListenerConfiguration() async {
        ensureRunningAndRefreshCount += 1
    }
}
