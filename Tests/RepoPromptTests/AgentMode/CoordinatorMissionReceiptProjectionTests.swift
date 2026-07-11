@testable import RepoPrompt
import XCTest

final class CoordinatorMissionReceiptProjectionTests: XCTestCase {
    func testMarkdownOutputIsDeterministic() {
        let plan = makePlan()

        let first = CoordinatorMissionReceiptProjection(plan: plan).markdown
        let second = CoordinatorMissionReceiptProjection(plan: plan).markdown

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, expectedMarkdown)
    }

    func testMarkdownIncludesReservedSpendSection() {
        let markdown = CoordinatorMissionReceiptProjection(plan: makePlan()).markdown

        XCTAssertTrue(markdown.contains("## Spend"))
        XCTAssertTrue(markdown.contains(CoordinatorMissionReceiptProjection.spendReserveCopy))
        XCTAssertTrue(markdown.contains("Not tracked in v1 — reserved for per-session usage across this Mission."))
    }

    func testRevisionProposalHistoryIncludesResolutionAndReferencedEvidenceWithoutApprovalClaims() throws {
        var plan = makePlan()
        plan.status = .running
        var state = CoordinatorFollowThroughState(missionPlan: plan)
        let base = try XCTUnwrap(state.missionPlan)
        let appended = try state.appendRevisionProposal(
            CoordinatorMissionRevisionProposalRequest(
                expectedBasePlanID: base.id,
                expectedBaseContractFingerprint: base.materialContractFingerprint(),
                summary: "Reconsider flaky-test scope",
                rationale: "The evidence changed.",
                affectedFields: ["objective"],
                remedy: "revise_scope",
                supportingEvidenceIDs: [uuid("00000000-0000-0000-0000-000000000201")],
                requestedChange: "Include scheduler stabilization.",
                actor: CoordinatorMissionRevisionProposalActor(
                    coordinatorSessionID: uuid("00000000-0000-0000-0000-000000000301"),
                    runtimeSessionID: uuid("00000000-0000-0000-0000-000000000302")
                )
            ),
            filedAt: Date(timeIntervalSince1970: 40)
        )
        _ = try state.resolveRevisionProposal(
            CoordinatorMissionRevisionProposalResolutionRequest(
                proposalID: appended.proposalID,
                outcome: .rejected,
                userDecisionID: uuid("00000000-0000-0000-0000-000000000303"),
                checkpointID: "revision-proposal",
                checkpointInstanceID: "checkpoint"
            ),
            resolvedAt: Date(timeIntervalSince1970: 41)
        )
        let markdown = try CoordinatorMissionReceiptProjection(
            plan: XCTUnwrap(state.missionPlan)
        ).markdown

        XCTAssertTrue(markdown.contains("## Revision proposal history"))
        XCTAssertTrue(markdown.contains("Director/runtime proposal"))
        XCTAssertTrue(markdown.contains("(non-decision event)"))
        XCTAssertTrue(markdown.contains("Trusted user resolution"))
        XCTAssertTrue(markdown.contains(": rejected."))
        XCTAssertTrue(markdown.contains("Referenced evidence 00000000-0000-0000-0000-000000000201"))
        XCTAssertTrue(markdown.contains("[meets] Fixed ordering issue."))
        XCTAssertFalse(markdown.contains("exact revised plan approved"))
        XCTAssertFalse(markdown.contains("deployed"))
    }

    func testEvidenceFallbackWhenNoEvidenceExists() {
        let plan = makePlan(evidence: [])

        let markdown = CoordinatorMissionReceiptProjection(plan: plan).markdown

        XCTAssertTrue(markdown.contains("## Evidence\n- No evidence recorded for this Mission."))
    }

    func testPolicyAndDecisionCountsRenderCorrectly() {
        let markdown = CoordinatorMissionReceiptProjection(plan: makePlan()).markdown

        XCTAssertTrue(markdown.contains("## Policy"))
        XCTAssertTrue(markdown.contains("- Name: Careful writes"))
        XCTAssertTrue(markdown.contains("- Pace: step"))
        XCTAssertTrue(markdown.contains("- Max concurrent sessions: 2"))
        XCTAssertTrue(markdown.contains("- Asks: plan, advance, writes, childAsk, irreversible"))
        XCTAssertTrue(markdown.contains("## Decisions"))
        XCTAssertTrue(markdown.contains("- Total: 3"))
        XCTAssertTrue(markdown.contains("- User: 2"))
        XCTAssertTrue(markdown.contains("- Director: 1"))
        XCTAssertTrue(markdown.contains("- By class: plan 1, advance 1, writes 1"))
    }

    private var expectedMarkdown: String {
        """
        # Cleanup Mission

        **Objective:** Clean up flaky tests
        **Summary:** Previous run found scheduler flakes.

        ## Policy
        - Name: Careful writes
        - Pace: step
        - Max concurrent sessions: 2
        - Asks: plan, advance, writes, childAsk, irreversible
        - Definition of done: Tests pass twice.
        - Guidance: Ask before writes.

        ## Decisions
        - Total: 3
        - User: 2
        - Director: 1
        - By class: plan 1, advance 1, writes 1

        ## Evidence
        - [meets] Fixed ordering issue.
        - [short] Needs another pass.

        ## Spend
        Not tracked in v1 — reserved for per-session usage across this Mission.
        """
    }

    private func makePlan(
        evidence: [CoordinatorMissionEvidenceRecord]? = nil
    ) -> CoordinatorMissionPlan {
        CoordinatorMissionPlan(
            id: uuid("00000000-0000-0000-0000-000000000001"),
            revision: 2,
            missionKey: "cleanup-mission",
            objective: " Clean up flaky tests ",
            predecessorSummary: " Previous run found scheduler flakes. ",
            status: .completed,
            approvalState: .approved,
            template: CoordinatorMissionTemplateSummary(
                id: "cleanup",
                displayName: "Cleanup Mission",
                iconName: "sparkles"
            ),
            policySnapshot: CoordinatorMissionPolicySnapshot(
                id: "careful-writes-test",
                name: "Careful writes",
                defaultPace: .step,
                autonomy: [
                    CoordinatorMissionDecisionClass.plan.rawValue: .ask,
                    CoordinatorMissionDecisionClass.advance.rawValue: .ask,
                    CoordinatorMissionDecisionClass.writes.rawValue: .ask,
                    CoordinatorMissionDecisionClass.childAsk.rawValue: .ask,
                    CoordinatorMissionDecisionClass.recover.rawValue: .auto,
                    CoordinatorMissionDecisionClass.irreversible.rawValue: .ask
                ],
                maxConcurrent: 2,
                definitionOfDone: "Tests pass twice.",
                standingGuidance: "Ask before writes."
            ),
            decisions: makeDecisions(),
            evidence: evidence ?? makeEvidence(),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }

    private func makeDecisions() -> [CoordinatorMissionDecisionRecord] {
        [
            CoordinatorMissionDecisionRecord(
                id: uuid("00000000-0000-0000-0000-000000000102"),
                decisionClass: CoordinatorMissionDecisionClass.writes.rawValue,
                actor: .director,
                label: "created patch",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            CoordinatorMissionDecisionRecord(
                id: uuid("00000000-0000-0000-0000-000000000100"),
                decisionClass: CoordinatorMissionDecisionClass.plan.rawValue,
                actor: .user,
                label: "approved plan",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            CoordinatorMissionDecisionRecord(
                id: uuid("00000000-0000-0000-0000-000000000101"),
                decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
                actor: .user,
                label: "continued",
                timestamp: Date(timeIntervalSince1970: 11)
            )
        ]
    }

    private func makeEvidence() -> [CoordinatorMissionEvidenceRecord] {
        [
            CoordinatorMissionEvidenceRecord(
                id: uuid("00000000-0000-0000-0000-000000000202"),
                verdict: .short,
                summary: "Needs another pass.",
                timestamp: Date(timeIntervalSince1970: 30)
            ),
            CoordinatorMissionEvidenceRecord(
                id: uuid("00000000-0000-0000-0000-000000000201"),
                verdict: .meets,
                summary: "Fixed ordering issue.",
                timestamp: Date(timeIntervalSince1970: 20)
            )
        ]
    }

    private func uuid(_ string: String) -> UUID {
        UUID(uuidString: string)!
    }
}
