@testable import RepoPrompt
import XCTest

final class CoordinatorMissionRevisionProposalLedgerTests: XCTestCase {
    func testCanonicalRequestIdentitySupportsOnlyConservativeExactRetries() throws {
        var state = try makeState()
        let evidenceA = uuid(20)
        let evidenceB = uuid(21)
        let first = try state.appendRevisionProposal(
            request(
                for: state,
                summary: "First summary",
                rationale: "First rationale",
                affectedFields: [" policy ", "objective", "policy"],
                evidenceIDs: [evidenceB, evidenceA, evidenceB],
                requestedChange: "  Cafe\u{301}\n\tneeds   a wider scope!  "
            ),
            filedAt: date(1)
        )
        let retry = try state.appendRevisionProposal(
            request(
                for: state,
                summary: "Changed summary",
                rationale: "Changed rationale",
                affectedFields: ["objective", "policy"],
                evidenceIDs: [evidenceA, evidenceB],
                requestedChange: "Café needs a wider scope!"
            ),
            filedAt: date(2)
        )

        XCTAssertEqual(first.disposition, .appended)
        XCTAssertEqual(retry.disposition, .existingPendingRetry)
        XCTAssertEqual(retry.proposalID, first.proposalID)
        let proposal = try XCTUnwrap(state.missionPlan?.pendingRevisionProposal)
        XCTAssertEqual(proposal.canonicalRequestIdentityVersion, 1)
        XCTAssertEqual(proposal.requestedChange.version, 1)
        XCTAssertEqual(proposal.requestedChange.value, "Café needs a wider scope!")
        XCTAssertEqual(proposal.affectedFields, ["objective", "policy"])
        XCTAssertEqual(proposal.supportingEvidenceIDs, [evidenceA, evidenceB])
        XCTAssertEqual(state.missionPlan?.events.count(where: { $0.kind == .revisionProposalFiled }), 1)
        XCTAssertEqual(state.missionPlan?.decisions, [])

        XCTAssertThrowsError(try state.appendRevisionProposal(
            request(for: state, requestedChange: "café needs a wider scope!"),
            filedAt: date(3)
        )) { error in
            XCTAssertEqual(
                error as? CoordinatorMissionRevisionProposalLedgerError,
                .differentProposalPending(first.proposalID)
            )
        }
        XCTAssertThrowsError(try state.appendRevisionProposal(
            request(for: state, requestedChange: "Café needs a wider scope?"),
            filedAt: date(3)
        )) { error in
            XCTAssertEqual(
                error as? CoordinatorMissionRevisionProposalLedgerError,
                .differentProposalPending(first.proposalID)
            )
        }
    }

    func testCanonicalRequestIdentityVersionHasStableGolden() throws {
        let identity = try CoordinatorMissionRevisionProposalIdentity.canonicalRequestIdentity(
            baseContractFingerprint: "contract-v1",
            affectedFields: ["policy", "objective", "policy"],
            remedy: "revise_scope",
            supportingEvidenceIDs: [uuid(2), uuid(1), uuid(2)],
            requestedChange: CoordinatorMissionCanonicalRequestedChange(
                rawValue: "  Keep\nCase, punctuation!  "
            ),
            version: 1
        )

        XCTAssertEqual(
            identity,
            "9640ed3b3a5f0296490c7735769784420ee8e1d1b7956227c5cd546e56fe8242"
        )
    }

