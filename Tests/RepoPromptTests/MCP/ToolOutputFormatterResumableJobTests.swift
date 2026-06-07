import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class ToolOutputFormatterResumableJobTests: XCTestCase {
    func testRunningWaitTimeoutEnvelopePreservesUnderlyingStatusAndNextCalls() throws {
        let jobID = UUID()
        let snapshot = MCPResumableJobSnapshot(
            jobID: jobID,
            serverInstanceID: "server-a",
            tool: "context_builder",
            windowID: 3,
            status: .running,
            statusText: "Still working",
            stage: "generating",
            progressMessage: "Writing answer",
            createdAt: Date(timeIntervalSince1970: 1800),
            updatedAt: Date(timeIntervalSince1970: 1801),
            expiresAt: Date(timeIntervalSince1970: 1900),
            pollAfterSeconds: 0.25,
            result: nil,
            error: nil,
            wait: MCPResumableJobWaitMetadata(
                result: .timedOut,
                requestedSeconds: 10,
                effectiveSeconds: 0.25
            )
        )

        let text = try Self.joinedText(ToolOutputFormatter.buildContentBlocks(
            toolName: "context_builder",
            args: [:],
            result: snapshot.toValue(now: Date(timeIntervalSince1970: 1801)),
            emitResources: false
        ))

        XCTAssertTrue(text.contains("## Resumable MCP Job"), text)
        XCTAssertTrue(text.contains("- **Status**: **Running**"), text)
        XCTAssertTrue(text.contains("- **Wait**: timed out (requested 10s, effective 0.25s)"), text)
        XCTAssertTrue(text.contains("job is still resumable and was not marked failed"), text)
        XCTAssertTrue(text.contains("Next wait call"), text)
        XCTAssertTrue(text.contains("\"op\":\"wait\""), text)
        XCTAssertTrue(text.contains("\"window_id\":3"), text)
        XCTAssertFalse(text.contains("**Failed**"), text)
    }

    func testCompletedContextBuilderEnvelopeDelegatesNestedResultFormatter() throws {
        let snapshot = MCPResumableJobSnapshot(
            jobID: UUID(),
            serverInstanceID: "server-a",
            tool: "context_builder",
            windowID: nil,
            status: .completed,
            statusText: "Complete",
            stage: "complete",
            progressMessage: nil,
            createdAt: Date(timeIntervalSince1970: 1800),
            updatedAt: Date(timeIntervalSince1970: 1801),
            expiresAt: Date(timeIntervalSince1970: 1900),
            pollAfterSeconds: 0,
            result: .object([
                "prompt": .string("Final prompt body"),
                "selection": .string("Selected files summary")
            ]),
            error: nil,
            wait: nil
        )

        let text = try Self.joinedText(ToolOutputFormatter.buildContentBlocks(
            toolName: "context_builder",
            args: [:],
            result: snapshot.toValue(now: Date(timeIntervalSince1970: 1801)),
            emitResources: false
        ))

        XCTAssertTrue(text.contains("- **Status**: **Completed**"), text)
        XCTAssertTrue(text.contains("### Result"), text)
        XCTAssertTrue(text.contains("## Final Prompt"), text)
        XCTAssertTrue(text.contains("Final prompt body"), text)
        XCTAssertTrue(text.contains("## Selection"), text)
    }

    func testCompletedOracleSendEnvelopeDelegatesNestedChatFormatter() throws {
        let snapshot = MCPResumableJobSnapshot(
            jobID: UUID(),
            serverInstanceID: "server-a",
            tool: "oracle_send",
            windowID: nil,
            status: .completed,
            statusText: "Complete",
            stage: "complete",
            progressMessage: nil,
            createdAt: Date(timeIntervalSince1970: 1800),
            updatedAt: Date(timeIntervalSince1970: 1801),
            expiresAt: Date(timeIntervalSince1970: 1900),
            pollAfterSeconds: 0,
            result: .object([
                "chat_id": .string("abc123"),
                "mode": .string("chat"),
                "response": .string("Nested Oracle answer")
            ]),
            error: nil,
            wait: nil
        )

        let text = try Self.joinedText(ToolOutputFormatter.buildContentBlocks(
            toolName: "oracle_send",
            args: [:],
            result: snapshot.toValue(now: Date(timeIntervalSince1970: 1801)),
            emitResources: false
        ))

        XCTAssertTrue(text.contains("- **Status**: **Completed**"), text)
        XCTAssertTrue(text.contains("### Result"), text)
        XCTAssertTrue(text.contains("Nested Oracle answer"), text)
        XCTAssertTrue(text.contains("abc123"), text)
    }

    func testTerminalProblemStatusesShowStartNewJobGuidance() throws {
        for status in [
            MCPResumableJobStatus.failed,
            .cancelled,
            .expired,
            .notFound,
            .serverRestarted
        ] {
            let snapshot = MCPResumableJobSnapshot(
                jobID: UUID(),
                serverInstanceID: "server-a",
                tool: "oracle_send",
                windowID: nil,
                status: status,
                statusText: "Terminal",
                stage: nil,
                progressMessage: nil,
                createdAt: Date(timeIntervalSince1970: 1800),
                updatedAt: Date(timeIntervalSince1970: 1801),
                expiresAt: nil,
                pollAfterSeconds: 0,
                result: nil,
                error: status == .failed ? MCPResumableJobError(type: "boom", message: "failed") : nil,
                wait: nil
            )

            let text = try Self.joinedText(ToolOutputFormatter.buildContentBlocks(
                toolName: "oracle_send",
                args: [:],
                result: snapshot.toValue(now: Date(timeIntervalSince1970: 1801)),
                emitResources: false
            ))

            XCTAssertTrue(text.contains("## Resumable MCP Job"), text)
            XCTAssertTrue(text.contains("start a new `oracle_send` job"), text)
        }
    }

    func testNonEnvelopeContextBuilderResultUsesNormalSynchronousFormatter() throws {
        let result: Value = .object([
            "kind": .string("ordinary_result"),
            "prompt": .string("Synchronous prompt")
        ])

        let text = try Self.joinedText(ToolOutputFormatter.buildContentBlocks(
            toolName: "context_builder",
            args: [:],
            result: result,
            emitResources: false
        ))

        XCTAssertFalse(text.contains("Resumable MCP Job"), text)
        XCTAssertTrue(text.contains("## Final Prompt"), text)
        XCTAssertTrue(text.contains("Synchronous prompt"), text)
    }

    private static func joinedText(_ blocks: [MCP.Tool.Content]) throws -> String {
        try blocks.map { block in
            guard case let .text(text, _, _) = block else {
                throw XCTSkip("Expected text content")
            }
            return text
        }.joined(separator: "\n")
    }
}
