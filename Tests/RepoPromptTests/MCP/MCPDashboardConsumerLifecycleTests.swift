import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPDashboardConsumerLifecycleTests: XCTestCase {
    func testFirstVisibleConsumerStartsObservationAndLastHiddenStopsAndClearsSnapshot() async throws {
        let window = makeWindowWithoutAutoStart()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let server = window.mcpServer

        let initialSubscriberCount = await server.test_dashboardSubscriberCount()
        XCTAssertEqual(initialSubscriberCount, 0)
        XCTAssertNil(server.dashboard)

        server.setDashboardUpdatesVisible(true, consumer: .coordinatorMode)
        try await waitForSubscriberCount(server, 1)
        try await waitForDashboard(server, isNil: false)
        XCTAssertTrue(server.test_hasDashboardTask)

        server.setDashboardUpdatesVisible(false, consumer: .coordinatorMode)
        try await waitForSubscriberCount(server, 0)
        XCTAssertFalse(server.test_hasDashboardTask)
        XCTAssertNil(server.dashboard)
    }

    func testSecondVisibleConsumerDoesNotStartDuplicateTaskAndHidingOneKeepsActive() async throws {
        let window = makeWindowWithoutAutoStart()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let server = window.mcpServer

        server.setDashboardUpdatesVisible(true, consumer: .toolbarPopover)
        try await waitForSubscriberCount(server, 1)
        XCTAssertEqual(server.test_dashboardConsumerCount, 1)

        server.setDashboardUpdatesVisible(true, consumer: .coordinatorMode)
        try await waitForSubscriberCount(server, 1)
        XCTAssertEqual(server.test_dashboardConsumerCount, 2)
        XCTAssertTrue(server.test_hasDashboardTask)

        server.setDashboardUpdatesVisible(false, consumer: .toolbarPopover)
        try await waitForSubscriberCount(server, 1)
        XCTAssertEqual(server.test_dashboardConsumerCount, 1)
        XCTAssertTrue(server.test_hasDashboardTask)

        server.setDashboardUpdatesVisible(false, consumer: .coordinatorMode)
        try await waitForSubscriberCount(server, 0)
        XCTAssertNil(server.dashboard)
    }

    func testWindowToolsForceObservationIndependentOfVisibleConsumers() async throws {
        let window = makeWindowWithoutAutoStart()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let server = window.mcpServer

        server.windowToolsEnabled = true
        try await waitForSubscriberCount(server, 1)
        XCTAssertTrue(server.test_hasDashboardTask)

        server.setDashboardUpdatesVisible(true, consumer: .coordinatorMode)
        server.setDashboardUpdatesVisible(false, consumer: .coordinatorMode)
        try await waitForSubscriberCount(server, 1)
        XCTAssertTrue(server.test_hasDashboardTask)

        server.windowToolsEnabled = false
        try await waitForSubscriberCount(server, 0)
        XCTAssertNil(server.dashboard)
    }

    func testStatusViewStartStopAndMixedToolbarStatusCoordinatorVisibilityShareLifecycle() async throws {
        let window = makeWindowWithoutAutoStart()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let server = window.mcpServer

        server.startDashboardUpdates()
        try await waitForSubscriberCount(server, 1)
        XCTAssertEqual(server.test_dashboardConsumerCount, 1)

        server.setDashboardUpdatesVisible(true, consumer: .toolbarPopover)
        server.setDashboardUpdatesVisible(true, consumer: .coordinatorMode)
        try await waitForSubscriberCount(server, 1)
        XCTAssertEqual(server.test_dashboardConsumerCount, 3)

        server.stopDashboardUpdates()
        try await waitForSubscriberCount(server, 1)
        XCTAssertEqual(server.test_dashboardConsumerCount, 2)
        XCTAssertTrue(server.test_hasDashboardTask)

        server.setDashboardUpdatesVisible(false, consumer: .toolbarPopover)
        try await waitForSubscriberCount(server, 1)
        XCTAssertEqual(server.test_dashboardConsumerCount, 1)

        server.setDashboardUpdatesVisible(false, consumer: .coordinatorMode)
        try await waitForSubscriberCount(server, 0)
        XCTAssertEqual(server.test_dashboardConsumerCount, 0)
        XCTAssertNil(server.dashboard)
    }

    private func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private func waitForSubscriberCount(
        _ server: MCPServerViewModel,
        _ expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitUntil(file: file, line: line) {
            await server.test_dashboardSubscriberCount() == expectedCount
        }
    }

    private func waitForDashboard(
        _ server: MCPServerViewModel,
        isNil: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitUntil(file: file, line: line) {
            (server.dashboard == nil) == isNil
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}
