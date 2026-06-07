import Foundation
@testable import RepoPrompt
import XCTest

final class NetworkMCPConfigExportTests: XCTestCase {
    func testOpenClawStreamableHTTPExportUsesEnvVarBearerTemplateAndEndpoint() {
        let settings = NetworkMCPSettingsSnapshot(
            enabled: true,
            bindAddress: "127.0.0.1",
            port: 4150,
            defaultTarget: NetworkMCPDefaultTargetMetadata(
                displayName: "RepoPrompt CE",
                rootPaths: ["/repo"]
            ),
            token: NetworkMCPBearerTokenMetadata(
                label: "OpenClaw",
                fingerprint: "sha256:abcdef123456",
                createdAt: Date(timeIntervalSince1970: 1800)
            )
        )

        let export = MCPConfigExportService.streamableHTTPRemoteConfig(
            settings: settings,
            serverName: "RepoPromptCE"
        )

        XCTAssertEqual(export.endpointURL, "http://127.0.0.1:4150/mcp")
        XCTAssertEqual(export.authorizationHeaderTemplate, "Bearer ${REPOPROMPT_MCP_TOKEN}")
        XCTAssertTrue(export.openClawJSON.contains("\"transport\" : \"streamable-http\""), export.openClawJSON)
        XCTAssertTrue(export.openClawJSON.contains("\"url\" : \"http:\\/\\/127.0.0.1:4150\\/mcp\""), export.openClawJSON)
        XCTAssertTrue(export.openClawJSON.contains("Bearer ${REPOPROMPT_MCP_TOKEN}"), export.openClawJSON)
        XCTAssertTrue(export.environmentSnippet.contains("export REPOPROMPT_MCP_TOKEN"), export.environmentSnippet)
        XCTAssertTrue(export.setupNotes.contains("Default workspace target: RepoPrompt CE (1 root)"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("OpenClaw"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("op: \"start\""), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("context_builder"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("oracle_send"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("multi-minute HTTP or tool-call timeouts"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("Resumable jobs are in-memory"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("export_response: true"), export.setupNotes)
    }

    func testExportForLANBindUsesPlaceholderHostAndNeverIncludesRawToken() {
        let rawToken = "rp-secret-token-never-export"
        let settings = NetworkMCPSettingsSnapshot(
            enabled: true,
            bindAddress: "0.0.0.0",
            port: 4151,
            defaultTarget: NetworkMCPDefaultTargetMetadata(displayName: "LAN", rootPaths: ["/repo", "/other"]),
            token: NetworkMCPBearerTokenMetadata(
                label: "LAN token",
                fingerprint: MCPRemoteBearerTokenStore.fingerprint(for: rawToken),
                createdAt: Date(timeIntervalSince1970: 1800)
            )
        )

        let export = MCPConfigExportService.streamableHTTPRemoteConfig(settings: settings)
        let combined = [export.openClawJSON, export.genericJSON, export.environmentSnippet, export.setupNotes].joined(separator: "\n")

        XCTAssertEqual(export.endpointURL, "http://<your-mac-lan-ip>:4151/mcp")
        XCTAssertTrue(combined.contains("${REPOPROMPT_MCP_TOKEN}"))
        XCTAssertFalse(combined.contains(rawToken))
        XCTAssertFalse(combined.contains("Bearer \(rawToken)"))
        XCTAssertTrue(export.setupNotes.contains("Non-loopback LAN clients require approval"), export.setupNotes)
    }

    func testExternalMCPInstructionsTellRemoteClientsToUseResumableLongRunningTools() {
        let instructions = RepoPromptMCPInstructions.text(for: .unknown)

        XCTAssertTrue(instructions.contains("RESUMABLE LONG-RUNNING TOOLS"), instructions)
        XCTAssertTrue(instructions.contains("OpenClaw"), instructions)
        XCTAssertTrue(instructions.contains("op: \"start\""), instructions)
        XCTAssertTrue(instructions.contains("context_builder"), instructions)
        XCTAssertTrue(instructions.contains("oracle_send"), instructions)
        XCTAssertTrue(instructions.contains("Do not depend on multi-minute HTTP/tool-call timeouts"), instructions)
        XCTAssertTrue(instructions.contains("v1 jobs are in-memory"), instructions)
        XCTAssertTrue(instructions.contains("export_response: true"), instructions)
    }

    func testIPv6HostOverrideIsBracketed() {
        let export = MCPConfigExportService.streamableHTTPRemoteConfig(
            settings: NetworkMCPSettingsSnapshot(bindAddress: "::1", port: 4150),
            hostOverride: "fe80::1"
        )

        XCTAssertEqual(export.endpointURL, "http://[fe80::1]:4150/mcp")
    }
}
