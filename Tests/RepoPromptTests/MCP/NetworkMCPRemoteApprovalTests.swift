import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class NetworkMCPRemoteApprovalTests: XCTestCase {
    func testLoopbackValidTokenAutoApprovesWithoutPromptOrTrustedPolicy() async throws {
        let store = try makeStore()
        var promptCount = 0
        let manager = MCPRemoteClientApprovalManager(settingsStore: store) { _ in
            promptCount += 1
            return .deny
        }

        let result = await manager.evaluate(.init(
            clientDisplayName: "OpenClaw",
            sourceAddress: "127.0.0.1:5000",
            tokenFingerprint: "sha256:abc"
        ))

        XCTAssertEqual(result, .approved(alwaysAllow: false, trustedPolicy: nil))
        XCTAssertEqual(promptCount, 0)
        XCTAssertTrue(store.networkMCPSettingsSnapshot().trustedClients.isEmpty)
    }

    func testRejectsNonPrivateRemoteAddressBeforePrompt() async throws {
        let store = try makeStore()
        var promptCount = 0
        let manager = MCPRemoteClientApprovalManager(settingsStore: store) { _ in
            promptCount += 1
            return .allow(alwaysAllow: true)
        }

        let result = await manager.evaluate(.init(
            clientDisplayName: "OpenClaw",
            sourceAddress: "8.8.8.8:1234",
            tokenFingerprint: "sha256:abc"
        ))

        XCTAssertEqual(result, .rejected(.nonLANSourceAddress("8.8.8.8")))
        XCTAssertEqual(promptCount, 0)
    }

    func testAlwaysAllowPersistsPolicyKeyedByNormalizedClientAndTokenFingerprint() async throws {
        let now = Date(timeIntervalSince1970: 1000)
        let policyID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let store = try makeStore()
        let manager = MCPRemoteClientApprovalManager(
            settingsStore: store,
            now: { now },
            idGenerator: { policyID }
        ) { request in
            XCTAssertEqual(request.normalizedClientID, "openclaw")
            return .allow(alwaysAllow: true)
        }

        let result = await manager.evaluate(.init(
            clientDisplayName: " OpenClaw ",
            sourceAddress: "192.168.1.44:61234",
            tokenFingerprint: "sha256:token-a"
        ))

        guard case let .approved(alwaysAllow, trustedPolicy?) = result else {
            return XCTFail("Expected trusted approval, got \(result)")
        }
        XCTAssertTrue(alwaysAllow)
        XCTAssertEqual(trustedPolicy.id, policyID)
        XCTAssertEqual(trustedPolicy.normalizedClientID, "openclaw")
        XCTAssertEqual(trustedPolicy.tokenFingerprint, "sha256:token-a")
        XCTAssertEqual(trustedPolicy.lastAddress, "192.168.1.44")
        XCTAssertEqual(trustedPolicy.createdAt, now)
        XCTAssertEqual(store.networkMCPSettingsSnapshot().trustedClients, [trustedPolicy])
    }

    func testTrustedPolicyRequiresMatchingTokenFingerprint() async throws {
        let store = try makeStore()
        store.setNetworkMCPTrustedClients([
            NetworkMCPTrustedClientPolicy(
                clientDisplayName: "OpenClaw",
                normalizedClientID: "openclaw",
                tokenFingerprint: "sha256:old-token",
                lastAddress: "192.168.1.20",
                createdAt: Date(timeIntervalSince1970: 100),
                lastUsedAt: Date(timeIntervalSince1970: 100)
            )
        ])

        var promptCount = 0
        let manager = MCPRemoteClientApprovalManager(settingsStore: store) { _ in
            promptCount += 1
            return .deny
        }

        let result = await manager.evaluate(.init(
            clientDisplayName: "OpenClaw",
            sourceAddress: "192.168.1.21",
            tokenFingerprint: "sha256:new-token"
        ))

        XCTAssertEqual(result, .denied)
        XCTAssertEqual(promptCount, 1)
    }

    func testTrustedPolicyMatchUpdatesLastAddressAndUsedAtWithoutPrompt() async throws {
        let createdAt = Date(timeIntervalSince1970: 100)
        let usedAt = Date(timeIntervalSince1970: 500)
        let store = try makeStore()
        let policy = NetworkMCPTrustedClientPolicy(
            clientDisplayName: "OpenClaw",
            normalizedClientID: "openclaw",
            tokenFingerprint: "sha256:token",
            lastAddress: "192.168.1.20",
            createdAt: createdAt,
            lastUsedAt: createdAt
        )
        store.setNetworkMCPTrustedClients([policy])
        var promptCount = 0
        let manager = MCPRemoteClientApprovalManager(settingsStore: store, now: { usedAt }) { _ in
            promptCount += 1
            return .deny
        }

        let result = await manager.evaluate(.init(
            clientDisplayName: "OpenClaw",
            sourceAddress: "192.168.1.55",
            tokenFingerprint: "sha256:token"
        ))

        XCTAssertEqual(result, .approved(alwaysAllow: false, trustedPolicy: policy))
        XCTAssertEqual(promptCount, 0)
        let updated = try XCTUnwrap(store.networkMCPSettingsSnapshot().trustedClients.first)
        XCTAssertEqual(updated.lastAddress, "192.168.1.55")
        XCTAssertEqual(updated.lastUsedAt, usedAt)
        XCTAssertEqual(updated.createdAt, createdAt)
    }

    func testQueuesRemoteApprovalPromptsFIFO() async throws {
        let store = try makeStore()
        var promptedClients: [String] = []
        var continuations: [CheckedContinuation<MCPRemoteClientApprovalDecision, Never>] = []
        let manager = MCPRemoteClientApprovalManager(settingsStore: store) { request in
            promptedClients.append(request.displayName)
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        let firstTask = Task { @MainActor in
            await manager.evaluate(.init(
                clientDisplayName: "First",
                sourceAddress: "192.168.1.10",
                tokenFingerprint: "sha256:first"
            ))
        }
        await waitUntil { continuations.count == 1 }
        XCTAssertEqual(promptedClients, ["First"])

        let secondTask = Task { @MainActor in
            await manager.evaluate(.init(
                clientDisplayName: "Second",
                sourceAddress: "192.168.1.11",
                tokenFingerprint: "sha256:second"
            ))
        }
        await Task.yield()
        XCTAssertEqual(promptedClients, ["First"])
        XCTAssertEqual(continuations.count, 1)

        continuations[0].resume(returning: .allow(alwaysAllow: false))
        let firstResult = await firstTask.value
        XCTAssertEqual(firstResult, .approved(alwaysAllow: false, trustedPolicy: nil))
        await waitUntil { continuations.count == 2 }
        XCTAssertEqual(promptedClients, ["First", "Second"])
        XCTAssertEqual(continuations.count, 2)

        continuations[1].resume(returning: .deny)
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, .denied)
    }

    func testAddressClassifierHandlesLANLoopbackAndPublicAddresses() {
        XCTAssertTrue(MCPRemoteClientAddress("localhost").isLoopback)
        XCTAssertTrue(MCPRemoteClientAddress("[::1]:4150").isLoopback)
        XCTAssertTrue(MCPRemoteClientAddress("IPv4(host: \"127.0.0.1\", port: 52178)").isLoopback)
        XCTAssertEqual(MCPRemoteClientAddress("IPv4(host: \"127.0.0.1\", port: 52178)").normalizedHost, "127.0.0.1")
        XCTAssertTrue(MCPRemoteClientAddress("IPv4(host: \"192.168.10.5\", port: 333)").isPrivateLANOrLinkLocal)
        XCTAssertTrue(MCPRemoteClientAddress("IPv6(host: \"::1\", port: 52178)").isLoopback)
        XCTAssertTrue(MCPRemoteClientAddress("10.0.0.12").isPrivateLANOrLinkLocal)
        XCTAssertTrue(MCPRemoteClientAddress("172.16.2.3").isPrivateLANOrLinkLocal)
        XCTAssertTrue(MCPRemoteClientAddress("192.168.10.5:333").isPrivateLANOrLinkLocal)
        XCTAssertTrue(MCPRemoteClientAddress("169.254.10.5").isPrivateLANOrLinkLocal)
        XCTAssertTrue(MCPRemoteClientAddress("fc00::1").isPrivateLANOrLinkLocal)
        XCTAssertTrue(MCPRemoteClientAddress("fe80::1").isPrivateLANOrLinkLocal)
        XCTAssertTrue(MCPRemoteClientAddress("[fe80::1%en0]:4150").isPrivateLANOrLinkLocal)
        XCTAssertEqual(MCPRemoteClientAddress("[fe80::1%en0]:4150").normalizedHost, "fe80::1")
        XCTAssertFalse(MCPRemoteClientAddress("172.32.0.1").isPrivateLANOrLinkLocal)
        XCTAssertFalse(MCPRemoteClientAddress("8.8.8.8").isPrivateLANOrLinkLocal)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        _ predicate: () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !predicate(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeStore() throws -> GlobalSettingsStore {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkMCPRemoteApprovalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NetworkMCPRemoteApprovalTests.\(UUID().uuidString)"))
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
    }
}
