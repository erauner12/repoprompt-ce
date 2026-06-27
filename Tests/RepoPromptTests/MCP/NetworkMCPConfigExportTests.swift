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
        XCTAssertTrue(export.setupNotes.contains("same-endpoint `GET /mcp` SSE"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("`DELETE /mcp` for session termination"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("context_builder"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("oracle_send"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("SDK Streamable HTTP SSE transport"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("keep the client session open"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("at least 300s"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("600s for broad `context_builder`"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("partially completed"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("Recovering after client timeout"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("do not assume RepoPrompt canceled"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("bind_context list"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("workspace_context"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("continue the recovered `context_builder` chat with `oracle_send`"), export.setupNotes)
        XCTAssertFalse(export.setupNotes.contains("op: \"start\""), export.setupNotes)
        XCTAssertFalse(export.setupNotes.localizedCaseInsensitiveContains("resumable"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("existing RepoPrompt MCP tool catalog"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("High-impact/mutating tools"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("bearer authentication"), export.setupNotes)
        XCTAssertTrue(export.setupNotes.contains("default-target routing"), export.setupNotes)
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

    func testExternalMCPInstructionsTellRemoteClientsToUseSSEForLongRunningTools() {
        let instructions = RepoPromptMCPInstructions.text(for: .unknown)

        XCTAssertTrue(instructions.contains("LONG-RUNNING TOOLS OVER SSE"), instructions)
        XCTAssertTrue(instructions.contains("OpenClaw"), instructions)
        XCTAssertTrue(instructions.contains("ordinary synchronous tool calls"), instructions)
        XCTAssertTrue(instructions.contains("SDK Streamable HTTP SSE transport"), instructions)
        XCTAssertTrue(instructions.contains("at least 300s"), instructions)
        XCTAssertTrue(instructions.contains("600s for broad planning/review calls"), instructions)
        XCTAssertTrue(instructions.contains("server-side context/oracle work"), instructions)
        XCTAssertTrue(instructions.contains("do not assume cancellation"), instructions)
        XCTAssertTrue(instructions.contains("bind_context list"), instructions)
        XCTAssertTrue(instructions.contains("workspace_context"), instructions)
        XCTAssertTrue(instructions.contains("continuing the recovered `context_builder` chat with `oracle_send`"), instructions)
        XCTAssertTrue(instructions.contains("context_builder"), instructions)
        XCTAssertTrue(instructions.contains("oracle_send"), instructions)
        XCTAssertFalse(instructions.contains("op: \"start\""), instructions)
        XCTAssertFalse(instructions.contains("v1 jobs are in-memory"), instructions)
        XCTAssertTrue(instructions.contains("NETWORK MCP BOUNDARY"), instructions)
        XCTAssertTrue(instructions.contains("existing RepoPrompt MCP tool catalog"), instructions)
        XCTAssertTrue(instructions.contains("High-impact/mutating tools"), instructions)
        XCTAssertTrue(instructions.contains("default-target routing"), instructions)
        XCTAssertTrue(instructions.contains("export_response: true"), instructions)
    }

    func testIPv6LoopbackBindExportsBracketedLoopbackHost() {
        let export = MCPConfigExportService.streamableHTTPRemoteConfig(
            settings: NetworkMCPSettingsSnapshot(bindAddress: "::1", port: 4150)
        )

        XCTAssertEqual(export.endpointURL, "http://[::1]:4150/mcp")
    }

    func testIPv6HostOverrideIsBracketed() {
        let export = MCPConfigExportService.streamableHTTPRemoteConfig(
            settings: NetworkMCPSettingsSnapshot(bindAddress: "::1", port: 4150),
            hostOverride: "fe80::1"
        )

        XCTAssertEqual(export.endpointURL, "http://[fe80::1]:4150/mcp")
    }
}
