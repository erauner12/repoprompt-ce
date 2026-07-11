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
        var requestedCoordinatorModels: [String?] = []
        var missionPlans: [UUID: CoordinatorMissionPlan] = [:]
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            startNew: { coordinatorModelID in
                events.append("start_new")
                requestedCoordinatorModels.append(coordinatorModelID)
            },
            submit: { message in
                events.append("submit:\(message)")
                return .accepted
            },
            pendingChild: { _ in
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
        XCTAssertEqual(requestedCoordinatorModels.count, 1)
        XCTAssertNil(requestedCoordinatorModels.first ?? nil)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["started_new_mission"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator")
        let plan = try XCTUnwrap(object["mission_plan"]?.objectValue)
        XCTAssertEqual(plan["predecessor_mission_id"]?.stringValue, predecessorID.uuidString)
        XCTAssertEqual(plan["predecessor_title"]?.stringValue, "PR #6 Tooling UX")
        XCTAssertEqual(plan["predecessor_summary"]?.stringValue, "Doctor UX discovery found missing prerequisite guidance.")
    }

    func testStartMissionPassesCoordinatorModelOverrideToFreshRuntime() async throws {
        let coordinatorID = UUID()
        var requestedCoordinatorModels: [String?] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            startNew: { coordinatorModelID in
                requestedCoordinatorModels.append(coordinatorModelID)
            }
        )

        let response = try await service.execute(args: [
            "op": .string("start_mission"),
            "message": .string("Run the cheap coordinator regression tier."),
            "coordinator_model_id": .string("engineer")
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(requestedCoordinatorModels.count, 1)
        XCTAssertEqual(requestedCoordinatorModels.first ?? nil, "engineer")
        XCTAssertEqual(object["coordinator_model_id"]?.stringValue, "engineer")
        XCTAssertEqual(object["started_new_mission"]?.boolValue, true)
    }

    func testSubmitNewParentPassesCoordinatorModelOverride() async throws {
        let coordinatorID = UUID()
        var requestedCoordinatorModels: [String?] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            startNew: { coordinatorModelID in
                requestedCoordinatorModels.append(coordinatorModelID)
            }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "new_parent": .bool(true),
            "message": .string("Start cheaper Coordinator parent."),
            "coordinator_model_id": .string("design"),
            "compact": .bool(true)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(requestedCoordinatorModels.count, 1)
        XCTAssertEqual(requestedCoordinatorModels.first ?? nil, "design")
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator")
    }

    func testStartMissionWaitsForInitialAwaitingApprovalPlan() async throws {
        let coordinatorID = UUID()
        let nodeID = UUID()
        var missionPlans: [UUID: CoordinatorMissionPlan] = [:]
        var sleepCalls = 0
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submit: { _ in .accepted },
            missionPlans: { missionPlans },
            initialMissionPlanTimeoutSeconds: 0.1,
            initialMissionPlanPollIntervalSeconds: 0.01,
            sleep: { _ in
                sleepCalls += 1
                missionPlans[coordinatorID] = CoordinatorMissionPlan(
                    objective: "Visible approval plan",
                    status: .draft,
                    approvalState: .awaitingApproval,
                    nodes: [
                        CoordinatorMissionPlanNode(
                            id: nodeID,
                            title: "Implement",
                            workstreamID: UUID(),
                            executionPolicy: .freshWorktree
                        )
                    ]
                )
            }
        )

        let response = try await service.execute(args: [
            "op": .string("start_mission"),
            "message": .string("Plan before running children.")
        ])
        let object = try XCTUnwrap(response.objectValue)
        let plan = try XCTUnwrap(object["mission_plan"]?.objectValue)

        XCTAssertGreaterThanOrEqual(sleepCalls, 1)
        XCTAssertEqual(plan["approval_state"]?.stringValue, "awaiting_approval")
        XCTAssertEqual(plan["nodes"]?.arrayValue?.count, 1)
        XCTAssertNil(object["initial_plan_visible"])
        XCTAssertNil(object["warning"])
    }

    func testStartMissionPublishesFallbackInitialPlanWhenRuntimePlanDoesNotAppear() async throws {
        let coordinatorID = UUID()
        var missionPlans: [UUID: CoordinatorMissionPlan] = [:]
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submit: { _ in .accepted },
            missionPlans: { missionPlans },
            updateMissionPlan: { sessionID, update in
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                state.updateMissionPlan(update)
                missionPlans[sessionID] = state.missionPlan
            },
            initialMissionPlanTimeoutSeconds: 0
        )

        let response = try await service.execute(args: [
            "op": .string("start_mission"),
            "message": .string("Plan before running children.")
        ])
        let object = try XCTUnwrap(response.objectValue)
        let plan = try XCTUnwrap(object["mission_plan"]?.objectValue)

        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["initial_plan_visible"]?.boolValue, true)
        XCTAssertEqual(object["initial_plan_fallback_published"]?.boolValue, true)
        XCTAssertNil(object["warning"])
        XCTAssertEqual(plan["approval_state"]?.stringValue, "awaiting_approval")
        XCTAssertEqual(plan["nodes"]?.arrayValue?.count, 1)
    }

    func testStartMissionTargetsFreshCoordinatorWhenPreviousSelectionExists() async throws {
        let existingID = UUID()
        let freshID = UUID()
        var coordinatorIDs = [existingID]
        var selectedID = existingID
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            existingID: CoordinatorMissionPlan(
                missionKey: "existing-mission",
                objective: "Already completed Mission.",
                status: .completed,
                approvalState: .approved
            )
        ]
        var updatedSessionIDs: [UUID] = []

        let service = CoordinatorChatMCPToolService(
            toolName: MCPWindowToolName.coordinatorChat,
            initialMissionPlanTimeoutSeconds: 0,
            initialMissionPlanPollIntervalSeconds: 0.01
        ) {
            CoordinatorChatMCPToolService.Environment(
                snapshot: {
                    Self.snapshot(
                        coordinatorIDs: coordinatorIDs,
                        selectedID: selectedID,
                        missionPlans: missionPlans
                    )
                },
                refresh: {},
                selectCoordinator: { sessionID in
                    selectedID = sessionID ?? existingID
                },
                startNewCoordinatorRun: { _ in
                    if !coordinatorIDs.contains(freshID) {
                        coordinatorIDs.append(freshID)
                    }
                },
                stopCoordinatorMission: { _ in .accepted },
                submitDirective: { _ in .accepted },
                acceptedRevisionDraftingResolutionID: {
                    missionPlans[$0]?.acceptedRevisionDraftingResolution?.id
                },
                holdsRevisionProposalAuthority: {
                    missionPlans[$0]?.holdsChildInteractionsForRevisionProposal == true
                },
                submitAcceptedRevisionDraftingDirective: { _, _, _ in .accepted },
                submitContinuation: { _, _ in .accepted },
                activePendingChildInteractionRow: { _ in nil },
                submitPendingChildInteractionResponse: { _, _, _ in .accepted },
                durableApprovalAuthorityToken: { missionPlans[$0]?.expectedDurableApprovalAuthorityToken },
                updateMissionPlan: { sessionID, update in
                    updatedSessionIDs.append(sessionID)
                    var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                    state.updateMissionPlan(update)
                    missionPlans[sessionID] = state.missionPlan
                },
                appendRevisionProposal: { _, _ in
                    throw MCPError.invalidParams("Revision proposals are unavailable in this test.")
                },
                resolveRevisionProposal: { _, _, _, _, _, _ in .accepted },
                missionEvents: { _, sinceSeq, _ in
                    CoordinatorMissionEventJournal.Batch(
                        events: [],
                        nextSeq: sinceSeq,
                        oldestSeq: nil,
                        latestSeq: nil,
                        truncated: false
                    )
                },
                setMissionPace: { _, _ in .accepted },
                setMissionAutonomy: { _, _, _ in .accepted },
                archiveMission: { _ in .accepted() }
            )
        }

        let response = try await service.execute(args: [
            "op": .string("start_mission"),
            "mission_key": .string("fresh-mission"),
            "message": .string("Start a fresh mission and publish the initial approval plan.")
        ])
        let object = try XCTUnwrap(response.objectValue)
        let plan = try XCTUnwrap(object["mission_plan"]?.objectValue)

        XCTAssertEqual(selectedID, freshID)
        XCTAssertEqual(object["selected_coordinator_session_id"]?.stringValue, freshID.uuidString)
        XCTAssertEqual(object["started_new_mission"]?.boolValue, true)
        XCTAssertEqual(plan["mission_key"]?.stringValue, "fresh-mission")
        XCTAssertEqual(plan["approval_state"]?.stringValue, "awaiting_approval")
        XCTAssertEqual(plan["nodes"]?.arrayValue?.count, 1)
        XCTAssertTrue(updatedSessionIDs.allSatisfy { $0 == freshID })
        XCTAssertEqual(missionPlans[existingID]?.missionKey, "existing-mission")
        XCTAssertEqual(missionPlans[freshID]?.missionKey, "fresh-mission")
    }

    func testStartMissionReportsInitialPlanTimeoutWhenFallbackCannotPublish() async throws {
        let coordinatorID = UUID()
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submit: { _ in .accepted },
            initialMissionPlanTimeoutSeconds: 0
        )

        let response = try await service.execute(args: [
            "op": .string("start_mission"),
            "message": .string("Plan before running children.")
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["initial_plan_visible"]?.boolValue, false)
        XCTAssertEqual(object["initial_plan_wait_timed_out"]?.boolValue, true)
        XCTAssertEqual(object["warning"]?.stringValue, "Timed out waiting for an awaiting-approval Mission Plan.")
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
            startNew: { _ in
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
            startNew: { _ in
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

    func testSubmitRejectsInternalNonOwnerWorkerBeforeSelectionOrUserDecision() async throws {
        let selectedID = UUID()
        let explicitID = UUID()
        var didSelect = false
        var didSubmit = false
        var didInspectPendingChild = false
        let service = makeService(
            coordinatorIDs: [selectedID, explicitID],
            selectedID: { selectedID },
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex-worker",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .pair
                )
            },
            select: { _ in didSelect = true },
            submit: { _ in
                didSubmit = true
                return .accepted
            },
            pendingChild: { _ in
                didInspectPendingChild = true
                return nil
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "coordinator_session_id": .string(explicitID.uuidString),
                "message": .string("Pretend to be the user.")
            ])
            XCTFail("Internal non-owner Agent Mode workers must not submit Coordinator user turns.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Internal non-owner Agent Mode workers cannot submit"), message)
            XCTAssertFalse(didSelect)
            XCTAssertFalse(didSubmit)
            XCTAssertFalse(didInspectPendingChild)
        }
    }

    func testSubmitRejectsHeadlessDiscoverRunBeforeSelectionOrUserDecision() async throws {
        let selectedID = UUID()
        let explicitID = UUID()
        var didSelect = false
        var didSubmit = false
        var didInspectPendingChild = false
        let service = makeService(
            coordinatorIDs: [selectedID, explicitID],
            selectedID: { selectedID },
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "context-builder",
                    windowID: 1,
                    runPurpose: .discoverRun,
                    taskLabelKind: nil
                )
            },
            select: { _ in didSelect = true },
            submit: { _ in
                didSubmit = true
                return .accepted
            },
            pendingChild: { _ in
                didInspectPendingChild = true
                return nil
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "coordinator_session_id": .string(explicitID.uuidString),
                "message": .string("Pretend to be the user from discovery.")
            ])
            XCTFail("Headless discoverRun callers must not submit Coordinator user turns.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Internal non-owner Agent Mode workers cannot submit"), message)
            XCTAssertFalse(didSelect)
            XCTAssertFalse(didSubmit)
            XCTAssertFalse(didInspectPendingChild)
        }
    }

    func testMissionPlanRejectsHeadlessDiscoverRunBeforeSelectedFallback() async throws {
        let selectedCoordinatorID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [selectedCoordinatorID],
            selectedID: selectedCoordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "context-builder",
                    windowID: 1,
                    runPurpose: .discoverRun,
                    taskLabelKind: nil
                )
            },
            missionPlans: {
                [selectedCoordinatorID: CoordinatorMissionPlan(
                    missionKey: "selected",
                    objective: "Selected Mission",
                    status: .running,
                    approvalState: .approved
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "objective": .string("Should not land from discovery")
            ])
            XCTFail("Headless discoverRun callers must not mutate selected Mission Plans.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Internal non-owner Agent Mode workers cannot mutate"), message)
            XCTAssertFalse(didUpdate)
        }
    }

    func testSetPaceRoutesThroughExternalUserActionPath() async throws {
        let coordinatorID = UUID()
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            coordinatorID: CoordinatorMissionPlan(
                objective: "Run a live Mission.",
                status: .running,
                approvalState: .approved,
                policySnapshot: .defaultPolicy,
                autonomy: CoordinatorMissionPolicySnapshot.defaultAutonomy
            )
        ]
        var setPaceCalls: [(UUID, CoordinatorMissionPolicyPace)] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            pendingChild: { _ in
                XCTFail("set_pace should not route through pending child interactions")
                return Self.pendingChildRow(parentCoordinatorID: coordinatorID)
            },
            missionPlans: { missionPlans },
            setMissionPace: { sessionID, pace in
                setPaceCalls.append((sessionID, pace))
                var policy = missionPlans[sessionID]?.policySnapshot ?? CoordinatorMissionPolicySnapshot.defaultPolicy
                policy.defaultPace = pace
                let record = CoordinatorMissionDecisionRecord(
                    userDecision: pace == .auto ? .setPaceToAuto : .setPaceToStep,
                    decisionClass: .advance,
                    checkpointInstanceID: "mission-policy:\(sessionID.uuidString):pace:test",
                    sessionID: sessionID,
                    checkpointID: "mission-policy-override"
                )
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                state.updateMissionPlan(CoordinatorMissionPlanUpdate(
                    policySnapshot: policy,
                    decisions: [record],
                    updatedAt: record.timestamp
                ))
                missionPlans[sessionID] = state.missionPlan
                return .accepted
            }
        )

        let response = try await service.execute(args: [
            "op": .string("set_pace"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "pace": .string("auto")
        ])
        let object = try XCTUnwrap(response.objectValue)
        let status = try XCTUnwrap(object["mission_status"]?.objectValue)
        let plan = try XCTUnwrap(status["plan"]?.objectValue)
        let policy = try XCTUnwrap(plan["policy_snapshot"]?.objectValue)

        XCTAssertEqual(setPaceCalls.count, 1)
        XCTAssertEqual(setPaceCalls.first?.0, coordinatorID)
        XCTAssertEqual(setPaceCalls.first?.1, .auto)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "set_pace")
        XCTAssertEqual(object["pace"]?.stringValue, "auto")
        XCTAssertEqual(policy["default_pace"]?.stringValue, "auto")
        XCTAssertEqual(status["decision_counts_by_actor"]?.objectValue?["user"]?.intValue, 1)
    }

    func testSetPaceRejectsCoordinatorRuntimeCaller() async throws {
        let coordinatorID = UUID()
        var didSetPace = false
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
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Runtime-gated Mission.",
                    status: .running,
                    approvalState: .approved,
                    policySnapshot: .defaultPolicy
                )]
            },
            setMissionPace: { _, _ in
                didSetPace = true
                return .accepted
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("set_pace"),
                "pace": .string("auto")
            ])
            XCTFail("Coordinator runtime callers must not be allowed to forge user-action parity.")
        } catch {
            XCTAssertFalse(didSetPace)
            XCTAssertTrue(String(describing: error).contains("cannot change Mission pace"))
            XCTAssertTrue(String(describing: error).contains("external user or CLI driver"))
        }
    }

    func testSetPaceRejectsUnknownPace() async throws {
        let coordinatorID = UUID()
        var didSetPace = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Invalid pace Mission.",
                    status: .running,
                    approvalState: .approved,
                    policySnapshot: .defaultPolicy
                )]
            },
            setMissionPace: { _, _ in
                didSetPace = true
                return .accepted
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("set_pace"),
                "pace": .string("turbo")
            ])
            XCTFail("Expected invalid pace to be rejected.")
        } catch {
            XCTAssertFalse(didSetPace)
            XCTAssertTrue(String(describing: error).contains("pace must be one of: step, auto"))
        }
    }

    func testSetAutonomyRoutesThroughExternalUserActionPath() async throws {
        let coordinatorID = UUID()
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            coordinatorID: CoordinatorMissionPlan(
                objective: "Run a live Mission.",
                status: .running,
                approvalState: .approved,
                policySnapshot: .defaultPolicy,
                autonomy: CoordinatorMissionPolicySnapshot.defaultAutonomy
            )
        ]
        var setAutonomyCalls: [(UUID, String, CoordinatorMissionAutonomyMode)] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            pendingChild: { _ in
                XCTFail("set_autonomy should not route through pending child interactions")
                return Self.pendingChildRow(parentCoordinatorID: coordinatorID)
            },
            missionPlans: { missionPlans },
            setMissionAutonomy: { sessionID, autonomyClassKey, mode in
                setAutonomyCalls.append((sessionID, autonomyClassKey, mode))
                var policy = missionPlans[sessionID]?.policySnapshot ?? CoordinatorMissionPolicySnapshot.defaultPolicy
                var autonomy = missionPlans[sessionID]?.autonomy ?? policy.autonomy
                policy.autonomy[autonomyClassKey] = mode
                autonomy[autonomyClassKey] = mode
                let record = CoordinatorMissionDecisionRecord(
                    userDecision: mode == .auto ? .routedChildQuestionsToDirector : .routedChildQuestionsToMe,
                    decisionClass: .childAsk,
                    checkpointInstanceID: "mission-policy:\(sessionID.uuidString):childAsk:test",
                    sessionID: sessionID,
                    checkpointID: "mission-policy-override"
                )
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                state.updateMissionPlan(CoordinatorMissionPlanUpdate(
                    policySnapshot: policy,
                    autonomy: autonomy,
                    decisions: [record],
                    updatedAt: record.timestamp
                ))
                missionPlans[sessionID] = state.missionPlan
                return .accepted
            }
        )

        let response = try await service.execute(args: [
            "op": .string("set_autonomy"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "autonomy_class": .string("childAsk"),
            "mode": .string("auto")
        ])
        let object = try XCTUnwrap(response.objectValue)
        let status = try XCTUnwrap(object["mission_status"]?.objectValue)
        let plan = try XCTUnwrap(status["plan"]?.objectValue)
        let policy = try XCTUnwrap(plan["policy_snapshot"]?.objectValue)
        let autonomySummary = try XCTUnwrap(plan["autonomy_summary"]?.objectValue)
        let autoClasses = try XCTUnwrap(autonomySummary["auto"]?.arrayValue)

        XCTAssertEqual(setAutonomyCalls.count, 1)
        XCTAssertEqual(setAutonomyCalls.first?.0, coordinatorID)
        XCTAssertEqual(setAutonomyCalls.first?.1, CoordinatorMissionAutonomyClasses.childAsk.key)
        XCTAssertEqual(setAutonomyCalls.first?.2, .auto)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "set_autonomy")
        XCTAssertEqual(object["autonomy_class"]?.stringValue, "childAsk")
        XCTAssertEqual(object["mode"]?.stringValue, "auto")
        XCTAssertTrue(autoClasses.contains(.string("childAsk")))
        XCTAssertEqual(status["decision_counts_by_actor"]?.objectValue?["user"]?.intValue, 1)
    }

    func testSetAutonomyRejectsCoordinatorRuntimeCaller() async throws {
        let coordinatorID = UUID()
        var didSetAutonomy = false
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
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Runtime-gated Mission.",
                    status: .running,
                    approvalState: .approved,
                    policySnapshot: .defaultPolicy
                )]
            },
            setMissionAutonomy: { _, _, _ in
                didSetAutonomy = true
                return .accepted
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("set_autonomy"),
                "autonomy_class": .string("childAsk"),
                "mode": .string("auto")
            ])
            XCTFail("Coordinator runtime callers must not be allowed to forge user-action parity.")
        } catch {
            XCTAssertFalse(didSetAutonomy)
            XCTAssertTrue(String(describing: error).contains("cannot change Mission autonomy"))
            XCTAssertTrue(String(describing: error).contains("external user or CLI driver"))
        }
    }

    func testSetAutonomyRejectsUnknownClassAndMode() async throws {
        let coordinatorID = UUID()
        var didSetAutonomy = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Invalid autonomy Mission.",
                    status: .running,
                    approvalState: .approved,
                    policySnapshot: .defaultPolicy
                )]
            },
            setMissionAutonomy: { _, _, _ in
                didSetAutonomy = true
                return .accepted
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("set_autonomy"),
                "autonomy_class": .string("writes"),
                "mode": .string("auto")
            ])
            XCTFail("Expected invalid autonomy class to be rejected.")
        } catch {
            XCTAssertFalse(didSetAutonomy)
            XCTAssertTrue(String(describing: error).contains("autonomy_class must be one of: childAsk"))
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("set_autonomy"),
                "autonomy_class": .string("childAsk"),
                "mode": .string("delegate")
            ])
            XCTFail("Expected invalid autonomy mode to be rejected.")
        } catch {
            XCTAssertFalse(didSetAutonomy)
            XCTAssertTrue(String(describing: error).contains("mode must be one of: ask, auto"))
        }
    }

    func testDoctorReportsCoordinatorCapabilities() async throws {
        let coordinatorID = UUID()
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Completed Mission.",
                    status: .completed,
                    approvalState: .approved
                )]
            }
        )

        let response = try await service.execute(args: ["op": .string("doctor")])
        let doctor = try XCTUnwrap(response.objectValue?["doctor"]?.objectValue)
        let coordinatorChat = try XCTUnwrap(doctor["coordinator_chat"]?.objectValue)
        let features = try XCTUnwrap(coordinatorChat["features"]?.objectValue)
        let ops = try XCTUnwrap(coordinatorChat["supported_ops"]?.arrayValue?.compactMap(\.stringValue))
        let childBackends = try XCTUnwrap(doctor["child_backends"]?.objectValue)

        XCTAssertEqual(doctor["ok"]?.boolValue, true)
        XCTAssertTrue(ops.contains("doctor"))
        XCTAssertTrue(ops.contains("list_missions"))
        XCTAssertTrue(ops.contains("archive_mission"))
        XCTAssertTrue(ops.contains("propose_revision"))
        let revisionProposals = try XCTUnwrap(features["revision_proposals"]?.objectValue)
        XCTAssertEqual(Set(revisionProposals.keys), ["version", "representation", "actions"])
        XCTAssertEqual(revisionProposals["version"]?.intValue, 1)
        XCTAssertEqual(revisionProposals["representation"]?.stringValue, "summary_only")
        XCTAssertEqual(
            revisionProposals["actions"]?.arrayValue?.compactMap(\.stringValue),
            ["revise_plan", "keep_current_plan", "stop_mission"]
        )
        XCTAssertEqual(features["mission_events"]?.boolValue, true)
        XCTAssertEqual(features["receipt_markdown"]?.boolValue, true)
        XCTAssertEqual(features["list_missions"]?.boolValue, true)
        XCTAssertEqual(features["archive_mission"]?.boolValue, true)
        XCTAssertEqual(childBackends["structured_user_input_advertised"]?.boolValue, true)
    }

    func testListMissionsReturnsLifecycleInventory() async throws {
        let liveID = UUID()
        let archivedID = UUID()
        let missionPlans: [UUID: CoordinatorMissionPlan] = [
            liveID: CoordinatorMissionPlan(
                missionKey: "live-key",
                objective: "Live Mission.",
                status: .running,
                approvalState: .approved
            ),
            archivedID: CoordinatorMissionPlan(
                missionKey: "archived-key",
                objective: "Archived Mission.",
                status: .completed,
                approvalState: .approved,
                decisions: [
                    CoordinatorMissionDecisionRecord(
                        userDecision: .approvedMissionPlan,
                        decisionClass: .advance,
                        checkpointInstanceID: "checkpoint",
                        sessionID: archivedID,
                        checkpointID: "plan"
                    )
                ],
                evidence: [
                    CoordinatorMissionEvidenceRecord(
                        verdict: .meets,
                        summary: "Completed.",
                        source: CoordinatorMissionEvidenceSource(kind: "test")
                    )
                ]
            )
        ]
        let service = makeService(
            coordinatorIDs: [liveID, archivedID],
            selectedID: liveID,
            missionPlans: { missionPlans },
            liveInCurrentWindow: [liveID: true, archivedID: false],
            persistedOnly: [liveID: false, archivedID: true]
        )

        let allResponse = try await service.execute(args: ["op": .string("list_missions")])
        let allMissions = try XCTUnwrap(allResponse.objectValue?["missions"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(allMissions.count, 2)
        let archived = try XCTUnwrap(allMissions.first { $0["coordinator_session_id"]?.stringValue == archivedID.uuidString })
        XCTAssertEqual(archived["archived"]?.boolValue, true)
        XCTAssertEqual(archived["terminal"]?.boolValue, true)
        XCTAssertEqual(archived["status"]?.stringValue, "completed")
        XCTAssertEqual(archived["receipt_ready"]?.boolValue, true)
        XCTAssertEqual(archived["decision_counts_by_actor"]?.objectValue?["user"]?.intValue, 1)
        XCTAssertEqual(archived["evidence_counts"]?.objectValue?["total"]?.intValue, 1)

        let liveOnlyResponse = try await service.execute(args: [
            "op": .string("list_missions"),
            "include_archived": .bool(false)
        ])
        let liveOnlyMissions = try XCTUnwrap(liveOnlyResponse.objectValue?["missions"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(liveOnlyMissions.count, 1)
        XCTAssertEqual(liveOnlyMissions.first?["coordinator_session_id"]?.stringValue, liveID.uuidString)
    }

    func testListMissionsRuntimeCallerIsScopedToCallerMission() async throws {
        let callerID = UUID()
        let otherID = UUID()
        let service = makeService(
            coordinatorIDs: [callerID, otherID],
            selectedID: otherID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex-runtime",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .coordinator,
                    isCoordinatorRuntime: true
                )
            },
            resolveRuntimeCoordinatorSessionID: { metadata in
                metadata.isCoordinatorRuntime ? callerID : nil
            }
        )

        let response = try await service.execute(args: ["op": .string("list_missions")])
        let object = try XCTUnwrap(response.objectValue)
        let missions = try XCTUnwrap(object["missions"]?.arrayValue?.compactMap(\.objectValue))

        XCTAssertEqual(object["runtime_scoped"]?.boolValue, true)
        XCTAssertEqual(missions.count, 1)
        XCTAssertEqual(missions.first?["coordinator_session_id"]?.stringValue, callerID.uuidString)

        let explicitOwn = try await service.execute(args: [
            "op": .string("list_missions"),
            "coordinator_session_id": .string(callerID.uuidString)
        ])
        XCTAssertEqual(explicitOwn.objectValue?["missions"]?.arrayValue?.count, 1)

        do {
            _ = try await service.execute(args: [
                "op": .string("list_missions"),
                "coordinator_session_id": .string(otherID.uuidString)
            ])
            XCTFail("Coordinator runtime list_missions must not inspect other Missions.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("cannot inspect other Coordinator Missions"))
        }
    }

    func testArchiveMissionRequiresTerminalMission() async throws {
        let coordinatorID = UUID()
        var didArchive = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Running Mission.",
                    status: .running,
                    approvalState: .approved
                )]
            },
            archiveMission: { _ in
                didArchive = true
                return .accepted()
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("archive_mission"),
                "coordinator_session_id": .string(coordinatorID.uuidString)
            ])
            XCTFail("archive_mission must reject non-terminal Missions.")
        } catch {
            XCTAssertFalse(didArchive)
            XCTAssertTrue(String(describing: error).contains("only available after a Mission is completed or stopped"))
        }
    }

    func testArchiveMissionRejectsCoordinatorRuntimeCaller() async throws {
        let coordinatorID = UUID()
        var didArchive = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "coordinator-runtime",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .coordinator,
                    isCoordinatorRuntime: true
                )
            },
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Completed Mission.",
                    status: .completed,
                    approvalState: .approved
                )]
            },
            archiveMission: { _ in
                didArchive = true
                return .accepted()
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("archive_mission"),
                "coordinator_session_id": .string(coordinatorID.uuidString)
            ])
            XCTFail("Coordinator runtime callers must not archive Missions.")
        } catch {
            XCTAssertFalse(didArchive)
            XCTAssertTrue(String(describing: error).contains("cannot archive Coordinator Missions"))
            XCTAssertTrue(String(describing: error).contains("external user or CLI driver"))
        }
    }

    func testArchiveMissionReturnsLifecycleResultAndInventory() async throws {
        let coordinatorID = UUID()
        var archiveCalls: [UUID] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Completed Mission.",
                    status: .completed,
                    approvalState: .approved
                )]
            },
            pinned: [coordinatorID: true],
            archiveMission: { sessionID in
                archiveCalls.append(sessionID)
                return .accepted(alreadyArchived: false, unpinned: true)
            }
        )

        let response = try await service.execute(args: [
            "op": .string("archive_mission"),
            "coordinator_session_id": .string(coordinatorID.uuidString)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(archiveCalls, [coordinatorID])
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "archive_mission")
        XCTAssertEqual(object["coordinator_session_id"]?.stringValue, coordinatorID.uuidString)
        XCTAssertEqual(object["already_archived"]?.boolValue, false)
        XCTAssertEqual(object["unpinned"]?.boolValue, true)
        XCTAssertNil(object["error"]?.stringValue)
        XCTAssertNotNil(object["missions"]?.arrayValue)
    }

    func testArchiveMissionIdempotentForAlreadyArchivedMission() async throws {
        let coordinatorID = UUID()
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Archived Mission.",
                    status: .stopped,
                    approvalState: .approved
                )]
            },
            liveInCurrentWindow: [coordinatorID: false],
            persistedOnly: [coordinatorID: true],
            archiveMission: { _ in .accepted(alreadyArchived: true) }
        )

        let response = try await service.execute(args: [
            "op": .string("archive_mission"),
            "coordinator_session_id": .string(coordinatorID.uuidString)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["already_archived"]?.boolValue, true)
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
            startNew: { _ in
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
            stopMission: { targetID in
                stoppedSelection = targetID
                return .accepted
            }
        )

        let response = try await service.execute(args: [
            "op": .string("stop_mission"),
            "coordinator_session_id": .string(secondID.uuidString)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(selectedID, firstID)
        XCTAssertEqual(stoppedSelection, secondID)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator_stop")
        XCTAssertEqual(object["coordinator_session_id"]?.stringValue, secondID.uuidString)
        XCTAssertEqual(object["selected_coordinator_session_id"]?.stringValue, firstID.uuidString)
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
                    approvalState: update.approvalState ?? .awaitingApproval,
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

    func testMissionPlanRejectsInternalNonOwnerWorkerBeforeSelectedFallback() async throws {
        let selectedCoordinatorID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [selectedCoordinatorID],
            selectedID: selectedCoordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex-worker",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .pair
                )
            },
            missionPlans: {
                [selectedCoordinatorID: CoordinatorMissionPlan(
                    missionKey: "selected",
                    objective: "Selected Mission",
                    status: .running,
                    approvalState: .approved
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "objective": .string("Should not land on selected Mission")
            ])
            XCTFail("Internal non-owner Agent Mode workers must not mutate selected Mission Plans.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Internal non-owner Agent Mode workers cannot mutate"), message)
            XCTAssertFalse(didUpdate)
        }
    }

    func testMissionPlanRuntimeCallerDefaultsToCallerMissionNotSelectedMission() async throws {
        let callerCoordinatorID = UUID()
        let selectedCoordinatorID = UUID()
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            callerCoordinatorID: Self.durablyApprovedPlan(
                CoordinatorMissionPlan(
                    missionKey: "caller",
                    objective: "Caller Mission",
                    status: .running,
                    approvalState: .approved
                ),
                coordinatorID: callerCoordinatorID
            ),
            selectedCoordinatorID: CoordinatorMissionPlan(
                missionKey: "selected",
                objective: "Selected Mission",
                status: .running,
                approvalState: .approved
            )
        ]
        var updatedIDs: [UUID] = []
        let service = makeService(
            coordinatorIDs: [callerCoordinatorID, selectedCoordinatorID],
            selectedID: selectedCoordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex-runtime",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .coordinator,
                    isCoordinatorRuntime: true
                )
            },
            resolveRuntimeCoordinatorSessionID: { metadata in
                metadata.isCoordinatorRuntime ? callerCoordinatorID : nil
            },
            missionPlans: { missionPlans },
            updateMissionPlan: { sessionID, update in
                updatedIDs.append(sessionID)
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                state.updateMissionPlan(update)
                missionPlans[sessionID] = state.missionPlan
            },
            durableApprovalAuthorityToken: { missionPlans[$0]?.expectedDurableApprovalAuthorityToken }
        )

        let response = try await service.execute(args: [
            "op": .string("mission_plan"),
            "routing_decisions": .array([
                .object([
                    "decision": .string("hold_for_user"),
                    "operation": .string("coordinator_hold"),
                    "reason": .string("Caller scoped hold.")
                ])
            ])
        ])
        let object = try XCTUnwrap(response.objectValue)
        let plan = try XCTUnwrap(object["mission_plan"]?.objectValue)

        XCTAssertEqual(updatedIDs, [callerCoordinatorID])
        XCTAssertEqual(plan["mission_key"]?.stringValue, "caller")
        XCTAssertEqual(plan["objective"]?.stringValue, "Caller Mission")
        XCTAssertEqual(plan["routing_decisions"]?.arrayValue?.count, 1)
        XCTAssertEqual(missionPlans[callerCoordinatorID]?.routingDecisions.count, 1)
        XCTAssertEqual(missionPlans[selectedCoordinatorID]?.objective, "Selected Mission")
    }

    func testMissionPlanRuntimeCallerRequiresDurableApprovalAuthorityForProgress() async throws {
        let coordinatorID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex-runtime",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .coordinator,
                    isCoordinatorRuntime: true
                )
            },
            resolveRuntimeCoordinatorSessionID: { metadata in
                metadata.isCoordinatorRuntime ? coordinatorID : nil
            },
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    missionKey: "caller",
                    objective: "Caller Mission",
                    status: .running,
                    approvalState: .approved
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "routing_decisions": .array([
                    .object([
                        "decision": .string("hold_for_user"),
                        "operation": .string("coordinator_hold"),
                        "reason": .string("Should require durable authority.")
                    ])
                ])
            ])
            XCTFail("Approved-but-not-durable runtime progress must fail closed.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("durable approval authority token"), message)
            XCTAssertFalse(didUpdate)
        }
    }

    func testMissionPlanRuntimeCallerWithoutResolvedMissionDoesNotUseSelectedFallback() async throws {
        let selectedCoordinatorID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [selectedCoordinatorID],
            selectedID: selectedCoordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex-runtime",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .coordinator,
                    isCoordinatorRuntime: true
                )
            },
            missionPlans: {
                [selectedCoordinatorID: CoordinatorMissionPlan(
                    missionKey: "selected",
                    objective: "Selected Mission",
                    status: .running,
                    approvalState: .approved
                )]
            },
            updateMissionPlan: { _, _ in
                didUpdate = true
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "objective": .string("Should not land on selected Mission")
            ])
            XCTFail("Coordinator runtime mission_plan without a resolvable caller Mission must reject instead of using selection fallback.")
        } catch {
            XCTAssertFalse(didUpdate)
            let message = String(describing: error)
            XCTAssertTrue(message.contains("cannot resolve the caller Mission"), message)
        }
    }

    func testMissionPlanRuntimeCallerRejectsExplicitCrossMissionID() async throws {
        let callerCoordinatorID = UUID()
        let otherCoordinatorID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [callerCoordinatorID, otherCoordinatorID],
            selectedID: callerCoordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex-runtime",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .coordinator,
                    isCoordinatorRuntime: true
                )
            },
            resolveRuntimeCoordinatorSessionID: { metadata in
                metadata.isCoordinatorRuntime ? callerCoordinatorID : nil
            },
            missionPlans: {
                [
                    callerCoordinatorID: CoordinatorMissionPlan(objective: "Caller", status: .running, approvalState: .approved),
                    otherCoordinatorID: CoordinatorMissionPlan(objective: "Other", status: .running, approvalState: .approved)
                ]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "coordinator_session_id": .string(otherCoordinatorID.uuidString),
                "objective": .string("Should not cross-write")
            ])
            XCTFail("Coordinator runtime mission_plan must reject explicit cross-Mission IDs.")
        } catch {
            XCTAssertFalse(didUpdate)
            let message = String(describing: error)
            XCTAssertTrue(message.contains("cannot write or inspect another Coordinator Mission"), message)
        }
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
            "approval_state": .string("awaiting_approval"),
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
                    "status": .string("pending")
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
        let workflow = CoordinatorMissionPlanNodeWorkflowHint(
            id: "builtin-orchestrate",
            name: "Orchestrate",
            iconName: "arrow.triangle.branch",
            accentColorHex: "#30D158"
        )
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            coordinatorID: CoordinatorMissionPlan(
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
                        id: nodeID,
                        title: "Docs edit",
                        workflowHint: workflow,
                        completionEvidence: "README wording is updated and tests pass.",
                        workstreamID: workstreamID,
                        executionPolicy: .freshWorktree,
                        status: .pending
                    )
                ]
            )
        ]
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
        let workflowValue = try XCTUnwrap(node["workflow"]?.objectValue)
        XCTAssertEqual(workflowValue["id"]?.stringValue, "builtin-orchestrate")
        XCTAssertEqual(workflowValue["icon_name"]?.stringValue, "arrow.triangle.branch")
        XCTAssertEqual(node["bound_session_id"]?.stringValue, childID.uuidString)
        let events = try XCTUnwrap(plan["events"]?.arrayValue)
        XCTAssertEqual(events.last?.objectValue?["kind"]?.stringValue, "node_started")
        XCTAssertEqual(events.last?.objectValue?["node_id"]?.stringValue, nodeID.uuidString)
    }

    func testMissionPlanRejectsRunningDelegatedNodeWithoutBinding() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "objective": .string("Run S5 child ask"),
                "status": .string("running"),
                "approval_state": .string("approved"),
                "workstreams": .array([
                    .object([
                        "id": .string(workstreamID.uuidString),
                        "title": .string("Probe"),
                        "purpose": .string("Ask one child question."),
                        "default_policy": .string("fresh_readonly_child"),
                        "worktree_strategy": .object(["mode": .string("noneReadOnly")])
                    ])
                ]),
                "nodes": .array([
                    .object([
                        "id": .string(nodeID.uuidString),
                        "title": .string("Ask marker question"),
                        "workstream_title": .string("Probe"),
                        "execution_policy": .string("fresh_readonly_child"),
                        "status": .string("running")
                    ])
                ])
            ])
            XCTFail("Expected running delegated node without bound_session_id to be rejected.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("requires bound_session_id"), message)
            XCTAssertTrue(message.contains("agent_explore.start"), message)
        }
    }

    func testMissionPlanRejectsRuntimeProgressBeforeInitialApproval() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let plan = CoordinatorMissionPlan(
            missionKey: "awaiting-approval",
            objective: "Ask before running.",
            status: .draft,
            approvalState: .awaitingApproval,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Probe",
                    purpose: "Ask one child question.",
                    role: "explore",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .noneReadOnly,
                        reason: "Read-only smoke."
                    )
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Ask marker question",
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "status": .string("completed"),
                "nodes": .array([
                    .object([
                        "id": .string(nodeID.uuidString),
                        "title": .string("Ask marker question"),
                        "workstream_title": .string("Probe"),
                        "execution_policy": .string("fresh_readonly_child"),
                        "status": .string("completed"),
                        "completion_evidence": .string("Stale child output says Alpha.")
                    ])
                ])
            ])
            XCTFail("Runtime mission_plan updates must not complete work before initial approval.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("before approval_state is approved"), message)
        }
    }

    func testMissionPlanRejectsApprovalAdvanceWithoutUserCheckpoint() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(
            missionKey: "awaiting-approval",
            objective: "Await user checkpoint.",
            status: .draft,
            approvalState: .awaitingApproval
        )
        var updateCalled = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] },
            updateMissionPlan: { _, _ in updateCalled = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "approval_state": .string("approved")
            ])
            XCTFail("Runtime mission_plan updates must not approve the plan without the user checkpoint path.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("cannot advance approval_state to approved"), message)
            XCTAssertTrue(message.contains("user checkpoint/continuation path"), message)
        }
        XCTAssertFalse(updateCalled)
    }

    func testMissionPlanRejectsApprovalDowngradeAfterApproval() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(
            missionKey: "approved-plan",
            objective: "Already approved.",
            status: .running,
            approvalState: .approved
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "status": .string("draft"),
                "approval_state": .string("awaiting_approval")
            ])
            XCTFail("Runtime mission_plan updates must not downgrade an approved plan.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("cannot downgrade approval_state"), message)
        }
    }

    func testMissionPlanRejectsNotRequiredApprovalWaiver() async throws {
        let coordinatorID = UUID()
        var updateCalled = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            updateMissionPlan: { _, _ in updateCalled = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "objective": .string("Legacy no-approval mission."),
                "approval_state": .string("not_required")
            ])
            XCTFail("mission_plan must not create or transition to approval_state not_required.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("cannot set approval_state to not_required"), message)
        }
        XCTAssertFalse(updateCalled)
    }

    func testMissionPlanRejectsApprovedObjectiveRewrite() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: Self.approvedContractPlan(
                    objective: "Approved objective.",
                    workstreamID: workstreamID,
                    nodeID: nodeID
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "objective": .string("Silently rewritten objective")
            ])
            XCTFail("Approved Mission objective must be immutable through mission_plan.")
        } catch {
            XCTAssertFalse(didUpdate)
            let message = String(describing: error)
            XCTAssertTrue(message.contains("approved contract field objective"), message)
            XCTAssertTrue(message.contains("trusted user-visible plan revision"), message)
        }
    }

    func testMissionPlanRejectsApprovedPredecessorLineageRewrite() async throws {
        let coordinatorID = UUID()
        let predecessorID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Approved lineage",
            predecessorMissionID: predecessorID,
            predecessorTitle: "Original predecessor",
            predecessorSummary: "Original summary",
            status: .running,
            approvalState: .approved
        )
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "predecessor_title": .string("Rewritten predecessor")
            ])
            XCTFail("Approved predecessor lineage must be immutable through mission_plan.")
        } catch {
            XCTAssertFalse(didUpdate)
            let message = String(describing: error)
            XCTAssertTrue(message.contains("predecessor_title"), message)
            XCTAssertTrue(message.contains("approved contract"), message)
        }
    }

    func testMissionPlanRejectsApprovedNodeContractRewrite() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: Self.approvedContractPlan(
                    objective: "Approved objective.",
                    workstreamID: workstreamID,
                    nodeID: nodeID
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "nodes": .array([
                    .object([
                        "id": .string(nodeID.uuidString),
                        "title": .string("Implement approved work"),
                        "workstream_id": .string(workstreamID.uuidString),
                        "execution_policy": .string("fresh_readonly_child"),
                        "status": .string("pending")
                    ])
                ])
            ])
            XCTFail("Approved Mission node execution policy must be immutable through mission_plan.")
        } catch {
            XCTAssertFalse(didUpdate)
            let message = String(describing: error)
            XCTAssertTrue(message.contains("approved contract field nodes"), message)
        }
    }

    func testMissionPlanRejectsUserOwnedChildAskAutonomyMutation() async throws {
        let coordinatorID = UUID()
        var didUpdate = false
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .ask
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Approved Mission.",
                    status: .running,
                    approvalState: .approved,
                    autonomy: autonomy
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "autonomy": .object([
                    CoordinatorMissionDecisionClass.childAsk.rawValue: .string("auto")
                ])
            ])
            XCTFail("mission_plan must not mutate user-owned childAsk routing.")
        } catch {
            XCTAssertFalse(didUpdate)
            XCTAssertTrue(String(describing: error).contains("Mission autonomy authority"))
        }
    }

    func testMissionPlanRejectsUserOwnedPolicyAuthorityMutationBeforeApproval() async throws {
        let coordinatorID = UUID()
        var didUpdate = false
        var existingPolicy = CoordinatorMissionPolicySnapshot.defaultPolicy
        existingPolicy.maxConcurrent = 2
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Awaiting approval.",
                    status: .draft,
                    approvalState: .awaitingApproval,
                    policySnapshot: existingPolicy
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "policy_snapshot": .object([
                    "id": .string(existingPolicy.id),
                    "name": .string(existingPolicy.name),
                    "default_pace": .string(existingPolicy.defaultPace.rawValue),
                    "autonomy": .object(Dictionary(uniqueKeysWithValues: existingPolicy.autonomy.map { key, value in
                        (key, Value.string(value.rawValue))
                    })),
                    "max_concurrent": .int(4)
                ])
            ])
            XCTFail("mission_plan must not mutate policy authority before approval.")
        } catch {
            XCTAssertFalse(didUpdate)
            XCTAssertTrue(String(describing: error).contains("Mission policy authority"))
        }
    }

    func testMissionPlanRejectsRuntimeFirstPlanArbitraryPolicyAuthority() async throws {
        let coordinatorID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "coordinator-runtime",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .coordinator,
                    isCoordinatorRuntime: true
                )
            },
            resolveRuntimeCoordinatorSessionID: { _ in coordinatorID },
            updateMissionPlan: { _, _ in didUpdate = true }
        )
        var arbitraryPolicy = CoordinatorMissionPolicySnapshot.defaultPolicy
        arbitraryPolicy.maxConcurrent = 7

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "objective": .string("Runtime-created plan"),
                "policy_snapshot": .object([
                    "id": .string(arbitraryPolicy.id),
                    "name": .string(arbitraryPolicy.name),
                    "default_pace": .string(arbitraryPolicy.defaultPace.rawValue),
                    "autonomy": .object(Dictionary(uniqueKeysWithValues: arbitraryPolicy.autonomy.map { key, value in
                        (key, Value.string(value.rawValue))
                    })),
                    "max_concurrent": .int(arbitraryPolicy.maxConcurrent)
                ])
            ])
            XCTFail("Owning runtime must not establish arbitrary first-plan policy authority.")
        } catch {
            XCTAssertFalse(didUpdate)
            XCTAssertTrue(String(describing: error).contains("first plan creation"))
        }
    }

    func testMissionPlanAllowsApprovedInitialWorktreeBindingButRejectsRewriteAndClear() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        var plan = Self.approvedContractPlan(
            objective: "Approved objective.",
            workstreamID: workstreamID,
            nodeID: nodeID
        )
        var updates: [CoordinatorMissionPlanUpdate] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] },
            updateMissionPlan: { _, update in
                updates.append(update)
                var state = CoordinatorFollowThroughState(missionPlan: plan)
                state.updateMissionPlan(update)
                plan = state.missionPlan ?? plan
            }
        )

        _ = try await service.execute(args: [
            "op": .string("mission_plan"),
            "workstreams": .array([
                .object([
                    "id": .string(workstreamID.uuidString),
                    "title": .string("Implementation"),
                    "purpose": .string("Implement the approved work."),
                    "default_policy": .string("fresh_worktree"),
                    "worktree_strategy": .object([
                        "mode": .string("createIsolated"),
                        "worktree_id": .string("wt-approved"),
                        "base_ref": .string("main"),
                        "base_reason": .string("Approved contract base.")
                    ])
                ])
            ])
        ])
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(plan.workstreams.first?.worktreeID, "wt-approved")

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "workstreams": .array([
                    .object([
                        "id": .string(workstreamID.uuidString),
                        "title": .string("Implementation"),
                        "purpose": .string("Implement the approved work."),
                        "default_policy": .string("fresh_worktree"),
                        "worktree_strategy": .object([
                            "mode": .string("createIsolated"),
                            "worktree_id": .string("wt-rewrite"),
                            "base_ref": .string("main"),
                            "base_reason": .string("Approved contract base.")
                        ])
                    ])
                ])
            ])
            XCTFail("Approved worktree target rewrites must be rejected.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("approved contract field workstreams"))
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "workstreams": .array([
                    .object([
                        "id": .string(workstreamID.uuidString),
                        "title": .string("Implementation"),
                        "purpose": .string("Implement the approved work."),
                        "default_policy": .string("fresh_worktree"),
                        "worktree_strategy": .object([
                            "mode": .string("createIsolated"),
                            "worktree_id": .string(""),
                            "base_ref": .string("main"),
                            "base_reason": .string("Approved contract base.")
                        ])
                    ])
                ])
            ])
            XCTFail("Approved worktree target clears must be rejected.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("approved contract field workstreams"))
        }
    }

    func testMissionPlanRejectsApprovedReplaceWorkstreamsWithoutPayload() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Approved Mission.",
                    status: .running,
                    approvalState: .approved,
                    workstreams: [
                        CoordinatorMissionWorkstreamSummary(
                            id: workstreamID,
                            title: "Approved lane",
                            purpose: "Must remain present.",
                            defaultPolicy: .freshWorktree,
                            worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                        )
                    ]
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "status": .string("running"),
                "replace_workstreams": .bool(true)
            ])
            XCTFail("Approved Mission contracts must reject replace_workstreams even without a payload.")
        } catch {
            XCTAssertFalse(didUpdate)
            XCTAssertTrue(String(describing: error).contains("replace_workstreams"))
        }
    }

    func testMissionPlanAllowsPreApprovalWorkflowlessReadOnlyProbeProgressOnNoneReadOnlyWorkstream() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            coordinatorID: CoordinatorMissionPlan(
                objective: "Ground the draft plan.",
                status: .draft,
                approvalState: .awaitingApproval,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: workstreamID,
                        title: "Read-only probe",
                        purpose: "Gather lightweight evidence before approval.",
                        defaultPolicy: .freshReadOnlyChild,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: nodeID,
                        title: "Probe plan risk",
                        completionEvidence: "Probe answer identifies the risk.",
                        workstreamID: workstreamID,
                        executionPolicy: .freshReadOnlyChild,
                        status: .pending
                    )
                ]
            )
        ]
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
            "nodes": .array([
                .object([
                    "id": .string(nodeID.uuidString),
                    "title": .string("Probe plan risk"),
                    "completion_evidence": .string("Probe answer identifies the risk."),
                    "workstream_id": .string(workstreamID.uuidString),
                    "execution_policy": .string("fresh_readonly_child"),
                    "status": .string("running"),
                    "bound_session_id": .string(childID.uuidString)
                ])
            ])
        ])

        let node = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue?["nodes"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(node["status"]?.stringValue, "running")
        XCTAssertEqual(node["bound_session_id"]?.stringValue, childID.uuidString)
    }

    func testMissionPlanAllowsPreApprovalPlanningNodeProgressForExactEligibleNode() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            coordinatorID: CoordinatorMissionPlan(
                objective: "Ground the draft plan.",
                status: .draft,
                approvalState: .awaitingApproval,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: workstreamID,
                        title: "Planning",
                        purpose: "Gather read-only evidence before approval.",
                        defaultPolicy: .freshReadOnlyChild,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                            mode: .createIsolated,
                            baseRef: "main",
                            baseReason: "Preapproval planning uses an isolated worktree."
                        )
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: nodeID,
                        title: "Deepen implementation plan",
                        workflowHint: CoordinatorMissionPlanNodeWorkflowHint(id: "builtin-deepplan", name: "Deep Plan"),
                        completionEvidence: "Deep Plan report identifies risks and a safe execution order.",
                        workstreamID: workstreamID,
                        executionPolicy: .freshReadOnlyChild,
                        status: .pending
                    )
                ]
            )
        ]
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
            "nodes": .array([
                .object([
                    "id": .string(nodeID.uuidString),
                    "title": .string("Deepen implementation plan"),
                    "workflow": .object([
                        "id": .string("builtin-deepplan"),
                        "name": .string("Deep Plan")
                    ]),
                    "completion_evidence": .string("Deep Plan report identifies risks and a safe execution order."),
                    "workstream_id": .string(workstreamID.uuidString),
                    "execution_policy": .string("fresh_readonly_child"),
                    "status": .string("running"),
                    "bound_session_id": .string(childID.uuidString)
                ])
            ])
        ])
        let node = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue?["nodes"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(node["status"]?.stringValue, "running")
        XCTAssertEqual(node["bound_session_id"]?.stringValue, childID.uuidString)
        XCTAssertEqual(missionPlans[coordinatorID]?.approvalState, .awaitingApproval)
    }

    func testMissionPlanRejectsPreApprovalPlanningNodeContractRewrite() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Ground the draft plan.",
                    status: .draft,
                    approvalState: .awaitingApproval,
                    workstreams: [
                        CoordinatorMissionWorkstreamSummary(
                            id: workstreamID,
                            title: "Planning",
                            purpose: "Gather read-only evidence before approval.",
                            defaultPolicy: .freshReadOnlyChild,
                            worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                        )
                    ],
                    nodes: [
                        CoordinatorMissionPlanNode(
                            id: nodeID,
                            title: "Probe plan risk",
                            completionEvidence: "Probe result explains the risk.",
                            workstreamID: workstreamID,
                            executionPolicy: .freshReadOnlyChild,
                            status: .pending
                        )
                    ]
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "nodes": .array([
                    .object([
                        "id": .string(nodeID.uuidString),
                        "title": .string("Probe a different plan risk"),
                        "completion_evidence": .string("Probe result explains the risk."),
                        "workstream_id": .string(workstreamID.uuidString),
                        "execution_policy": .string("fresh_readonly_child"),
                        "status": .string("running"),
                        "bound_session_id": .string(UUID().uuidString)
                    ])
                ])
            ])
            XCTFail("Preapproval progress must not rewrite the planning node contract.")
        } catch {
            XCTAssertFalse(didUpdate)
            XCTAssertTrue(String(describing: error).contains("exact node-bound pre-approval"))
        }
    }

    func testMissionPlanRejectsRuntimeStopAndTerminalReopen() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Stopped Mission.",
                    status: .stopped,
                    approvalState: .approved,
                    workstreams: [
                        CoordinatorMissionWorkstreamSummary(
                            id: workstreamID,
                            title: "Stopped workstream",
                            purpose: "Already stopped.",
                            defaultPolicy: .freshReadOnlyChild,
                            worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                        )
                    ],
                    nodes: [
                        CoordinatorMissionPlanNode(
                            id: nodeID,
                            title: "Stopped node",
                            completionEvidence: "Stopped by user.",
                            workstreamID: workstreamID,
                            executionPolicy: .freshReadOnlyChild,
                            status: .cancelled
                        )
                    ]
                )]
            },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "status": .string("running")
            ])
            XCTFail("Terminal Mission status must not reopen.")
        } catch {
            XCTAssertFalse(didUpdate)
            XCTAssertTrue(String(describing: error).contains("cannot reopen a terminal Mission"))
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "status": .string("stopped")
            ])
            XCTFail("Runtime/generic mission_plan must not own Stop.")
        } catch {
            XCTAssertFalse(didUpdate)
            XCTAssertTrue(String(describing: error).contains("Stop is app/external-user owned"))
        }
    }

    func testMissionPlanRejectsTerminalReceiptAffectingLedgerMutation() async throws {
        let coordinatorID = UUID()
        let decisionID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Terminal receipt is frozen",
            status: .completed,
            approvalState: .approved
        )
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "decisions": .array([
                    .object([
                        "id": .string(decisionID.uuidString),
                        "actor": .string("director"),
                        "decision_class": .string("advance"),
                        "label": .string("late mutation")
                    ])
                ])
            ])
            XCTFail("Terminal Mission receipt inputs must be frozen.")
        } catch {
            XCTAssertFalse(didUpdate)
            let message = String(describing: error)
            XCTAssertTrue(message.contains("receipt-affecting fields"), message)
            XCTAssertTrue(message.contains("decisions"), message)
        }
    }

    func testMissionPlanRejectsCompletedNodeWithStaleWaitingEvidence() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let interactionID = UUID()
        let plan = CoordinatorMissionPlan(
            missionKey: "approved-s5",
            objective: "Ask after approval.",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Probe",
                    purpose: "Ask one child question.",
                    role: "explore",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .noneReadOnly,
                        reason: "Read-only smoke."
                    )
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Ask marker question",
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: childID,
                    boundInteractionID: interactionID
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "nodes": .array([
                    .object([
                        "id": .string(nodeID.uuidString),
                        "title": .string("Ask marker question"),
                        "workstream_title": .string("Probe"),
                        "execution_policy": .string("fresh_readonly_child"),
                        "status": .string("completed"),
                        "bound_session_id": .string(childID.uuidString),
                        "bound_interaction_id": .string(interactionID.uuidString),
                        "completion_evidence": .string("Child is waiting at the required ask_user interaction before completion.")
                    ])
                ])
            ])
            XCTFail("Completed nodes must not keep stale waiting evidence.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("stale waiting/bound state"), message)
        }
    }

    func testMissionPlanRejectsCompletedStatusWithPendingNodes() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let pendingNodeID = UUID()
        let completedNodeID = UUID()
        let plan = CoordinatorMissionPlan(
            missionKey: "mixed-terminal-state",
            objective: "Do not complete until all nodes are terminal.",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Probe",
                    purpose: "Keep pending work visible.",
                    defaultPolicy: .coordinatorOnly,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: pendingNodeID,
                    title: "Still pending",
                    workstreamID: workstreamID,
                    executionPolicy: .coordinatorOnly
                ),
                CoordinatorMissionPlanNode(
                    id: completedNodeID,
                    title: "Already done",
                    completionEvidence: "Coordinator completed this node.",
                    workstreamID: workstreamID,
                    executionPolicy: .coordinatorOnly,
                    status: .completed
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "status": .string("completed")
            ])
            XCTFail("A Mission cannot become completed while any node is still pending.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("status completed requires every node to be terminal"), message)
            XCTAssertTrue(message.contains("Still pending"), message)
        }
    }

    func testMissionPlanRejectsChildAskAutoCompletionWithoutDirectorLedger() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let interactionID = UUID()
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        let plan = CoordinatorMissionPlan(
            missionKey: "auto-child-ask",
            objective: "Answer child questions as Director.",
            status: .running,
            approvalState: .approved,
            autonomy: autonomy,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Probe",
                    purpose: "Ask one child question.",
                    role: "explore",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .noneReadOnly,
                        reason: "Read-only smoke."
                    )
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Ask marker question",
                    completionEvidence: "Child is running.",
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: childID,
                    boundInteractionID: interactionID
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        do {
            let args: [String: Value] = [
                "op": .string("mission_plan"),
                "status": .string("completed"),
                "nodes": .array([
                    .object([
                        "id": .string(nodeID.uuidString),
                        "title": .string("Ask marker question"),
                        "workstream_title": .string("Probe"),
                        "execution_policy": .string("fresh_readonly_child"),
                        "status": .string("completed"),
                        "bound_session_id": .string(childID.uuidString),
                        "bound_interaction_id": .string(interactionID.uuidString),
                        "completion_evidence": .string("Child final output selected marker Alpha.")
                    ])
                ])
            ]
            _ = try await service.execute(args: args)
            XCTFail("childAsk:auto completion must include childAsk ledger records.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("childAsk decision and evidence"), message)
        }
    }

    func testMissionPlanRejectsPolicySnapshotChildAskAutoCompletionWithoutDirectorLedger() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let interactionID = UUID()
        var policySnapshot = CoordinatorMissionPolicySnapshot.defaultPolicy
        policySnapshot.autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        let plan = CoordinatorMissionPlan(
            missionKey: "auto-child-ask-policy",
            objective: "Answer child questions as Director.",
            status: .running,
            approvalState: .approved,
            policySnapshot: policySnapshot,
            autonomy: policySnapshot.autonomy,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Probe",
                    purpose: "Ask one child question.",
                    role: "explore",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .noneReadOnly,
                        reason: "Read-only smoke."
                    )
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Ask marker question",
                    completionEvidence: "Child is running.",
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: childID,
                    boundInteractionID: interactionID
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "status": .string("completed"),
                "nodes": .array([
                    .object([
                        "id": .string(nodeID.uuidString),
                        "title": .string("Ask marker question"),
                        "workstream_title": .string("Probe"),
                        "execution_policy": .string("fresh_readonly_child"),
                        "status": .string("completed"),
                        "bound_session_id": .string(childID.uuidString),
                        "bound_interaction_id": .string(interactionID.uuidString),
                        "completion_evidence": .string("Child final output selected marker Alpha.")
                    ])
                ])
            ])
            XCTFail("childAsk:auto from policy_snapshot must require childAsk ledger records.")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("childAsk decision and evidence"), message)
        }
    }

    func testMissionPlanChildAskDialOverridesPolicySnapshotWhenCompletingUserAnsweredNode() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let interactionID = UUID()
        var policySnapshot = CoordinatorMissionPolicySnapshot.defaultPolicy
        policySnapshot.autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .ask
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            coordinatorID: CoordinatorMissionPlan(
                missionKey: "ask-overrides-policy-auto",
                objective: "User answers child questions.",
                status: .running,
                approvalState: .approved,
                policySnapshot: policySnapshot,
                autonomy: autonomy,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: workstreamID,
                        title: "Probe",
                        purpose: "Ask one child question.",
                        role: "explore",
                        defaultPolicy: .freshReadOnlyChild,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                            mode: .noneReadOnly,
                            reason: "Read-only smoke."
                        )
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: nodeID,
                        title: "Ask marker question",
                        completionEvidence: "Child is running.",
                        workstreamID: workstreamID,
                        executionPolicy: .freshReadOnlyChild,
                        status: .running,
                        boundSessionID: childID,
                        boundInteractionID: interactionID
                    )
                ]
            )
        ]
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
            "status": .string("completed"),
            "nodes": .array([
                .object([
                    "id": .string(nodeID.uuidString),
                    "title": .string("Ask marker question"),
                    "workstream_title": .string("Probe"),
                    "execution_policy": .string("fresh_readonly_child"),
                    "status": .string("completed"),
                    "bound_session_id": .string(childID.uuidString),
                    "bound_interaction_id": .string(interactionID.uuidString),
                    "completion_evidence": .string("Child final output selected marker Alpha after the user answered.")
                ])
            ])
        ])

        let plan = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue)
        XCTAssertEqual(plan["status"]?.stringValue, "completed")
    }

    func testMissionPlanAcceptsChildAskAutoCompletionWithDirectorLedger() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let interactionID = UUID()
        let decisionID = UUID()
        let evidenceID = UUID()
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            coordinatorID: CoordinatorMissionPlan(
                missionKey: "auto-child-ask",
                objective: "Answer child questions as Director.",
                status: .running,
                approvalState: .approved,
                autonomy: autonomy,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: workstreamID,
                        title: "Probe",
                        purpose: "Ask one child question.",
                        role: "explore",
                        defaultPolicy: .freshReadOnlyChild,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                            mode: .noneReadOnly,
                            reason: "Read-only smoke."
                        )
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: nodeID,
                        title: "Ask marker question",
                        completionEvidence: "Child is running.",
                        workstreamID: workstreamID,
                        executionPolicy: .freshReadOnlyChild,
                        status: .running,
                        boundSessionID: childID,
                        boundInteractionID: interactionID
                    )
                ]
            )
        ]
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
            "status": .string("completed"),
            "nodes": .array([
                .object([
                    "id": .string(nodeID.uuidString),
                    "title": .string("Ask marker question"),
                    "workstream_title": .string("Probe"),
                    "execution_policy": .string("fresh_readonly_child"),
                    "status": .string("completed"),
                    "bound_session_id": .string(childID.uuidString),
                    "bound_interaction_id": .string(interactionID.uuidString),
                    "completion_evidence": .string("Child final output selected marker Alpha.")
                ])
            ]),
            "decisions": .array([
                .object([
                    "id": .string(decisionID.uuidString),
                    "actor": .string("director"),
                    "decision_class": .string("childAsk"),
                    "label": .string("answered a child question"),
                    "reason": .string("Director answered with Alpha."),
                    "session_id": .string(childID.uuidString),
                    "interaction_id": .string(interactionID.uuidString),
                    "checkpoint_id": .string("child-question")
                ])
            ]),
            "evidence": .array([
                .object([
                    "id": .string(evidenceID.uuidString),
                    "verdict": .string("meets"),
                    "summary": .string("Director answered child question with Alpha."),
                    "session_id": .string(childID.uuidString),
                    "interaction_id": .string(interactionID.uuidString),
                    "decision_id": .string(decisionID.uuidString)
                ])
            ])
        ])

        let plan = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue)
        XCTAssertEqual(plan["status"]?.stringValue, "completed")
        XCTAssertEqual(plan["decisions"]?.arrayValue?.last?.objectValue?["actor"]?.stringValue, "director")
        XCTAssertEqual(plan["evidence"]?.arrayValue?.last?.objectValue?["interaction_id"]?.stringValue, interactionID.uuidString)
    }

    func testMissionPlanAcceptsChildAskAutoCompletionWithUserOverrideLedger() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let interactionID = UUID()
        let decisionID = UUID()
        let evidenceID = UUID()
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            coordinatorID: CoordinatorMissionPlan(
                missionKey: "auto-child-ask-user-override",
                objective: "User overrides a child question.",
                status: .running,
                approvalState: .approved,
                autonomy: autonomy,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: workstreamID,
                        title: "Probe",
                        purpose: "Ask one child question.",
                        role: "explore",
                        defaultPolicy: .freshReadOnlyChild,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                            mode: .noneReadOnly,
                            reason: "Read-only smoke."
                        )
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: nodeID,
                        title: "Ask marker question",
                        completionEvidence: "Child is running.",
                        workstreamID: workstreamID,
                        executionPolicy: .freshReadOnlyChild,
                        status: .running,
                        boundSessionID: childID,
                        boundInteractionID: interactionID
                    )
                ],
                decisions: [
                    CoordinatorMissionDecisionRecord(
                        id: decisionID,
                        decisionClass: CoordinatorMissionDecisionClass.childAsk.rawValue,
                        actor: .user,
                        label: CoordinatorMissionUserDecisionLabel.answeredChildQuestion.rawValue,
                        reason: "User supplied Alpha before Director answered.",
                        sessionID: childID,
                        interactionID: interactionID
                    )
                ],
                evidence: [
                    CoordinatorMissionEvidenceRecord(
                        id: evidenceID,
                        verdict: .meets,
                        summary: "User answered child question with Alpha.",
                        sessionID: childID,
                        interactionID: interactionID,
                        decisionID: decisionID
                    )
                ]
            )
        ]
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
            "status": .string("completed"),
            "nodes": .array([
                .object([
                    "id": .string(nodeID.uuidString),
                    "title": .string("Ask marker question"),
                    "workstream_title": .string("Probe"),
                    "execution_policy": .string("fresh_readonly_child"),
                    "status": .string("completed"),
                    "bound_session_id": .string(childID.uuidString),
                    "bound_interaction_id": .string(interactionID.uuidString),
                    "completion_evidence": .string("Child final output selected marker Alpha after the user override.")
                ])
            ])
        ])

        let plan = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue)
        XCTAssertEqual(plan["status"]?.stringValue, "completed")
        XCTAssertEqual(plan["decisions"]?.arrayValue?.last?.objectValue?["actor"]?.stringValue, "user")
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
        XCTAssertEqual(
            updatedDecisions.first?.objectValue?["reason"]?.stringValue,
            "The implementation surface is unknown, so start a narrow read-only probe first."
        )
        XCTAssertEqual(updatedDecisions.last?.objectValue?["operation"]?.stringValue, "coordinator_hold")
    }

    func testMissionPlanAcceptsMissionContractAndAppendOnlyLedgers() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let probeSessionID = try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000010"))
        let probeInteractionID = try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000011"))
        let routingDecisionID = try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000012"))
        let overruledDecisionID = try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000013"))
        let decisionID = try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000001"))
        let evidenceID = try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000002"))
        let secondEvidenceID = try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000003"))
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
            "objective": .string("Ship ledger-backed status"),
            "shape_summary": .object([
                "id": .string("investigation"),
                "display_name": .string("Investigation"),
                "reason": .string("Need a bounded read-only proof."),
                "named_close": .string("Receipt")
            ]),
            "policy_snapshot": .object([
                "id": .string("careful-writes"),
                "name": .string("Careful writes"),
                "default_pace": .string("step"),
                "max_concurrent": .int(4),
                "autonomy": .object([
                    "advance": .string("ask"),
                    "writes": .string("ask")
                ]),
                "definition_of_done": .string("Tests prove the MCP ledger contract."),
                "standing_guidance": .string("Keep write boundaries visible."),
                "pinned_skill_ids": .array([.string("rpce-test-quality")]),
                "pinned_context_ids": .array([.string("ctx-ledger")])
            ]),
            "autonomy": .object([
                "advance": .string("ask"),
                "writes": .string("auto"),
                "customRisk": .string("ask")
            ]),
            "workstreams": .array([
                .object([
                    "id": .string(workstreamID.uuidString),
                    "title": .string("Discovery"),
                    "purpose": .string("Gather proof."),
                    "default_policy": .string("fresh_readonly_child"),
                    "worktree_strategy": .object(["mode": .string("noneReadOnly")])
                ])
            ]),
            "nodes": .array([
                .object([
                    "id": .string(nodeID.uuidString),
                    "title": .string("Verify MCP ledger path"),
                    "workstream_id": .string(workstreamID.uuidString),
                    "execution_policy": .string("fresh_readonly_child"),
                    "completion_evidence": .string("Focused MCP test passes."),
                    "done_criteria": .string("Decision and evidence append without replacing existing ledger records.")
                ])
            ]),
            "decisions": .array([
                .object([
                    "id": .string(decisionID.uuidString),
                    "decision_class": .string("advance"),
                    "actor": .string("director"),
                    "label": .string("started read-only proof"),
                    "reason": .string("Runtime chose a read-only evidence pass."),
                    "timestamp": .string("2026-07-02T10:00:00Z"),
                    "node_title": .string("Verify MCP ledger path"),
                    "workstream_title": .string("Discovery"),
                    "checkpoint_id": .string("plan_approval"),
                    "checkpoint_instance_id": .string("plan:r1"),
                    "overruled_decision_id": .string(overruledDecisionID.uuidString),
                    "overrule_reason": .string("Earlier probe conclusion did not include done criteria."),
                    "correction_reason": .string("Director correction used structured evidence instead."),
                    "correction_steer_text": .string("Steer the probe to answer only the missing evidence question.")
                ])
            ]),
            "evidence": .array([
                .object([
                    "id": .string(evidenceID.uuidString),
                    "verdict": .string("meets"),
                    "summary": .string("The old payload fields still coexist with ledgers."),
                    "timestamp": .string("2026-07-02T10:01:00Z"),
                    "node_title": .string("Verify MCP ledger path"),
                    "session_id": .string(probeSessionID.uuidString),
                    "interaction_id": .string(probeInteractionID.uuidString),
                    "decision_id": .string(decisionID.uuidString),
                    "source": .object([
                        "kind": .string("probe_answer"),
                        "operation": .string("agent_explore.start"),
                        "routing_decision_id": .string(routingDecisionID.uuidString),
                        "node_title": .string("Verify MCP ledger path"),
                        "session_id": .string(probeSessionID.uuidString),
                        "interaction_id": .string(probeInteractionID.uuidString),
                        "answer_id": .string("probe-answer-1"),
                        "summary": .string("Read-only probe answered the evidence question without transcript import.")
                    ]),
                    "judgment_bundle": .object([
                        "done_criteria": .string("Decision and evidence append without replacing existing ledger records."),
                        "structured_evidence": .string("Focused MCP test exercises policy, overrule, and evidence source fields."),
                        "diff_stats": .object([
                            "files_changed": .int(3),
                            "insertions": .int(120),
                            "deletions": .int(4),
                            "summary": .string("Schema, MCP service, and focused tests changed.")
                        ]),
                        "probe_answer": .object([
                            "answer_id": .string("probe-answer-1"),
                            "source": .string("agent_explore.start"),
                            "answer": .string("The narrow probe found the required MCP contract paths."),
                            "session_id": .string(probeSessionID.uuidString),
                            "interaction_id": .string(probeInteractionID.uuidString),
                            "routing_decision_id": .string(routingDecisionID.uuidString)
                        ]),
                        "transcript_framing": .string("not_transcript_summary")
                    ])
                ])
            ])
        ])

        let response = try await service.execute(args: [
            "op": .string("mission_plan"),
            "decisions": .array([
                .object([
                    "id": .string(decisionID.uuidString),
                    "decision_class": .string("advance"),
                    "actor": .string("director"),
                    "label": .string("should not replace existing decision"),
                    "timestamp": .string("2026-07-02T10:02:00Z")
                ])
            ]),
            "evidence": .array([
                .object([
                    "id": .string(evidenceID.uuidString),
                    "verdict": .string("short"),
                    "summary": .string("Should not replace existing evidence."),
                    "timestamp": .string("2026-07-02T10:03:00Z")
                ]),
                .object([
                    "id": .string(secondEvidenceID.uuidString),
                    "verdict": .string("short"),
                    "summary": .string("Follow-up proof is still short on UI projection."),
                    "timestamp": .string("2026-07-02T10:04:00Z")
                ])
            ])
        ])

        let plan = try XCTUnwrap(response.objectValue?["mission_plan"]?.objectValue)
        XCTAssertEqual(plan["shape_summary"]?.objectValue?["display_name"]?.stringValue, "Investigation")
        XCTAssertEqual(plan["policy_snapshot"]?.objectValue?["name"]?.stringValue, "Careful writes")
        XCTAssertEqual(plan["policy_snapshot"]?.objectValue?["max_concurrent"]?.intValue, 4)
        XCTAssertEqual(plan["policy_snapshot"]?.objectValue?["pinned_skill_ids"]?.arrayValue?.first?.stringValue, "rpce-test-quality")
        XCTAssertEqual(plan["autonomy"]?.objectValue?["writes"]?.stringValue, "auto")
        let node = try XCTUnwrap(plan["nodes"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(node["done_criteria"]?.stringValue, "Decision and evidence append without replacing existing ledger records.")
        let decisions = try XCTUnwrap(plan["decisions"]?.arrayValue)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.objectValue?["label"]?.stringValue, "started read-only proof")
        XCTAssertEqual(decisions.first?.objectValue?["node_id"]?.stringValue, nodeID.uuidString)
        XCTAssertEqual(decisions.first?.objectValue?["overruled_decision_id"]?.stringValue, overruledDecisionID.uuidString)
        XCTAssertEqual(decisions.first?.objectValue?["correction_steer_text"]?.stringValue, "Steer the probe to answer only the missing evidence question.")
        let evidence = try XCTUnwrap(plan["evidence"]?.arrayValue)
        XCTAssertEqual(evidence.count, 2)
        XCTAssertEqual(evidence.first?.objectValue?["summary"]?.stringValue, "The old payload fields still coexist with ledgers.")
        XCTAssertEqual(evidence.first?.objectValue?["source"]?.objectValue?["operation"]?.stringValue, "agent_explore.start")
        XCTAssertEqual(evidence.first?.objectValue?["source"]?.objectValue?["node_id"]?.stringValue, nodeID.uuidString)
        XCTAssertEqual(evidence.first?.objectValue?["judgment_bundle"]?.objectValue?["transcript_framing"]?.stringValue, "not_transcript_summary")
        XCTAssertEqual(evidence.first?.objectValue?["judgment_bundle"]?.objectValue?["diff_stats"]?.objectValue?["files_changed"]?.intValue, 3)
        XCTAssertEqual(evidence.first?.objectValue?["judgment_bundle"]?.objectValue?["probe_answer"]?.objectValue?["answer_id"]?.stringValue, "probe-answer-1")
        XCTAssertEqual(evidence.last?.objectValue?["summary"]?.stringValue, "Follow-up proof is still short on UI projection.")

        let statusResponse = try await service.execute(args: ["op": .string("mission_status")])
        let status = try XCTUnwrap(statusResponse.objectValue?["mission_status"]?.objectValue)
        XCTAssertEqual(status["decision_counts_by_actor"]?.objectValue?["director"]?.intValue, 1)
        XCTAssertEqual(status["decision_counts_by_actor"]?.objectValue?["user"]?.intValue, 0)
        XCTAssertEqual(status["evidence_counts"]?.objectValue?["total"]?.intValue, 2)
        XCTAssertEqual(status["evidence_counts"]?.objectValue?["short"]?.intValue, 1)
        XCTAssertEqual(status["recent_ledger_entries"]?.arrayValue?.first?.objectValue?["kind"]?.stringValue, "evidence")
        XCTAssertEqual(status["receipt_ready_summary"], .null)

        let compactResponse = try await service.execute(args: [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ])
        let compactStatus = try XCTUnwrap(compactResponse.objectValue?["mission_status"]?.objectValue)
        let compactPlan = try XCTUnwrap(compactStatus["plan"]?.objectValue)
        XCTAssertEqual(compactPlan["shape_summary"]?.objectValue?["id"]?.stringValue, "investigation")
        XCTAssertEqual(compactPlan["policy_snapshot"]?.objectValue?["id"]?.stringValue, "careful-writes")
        XCTAssertEqual(compactPlan["policy_snapshot"]?.objectValue?["max_concurrent"]?.intValue, 4)
        let effectiveAsk = compactPlan["autonomy_summary"]?.objectValue?["ask"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertTrue(effectiveAsk?.contains("customRisk") == true)
        XCTAssertTrue(effectiveAsk?.contains("irreversible") == true)
        XCTAssertEqual(compactStatus["decision_counts_by_actor"]?.objectValue?["director"]?.intValue, 1)
        XCTAssertEqual(compactStatus["recent_ledger_entries"]?.arrayValue?.count, 3)
    }

    func testMissionPlanRejectsUserDecisionActorAndMissingLedgerIDs() async throws {
        let coordinatorID = UUID()
        let service = makeService(coordinatorIDs: [coordinatorID], selectedID: coordinatorID)

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "decisions": .array([
                    .object([
                        "id": .string(UUID().uuidString),
                        "decision_class": .string("advance"),
                        "actor": .string("user"),
                        "label": .string("should be app-owned")
                    ])
                ])
            ])
            XCTFail("Expected user-actor decision to be rejected.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("User decisions are recorded by the app/MCP submit path"))
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "decisions": .array([
                    .object([
                        "decision_class": .string("advance"),
                        "actor": .string("director"),
                        "label": .string("missing id")
                    ])
                ])
            ])
            XCTFail("Expected missing decision id to be rejected.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("decisions[].id is required"))
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "evidence": .array([
                    .object([
                        "verdict": .string("meets"),
                        "summary": .string("missing id")
                    ])
                ])
            ])
            XCTFail("Expected missing evidence id to be rejected.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("evidence[].id is required"))
        }
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
        var missionPlans: [UUID: CoordinatorMissionPlan] = [
            coordinatorID: CoordinatorMissionPlan(
                objective: "Issue 298 provider cleanup",
                status: .draft,
                approvalState: .awaitingApproval
            )
        ]
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
            "status": .string("draft"),
            "approval_state": .string("awaiting_approval"),
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
                    "status": .string("pending"),
                    "completion_evidence": .string("Discovery mapped the cleanup entry points.")
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

        if var plan = missionPlans[coordinatorID] {
            plan.status = .running
            plan.approvalState = .approved
            missionPlans[coordinatorID] = plan
        }

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
        XCTAssertEqual(plan["revision"]?.intValue, 3)
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

    func testMissionStatusProjectsLegacyNotRequiredAsNonAuthorizingRecoveryGuidance() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(
            revision: 4,
            objective: "Recover legacy approval",
            status: .draft,
            approvalState: .notRequired,
            nodes: [
                CoordinatorMissionPlanNode(
                    title: "Await fresh approval",
                    workstreamID: UUID(),
                    executionPolicy: .coordinatorOnly
                )
            ]
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        for compact in [false, true] {
            let response = try await service.execute(args: [
                "op": .string("mission_status"),
                "compact": .bool(compact)
            ])
            let status = try XCTUnwrap(response.objectValue?["mission_status"]?.objectValue)
            let recovery = try XCTUnwrap(status["approval_recovery"]?.objectValue)

            XCTAssertEqual(recovery["legacy_state"]?.stringValue, "not_required")
            XCTAssertEqual(recovery["authorizing"]?.boolValue, false)
            XCTAssertEqual(recovery["requires_fresh_approval_checkpoint"]?.boolValue, true)
            let guidance = try XCTUnwrap(recovery["guidance"]?.stringValue)
            XCTAssertTrue(guidance.contains("output-only and non-authorizing"))
            XCTAssertTrue(guidance.contains("fresh visible revision-bound approval checkpoint"))
            XCTAssertTrue(guidance.contains("before ordinary delegation, runtime progress, or follow-through resume"))
            XCTAssertEqual(status["plan"]?.objectValue?["approval_state"]?.stringValue, "not_required")
        }
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

    func testMissionStatusCompactWarnsWhenCompletedChildAskNodeLacksLedgerAndAcceptsAnyActorLedger() async throws {
        let coordinatorID = UUID()
        let childID = UUID()
        let workstreamID = UUID()
        let nodeID = UUID()
        let interactionID = UUID()
        let decisionID = UUID()
        let evidenceID = UUID()
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        func plan(decisions: [CoordinatorMissionDecisionRecord] = [], evidence: [CoordinatorMissionEvidenceRecord] = []) -> CoordinatorMissionPlan {
            CoordinatorMissionPlan(
                objective: "Answer child question.",
                status: .running,
                approvalState: .approved,
                policySnapshot: policy,
                autonomy: policy.autonomy,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: workstreamID,
                        title: "Probe",
                        purpose: "Ask a child question.",
                        defaultPolicy: .freshReadOnlyChild,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: nodeID,
                        title: "Ask child",
                        workstreamID: workstreamID,
                        executionPolicy: .freshReadOnlyChild,
                        status: .running,
                        boundSessionID: childID,
                        boundInteractionID: interactionID
                    )
                ],
                decisions: decisions,
                evidence: evidence
            )
        }
        var missionPlan = plan()
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            rows: [
                Self.childRow(
                    id: childID,
                    parentCoordinatorID: coordinatorID,
                    title: "Child",
                    runState: .completed,
                    statusGroup: .done,
                    workflow: nil
                )
            ],
            missionPlans: { [coordinatorID: missionPlan] }
        )

        var warnings = try await compactWarnings(service: service, args: [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ])
        XCTAssertTrue(warnings.contains("completed_child_missing_childask_ledger"))

        missionPlan = plan(
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: decisionID,
                    decisionClass: CoordinatorMissionDecisionClass.childAsk.rawValue,
                    actor: .user,
                    label: CoordinatorMissionUserDecisionLabel.answeredChildQuestion.rawValue,
                    sessionID: childID,
                    interactionID: interactionID
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: evidenceID,
                    verdict: .meets,
                    summary: "User answered Alpha.",
                    sessionID: childID,
                    interactionID: interactionID,
                    decisionID: decisionID
                )
            ]
        )
        warnings = try await compactWarnings(service: service, args: [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ])
        XCTAssertFalse(warnings.contains("completed_child_missing_childask_ledger"))
    }

    func testMissionStatusCompactIncludesDepsSatisfiedAndReadyNodeIDs() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let fourthID = UUID()
        let blockedID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Run canonical DAG",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Runtime",
                    purpose: "Exercise ready nodes.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: firstID,
                    title: "First independent node",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .completed
                ),
                CoordinatorMissionPlanNode(
                    id: secondID,
                    title: "Second independent node",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .pending
                ),
                CoordinatorMissionPlanNode(
                    id: thirdID,
                    title: "Depends on first",
                    workstreamID: workstreamID,
                    dependsOn: [firstID],
                    executionPolicy: .freshWorktree,
                    status: .pending
                ),
                CoordinatorMissionPlanNode(
                    id: fourthID,
                    title: "Depends on second and third",
                    workstreamID: workstreamID,
                    dependsOn: [secondID, thirdID],
                    executionPolicy: .freshWorktree,
                    status: .pending
                ),
                CoordinatorMissionPlanNode(
                    id: blockedID,
                    title: "Blocked active node",
                    workstreamID: workstreamID,
                    dependsOn: [firstID],
                    executionPolicy: .freshWorktree,
                    status: .blocked
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
        let readyNodeIDs = try XCTUnwrap(status["ready_node_ids"]?.arrayValue?.compactMap(\.stringValue))
        let activeNodes = try XCTUnwrap(status["active_nodes"]?.arrayValue?.compactMap(\.objectValue))
        let blockedNode = try XCTUnwrap(activeNodes.first { $0["id"]?.stringValue == blockedID.uuidString })

        XCTAssertEqual(readyNodeIDs, [secondID.uuidString, thirdID.uuidString])
        XCTAssertFalse(readyNodeIDs.contains(fourthID.uuidString))
        XCTAssertEqual(blockedNode["deps_satisfied"]?.boolValue, true)
    }

    func testMissionEventsReturnsSequencedJournalEntries() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let decisionID = UUID()
        let evidenceID = UUID()
        let proposalID = UUID()
        let resolutionID = UUID()
        let entry = CoordinatorMissionEventJournal.Entry(
            seq: 2,
            observedAt: Date(timeIntervalSince1970: 12),
            coordinatorSessionID: coordinatorID,
            fingerprint: "fp-2",
            title: "Coordinator 1",
            selected: true,
            runState: "running",
            hasPlan: true,
            plan: CoordinatorMissionEventJournal.PlanSummary(
                revision: 4,
                missionKey: "s2",
                status: "running",
                approvalState: "approved",
                terminalNodeCount: 1,
                nodeCount: 2
            ),
            nodeCounts: ["completed": 1, "pending": 1],
            readyNodeIDs: [childID],
            activeNodeIDs: [],
            nodes: [
                CoordinatorMissionEventJournal.NodeSummary(
                    id: parentID,
                    title: "A",
                    status: "completed",
                    executionPolicy: "fresh_worktree",
                    workstreamID: workstreamID,
                    dependsOn: [],
                    depsSatisfied: true,
                    boundSessionID: nil,
                    boundInteractionID: nil
                ),
                CoordinatorMissionEventJournal.NodeSummary(
                    id: childID,
                    title: "Summary",
                    status: "pending",
                    executionPolicy: "coordinator_only",
                    workstreamID: workstreamID,
                    dependsOn: [parentID],
                    depsSatisfied: true,
                    boundSessionID: nil,
                    boundInteractionID: nil
                )
            ],
            recentEventIDs: [UUID()],
            routingDecisionIDs: [UUID()],
            decisionIDs: [decisionID],
            evidenceIDs: [evidenceID],
            pendingRevisionProposalID: proposalID,
            baseContractFingerprint: "contract-fingerprint",
            recentRevisionProposalResolutionID: resolutionID,
            recentRevisionProposalResolutionOutcome: "rejected",
            livenessWarnings: []
        )
        let plan = CoordinatorMissionPlan(
            objective: "Watch events",
            status: .running,
            approvalState: .approved
        )
        var requestedSinceSeq: Int?
        var requestedLimit: Int?
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] },
            missionEvents: { _, sinceSeq, limit in
                requestedSinceSeq = sinceSeq
                requestedLimit = limit
                return CoordinatorMissionEventJournal.Batch(
                    events: [entry],
                    nextSeq: 2,
                    oldestSeq: 1,
                    latestSeq: 2,
                    truncated: false
                )
            }
        )

        let response = try await service.execute(args: [
            "op": .string("mission_events"),
            "since_seq": .int(1),
            "limit": .int(25)
        ])
        let object = try XCTUnwrap(response.objectValue)
        let events = try XCTUnwrap(object["events"]?.arrayValue?.compactMap(\.objectValue))
        let first = try XCTUnwrap(events.first)
        let nodes = try XCTUnwrap(first["nodes"]?.arrayValue?.compactMap(\.objectValue))

        XCTAssertEqual(requestedSinceSeq, 1)
        XCTAssertEqual(requestedLimit, 25)
        XCTAssertEqual(object["next_seq"]?.intValue, 2)
        XCTAssertEqual(object["oldest_seq"]?.intValue, 1)
        XCTAssertEqual(object["latest_seq"]?.intValue, 2)
        XCTAssertEqual(object["truncated"]?.boolValue, false)
        XCTAssertEqual(first["seq"]?.intValue, 2)
        XCTAssertEqual(first["fingerprint"]?.stringValue, "fp-2")
        XCTAssertEqual(first["plan"]?.objectValue?["revision"]?.intValue, 4)
        XCTAssertEqual(first["ready_node_ids"]?.arrayValue?.compactMap(\.stringValue), [childID.uuidString])
        XCTAssertEqual(first["decision_ids"]?.arrayValue?.compactMap(\.stringValue), [decisionID.uuidString])
        XCTAssertEqual(first["evidence_ids"]?.arrayValue?.compactMap(\.stringValue), [evidenceID.uuidString])
        XCTAssertEqual(first["pending_revision_proposal_id"]?.stringValue, proposalID.uuidString)
        XCTAssertEqual(first["base_contract_fingerprint"]?.stringValue, "contract-fingerprint")
        XCTAssertEqual(first["recent_revision_proposal_resolution_id"]?.stringValue, resolutionID.uuidString)
        XCTAssertEqual(first["recent_revision_proposal_resolution_outcome"]?.stringValue, "rejected")
        XCTAssertEqual(nodes[1]["deps_satisfied"]?.boolValue, true)
        XCTAssertEqual(nodes[1]["depends_on"]?.arrayValue?.compactMap(\.stringValue), [parentID.uuidString])
    }

    func testReceiptReturnsCompletedMissionMarkdown() async throws {
        let coordinatorID = UUID()
        let decisionID = UUID()
        let evidenceID = UUID()
        let plan = CoordinatorMissionPlan(
            missionKey: "receipt-demo",
            objective: "Prove the receipt op uses the app projection.",
            status: .completed,
            approvalState: .approved,
            policySnapshot: .readOnly,
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: decisionID,
                    decisionClass: CoordinatorMissionDecisionClass.plan.rawValue,
                    actor: .user,
                    label: "approved the Mission plan",
                    timestamp: Date(timeIntervalSince1970: 10)
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: evidenceID,
                    verdict: .meets,
                    summary: "The Mission completed with a durable receipt.",
                    timestamp: Date(timeIntervalSince1970: 20)
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
            "op": .string("receipt"),
            "format": .string("markdown")
        ])
        let object = try XCTUnwrap(response.objectValue)
        let markdown = try XCTUnwrap(object["markdown"]?.stringValue)

        XCTAssertEqual(object["receipt_ready"]?.boolValue, true)
        XCTAssertEqual(object["format"]?.stringValue, "markdown")
        XCTAssertEqual(object["receipt_ready_summary"]?.objectValue?["ready"]?.boolValue, true)
        XCTAssertTrue(markdown.contains("# receipt-demo"))
        XCTAssertTrue(markdown.contains("**Objective:** Prove the receipt op uses the app projection."))
        XCTAssertTrue(markdown.contains("## Decisions"))
        XCTAssertTrue(markdown.contains("- Total: 1"))
        XCTAssertTrue(markdown.contains("## Evidence"))
        XCTAssertTrue(markdown.contains("- [meets] The Mission completed with a durable receipt."))
        XCTAssertTrue(markdown.contains("## Spend"))
        XCTAssertTrue(markdown.contains(CoordinatorMissionReceiptProjection.spendReserveCopy))
    }

    func testReceiptReturnsStoppedMissionMarkdown() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(
            missionKey: "receipt-stopped-demo",
            objective: "Stop safely and preserve the receipt.",
            status: .stopped,
            approvalState: .awaitingApproval,
            decisions: [
                CoordinatorMissionDecisionRecord(
                    userDecision: .stoppedMission,
                    decisionClass: .irreversible,
                    checkpointInstanceID: "mission-stop:\(coordinatorID.uuidString):r1",
                    timestamp: Date(timeIntervalSince1970: 10),
                    sessionID: coordinatorID,
                    checkpointID: "mission-stop"
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    verdict: .meets,
                    summary: "The Mission stopped without completing mutable work.",
                    timestamp: Date(timeIntervalSince1970: 20)
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
            "op": .string("receipt"),
            "format": .string("markdown")
        ])
        let object = try XCTUnwrap(response.objectValue)
        let markdown = try XCTUnwrap(object["markdown"]?.stringValue)

        XCTAssertEqual(object["receipt_ready"]?.boolValue, true)
        XCTAssertEqual(object["receipt_ready_summary"]?.objectValue?["ready"]?.boolValue, true)
        XCTAssertTrue(markdown.contains("# receipt-stopped-demo"))
        XCTAssertTrue(markdown.contains("**Objective:** Stop safely and preserve the receipt."))
        XCTAssertTrue(markdown.contains("- User: 1"))
        XCTAssertTrue(markdown.contains("irreversible 1"))
        XCTAssertTrue(markdown.contains("- [meets] The Mission stopped without completing mutable work."))
    }

    func testReceiptReportsNotReadyBeforeMissionCompletes() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(
            missionKey: "receipt-demo",
            objective: "Still running.",
            status: .running,
            approvalState: .approved
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("receipt"),
            "format": .string("markdown")
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(object["receipt_ready"]?.boolValue, false)
        XCTAssertNil(object["markdown"]?.stringValue)
        XCTAssertTrue(object["error"]?.stringValue?.contains("not ready") == true)
    }

    func testMissionEventJournalRecordsReadyRunningCompletedTransitionOrder() {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let summaryID = UUID()
        let journal = CoordinatorMissionEventJournal(capacity: 16)

        func plan(
            firstStatus: CoordinatorMissionPlanNodeStatus,
            secondStatus: CoordinatorMissionPlanNodeStatus,
            summaryStatus: CoordinatorMissionPlanNodeStatus,
            revision: Int
        ) -> CoordinatorMissionPlan {
            CoordinatorMissionPlan(
                revision: revision,
                objective: "S2 exact transition",
                status: summaryStatus == .completed ? .completed : .running,
                approvalState: .approved,
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: firstID,
                        title: "A",
                        workstreamID: workstreamID,
                        executionPolicy: .freshWorktree,
                        status: firstStatus
                    ),
                    CoordinatorMissionPlanNode(
                        id: secondID,
                        title: "B",
                        workstreamID: workstreamID,
                        executionPolicy: .freshWorktree,
                        status: secondStatus
                    ),
                    CoordinatorMissionPlanNode(
                        id: summaryID,
                        title: "Summary",
                        workstreamID: workstreamID,
                        dependsOn: [firstID, secondID],
                        executionPolicy: .coordinatorOnly,
                        status: summaryStatus
                    )
                ]
            )
        }

        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .running,
            missionPlans: [
                coordinatorID: plan(firstStatus: .running, secondStatus: .running, summaryStatus: .pending, revision: 1)
            ]
        ))
        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .running,
            missionPlans: [
                coordinatorID: plan(firstStatus: .completed, secondStatus: .completed, summaryStatus: .pending, revision: 2)
            ]
        ))
        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .running,
            missionPlans: [
                coordinatorID: plan(firstStatus: .completed, secondStatus: .completed, summaryStatus: .running, revision: 3)
            ]
        ))
        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .completed,
            missionPlans: [
                coordinatorID: plan(firstStatus: .completed, secondStatus: .completed, summaryStatus: .completed, revision: 4)
            ]
        ))

        let events = journal.events(for: coordinatorID, sinceSeq: 0, limit: 10).events
        let summaryStates = events.compactMap { event in
            event.nodes.first { $0.id == summaryID }
        }

        XCTAssertEqual(events.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(summaryStates.map(\.status), ["pending", "pending", "running", "completed"])
        XCTAssertEqual(events[1].readyNodeIDs, [summaryID])
        XCTAssertEqual(events[2].activeNodeIDs, [summaryID])
        XCTAssertEqual(events[3].plan?.status, "completed")
    }

    func testMissionEventJournalSynthesizesReadyInterludeForCollapsedLaunch() {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let summaryID = UUID()
        let journal = CoordinatorMissionEventJournal(capacity: 16)

        func plan(
            firstStatus: CoordinatorMissionPlanNodeStatus,
            secondStatus: CoordinatorMissionPlanNodeStatus,
            summaryStatus: CoordinatorMissionPlanNodeStatus,
            revision: Int
        ) -> CoordinatorMissionPlan {
            CoordinatorMissionPlan(
                revision: revision,
                objective: "S2 collapsed transition",
                status: summaryStatus == .completed ? .completed : .running,
                approvalState: .approved,
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: firstID,
                        title: "A",
                        workstreamID: workstreamID,
                        executionPolicy: .freshWorktree,
                        status: firstStatus
                    ),
                    CoordinatorMissionPlanNode(
                        id: secondID,
                        title: "B",
                        workstreamID: workstreamID,
                        executionPolicy: .freshWorktree,
                        status: secondStatus
                    ),
                    CoordinatorMissionPlanNode(
                        id: summaryID,
                        title: "Summary",
                        workstreamID: workstreamID,
                        dependsOn: [firstID, secondID],
                        executionPolicy: .freshWorktree,
                        status: summaryStatus
                    )
                ]
            )
        }

        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .running,
            missionPlans: [
                coordinatorID: plan(firstStatus: .running, secondStatus: .running, summaryStatus: .pending, revision: 1)
            ]
        ))
        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .running,
            missionPlans: [
                coordinatorID: plan(firstStatus: .completed, secondStatus: .completed, summaryStatus: .running, revision: 2)
            ]
        ))
        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .completed,
            missionPlans: [
                coordinatorID: plan(firstStatus: .completed, secondStatus: .completed, summaryStatus: .completed, revision: 3)
            ]
        ))

        let events = journal.events(for: coordinatorID, sinceSeq: 0, limit: 10).events
        let summaryStates = events.compactMap { event in
            event.nodes.first { $0.id == summaryID }
        }

        XCTAssertEqual(events.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(summaryStates.map(\.status), ["pending", "pending", "running", "completed"])
        XCTAssertEqual(events[1].readyNodeIDs, [summaryID])
        XCTAssertEqual(events[1].activeNodeIDs, [])
        XCTAssertEqual(events[2].readyNodeIDs, [])
        XCTAssertEqual(events[2].activeNodeIDs, [summaryID])
    }

    func testCompactMissionStatusFingerprintMovesForReadySetDeltaAndEdgeOnlyRevision() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let baseNodes = [
            CoordinatorMissionPlanNode(
                id: parentID,
                title: "Parent",
                workstreamID: workstreamID,
                executionPolicy: .freshWorktree,
                status: .pending
            ),
            CoordinatorMissionPlanNode(
                id: childID,
                title: "Child",
                workstreamID: workstreamID,
                dependsOn: [parentID],
                executionPolicy: .freshWorktree,
                status: .pending
            )
        ]
        let basePlan = CoordinatorMissionPlan(
            revision: 4,
            objective: "Watch ready set",
            status: .running,
            approvalState: .approved,
            nodes: baseNodes
        )
        let completedParentPlan = CoordinatorMissionPlan(
            revision: 5,
            objective: "Watch ready set",
            status: .running,
            approvalState: .approved,
            nodes: [
                CoordinatorMissionPlanNode(
                    id: parentID,
                    title: "Parent",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .completed
                ),
                baseNodes[1]
            ]
        )
        let noEdgePlan = CoordinatorMissionPlan(
            revision: 6,
            objective: "Watch edge-only revision",
            status: .running,
            approvalState: .approved,
            nodes: [
                baseNodes[0],
                CoordinatorMissionPlanNode(
                    id: childID,
                    title: "Child",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .pending
                )
            ]
        )
        let edgeOnlyPlan = CoordinatorMissionPlan(
            revision: 6,
            objective: "Watch edge-only revision",
            status: .running,
            approvalState: .approved,
            nodes: baseNodes
        )
        let args: [String: Value] = [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ]

        let baseFingerprint = try await compactFingerprint(
            service: makeService(coordinatorIDs: [coordinatorID], selectedID: coordinatorID, missionPlans: { [coordinatorID: basePlan] }),
            args: args
        )
        let completedFingerprint = try await compactFingerprint(
            service: makeService(coordinatorIDs: [coordinatorID], selectedID: coordinatorID, missionPlans: { [coordinatorID: completedParentPlan] }),
            args: args
        )
        let noEdgeFingerprint = try await compactFingerprint(
            service: makeService(coordinatorIDs: [coordinatorID], selectedID: coordinatorID, missionPlans: { [coordinatorID: noEdgePlan] }),
            args: args
        )
        let edgeOnlyFingerprint = try await compactFingerprint(
            service: makeService(coordinatorIDs: [coordinatorID], selectedID: coordinatorID, missionPlans: { [coordinatorID: edgeOnlyPlan] }),
            args: args
        )

        XCTAssertNotEqual(baseFingerprint, completedFingerprint)
        XCTAssertNotEqual(noEdgeFingerprint, edgeOnlyFingerprint)
    }

    func testMissionStatusCompactEligibleNodesIdleWarningMatrix() async throws {
        let coordinatorID = UUID()
        let workstreamID = UUID()
        let readyPlan = CoordinatorMissionPlan(
            objective: "Ready idle work",
            status: .running,
            approvalState: .approved,
            nodes: [
                CoordinatorMissionPlanNode(
                    title: "Ready node",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .pending
                )
            ]
        )
        let runningPlan = CoordinatorMissionPlan(
            objective: "Running work",
            status: .running,
            approvalState: .approved,
            nodes: [
                CoordinatorMissionPlanNode(
                    title: "Running node",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .running
                ),
                CoordinatorMissionPlanNode(
                    title: "Ready later node",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .pending
                )
            ]
        )
        let args: [String: Value] = [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ]

        let idleWarnings = try await compactWarnings(
            service: makeService(
                coordinatorIDs: [coordinatorID],
                selectedID: coordinatorID,
                coordinatorRunState: .completed,
                missionPlans: { [coordinatorID: readyPlan] }
            ),
            args: args
        )
        let runningNodeWarnings = try await compactWarnings(
            service: makeService(
                coordinatorIDs: [coordinatorID],
                selectedID: coordinatorID,
                coordinatorRunState: .completed,
                missionPlans: { [coordinatorID: runningPlan] }
            ),
            args: args
        )
        let checkpointActiveWarnings = try await compactWarnings(
            service: makeService(
                coordinatorIDs: [coordinatorID],
                selectedID: coordinatorID,
                coordinatorRunState: .waitingForApproval,
                missionPlans: { [coordinatorID: readyPlan] }
            ),
            args: args
        )

        XCTAssertTrue(idleWarnings.contains("eligible_nodes_idle"))
        XCTAssertFalse(runningNodeWarnings.contains("eligible_nodes_idle"))
        XCTAssertFalse(checkpointActiveWarnings.contains("eligible_nodes_idle"))
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
        XCTAssertEqual(checkpoint["checkpoint_id"]?.stringValue, "plan-approval")
        XCTAssertEqual(
            checkpoint["checkpoint_instance_id"]?.stringValue,
            "coordinator:\(coordinatorID.uuidString):plan-approval:r1"
        )
        XCTAssertTrue(labels.contains("Proceed"))
        XCTAssertTrue(labels.contains("Gather evidence"))
        XCTAssertTrue(labels.contains("Get independent critique"))
        let proceed = try XCTUnwrap(actions.first { $0["label"]?.stringValue == "Proceed" })
        XCTAssertEqual(proceed["submit_op"]?.stringValue, "submit")
        XCTAssertEqual(proceed["checkpoint_action"]?.stringValue, "proceed")
        XCTAssertEqual(
            proceed["expected_checkpoint_instance_id"]?.stringValue,
            "coordinator:\(coordinatorID.uuidString):plan-approval:r1"
        )
        let stop = try XCTUnwrap(actions.first { $0["label"]?.stringValue == "Stop" })
        XCTAssertEqual(stop["checkpoint_action"]?.stringValue, "stop")
        XCTAssertNil(stop["expected_checkpoint_instance_id"])
        XCTAssertTrue(proceed["submit_message"]?.stringValue?.contains("Approved to proceed") == true)
        XCTAssertTrue(proceed["submit_message"]?.stringValue?.contains("actor:\"director\"") == true)
        XCTAssertTrue(proceed["submit_message"]?.stringValue?.contains("Do not record user decisions") == true)
        XCTAssertTrue(proceed["submit_message"]?.stringValue?.contains("bounded Mission ledger") == true)
        XCTAssertTrue(proceed["submit_message"]?.stringValue?.contains("Auto decisions are visible and contestable") == true)
        XCTAssertTrue(proceed["mission_plan_append_guidance"]?.stringValue?.contains("actor:\"director\"") == true)
        XCTAssertTrue(proceed["mission_plan_append_guidance"]?.stringValue?.contains("overruled_decision_id") == true)
    }

    func testMissionStatusAndSubmitProjectRevisionProposalActionParity() async throws {
        let coordinatorID = UUID()
        let evidenceID = UUID()
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Ship approved work",
            status: .running,
            approvalState: .approved
        ))
        let basePlan = try XCTUnwrap(state.missionPlan)
        _ = try state.appendRevisionProposal(CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: basePlan.id,
            expectedBaseContractFingerprint: basePlan.materialContractFingerprint(),
            summary: "Change the approved workstream",
            rationale: "Continuing would be unsafe after the prerequisite changed.",
            affectedFields: ["workstreams", "done_criteria"],
            remedy: "safety_risk",
            supportingEvidenceIDs: [evidenceID],
            requestedChange: "Use the replacement prerequisite before implementation.",
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: coordinatorID,
                runtimeSessionID: coordinatorID
            )
        ))
        let plan = try XCTUnwrap(state.missionPlan)
        let proposal = try XCTUnwrap(plan.pendingRevisionProposal)
        let checkpointID = CoordinatorMissionRevisionProposalCheckpoint.instanceID(
            coordinatorSessionID: coordinatorID,
            proposal: proposal
        )
        var resolvedAction: CoordinatorMissionRevisionProposalResolutionAction?
        var resolvedProposalID: UUID?
        var resolvedContract: String?
        var resolvedCheckpoint: String?
        var resolvedGuidance: String?
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: plan] },
            resolveRevisionProposal: { sessionID, action, proposalID, contract, checkpoint, guidance in
                XCTAssertEqual(sessionID, coordinatorID)
                resolvedAction = action
                resolvedProposalID = proposalID
                resolvedContract = contract
                resolvedCheckpoint = checkpoint
                resolvedGuidance = guidance
                return .accepted
            }
        )

        let statusResponse = try await service.execute(args: [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ])
        let status = try XCTUnwrap(statusResponse.objectValue?["mission_status"]?.objectValue)
        let checkpoint = try XCTUnwrap(status["checkpoint"]?.objectValue)
        let actions = try XCTUnwrap(checkpoint["actions"]?.arrayValue?.compactMap(\.objectValue))
        let proposalStatus = try XCTUnwrap(status["revision_proposal"]?.objectValue)
        let pendingStatus = try XCTUnwrap(proposalStatus["pending"]?.objectValue)
        let currentContract = try XCTUnwrap(proposalStatus["current_contract"]?.objectValue)
        let submitHints = try XCTUnwrap(pendingStatus["submit_hints"]?.objectValue)

        XCTAssertEqual(pendingStatus["proposal_id"]?.stringValue, proposal.id.uuidString)
        XCTAssertEqual(pendingStatus["representation"]?.stringValue, "summary_only")
        XCTAssertEqual(pendingStatus["summary"]?.stringValue, proposal.summary)
        XCTAssertEqual(pendingStatus["material_fields"]?.arrayValue?.compactMap(\.stringValue), proposal.affectedFields)
        XCTAssertEqual(pendingStatus["checkpoint_instance_id"]?.stringValue, checkpointID)
        XCTAssertEqual(submitHints["expected_contract_fingerprint"]?.stringValue, proposal.baseContractFingerprint)
        XCTAssertEqual(currentContract["plan_id"]?.stringValue, plan.id.uuidString)
        XCTAssertEqual(proposalStatus["history"]?.arrayValue?.count, 1)
        XCTAssertEqual(
            proposalStatus["held_child_questions"]?.objectValue?["reason"]?.stringValue,
            CoordinatorMissionRevisionProposalPause.heldReason
        )
        XCTAssertNil(pendingStatus["replacement_plan"])
        XCTAssertNil(pendingStatus["requested_change"])
        XCTAssertEqual(checkpoint["kind"]?.stringValue, "revision_proposal")
        XCTAssertEqual(checkpoint["checkpoint_instance_id"]?.stringValue, checkpointID)
        XCTAssertEqual(checkpoint["what_changed"]?.stringValue, proposal.summary)
        XCTAssertEqual(checkpoint["why"]?.stringValue, proposal.rationale)
        XCTAssertEqual(checkpoint["continuing_would_be"]?.stringValue, "unsafe")
        XCTAssertEqual(
            actions.compactMap { $0["label"]?.stringValue },
            ["Revise plan", "Keep current plan", "Stop Mission"]
        )
        XCTAssertFalse(String(describing: checkpoint).contains("Approve revised plan"))
        let stop = try XCTUnwrap(actions.first { $0["label"]?.stringValue == "Stop Mission" })
        XCTAssertEqual(stop["coordinator_session_id"]?.stringValue, coordinatorID.uuidString)
        XCTAssertNil(checkpoint["replacement_plan"])
        XCTAssertNil(checkpoint["replacement_diff"])

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "checkpoint_action": .string("revise_plan"),
            "proposal_id": .string(proposal.id.uuidString),
            "expected_contract_fingerprint": .string(proposal.baseContractFingerprint),
            "expected_checkpoint_instance_id": .string(checkpointID),
            "guidance": .string("Keep the scope narrow.")
        ])

        XCTAssertEqual(response.objectValue?["accepted"]?.boolValue, true)
        XCTAssertEqual(resolvedAction, .revisePlan)
        XCTAssertEqual(resolvedProposalID, proposal.id)
        XCTAssertEqual(resolvedContract, proposal.baseContractFingerprint)
        XCTAssertEqual(resolvedCheckpoint, checkpointID)
        XCTAssertEqual(resolvedGuidance, "Keep the scope narrow.")

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "coordinator_session_id": .string(coordinatorID.uuidString),
                "checkpoint_action": .string("keep_current_plan"),
                "proposal_id": .string(proposal.id.uuidString),
                "expected_contract_fingerprint": .string(proposal.baseContractFingerprint),
                "expected_checkpoint_instance_id": .string(checkpointID),
                "message": .string("This must not be silently ignored.")
            ])
            XCTFail("Expected proposal action payload rejection.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("does not deliver message"))
        }
    }

    func testProposalAppendAndResolutionMoveStatusWaitAndJournalFingerprintsWithoutPlanRevision() async throws {
        let coordinatorID = UUID()
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 7,
            objective: "Observe proposal lifecycle",
            status: .running,
            approvalState: .approved
        ))
        var currentPlan = try XCTUnwrap(state.missionPlan)
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: currentPlan] }
        )
        let statusArgs: [String: Value] = [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ]
        let initial = try await service.execute(args: statusArgs)
        let initialFingerprint = try XCTUnwrap(
            initial.objectValue?["mission_status"]?.objectValue?["fingerprint"]?.stringValue
        )

        let base = try XCTUnwrap(state.missionPlan)
        let appended = try state.appendRevisionProposal(
            CoordinatorMissionRevisionProposalRequest(
                expectedBasePlanID: base.id,
                expectedBaseContractFingerprint: base.materialContractFingerprint(),
                summary: "Change the objective",
                affectedFields: ["objective"],
                remedy: "revise_scope",
                requestedChange: "Change the objective.",
                actor: CoordinatorMissionRevisionProposalActor(
                    coordinatorSessionID: coordinatorID,
                    runtimeSessionID: coordinatorID
                )
            )
        )
        currentPlan = try XCTUnwrap(state.missionPlan)
        currentPlan.revision = 7

        let waitAfterAppend = try await service.execute(args: [
            "op": .string("wait_for_update"),
            "since_fingerprint": .string(initialFingerprint),
            "timeout_seconds": .int(0)
        ])
        let appendStatus = try XCTUnwrap(waitAfterAppend.objectValue?["mission_status"]?.objectValue)
        let appendFingerprint = try XCTUnwrap(appendStatus["fingerprint"]?.stringValue)
        XCTAssertEqual(waitAfterAppend.objectValue?["changed"]?.boolValue, true)
        XCTAssertNotEqual(appendFingerprint, initialFingerprint)
        XCTAssertEqual(
            appendStatus["revision_proposal"]?.objectValue?["pending"]?.objectValue?["proposal_id"]?.stringValue,
            appended.proposalID.uuidString
        )

        let journal = CoordinatorMissionEventJournal(capacity: 8)
        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .running,
            missionPlans: [coordinatorID: currentPlan]
        ))
        let proposal = try XCTUnwrap(state.missionPlan?.pendingRevisionProposal)
        let checkpointInstanceID = CoordinatorMissionRevisionProposalCheckpoint.instanceID(
            coordinatorSessionID: coordinatorID,
            proposal: proposal
        )
        let resolution = try state.resolveRevisionProposalTransaction(
            CoordinatorMissionRevisionProposalTrustedResolutionRequest(
                coordinatorSessionID: coordinatorID,
                action: .keepCurrentPlan,
                proposalID: appended.proposalID,
                expectedContractFingerprint: proposal.baseContractFingerprint,
                expectedCheckpointInstanceID: checkpointInstanceID
            )
        )
        currentPlan = try XCTUnwrap(state.missionPlan)
        currentPlan.revision = 7
        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .running,
            missionPlans: [coordinatorID: currentPlan]
        ))

        let waitAfterResolution = try await service.execute(args: [
            "op": .string("wait_for_update"),
            "since_fingerprint": .string(appendFingerprint),
            "timeout_seconds": .int(0)
        ])
        let resolvedStatus = try XCTUnwrap(waitAfterResolution.objectValue?["mission_status"]?.objectValue)
        let resolvedFingerprint = try XCTUnwrap(resolvedStatus["fingerprint"]?.stringValue)
        let proposalStatus = try XCTUnwrap(resolvedStatus["revision_proposal"]?.objectValue)
        let recentResolution = try XCTUnwrap(proposalStatus["recent_resolution"]?.objectValue)
        XCTAssertEqual(waitAfterResolution.objectValue?["changed"]?.boolValue, true)
        XCTAssertNotEqual(resolvedFingerprint, appendFingerprint)
        XCTAssertEqual(recentResolution["outcome"]?.stringValue, "rejected")
        XCTAssertNotNil(proposalStatus["durability_hold"]?.objectValue)
        XCTAssertNil(proposalStatus["pending"]?.objectValue)

        XCTAssertTrue(state.clearRevisionProposalDurabilityHold(transactionID: resolution.resolutionID))
        currentPlan = try XCTUnwrap(state.missionPlan)
        currentPlan.revision = 7
        journal.record(snapshot: Self.snapshot(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            coordinatorRunState: .running,
            missionPlans: [coordinatorID: currentPlan]
        ))
        let waitAfterHoldClear = try await service.execute(args: [
            "op": .string("wait_for_update"),
            "since_fingerprint": .string(resolvedFingerprint),
            "timeout_seconds": .int(0)
        ])
        let releasedStatus = try XCTUnwrap(waitAfterHoldClear.objectValue?["mission_status"]?.objectValue)
        XCTAssertEqual(waitAfterHoldClear.objectValue?["changed"]?.boolValue, true)
        XCTAssertNil(releasedStatus["revision_proposal"]?.objectValue?["durability_hold"]?.objectValue)
        XCTAssertEqual(
            releasedStatus["revision_proposal"]?.objectValue?["held_child_questions"]?.objectValue?["held"]?.boolValue,
            false
        )

        let journalEvents = journal.events(for: coordinatorID, sinceSeq: 0, limit: 8).events
        XCTAssertEqual(journalEvents.count, 3)
        XCTAssertNotEqual(journalEvents[0].fingerprint, journalEvents[1].fingerprint)
        XCTAssertNotEqual(journalEvents[1].fingerprint, journalEvents[2].fingerprint)
        XCTAssertEqual(journalEvents[0].pendingRevisionProposalID, appended.proposalID)
        XCTAssertNil(journalEvents[1].pendingRevisionProposalID)
        XCTAssertEqual(journalEvents[1].recentRevisionProposalResolutionOutcome, "rejected")
    }

    func testRevisionProposalSubmitRequiresAllIdentities() async throws {
        let coordinatorID = UUID()
        var didResolve = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            resolveRevisionProposal: { _, _, _, _, _, _ in
                didResolve = true
                return .accepted
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "coordinator_session_id": .string(coordinatorID.uuidString),
                "checkpoint_action": .string("keep_current_plan")
            ])
            XCTFail("Expected missing proposal identity rejection.")
        } catch {
            XCTAssertFalse(didResolve)
            XCTAssertTrue(String(describing: error).contains("proposal_id is required"))
        }
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

    func testWaitForUpdateAdvancesAfterDecisionAndEvidenceAppendWithoutRevisionChange() async throws {
        let coordinatorID = UUID()
        var plan = CoordinatorMissionPlan(
            revision: 7,
            objective: "Watch ledger appends",
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

        plan.decisions.append(CoordinatorMissionDecisionRecord(
            decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
            actor: .director,
            label: "continued after evidence met bar",
            timestamp: Date(timeIntervalSince1970: 10)
        ))
        plan.evidence.append(CoordinatorMissionEvidenceRecord(
            verdict: .meets,
            summary: "Focused validation passed.",
            timestamp: Date(timeIntervalSince1970: 11)
        ))

        let response = try await service.execute(args: [
            "op": .string("wait_for_update"),
            "since_fingerprint": .string(fingerprint),
            "timeout_seconds": .int(0)
        ])
        let object = try XCTUnwrap(response.objectValue)
        let status = try XCTUnwrap(object["mission_status"]?.objectValue)

        XCTAssertEqual(object["changed"]?.boolValue, true)
        XCTAssertEqual(object["timed_out"]?.boolValue, false)
        XCTAssertNotEqual(status["fingerprint"]?.stringValue, fingerprint)
        XCTAssertEqual(status["decision_counts_by_actor"]?.objectValue?["director"]?.intValue, 1)
        XCTAssertEqual(status["evidence_counts"]?.objectValue?["meets"]?.intValue, 1)
    }

    func testCompactMissionStatusFingerprintChangesForDirectorDoctrineFields() async throws {
        let coordinatorID = UUID()
        let decisionID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000001"))
        let evidenceID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000002"))
        let basePlan = CoordinatorMissionPlan(
            revision: 7,
            objective: "Watch Director doctrine fields",
            status: .running,
            approvalState: .approved,
            policySnapshot: CoordinatorMissionPolicySnapshot(
                id: "director-default",
                name: "Director default",
                defaultPace: .auto,
                maxConcurrent: 3
            ),
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: decisionID,
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "continued after evidence",
                    timestamp: Date(timeIntervalSince1970: 10),
                    correctionReason: "Initial correction reason."
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: evidenceID,
                    verdict: .meets,
                    summary: "Evidence summary.",
                    timestamp: Date(timeIntervalSince1970: 11),
                    judgmentBundle: CoordinatorMissionJudgmentBundle(
                        doneCriteria: "Focused test passes.",
                        structuredEvidence: "Initial structured evidence."
                    )
                )
            ]
        )
        let updatedPlan = CoordinatorMissionPlan(
            id: basePlan.id,
            revision: basePlan.revision,
            objective: basePlan.objective,
            status: basePlan.status,
            approvalState: basePlan.approvalState,
            policySnapshot: CoordinatorMissionPolicySnapshot(
                id: "director-default",
                name: "Director default",
                defaultPace: .auto,
                maxConcurrent: 4
            ),
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: decisionID,
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "continued after evidence",
                    timestamp: Date(timeIntervalSince1970: 10),
                    correctionReason: "Updated correction reason."
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: evidenceID,
                    verdict: .meets,
                    summary: "Evidence summary.",
                    timestamp: Date(timeIntervalSince1970: 11),
                    judgmentBundle: CoordinatorMissionJudgmentBundle(
                        doneCriteria: "Focused test passes.",
                        structuredEvidence: "Updated structured evidence."
                    )
                )
            ],
            updatedAt: basePlan.updatedAt
        )
        let baseService = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: basePlan] }
        )
        let updatedService = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: updatedPlan] }
        )
        let args: [String: Value] = [
            "op": .string("mission_status"),
            "compact": .bool(true)
        ]

        let base = try await baseService.execute(args: args)
        let updated = try await updatedService.execute(args: args)
        let baseFingerprint = try XCTUnwrap(base.objectValue?["mission_status"]?.objectValue?["fingerprint"]?.stringValue)
        let updatedFingerprint = try XCTUnwrap(updated.objectValue?["mission_status"]?.objectValue?["fingerprint"]?.stringValue)

        XCTAssertNotEqual(baseFingerprint, updatedFingerprint)
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
            startNew: { _ in startNewCount += 1 },
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

    func testSubmitWithCheckpointActionRejectsCoordinatorRuntimeCaller() async throws {
        let coordinatorID = UUID()
        let plan = Self.approvalPlan(coordinatorID: coordinatorID, revision: 2)
        var submittedActions: [CoordinatorModeViewModel.ContinuationAction] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex-runtime",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .coordinator,
                    isCoordinatorRuntime: true
                )
            },
            resolveRuntimeCoordinatorSessionID: { metadata in
                metadata.isCoordinatorRuntime ? coordinatorID : nil
            },
            submitContinuation: { action, _ in
                submittedActions.append(action)
                return .accepted
            },
            missionPlans: { [coordinatorID: plan] }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "coordinator_session_id": .string(coordinatorID.uuidString),
                "checkpoint_action": .string("proceed"),
                "expected_checkpoint_instance_id": .string("coordinator:\(coordinatorID.uuidString):plan-approval:r2")
            ])
            XCTFail("Coordinator runtime callers must not submit checkpoint actions as the user.")
        } catch {
            XCTAssertTrue(submittedActions.isEmpty)
            let message = String(describing: error)
            XCTAssertTrue(message.contains("submit Coordinator checkpoint actions"), message)
        }
    }

    func testSubmitWithCheckpointActionRejectsMissingExpectedCheckpointInstance() async throws {
        let coordinatorID = UUID()
        let plan = Self.approvalPlan(coordinatorID: coordinatorID, revision: 2)
        var submittedActions: [CoordinatorModeViewModel.ContinuationAction] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submitContinuation: { action, _ in
                submittedActions.append(action)
                return .accepted
            },
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "checkpoint_action": .string("proceed"),
            "compact": .bool(true)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertTrue(submittedActions.isEmpty)
        XCTAssertEqual(object["accepted"]?.boolValue, false)
        let error = try XCTUnwrap(object["error"]?.stringValue)
        XCTAssertTrue(error.contains("expected_checkpoint_instance_id is required"), error)
    }

    func testSubmitWithCheckpointActionRejectsStaleExpectedCheckpointInstance() async throws {
        let coordinatorID = UUID()
        let plan = Self.approvalPlan(coordinatorID: coordinatorID, revision: 2)
        var submittedActions: [CoordinatorModeViewModel.ContinuationAction] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submitContinuation: { action, _ in
                submittedActions.append(action)
                return .accepted
            },
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "checkpoint_action": .string("proceed"),
            "expected_checkpoint_instance_id": .string("coordinator:\(coordinatorID.uuidString):plan-approval:r1"),
            "compact": .bool(true)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertTrue(submittedActions.isEmpty)
        XCTAssertEqual(object["accepted"]?.boolValue, false)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator")
        let error = try XCTUnwrap(object["error"]?.stringValue)
        XCTAssertTrue(error.contains("Stale checkpoint submit rejected"), error)
        XCTAssertTrue(error.contains("plan-approval:r2"), error)
    }

    func testSubmitWithCheckpointActionAcceptsCurrentExpectedCheckpointInstance() async throws {
        let coordinatorID = UUID()
        let plan = Self.approvalPlan(coordinatorID: coordinatorID, revision: 2)
        var submittedActions: [CoordinatorModeViewModel.ContinuationAction] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submitContinuation: { action, _ in
                submittedActions.append(action)
                return .accepted
            },
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "checkpoint_action": .string("proceed"),
            "expected_checkpoint_instance_id": .string("coordinator:\(coordinatorID.uuidString):plan-approval:r2"),
            "compact": .bool(true)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(submittedActions, [.proceed])
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator")
    }

    func testSubmitWithStopCheckpointActionAcceptsStaleExpectedCheckpointInstance() async throws {
        let coordinatorID = UUID()
        let plan = Self.approvalPlan(coordinatorID: coordinatorID, revision: 2)
        var submittedActions: [CoordinatorModeViewModel.ContinuationAction] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submitContinuation: { action, _ in
                submittedActions.append(action)
                return .accepted
            },
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "checkpoint_action": .string("stop"),
            "expected_checkpoint_instance_id": .string("coordinator:\(coordinatorID.uuidString):plan-approval:r1"),
            "compact": .bool(true)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(submittedActions, [.stopHere])
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator")
    }

    func testSubmitWithCheckpointActionDoesNotAnswerPendingChildInteraction() async throws {
        let coordinatorID = UUID()
        let plan = Self.approvalPlan(coordinatorID: coordinatorID, revision: 2)
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var submittedActions: [CoordinatorModeViewModel.ContinuationAction] = []
        var childResponses: [CoordinatorModeViewModel.ChildInteractionResponseSubmission] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submitContinuation: { action, _ in
                submittedActions.append(action)
                return .accepted
            },
            pendingChild: { _ in childRow },
            submitPendingChild: { submission, _, _ in
                childResponses.append(submission)
                return .accepted
            },
            missionPlans: { [coordinatorID: plan] }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "checkpoint_action": .string("proceed"),
            "expected_checkpoint_instance_id": .string("coordinator:\(coordinatorID.uuidString):plan-approval:r2"),
            "message": .string("Approved to proceed with the plan."),
            "compact": .bool(true)
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(submittedActions, [.proceed])
        XCTAssertTrue(childResponses.isEmpty)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "coordinator")
    }

    func testSubmitRoutesToPendingChildInteractionWhenSelectedCoordinatorNeedsInput() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var coordinatorSubmissions: [String] = []
        var childResponses: [(submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission, rowID: UUID, actor: CoordinatorMissionDecisionActor)] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submit: {
                coordinatorSubmissions.append($0)
                return .accepted
            },
            pendingChild: { _ in childRow },
            submitPendingChild: { submission, row, actor in
                childResponses.append((submission, row.sessionID, actor))
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
        XCTAssertEqual(childResponses.first?.actor, .user)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "child_interaction")
    }

    func testSubmitRuntimePendingChildInteractionRecordsDirectorActor() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        var actors: [CoordinatorMissionDecisionActor] = []
        let plan = Self.durablyApprovedPlan(
            CoordinatorMissionPlan(
                objective: "Director-routed child question.",
                status: .running,
                approvalState: .approved,
                policySnapshot: .defaultPolicy,
                autonomy: autonomy
            ),
            coordinatorID: coordinatorID
        )
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
            resolveRuntimeCoordinatorSessionID: { metadata in
                metadata.isCoordinatorRuntime ? coordinatorID : nil
            },
            pendingChild: { _ in childRow },
            submitPendingChild: { _, _, actor in
                actors.append(actor)
                return .accepted
            },
            missionPlans: { [coordinatorID: plan] },
            durableApprovalAuthorityToken: { _ in plan.expectedDurableApprovalAuthorityToken }
        )

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "message": .string("Alpha")
        ])
        let object = try XCTUnwrap(response.objectValue)

        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["routed_to"]?.stringValue, "child_interaction")
        XCTAssertEqual(actors, [.director])
    }

    func testSubmitRuntimePendingChildInteractionRequiresDurableApprovalAuthority() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        var didSubmitChild = false
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
            resolveRuntimeCoordinatorSessionID: { metadata in
                metadata.isCoordinatorRuntime ? coordinatorID : nil
            },
            pendingChild: { _ in childRow },
            submitPendingChild: { _, _, _ in
                didSubmitChild = true
                return .accepted
            },
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "Director-routed child question.",
                    status: .running,
                    approvalState: .approved,
                    policySnapshot: .defaultPolicy,
                    autonomy: autonomy
                )]
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "message": .string("Alpha")
            ])
            XCTFail("Runtime child answer should require durable approval authority after approval.")
        } catch {
            XCTAssertFalse(didSubmitChild)
            XCTAssertTrue(String(describing: error).contains("durable approval authority token"))
        }
    }

    func testCoordinatorModelOverrideKeepsRuntimeChildAnswerAttribution() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var requestMetadata = MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: "external", windowID: 1)
        var requestedCoordinatorModels: [String?] = []
        var submittedDirectives: [String] = []
        var actors: [CoordinatorMissionDecisionActor] = []
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        let plan = Self.durablyApprovedPlan(
            CoordinatorMissionPlan(
                objective: "Director-routed child question.",
                status: .running,
                approvalState: .approved,
                policySnapshot: .defaultPolicy,
                autonomy: autonomy
            ),
            coordinatorID: coordinatorID
        )
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: { requestMetadata },
            resolveRuntimeCoordinatorSessionID: { metadata in
                metadata.isCoordinatorRuntime ? coordinatorID : nil
            },
            startNew: { requestedCoordinatorModels.append($0) },
            submit: { message in
                submittedDirectives.append(message)
                return .accepted
            },
            pendingChild: { _ in childRow },
            submitPendingChild: { _, _, actor in
                actors.append(actor)
                return .accepted
            },
            missionPlans: { [coordinatorID: plan] },
            durableApprovalAuthorityToken: { _ in plan.expectedDurableApprovalAuthorityToken }
        )

        let startResponse = try await service.execute(args: [
            "op": .string("start_mission"),
            "message": .string("Use the cheap Coordinator regression tier."),
            "coordinator_model_id": .string("engineer")
        ])
        let startObject = try XCTUnwrap(startResponse.objectValue)
        XCTAssertEqual(startObject["accepted"]?.boolValue, true)
        XCTAssertEqual(requestedCoordinatorModels, ["engineer"])
        XCTAssertEqual(submittedDirectives, ["Use the cheap Coordinator regression tier."])

        requestMetadata = MCPServerViewModel.RequestMetadata(
            connectionID: UUID(),
            clientName: "codex",
            windowID: 1,
            runPurpose: .agentModeRun,
            taskLabelKind: .coordinator,
            isCoordinatorRuntime: true
        )
        let answerResponse = try await service.execute(args: [
            "op": .string("submit"),
            "message": .string("Alpha")
        ])
        let answerObject = try XCTUnwrap(answerResponse.objectValue)

        XCTAssertEqual(answerObject["accepted"]?.boolValue, true)
        XCTAssertEqual(answerObject["routed_to"]?.stringValue, "child_interaction")
        XCTAssertEqual(actors, [.director])
    }

    func testSubmitExternalDirectiveResumesOnlyAcceptedRevisionDraftingWhileChildQuestionsStayHeld() async throws {
        let coordinatorID = UUID()
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Replace the approved contract.",
            status: .running,
            approvalState: .approved
        ))
        let basePlan = try XCTUnwrap(state.missionPlan)
        let appended = try state.appendRevisionProposal(CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: basePlan.id,
            expectedBaseContractFingerprint: basePlan.materialContractFingerprint(),
            summary: "Draft a concrete replacement",
            affectedFields: ["objective"],
            remedy: "revise_scope",
            requestedChange: "Draft a concrete replacement.",
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: coordinatorID,
                runtimeSessionID: coordinatorID
            )
        ))
        let proposal = try XCTUnwrap(state.missionPlan?.pendingRevisionProposal)
        let resolution = try state.resolveRevisionProposalTransaction(
            CoordinatorMissionRevisionProposalTrustedResolutionRequest(
                coordinatorSessionID: coordinatorID,
                action: .revisePlan,
                proposalID: appended.proposalID,
                expectedContractFingerprint: proposal.baseContractFingerprint,
                expectedCheckpointInstanceID: CoordinatorMissionRevisionProposalCheckpoint.instanceID(
                    coordinatorSessionID: coordinatorID,
                    proposal: proposal
                )
            )
        )
        XCTAssertTrue(state.clearRevisionProposalDurabilityHold(transactionID: resolution.resolutionID))
        XCTAssertEqual(state.missionPlan?.approvalState, .revisionRequested)
        XCTAssertNil(state.missionPlan?.pendingRevisionProposal)
        XCTAssertNil(state.missionPlan?.revisionProposalDurabilityHold)
        XCTAssertTrue(state.missionPlan?.holdsChildInteractionsForRevisionProposal == true)
        XCTAssertEqual(
            state.missionPlan?.acceptedRevisionDraftingResolution?.id,
            resolution.resolutionID
        )

        var genericDirectiveSubmitted = false
        var draftingSubmissions: [(String, UUID, UUID)] = []
        let otherCoordinatorID = UUID()
        var selectedID = coordinatorID
        var projectedPlans = try [
            coordinatorID: XCTUnwrap(state.missionPlan),
            otherCoordinatorID: CoordinatorMissionPlan(status: .running, approvalState: .approved)
        ]
        let service = makeService(
            coordinatorIDs: [coordinatorID, otherCoordinatorID],
            selectedID: { selectedID },
            select: { selectedID = $0 ?? selectedID },
            submit: { _ in
                genericDirectiveSubmitted = true
                return .accepted
            },
            revisionProposalAuthorityPlan: { sessionID in
                sessionID == coordinatorID ? state.missionPlan : nil
            },
            submitAcceptedRevisionDraftingDirective: { message, sessionID, resolutionID in
                draftingSubmissions.append((message, sessionID, resolutionID))
                return .accepted
            },
            pendingChild: { _ in nil },
            missionPlans: { projectedPlans }
        )

        let statusResponse = try await service.execute(args: [
            "op": .string("mission_status"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "compact": .bool(true)
        ])
        let proposalStatus = try XCTUnwrap(
            statusResponse.objectValue?["mission_status"]?.objectValue?["revision_proposal"]?.objectValue
        )
        XCTAssertNil(proposalStatus["pending"]?.objectValue)
        XCTAssertNil(proposalStatus["durability_hold"]?.objectValue)
        XCTAssertEqual(
            proposalStatus["recent_resolution"]?.objectValue?["outcome"]?.stringValue,
            "accepted_for_concrete_revision"
        )
        XCTAssertEqual(
            proposalStatus["held_child_questions"]?.objectValue?["held"]?.boolValue,
            true
        )
        XCTAssertEqual(
            proposalStatus["held_child_questions"]?.objectValue?["reason"]?.stringValue,
            CoordinatorMissionRevisionProposalPause.heldReason
        )

        selectedID = otherCoordinatorID
        projectedPlans[coordinatorID] = nil

        let response = try await service.execute(args: [
            "op": .string("submit"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "message": .string("Continue drafting the concrete revised plan.")
        ])
        XCTAssertEqual(response.objectValue?["accepted"]?.boolValue, true)
        XCTAssertEqual(response.objectValue?["routed_to"]?.stringValue, "coordinator")
        XCTAssertFalse(genericDirectiveSubmitted)
        XCTAssertEqual(draftingSubmissions.map(\.0), ["Continue drafting the concrete revised plan."])
        XCTAssertEqual(draftingSubmissions.map(\.1), [coordinatorID])
        XCTAssertEqual(draftingSubmissions.map(\.2), [resolution.resolutionID])
        XCTAssertEqual(selectedID, otherCoordinatorID)

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "coordinator_session_id": .string(coordinatorID.uuidString),
                "answers": .array([.string("Do not deliver this held child answer.")])
            ])
            XCTFail("Accepted revision drafting must keep child answers held.")
        } catch {
            XCTAssertTrue(String(describing: error).contains(CoordinatorMissionRevisionProposalPause.heldReason))
            XCTAssertEqual(draftingSubmissions.count, 1)
        }

        state.missionPlan?.approvalState = .awaitingApproval
        XCTAssertNil(state.missionPlan?.acceptedRevisionDraftingResolution)
        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "coordinator_session_id": .string(coordinatorID.uuidString),
                "message": .string("Bypass revised-plan approval.")
            ])
            XCTFail("Generic directives must not bypass revised-plan approval.")
        } catch {
            XCTAssertTrue(String(describing: error).contains(CoordinatorMissionRevisionProposalPause.heldReason))
            XCTAssertFalse(genericDirectiveSubmitted)
            XCTAssertEqual(draftingSubmissions.count, 1)
        }
    }

    func testSubmitExternalAnswerCannotFallThroughToCoordinatorDirectiveDuringProposalHold() async throws {
        let coordinatorID = UUID()
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Hold child answers.",
            status: .running,
            approvalState: .approved
        ))
        let plan = try XCTUnwrap(state.missionPlan)
        _ = try state.appendRevisionProposal(CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: plan.id,
            expectedBaseContractFingerprint: plan.materialContractFingerprint(),
            summary: "Revise child direction",
            affectedFields: ["objective"],
            remedy: "revise_scope",
            supportingEvidenceIDs: [],
            requestedChange: "Revise child direction.",
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: coordinatorID,
                runtimeSessionID: coordinatorID
            )
        ))
        var didSubmitDirective = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            submit: { _ in
                didSubmitDirective = true
                return .accepted
            },
            pendingChild: { _ in nil },
            missionPlans: { [coordinatorID: state.missionPlan!] }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "message": .string("Do not reroute this held answer.")
            ])
            XCTFail("Held child answer must not fall through to a Coordinator directive.")
        } catch {
            XCTAssertFalse(didSubmitDirective)
            XCTAssertTrue(String(describing: error).contains(CoordinatorMissionRevisionProposalPause.heldReason))
        }
    }

    func testSubmitRuntimePendingChildInteractionRejectsPendingRevisionProposalWithoutAnswerRecord() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        var state = CoordinatorFollowThroughState(missionPlan: Self.durablyApprovedPlan(
            CoordinatorMissionPlan(
                objective: "Director-routed child question.",
                status: .running,
                approvalState: .approved,
                autonomy: autonomy
            ),
            coordinatorID: coordinatorID
        ))
        let plan = try XCTUnwrap(state.missionPlan)
        _ = try state.appendRevisionProposal(CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: plan.id,
            expectedBaseContractFingerprint: plan.materialContractFingerprint(),
            summary: "Revise child direction",
            affectedFields: ["objective"],
            remedy: "revise_scope",
            supportingEvidenceIDs: [],
            requestedChange: "Revise child direction.",
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: coordinatorID,
                runtimeSessionID: coordinatorID
            )
        ))
        var didSubmitChild = false
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
            resolveRuntimeCoordinatorSessionID: { _ in coordinatorID },
            pendingChild: { _ in childRow },
            submitPendingChild: { _, _, _ in
                didSubmitChild = true
                return .accepted
            },
            missionPlans: { [coordinatorID: state.missionPlan!] },
            durableApprovalAuthorityToken: { _ in state.missionPlan?.expectedDurableApprovalAuthorityToken }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "message": .string("Do not record this answer.")
            ])
            XCTFail("Pending revision proposal must block childAsk:auto answers.")
        } catch {
            XCTAssertFalse(didSubmitChild)
            XCTAssertTrue(String(describing: error).contains(CoordinatorMissionRevisionProposalPause.heldReason))
            XCTAssertEqual(state.missionPlan?.decisions, [])
            XCTAssertEqual(state.missionPlan?.evidence, [])
        }
    }

    func testSubmitRuntimePendingChildInteractionRejectsWhenChildAskRoutesToMe() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var didSubmitChild = false
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
            resolveRuntimeCoordinatorSessionID: { metadata in
                metadata.isCoordinatorRuntime ? coordinatorID : nil
            },
            pendingChild: { _ in childRow },
            submitPendingChild: { _, _, _ in
                didSubmitChild = true
                return .accepted
            },
            missionPlans: {
                [coordinatorID: CoordinatorMissionPlan(
                    objective: "User-routed child question.",
                    status: .running,
                    approvalState: .approved,
                    policySnapshot: .defaultPolicy
                )]
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "message": .string("Alpha")
            ])
            XCTFail("Coordinator runtime must not answer child questions while childAsk routes to Me.")
        } catch {
            XCTAssertFalse(didSubmitChild)
            XCTAssertTrue(String(describing: error).contains("routes child questions to Me"))
        }
    }

    func testSubmitAgentModeNonCoordinatorPendingChildInteractionCannotImpersonateUser() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var actors: [CoordinatorMissionDecisionActor] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "codex",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .pair,
                    isCoordinatorRuntime: false
                )
            },
            pendingChild: { _ in childRow },
            submitPendingChild: { _, _, actor in
                actors.append(actor)
                return .accepted
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("submit"),
                "message": .string("Alpha")
            ])
            XCTFail("Non-Coordinator Agent Mode workers must not answer child questions as user.")
        } catch {
            XCTAssertTrue(actors.isEmpty)
            XCTAssertTrue(String(describing: error).contains("Internal non-owner Agent Mode workers cannot submit"))
        }
    }

    func testSubmitRoutesStructuredAnswersToPendingChildInteraction() async throws {
        let coordinatorID = UUID()
        let childRow = Self.pendingChildRow(parentCoordinatorID: coordinatorID)
        var childResponses: [CoordinatorModeViewModel.ChildInteractionResponseSubmission] = []
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            pendingChild: { _ in childRow },
            submitPendingChild: { submission, _, _ in
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
            startNew: { _ in startNewCount += 1 },
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

    func testAgentModeChildrenAdvertiseStructuredUserInput() {
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.askUser,
            taskLabelKind: .explore
        ))
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: MCPWindowToolName.askUser,
            taskLabelKind: .pair
        ))
        XCTAssertTrue(AgentModeMCPToolPolicy.grantedTools(forAgent: .codexExec).contains(MCPWindowToolName.askUser))
    }

    func testProposeRevisionRoutesOwningRuntimeThroughDedicatedPersistedCallback() async throws {
        let coordinatorID = UUID()
        let evidenceID = UUID()
        let basePlan = CoordinatorMissionPlan(
            objective: "Implement approved work.",
            status: .running,
            approvalState: .approved
        )
        let baseFingerprint = try basePlan.materialContractFingerprint()
        var missionPlans = [coordinatorID: basePlan]
        var callbackCount = 0
        var persisted = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: { Self.coordinatorRuntimeMetadata() },
            resolveRuntimeCoordinatorSessionID: { _ in coordinatorID },
            missionPlans: { missionPlans },
            appendRevisionProposal: { sessionID, request in
                XCTAssertEqual(sessionID, coordinatorID)
                XCTAssertFalse(persisted)
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                let result = try state.appendRevisionProposal(request, filedAt: Date(timeIntervalSince1970: 10))
                missionPlans[sessionID] = state.missionPlan
                callbackCount += 1
                persisted = true
                return result
            }
        )

        let response = try await service.execute(args: proposalArgs(
            coordinatorID: coordinatorID,
            plan: basePlan,
            fingerprint: baseFingerprint,
            evidenceIDs: [evidenceID],
            requestedChange: "  Expand   the approved scope. "
        ))
        let object = try XCTUnwrap(response.objectValue)
        let proposal = try XCTUnwrap(missionPlans[coordinatorID]?.pendingRevisionProposal)

        XCTAssertTrue(persisted)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(object["accepted"]?.boolValue, true)
        XCTAssertEqual(object["persisted"]?.boolValue, true)
        XCTAssertEqual(object["proposal_id"]?.stringValue, proposal.id.uuidString)
        XCTAssertEqual(proposal.requestedChange.value, "Expand the approved scope.")
        XCTAssertFalse(proposal.canonicalRequestIdentity.isEmpty)
        XCTAssertEqual(proposal.actor.coordinatorSessionID, coordinatorID)
        XCTAssertEqual(proposal.actor.runtimeSessionID, coordinatorID)
        XCTAssertEqual(proposal.supportingEvidenceIDs, [evidenceID])
        XCTAssertEqual(missionPlans[coordinatorID]?.decisions, [])
        XCTAssertEqual(missionPlans[coordinatorID]?.revisionProposalResolutions, [])
        XCTAssertEqual(
            missionPlans[coordinatorID]?.events.count(where: { $0.kind == .revisionProposalFiled }),
            1
        )
        XCTAssertEqual(try missionPlans[coordinatorID]?.materialContractFingerprint(), baseFingerprint)
    }

    func testMissionPlanMCPRejectsAdvancementWhileRevisionProposalIsPending() async throws {
        let coordinatorID = UUID()
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Implement approved work.",
            status: .running,
            approvalState: .approved
        ))
        let plan = try XCTUnwrap(state.missionPlan)
        _ = try state.appendRevisionProposal(CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: plan.id,
            expectedBaseContractFingerprint: plan.materialContractFingerprint(),
            summary: "Revise approved work",
            affectedFields: ["objective"],
            remedy: "revise_scope",
            supportingEvidenceIDs: [],
            requestedChange: "Revise approved work.",
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: coordinatorID,
                runtimeSessionID: coordinatorID
            )
        ))
        var didUpdate = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            missionPlans: { [coordinatorID: state.missionPlan!] },
            updateMissionPlan: { _, _ in didUpdate = true }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("mission_plan"),
                "status": .string("approved")
            ])
            XCTFail("Pending proposal must block Mission Plan advancement.")
        } catch {
            XCTAssertFalse(didUpdate)
            let message = String(describing: error)
            XCTAssertTrue(message.contains(CoordinatorMissionRevisionProposalPause.heldReason), message)
        }
    }

    func testProposeRevisionExactRetryUsesServerDerivedIdentityAndExistingProposalID() async throws {
        let coordinatorID = UUID()
        let basePlan = CoordinatorMissionPlan(
            objective: "Implement approved work.",
            status: .running,
            approvalState: .approved
        )
        let fingerprint = try basePlan.materialContractFingerprint()
        var missionPlans = [coordinatorID: basePlan]
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: { Self.coordinatorRuntimeMetadata() },
            resolveRuntimeCoordinatorSessionID: { _ in coordinatorID },
            missionPlans: { missionPlans },
            appendRevisionProposal: { sessionID, request in
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                let result = try state.appendRevisionProposal(request)
                missionPlans[sessionID] = state.missionPlan
                return result
            }
        )

        let first = try await service.execute(args: proposalArgs(
            coordinatorID: coordinatorID,
            plan: basePlan,
            fingerprint: fingerprint,
            summary: "First summary",
            requestedChange: "Cafe\u{301} needs a wider scope."
        ))
        let retry = try await service.execute(args: proposalArgs(
            coordinatorID: coordinatorID,
            plan: basePlan,
            fingerprint: fingerprint,
            summary: "Retry summary",
            requestedChange: "  Café   needs a wider scope. "
        ))

        XCTAssertEqual(first.objectValue?["proposal_id"]?.stringValue, retry.objectValue?["proposal_id"]?.stringValue)
        XCTAssertEqual(retry.objectValue?["existing_pending_retry"]?.boolValue, true)
        XCTAssertEqual(missionPlans[coordinatorID]?.revisionProposals.count, 1)
        XCTAssertEqual(
            missionPlans[coordinatorID]?.events.count(where: { $0.kind == .revisionProposalFiled }),
            1
        )
    }

    func testProposeRevisionRejectsExternalMissingIdentityAndInternalNonOwnerCallers() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(objective: "Approved", status: .running, approvalState: .approved)
        let fingerprint = try plan.materialContractFingerprint()
        let callers: [(MCPServerViewModel.RequestMetadata, UUID?)] = [
            (MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: "cli", windowID: 1), nil),
            (Self.coordinatorRuntimeMetadata(), nil),
            (
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "worker",
                    windowID: 1,
                    runPurpose: .agentModeRun,
                    taskLabelKind: .engineer,
                    isCoordinatorRuntime: false
                ),
                nil
            )
        ]

        for (metadata, resolvedID) in callers {
            var didAppend = false
            let service = makeService(
                coordinatorIDs: [coordinatorID],
                selectedID: coordinatorID,
                captureRequestMetadata: { metadata },
                resolveRuntimeCoordinatorSessionID: { _ in resolvedID },
                missionPlans: { [coordinatorID: plan] },
                appendRevisionProposal: { _, _ in
                    didAppend = true
                    throw MCPError.invalidParams("unexpected append")
                }
            )
            await assertThrowsAsync {
                try await service.execute(args: proposalArgs(
                    coordinatorID: coordinatorID,
                    plan: plan,
                    fingerprint: fingerprint
                ))
            }
            XCTAssertFalse(didAppend)
        }
    }

    func testProposeRevisionRejectsCrossMissionWithoutSelectedMissionFallback() async {
        let ownerID = UUID()
        let selectedID = UUID()
        let ownerPlan = CoordinatorMissionPlan(objective: "Owner", status: .running, approvalState: .approved)
        let selectedPlan = CoordinatorMissionPlan(objective: "Selected", status: .running, approvalState: .approved)
        var didAppend = false
        let service = makeService(
            coordinatorIDs: [ownerID, selectedID],
            selectedID: selectedID,
            captureRequestMetadata: { Self.coordinatorRuntimeMetadata() },
            resolveRuntimeCoordinatorSessionID: { _ in ownerID },
            missionPlans: { [ownerID: ownerPlan, selectedID: selectedPlan] },
            appendRevisionProposal: { _, _ in
                didAppend = true
                throw MCPError.invalidParams("unexpected append")
            }
        )

        await assertThrowsAsync {
            try await service.execute(args: proposalArgs(
                coordinatorID: selectedID,
                plan: selectedPlan,
                fingerprint: selectedPlan.materialContractFingerprint()
            ))
        }
        XCTAssertFalse(didAppend)
    }

    func testProposeRevisionRejectsAbsentUnapprovedTerminalAndStaleMissionState() async throws {
        let coordinatorID = UUID()
        let approved = CoordinatorMissionPlan(objective: "Approved", status: .running, approvalState: .approved)
        let cases: [(String, [UUID: CoordinatorMissionPlan], UUID, String)] = try [
            ("absent", [:], approved.id, approved.materialContractFingerprint()),
            (
                "unapproved",
                [coordinatorID: CoordinatorMissionPlan(objective: "Draft", status: .draft, approvalState: .awaitingApproval)],
                approved.id,
                approved.materialContractFingerprint()
            ),
            (
                "terminal",
                [coordinatorID: CoordinatorMissionPlan(objective: "Done", status: .completed, approvalState: .approved)],
                approved.id,
                approved.materialContractFingerprint()
            ),
            ("stale plan", [coordinatorID: approved], UUID(), approved.materialContractFingerprint()),
            ("stale contract", [coordinatorID: approved], approved.id, String(repeating: "0", count: 64))
        ]

        for (name, missionPlans, basePlanID, fingerprint) in cases {
            var didAppend = false
            let service = makeService(
                coordinatorIDs: [coordinatorID],
                selectedID: coordinatorID,
                captureRequestMetadata: { Self.coordinatorRuntimeMetadata() },
                resolveRuntimeCoordinatorSessionID: { _ in coordinatorID },
                missionPlans: { missionPlans },
                appendRevisionProposal: { _, _ in
                    didAppend = true
                    throw MCPError.invalidParams("unexpected append")
                }
            )
            var args = proposalArgs(
                coordinatorID: coordinatorID,
                plan: approved,
                fingerprint: fingerprint
            )
            args["base_plan_id"] = .string(basePlanID.uuidString)
            do {
                _ = try await service.execute(args: args)
                XCTFail("Expected \(name) proposal to be rejected.")
            } catch {}
            XCTAssertFalse(didAppend, "\(name) must reject before mutation")
        }
    }

    func testProposeRevisionRejectsReplacementAndAuthorityFields() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(objective: "Approved", status: .running, approvalState: .approved)
        let fingerprint = try plan.materialContractFingerprint()
        let forbiddenFields = [
            "replacement_plan", "plan_diff", "approve_revised_plan",
            "canonicalRequestIdentity", "canonical_requested_change",
            "approval_state", "objective", "user_decision_id", "decisions",
            "nodes", "bound_session_id", "bindings", "resolution", "resolution_state"
        ]
        var didAppend = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: { Self.coordinatorRuntimeMetadata() },
            resolveRuntimeCoordinatorSessionID: { _ in coordinatorID },
            missionPlans: { [coordinatorID: plan] },
            appendRevisionProposal: { _, _ in
                didAppend = true
                throw MCPError.invalidParams("unexpected append")
            }
        )

        for field in forbiddenFields {
            var args = proposalArgs(coordinatorID: coordinatorID, plan: plan, fingerprint: fingerprint)
            args[field] = .string("forbidden")
            do {
                _ = try await service.execute(args: args)
                XCTFail("Expected \(field) to be rejected.")
            } catch {
                XCTAssertTrue(String(describing: error).contains("summary-only"))
            }
        }
        XCTAssertFalse(didAppend)
    }

    func testProposeRevisionValidatesSummaryFieldsAndSupportingEvidenceIDsBeforeMutation() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(objective: "Approved", status: .running, approvalState: .approved)
        let fingerprint = try plan.materialContractFingerprint()
        var didAppend = false
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: { Self.coordinatorRuntimeMetadata() },
            resolveRuntimeCoordinatorSessionID: { _ in coordinatorID },
            missionPlans: { [coordinatorID: plan] },
            appendRevisionProposal: { _, _ in
                didAppend = true
                throw MCPError.invalidParams("unexpected append")
            }
        )
        var missingSummary = proposalArgs(coordinatorID: coordinatorID, plan: plan, fingerprint: fingerprint)
        missingSummary.removeValue(forKey: "summary")
        await assertThrowsAsync { try await service.execute(args: missingSummary) }

        var emptyAffectedFields = proposalArgs(coordinatorID: coordinatorID, plan: plan, fingerprint: fingerprint)
        emptyAffectedFields["affected_fields"] = .array([])
        await assertThrowsAsync { try await service.execute(args: emptyAffectedFields) }

        var invalidEvidence = proposalArgs(coordinatorID: coordinatorID, plan: plan, fingerprint: fingerprint)
        invalidEvidence["supporting_evidence_ids"] = .array([.string("not-a-uuid")])
        await assertThrowsAsync { try await service.execute(args: invalidEvidence) }
        XCTAssertFalse(didAppend)
    }

    func testProposeRevisionAliasPairsRequireSemanticallyIdenticalValues() async throws {
        let coordinatorID = UUID()
        let evidenceA = UUID()
        let evidenceB = UUID()
        let plan = CoordinatorMissionPlan(objective: "Approved", status: .running, approvalState: .approved)
        let fingerprint = try plan.materialContractFingerprint()
        var missionPlans = [coordinatorID: plan]
        var appendCount = 0
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: { Self.coordinatorRuntimeMetadata() },
            resolveRuntimeCoordinatorSessionID: { _ in coordinatorID },
            missionPlans: { missionPlans },
            appendRevisionProposal: { sessionID, request in
                var state = CoordinatorFollowThroughState(missionPlan: missionPlans[sessionID])
                let result = try state.appendRevisionProposal(request)
                missionPlans[sessionID] = state.missionPlan
                appendCount += 1
                return result
            }
        )
        var identical = proposalArgs(
            coordinatorID: coordinatorID,
            plan: plan,
            fingerprint: fingerprint,
            evidenceIDs: [evidenceA, evidenceB],
            requestedChange: "Cafe\u{301} needs a wider scope."
        )
        identical["coordinatorSessionID"] = .string(coordinatorID.uuidString.lowercased())
        identical["basePlanID"] = .string(plan.id.uuidString.lowercased())
        identical["baseContractFingerprint"] = .string("  \(fingerprint)  ")
        identical["affectedFields"] = .array([
            .string("workstreams"),
            .string("objective"),
            .string("objective")
        ])
        identical["supportingEvidenceIDs"] = .array([
            .string(evidenceB.uuidString),
            .string(evidenceA.uuidString),
            .string(evidenceA.uuidString)
        ])
        identical["requestedChange"] = .string("  Café   needs a wider scope. ")

        let response = try await service.execute(args: identical)
        XCTAssertEqual(response.objectValue?["accepted"]?.boolValue, true)
        XCTAssertEqual(appendCount, 1)

        let conflicts: [(String, Value)] = [
            ("coordinatorSessionID", .string(UUID().uuidString)),
            ("basePlanID", .string(UUID().uuidString)),
            ("baseContractFingerprint", .string(String(repeating: "0", count: 64))),
            ("affectedFields", .array([.string("policy")])),
            ("supportingEvidenceIDs", .array([.string(UUID().uuidString)])),
            ("requestedChange", .string("café needs a wider scope."))
        ]
        for (alias, conflictingValue) in conflicts {
            var args = proposalArgs(
                coordinatorID: coordinatorID,
                plan: plan,
                fingerprint: fingerprint,
                evidenceIDs: [evidenceA, evidenceB],
                requestedChange: "Cafe\u{301} needs a wider scope."
            )
            args[alias] = conflictingValue
            do {
                _ = try await service.execute(args: args)
                XCTFail("Expected conflicting alias \(alias) to be rejected.")
            } catch {
                XCTAssertTrue(String(describing: error).contains("Conflicting"))
            }
        }
        XCTAssertEqual(appendCount, 1)
    }

    func testProposeRevisionDoesNotReturnSuccessWhenPersistenceCallbackFails() async throws {
        let coordinatorID = UUID()
        let plan = CoordinatorMissionPlan(objective: "Approved", status: .running, approvalState: .approved)
        let fingerprint = try plan.materialContractFingerprint()
        let service = makeService(
            coordinatorIDs: [coordinatorID],
            selectedID: coordinatorID,
            captureRequestMetadata: { Self.coordinatorRuntimeMetadata() },
            resolveRuntimeCoordinatorSessionID: { _ in coordinatorID },
            missionPlans: { [coordinatorID: plan] },
            appendRevisionProposal: { _, _ in
                throw MCPError.invalidParams("durable proposal persistence failed")
            }
        )

        do {
            _ = try await service.execute(args: proposalArgs(
                coordinatorID: coordinatorID,
                plan: plan,
                fingerprint: fingerprint
            ))
            XCTFail("Expected persistence failure.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("durable proposal persistence failed"))
        }
    }

    func testDirectorE2ECompactStatusFixtureMatchesCoreShape() throws {
        let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Scripts/Fixtures/director_e2e_compact_status.json")
        let data = try Data(contentsOf: fixtureURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let plan = try XCTUnwrap(root["plan"] as? [String: Any])

        XCTAssertNotNil(root["fingerprint"])
        XCTAssertNotNil(plan["status"])
        XCTAssertNotNil(plan["revision"])
        XCTAssertNotNil(plan["approval_state"])
        XCTAssertNotNil(plan["policy_snapshot"])
        XCTAssertNotNil(plan["autonomy_summary"])
        XCTAssertNotNil(root["node_counts"])
        XCTAssertNotNil(root["ready_node_ids"])
        XCTAssertNotNil(root["decision_counts_by_actor"])
        XCTAssertNotNil(root["evidence_counts"])
        XCTAssertNotNil(root["counts"])
        XCTAssertNotNil(root["active_nodes"])
        XCTAssertNotNil(root["liveness_warnings"])
    }

    private static func coordinatorRuntimeMetadata() -> MCPServerViewModel.RequestMetadata {
        MCPServerViewModel.RequestMetadata(
            connectionID: UUID(),
            clientName: "coordinator-runtime",
            windowID: 1,
            runPurpose: .agentModeRun,
            taskLabelKind: .coordinator,
            isCoordinatorRuntime: true
        )
    }

    private func proposalArgs(
        coordinatorID: UUID,
        plan: CoordinatorMissionPlan,
        fingerprint: String,
        summary: String = "Request a material scope revision.",
        evidenceIDs: [UUID] = [],
        requestedChange: String = "Expand the approved scope."
    ) -> [String: Value] {
        [
            "op": .string("propose_revision"),
            "coordinator_session_id": .string(coordinatorID.uuidString),
            "base_plan_id": .string(plan.id.uuidString),
            "base_contract_fingerprint": .string(fingerprint),
            "summary": .string(summary),
            "rationale": .string("New evidence requires a contract-changing remedy."),
            "affected_fields": .array([.string("objective"), .string("workstreams")]),
            "remedy": .string("revise_plan"),
            "supporting_evidence_ids": .array(evidenceIDs.map { .string($0.uuidString) }),
            "requested_change": .string(requestedChange)
        ]
    }

    private func assertThrowsAsync(
        _ operation: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected operation to throw.", file: file, line: line)
        } catch {}
    }

    private func compactFingerprint(
        service: CoordinatorChatMCPToolService,
        args: [String: Value]
    ) async throws -> String {
        let response = try await service.execute(args: args)
        return try XCTUnwrap(response.objectValue?["mission_status"]?.objectValue?["fingerprint"]?.stringValue)
    }

    private func compactWarnings(
        service: CoordinatorChatMCPToolService,
        args: [String: Value]
    ) async throws -> [String] {
        let response = try await service.execute(args: args)
        return try XCTUnwrap(response.objectValue?["mission_status"]?.objectValue?["liveness_warnings"]?.arrayValue?.compactMap(\.stringValue))
    }

    private static func durablyApprovedPlan(
        _ plan: CoordinatorMissionPlan,
        coordinatorID: UUID
    ) -> CoordinatorMissionPlan {
        var plan = plan
        let continuation = CoordinatorPostApprovalContinuationRecord(
            coordinatorSessionID: coordinatorID,
            checkpointInstanceID: "coordinator:\(coordinatorID.uuidString):plan-approval:r\(plan.revision)",
            planID: plan.id,
            planRevision: plan.revision,
            directiveText: "Proceed.",
            status: .delivered,
            attempts: 1
        ).confirmingDurableApprovalAuthority()
        plan.postApprovalContinuation = continuation
        return plan
    }

    private static func approvedContractPlan(
        objective: String,
        workstreamID: UUID,
        nodeID: UUID
    ) -> CoordinatorMissionPlan {
        CoordinatorMissionPlan(
            objective: objective,
            status: .running,
            approvalState: .approved,
            policySnapshot: .defaultPolicy,
            autonomy: CoordinatorMissionPolicySnapshot.defaultAutonomy,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Implementation",
                    purpose: "Implement the approved work.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .createIsolated,
                        baseRef: "main",
                        baseReason: "Approved contract base."
                    )
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Implement approved work",
                    completionEvidence: "Approved work is implemented and validated.",
                    doneCriteria: "Implementation and validation are complete.",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .pending
                )
            ]
        )
    }

    private func makeService(
        coordinatorIDs: [UUID],
        selectedID: UUID,
        captureRequestMetadata: @escaping () async -> MCPServerViewModel.RequestMetadata = {
            MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: nil, windowID: nil)
        },
        resolveRuntimeCoordinatorSessionID: @escaping (MCPServerViewModel.RequestMetadata) async -> UUID? = { _ in nil },
        coordinatorRunState: AgentSessionRunState = .idle,
        startNew: @escaping (String?) -> Void = { _ in },
        stopMission: @escaping (UUID) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted },
        submit: @escaping (String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted },
        revisionProposalAuthorityPlan: ((UUID) -> CoordinatorMissionPlan?)? = nil,
        submitAcceptedRevisionDraftingDirective: @escaping (String, UUID, UUID) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _, _ in .accepted },
        submitContinuation: @escaping (CoordinatorModeViewModel.ContinuationAction, String?) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted },
        pendingChild: @escaping (UUID?) -> CoordinatorModeRow? = { _ in nil },
        submitPendingChild: @escaping (CoordinatorModeViewModel.ChildInteractionResponseSubmission, CoordinatorModeRow, CoordinatorMissionDecisionActor) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _, _ in .accepted },
        counts: CoordinatorModeCounts = .empty,
        rows: [CoordinatorModeRow] = [],
        missionPlans: @escaping () -> [UUID: CoordinatorMissionPlan] = { [:] },
        liveInCurrentWindow: [UUID: Bool] = [:],
        persistedOnly: [UUID: Bool] = [:],
        pinned: [UUID: Bool] = [:],
        updateMissionPlan: @escaping (UUID, CoordinatorMissionPlanUpdate) throws -> Void = { _, _ in },
        appendRevisionProposal: @escaping (UUID, CoordinatorMissionRevisionProposalRequest) async throws -> CoordinatorMissionRevisionProposalAppendResult = { _, _ in
            throw MCPError.invalidParams("Revision proposals are unavailable in this test.")
        },
        resolveRevisionProposal: @escaping (UUID, CoordinatorMissionRevisionProposalResolutionAction, UUID, String, String, String?) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _, _, _, _, _ in .accepted },
        durableApprovalAuthorityToken: @escaping (UUID) -> String? = { _ in nil },
        missionEvents: @escaping (UUID, Int, Int) -> CoordinatorMissionEventJournal.Batch = { _, sinceSeq, _ in
            CoordinatorMissionEventJournal.Batch(events: [], nextSeq: sinceSeq, oldestSeq: nil, latestSeq: nil, truncated: false)
        },
        setMissionPace: @escaping (UUID, CoordinatorMissionPolicyPace) -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted },
        setMissionAutonomy: @escaping (UUID, String, CoordinatorMissionAutonomyMode) -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _, _ in .accepted },
        archiveMission: @escaping (UUID) async -> CoordinatorModeViewModel.CoordinatorArchiveMissionResult = { _ in .accepted() },
        initialMissionPlanTimeoutSeconds: TimeInterval = 0,
        initialMissionPlanPollIntervalSeconds: TimeInterval = 0.01,
        sleep: @escaping (UInt64) async -> Void = { _ in }
    ) -> CoordinatorChatMCPToolService {
        makeService(
            coordinatorIDs: coordinatorIDs,
            selectedID: { selectedID },
            captureRequestMetadata: captureRequestMetadata,
            resolveRuntimeCoordinatorSessionID: resolveRuntimeCoordinatorSessionID,
            coordinatorRunState: coordinatorRunState,
            startNew: startNew,
            stopMission: stopMission,
            submit: submit,
            revisionProposalAuthorityPlan: revisionProposalAuthorityPlan,
            submitAcceptedRevisionDraftingDirective: submitAcceptedRevisionDraftingDirective,
            submitContinuation: submitContinuation,
            pendingChild: pendingChild,
            submitPendingChild: submitPendingChild,
            counts: counts,
            rows: rows,
            missionPlans: missionPlans,
            liveInCurrentWindow: liveInCurrentWindow,
            persistedOnly: persistedOnly,
            pinned: pinned,
            updateMissionPlan: updateMissionPlan,
            appendRevisionProposal: appendRevisionProposal,
            resolveRevisionProposal: resolveRevisionProposal,
            durableApprovalAuthorityToken: durableApprovalAuthorityToken,
            missionEvents: missionEvents,
            setMissionPace: setMissionPace,
            setMissionAutonomy: setMissionAutonomy,
            archiveMission: archiveMission,
            initialMissionPlanTimeoutSeconds: initialMissionPlanTimeoutSeconds,
            initialMissionPlanPollIntervalSeconds: initialMissionPlanPollIntervalSeconds,
            sleep: sleep
        )
    }

    private func makeService(
        coordinatorIDs: [UUID],
        selectedID: @escaping () -> UUID,
        captureRequestMetadata: @escaping () async -> MCPServerViewModel.RequestMetadata = {
            MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: nil, windowID: nil)
        },
        resolveRuntimeCoordinatorSessionID: @escaping (MCPServerViewModel.RequestMetadata) async -> UUID? = { _ in nil },
        coordinatorRunState: AgentSessionRunState = .idle,
        select: @escaping (UUID?) -> Void = { _ in },
        startNew: @escaping (String?) -> Void = { _ in },
        stopMission: @escaping (UUID) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted },
        submit: @escaping (String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _ in .accepted },
        revisionProposalAuthorityPlan: ((UUID) -> CoordinatorMissionPlan?)? = nil,
        submitAcceptedRevisionDraftingDirective: @escaping (String, UUID, UUID) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _, _ in .accepted },
        submitContinuation: @escaping (CoordinatorModeViewModel.ContinuationAction, String?) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted },
        pendingChild: @escaping (UUID?) -> CoordinatorModeRow? = { _ in nil },
        submitPendingChild: @escaping (CoordinatorModeViewModel.ChildInteractionResponseSubmission, CoordinatorModeRow, CoordinatorMissionDecisionActor) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _, _ in .accepted },
        counts: CoordinatorModeCounts = .empty,
        rows: [CoordinatorModeRow] = [],
        missionPlans: @escaping () -> [UUID: CoordinatorMissionPlan] = { [:] },
        liveInCurrentWindow: [UUID: Bool] = [:],
        persistedOnly: [UUID: Bool] = [:],
        pinned: [UUID: Bool] = [:],
        updateMissionPlan: @escaping (UUID, CoordinatorMissionPlanUpdate) throws -> Void = { _, _ in },
        appendRevisionProposal: @escaping (UUID, CoordinatorMissionRevisionProposalRequest) async throws -> CoordinatorMissionRevisionProposalAppendResult = { _, _ in
            throw MCPError.invalidParams("Revision proposals are unavailable in this test.")
        },
        resolveRevisionProposal: @escaping (UUID, CoordinatorMissionRevisionProposalResolutionAction, UUID, String, String, String?) async -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _, _, _, _, _ in .accepted },
        durableApprovalAuthorityToken: @escaping (UUID) -> String? = { _ in nil },
        missionEvents: @escaping (UUID, Int, Int) -> CoordinatorMissionEventJournal.Batch = { _, sinceSeq, _ in
            CoordinatorMissionEventJournal.Batch(events: [], nextSeq: sinceSeq, oldestSeq: nil, latestSeq: nil, truncated: false)
        },
        setMissionPace: @escaping (UUID, CoordinatorMissionPolicyPace) -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _ in .accepted },
        setMissionAutonomy: @escaping (UUID, String, CoordinatorMissionAutonomyMode) -> CoordinatorModeViewModel.DirectiveSubmissionResult = { _, _, _ in .accepted },
        archiveMission: @escaping (UUID) async -> CoordinatorModeViewModel.CoordinatorArchiveMissionResult = { _ in .accepted() },
        initialMissionPlanTimeoutSeconds: TimeInterval = 0,
        initialMissionPlanPollIntervalSeconds: TimeInterval = 0.01,
        sleep: @escaping (UInt64) async -> Void = { _ in }
    ) -> CoordinatorChatMCPToolService {
        CoordinatorChatMCPToolService(
            toolName: MCPWindowToolName.coordinatorChat,
            captureRequestMetadata: captureRequestMetadata,
            resolveRuntimeCoordinatorSessionID: resolveRuntimeCoordinatorSessionID,
            initialMissionPlanTimeoutSeconds: initialMissionPlanTimeoutSeconds,
            initialMissionPlanPollIntervalSeconds: initialMissionPlanPollIntervalSeconds,
            sleep: sleep
        ) {
            CoordinatorChatMCPToolService.Environment(
                snapshot: {
                    Self.snapshot(
                        coordinatorIDs: coordinatorIDs,
                        selectedID: selectedID(),
                        coordinatorRunState: coordinatorRunState,
                        counts: counts,
                        rows: rows,
                        missionPlans: missionPlans(),
                        liveInCurrentWindow: liveInCurrentWindow,
                        persistedOnly: persistedOnly,
                        pinned: pinned
                    )
                },
                refresh: {},
                selectCoordinator: select,
                startNewCoordinatorRun: startNew,
                stopCoordinatorMission: stopMission,
                submitDirective: submit,
                acceptedRevisionDraftingResolutionID: { coordinatorSessionID in
                    let plan = revisionProposalAuthorityPlan?(coordinatorSessionID)
                        ?? missionPlans()[coordinatorSessionID]
                    return plan?.acceptedRevisionDraftingResolution?.id
                },
                holdsRevisionProposalAuthority: { coordinatorSessionID in
                    let plan = revisionProposalAuthorityPlan?(coordinatorSessionID)
                        ?? missionPlans()[coordinatorSessionID]
                    return plan?.holdsChildInteractionsForRevisionProposal == true
                },
                submitAcceptedRevisionDraftingDirective: submitAcceptedRevisionDraftingDirective,
                submitContinuation: submitContinuation,
                activePendingChildInteractionRow: pendingChild,
                submitPendingChildInteractionResponse: submitPendingChild,
                durableApprovalAuthorityToken: durableApprovalAuthorityToken,
                updateMissionPlan: updateMissionPlan,
                appendRevisionProposal: appendRevisionProposal,
                resolveRevisionProposal: resolveRevisionProposal,
                missionEvents: missionEvents,
                setMissionPace: setMissionPace,
                setMissionAutonomy: setMissionAutonomy,
                archiveMission: archiveMission
            )
        }
    }

    private static func snapshot(
        coordinatorIDs: [UUID],
        selectedID: UUID,
        coordinatorRunState: AgentSessionRunState = .idle,
        counts: CoordinatorModeCounts = .empty,
        rows: [CoordinatorModeRow] = [],
        missionPlans: [UUID: CoordinatorMissionPlan] = [:],
        liveInCurrentWindow: [UUID: Bool] = [:],
        persistedOnly: [UUID: Bool] = [:],
        pinned: [UUID: Bool] = [:]
    ) -> CoordinatorModeSnapshot {
        let options = coordinatorIDs.enumerated().map { index, id in
            let isLive = liveInCurrentWindow[id] ?? true
            let isPersistedOnly = persistedOnly[id] ?? false
            let isPinned = pinned[id] ?? false
            return CoordinatorModeCoordinatorOption(
                sessionID: id,
                tabID: UUID(),
                workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
                title: "Coordinator \(index + 1)",
                selectionSource: .demoRuntime,
                isSelected: id == selectedID,
                isLiveInCurrentWindow: isLive,
                isPinned: isPinned,
                isPersistedOnly: isPersistedOnly,
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
                isLiveInCurrentWindow: options.first(where: { $0.sessionID == selectedID })?.isLiveInCurrentWindow ?? true,
                isPersistedOnly: options.first(where: { $0.sessionID == selectedID })?.isPersistedOnly ?? false,
                isPinned: options.first(where: { $0.sessionID == selectedID })?.isPinned ?? false,
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
            decisionQueue: [],
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

    private static func approvalPlan(coordinatorID _: UUID, revision: Int) -> CoordinatorMissionPlan {
        let workstreamID = UUID()
        return CoordinatorMissionPlan(
            revision: revision,
            objective: "Approve the next safe slice.",
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
                    id: UUID(),
                    title: "Choose next PR scope",
                    workstreamID: workstreamID,
                    executionPolicy: .coordinatorOnly,
                    status: .pending
                )
            ]
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
