import Foundation
@testable import RepoPrompt
import XCTest

final class NetworkMCPRemoteDefaultTargetResolverTests: XCTestCase {
    func testFailsClosedWhenDefaultTargetUnset() async {
        let resolver = makeResolver(target: nil, windows: [])

        await assertThrowsAsync({
            _ = try await resolver.resolve()
        }) { error in
            XCTAssertEqual(error as? MCPRemoteDefaultTargetResolutionError, .missingDefaultTarget)
        }
    }

    func testFailsClosedWhenDefaultTargetHasNoWorkspaceOrRootMetadata() async {
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(rootPaths: []),
            windows: []
        )

        await assertThrowsAsync({
            _ = try await resolver.resolve()
        }) { error in
            XCTAssertEqual(error as? MCPRemoteDefaultTargetResolutionError, .underspecifiedDefaultTarget)
        }
    }

    func testWorkspaceIDTargetDoesNotRequireRootMetadata() async throws {
        let workspaceID = UUID()
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(workspaceID: workspaceID, rootPaths: []),
            windows: [candidate(windowID: 6, workspaceID: workspaceID, roots: ["/tmp/project-current"])]
        )

        let resolved = try await resolver.resolve()

        XCTAssertEqual(resolved.windowID, 6)
        XCTAssertEqual(resolved.rootPaths, ["/tmp/project-current"])
        XCTAssertNil(resolved.contextID)
    }

    func testFailsClosedWhenDefaultTargetContextIDIsMalformed() async {
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(
                workspaceID: UUID(),
                contextID: "not-a-uuid",
                rootPaths: ["/tmp/project"]
            ),
            windows: []
        )

        await assertThrowsAsync({
            _ = try await resolver.resolve()
        }) { error in
            XCTAssertEqual(error as? MCPRemoteDefaultTargetResolutionError, .underspecifiedDefaultTarget)
        }
    }

    func testResolvesWorkspaceIDTargetWhenSavedRootsAreStale() async throws {
        let workspaceID = UUID()
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(
                workspaceID: workspaceID,
                displayName: "Project",
                rootPaths: ["/tmp/project-old"],
                openIfNeeded: false
            ),
            windows: [candidate(windowID: 3, workspaceID: workspaceID, roots: ["/tmp/project-new"])]
        )

        let resolved = try await resolver.resolve()

        XCTAssertEqual(resolved.windowID, 3)
        XCTAssertEqual(resolved.workspaceID, workspaceID)
        XCTAssertEqual(resolved.rootPaths, ["/tmp/project-new"])
    }

    func testResolvesExistingOpenWorkspaceAndNormalizesRoots() async throws {
        let workspaceID = UUID()
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(
                workspaceID: workspaceID,
                displayName: "Project",
                rootPaths: ["/tmp/project", "/tmp/project"]
            ),
            windows: [candidate(windowID: 8, workspaceID: workspaceID, roots: ["/tmp/project"])]
        )

        let resolved = try await resolver.resolve()

        XCTAssertEqual(resolved.windowID, 8)
        XCTAssertEqual(resolved.workspaceID, workspaceID)
        XCTAssertEqual(resolved.rootPaths, ["/tmp/project"])
        XCTAssertFalse(resolved.didOpenWindow)
    }

    func testChoosesLowestWindowIDDeterministicallyAmongMultipleMatchingWorkspaceIDWindows() async throws {
        let workspaceID = UUID()
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(workspaceID: workspaceID, rootPaths: ["/tmp/project-old"]),
            windows: [
                candidate(windowID: 9, workspaceID: workspaceID, roots: ["/tmp/project-a"]),
                candidate(windowID: 2, workspaceID: workspaceID, roots: ["/tmp/project-b"]),
                candidate(windowID: 5, workspaceID: workspaceID, roots: ["/tmp/project-c"])
            ]
        )

        let resolved = try await resolver.resolve()

        XCTAssertEqual(resolved.windowID, 2)
        XCTAssertEqual(resolved.rootPaths, ["/tmp/project-b"])
    }

    func testRootOnlyTargetFailsClosedWhenRootsAreStale() async {
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(rootPaths: ["/tmp/project-old"]),
            windows: [candidate(windowID: 3, workspaceID: UUID(), roots: ["/tmp/project-new"])]
        )

        await assertThrowsAsync({
            _ = try await resolver.resolve()
        }) { error in
            guard case .openingNotAllowed = error as? MCPRemoteDefaultTargetResolutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRootOnlyTargetFailsClosedWhenAmbiguous() async {
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(rootPaths: ["/tmp/project"]),
            windows: [
                candidate(windowID: 3, workspaceID: UUID(), roots: ["/tmp/project"]),
                candidate(windowID: 4, workspaceID: UUID(), roots: ["/tmp/project"])
            ]
        )

        await assertThrowsAsync({
            _ = try await resolver.resolve()
        }) { error in
            guard case .staleDefaultTarget = error as? MCPRemoteDefaultTargetResolutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExplicitWindowIDMustMatchConfiguredTarget() async throws {
        let workspaceID = UUID()
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(workspaceID: workspaceID, rootPaths: ["/tmp/project"]),
            windows: [
                candidate(windowID: 1, workspaceID: workspaceID, roots: ["/tmp/project"]),
                candidate(windowID: 2, workspaceID: UUID(), roots: ["/tmp/other"])
            ]
        )

        await assertThrowsAsync({
            _ = try await resolver.resolve(requestedWindowID: 2)
        }) { error in
            guard case let .requestedWindowUnavailable(windowID, guidance) = error as? MCPRemoteDefaultTargetResolutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(windowID, 2)
            XCTAssertTrue(guidance.contains(workspaceID.uuidString), guidance)
        }

        let resolved = try await resolver.resolve(requestedWindowID: 1)
        XCTAssertEqual(resolved.windowID, 1)
    }

    func testOpenIfNeededUsesInjectedOpenerOnlyWhenAllowed() async throws {
        let workspaceID = UUID()
        let target = NetworkMCPDefaultTargetMetadata(
            workspaceID: workspaceID,
            rootPaths: ["/tmp/project"],
            openIfNeeded: true
        )
        var openCount = 0
        let resolver = makeResolver(target: target, windows: []) { openedTarget in
            openCount += 1
            XCTAssertEqual(openedTarget.workspaceID, workspaceID)
            return self.candidate(windowID: 11, workspaceID: workspaceID, roots: ["/tmp/project"])
        }

        let resolved = try await resolver.resolve()

        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(resolved.windowID, 11)
        XCTAssertTrue(resolved.didOpenWindow)
    }

    func testDoesNotOpenWhenOpenIfNeededIsFalse() async {
        let workspaceID = UUID()
        var openCount = 0
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(
                workspaceID: workspaceID,
                rootPaths: ["/tmp/project"],
                openIfNeeded: false
            ),
            windows: []
        ) { _ in
            openCount += 1
            return self.candidate(windowID: 11, workspaceID: workspaceID, roots: ["/tmp/project"])
        }

        await assertThrowsAsync({
            _ = try await resolver.resolve()
        }) { error in
            guard case .openingNotAllowed = error as? MCPRemoteDefaultTargetResolutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(openCount, 0)
    }

    func testOpenIfNeededStillRequiresConfiguredContextProofFromOpenedWindow() async {
        let workspaceID = UUID()
        let expectedContextID = UUID()
        var openCount = 0
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(
                workspaceID: workspaceID,
                contextID: expectedContextID.uuidString,
                rootPaths: ["/tmp/project"],
                openIfNeeded: true
            ),
            windows: []
        ) { _ in
            openCount += 1
            return self.candidate(windowID: 11, workspaceID: workspaceID, roots: ["/tmp/project"])
        }

        await assertThrowsAsync({
            _ = try await resolver.resolve()
        }) { error in
            guard case .openFailed = error as? MCPRemoteDefaultTargetResolutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(openCount, 1)
    }

    func testContextIDMetadataIsValidatedWhenCandidatesExposeTabIDs() async {
        let workspaceID = UUID()
        let expectedContextID = UUID()
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(
                workspaceID: workspaceID,
                contextID: expectedContextID.uuidString,
                rootPaths: ["/tmp/project"]
            ),
            windows: [candidate(windowID: 4, workspaceID: workspaceID, roots: ["/tmp/project"], contextIDs: [UUID()])]
        )

        await assertThrowsAsync({
            _ = try await resolver.resolve()
        }) { error in
            guard case .staleDefaultTarget = error as? MCPRemoteDefaultTargetResolutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testContextIDTargetRequiresCandidateProofEvenWhenCandidateExposesNoTabIDs() async {
        let workspaceID = UUID()
        let expectedContextID = UUID()
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(
                workspaceID: workspaceID,
                contextID: expectedContextID.uuidString,
                rootPaths: ["/tmp/project"]
            ),
            windows: [candidate(windowID: 4, workspaceID: workspaceID, roots: ["/tmp/project"])]
        )

        await assertThrowsAsync({
            _ = try await resolver.resolve()
        }) { error in
            guard case .staleDefaultTarget = error as? MCPRemoteDefaultTargetResolutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testContextIDTargetResolvesOnlyCandidateWithMatchingContextProof() async throws {
        let workspaceID = UUID()
        let expectedContextID = UUID()
        let resolver = makeResolver(
            target: NetworkMCPDefaultTargetMetadata(
                workspaceID: workspaceID,
                contextID: expectedContextID.uuidString,
                rootPaths: ["/tmp/project"]
            ),
            windows: [
                candidate(windowID: 2, workspaceID: workspaceID, roots: ["/tmp/project"]),
                candidate(windowID: 4, workspaceID: workspaceID, roots: ["/tmp/project"], contextIDs: [expectedContextID])
            ]
        )

        let resolved = try await resolver.resolve()

        XCTAssertEqual(resolved.windowID, 4)
        XCTAssertEqual(resolved.contextID, expectedContextID)
    }

    private func assertThrowsAsync(
        _ expression: () async throws -> Void,
        verify: (Error) -> Void
    ) async {
        do {
            try await expression()
            XCTFail("Expected async expression to throw")
        } catch {
            verify(error)
        }
    }

    private func makeResolver(
        target: NetworkMCPDefaultTargetMetadata?,
        windows: [MCPRemoteTargetWindowCandidate],
        opener: MCPRemoteDefaultTargetResolver.WindowOpener? = nil
    ) -> MCPRemoteDefaultTargetResolver {
        MCPRemoteDefaultTargetResolver(
            settingsProvider: {
                NetworkMCPSettingsSnapshot(defaultTarget: target)
            },
            windowProvider: { windows },
            windowOpener: opener
        )
    }

    private func candidate(
        windowID: Int,
        workspaceID: UUID,
        workspaceName: String = "Project",
        roots: [String],
        contextIDs: Set<UUID> = []
    ) -> MCPRemoteTargetWindowCandidate {
        MCPRemoteTargetWindowCandidate(
            windowID: windowID,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            rootPaths: roots,
            contextIDs: contextIDs
        )
    }
}
