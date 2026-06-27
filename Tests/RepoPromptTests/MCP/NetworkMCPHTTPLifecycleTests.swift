import Foundation
@testable import RepoPrompt
import XCTest

final class NetworkMCPHTTPLifecycleTests: XCTestCase {
    func testStaleHTTPListenerStartCannotPublishAfterStopRestart() async throws {
        #if DEBUG
            let fixture = try TemporaryHTTPLifecycleSocketFixture.make(prefix: "http-stale-start")
            defer { fixture.removeOwnedDirectory() }

            let manager = ServerNetworkManager()
            let bearerToken = "network-mcp-lifecycle-token"
            let settings = NetworkMCPSettingsSnapshot(
                enabled: true,
                bindAddress: "127.0.0.1",
                port: 0,
                token: NetworkMCPBearerTokenMetadata(
                    label: "Lifecycle test",
                    fingerprint: MCPRemoteBearerTokenStore.fingerprint(for: bearerToken),
                    createdAt: Date(timeIntervalSince1970: 1800)
                )
            )
            try await manager.debugInstallBootstrapSocketURLOverride(fixture.socketURL)
            await manager.debugSetNetworkMCPBearerTokenOverride(bearerToken)
            await manager.debugSetNetworkMCPSettingsSnapshotOverride(settings)
            do {
                await manager.debugSuspendNextLifecycleFenceCheckpoint(.httpListenerCreatedBeforeStartInvocation)
                let staleStartTask = Task { await manager.start() }
                let startSuspended = await Self.waitUntil {
                    await manager.debugIsLifecycleFenceCheckpointSuspended(.httpListenerCreatedBeforeStartInvocation)
                }
                XCTAssertTrue(startSuspended)
                let suspendedListenerIdentity = await manager.debugHTTPListenerIdentityForLifecycleFenceTest()
                let suspendedStartState = await manager.debugHTTPListenerStartStateForLifecycleFenceTest()
                XCTAssertNil(suspendedListenerIdentity)
                XCTAssertTrue(suspendedStartState)

                await manager.stop()
                let stoppedStartState = await manager.debugHTTPListenerStartStateForLifecycleFenceTest()
                XCTAssertFalse(stoppedStartState)

                await manager.start()
                let replacementReady = await Self.waitUntil {
                    let status = await manager.networkHTTPListenerStatus()
                    return status.enabled && status.isListening
                }
                XCTAssertTrue(replacementReady)
                let replacementGeneration = await manager.debugLifecycleGenerationForLifecycleFenceTest()
                let httpListenerGeneration = await manager.debugHTTPListenerLifecycleGenerationForLifecycleFenceTest()
                let replacementListenerIdentity = await manager.debugHTTPListenerIdentityForLifecycleFenceTest()
                XCTAssertEqual(httpListenerGeneration, replacementGeneration)
                XCTAssertNotNil(replacementListenerIdentity)

                await manager.debugResumeLifecycleFenceCheckpoint(.httpListenerCreatedBeforeStartInvocation)
                await staleStartTask.value
                let runningAfterStaleStart = await manager.isRunning()
                let listenerIdentityAfterStaleStart = await manager.debugHTTPListenerIdentityForLifecycleFenceTest()
                let staleStartState = await manager.debugHTTPListenerStartStateForLifecycleFenceTest()
                XCTAssertTrue(runningAfterStaleStart)
                XCTAssertEqual(listenerIdentityAfterStaleStart, replacementListenerIdentity)
                XCTAssertFalse(staleStartState)

                await manager.stop()
                await manager.debugSetNetworkMCPSettingsSnapshotOverride(nil)
                await manager.debugSetNetworkMCPBearerTokenOverride(nil)
                try await manager.debugRestoreBootstrapSocketURLOverride(expected: fixture.socketURL)
            } catch {
                await manager.debugResumeAllLifecycleFenceCheckpoints()
                await manager.stop()
                await manager.debugSetNetworkMCPSettingsSnapshotOverride(nil)
                await manager.debugSetNetworkMCPBearerTokenOverride(nil)
                try? await manager.debugRestoreBootstrapSocketURLOverride(expected: fixture.socketURL)
                throw error
            }
        #else
            throw XCTSkip("Network MCP HTTP lifecycle fence seams are DEBUG-only")
        #endif
    }

    private static func waitUntil(
        timeout: TimeInterval = 2,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

private struct TemporaryHTTPLifecycleSocketFixture {
    let directoryURL: URL
    let socketURL: URL

    static func make(prefix: String) throws -> Self {
        let directoryURL = URL(
            fileURLWithPath: "/tmp/rpce-http-lifecycle-xctest-\(prefix)-\(getpid())-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = directoryURL.appendingPathComponent("s.sock")
        XCTAssertNotEqual(socketURL.standardizedFileURL, MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return .init(directoryURL: directoryURL, socketURL: socketURL)
    }

    func removeOwnedDirectory() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
