@testable import RepoPrompt
import XCTest

final class CoordinatorMissionMaterialContractTests: XCTestCase {
    func testEveryRatifiedMaterialFieldChangesStructuralIdentity() {
        let base = makePlan()
        let baseSnapshot = base.materialContractSnapshot
        let newWorkstreamID = uuid(90)

        let mutations: [(String, (inout CoordinatorMissionPlan) -> Void)] = [
            ("mission key", { $0.missionKey = "mission-v2" }),
            ("objective", { $0.objective = "Changed objective" }),
            ("predecessor ID", { $0.predecessorMissionID = self.uuid(91) }),
            ("predecessor title", { $0.predecessorTitle = "Changed predecessor" }),
            ("predecessor summary", { $0.predecessorSummary = "Changed lineage" }),
            ("shape ID", { $0.shapeSummary?.id = "parallel" }),
            ("shape display name", { $0.shapeSummary?.displayName = "Parallel" }),
            ("shape reason", { $0.shapeSummary?.reason = "Changed shape reason" }),
            ("shape named close", { $0.shapeSummary?.namedClose = "Changed close" }),
            ("shape presence", { $0.shapeSummary = nil }),
            ("policy ID", { $0.policySnapshot?.id = "custom-v2" }),
            ("policy name", { $0.policySnapshot?.name = "Changed policy" }),
            ("pace", { $0.policySnapshot?.defaultPace = .step }),
            ("policy autonomy", { $0.policySnapshot?.autonomy["recover"] = .ask }),
            ("concurrency", { $0.policySnapshot?.maxConcurrent = 7 }),
            ("definition of done", { $0.policySnapshot?.definitionOfDone = "Changed done" }),
            ("guidance", { $0.policySnapshot?.standingGuidance = "Changed guidance" }),
            ("pinned skills", { $0.policySnapshot?.pinnedSkillIDs.append("skill-c") }),
            ("pinned contexts", { $0.policySnapshot?.pinnedContextIDs.append("context-c") }),
            ("policy presence", { $0.policySnapshot = nil }),
            ("plan autonomy", { $0.autonomy["childAsk"] = .auto }),
            ("workstream membership", {
                $0.workstreams.append(CoordinatorMissionWorkstreamSummary(
                    id: newWorkstreamID,
                    title: "New stream",
                    purpose: "New purpose",
                    defaultPolicy: .coordinatorOnly,
                    worktreeStrategy: .init(mode: .noneReadOnly)
                ))
            }),
            ("workstream ID", {
                $0.workstreams[0] = self.workstream($0.workstreams[0], replacingIDWith: self.uuid(95))
            }),
            ("workstream title", { $0.workstreams[0].title = "Changed stream" }),
            ("workstream purpose", { $0.workstreams[0].purpose = "Changed purpose" }),
            ("workstream role", { $0.workstreams[0].role = "changed-role" }),
            ("workstream default policy", { $0.workstreams[0].defaultPolicy = .askUser }),
            ("worktree mode", { $0.workstreams[0].worktreeStrategy.mode = .askUser }),
            ("worktree base ref", { $0.workstreams[0].worktreeStrategy.baseRef = "release" }),
            ("worktree base reason", { $0.workstreams[0].worktreeStrategy.baseReason = "Changed base" }),
            ("worktree reason", { $0.workstreams[0].worktreeStrategy.reason = "Changed reason" }),
            ("node membership", {
                $0.nodes.append(CoordinatorMissionPlanNode(
                    id: self.uuid(92),
                    title: "New node",
                    workstreamID: newWorkstreamID,
                    executionPolicy: .coordinatorOnly
                ))
            }),
            ("node ID", {
                $0.nodes[0] = self.node($0.nodes[0], replacingIDWith: self.uuid(96))
            }),
            ("node title", { $0.nodes[0].title = "Changed node" }),
            ("node detail", { $0.nodes[0].detail = "Changed detail" }),
            ("workflow ID", { $0.nodes[0].workflowHint?.id = "changed-workflow" }),
            ("workflow name", { $0.nodes[0].workflowHint?.name = "Changed workflow" }),
            ("workflow icon", { $0.nodes[0].workflowHint?.iconName = "bolt" }),
            ("workflow accent", { $0.nodes[0].workflowHint?.accentColorHex = "#FFFFFF" }),
            ("node done criteria", { $0.nodes[0].doneCriteria = "Changed criteria" }),
            ("node workstream", { $0.nodes[0].workstreamID = self.uuid(93) }),
            ("node dependencies", { $0.nodes[0].dependsOn.append(self.uuid(94)) }),
            ("node role", { $0.nodes[0].role = "changed-node-role" }),
            ("node execution policy", { $0.nodes[0].executionPolicy = .askUser })
        ]

        for (field, mutate) in mutations {
            var changed = base
            mutate(&changed)
            XCTAssertFalse(
                CoordinatorMissionMaterialContractComparator.matches(baseSnapshot, current: changed),
                "Expected material field to invalidate structural CAS: \(field)"
            )
        }
    }

