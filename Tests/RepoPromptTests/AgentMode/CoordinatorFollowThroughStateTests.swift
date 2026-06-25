@testable import RepoPrompt
import XCTest

final class CoordinatorFollowThroughStateTests: XCTestCase {
    func testMissionPlanDecodesFromOlderPayloadAndResetsForNewObjective() throws {
        let oldPayload = """
        {
          "originalObjectiveSummary": "Ship docs",
          "observedChildPhases": [],
          "pendingEvents": [],
          "handledEventIDs": [],
          "childInteractionResponses": []
        }
        """
        let decoded = try JSONDecoder().decode(
            CoordinatorFollowThroughState.self,
            from: Data(oldPayload.utf8)
        )
        XCTAssertNil(decoded.missionPlan)

        var state = CoordinatorFollowThroughState(
            originalObjectiveSummary: "Ship docs",
            missionPlan: CoordinatorMissionPlan(
                objective: "Ship docs",
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        title: "Docs implementation",
                        purpose: "Update README wording.",
                        defaultPolicy: .freshWorktree,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                    )
                ]
            )
        )
        state.rememberObjective("Ship tests")
        XCTAssertEqual(state.originalObjectiveSummary, "Ship tests")
        XCTAssertNil(state.missionPlan)
    }

    func testRememberObjectiveCanPreserveMissionPlanForFollowUpTurns() {
        let plan = CoordinatorMissionPlan(
            objective: "Validate DAG-lite status surface",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    title: "Status surface",
                    purpose: "Keep Plan tab state visible.",
                    defaultPolicy: .coordinatorOnly,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ]
        )
        var state = CoordinatorFollowThroughState(
            originalObjectiveSummary: "DAG-lite smoke",
            missionPlan: plan
        )

        state.rememberObjective("What should we do next?", resetMissionPlan: false)

        XCTAssertEqual(state.originalObjectiveSummary, "What should we do next?")
        XCTAssertEqual(state.missionPlan, plan)
    }

    func testMissionPlanNodeWorkflowHintAndEvidenceCodableRoundTrip() throws {
        let workstreamID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Add CSV export to orders table",
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Product behavior",
                    purpose: "Ship the export behavior.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    title: "Generate CSV from filtered rows",
                    workflowHint: CoordinatorMissionPlanNodeWorkflowHint(
                        id: "builtin-orchestrate",
                        name: "Orchestrate",
                        iconName: "arrow.triangle.branch",
                        accentColorHex: "#30D158"
                    ),
                    completionEvidence: "Downloaded CSV matches the currently visible filtered data.",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree
                )
            ]
        )

        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(CoordinatorMissionPlan.self, from: data)

        XCTAssertEqual(decoded.nodes.first?.title, "Generate CSV from filtered rows")
        XCTAssertEqual(decoded.nodes.first?.workflowHint?.name, "Orchestrate")
        XCTAssertEqual(decoded.nodes.first?.workflowHint?.id, "builtin-orchestrate")
        XCTAssertEqual(decoded.nodes.first?.completionEvidence, "Downloaded CSV matches the currently visible filtered data.")
    }

    func testMissionPlanUpsertReusesWorkstreamIDByTitle() {
        let existingID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let eventID = UUID()
        var state = CoordinatorFollowThroughState(
            missionPlan: CoordinatorMissionPlan(
                objective: "Ship docs",
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: existingID,
                        title: "Docs implementation",
                        purpose: "Old purpose",
                        defaultPolicy: .freshWorktree,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: nodeID,
                        title: "Implement docs",
                        detail: "Apply the wording change.",
                        workstreamID: existingID,
                        executionPolicy: .freshWorktree,
                        status: .running,
                        boundSessionID: childID
                    )
                ],
                events: [
                    CoordinatorMissionPlanEvent(
                        id: eventID,
                        kind: .sessionBound,
                        nodeID: nodeID,
                        sessionID: childID,
                        timestamp: Date(timeIntervalSince1970: 10),
                        summary: "Implementation child started."
                    )
                ]
            )
        )

        state.updateMissionPlan(
            objective: "Ship docs",
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    title: "docs IMPLEMENTATION",
                    purpose: "New purpose",
                    defaultPolicy: .steerPrimary,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .reuseWorkstream,
                        worktreeID: "wt-docs",
                        reason: "Continue in the implementation lane."
                    )
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(state.missionPlan?.workstreams.first?.id, existingID)
        XCTAssertEqual(state.missionPlan?.workstreams.first?.purpose, "New purpose")
        XCTAssertEqual(state.missionPlan?.workstreams.first?.defaultPolicy, .steerPrimary)
        XCTAssertEqual(state.missionPlan?.workstreams.first?.worktreeStrategy.mode, .reuseWorkstream)
        XCTAssertEqual(state.missionPlan?.revision, 2)
        XCTAssertEqual(state.missionPlan?.nodes.first?.id, nodeID)
        XCTAssertEqual(state.missionPlan?.nodes.first?.boundSessionID, childID)
        XCTAssertEqual(state.missionPlan?.events.first?.id, eventID)
        XCTAssertEqual(state.missionPlan?.events.last?.kind, .revised)
    }

    func testMissionPlanPartialUpdatePreservesOmittedFieldsAndAppendsEvents() throws {
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        var state = CoordinatorFollowThroughState(
            missionPlan: CoordinatorMissionPlan(
                revision: 4,
                objective: "Ship DAG",
                status: .draft,
                approvalState: .awaitingApproval,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: workstreamID,
                        title: "Implementation",
                        purpose: "Make the change.",
                        defaultPolicy: .freshWorktree,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: nodeID,
                        title: "Implement",
                        workstreamID: workstreamID,
                        executionPolicy: .freshWorktree,
                        status: .pending,
                        boundSessionID: childID
                    )
                ],
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )

        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            status: .running,
            events: [
                CoordinatorMissionPlanEvent(
                    kind: .nodeStarted,
                    nodeID: nodeID,
                    sessionID: childID,
                    timestamp: Date(timeIntervalSince1970: 20),
                    summary: "Implementation started."
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 20)
        ))

        let plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.revision, 5)
        XCTAssertEqual(plan.objective, "Ship DAG")
        XCTAssertEqual(plan.status, .running)
        XCTAssertEqual(plan.approvalState, .awaitingApproval)
        XCTAssertEqual(plan.workstreams.map(\.id), [workstreamID])
        XCTAssertEqual(plan.nodes.map(\.id), [nodeID])
        XCTAssertEqual(plan.events.suffix(2).map(\.kind), [.revised, .nodeStarted])
    }

    func testCompletesSatisfiedCoordinatorOnlyRunningMissionPlanNodes() throws {
        let workstreamID = UUID()
        let planID = UUID()
        let orchestrateID = UUID()
        let reviewID = UUID()
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 1,
            objective: "DAG smoke",
            status: .running,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "State surface",
                    purpose: "Validate DAG state.",
                    defaultPolicy: .coordinatorOnly,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: planID,
                    title: "Plan",
                    workstreamID: workstreamID,
                    executionPolicy: .coordinatorOnly,
                    status: .completed
                ),
                CoordinatorMissionPlanNode(
                    id: orchestrateID,
                    title: "Orchestrate",
                    workstreamID: workstreamID,
                    dependsOn: [planID],
                    executionPolicy: .coordinatorOnly,
                    status: .completed
                ),
                CoordinatorMissionPlanNode(
                    id: reviewID,
                    title: "Review",
                    workstreamID: workstreamID,
                    dependsOn: [orchestrateID],
                    executionPolicy: .coordinatorOnly,
                    status: .running
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 10)
        ))

        XCTAssertTrue(state.completeSatisfiedCoordinatorOnlyRunningMissionPlanNodes(at: Date(timeIntervalSince1970: 20)))

        let plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.revision, 2)
        XCTAssertEqual(plan.status, .completed)
        XCTAssertEqual(plan.nodes.map(\.status), [.completed, .completed, .completed])
        XCTAssertEqual(plan.events.suffix(2).map(\.kind), [.revised, .nodeCompleted])
        XCTAssertEqual(plan.events.last?.nodeID, reviewID)
    }

    func testDoesNotCompleteUnsatisfiedOrMutableRunningMissionPlanNodes() throws {
        let workstreamID = UUID()
        let planID = UUID()
        let blockedReviewID = UUID()
        let mutableID = UUID()
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 3,
            objective: "DAG smoke",
            status: .running,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "State surface",
                    purpose: "Validate DAG state.",
                    defaultPolicy: .coordinatorOnly,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: planID,
                    title: "Plan",
                    workstreamID: workstreamID,
                    executionPolicy: .coordinatorOnly,
                    status: .running
                ),
                CoordinatorMissionPlanNode(
                    id: blockedReviewID,
                    title: "Review",
                    workstreamID: workstreamID,
                    dependsOn: [planID],
                    executionPolicy: .coordinatorOnly,
                    status: .running
                ),
                CoordinatorMissionPlanNode(
                    id: mutableID,
                    title: "Implement",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .running
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 10)
        ))

        XCTAssertTrue(state.completeSatisfiedCoordinatorOnlyRunningMissionPlanNodes(at: Date(timeIntervalSince1970: 20)))

        let plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.revision, 4)
        XCTAssertEqual(plan.status, .running)
        XCTAssertEqual(plan.nodes.map(\.status), [.completed, .running, .running])
        XCTAssertEqual(plan.events.last?.nodeID, planID)
    }
}
