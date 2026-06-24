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
        let firstCoordinator = try XCTUnwrap(object["coordinators"]?.arrayValue?.first?.objectValue)
        XCTAssertNotNil(firstCoordinator["tab_id"]?.stringValue)
        XCTAssertEqual(firstCoordinator["workspace_id"]?.stringValue, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(firstCoordinator["pinned"]?.boolValue, false)
        XCTAssertEqual(firstCoordinator["persisted_only"]?.boolValue, false)
        XCTAssertEqual(firstCoordinator["child_counts"]?.objectValue?["total"]?.intValue, 0)
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

    func testSubmitRoutesToPendingChildInteractionWhenSelectedCoordinatorNeedsInput() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var coordinatorSubmissions: [String] = []
        var childResponses: [(submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission, rowID: UUID)] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submit: {
                coordinatorSubmissions.append($0)
                return .accepted
            },
            pendingChild: { childRow },
            submitPendingChild: { submission, row in
                childResponses.append((submission, row.sessionID))
                return .accepted
            }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "message": .string("Stay involved at review checkpoints.")
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertTrue(coordinatorSubmissions.isEmpty)
        XCTAssertEqual(childResponses.count, 1)
        XCTAssertEqual(childResponses.first?.submission.text, "Stay involved at review checkpoints.")
        XCTAssertEqual(childResponses.first?.submission.displayText, "Stay involved at review checkpoints.")
        XCTAssertEqual(childResponses.first?.rowID, childRow.sessionID)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "child_interaction")
    }

    func testSubmitRoutesStructuredAnswersToPendingChildInteraction() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var childResponses: [CoordinatorModeViewModel.ChildInteractionResponseSubmission] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            pendingChild: { childRow },
            submitPendingChild: { submission, _ in
                childResponses.append(submission)
                return .accepted
            }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "answers": .object([
                "involvement": .object([
                    "selected_options": .array([.string("Mid-flow")]),
                    "answers": .array([.string("Mid-flow")])
                ])
            ])
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "child_interaction")
        let submission = try XCTUnwrap(childResponses.first)
        XCTAssertNil(submission.text)
        XCTAssertEqual(submission.answersByQuestionID["involvement"]?.selectedOptions, ["Mid-flow"])
        XCTAssertEqual(submission.answersByQuestionID["involvement"]?.answers, ["Mid-flow"])
        XCTAssertEqual(submission.displayText, "involvement: Mid-flow")
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
        submit: @escaping (String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted },
        pendingChild: @escaping () -> CoordinatorModeRow? = { nil },
        submitPendingChild: @escaping (CoordinatorModeViewModel.ChildInteractionResponseSubmission, CoordinatorModeRow) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted }
    ) -> CoordinatorChatMCPToolService {
        makeService(
            coordinatorIDs: coordinatorIDs,
            selectedID: { selectedID },
            startNew: startNew,
            submit: submit,
            pendingChild: pendingChild,
            submitPendingChild: submitPendingChild
        )
    }

    private func makeService(
        coordinatorIDs: [UUID],
        selectedID: @escaping () -> UUID,
        select: @escaping (UUID?) -> Void = { _ in },
        startNew: @escaping () -> Void = {},
        submit: @escaping (String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted },
        pendingChild: @escaping () -> CoordinatorModeRow? = { nil },
        submitPendingChild: @escaping (CoordinatorModeViewModel.ChildInteractionResponseSubmission, CoordinatorModeRow) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted }
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
                submitDirective: submit,
                activePendingChildInteractionRow: pendingChild,
                submitPendingChildInteractionResponse: submitPendingChild
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
                tabID: UUID(),
                workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
                title: "Coordinator \(index + 1)",
                selectionSource: .demoRuntime,
                isSelected: id == selectedID,
                isLiveInCurrentWindow: true,
                isPinned: false,
                isPersistedOnly: false,
                childCounts: .empty,
                runState: .idle,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                lastActivityAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
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
                coordinatorTabID: options.first(where: { $0.sessionID == selectedID })?.tabID,
                selectionSource: .demoRuntime,
                title: options.first(where: { $0.sessionID == selectedID })?.title,
                availableCoordinators: options,
                isLiveInCurrentWindow: true,
                isPersistedOnly: false,
                isPinned: false,
                childCounts: .empty,
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

    private static func pendingChildRow(parentCoordinatorID: UUID) -> CoordinatorModeRow {
        let childID = UUID()
        return CoordinatorModeRow(
            id: childID,
            sessionID: childID,
            tabID: UUID(),
            title: "Deep Plan child",
            providerName: "codexExec",
            modelName: "gpt-5.5",
            runState: .waitingForQuestion,
            statusGroup: .needsYou,
            parentSessionID: parentCoordinatorID,
            parentCoordinator: CoordinatorModeRow.ParentCoordinator(
                sessionID: parentCoordinatorID,
                title: "Coordinator mission",
                isSelected: true
            ),
            childSessionIDs: [],
            isMCPOriginated: true,
            isPersistedOnly: false,
            isCoordinator: false,
            startedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            priority: nil,
            workstream: nil,
            workstreamSummary: nil,
            workflow: CoordinatorModeWorkflowDisplaySummary(
                id: "rp-deep-plan",
                displayName: "Deep Plan",
                iconName: "text.book.closed.fill",
                accentColorHex: "#2F80ED"
            ),
            mergeAttention: nil,
            pendingInteraction: CoordinatorModePendingInteractionSummary(
                id: UUID(),
                sessionID: childID,
                kind: .question,
                responseType: .structured,
                title: "Deep Plan involvement",
                prompt: "How involved would you like to be?",
                context: "Choose how the child should pause.",
                options: [],
                fields: [
                    AgentRunMCPSnapshot.Interaction.Field(
                        id: "involvement",
                        header: "Plan involvement",
                        prompt: "How involved would you like to be?",
                        context: nil,
                        isSecret: false,
                        allowsOther: true,
                        allowsMultiple: false,
                        allowsCustom: true,
                        options: [
                            AgentRunMCPSnapshot.Interaction.Option(label: "Mid-flow", description: nil)
                        ]
                    )
                ],
                details: [],
                openAgentChatRoute: nil
            ),
            openAgentChatRoute: nil,
            statusReport: nil,
            origin: .coordinatorFleet
        )
    }
}
