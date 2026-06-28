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

    func testStartMissionStartsFreshCoordinatorAndSubmitsInitialDirective() async throws {
        let coordinatorID = UUID()
        let predecessorID = UUID()
        var events: [String] = []
        var missionPlans: [UUID: CoordinatorMissionPlan] = [:]
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            startNew: {
                events.append("start_new")
            },
            submit: { message in
                events.append("submit:\(message)")
                return .accepted
            },
            pendingChild: {
                XCTFail("start_mission should not route to an existing pending child interaction")
                return Self.pendingChildRow(parentCoordinatorID: coordinatorID)
            },
            missionPlans: { missionPlans },
            updateMissionPlan: { sessionID, update in
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                state.updateMissionPlan(update)
                missionPlans[sessionID] = state.missionPlan
            }
        )

        let response = try await service.execute(args: [
            "op": .string("start_mission"),
            "message": .string("Plan the next safe repo change."),
            "predecessor_mission_id": .string(predecessorID.uuidString),
            "predecessor_title": .string("PR #6 Tooling UX"),
            "predecessor_summary": .string("Doctor UX discovery found missing prerequisite guidance.")
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(events, [
            "start_new",
            "submit:Plan the next safe repo change."
        ])
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["started_new_mission"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator")
        let plan = try XCTUnwrap(object["mission_plan"]?.objectValue)
        XCTAssertEqual(plan["predecessor_mission_id"]?.stringValue, predecessorID.uuidString)
        XCTAssertEqual(plan["predecessor_title"]?.stringValue, "PR #6 Tooling UX")
        XCTAssertEqual(plan["predecessor_summary"]?.stringValue, "Doctor UX discovery found missing prerequisite guidance.")
    }

    func testSubmitDefaultsToCompactResponseForExternalDrivers() async throws {
        let coordinatorID = UUID()
        var submittedMessages: [String] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submit: {
                submittedMessages.append($0)
                return .accepted
            }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "message": .string("Continue to the next safe step.")
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(submittedMessages, ["Continue to the next safe step."])
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator")
        XCTAssertNil(object["mission_plan"])
        XCTAssertNil(object["coordinators"])
        XCTAssertEqual(object["coordinator_count"]?.intValue, 1)
    }

    func testSubmitCanReturnFullStateWhenCompactFalse() async throws {
        let coordinatorID = UUID()
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submit: { _ in .accepted }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "message": .string("Continue to the next safe step."),
            "compact": .bool(false)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertNotNil(object["mission_plan"])
        XCTAssertNotNil(object["coordinators"])
        XCTAssertNil(object["coordinator_count"])
    }

    func testStartMissionRejectsCoordinatorRuntimeCaller() async throws {
        let coordinatorID = UUID()
        var didStartNew = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .coordinator,
                    isCoordinatorRuntime: true
                )
            },
            startNew: {
                didStartNew = true
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("start_mission"),
                "message": .string("Start another mission.")
            ])
            XCTFail("Coordinator runtime callers must not be allowed to create peer Missions.")
        } catch {
            XCTAssertFalse(didStartNew)
            XCTAssertTrue(String(describing: error).contains("cannot create other Coordinator Missions"))
        }
    }

    func testStartMissionRejectsAgentModeWorkerCaller() async throws {
        let coordinatorID = UUID()
        var didStartNew = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex-worker",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .pair
                )
            },
            startNew: {
                didStartNew = true
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("start_mission"),
                "message": .string("Start a worker-created mission.")
            ])
            XCTFail("Agent Mode workers must not be allowed to create Coordinator Missions.")
        } catch {
            XCTAssertFalse(didStartNew)
            XCTAssertTrue(String(describing: error).contains("cannot create other Coordinator Missions"))
            XCTAssertTrue(String(describing: error).contains("external user or CLI driver"))
        }
    }

    func testEnsureMissionSelectsExistingMissionByKey() async throws {
        let firstID = UUID()
        let secondID = UUID()
        var selectedID = firstID
        var didStartNew = false
        let existingPlan = CoordinatorMissionPlan(
            missionKey: "homelab-garden:pr6-doctor",
            objective: "Existing PR #6 Mission",
            status: .draft
        )
        let service = makeService(
            coordinatorIDs: [firstID, secondID],
            selectedID: { selectedID },
            select: { selectedID = $0 ?? firstID },
            startNew: {
                didStartNew = true
            },
            missionPlans: {
                [secondID: existingPlan]
            }
        )

        let response = try await service.execute(args: [
            "op": .string("ensure_mission"),
            "mission_key": .string("homelab-garden:pr6-doctor"),
            "message": .string("Retry-safe start.")
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(selectedID, secondID)
        XCTAssertFalse(didStartNew)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["started_new_mission"]?.boolValue, false)
        XCTAssertEqual(object["selected_existing_mission"]?.boolValue, true)
        XCTAssertEqual(object["mission_key"]?.stringValue, "homelab-garden:pr6-doctor")
    }

    func testStopMissionSelectsRequestedCoordinatorAndStopsIt() async throws {
        let firstID = UUID()
        let secondID = UUID()
        var selectedID = firstID
        var stoppedSelection: UUID?
        let service = makeService(
            coordinatorIDs: [firstID, secondID],
            selectedID: { selectedID },
            select: { selectedID = $0 ?? firstID },
            stopMission: {
                stoppedSelection = selectedID
                return .accepted
            }
        )

        let response = try await service.execute(args: [
            "op": .string("stop_mission"),
            "coordinator_session_id": .string(secondID.uuidString)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(selectedID, secondID)
        XCTAssertEqual(stoppedSelection, secondID)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator_stop")
        XCTAssertEqual(object["selected_coordinator_session_id"]?.stringValue, secondID.uuidString)
    }

    func testMissionPlanUpdatesStateWithoutSubmittingChatTurn() async throws {
        let coordinatorID = UUID()
        let childID = UUID()
        let predecessorID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
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
                    predecessorMissionID: update.predecessorMissionID,
                    predecessorTitle: update.predecessorTitle,
                    predecessorSummary: update.predecessorSummary,
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
            "predecessor_mission_id": .string(predecessorID.uuidString),
            "predecessor_title": .string("PR #5 Contract Fixtures"),
            "predecessor_summary": .string("Contract fixture work established negative testdata conventions."),
            "workstreams": .array([
                .object([
                    "title": .string("Docs implementation"),
                    "purpose": .string("Apply the README wording change."),
                    "role": .string("Implement"),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object([
                        "mode": .string("createIsolated"),
                        "worktree_id": .string("wt-docs"),
                        "base_ref": .string("master"),
                        "base_reason": .string("Issue-style work should start from this repository's default branch."),
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
        XCTAssertEqual(plan["predecessor_mission_id"]?.stringValue, "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        XCTAssertEqual(plan["predecessor_title"]?.stringValue, "PR #5 Contract Fixtures")
        XCTAssertEqual(plan["predecessor_summary"]?.stringValue, "Contract fixture work established negative testdata conventions.")
        XCTAssertEqual(plan["revision"]?.intValue, 1)
        let workstream = try XCTUnwrap(plan["workstreams"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(workstream["title"]?.stringValue, "Docs implementation")
        XCTAssertEqual(workstream["default_policy"]?.stringValue, "fresh_worktree")
        let strategy = try XCTUnwrap(workstream["worktree_strategy"]?.objectValue)
        XCTAssertEqual(strategy["mode"]?.stringValue, "createIsolated")
        XCTAssertEqual(strategy["display_name"]?.stringValue, "New isolated worktree")
        XCTAssertEqual(strategy["worktree_id"]?.stringValue, "wt-docs")
        XCTAssertEqual(strategy["base_ref"]?.stringValue, "master")
        XCTAssertEqual(strategy["base_reason"]?.stringValue, "Issue-style work should start from this repository's default branch.")
        XCTAssertEqual(workstream["primary_session_id"]?.stringValue, childID.uuidString)
    }

    func testMissionPlanPreservesWorktreeBaseOnPartialStrategyUpdate() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
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
            "workstreams": .array([
                .object([
                    "id": .string(workstreamID.uuidString),
                    "title": .string("Implementation"),
                    "purpose": .string("Apply the issue fix."),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object([
                        "mode": .string("createIsolated"),
                        "base_ref": .string("master"),
                        "base_reason": .string("Issue implementation starts from this repository's default branch.")
                    ])
                ])
            ])
        ])

        let response = try await service.execute(args: [
            "op": .string("mission_plan"),
            "workstreams": .array([
                .object([
                    "id": .string(workstreamID.uuidString),
                    "title": .string("Implementation"),
                    "purpose": .string("Apply the issue fix."),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object([
                        "mode": .string("createIsolated"),
                        "worktree_id": .string("wt-issue")
                    ])
                ])
            ])
        ])

        let plan = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue)
        let workstream = try XCTUnwrap(plan["workstreams"]?.arrayValue?.first?.objectValue)
        let strategy = try XCTUnwrap(workstream["worktree_strategy"]?.objectValue)
        XCTAssertEqual(strategy["worktree_id"]?.stringValue, "wt-issue")
        XCTAssertEqual(strategy["base_ref"]?.stringValue, "master")
        XCTAssertEqual(strategy["base_reason"]?.stringValue, "Issue implementation starts from this repository's default branch.")
    }

    func testMissionPlanCanReplaceWorkstreamsAndNodes() async throws {
        let coordinatorID = UUID()
        let staleWorkstreamID = UUID()
        let replacementWorkstreamID = UUID()
        let replacementNodeID = UUID()
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
            "objective": .string("Ship next PR"),
            "workstreams": .array([
                .object([
                    "id": .string(staleWorkstreamID.uuidString),
                    "title": .string("Old platform smoke"),
                    "purpose": .string("No longer part of this PR."),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object([
                        "mode": .string("createIsolated")
                    ])
                ])
            ]),
            "nodes": .array([
                .object([
                    "title": .string("Old platform smoke node"),
                    "workstream_id": .string(staleWorkstreamID.uuidString),
                    "execution_policy": .string("fresh_worktree"),
                    "status": .string("blocked")
                ])
            ])
        ])

        let response = try await service.execute(args: [
            "op": .string("mission_plan"),
            "replace_workstreams": .bool(true),
            "replace_nodes": .bool(true),
            "workstreams": .array([
                .object([
                    "id": .string(replacementWorkstreamID.uuidString),
                    "title": .string("Developer UX"),
                    "purpose": .string("Add prerequisites and doctor checks."),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object([
                        "mode": .string("createIsolated")
                    ])
                ])
            ]),
            "nodes": .array([
                .object([
                    "id": .string(replacementNodeID.uuidString),
                    "title": .string("Add doctor prerequisite checks"),
                    "workstream_id": .string(replacementWorkstreamID.uuidString),
                    "execution_policy": .string("fresh_worktree"),
                    "status": .string("pending")
                ])
            ])
        ])

        let plan = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue)
        let workstreams = try XCTUnwrap(plan["workstreams"]?.arrayValue)
        let nodes = try XCTUnwrap(plan["nodes"]?.arrayValue)
        XCTAssertEqual(workstreams.count, 1)
        XCTAssertEqual(workstreams.first?.objectValue?["title"]?.stringValue, "Developer UX")
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.objectValue?["id"]?.stringValue, replacementNodeID.uuidString)
        XCTAssertEqual(nodes.first?.objectValue?["title"]?.stringValue, "Add doctor prerequisite checks")
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

    func testMissionPlanAcceptsRoutingDecisionsAndUpsertsByID() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let decisionID = UUID()
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
            "objective": .string("Issue 298 provider cleanup"),
            "workstreams": .array([
                .object([
                    "id": .string(workstreamID.uuidString),
                    "title": .string("Discovery"),
                    "purpose": .string("Map cleanup paths."),
                    "default_policy": .string("fresh_readonly_child"),
                    "worktree_strategy": .object(["mode": .string("noneReadOnly")])
                ])
            ]),
            "nodes": .array([
                .object([
                    "id": .string(nodeID.uuidString),
                    "title": .string("Map provider cleanup entry points"),
                    "workstream_id": .string(workstreamID.uuidString),
                    "execution_policy": .string("fresh_readonly_child")
                ])
            ]),
            "routing_decisions": .array([
                .object([
                    "id": .string(decisionID.uuidString),
                    "timestamp": .string("2026-06-25T10:00:00Z"),
                    "node_title": .string("Map provider cleanup entry points"),
                    "workstream_title": .string("Discovery"),
                    "decision": .string("start_fresh_readonly_child"),
                    "operation": .string("agent_explore.start"),
                    "session_id": .string(childID.uuidString),
                    "model_id": .string("explore"),
                    "role": .string("explore"),
                    "reason": .string("The implementation surface is unknown, so start a narrow read-only probe first."),
                    "context_summary": .string("Need to map MCP session cleanup, provider metadata, and Oracle finalization.")
                ]),
                .object([
                    "decision": .string("hold_for_user"),
                    "operation": .string("coordinator_hold"),
                    "reason": .string("User must approve commit, push, PR creation, and merge.")
                ])
            ])
        ])

        let plan = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue)
        let decisions = try XCTUnwrap(plan["routing_decisions"]?.arrayValue)
        XCTAssertEqual(decisions.count, 2)
        let decision = try XCTUnwrap(decisions.first?.objectValue)
        XCTAssertEqual(decision["id"]?.stringValue, decisionID.uuidString)
        XCTAssertEqual(decision["node_id"]?.stringValue, nodeID.uuidString)
        XCTAssertEqual(decision["workstream_id"]?.stringValue, workstreamID.uuidString)
        XCTAssertEqual(decision["decision"]?.stringValue, "start_fresh_readonly_child")
        XCTAssertEqual(decision["operation"]?.stringValue, "agent_explore.start")
        XCTAssertEqual(decision["session_id"]?.stringValue, childID.uuidString)
        XCTAssertEqual(decision["model_id"]?.stringValue, "explore")
        XCTAssertNil(decision["workflow_name"]?.stringValue)
        XCTAssertEqual(decisions.last?.objectValue?["operation"]?.stringValue, "coordinator_hold")

        let updated = try await service.execute(args: [
            "op": .string("mission_plan"),
            "routing_decisions": .array([
                .object([
                    "id": .string(decisionID.uuidString),
                    "timestamp": .string("2026-06-25T10:00:00Z"),
                    "decision": .string("start_fresh_readonly_child"),
                    "operation": .string("agent_explore.start"),
                    "reason": .string("Corrected route rationale.")
                ])
            ])
        ])
        let updatedDecisions = try XCTUnwrap(updated.objectValue?["mission_plan"]?.objectValue?["routing_decisions"]?.arrayValue)
        XCTAssertEqual(updatedDecisions.count, 2)
        XCTAssertEqual(updatedDecisions.first?.objectValue?["reason"]?.stringValue, "Corrected route rationale.")
        XCTAssertEqual(updatedDecisions.last?.objectValue?["operation"]?.stringValue, "coordinator_hold")
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
        let reviewSessionID = UUID()
        let routingDecisions = (0 ..< 25).map { index in
            CoordinatorMissionRoutingDecision(
                id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index))")!,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                nodeID: reviewNodeID,
                workstreamID: workstreamID,
                decision: .steerPrimary,
                operation: .agentRunSteer,
                modelID: "engineer",
                reason: "Decision \(index)."
            )
        }
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
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .createIsolated,
                        baseRef: "main",
                        baseReason: "Issue implementation starts from the repository default branch."
                    )
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
                    status: .pending,
                    boundSessionID: reviewSessionID
                )
            ],
            routingDecisions: routingDecisions,
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
            rows: [
                Self.childRow(
                    id: reviewSessionID,
                    parentCoordinatorID: coordinatorID,
                    title: "Review implementation",
                    workflow: CoordinatorModeWorkflowDisplaySummary(AgentWorkflow.review.definition)
                )
            ],
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
        XCTAssertEqual(review["planned_workflow"]?.objectValue?["name"]?.stringValue, "Review")
        XCTAssertEqual(review["actual_workflow"]?.objectValue?["name"]?.stringValue, "Review")
        XCTAssertEqual(review["workflow_matches_plan"]?.boolValue, true)
        XCTAssertEqual(review["bound_row"]?.objectValue?["workflow_name"]?.stringValue, "Review")
        let recentEvents = try XCTUnwrap(status["recent_events"]?.arrayValue)
        XCTAssertEqual(recentEvents.first?.objectValue?["kind"]?.stringValue, "node_completed")
        let recentRouting = try XCTUnwrap(status["routing_decisions_recent"]?.arrayValue)
        XCTAssertEqual(recentRouting.count, 20)
        XCTAssertEqual(recentRouting.first?.objectValue?["reason"]?.stringValue, "Decision 24.")
        XCTAssertEqual(recentRouting.last?.objectValue?["reason"]?.stringValue, "Decision 5.")
        XCTAssertNil(status["routing_decisions_recent"]?.arrayValue?.first?.objectValue?["context_summary"]?.stringValue)
    }

    func testMissionStatusCompactReturnsPollingSummaryAndLivenessWarnings() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let plan = CoordinatorMissionPlan(
            revision: 2,
            objective: "Ship provider cleanup",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Implementation",
                    purpose: "Apply provider cleanup.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .createIsolated,
                        baseRef: "main",
                        baseReason: "Issue implementation starts from the repository default branch."
                    )
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Implement provider cleanup",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .running
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .completed,
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ])
        let object = try XCTUnwrap(response.objectValue)
        let status = try XCTUnwrap(object["mission_status"]?.objectValue)

        XCTAssertNil(object["mission_plan"])
        XCTAssertNil(object["coordinators"])
        XCTAssertEqual(status["compact"]?.boolValue, true)
        XCTAssertNotNil(status["fingerprint"]?.stringValue)
        XCTAssertEqual(status["run_state"]?.stringValue, "completed")
        XCTAssertEqual(status["plan"]?.objectValue?["status"]?.stringValue, "running")
        let workstream = try XCTUnwrap(status["workstreams"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(workstream["base_ref"]?.stringValue, "main")
        XCTAssertEqual(status["active_nodes"]?.arrayValue?.count, 1)
        XCTAssertEqual(status["running_delegated_nodes_without_bound_sessions"]?.arrayValue?.count, 1)
        let warnings = try XCTUnwrap(status["liveness_warnings"]?.arrayValue?.compactMap(\.stringValue))
        XCTAssertTrue(warnings.contains("coordinator_run_state_is_not_active_but_plan_has_active_nodes"))
        XCTAssertTrue(warnings.contains("plan_is_running_but_coordinator_run_state_is_not_active"))
        XCTAssertTrue(warnings.contains("running_delegated_nodes_without_bound_sessions"))
    }

    func testMissionStatusCompactIncludesPlanApprovalCheckpointActions() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Plan the next PR",
            status: .draft,
            approvalState: .awaitingApproval,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Planning",
                    purpose: "Choose the next safe slice.",
                    defaultPolicy: .coordinatorOnly,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Choose next PR scope",
                    workstreamID: workstreamID,
                    executionPolicy: .coordinatorOnly,
                    status: .pending
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ])
        let status = try XCTUnwrap(response.objectValue?["mission_status"]?.objectValue)
        let checkpoint = try XCTUnwrap(status["checkpoint"]?.objectValue)
        let actions = try XCTUnwrap(checkpoint["actions"]?.arrayValue?.compactMap(\.objectValue))
        let labels = actions.compactMap { $0["label"]?.stringValue }

        XCTAssertEqual(checkpoint["kind"]?.stringValue, "plan_approval")
        XCTAssertTrue(labels.contains("Proceed"))
        XCTAssertTrue(labels.contains("Gather evidence"))
        XCTAssertTrue(labels.contains("Get independent critique"))
        let proceed = try XCTUnwrap(actions.first { $0["label"]?.stringValue == "Proceed" })
        XCTAssertEqual(proceed["submit_op"]?.stringValue, "submit")
        XCTAssertTrue(proceed["submit_message"]?.stringValue?.contains("Approved to proceed") == true)
    }

    func testMissionStatusCompactFlagsFreshSessionDriftAfterPrimaryExists() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let primarySessionID = UUID()
        let extraSessionID = UUID()
        let firstNodeID = UUID()
        let secondNodeID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Ship implementation",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Implementation",
                    purpose: "Implement the change.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .createIsolated,
                        worktreeID: "wt-implementation"
                    ),
                    primarySessionID: primarySessionID
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: firstNodeID,
                    title: "Initial implementation",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .running,
                    boundSessionID: primarySessionID
                ),
                CoordinatorMissionPlanNode(
                    id: secondNodeID,
                    title: "Follow-up implementation",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .running,
                    boundSessionID: extraSessionID
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            rows: [
                Self.childRow(
                    id: primarySessionID,
                    parentCoordinatorID: coordinatorID,
                    title: "Primary implementation",
                    workflow: CoordinatorModeWorkflowDisplaySummary(AgentWorkflow.orchestrate.definition)
                ),
                Self.childRow(
                    id: extraSessionID,
                    parentCoordinatorID: coordinatorID,
                    title: "Extra implementation",
                    workflow: CoordinatorModeWorkflowDisplaySummary(AgentWorkflow.orchestrate.definition)
                )
            ],
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ])
        let status = try XCTUnwrap(response.objectValue?["mission_status"]?.objectValue)
        let workstream = try XCTUnwrap(status["workstreams"]?.arrayValue?.first?.objectValue)
        let warnings = try XCTUnwrap(status["liveness_warnings"]?.arrayValue?.compactMap(\.stringValue))

        XCTAssertEqual(workstream["primary_session_id"]?.stringValue, primarySessionID.uuidString)
        XCTAssertEqual(workstream["primary_session_state"]?.stringValue, "running")
        XCTAssertEqual(workstream["worktree_id"]?.stringValue, "wt-implementation")
        XCTAssertEqual(workstream["next_recommended_route"]?.stringValue, "steer_primary")
        XCTAssertTrue(warnings.contains("workstream_has_multiple_fresh_sessions"))
        XCTAssertTrue(warnings.contains("node_should_steer_primary_but_started_fresh"))
        XCTAssertTrue(warnings.contains("task_aware_child_missing_worktree_binding"))
    }

    func testWaitForUpdateReturnsImmediatelyWithoutPriorFingerprint() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Watch mission",
            status: .running,
            approvalState: .approved
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("wait_for_update"),
            "timeout_seconds": .int(0)
        ])
        let object = try XCTUnwrap(response.objectValue)
        let status = try XCTUnwrap(object["mission_status"]?.objectValue)

        XCTAssertEqual(object["changed"]?.boolValue, true)
        XCTAssertEqual(object["timed_out"]?.boolValue, false)
        XCTAssertEqual(status["compact"]?.boolValue, true)
        XCTAssertNotNil(status["fingerprint"]?.stringValue)
    }

    func testWaitForUpdateTimesOutWhenFingerprintIsUnchanged() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Watch mission",
            status: .running,
            approvalState: .approved
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        let initial = try await service.execute(args: [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ])
        let fingerprint = try XCTUnwrap(initial.objectValue?["mission_status"]?.objectValue?["fingerprint"]?.stringValue)
        let response = try await service.execute(args: [
            "op": .string("wait_for_update"),
            "since_fingerprint": .string(fingerprint),
            "timeout_seconds": .int(0)
        ])
        let object = try XCTUnwrap(response.objectValue)
        let status = try XCTUnwrap(object["mission_status"]?.objectValue)

        XCTAssertEqual(object["changed"]?.boolValue, false)
        XCTAssertEqual(object["timed_out"]?.boolValue, true)
        XCTAssertEqual(status["fingerprint"]?.stringValue, fingerprint)
    }

    func testCompactMissionStatusFingerprintChangesForGrandchildFleetMotion() async throws {
        let coordinatorID = UUID()
        let workerID = UUID()
        let helperID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Watch mission fleet",
            status: .running,
            approvalState: .approved
        )

        let workerRow = Self.childRow(
            id: workerID,
            parentCoordinatorID: coordinatorID,
            title: "Primary worker",
            workflow: nil
        )
        let runningHelperRow = Self.childRow(
            id: helperID,
            parentCoordinatorID: coordinatorID,
            title: "Worker helper",
            parentSessionID: workerID,
            runState: .running,
            statusGroup: .working,
            workflow: nil
        )
        let completedHelperRow = Self.childRow(
            id: helperID,
            parentCoordinatorID: coordinatorID,
            title: "Worker helper",
            parentSessionID: workerID,
            runState: .completed,
            statusGroup: .done,
            workflow: nil
        )

        let runningService = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            rows: [workerRow, runningHelperRow],
            missionPlans: { [coordinatorID: plan] }
        )
        let completedService = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            rows: [workerRow, completedHelperRow],
            missionPlans: { [coordinatorID: plan] }
        )

        let compactStatusArgs: [String: Value] = [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ]
        let runningResponse = try await runningService.execute(args: compactStatusArgs)
        let completedResponse = try await completedService.execute(args: compactStatusArgs)
        let runningFingerprint = try XCTUnwrap(
            runningResponse.objectValue?["mission_status"]?.objectValue?["fingerprint"]?.stringValue
        )
        let completedFingerprint = try XCTUnwrap(
            completedResponse.objectValue?["mission_status"]?.objectValue?["fingerprint"]?.stringValue
        )

        XCTAssertNotEqual(runningFingerprint, completedFingerprint)
    }

    func testCompactMissionStatusFingerprintChangesForFleetCountMotion() async throws {
        let coordinatorID = UUID()
        let workerID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Watch mission fleet counts",
            status: .running,
            approvalState: .approved
        )
        let workerRow = Self.childRow(
            id: workerID,
            parentCoordinatorID: coordinatorID,
            title: "Primary worker",
            workflow: nil
        )
        let liveCounts = CoordinatorModeCounts(
            totalRows: 3,
            needsYou: 0,
            blocked: 0,
            working: 2,
            review: 0,
            done: 1,
            stalePersistedOnly: 0,
            liveRows: 3
        )
        let staleCounts = CoordinatorModeCounts(
            totalRows: 3,
            needsYou: 0,
            blocked: 0,
            working: 1,
            review: 0,
            done: 1,
            stalePersistedOnly: 1,
            liveRows: 2
        )
        let liveService = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            counts: liveCounts,
            rows: [workerRow],
            missionPlans: { [coordinatorID: plan] }
        )
        let staleService = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            counts: staleCounts,
            rows: [workerRow],
            missionPlans: { [coordinatorID: plan] }
        )

        let compactStatusArgs: [String: Value] = [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ]
        let liveResponse = try await liveService.execute(args: compactStatusArgs)
        let staleResponse = try await staleService.execute(args: compactStatusArgs)
        let liveFingerprint = try XCTUnwrap(
            liveResponse.objectValue?["mission_status"]?.objectValue?["fingerprint"]?.stringValue
        )
        let staleFingerprint = try XCTUnwrap(
            staleResponse.objectValue?["mission_status"]?.objectValue?["fingerprint"]?.stringValue
        )

        XCTAssertNotEqual(liveFingerprint, staleFingerprint)
    }

    func testMissionStatusFlagsBoundWorkflowMismatch() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Investigate cleanup behavior",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Discovery",
                    purpose: "Map provider cleanup paths.",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Investigate provider cleanup paths",
                    workflowHint: CoordinatorMissionPlanNodeWorkflowHint(
                        id: AgentWorkflow.investigate.definition.id,
                        name: "Investigate"
                    ),
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: childID
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            rows: [
                Self.childRow(
                    id: childID,
                    parentCoordinatorID: coordinatorID,
                    title: "Explore cleanup paths",
                    workflow: nil
                )
            ],
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("mission_status")
        ])
        let status = try XCTUnwrap(response.objectValue?["mission_status"]?.objectValue)
        let node = try XCTUnwrap(status["nodes"]?.arrayValue?.first?.objectValue)

        XCTAssertEqual(node["planned_workflow"]?.objectValue?["name"]?.stringValue, "Investigate")
        XCTAssertEqual(node["actual_workflow"], .null)
        XCTAssertEqual(node["workflow_matches_plan"]?.boolValue, false)
        XCTAssertNil(node["bound_row"]?.objectValue?["workflow_name"]?.stringValue)
    }

    func testMissionStatusDoesNotFlagWorkflowlessProbeNodeAsMismatch() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Map cleanup behavior",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Discovery",
                    purpose: "Map provider cleanup paths.",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Probe provider cleanup entry points",
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: childID
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            rows: [
                Self.childRow(
                    id: childID,
                    parentCoordinatorID: coordinatorID,
                    title: "Explore cleanup paths",
                    workflow: nil
                )
            ],
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("mission_status")
        ])
        let status = try XCTUnwrap(response.objectValue?["mission_status"]?.objectValue)
        let node = try XCTUnwrap(status["nodes"]?.arrayValue?.first?.objectValue)

        XCTAssertEqual(node["planned_workflow"], .null)
        XCTAssertEqual(node["actual_workflow"], .null)
        XCTAssertEqual(node["workflow_matches_plan"], .null)
        XCTAssertNil(node["bound_row"]?.objectValue?["workflow_name"]?.stringValue)
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
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.agentExplore,
            taskLabelKind: .coordinator
        ))
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.agentRun,
            taskLabelKind: .coordinator
        ))
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.agentManage,
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

    func testAllowedWorkerAdvertisesAgentRunButNotCoordinatorChat() {
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.agentRun,
            taskLabelKind: .pair,
            allowsAgentExternalControlTools: true
        ))
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.agentManage,
            taskLabelKind: .pair,
            allowsAgentExternalControlTools: true
        ))
        XCTAssertFalse(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.coordinatorChat,
            taskLabelKind: .pair,
            allowsAgentExternalControlTools: true
        ))
    }

    private func makeService(
        coordinatorIDs: [UUID],
        selectedID: UUID,
        captureRequestMetadata: @escaping () async -> MCPServerViewModel.RequestMetadata = {
            MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: nil, windowID: nil)
        },
        coordinatorRunState: AgentSessionRunState = .idle,
        startNew: @escaping () -> Void = {},
        stopMission: @escaping () async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { .accepted },
        submit: @escaping (String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted },
        pendingChild: @escaping () -> CoordinatorModeRow? = { nil },
        submitPendingChild: @escaping (CoordinatorModeViewModel.ChildInteractionResponseSubmission, CoordinatorModeRow) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted },
        counts: CoordinatorModeCounts = .empty,
        rows: [CoordinatorModeRow] = [],
        missionPlans: @escaping () -> [UUID: CoordinatorMissionPlan] = { [:] },
        updateMissionPlan: @escaping (UUID, CoordinatorMissionPlanUpdate) throws -> Void = { _, _ in }
    ) -> CoordinatorChatMCPToolService {
        makeService(
            coordinatorIDs: coordinatorIDs,
            selectedID: { selectedID },
            captureRequestMetadata: captureRequestMetadata,
            coordinatorRunState: coordinatorRunState,
            startNew: startNew,
            stopMission: stopMission,
            submit: submit,
            pendingChild: pendingChild,
            submitPendingChild: submitPendingChild,
            counts: counts,
            rows: rows,
            missionPlans: missionPlans,
            updateMissionPlan: updateMissionPlan
        )
    }

    private func makeService(
        coordinatorIDs: [UUID],
        selectedID: @escaping () -> UUID,
        captureRequestMetadata: @escaping () async -> MCPServerViewModel.RequestMetadata = {
            MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: nil, windowID: nil)
        },
        coordinatorRunState: AgentSessionRunState = .idle,
        select: @escaping (UUID?) -> Void = { _ in },
        startNew: @escaping () -> Void = {},
        stopMission: @escaping () async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { .accepted },
        submit: @escaping (String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted },
        pendingChild: @escaping () -> CoordinatorModeRow? = { nil },
        submitPendingChild: @escaping (CoordinatorModeViewModel.ChildInteractionResponseSubmission, CoordinatorModeRow) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted },
        counts: CoordinatorModeCounts = .empty,
        rows: [CoordinatorModeRow] = [],
        missionPlans: @escaping () -> [UUID: CoordinatorMissionPlan] = { [:] },
        updateMissionPlan: @escaping (UUID, CoordinatorMissionPlanUpdate) throws -> Void = { _, _ in }
    ) -> CoordinatorChatMCPToolService {
        CoordinatorChatMCPToolService(
            toolName: MCPWindowToolName.coordinatorChat,
            captureRequestMetadata: captureRequestMetadata
        ) {
            CoordinatorChatMCPToolService.Environment(
                snapshot: {
                    Self.snapshot(
                        coordinatorIDs: coordinatorIDs,
                        selectedID: selectedID(),
                        coordinatorRunState: coordinatorRunState,
                        counts: counts,
                        rows: rows,
                        missionPlans: missionPlans()
                    )
                },
                refresh: {},
                selectCoordinator: select,
                startNewCoordinatorRun: startNew,
                stopSelectedCoordinatorMission: stopMission,
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
        coordinatorRunState: AgentSessionRunState = .idle,
        counts: CoordinatorModeCounts = .empty,
        rows: [CoordinatorModeRow] = [],
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
                runState: coordinatorRunState,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                lastActivityAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }

        return CoordinatorModeSnapshot(
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            sortMode: .lastUpdated,
            boardScope: .coordinatorFleet,
            counts: counts,
            groups: CoordinatorModeStatusGroup.allCases.map { group in
                CoordinatorModeStatusSection(group: group, rows: rows.filter { $0.statusGroup == group })
            },
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

    private static func childRow(
        id: UUID,
        parentCoordinatorID: UUID,
        title: String,
        parentSessionID: UUID? = nil,
        runState: AgentSessionRunState = .running,
        statusGroup: CoordinatorModeStatusGroup = .working,
        workflow: CoordinatorModeWorkflowDisplaySummary?
    ) -> CoordinatorModeRow {
        CoordinatorModeRow(
            id: id,
            sessionID: id,
            tabID: UUID(),
            title: title,
            providerName: "codexExec",
            modelName: "gpt-5.5",
            runState: runState,
            statusGroup: statusGroup,
            parentSessionID: parentSessionID ?? parentCoordinatorID,
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
            workflow: workflow,
            mergeAttention: nil,
            pendingInteraction: nil,
            openAgentChatRoute: nil,
            statusReport: nil,
            origin: .coordinatorFleet
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