    func testOnePendingFirstResolutionWinsAndPostResolutionReproposalIsAllowed() throws {
        var state = try makeState()
        let first = try state.appendRevisionProposal(
            request(for: state),
            filedAt: date(1)
        )
        let resolutionRequest = CoordinatorMissionRevisionProposalResolutionRequest(
            proposalID: first.proposalID,
            outcome: .rejected,
            userDecisionID: uuid(30),
            checkpointID: "revision-proposal",
            checkpointInstanceID: "checkpoint-1"
        )
        let resolution = try state.resolveRevisionProposal(
            resolutionRequest,
            resolvedAt: date(2)
        )
        let retry = try state.resolveRevisionProposal(
            resolutionRequest,
            resolvedAt: date(3)
        )

        XCTAssertEqual(resolution.disposition, .appended)
        XCTAssertEqual(retry.disposition, .existingResolutionRetry)
        XCTAssertEqual(retry.resolutionID, resolution.resolutionID)
        XCTAssertEqual(state.missionPlan?.revisionProposalResolutions.count, 1)
        XCTAssertThrowsError(try state.resolveRevisionProposal(
            CoordinatorMissionRevisionProposalResolutionRequest(
                proposalID: first.proposalID,
                outcome: .acceptedForConcreteRevision,
                userDecisionID: uuid(31),
                checkpointID: "revision-proposal",
                checkpointInstanceID: "checkpoint-1"
            )
        )) { error in
            XCTAssertEqual(
                error as? CoordinatorMissionRevisionProposalLedgerError,
                .conflictingResolution(first.proposalID)
            )
        }

        let second = try state.appendRevisionProposal(
            request(for: state, summary: "Ask again"),
            filedAt: date(4)
        )
        XCTAssertEqual(second.disposition, .appended)
        XCTAssertNotEqual(second.proposalID, first.proposalID)
        XCTAssertEqual(state.missionPlan?.revisionProposals.count, 2)
        XCTAssertEqual(state.missionPlan?.pendingRevisionProposal?.id, second.proposalID)
    }

    func testProposalAndResolutionRoundTripAndOlderDecodeDefaults() throws {
        var state = try makeState()
        let result = try state.appendRevisionProposal(
            request(for: state),
            filedAt: date(1)
        )
        _ = try state.resolveRevisionProposal(
            CoordinatorMissionRevisionProposalResolutionRequest(
                proposalID: result.proposalID,
                outcome: .rejected,
                userDecisionID: uuid(40),
                checkpointID: "revision-proposal",
                checkpointInstanceID: "checkpoint-1"
            ),
            resolvedAt: date(2)
        )

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(CoordinatorFollowThroughState.self, from: data)
        XCTAssertEqual(restored, state)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var plan = try XCTUnwrap(object["missionPlan"] as? [String: Any])
        plan.removeValue(forKey: "revisionProposals")
        plan.removeValue(forKey: "revisionProposalResolutions")
        object["missionPlan"] = plan
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(CoordinatorFollowThroughState.self, from: legacyData)
        XCTAssertEqual(legacy.missionPlan?.revisionProposals, [])
        XCTAssertEqual(legacy.missionPlan?.revisionProposalResolutions, [])
    }

    func testGenericMissionPlanUpdatePreservesLedgerAndFreshMissionResetClearsIt() throws {
        var state = try makeState()
        let result = try state.appendRevisionProposal(
            request(for: state),
            filedAt: date(1)
        )
        let proposals = try XCTUnwrap(state.missionPlan?.revisionProposals)
        let eventCount = try XCTUnwrap(state.missionPlan?.events.count)

        state.updateMissionPlan(CoordinatorMissionPlanUpdate(
            evidence: [
                CoordinatorMissionEvidenceRecord(
                    verdict: .meets,
                    summary: "Runtime evidence"
                )
            ],
            updatedAt: date(2)
        ))

        XCTAssertEqual(state.missionPlan?.revisionProposals, proposals)
        XCTAssertEqual(state.missionPlan?.revisionProposalResolutions, [])
        XCTAssertEqual(state.missionPlan?.pendingRevisionProposal?.id, result.proposalID)
        XCTAssertEqual(
            Mirror(reflecting: CoordinatorMissionPlanUpdate()).children.compactMap(\.label)
                .filter { $0.localizedCaseInsensitiveContains("proposal") },
            []
        )
        XCTAssertEqual(
            state.missionPlan?.events.count(where: { $0.kind == .revisionProposalFiled }),
            1
        )
        XCTAssertEqual(state.missionPlan?.events.count, eventCount + 1)

        state.rememberObjective("A fresh Mission", resetMissionPlan: true)
        XCTAssertNil(state.missionPlan)
    }

