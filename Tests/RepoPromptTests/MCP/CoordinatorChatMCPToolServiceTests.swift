import Foundation
import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class CoordinatorChatMCPToolServiceTests: XCTestCase {
    func testListReturnsSelectedCoordinatorAndAvailableParents() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let service = makeService(
            coordinatorIDs: [firstID, secondID],
            selectedID: firstID
        )

        let response = try await service.execute(args: ["op": .string("list")])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(object["selected_coordinator_session_id"]?.stringValue, firstID.uuidString)
        XCTAssertEqual(object["selected_title"]?.stringValue, "Coordinator 1")
        XCTAssertEqual(object["coordinators"]?.arrayValue?.count, 2)
    }

    func testSelectUpdatesCoordinatorSelection() async throws {
        let firstID = UUID()
        let secondID = UUID()
        var selectedID = firstID
        let service = makeService(
            coordinatorIDs: [firstID, secondID],
            selectedID: { selectedID },
            select: { selectedID = $0 ?? firstID }
        )

        let response = try await service.execute(args: [
            "op": .string("select"),
            "coordinator_session_id": .string(secondID.uuidString)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(selectedID, secondID)
        XCTAssertEqual(object["selected"]?.boolValue, true)
        XCTAssertEqual(object["selected_coordinator_session_id"]?.stringValue, secondID.uuidString)
    }

    func testSubmitWithNewParentStartsFreshContextAndSubmits() async throws {
        let coordinatorID = UUID()
        var startNewCount = 0
        var submittedMessages: [String] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            startNew: { startNewCount += 1 },
            submit: {
                submittedMessages.append($0)
                return .accepted
            }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "new_parent": .bool(true),
            "message": .string("Reply exactly OK.")
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(startNewCount, 1)
        XCTAssertEqual(submittedMessages, ["Reply exactly OK."])
        XCTAssertEqual(object["accepted"]?.boolValue, true)
    }

    func testSubmitRejectsBlankMessageBeforeMutating() async throws {
        let coordinatorID = UUID()
        var startNewCount = 0
        var submittedMessages: [String] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            startNew: { startNewCount += 1 },
            submit: {
                submittedMessages.append($0)
                return .accepted
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "new_parent": .bool(true),
                "message": .string("   ")
            ])
            XCTFail("Expected blank message to be rejected.")
        } catch {
            XCTAssertEqual(startNewCount, 0)
            XCTAssertTrue(submittedMessages.isEmpty)
        }
    }

    func testCoordinatorChatIsDirectClientOnlyInAgentAdvertisements() {
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.coordinatorChat,
            taskLabelKind: nil
        ))
        for role in AgentModelCatalog.TaskLabelKind.allCases {
            XCTAssertFalse(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                toolName: MCPWindowToolName.coordinatorChat,
                taskLabelKind: role
            ), "\(role)")
        }
    }

    private func makeService(
        coordinatorIDs: [UUID],
        selectedID: UUID,
        startNew: @escaping () -> Void = {},
        submit: @escaping (String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted }
    ) -> CoordinatorChatMCPToolService {
        makeService(
            coordinatorIDs: coordinatorIDs,
            selectedID: { selectedID },
            startNew: startNew,
            submit: submit
        )
    }

    private func makeService(
        coordinatorIDs: [UUID],
        selectedID: @escaping () -> UUID,
        select: @escaping (UUID?) -> Void = { _ in },
        startNew: @escaping () -> Void = {},
        submit: @escaping (String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted }
    ) -> CoordinatorChatMCPToolService {
        CoordinatorChatMCPToolService(toolName: MCPWindowToolName.coordinatorChat) {
            CoordinatorChatMCPToolService.Environment(
                snapshot: {
                    Self.snapshot(
                        coordinatorIDs: coordinatorIDs,
                        selectedID: selectedID()
                    )
                },
                refresh: {},
                selectCoordinator: select,
                startNewCoordinatorRun: startNew,
                submitDirective: submit
            )
        }
    }

    private static func snapshot(
        coordinatorIDs: [UUID],
        selectedID: UUID
    ) -> CoordinatorModeSnapshot {
        let options = coordinatorIDs.enumerated().map { index, id in
            CoordinatorModeCoordinatorOption(
                sessionID: id,
                title: "Coordinator \(index + 1)",
                selectionSource: .demoRuntime,
                isSelected: id == selectedID,
                isLiveInCurrentWindow: true,
                runState: .idle,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }

        return CoordinatorModeSnapshot(
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            sortMode: .lastUpdated,
            boardScope: .coordinatorFleet,
            counts: .empty,
            groups: CoordinatorModeStatusGroup.allCases.map { CoordinatorModeStatusSection(group: $0, rows: []) },
            coordinatorRail: CoordinatorModeCoordinatorRail(
                state: .selected,
                coordinatorSessionID: selectedID,
                selectionSource: .demoRuntime,
                title: options.first(where: { $0.sessionID == selectedID })?.title,
                availableCoordinators: options,
                isLiveInCurrentWindow: true,
                openAgentChatRoute: nil,
                statusReport: nil,
                isComposerEnabled: true,
                isComposerSendEnabled: true
            ),
            pendingInteractions: [],
            mcpAwareness: .off,
            isEmpty: false
        )
    }
}
