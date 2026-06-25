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

    func testMissionPlanUpdatesStateWithoutSubmittingChatTurn() async throws {
        let coordinatorID = UUID()
        let childID = UUID()
        var submittedMessages: [String] = []
        var missionPlans: [UUID: CoordinatorMissionPlan] = [:]
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submit: {
                submittedMessages.append($0)
                return .accepted
            },
            missionPlans: { missionPlans },
            updateMissionPlan: { sessionID, update in
                missionPlans[sessionID] = CoordinatorMissionPlan(
                    objective: update.objective,
                    status: update.status ?? .draft,
                    approvalState: update.approvalState ?? .notRequired,
                    workstreams: update.workstreams ?? [],
                    nodes: update.nodes ?? [],
                    events: update.events,
                    updatedAt: Date(timeIntervalSince1970: 10)
                )
            }
        )

        let args: [String: Value] = [
            "op": .string("mission_plan"),
            "objective": .string("Ship docs"),
            "workstreams": .array([
                .object([
                    "title": .string("Docs implementation"),
                    "purpose": .string("Apply the README wording change."),
                    "role": .string("Implement"),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object([
                        "mode": .string("createIsolated"),
                        "worktree_id": .string("wt-docs"),
                        "reason": .string("Mutable docs work should stay isolated.")
                    ]),
                    "primary_session_id": .string(childID.uuidString)
                ])
            ])
        ]
        let response = try await service.execute(args: args)
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertTrue(submittedMessages.isEmpty)
        XCTAssertEqual(object["updated"]?.boolValue, true)
        let plan = try XCTUnwrap(object["mission_plan"]?.objectValue)
        XCTAssertEqual(plan["objective"]?.stringValue, "Ship docs")
        XCTAssertEqual(plan["revision"]?.intValue, 1)
        let workstream = try XCTUnwrap(plan["workstreams"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(workstream["title"]?.stringValue, "Docs implementation")
        XCTAssertEqual(workstream["default_policy"]?.stringValue, "fresh_worktree")
        let strategy = try XCTUnwrap(workstream["worktree_strategy"]?.objectValue)
        XCTAssertEqual(strategy["mode"]?.stringValue, "createIsolated")
        XCTAssertEqual(strategy["display_name"]?.stringValue, "New isolated worktree")
        XCTAssertEqual(strategy["worktree_id"]?.stringValue, "wt-docs")
        XCTAssertEqual(workstream["primary_session_id"]?.stringValue, childID.uuidString)
    }

    func testMissionPlanAcceptsNodesStatusAndEvents() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        var missionPlans: [UUID: CoordinatorMissionPlan] = [:]
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { missionPlans },
            updateMissionPlan: { sessionID, update in
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                state.updateMissionPlan(update)
                missionPlans[sessionID] = state.missionPlan
            }
        )

        let response = try await service.execute(args: [
            "op": .string("mission_plan"),
            "objective": .string("Ship DAG"),
            "status": .string("running"),
            "approval_state": .string("approved"),
            "workstreams": .array([
                .object([
                    "id": .string(workstreamID.uuidString),
                    "title": .string("Implement"),
                    "purpose": .string("Make the docs change."),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object([
                        "mode": .string("createIsolated")
                    ])
                ])
            ]),
            "nodes": .array([
                .object([
                    "id": .string(nodeID.uuidString),
                    "title": .string("Docs edit"),
                    "workstream_title": .string("Implement"),
                    "workflow": .object([
                        "id": .string("builtin-orchestrate"),
                        "name": .string("Orchestrate"),
                        "icon_name": .string("arrow.triangle.branch"),
                        "accent_color_hex": .string("#30D158")
                    ]),
                    "completion_evidence": .string("README wording is updated and tests pass."),
                    "execution_policy": .string("fresh_worktree"),
                    "status": .string("running"),
                    "bound_session_id": .string(childID.uuidString)
                ])
            ]),
            "events": .array([
                .object([
                    "kind": .string("node_started"),
                    "node_title": .string("Docs edit"),
                    "session_id": .string(childID.uuidString),
                    "summary": .string("Child started.")
                ])
            ])
        ])

        let plan = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue)
        XCTAssertEqual(plan["status"]?.stringValue, "running")
        XCTAssertEqual(plan["approval_state"]?.stringValue, "approved")
        let node = try XCTUnwrap(plan["nodes"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(node["id"]?.stringValue, nodeID.uuidString)
        XCTAssertEqual(node["workstream_id"]?.stringValue, workstreamID.uuidString)
        XCTAssertEqual(node["workflow_name"]?.stringValue, "Orchestrate")
        XCTAssertEqual(node["completion_evidence"]?.stringValue, "README wording is updated and tests pass.")
        let workflow = try XCTUnwrap(node["workflow"]?.objectValue)
        XCTAssertEqual(workflow["id"]?.stringValue, "builtin-orchestrate")
        XCTAssertEqual(workflow["icon_name"]?.stringValue, "arrow.triangle.branch")
        XCTAssertEqual(node["bound_session_id"]?.stringValue, childID.uuidString)
        let events = try XCTUnwrap(plan["events"]?.arrayValue)
        XCTAssertEqual(events.last?.objectValue?["kind"]?.stringValue, "node_started")
        XCTAssertEqual(events.last?.objectValue?["node_id"]?.stringValue, nodeID.uuidString)
    }

    func testMissionPlanSubsetUpdatePreservesExistingDagEntries() async throws {
        let coordinatorID = UUID()
        let discoveryWorkstreamID = UUID()
        let implementationWorkstreamID = UUID()
        let reviewWorkstreamID = UUID()
        let discoveryNodeID = UUID()
        let implementationNodeID = UUID()
        let settingNodeID = UUID()
        let reviewNodeID = UUID()
        let childID = UUID()
        var missionPlans: [UUID: CoordinatorMissionPlan] = [:]
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { missionPlans },
            updateMissionPlan: { sessionID, update in
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                state.updateMissionPlan(update)
                missionPlans[sessionID] = state.missionPlan
            }
        )

        _ = try await service.execute(args: [
            "op": .string("mission_plan"),
            "objective": .string("Issue 298 provider cleanup"),
            "status": .string("running"),
            "approval_state": .string("approved"),
            "workstreams": .array([
                .object([
                    "id": .string(discoveryWorkstreamID.uuidString),
                    "title": .string("Discovery"),
                    "purpose": .string("Map cleanup code paths."),
                    "default_policy": .string("fresh_readonly_child"),
                    "worktree_strategy": .object(["mode": .string("noneReadOnly")])
                ]),
                .object([
                    "id": .string(implementationWorkstreamID.uuidString),
                    "title": .string("Implementation"),
                    "purpose": .string("Make provider cleanup changes."),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object(["mode": .string("createIsolated")])
                ]),
                .object([
                    "id": .string(reviewWorkstreamID.uuidString),
                    "title": .string("Review"),
                    "purpose": .string("Fresh review the implementation."),
                    "default_policy": .string("fresh_sibling_on_same_worktree"),
                    "worktree_strategy": .object(["mode": .string("reuseWorkstream")])
                ])
            ]),
            "nodes": .array([
                .object([
                    "id": .string(discoveryNodeID.uuidString),
                    "title": .string("Map cleanup entry points"),
                    "workstream_id": .string(discoveryWorkstreamID.uuidString),
                    "workflow_name": .string("Investigate"),
                    "execution_policy": .string("fresh_readonly_child"),
                    "status": .string("completed")
                ]),
                .object([
                    "id": .string(implementationNodeID.uuidString),
                    "title": .string("Add provider cleanup contract"),
                    "detail": .string("Implement cleanup contract."),
                    "workstream_id": .string(implementationWorkstreamID.uuidString),
                    "depends_on": .array([.string(discoveryNodeID.uuidString)]),
                    "workflow_name": .string("Orchestrate"),
                    "execution_policy": .string("fresh_worktree"),
                    "status": .string("pending")
                ]),
                .object([
                    "id": .string(settingNodeID.uuidString),
                    "title": .string("Add cleanup setting"),
                    "workstream_id": .string(implementationWorkstreamID.uuidString),
                    "depends_on": .array([.string(discoveryNodeID.uuidString)]),
                    "workflow_name": .string("Orchestrate"),
                    "execution_policy": .string("fresh_worktree"),
                    "status": .string("pending")
                ]),
                .object([
                    "id": .string(reviewNodeID.uuidString),
                    "title": .string("Review cleanup safety"),
                    "workstream_id": .string(reviewWorkstreamID.uuidString),
                    "depends_on": .array([
                        .string(implementationNodeID.uuidString),
                        .string(settingNodeID.uuidString)
                    ]),
                    "workflow_name": .string("Review"),
                    "execution_policy": .string("fresh_sibling_on_same_worktree"),
                    "status": .string("pending")
                ])
            ])
        ])

        let response = try await service.execute(args: [
            "op": .string("mission_plan"),
            "workstreams": .array([
                .object([
                    "id": .string(implementationWorkstreamID.uuidString),
                    "title": .string("Implementation"),
                    "primary_session_id": .string(childID.uuidString)
                ])
            ]),
            "nodes": .array([
                .object([
                    "id": .string(implementationNodeID.uuidString),
                    "title": .string("Add provider cleanup contract"),
                    "status": .string("running"),
                    "bound_session_id": .string(childID.uuidString)
                ]),
                .object([
                    "id": .string(settingNodeID.uuidString),
                    "title": .string("Add cleanup setting"),
                    "status": .string("running"),
                    "bound_session_id": .string(childID.uuidString)
                ])
            ])
        ])

        let plan = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue)
        XCTAssertEqual(plan["revision"]?.intValue, 2)
        let workstreams = try XCTUnwrap(plan["workstreams"]?.arrayValue)
        XCTAssertEqual(workstreams.count, 3)
        XCTAssertEqual(workstreams.map { $0.objectValue?["id"]?.stringValue }, [
            discoveryWorkstreamID.uuidString,
            implementationWorkstreamID.uuidString,
            reviewWorkstreamID.uuidString
        ])
        XCTAssertEqual(workstreams[0].objectValue?["default_policy"]?.stringValue, "fresh_readonly_child")
        XCTAssertEqual(workstreams[1].objectValue?["purpose"]?.stringValue, "Make provider cleanup changes.")
        XCTAssertEqual(workstreams[1].objectValue?["default_policy"]?.stringValue, "fresh_worktree")
        let nodes = try XCTUnwrap(plan["nodes"]?.arrayValue)
        XCTAssertEqual(nodes.count, 4)
        XCTAssertEqual(nodes.map { $0.objectValue?["id"]?.stringValue }, [
            discoveryNodeID.uuidString,
            implementationNodeID.uuidString,
            settingNodeID.uuidString,
            reviewNodeID.uuidString
        ])
        XCTAssertEqual(nodes[0].objectValue?["execution_policy"]?.stringValue, "fresh_readonly_child")
        XCTAssertEqual(nodes[0].objectValue?["workflow_name"]?.stringValue, "Investigate")
        XCTAssertEqual(nodes[1].objectValue?["status"]?.stringValue, "running")
        XCTAssertEqual(nodes[1].objectValue?["bound_session_id"]?.stringValue, childID.uuidString)
        XCTAssertEqual(nodes[1].objectValue?["detail"]?.stringValue, "Implement cleanup contract.")
        XCTAssertEqual(nodes[1].objectValue?["depends_on"]?.arrayValue?.compactMap(\.stringValue), [discoveryNodeID.uuidString])
        XCTAssertEqual(nodes[3].objectValue?["workflow_name"]?.stringValue, "Review")
    }

    func testMissionStatusReturnsCompactDagStatus() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let planNodeID = UUID()
        let reviewNodeID = UUID()
        let plan = CoordinatorMissionPlan(
            revision: 3,
            objective: "Ship DAG",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Implement",
                    purpose: "Make the docs change.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: planNodeID,
                    title: "Plan",
                    workstreamID: workstreamID,
                    executionPolicy: .coordinatorOnly,
                    status: .completed
                ),
                CoordinatorMissionPlanNode(
                    id: reviewNodeID,
                    title: "Review implementation from fresh session",
                    workflowHint: CoordinatorMissionPlanNodeWorkflowHint(
                        id: "builtin-review",
                        name: "Review",
                        iconName: "eye.fill",
                        accentColorHex: "#BF5AF2"
                    ),
                    completionEvidence: "Review reports no must-fix issues.",
                    workstreamID: workstreamID,
                    dependsOn: [planNodeID],
                    executionPolicy: .freshSiblingOnSameWorktree,
                    status: .pending
                )
            ],
            events: [
                CoordinatorMissionPlanEvent(
                    kind: .nodeCompleted,
                    nodeID: planNodeID,
                    timestamp: Date(timeIntervalSince1970: 20),
                    summary: "Plan complete."
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("mission_status")
        ])
        let status = try XCTUnwrap(response.objectValue?["mission_status"]?.objectValue)

        XCTAssertEqual(status["has_plan"]?.boolValue, true)
        XCTAssertTrue(status["debug_summary"]?.stringValue?.contains("1/2 terminal nodes") == true)
        let nodeCounts = try XCTUnwrap(status["node_counts"]?.objectValue)
        XCTAssertEqual(nodeCounts["completed"]?.intValue, 1)
        XCTAssertEqual(nodeCounts["pending"]?.intValue, 1)
        let nodes = try XCTUnwrap(status["nodes"]?.arrayValue)
        let review = try XCTUnwrap(nodes.first { element in
            element.objectValue?["id"]?.stringValue == reviewNodeID.uuidString
        }?.objectValue)
        XCTAssertEqual(review["dependencies_satisfied"]?.boolValue, true)
        XCTAssertEqual(review["workstream_title"]?.stringValue, "Implement")
        XCTAssertEqual(review["workflow_name"]?.stringValue, "Review")
        XCTAssertEqual(review["completion_evidence"]?.stringValue, "Review reports no must-fix issues.")
        let recentEvents = try XCTUnwrap(status["recent_events"]?.arrayValue)
        XCTAssertEqual(recentEvents.first?.objectValue?["kind"]?.stringValue, "node_completed")
    }

    func testMissionPlanRejectsInvalidWorktreeStrategy() async throws {
        let coordinatorID = UUID()
        let service = makeService(coordinatorIDs: [coordinatorID], selectedID: coordinatorID)

        let args: [String: Value] = [
            "op": .string("mission_plan"),
            "workstreams": .array([
                .object([
                    "title": .string("Docs implementation"),
                    "purpose": .string("Apply the README wording change."),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object([
                        "mode": .string("maybeLater")
                    ])
                ])
            ])
        ]

        do {
            _ = try await service.execute(args: args)
            XCTFail("Expected invalid worktree strategy to be rejected.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("workstreams[].worktree_strategy.mode"))
        }
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

    func testCoordinatorChatIsAvailableToDirectClientsAndCoordinatorRole() {
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.coordinatorChat,
            taskLabelKind: nil
        ))
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.coordinatorChat,
            taskLabelKind: .coordinator
        ))
        for role in AgentModelCatalog.TaskLabelKind.allCases {
            guard role != .coordinator else { continue }
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
        submitPendingChild: @escaping (CoordinatorModeViewModel.ChildInteractionResponseSubmission, CoordinatorModeRow) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted },
        missionPlans: @escaping () -> [UUID: CoordinatorMissionPlan] = { [:] },
        updateMissionPlan: @escaping (UUID, CoordinatorMissionPlanUpdate) throws -> Void = { _, _ in }
    ) -> CoordinatorChatMCPToolService {
        makeService(
            coordinatorIDs: coordinatorIDs,
            selectedID: { selectedID },
            startNew: startNew,
            submit: submit,
            pendingChild: pendingChild,
            submitPendingChild: submitPendingChild,
            missionPlans: missionPlans,
            updateMissionPlan: updateMissionPlan
        )
    }

    private func makeService(
        coordinatorIDs: [UUID],
        selectedID: @escaping () -> UUID,
        select: @escaping (UUID?) -> Void = { _ in },
        startNew: @escaping () -> Void = {},
        submit: @escaping (String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted },
        pendingChild: @escaping () -> CoordinatorModeRow? = { nil },
        submitPendingChild: @escaping (CoordinatorModeViewModel.ChildInteractionResponseSubmission, CoordinatorModeRow) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted },
        missionPlans: @escaping () -> [UUID: CoordinatorMissionPlan] = { [:] },
        updateMissionPlan: @escaping (UUID, CoordinatorMissionPlanUpdate) throws -> Void = { _, _ in }
    ) -> CoordinatorChatMCPToolService {
        CoordinatorChatMCPToolService(toolName: MCPWindowToolName.coordinatorChat) {
            CoordinatorChatMCPToolService.Environment(
                snapshot: {
                    Self.snapshot(
                        coordinatorIDs: coordinatorIDs,
                        selectedID: selectedID(),
                        missionPlans: missionPlans()
                    )
                },
                refresh: {},
                selectCoordinator: select,
                startNewCoordinatorRun: startNew,
                submitDirective: submit,
                activePendingChildInteractionRow: pendingChild,
                submitPendingChildInteractionResponse: submitPendingChild,
                updateMissionPlan: updateMissionPlan
            )
        }
    }

    private static func snapshot(
        coordinatorIDs: [UUID],
        selectedID: UUID,
        missionPlans: [UUID: CoordinatorMissionPlan] = [:]
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
                missionTemplate: nil,
                missionPlan: missionPlans[id],
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
                missionTemplate: nil,
                missionPlan: missionPlans[selectedID],
                pendingInteraction: nil,
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
