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

    func testResumeDirectiveContainsMissionEligibilityCapAndIdempotencyClauses() {
        let event = CoordinatorFollowThroughEvent(
            id: "resume-1",
            kind: .childTerminal,
            coordinatorSessionID: UUID(),
            childSessionID: UUID(),
            childTitle: "Implementation child",
            gate: nil,
            phase: nil,
            detail: "Child completed node A."
        )

        let directive = event.resumeDirective

        XCTAssertTrue(directive.contains("coordinator_chat op=mission_status"))
        XCTAssertTrue(directive.contains("compact:true"))
        XCTAssertTrue(directive.contains("pending node whose dependencies are now all completed is eligible"))
        XCTAssertTrue(directive.contains("Mission policy `max_concurrent` cap"))
        XCTAssertTrue(directive.contains("Never start a node that is already running or has a bound session"))
    }

    func testMissionPlanNodeWorkflowHintAndEvidenceCodableRoundTrip() throws {
        let workstreamID = UUID()
        let predecessorID = UUID()
        let plan = CoordinatorMissionPlan(
            objective: "Add CSV export to orders table",
            predecessorMissionID: predecessorID,
            predecessorTitle: "PR #5 Contract Fixtures",
            predecessorSummary: "Negative fixture tests now define the contract harness shape.",
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
        XCTAssertEqual(decoded.predecessorMissionID, predecessorID)
        XCTAssertEqual(decoded.predecessorTitle, "PR #5 Contract Fixtures")
        XCTAssertEqual(decoded.predecessorSummary, "Negative fixture tests now define the contract harness shape.")
    }

    func testPlanCritiqueExecutionPolicyCodableAndDisplayName() throws {
        let data = try JSONEncoder().encode(CoordinatorMissionExecutionPolicy.planCritique)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"plan_critique\"")

        let decoded = try JSONDecoder().decode(CoordinatorMissionExecutionPolicy.self, from: data)
        XCTAssertEqual(decoded, .planCritique)
        XCTAssertEqual(decoded.displayName, "Plan critique")
    }

    func testMissionPlanRoutingDecisionsCodableRoundTripAndDefaultEmpty() throws {
        let planPayloadMissingRoutingDecisions = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "revision": 1,
          "objective": "Ship docs",
          "status": "draft",
          "approvalState": "not_required",
          "workstreams": [],
          "nodes": [],
          "events": [],
          "updatedAt": 0
        }
        """
        let oldPlan = try JSONDecoder().decode(
            CoordinatorMissionPlan.self,
            from: Data(planPayloadMissingRoutingDecisions.utf8)
        )
        XCTAssertEqual(oldPlan.routingDecisions, [])

        let nodeID = UUID()
        let workstreamID = UUID()
        let decision = CoordinatorMissionRoutingDecision(
            timestamp: Date(timeIntervalSince1970: 10),
            nodeID: nodeID,
            workstreamID: workstreamID,
            decision: .startFreshWorktree,
            operation: .agentRunStart,
            sessionID: UUID(),
            worktreeID: "wt-docs",
            workflowName: "Orchestrate",
            modelID: "engineer",
            role: "engineer",
            reason: "Mutable docs work needs an isolated worktree.",
            contextSummary: "README wording change."
        )
        let plan = CoordinatorMissionPlan(
            objective: "Ship docs",
            routingDecisions: [decision]
        )

        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(CoordinatorMissionPlan.self, from: data)

        XCTAssertEqual(decoded.routingDecisions, [decision])
        XCTAssertEqual(decoded.routingDecisions.first?.modelID, "engineer")
    }

    func testMissionPlanRoutingDecisionUpsertPreservesOmittedAndSortsChronologically() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Ship docs",
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    id: secondID,
                    timestamp: Date(timeIntervalSince1970: 20),
                    decision: .startFreshReadOnlyChild,
                    operation: .agentRunStart,
                    reason: "Initial discovery."
                )
            ]
        ))

        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    id: firstID,
                    timestamp: Date(timeIntervalSince1970: 10),
                    decision: .holdForUser,
                    operation: .coordinatorHold,
                    reason: "Ask before discovery."
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 30)
        ))
        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            status: .running,
            updatedAt: Date(timeIntervalSince1970: 40)
        ))
        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            routingDecisions: [
                CoordinatorMissionRoutingDecision(
                    id: secondID,
                    timestamp: Date(timeIntervalSince1970: 20),
                    decision: .startFreshReadOnlyChild,
                    operation: .agentRunStart,
                    reason: "Updated discovery route."
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 50)
        ))

        let decisions = try XCTUnwrap(state.missionPlan?.routingDecisions)
        XCTAssertEqual(decisions.map(\.id), [firstID, secondID])
        XCTAssertEqual(decisions.map(\.reason), ["Ask before discovery.", "Updated discovery route."])
        XCTAssertEqual(state.missionPlan?.status, .running)
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

    func testStoppedMissionPlanCancelsActiveNodesAndClearsPendingFollowThroughEvents() throws {
        let workstreamID = UUID()
        let runningNodeID = UUID()
        let blockedNodeID = UUID()
        let pendingNodeID = UUID()
        let cancelledSessionID = UUID()
        let skippedSessionID = UUID()
        var state = CoordinatorFollowThroughState(
            missionPlan: CoordinatorMissionPlan(
                objective: "Issue 298 provider cleanup",
                status: .running,
                approvalState: .approved,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: workstreamID,
                        title: "Implementation",
                        purpose: "Make provider cleanup changes.",
                        defaultPolicy: .freshWorktree,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: runningNodeID,
                        title: "Implement cleanup hook",
                        workstreamID: workstreamID,
                        executionPolicy: .freshWorktree,
                        status: .running,
                        boundSessionID: cancelledSessionID
                    ),
                    CoordinatorMissionPlanNode(
                        id: blockedNodeID,
                        title: "Answer cleanup question",
                        workstreamID: workstreamID,
                        executionPolicy: .coordinatorOnly,
                        status: .blocked
                    ),
                    CoordinatorMissionPlanNode(
                        id: pendingNodeID,
                        title: "Review cleanup behavior",
                        workstreamID: workstreamID,
                        executionPolicy: .freshSiblingOnSameWorktree,
                        status: .pending,
                        boundSessionID: skippedSessionID
                    )
                ],
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            pendingEvents: [
                CoordinatorFollowThroughEvent(
                    id: "resume-1",
                    kind: .childTerminal,
                    coordinatorSessionID: UUID(),
                    childSessionID: cancelledSessionID,
                    childTitle: "Cleanup child",
                    gate: nil,
                    phase: .done,
                    detail: "Child completed."
                )
            ]
        )
        var plan = try XCTUnwrap(state.missionPlan)
        plan.stopMission(
            cancelledSessionIDs: [cancelledSessionID],
            at: Date(timeIntervalSince1970: 20)
        )

        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            status: plan.status,
            nodes: plan.nodes,
            routingDecisions: plan.routingDecisions,
            updatedAt: plan.updatedAt
        ))

        let stoppedPlan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(stoppedPlan.status, .stopped)
        XCTAssertEqual(stoppedPlan.nodes.map(\.status), [.cancelled, .cancelled, .pending])
        XCTAssertEqual(stoppedPlan.routingDecisions.last?.operation, .agentRunCancel)
        XCTAssertEqual(stoppedPlan.routingDecisions.last?.sessionID, cancelledSessionID)
        XCTAssertTrue(state.pendingEvents.isEmpty)
    }

    func testMissionPlanSubsetNodeAndWorkstreamUpdatePreservesOmittedPlanEntries() throws {
        let discoveryWorkstreamID = UUID()
        let implementationWorkstreamID = UUID()
        let reviewWorkstreamID = UUID()
        let discoveryNodeID = UUID()
        let implementationNodeID = UUID()
        let settingNodeID = UUID()
        let reviewNodeID = UUID()
        let childID = UUID()
        var state = CoordinatorFollowThroughState(
            missionPlan: CoordinatorMissionPlan(
                revision: 3,
                objective: "Issue 298 provider cleanup",
                status: .running,
                approvalState: .approved,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: discoveryWorkstreamID,
                        title: "Discovery",
                        purpose: "Map cleanup code paths.",
                        defaultPolicy: .freshReadOnlyChild,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                    ),
                    CoordinatorMissionWorkstreamSummary(
                        id: implementationWorkstreamID,
                        title: "Implementation",
                        purpose: "Make provider cleanup changes.",
                        defaultPolicy: .freshWorktree,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                    ),
                    CoordinatorMissionWorkstreamSummary(
                        id: reviewWorkstreamID,
                        title: "Review",
                        purpose: "Fresh review the implementation.",
                        defaultPolicy: .freshSiblingOnSameWorktree,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .reuseWorkstream)
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: discoveryNodeID,
                        title: "Map cleanup entry points",
                        workstreamID: discoveryWorkstreamID,
                        executionPolicy: .freshReadOnlyChild,
                        status: .completed
                    ),
                    CoordinatorMissionPlanNode(
                        id: implementationNodeID,
                        title: "Add provider cleanup contract",
                        workstreamID: implementationWorkstreamID,
                        dependsOn: [discoveryNodeID],
                        executionPolicy: .freshWorktree,
                        status: .pending
                    ),
                    CoordinatorMissionPlanNode(
                        id: settingNodeID,
                        title: "Add cleanup setting",
                        workstreamID: implementationWorkstreamID,
                        dependsOn: [discoveryNodeID],
                        executionPolicy: .freshWorktree,
                        status: .pending
                    ),
                    CoordinatorMissionPlanNode(
                        id: reviewNodeID,
                        title: "Review cleanup safety",
                        workstreamID: reviewWorkstreamID,
                        dependsOn: [implementationNodeID, settingNodeID],
                        executionPolicy: .freshSiblingOnSameWorktree,
                        status: .pending
                    )
                ],
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )

        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: implementationWorkstreamID,
                    title: "Implementation",
                    purpose: "Implementation is active in an isolated worktree.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .createIsolated,
                        worktreeID: "wt_issue_298",
                        reason: "Keep the Coordinator demo checkout clean."
                    ),
                    primarySessionID: childID,
                    relatedSessionIDs: [childID]
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: implementationNodeID,
                    title: "Add provider cleanup contract",
                    workstreamID: implementationWorkstreamID,
                    dependsOn: [discoveryNodeID],
                    executionPolicy: .freshWorktree,
                    status: .running,
                    boundSessionID: childID
                ),
                CoordinatorMissionPlanNode(
                    id: settingNodeID,
                    title: "Add cleanup setting",
                    workstreamID: implementationWorkstreamID,
                    dependsOn: [discoveryNodeID],
                    executionPolicy: .freshWorktree,
                    status: .running,
                    boundSessionID: childID
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 20)
        ))

        let plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.revision, 4)
        XCTAssertEqual(plan.workstreams.map(\.id), [discoveryWorkstreamID, implementationWorkstreamID, reviewWorkstreamID])
        XCTAssertEqual(plan.workstreams[0].defaultPolicy, .freshReadOnlyChild)
        XCTAssertEqual(plan.workstreams[1].purpose, "Implementation is active in an isolated worktree.")
        XCTAssertEqual(plan.workstreams[1].primarySessionID, childID)
        XCTAssertEqual(plan.nodes.map(\.id), [discoveryNodeID, implementationNodeID, settingNodeID, reviewNodeID])
        XCTAssertEqual(plan.nodes[0].executionPolicy, .freshReadOnlyChild)
        XCTAssertEqual(plan.nodes.map(\.status), [.completed, .running, .running, .pending])
        XCTAssertEqual(plan.nodes[1].boundSessionID, childID)
        XCTAssertEqual(plan.nodes[3].dependsOn, [implementationNodeID, settingNodeID])
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

    func testCompletesRunningPlanNodesBoundToCompletedChildSessions() throws {
        let workstreamID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let dependentID = UUID()
        let firstChildID = UUID()
        let secondChildID = UUID()
        let date = Date(timeIntervalSince1970: 20)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 7,
            objective: "DAG smoke",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Fanout",
                    purpose: "Create two files before summary.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: firstID,
                    title: "Create A",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .running,
                    boundSessionID: firstChildID
                ),
                CoordinatorMissionPlanNode(
                    id: secondID,
                    title: "Create B",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .running,
                    boundSessionID: secondChildID
                ),
                CoordinatorMissionPlanNode(
                    id: dependentID,
                    title: "Summarize",
                    workstreamID: workstreamID,
                    dependsOn: [firstID, secondID],
                    executionPolicy: .coordinatorOnly,
                    status: .pending
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 10)
        ))

        XCTAssertTrue(state.completeTerminalBoundRunningMissionPlanNodes(
            completedSessionIDs: [firstChildID, secondChildID],
            at: date
        ))

        let plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.revision, 8)
        XCTAssertEqual(plan.status, .running)
        XCTAssertEqual(plan.nodes.map(\.status), [.completed, .completed, .pending])
        XCTAssertEqual(plan.events.suffix(3).map(\.kind), [.revised, .nodeCompleted, .nodeCompleted])
        XCTAssertEqual(Set(plan.events.suffix(2).compactMap(\.sessionID)), [firstChildID, secondChildID])
    }

    func testDoesNotCompleteRunningPlanNodesBoundToCancelledOrUnknownChildSessions() {
        let workstreamID = UUID()
        let childID = UUID()
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 2,
            objective: "DAG smoke",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Fanout",
                    purpose: "Create files.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    title: "Create A",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .running,
                    boundSessionID: childID
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 10)
        ))

        XCTAssertFalse(state.completeTerminalBoundRunningMissionPlanNodes(completedSessionIDs: [UUID()]))
        XCTAssertEqual(state.missionPlan?.revision, 2)
        XCTAssertEqual(state.missionPlan?.nodes.first?.status, .running)
    }

    func testDoesNotAutoCompleteChildAskAutoBoundNodeWithoutDirectorLedger() {
        let workstreamID = UUID()
        let childID = UUID()
        let interactionID = UUID()
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 2,
            objective: "Answer child ask as Director.",
            status: .running,
            approvalState: .approved,
            autonomy: autonomy,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Smoke",
                    purpose: "Ask a child question.",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    title: "Ask marker",
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: childID,
                    boundInteractionID: interactionID
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 10)
        ))

        XCTAssertFalse(state.completeTerminalBoundRunningMissionPlanNodes(completedSessionIDs: [childID]))
        XCTAssertEqual(state.missionPlan?.revision, 2)
        XCTAssertEqual(state.missionPlan?.status, .running)
        XCTAssertEqual(state.missionPlan?.nodes.first?.status, .running)
    }

    func testAutoCompletesChildAskAutoBoundNodeAfterDirectorLedger() throws {
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let interactionID = UUID()
        let decisionID = UUID()
        let date = Date(timeIntervalSince1970: 20)
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 2,
            objective: "Answer child ask as Director.",
            status: .running,
            approvalState: .approved,
            autonomy: autonomy,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Smoke",
                    purpose: "Ask a child question.",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Ask marker",
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
                    actor: .director,
                    label: CoordinatorMissionUserDecisionLabel.answeredChildQuestion.rawValue,
                    reason: "Director answered with Alpha.",
                    sessionID: childID,
                    interactionID: interactionID
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    verdict: .meets,
                    summary: "Director answered child question with Alpha.",
                    sessionID: childID,
                    interactionID: interactionID,
                    decisionID: decisionID
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 10)
        ))

        XCTAssertTrue(state.completeTerminalBoundRunningMissionPlanNodes(
            completedSessionIDs: [childID],
            at: date
        ))
        let plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.revision, 3)
        XCTAssertEqual(plan.status, .completed)
        XCTAssertEqual(plan.nodes.first?.status, .completed)
        XCTAssertEqual(plan.events.suffix(2).map(\.kind), [.revised, .nodeCompleted])
    }

    func testAutoCompletesChildAskAutoBoundNodeAfterUserOverrideLedger() throws {
        let workstreamID = UUID()
        let nodeID = UUID()
        let childID = UUID()
        let interactionID = UUID()
        let decisionID = UUID()
        var autonomy = CoordinatorMissionPolicySnapshot.defaultAutonomy
        autonomy[CoordinatorMissionDecisionClass.childAsk.rawValue] = .auto
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            revision: 2,
            objective: "Accept a user child-answer override.",
            status: .running,
            approvalState: .approved,
            autonomy: autonomy,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Smoke",
                    purpose: "Ask a child question.",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .noneReadOnly)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Ask marker",
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
                    reason: "User answered with Alpha.",
                    sessionID: childID,
                    interactionID: interactionID
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    verdict: .meets,
                    summary: "User answered child question with Alpha.",
                    sessionID: childID,
                    interactionID: interactionID,
                    decisionID: decisionID
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 10)
        ))

        XCTAssertTrue(state.completeTerminalBoundRunningMissionPlanNodes(
            completedSessionIDs: [childID],
            at: Date(timeIntervalSince1970: 20)
        ))
        let plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.status, .completed)
        XCTAssertEqual(plan.nodes.first?.status, .completed)
    }

    func testMissionPolicyBuiltInsAndFixedDecisionLabelsStayStable() {
        XCTAssertEqual(
            CoordinatorMissionPolicySnapshot.builtInPolicies.map(\.name),
            ["Default", "Hands-off", "Careful writes", "Read-only"]
        )
        XCTAssertEqual(
            CoordinatorMissionDecisionClass.allCases.map(\.rawValue),
            ["plan", "advance", "writes", "childAsk", "recover", "irreversible"]
        )
        XCTAssertEqual(
            CoordinatorMissionUserDecisionLabel.allCases.map(\.rawValue),
            [
                "approved the Mission plan",
                "requested plan revision",
                "stopped the Mission",
                "continued past a step check-in",
                "answered a child question",
                "set pace to Auto",
                "set pace to Step",
                "routed child questions to Me",
                "routed child questions to the Director"
            ]
        )
    }

    func testMissionPlanOldPersistedFixtureDecodesWithMissionDefaults() throws {
        let plan = try decodeMissionPlanFixture(Self.oldMissionPlanFixture)

        XCTAssertNil(plan.shapeSummary)
        XCTAssertNil(plan.policySnapshot)
        XCTAssertEqual(plan.autonomy, CoordinatorMissionPolicySnapshot.defaultAutonomy)
        XCTAssertEqual(plan.decisions, [])
        XCTAssertEqual(plan.evidence, [])
        XCTAssertNil(plan.nodes.first?.doneCriteria)
        XCTAssertEqual(plan.routingDecisions, [])
        XCTAssertEqual(plan.nodes.first?.completionEvidence, "README explains the new behavior.")
    }

    func testMissionPlanCurrentPersistedFixtureRoundTripsMissionOwnedFields() throws {
        let plan = try decodeMissionPlanFixture(Self.currentMissionPlanFixture)

        XCTAssertEqual(plan.shapeSummary?.id, "single-track")
        XCTAssertEqual(plan.shapeSummary?.displayName, "Single track")
        XCTAssertEqual(plan.shapeSummary?.namedClose, "Close with receipt")
        XCTAssertEqual(plan.policySnapshot?.id, "careful-writes")
        XCTAssertEqual(plan.policySnapshot?.maxConcurrent, CoordinatorMissionPolicySnapshot.defaultMaxConcurrent)
        XCTAssertEqual(plan.policySnapshot?.pinnedSkillIDs, ["rpce-test-quality"])
        XCTAssertEqual(plan.autonomy[CoordinatorMissionDecisionClass.writes.rawValue], .ask)
        XCTAssertEqual(plan.nodes.first?.doneCriteria, "README and tests describe the behavior.")
        XCTAssertEqual(plan.decisions.map(\.label), ["approved the Mission plan", "started implementation"])
        XCTAssertEqual(plan.evidence.map(\.verdict), [.meets, .short])

        let data = try JSONEncoder().encode(plan)
        let decodedAgain = try JSONDecoder().decode(CoordinatorMissionPlan.self, from: data)
        XCTAssertEqual(decodedAgain, plan)
    }

    func testMissionPlanDirectorDoctrineFieldsRoundTripLosslessly() throws {
        let nodeID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000901"))
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000902"))
        let interactionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000903"))
        let routingDecisionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000904"))
        let firstDecisionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000905"))
        let overruleDecisionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000906"))
        let evidenceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000907"))
        let plan = CoordinatorMissionPlan(
            objective: "Ship Director receipt",
            policySnapshot: CoordinatorMissionPolicySnapshot(
                id: "director-default",
                name: "Director default",
                defaultPace: .auto,
                maxConcurrent: 5,
                definitionOfDone: "Done criteria are disclosed with evidence."
            ),
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: firstDecisionID,
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "advanced after read-only probe",
                    timestamp: Date(timeIntervalSince1970: 10)
                ),
                CoordinatorMissionDecisionRecord(
                    id: overruleDecisionID,
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "corrected probe conclusion",
                    timestamp: Date(timeIntervalSince1970: 11),
                    overruledDecisionID: firstDecisionID,
                    overruleReason: "Probe evidence was incomplete.",
                    correctionReason: "Diff stats showed one missing test file.",
                    correctionSteerText: "Re-check the focused persistence test."
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: evidenceID,
                    verdict: .meets,
                    summary: "Structured evidence is a summary, not a transcript.",
                    timestamp: Date(timeIntervalSince1970: 12),
                    nodeID: nodeID,
                    sessionID: sessionID,
                    interactionID: interactionID,
                    decisionID: overruleDecisionID,
                    source: CoordinatorMissionEvidenceSource(
                        kind: "probe_answer",
                        operation: .agentExploreStart,
                        routingDecisionID: routingDecisionID,
                        nodeID: nodeID,
                        sessionID: sessionID,
                        interactionID: interactionID,
                        answerID: "probe-answer-1",
                        summary: "Explore probe mapped the relevant files."
                    ),
                    judgmentBundle: CoordinatorMissionJudgmentBundle(
                        doneCriteria: "Focused tests pass.",
                        structuredEvidence: "Persistence and MCP contract tests cover the new fields.",
                        diffStats: CoordinatorMissionDiffStats(
                            filesChanged: 3,
                            insertions: 120,
                            deletions: 4,
                            summary: "Schema, MCP, and tests changed."
                        ),
                        probeAnswer: CoordinatorMissionProbeAnswerSummary(
                            answerID: "probe-answer-1",
                            source: "agent_explore.start",
                            answer: "Relevant files are CoordinatorFollowThroughState and CoordinatorChatMCPToolServiceTests.",
                            sessionID: sessionID,
                            interactionID: interactionID,
                            routingDecisionID: routingDecisionID
                        )
                    )
                )
            ]
        )

        let data = try JSONEncoder().encode(plan)
        let decodedAgain = try JSONDecoder().decode(CoordinatorMissionPlan.self, from: data)

        XCTAssertEqual(decodedAgain.policySnapshot?.maxConcurrent, 5)
        XCTAssertEqual(decodedAgain.decisions.last?.overruledDecisionID, firstDecisionID)
        XCTAssertEqual(decodedAgain.decisions.last?.correctionSteerText, "Re-check the focused persistence test.")
        XCTAssertEqual(decodedAgain.evidence.first?.source?.operation, .agentExploreStart)
        XCTAssertEqual(decodedAgain.evidence.first?.source?.answerID, "probe-answer-1")
        XCTAssertEqual(decodedAgain.evidence.first?.judgmentBundle?.doneCriteria, "Focused tests pass.")
        XCTAssertEqual(decodedAgain.evidence.first?.judgmentBundle?.diffStats?.filesChanged, 3)
        XCTAssertEqual(decodedAgain.evidence.first?.judgmentBundle?.probeAnswer?.source, "agent_explore.start")
        XCTAssertEqual(decodedAgain.evidence.first?.judgmentBundle?.transcriptFraming, CoordinatorMissionJudgmentBundle.notTranscriptFraming)
        XCTAssertEqual(decodedAgain, plan)
    }

    func testMissionPlanForwardFixtureUnknownAutonomyAndDecisionClassRoundTripLosslessly() throws {
        let plan = try decodeMissionPlanFixture(Self.forwardMissionPlanFixture)

        XCTAssertEqual(plan.autonomy["reshape"], .auto)
        XCTAssertEqual(plan.resolvedAutonomy(for: "reshape"), .ask)
        XCTAssertEqual(plan.resolvedAutonomy(for: "plan"), .auto)
        XCTAssertEqual(plan.resolvedAutonomy(for: "irreversible"), .ask)
        XCTAssertEqual(plan.decisions.first?.decisionClass, "reshape")
        XCTAssertNil(plan.decisions.first?.resolvedAutonomyClass)

        let data = try JSONEncoder().encode(plan)
        let decodedAgain = try JSONDecoder().decode(CoordinatorMissionPlan.self, from: data)
        XCTAssertEqual(decodedAgain.autonomy["reshape"], .auto)
        XCTAssertEqual(decodedAgain.decisions.first?.decisionClass, "reshape")
        XCTAssertEqual(decodedAgain.decisions.first?.label, "accepted future shape proposal")
    }

    func testDecisionAndEvidenceUpdatesAppendOnlyAndDedupeByRecordIDOnly() throws {
        let originalDecisionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000701"))
        let secondDecisionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000702"))
        let originalEvidenceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000801"))
        let secondEvidenceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000802"))
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Ship docs",
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: originalDecisionID,
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "continue after evidence",
                    timestamp: Date(timeIntervalSince1970: 10)
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: originalEvidenceID,
                    verdict: .meets,
                    summary: "Existing evidence stays first.",
                    timestamp: Date(timeIntervalSince1970: 11)
                )
            ]
        ))

        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            decisions: [
                CoordinatorMissionDecisionRecord(
                    id: originalDecisionID,
                    decisionClass: CoordinatorMissionDecisionClass.irreversible.rawValue,
                    actor: .director,
                    label: "duplicate id must not replace",
                    timestamp: Date(timeIntervalSince1970: 20)
                ),
                CoordinatorMissionDecisionRecord(
                    id: secondDecisionID,
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .director,
                    label: "continue after evidence",
                    timestamp: Date(timeIntervalSince1970: 21)
                )
            ],
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    id: originalEvidenceID,
                    verdict: .short,
                    summary: "Duplicate id must not replace.",
                    timestamp: Date(timeIntervalSince1970: 22)
                ),
                CoordinatorMissionEvidenceRecord(
                    id: secondEvidenceID,
                    verdict: .meets,
                    summary: "Same semantic evidence with a new id appends.",
                    timestamp: Date(timeIntervalSince1970: 23)
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 30)
        ))

        let plan = try XCTUnwrap(state.missionPlan)
        XCTAssertEqual(plan.decisions.map(\.id), [originalDecisionID, secondDecisionID])
        XCTAssertEqual(plan.decisions.map(\.label), ["continue after evidence", "continue after evidence"])
        XCTAssertEqual(plan.decisions.first?.decisionClass, CoordinatorMissionDecisionClass.advance.rawValue)
        XCTAssertEqual(plan.evidence.map(\.id), [originalEvidenceID, secondEvidenceID])
        XCTAssertEqual(plan.evidence.map(\.summary), ["Existing evidence stays first.", "Same semantic evidence with a new id appends."])
        XCTAssertEqual(plan.evidence.first?.verdict, .meets)
    }

    func testPlanUserDecisionIDsAreDeterministicAcrossRetriesAndRevisionAware() throws {
        let approvalR1 = CoordinatorMissionDecisionRecord(
            userDecision: .approvedMissionPlan,
            decisionClass: .plan,
            checkpointInstanceID: "mission-plan:revision:1",
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let approvalR1Retry = CoordinatorMissionDecisionRecord(
            userDecision: .approvedMissionPlan,
            decisionClass: .plan,
            checkpointInstanceID: "mission-plan:revision:1",
            timestamp: Date(timeIntervalSince1970: 11)
        )
        let revisionRequestR1 = CoordinatorMissionDecisionRecord(
            userDecision: .requestedPlanRevision,
            decisionClass: .plan,
            checkpointInstanceID: "mission-plan:revision:1",
            timestamp: Date(timeIntervalSince1970: 12)
        )
        let approvalR3 = CoordinatorMissionDecisionRecord(
            userDecision: .approvedMissionPlan,
            decisionClass: .plan,
            checkpointInstanceID: "mission-plan:revision:3",
            timestamp: Date(timeIntervalSince1970: 13)
        )

        XCTAssertEqual(approvalR1.id, approvalR1Retry.id)
        XCTAssertNotEqual(approvalR1.id, revisionRequestR1.id)
        XCTAssertNotEqual(approvalR1.id, approvalR3.id)
        XCTAssertEqual(approvalR1.actor, .user)
        XCTAssertEqual(approvalR1.label, "approved the Mission plan")

        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(objective: "Ship docs"))
        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            decisions: [approvalR1, approvalR1Retry, revisionRequestR1, approvalR3],
            updatedAt: Date(timeIntervalSince1970: 20)
        ))

        let decisions = try XCTUnwrap(state.missionPlan?.decisions)
        XCTAssertEqual(decisions.map(\.id), [approvalR1.id, revisionRequestR1.id, approvalR3.id])
        XCTAssertEqual(decisions.map(\.label), [
            "approved the Mission plan",
            "requested plan revision",
            "approved the Mission plan"
        ])
    }

    private func decodeMissionPlanFixture(_ json: String) throws -> CoordinatorMissionPlan {
        try JSONDecoder().decode(CoordinatorMissionPlan.self, from: Data(json.utf8))
    }

    private static let oldMissionPlanFixture = """
    {
      "id": "00000000-0000-4000-8000-000000000101",
      "revision": 1,
      "objective": "Ship docs",
      "status": "draft",
      "approvalState": "not_required",
      "workstreams": [
        {
          "id": "00000000-0000-4000-8000-000000000201",
          "title": "Docs",
          "purpose": "Update README wording.",
          "defaultPolicy": "fresh_worktree",
          "worktreeStrategy": {
            "mode": "createIsolated"
          },
          "relatedSessionIDs": []
        }
      ],
      "nodes": [
        {
          "id": "00000000-0000-4000-8000-000000000301",
          "title": "Update README",
          "completionEvidence": "README explains the new behavior.",
          "workstreamID": "00000000-0000-4000-8000-000000000201",
          "dependsOn": [],
          "executionPolicy": "fresh_worktree",
          "status": "pending"
        }
      ],
      "events": [],
      "updatedAt": 0
    }
    """

    private static let currentMissionPlanFixture = """
    {
      "id": "00000000-0000-4000-8000-000000000102",
      "revision": 2,
      "missionKey": "mission-docs",
      "objective": "Ship docs",
      "status": "running",
      "approvalState": "approved",
      "shapeSummary": {
        "id": "single-track",
        "displayName": "Single track",
        "reason": "One docs lane is enough.",
        "namedClose": "Close with receipt"
      },
      "policySnapshot": {
        "id": "careful-writes",
        "name": "Careful writes",
        "defaultPace": "step",
        "autonomy": {
          "plan": "ask",
          "advance": "ask",
          "writes": "ask",
          "childAsk": "ask",
          "recover": "auto",
          "irreversible": "ask"
        },
        "definitionOfDone": "README and tests describe the behavior.",
        "standingGuidance": "Ask before edits.",
        "pinnedSkillIDs": ["rpce-test-quality"],
        "pinnedContextIDs": ["docs-plan"]
      },
      "autonomy": {
        "plan": "ask",
        "advance": "ask",
        "writes": "ask",
        "childAsk": "ask",
        "recover": "auto",
        "irreversible": "ask"
      },
      "workstreams": [
        {
          "id": "00000000-0000-4000-8000-000000000202",
          "title": "Docs",
          "purpose": "Update README wording.",
          "defaultPolicy": "fresh_worktree",
          "worktreeStrategy": {
            "mode": "createIsolated",
            "worktreeID": "wt-docs"
          },
          "relatedSessionIDs": []
        }
      ],
      "nodes": [
        {
          "id": "00000000-0000-4000-8000-000000000302",
          "title": "Update README",
          "completionEvidence": "README explains the new behavior.",
          "doneCriteria": "README and tests describe the behavior.",
          "workstreamID": "00000000-0000-4000-8000-000000000202",
          "dependsOn": [],
          "executionPolicy": "fresh_worktree",
          "status": "running"
        }
      ],
      "routingDecisions": [],
      "decisions": [
        {
          "id": "00000000-0000-4000-8000-000000000401",
          "decisionClass": "plan",
          "actor": "user",
          "label": "approved the Mission plan",
          "reason": "Plan is small and clear.",
          "timestamp": 10,
          "checkpointID": "plan-approval",
          "checkpointInstanceID": "mission-plan:revision:1"
        },
        {
          "id": "00000000-0000-4000-8000-000000000402",
          "decisionClass": "advance",
          "actor": "director",
          "label": "started implementation",
          "reason": "The approved plan has one unblocked node.",
          "timestamp": 11,
          "nodeID": "00000000-0000-4000-8000-000000000302"
        }
      ],
      "evidence": [
        {
          "id": "00000000-0000-4000-8000-000000000501",
          "verdict": "meets",
          "summary": "README wording is updated.",
          "timestamp": 12,
          "nodeID": "00000000-0000-4000-8000-000000000302"
        },
        {
          "id": "00000000-0000-4000-8000-000000000502",
          "verdict": "short",
          "summary": "Tests are still pending.",
          "timestamp": 13,
          "nodeID": "00000000-0000-4000-8000-000000000302"
        }
      ],
      "events": [],
      "updatedAt": 14
    }
    """

    private static let forwardMissionPlanFixture = """
    {
      "id": "00000000-0000-4000-8000-000000000103",
      "revision": 3,
      "objective": "Ship future shape",
      "status": "draft",
      "approvalState": "awaiting_approval",
      "autonomy": {
        "plan": "auto",
        "reshape": "auto",
        "irreversible": "auto"
      },
      "workstreams": [],
      "nodes": [],
      "routingDecisions": [],
      "decisions": [
        {
          "id": "00000000-0000-4000-8000-000000000601",
          "decisionClass": "reshape",
          "actor": "director",
          "label": "accepted future shape proposal",
          "reason": "Forward fixture exercises unknown decision classes.",
          "timestamp": 20
        }
      ],
      "evidence": [],
      "events": [],
      "updatedAt": 21
    }
    """
}