    func testRuntimeFieldsDoNotChangeSnapshotOrFingerprint() throws {
        let base = makePlan()
        let expectedSnapshot = base.materialContractSnapshot
        let expectedFingerprint = try base.materialContractFingerprint()
        let runtimeMutations: [(String, (inout CoordinatorMissionPlan) -> Void)] = [
            ("plan ID", { $0.id = self.uuid(101) }),
            ("revision", { $0.revision += 10 }),
            ("status", { $0.status = .completed }),
            ("approval state", { $0.approvalState = .revisionRequested }),
            ("template", { $0.template = .init(id: "other", displayName: "Other", iconName: "circle") }),
            ("runtime worktree ID", { $0.workstreams[0].worktreeStrategy.worktreeID = "assigned-runtime-worktree" }),
            ("primary session binding", { $0.workstreams[0].primarySessionID = self.uuid(102) }),
            ("related session bindings", { $0.workstreams[0].relatedSessionIDs = [self.uuid(103)] }),
            ("completion evidence", { $0.nodes[0].completionEvidence = "Runtime evidence" }),
            ("node status", { $0.nodes[0].status = .completed }),
            ("bound session", { $0.nodes[0].boundSessionID = self.uuid(104) }),
            ("bound interaction", { $0.nodes[0].boundInteractionID = self.uuid(105) }),
            ("routing decisions", {
                $0.routingDecisions.append(.init(
                    decision: .startFreshWorktree,
                    operation: .agentRunStart,
                    reason: "Runtime route"
                ))
            }),
            ("decisions", {
                $0.decisions.append(.init(
                    decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                    actor: .user,
                    label: "Runtime decision"
                ))
            }),
            ("evidence", { $0.evidence.append(.init(verdict: .meets, summary: "Runtime evidence")) }),
            ("events", { $0.events.append(.init(kind: .nodeCompleted, summary: "Runtime event")) }),
            ("continuation", {
                $0.postApprovalContinuation = CoordinatorPostApprovalContinuationRecord(
                    coordinatorSessionID: self.uuid(106),
                    checkpointInstanceID: "checkpoint",
                    planID: $0.id,
                    planRevision: $0.revision,
                    directiveText: "Continue"
                )
            }),
            ("updated time", { $0.updatedAt = Date(timeIntervalSince1970: 999) })
        ]

        for (field, mutate) in runtimeMutations {
            var changed = base
            mutate(&changed)
            XCTAssertEqual(changed.materialContractSnapshot, expectedSnapshot, "Runtime field leaked into snapshot: \(field)")
            XCTAssertEqual(try changed.materialContractFingerprint(), expectedFingerprint, "Runtime field changed fingerprint: \(field)")
        }

        var state = CoordinatorFollowThroughState(missionPlan: base)
        state.observedChildPhases[uuid(107)] = .done
        state.childInteractionResponses.append(.init(
            childSessionID: uuid(108),
            childTitle: "Child",
            interactionID: uuid(109),
            answeredAt: Date(timeIntervalSince1970: 1000),
            responseText: "Answer"
        ))
        XCTAssertEqual(state.missionPlan?.materialContractSnapshot, expectedSnapshot)
    }