    func testTerminalUpdatesResolvePendingProposalBeforeFreezingAndCannotOverwriteFirstResolution() throws {
        var completed = try makeState()
        let completedProposal = try completed.appendRevisionProposal(
            request(for: completed),
            filedAt: date(1)
        )
        completed.updateMissionPlan(CoordinatorMissionPlanUpdate(
            status: .completed,
            updatedAt: date(2)
        ))
        XCTAssertEqual(completed.missionPlan?.status, .completed)
        XCTAssertEqual(
            completed.missionPlan?.revisionProposalResolution(for: completedProposal.proposalID)?.outcome,
            .invalidatedMissionTerminal
        )
        let frozenCompleted = completed
        completed.updateMissionPlan(CoordinatorMissionPlanUpdate(
            status: .completed,
            updatedAt: date(3)
        ))
        XCTAssertEqual(completed, frozenCompleted)
        XCTAssertEqual(completed.missionPlan?.revisionProposalResolutions.count, 1)

        var stopped = try makeState()
        let stoppedProposal = try stopped.appendRevisionProposal(
            request(for: stopped),
            filedAt: date(1)
        )
        stopped.updateMissionPlan(CoordinatorMissionPlanUpdate(
            status: .stopped,
            updatedAt: date(2)
        ))
        XCTAssertEqual(stopped.missionPlan?.status, .stopped)
        XCTAssertEqual(
            stopped.missionPlan?.revisionProposalResolution(for: stoppedProposal.proposalID)?.outcome,
            .stopped
        )
        let frozenStopped = stopped
        stopped.updateMissionPlan(CoordinatorMissionPlanUpdate(
            status: .stopped,
            updatedAt: date(3)
        ))
        XCTAssertEqual(stopped, frozenStopped)
        XCTAssertEqual(stopped.missionPlan?.revisionProposalResolutions.count, 1)

        var resolved = try makeState()
        let resolvedProposal = try resolved.appendRevisionProposal(
            request(for: resolved),
            filedAt: date(1)
        )
        _ = try resolved.resolveRevisionProposal(
            CoordinatorMissionRevisionProposalResolutionRequest(
                proposalID: resolvedProposal.proposalID,
                outcome: .rejected,
                userDecisionID: uuid(50),
                checkpointInstanceID: "checkpoint-1"
            ),
            resolvedAt: date(2)
        )
        resolved.updateMissionPlan(CoordinatorMissionPlanUpdate(
            status: .stopped,
            updatedAt: date(3)
        ))
        XCTAssertEqual(resolved.missionPlan?.revisionProposalResolutions.count, 1)
        XCTAssertEqual(
            resolved.missionPlan?.revisionProposalResolutions.first?.outcome,
            .rejected
        )
    }

    func testProposalIDIsRandomAndExactPendingRetryReturnsPersistedID() throws {
        var firstState = try makeState()
        var secondState = try makeState()
        let first = try firstState.appendRevisionProposal(
            request(for: firstState),
            filedAt: date(1)
        )
        let second = try secondState.appendRevisionProposal(
            request(for: secondState),
            filedAt: date(1)
        )
        let retry = try firstState.appendRevisionProposal(
            request(
                for: firstState,
                summary: "Retry summary is excluded",
                rationale: "Retry rationale is excluded"
            ),
            filedAt: date(2)
        )

        XCTAssertNotEqual(first.proposalID, second.proposalID)
        XCTAssertEqual(retry.proposalID, first.proposalID)
        XCTAssertEqual(retry.disposition, .existingPendingRetry)
        XCTAssertEqual(firstState.missionPlan?.revisionProposals.count, 1)
    }

    func testResolveRevisionProposalRejectsCompletedAndStoppedMissionsWithoutMutation() throws {
        for terminalStatus in [CoordinatorMissionPlanStatus.completed, .stopped] {
            var state = try makeState()
            let proposal = try state.appendRevisionProposal(
                request(for: state),
                filedAt: date(1)
            )
            state.updateMissionPlan(CoordinatorMissionPlanUpdate(
                status: terminalStatus,
                updatedAt: date(2)
            ))
            let frozenState = state

            XCTAssertThrowsError(try state.resolveRevisionProposal(
                CoordinatorMissionRevisionProposalResolutionRequest(
                    proposalID: proposal.proposalID,
                    outcome: .rejected,
                    userDecisionID: uuid(70),
                    checkpointInstanceID: "terminal-checkpoint"
                ),
                resolvedAt: date(3)
            )) { error in
                XCTAssertEqual(
                    error as? CoordinatorMissionRevisionProposalLedgerError,
                    .missionTerminal
                )
            }
            XCTAssertEqual(state, frozenState)
            XCTAssertEqual(state.missionPlan?.revisionProposalResolutions.count, 1)
        }
    }

