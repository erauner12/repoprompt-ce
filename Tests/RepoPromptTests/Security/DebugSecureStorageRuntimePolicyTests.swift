@testable import RepoPromptCoreMacOS
#if DEBUG
    @testable import RepoPrompt
    import XCTest

    final class DebugSecureStorageRuntimePolicyTests: XCTestCase {
        func testBackendKindRequiresExplicitKeychainMarkerAndNonEmptyTeamIdentifier() {
            let cases: [(marker: String?, teamIdentifier: String?, expected: DebugSecureStorageBackendKind)] = [
                (nil, "TEAM123", .alternateInMemory),
                ("keychain", nil, .alternateInMemory),
                ("keychain", "   ", .alternateInMemory),
                ("alternate-in-memory", "TEAM123", .alternateInMemory),
                (" KEYCHAIN ", "TEAM123", .keychain)
            ]

            for testCase in cases {
                let signingInfo = RuntimeCodeSigningInfo(
                    teamIdentifier: testCase.teamIdentifier,
                    codeIdentifier: nil,
                    detectionErrorDescription: nil
                )

                XCTAssertEqual(
                    DebugSecureStorageRuntimePolicy.backendKind(
                        for: signingInfo,
                        debugStorageMarker: testCase.marker
                    ),
                    testCase.expected,
                    "Unexpected backend for marker \(String(describing: testCase.marker)) and TeamIdentifier \(String(describing: testCase.teamIdentifier))"
                )
            }
        }
    }
#endif