    func testCanonicalOrderingIsStableForMapAndSetLikeValues() throws {
        let first = makePlan()
        var reordered = first
        reordered.workstreams.reverse()
        reordered.nodes.reverse()
        reordered.nodes[1].dependsOn.reverse()
        reordered.policySnapshot?.pinnedSkillIDs = ["skill-a", "skill-b", "skill-a"]
        reordered.policySnapshot?.pinnedContextIDs = ["context-a", "context-b", "context-a"]
        reordered.policySnapshot?.autonomy = [
            "recover": .auto,
            "childAsk": .ask,
            "writes": .auto
        ]
        reordered.autonomy = [
            "writes": .auto,
            "childAsk": .ask,
            "recover": .auto
        ]

        XCTAssertEqual(first.materialContractSnapshot, reordered.materialContractSnapshot)
        XCTAssertEqual(try first.materialContractSnapshot.canonicalData(), try reordered.materialContractSnapshot.canonicalData())
        XCTAssertEqual(try first.materialContractFingerprint(), try reordered.materialContractFingerprint())
    }

    func testUnicodeCanonicalEquivalenceNormalizesAllMaterialStringsBeforeOrderingAndDeduplication() throws {
        let composed = "é"
        let decomposed = "e\u{301}"
        var nfcPlan = makePlan()
        var nfdPlan = makePlan()
        applyUnicodeMaterialStrings(composed, to: &nfcPlan, duplicatePinnedIDs: false)
        applyUnicodeMaterialStrings(decomposed, to: &nfdPlan, duplicatePinnedIDs: true)

        let nfcSnapshot = nfcPlan.materialContractSnapshot
        let canonicalData = try nfcSnapshot.canonicalData()
        XCTAssertEqual(nfcSnapshot, nfdPlan.materialContractSnapshot)
        XCTAssertEqual(canonicalData, try nfdPlan.materialContractSnapshot.canonicalData())
        XCTAssertEqual(try nfcPlan.materialContractFingerprint(), try nfdPlan.materialContractFingerprint())

        let decomposedJSON = try XCTUnwrap(String(data: canonicalData, encoding: .utf8))
            .decomposedStringWithCanonicalMapping
        let decoded = try JSONDecoder().decode(
            CoordinatorMissionMaterialContractSnapshot.self,
            from: Data(decomposedJSON.utf8)
        )
        XCTAssertEqual(decoded, nfcSnapshot)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonicalData) as? [String: Any])
        var autonomy = try XCTUnwrap(object["autonomy"] as? [[String: Any]])
        var conflicting = try XCTUnwrap(autonomy.first)
        conflicting["key"] = try XCTUnwrap(conflicting["key"] as? String).decomposedStringWithCanonicalMapping
        conflicting["mode"] = try XCTUnwrap(conflicting["mode"] as? String) == "ask" ? "auto" : "ask"
        autonomy.append(conflicting)
        object["autonomy"] = autonomy
        let conflictingData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(
            CoordinatorMissionMaterialContractSnapshot.self,
            from: conflictingData
        ))
    }

    func testEvidenceOnlyProgressPreservesContractIdentity() throws {
        let base = makePlan()
        var progressed = base
        progressed.revision += 1
        progressed.nodes[0].status = .completed
        progressed.nodes[0].completionEvidence = "All checks passed."
        progressed.evidence.append(.init(verdict: .meets, summary: "All checks passed."))
        progressed.events.append(.init(kind: .nodeCompleted, nodeID: progressed.nodes[0].id))

        XCTAssertTrue(CoordinatorMissionMaterialContractComparator.matches(base.materialContractSnapshot, current: progressed))
        XCTAssertEqual(try base.materialContractFingerprint(), try progressed.materialContractFingerprint())
    }

    func testStructuralCASDetectsStaleMaterialContractDespiteUnchangedRevision() throws {
        let base = makePlan()
        let baseSnapshot = base.materialContractSnapshot
        let baseFingerprint = try base.materialContractFingerprint()
        var stale = base
        stale.objective = "Materially changed objective"
        stale.revision = base.revision

        XCTAssertFalse(CoordinatorMissionMaterialContractComparator.matches(baseSnapshot, current: stale))
        XCTAssertNotEqual(try stale.materialContractFingerprint(), baseFingerprint)
        XCTAssertEqual(baseFingerprint, "42007ef2e88663e1ec8646015e0685ee3a475f758c5d0dfb793593a0ae46d60f")
        XCTAssertEqual(baseFingerprint.count, 64)
        XCTAssertNotNil(baseFingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    }

    func testMaterialContractDeltaClassifiesStructuralChangesAndPromiseDriftDeterministically() {
        let base = makePlan()
        var revised = base
        revised.objective = "Revised objective"
        revised.workstreams[0].worktreeStrategy.mode = .askUser
        revised.nodes[0].title = "Unexpected node title"
        revised.nodes.removeLast()
        revised.nodes.append(CoordinatorMissionPlanNode(
            id: uuid(99),
            title: "Added step",
            workstreamID: revised.workstreams[0].id,
            executionPolicy: .coordinatorOnly
        ))

        let delta = materialContractDelta(
            from: base.materialContractSnapshot,
            to: revised.materialContractSnapshot,
            proposalAffectedFields: ["objective", "workstreams"]
        )
        XCTAssertEqual(delta.fields.map(\.path), delta.fields.map(\.path).sorted())
        XCTAssertEqual(
            delta.materialChanges.first(where: { $0.path == "objective" })?.promiseClassification,
            .withinStatedAffectedAreas
        )
        XCTAssertEqual(
            delta.materialChanges.first(where: { $0.path.hasSuffix(".planned_worktree_strategy") })?.change,
            .changed
        )
        XCTAssertEqual(
            delta.materialChanges.first(where: { $0.path.hasSuffix(".planned_worktree_strategy") })?.promiseClassification,
            .withinStatedAffectedAreas
        )
        XCTAssertTrue(delta.materialChanges.contains {
            $0.change == .removed && $0.path == "nodes.\(self.uuid(41).uuidString.lowercased())"
        })
        XCTAssertTrue(delta.materialChanges.contains {
            $0.change == .added && $0.path == "nodes.\(self.uuid(99).uuidString.lowercased())"
        })
        XCTAssertTrue(delta.unexpectedChanges.contains { $0.path.hasSuffix(".title") })
        XCTAssertTrue(delta.fields.contains {
            $0.change == .unchanged && $0.promiseClassification == .unchanged
        })
        for field in delta.materialChanges {
            XCTAssertNotEqual(field.beforeCanonicalValue, field.afterCanonicalValue)
        }

        let repeated = materialContractDelta(
            from: base.materialContractSnapshot,
            to: revised.materialContractSnapshot,
            proposalAffectedFields: ["workstreams", "objective"]
        )
        XCTAssertEqual(delta, repeated)
    }

    func testMaterialContractDeltaExcludesRuntimeBindingsButNamesPlannedWorktreeStrategy() {
        let base = makePlan()
        var runtimeOnly = base
        runtimeOnly.workstreams[0].worktreeStrategy.worktreeID = "runtime-binding"
        runtimeOnly.workstreams[0].primarySessionID = uuid(200)
        runtimeOnly.workstreams[0].relatedSessionIDs = [uuid(201)]
        runtimeOnly.nodes[0].boundSessionID = uuid(202)

        XCTAssertTrue(materialContractDelta(
            from: base.materialContractSnapshot,
            to: runtimeOnly.materialContractSnapshot,
            proposalAffectedFields: ["workstreams"]
        ).materialChanges.isEmpty)

        var planned = base
        planned.workstreams[0].worktreeStrategy.baseRef = "release"
        let delta = materialContractDelta(
            from: base.materialContractSnapshot,
            to: planned.materialContractSnapshot,
            proposalAffectedFields: ["workstreams"]
        )
        XCTAssertEqual(delta.materialChanges.count, 1)
        XCTAssertTrue(delta.materialChanges[0].path.hasSuffix(".planned_worktree_strategy"))
    }

    private func makePlan() -> CoordinatorMissionPlan {
        let workstreamA = uuid(1)
        let workstreamB = uuid(2)
        let dependencyA = uuid(11)
        let dependencyB = uuid(12)
        return CoordinatorMissionPlan(
            id: uuid(20),
            revision: 7,
            missionKey: "mission-v1",
            objective: "Ship the ratified contract",
            predecessorMissionID: uuid(21),
            predecessorTitle: "Previous mission",
            predecessorSummary: "Approved predecessor lineage",
            status: .approved,
            approvalState: .approved,
            template: .init(id: "orchestrate", displayName: "Orchestrate", iconName: "circle.hexagongrid"),
            shapeSummary: .init(
                id: "dag",
                displayName: "DAG",
                reason: "Parallelize safely",
                namedClose: "Verified delivery"
            ),
            policySnapshot: CoordinatorMissionPolicySnapshot(
                id: "custom",
                name: "Custom",
                defaultPace: .auto,
                autonomy: [
                    "writes": .auto,
                    "childAsk": .ask,
                    "recover": .auto
                ],
                maxConcurrent: 4,
                definitionOfDone: "Every criterion passes.",
                standingGuidance: "Keep trust boundaries visible.",
                pinnedSkillIDs: ["skill-b", "skill-a"],
                pinnedContextIDs: ["context-b", "context-a"]
            ),
            autonomy: [
                "recover": .auto,
                "writes": .auto,
                "childAsk": .ask
            ],
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamB,
                    title: "Review",
                    purpose: "Review the result",
                    role: "reviewer",
                    defaultPolicy: .planCritique,
                    worktreeStrategy: .init(
                        mode: .reuseWorkstream,
                        worktreeID: "runtime-b",
                        baseRef: "main",
                        baseReason: "Approved base",
                        reason: "Review together"
                    ),
                    primarySessionID: uuid(31),
                    relatedSessionIDs: [uuid(32)]
                ),
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamA,
                    title: "Build",
                    purpose: "Build the result",
                    role: "engineer",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: .init(
                        mode: .createIsolated,
                        worktreeID: "runtime-a",
                        baseRef: "main",
                        baseReason: "Approved base",
                        reason: "Isolate writes"
                    ),
                    primarySessionID: uuid(33),
                    relatedSessionIDs: [uuid(34)]
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: uuid(42),
                    title: "Review node",
                    detail: "Review details",
                    workflowHint: .init(
                        id: "review",
                        name: "Review",
                        iconName: "checkmark",
                        accentColorHex: "#00FF00"
                    ),
                    completionEvidence: "Runtime review evidence",
                    doneCriteria: "Review passes",
                    workstreamID: workstreamB,
                    dependsOn: [dependencyB, dependencyA],
                    role: "reviewer",
                    executionPolicy: .planCritique,
                    status: .running,
                    boundSessionID: uuid(35),
                    boundInteractionID: uuid(36)
                ),
                CoordinatorMissionPlanNode(
                    id: uuid(41),
                    title: "Build node",
                    detail: "Build details",
                    workflowHint: .init(
                        id: "build",
                        name: "Build",
                        iconName: "hammer",
                        accentColorHex: "#FF0000"
                    ),
                    completionEvidence: "Runtime build evidence",
                    doneCriteria: "Build passes",
                    workstreamID: workstreamA,
                    dependsOn: [],
                    role: "engineer",
                    executionPolicy: .freshWorktree,
                    status: .completed,
                    boundSessionID: uuid(37),
                    boundInteractionID: uuid(38)
                )
            ],
            routingDecisions: [
                .init(decision: .startFreshWorktree, operation: .agentRunStart, reason: "Runtime route")
            ],
            decisions: [
                .init(
                    decisionClass: CoordinatorMissionDecisionClass.plan.rawValue,
                    actor: .user,
                    label: "Approved"
                )
            ],
            evidence: [.init(verdict: .meets, summary: "Runtime evidence")],
            events: [.init(kind: .approved, summary: "Approved")],
            postApprovalContinuation: CoordinatorPostApprovalContinuationRecord(
                coordinatorSessionID: uuid(50),
                checkpointInstanceID: "checkpoint",
                planID: uuid(20),
                planRevision: 7,
                directiveText: "Continue"
            ),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func applyUnicodeMaterialStrings(
        _ accent: String,
        to plan: inout CoordinatorMissionPlan,
        duplicatePinnedIDs: Bool
    ) {
        func value(_ prefix: String) -> String {
            "\(prefix)-\(accent)"
        }

        plan.missionKey = value("mission")
        plan.objective = value("objective")
        plan.predecessorTitle = value("predecessor-title")
        plan.predecessorSummary = value("predecessor-summary")
        plan.shapeSummary?.id = value("shape-id")
        plan.shapeSummary?.displayName = value("shape-name")
        plan.shapeSummary?.reason = value("shape-reason")
        plan.shapeSummary?.namedClose = value("shape-close")
        plan.policySnapshot?.id = value("policy-id")
        plan.policySnapshot?.name = value("policy-name")
        plan.policySnapshot?.autonomy = [value("policy-autonomy-key"): .ask]
        plan.policySnapshot?.definitionOfDone = value("definition-of-done")
        plan.policySnapshot?.standingGuidance = value("guidance")
        plan.policySnapshot?.pinnedSkillIDs = duplicatePinnedIDs
            ? [value("skill-stable"), "skill-é", value("skill")]
            : [value("skill"), value("skill-stable")]
        plan.policySnapshot?.pinnedContextIDs = duplicatePinnedIDs
            ? [value("context-stable"), "context-é", value("context")]
            : [value("context"), value("context-stable")]
        plan.autonomy = [value("plan-autonomy-key"): .auto]
        plan.workstreams[0].title = value("workstream-title")
        plan.workstreams[0].purpose = value("workstream-purpose")
        plan.workstreams[0].role = value("workstream-role")
        plan.workstreams[0].worktreeStrategy.baseRef = value("base-ref")
        plan.workstreams[0].worktreeStrategy.baseReason = value("base-reason")
        plan.workstreams[0].worktreeStrategy.reason = value("worktree-reason")
        plan.nodes[0].title = value("node-title")
        plan.nodes[0].detail = value("node-detail")
        plan.nodes[0].workflowHint?.id = value("workflow-id")
        plan.nodes[0].workflowHint?.name = value("workflow-name")
        plan.nodes[0].workflowHint?.iconName = value("workflow-icon")
        plan.nodes[0].workflowHint?.accentColorHex = value("workflow-accent")
        plan.nodes[0].doneCriteria = value("node-done")
        plan.nodes[0].role = value("node-role")
    }

    private func workstream(
        _ workstream: CoordinatorMissionWorkstreamSummary,
        replacingIDWith id: UUID
    ) -> CoordinatorMissionWorkstreamSummary {
        CoordinatorMissionWorkstreamSummary(
            id: id,
            title: workstream.title,
            purpose: workstream.purpose,
            role: workstream.role,
            defaultPolicy: workstream.defaultPolicy,
            worktreeStrategy: workstream.worktreeStrategy,
            primarySessionID: workstream.primarySessionID,
            relatedSessionIDs: workstream.relatedSessionIDs
        )
    }

    private func node(
        _ node: CoordinatorMissionPlanNode,
        replacingIDWith id: UUID
    ) -> CoordinatorMissionPlanNode {
        CoordinatorMissionPlanNode(
            id: id,
            title: node.title,
            detail: node.detail,
            workflowHint: node.workflowHint,
            completionEvidence: node.completionEvidence,
            doneCriteria: node.doneCriteria,
            workstreamID: node.workstreamID,
            dependsOn: node.dependsOn,
            role: node.role,
            executionPolicy: node.executionPolicy,
            status: node.status,
            boundSessionID: node.boundSessionID,
            boundInteractionID: node.boundInteractionID
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}