    func testDirectStopResolvesPendingProposalOnceBeforeTerminalization() throws {
        var state = try makeState()
        let proposal = try state.appendRevisionProposal(
            request(for: state),
            filedAt: date(1)
        )
        var plan = try XCTUnwrap(state.missionPlan)
        let expectedFingerprint = try XCTUnwrap(plan.pendingRevisionProposal?.baseContractFingerprint)

        plan.stopMission(cancelledSessionIDs: [uuid(80)], at: date(2))

        XCTAssertEqual(plan.status, .stopped)
        XCTAssertEqual(plan.revisionProposalResolutions.count, 1)
        let resolution = try XCTUnwrap(plan.revisionProposalResolution(for: proposal.proposalID))
        XCTAssertEqual(resolution.outcome, .stopped)
        XCTAssertEqual(resolution.resultingPlanID, plan.id)
        XCTAssertEqual(resolution.resultingContractFingerprint, expectedFingerprint)

        let frozenPlan = plan
        plan.stopMission(cancelledSessionIDs: [uuid(81)], at: date(3))
        XCTAssertEqual(plan, frozenPlan)
        XCTAssertEqual(plan.revisionProposalResolutions.count, 1)
    }

    func testResolutionFingerprintFailureDoesNotPartiallyMutateState() throws {
        enum FingerprintFailure: Error {
            case injected
        }

        var state = try makeState()
        let proposal = try state.appendRevisionProposal(
            request(for: state),
            filedAt: date(1)
        )
        let beforeResolution = state

        XCTAssertThrowsError(try state.resolveRevisionProposal(
            CoordinatorMissionRevisionProposalResolutionRequest(
                proposalID: proposal.proposalID,
                outcome: .rejected,
                userDecisionID: uuid(90),
                checkpointInstanceID: "checkpoint-1"
            ),
            resolvedAt: date(2),
            fingerprintProvider: { _ in throw FingerprintFailure.injected }
        )) { error in
            XCTAssertTrue(error is FingerprintFailure)
        }
        XCTAssertEqual(state, beforeResolution)
        XCTAssertEqual(state.missionPlan?.revisionProposalResolutions, [])
    }

    private func makeState() throws -> CoordinatorFollowThroughState {
        let plan = CoordinatorMissionPlan(
            id: uuid(10),
            revision: 1,
            missionKey: "mission-key",
            objective: "Ship the approved objective",
            status: .running,
            approvalState: .approved,
            autonomy: CoordinatorMissionPolicySnapshot.defaultAutonomy,
            updatedAt: date(0)
        )
        return CoordinatorFollowThroughState(missionPlan: plan)
    }

    private func request(
        for state: CoordinatorFollowThroughState,
        summary: String = "Widen the approved scope",
        rationale: String? = "New constraints require reconsideration",
        affectedFields: [String] = ["objective"],
        evidenceIDs: [UUID]? = nil,
        requestedChange: String = "Widen the approved scope."
    ) throws -> CoordinatorMissionRevisionProposalRequest {
        let plan = try XCTUnwrap(state.missionPlan)
        return try CoordinatorMissionRevisionProposalRequest(
            expectedBasePlanID: plan.id,
            expectedBaseContractFingerprint: plan.materialContractFingerprint(),
            summary: summary,
            rationale: rationale,
            affectedFields: affectedFields,
            remedy: "revise_scope",
            supportingEvidenceIDs: evidenceIDs ?? [uuid(20)],
            requestedChange: requestedChange,
            actor: CoordinatorMissionRevisionProposalActor(
                coordinatorSessionID: uuid(60),
                runtimeSessionID: uuid(61),
                modelID: "director-model"
            )
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
