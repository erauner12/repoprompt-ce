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

        var proposalOnlyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var proposalOnlyPlan = try XCTUnwrap(proposalOnlyObject["missionPlan"] as? [String: Any])
        proposalOnlyPlan.removeValue(forKey: "revisionProposalResolutions")
        proposalOnlyObject["missionPlan"] = proposalOnlyPlan
        let proposalOnly = try JSONDecoder().decode(
            CoordinatorFollowThroughState.self,
            from: JSONSerialization.data(withJSONObject: proposalOnlyObject)
        )
        XCTAssertEqual(proposalOnly.missionPlan?.revisionProposals.count, 1)
        XCTAssertEqual(proposalOnly.missionPlan?.revisionProposalResolutions, [])
        XCTAssertEqual(proposalOnly.missionPlan?.pendingRevisionProposal?.id, result.proposalID)

        var resolutionOnlyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var resolutionOnlyPlan = try XCTUnwrap(resolutionOnlyObject["missionPlan"] as? [String: Any])
        resolutionOnlyPlan.removeValue(forKey: "revisionProposals")
        resolutionOnlyObject["missionPlan"] = resolutionOnlyPlan
        let resolutionOnly = try JSONDecoder().decode(
            CoordinatorFollowThroughState.self,
            from: JSONSerialization.data(withJSONObject: resolutionOnlyObject)
        )
        XCTAssertEqual(resolutionOnly.missionPlan?.revisionProposals, [])
        XCTAssertEqual(resolutionOnly.missionPlan?.revisionProposalResolutions, [])
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

        let pendingState = state
        state.rememberObjective("Follow up", resetMissionPlan: false)
        XCTAssertEqual(state.missionPlan, pendingState.missionPlan)

        state.rememberObjective("A fresh Mission", resetMissionPlan: true)
        XCTAssertNil(state.missionPlan)
        XCTAssertTrue(state.observedChildPhases.isEmpty)
        XCTAssertTrue(state.pendingEvents.isEmpty)
        XCTAssertTrue(state.handledEventIDs.isEmpty)
        XCTAssertNil(state.postApprovalContinuation)
        XCTAssertTrue(state.childInteractionResponses.isEmpty)
    }

    func testPendingProposalSurvivesRestartAndMustResolveOrStopBeforeRollback() throws {
        var state = try makeState()
        let appended = try state.appendRevisionProposal(request(for: state), filedAt: date(1))

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(CoordinatorFollowThroughState.self, from: data)

        XCTAssertEqual(restored.missionPlan?.pendingRevisionProposal?.id, appended.proposalID)
        XCTAssertTrue(restored.missionPlan?.holdsChildInteractionsForRevisionProposal == true)
        XCTAssertFalse(restored.missionPlan?.status.isTerminal == true)
        // Operational rollback to a binary that predates revision proposals is unsafe here:
        // resolve with Keep/Revise or stop the Mission before installing the older build.
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

    func testPendingProposalReducerBlocksAdvancementButAllowsBookkeepingAndTerminalReconciliation() throws {
        let workstreamID = uuid(70)
        let runningNodeID = uuid(71)
        let pendingNodeID = uuid(72)
        var state = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            id: uuid(10),
            revision: 1,
            objective: "Ship the approved objective",
            status: .running,
            approvalState: .approved,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Implementation",
                    purpose: "Finish existing work honestly.",
                    defaultPolicy: .freshWorktree,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(mode: .createIsolated)
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: runningNodeID,
                    title: "Already running",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .running,
                    boundSessionID: uuid(73)
                ),
                CoordinatorMissionPlanNode(
                    id: pendingNodeID,
                    title: "Not started",
                    workstreamID: workstreamID,
                    executionPolicy: .freshWorktree,
                    status: .pending
                )
            ]
        ))
        _ = try state.appendRevisionProposal(request(for: state), filedAt: date(1))
        let heldPlan = try XCTUnwrap(state.missionPlan)
        let runningNode = try XCTUnwrap(heldPlan.nodes.first(where: { $0.id == runningNodeID }))
        let pendingNode = try XCTUnwrap(heldPlan.nodes.first(where: { $0.id == pendingNodeID }))

        var newlyBound = pendingNode
        newlyBound.boundSessionID = uuid(74)
        XCTAssertThrowsError(try state.applyMissionPlanUpdate(.init(nodes: [newlyBound]))) {
            XCTAssertEqual($0 as? CoordinatorMissionRevisionProposalPauseError, .binding)
        }

        var started = pendingNode
        started.status = .running
        XCTAssertThrowsError(try state.applyMissionPlanUpdate(.init(nodes: [started]))) {
            XCTAssertEqual($0 as? CoordinatorMissionRevisionProposalPauseError, .advancement)
        }
        XCTAssertThrowsError(try state.applyMissionPlanUpdate(.init(status: .approved))) {
            XCTAssertEqual($0 as? CoordinatorMissionRevisionProposalPauseError, .advancement)
        }
        XCTAssertThrowsError(try state.applyMissionPlanUpdate(.init(objective: "Changed contract"))) {
            XCTAssertEqual($0 as? CoordinatorMissionRevisionProposalPauseError, .contractChange)
        }
        XCTAssertThrowsError(try state.applyMissionPlanUpdate(.init(decisions: [
            CoordinatorMissionDecisionRecord(
                decisionClass: CoordinatorMissionDecisionClass.childAsk.rawValue,
                actor: .director,
                label: "answered child question",
                timestamp: date(2)
            )
        ]))) {
            XCTAssertEqual($0 as? CoordinatorMissionRevisionProposalPauseError, .directorDecision)
        }

        try state.applyMissionPlanUpdate(.init(
            evidence: [CoordinatorMissionEvidenceRecord(verdict: .meets, summary: "Observed evidence")],
            events: [CoordinatorMissionPlanEvent(kind: .revised, summary: "Recorded changed assumption")],
            updatedAt: date(3)
        ))
        XCTAssertNotNil(state.missionPlan?.pendingRevisionProposal)
        XCTAssertEqual(state.missionPlan?.evidence.last?.summary, "Observed evidence")

        var blocked = runningNode
        blocked.status = .blocked
        try state.applyMissionPlanUpdate(.init(nodes: [blocked], updatedAt: date(4)))
        XCTAssertEqual(state.missionPlan?.nodes.first(where: { $0.id == runningNodeID })?.status, .blocked)

        var completed = blocked
        completed.status = .completed
        completed.completionEvidence = "Terminal output received."
        var cancelled = pendingNode
        cancelled.status = .cancelled
        XCTAssertThrowsError(try state.applyMissionPlanUpdate(.init(nodes: [cancelled]))) {
            XCTAssertEqual($0 as? CoordinatorMissionRevisionProposalPauseError, .advancement)
        }
        try state.applyMissionPlanUpdate(.init(
            status: .completed,
            nodes: [completed],
            evidence: [CoordinatorMissionEvidenceRecord(verdict: .meets, summary: "Terminal output")],
            updatedAt: date(5)
        ))
        XCTAssertEqual(state.missionPlan?.nodes.first(where: { $0.id == runningNodeID })?.status, .completed)
        XCTAssertNotNil(state.missionPlan?.pendingRevisionProposal)
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

    func testTrustedKeepResolutionIsAtomicIdempotentAndRestoresContinuationOnlyAfterHoldClears() throws {
        let coordinatorID = uuid(11)
        var state = try makeState()
        let continuation = try CoordinatorPostApprovalContinuationRecord(
            id: uuid(12),
            coordinatorSessionID: coordinatorID,
            checkpointInstanceID: "approval-checkpoint",
            planID: XCTUnwrap(state.missionPlan?.id),
            planRevision: 1,
            directiveText: "Continue",
            status: .deferred,
            createdAt: date(0),
            updatedAt: date(1),
            lastError: CoordinatorMissionRevisionProposalPause.heldReason
        )
        state.recordPostApprovalContinuation(continuation)
        let appended = try state.appendRevisionProposal(request(for: state), filedAt: date(2))
        let proposal = try XCTUnwrap(state.missionPlan?.pendingRevisionProposal)
        let trusted = CoordinatorMissionRevisionProposalTrustedResolutionRequest(
            coordinatorSessionID: coordinatorID,
            action: .keepCurrentPlan,
            proposalID: appended.proposalID,
            expectedContractFingerprint: proposal.baseContractFingerprint,
            expectedCheckpointInstanceID: CoordinatorMissionRevisionProposalCheckpoint.instanceID(
                coordinatorSessionID: coordinatorID,
                proposal: proposal
            )
        )

        let first = try state.resolveRevisionProposalTransaction(trusted, resolvedAt: date(3))
        let retry = try state.resolveRevisionProposalTransaction(trusted, resolvedAt: date(4))

        XCTAssertEqual(first.disposition, .appended)
        XCTAssertEqual(retry.disposition, .existingResolutionRetry)
        XCTAssertEqual(first.resolutionID, retry.resolutionID)
        XCTAssertEqual(state.missionPlan?.revisionProposalResolutions.count, 1)
        XCTAssertEqual(state.missionPlan?.decisions.count, 1)
        XCTAssertEqual(state.missionPlan?.approvalState, .approved)
        XCTAssertEqual(state.missionPlan?.postApprovalContinuation?.status, .deferred)
        XCTAssertTrue(state.missionPlan?.hasRevisionProposalDurabilityHold == true)
        XCTAssertTrue(state.missionPlan?.holdsChildInteractionsForRevisionProposal == true)

        XCTAssertTrue(state.clearRevisionProposalDurabilityHold(
            transactionID: first.resolutionID,
            at: date(5)
        ))
        XCTAssertFalse(state.missionPlan?.hasRevisionProposalDurabilityHold == true)
        XCTAssertFalse(state.missionPlan?.holdsChildInteractionsForRevisionProposal == true)
    }

    func testTrustedReviseResolutionCASInvalidatesOldContinuationAndRejectsConflicts() throws {
        let coordinatorID = uuid(11)
        var state = try makeState()
        let continuation = try CoordinatorPostApprovalContinuationRecord(
            id: uuid(12),
            coordinatorSessionID: coordinatorID,
            checkpointInstanceID: "approval-checkpoint",
            planID: XCTUnwrap(state.missionPlan?.id),
            planRevision: 1,
            directiveText: "Continue",
            status: .deferred,
            createdAt: date(0),
            updatedAt: date(1)
        )
        state.recordPostApprovalContinuation(continuation)
        let appended = try state.appendRevisionProposal(request(for: state), filedAt: date(2))
        let proposal = try XCTUnwrap(state.missionPlan?.pendingRevisionProposal)
        let checkpoint = CoordinatorMissionRevisionProposalCheckpoint.instanceID(
            coordinatorSessionID: coordinatorID,
            proposal: proposal
        )
        let revise = CoordinatorMissionRevisionProposalTrustedResolutionRequest(
            coordinatorSessionID: coordinatorID,
            action: .revisePlan,
            proposalID: appended.proposalID,
            expectedContractFingerprint: proposal.baseContractFingerprint,
            expectedCheckpointInstanceID: checkpoint
        )

        let result = try state.resolveRevisionProposalTransaction(revise, resolvedAt: date(3))
        XCTAssertEqual(state.missionPlan?.approvalState, .revisionRequested)
        XCTAssertEqual(state.missionPlan?.postApprovalContinuation?.status, .invalidated)
        XCTAssertTrue(state.missionPlan?.holdsChildInteractionsForRevisionProposal == true)
        XCTAssertTrue(state.pendingEvents.isEmpty)

        let keep = CoordinatorMissionRevisionProposalTrustedResolutionRequest(
            coordinatorSessionID: coordinatorID,
            action: .keepCurrentPlan,
            proposalID: appended.proposalID,
            expectedContractFingerprint: proposal.baseContractFingerprint,
            expectedCheckpointInstanceID: checkpoint
        )
        XCTAssertThrowsError(try state.resolveRevisionProposalTransaction(keep)) {
            XCTAssertEqual(
                $0 as? CoordinatorMissionRevisionProposalLedgerError,
                .conflictingResolution(appended.proposalID)
            )
        }
        XCTAssertThrowsError(try state.resolveRevisionProposalTransaction(.init(
            coordinatorSessionID: coordinatorID,
            action: .revisePlan,
            proposalID: appended.proposalID,
            expectedContractFingerprint: proposal.baseContractFingerprint,
            expectedCheckpointInstanceID: "stale"
        ))) {
            XCTAssertEqual($0 as? CoordinatorMissionRevisionProposalLedgerError, .staleCheckpoint)
        }
        XCTAssertTrue(state.clearRevisionProposalDurabilityHold(transactionID: result.resolutionID))
        XCTAssertTrue(state.missionPlan?.holdsChildInteractionsForRevisionProposal == true)
    }

    func testTrustedStopAndContractChangeResolvePendingProposalAtomically() throws {
        let coordinatorID = uuid(11)
        var stopped = try makeState()
        let stoppedProposal = try stopped.appendRevisionProposal(request(for: stopped), filedAt: date(1))
        let stopResult = try XCTUnwrap(try stopped.stopMissionTransaction(
            coordinatorSessionID: coordinatorID,
            cancelledSessionIDs: [uuid(12)],
            stoppedAt: date(2)
        ))
        XCTAssertEqual(stopped.missionPlan?.status, .stopped)
        XCTAssertEqual(
            stopped.missionPlan?.revisionProposalResolution(for: stoppedProposal.proposalID)?.outcome,
            .stopped
        )
        XCTAssertEqual(stopped.missionPlan?.postApprovalContinuation?.status, nil)
        XCTAssertEqual(stopped.missionPlan?.revisionProposalDurabilityHold?.transactionID, stopResult.resolutionID)
        XCTAssertEqual(stopped.missionPlan?.decisions.last?.label, CoordinatorMissionUserDecisionLabel.stoppedMission.rawValue)
        let stopRetry = try XCTUnwrap(try stopped.stopMissionTransaction(
            coordinatorSessionID: coordinatorID,
            cancelledSessionIDs: [uuid(12)],
            stoppedAt: date(3)
        ))
        XCTAssertEqual(stopRetry.resolutionID, stopResult.resolutionID)
        XCTAssertEqual(stopRetry.disposition, .existingResolutionRetry)

        for action in [
            CoordinatorMissionRevisionProposalResolutionAction.revisePlan,
            .keepCurrentPlan
        ] {
            var resolved = try makeState()
            let appended = try resolved.appendRevisionProposal(request(for: resolved), filedAt: date(1))
            let proposal = try XCTUnwrap(resolved.missionPlan?.pendingRevisionProposal)
            let resolution = try resolved.resolveRevisionProposalTransaction(
                CoordinatorMissionRevisionProposalTrustedResolutionRequest(
                    coordinatorSessionID: coordinatorID,
                    action: action,
                    proposalID: proposal.id,
                    expectedContractFingerprint: proposal.baseContractFingerprint,
                    expectedCheckpointInstanceID: CoordinatorMissionRevisionProposalCheckpoint.instanceID(
                        coordinatorSessionID: coordinatorID,
                        proposal: proposal
                    )
                ),
                resolvedAt: date(2)
            )
            let originalOutcome = action.outcome
            let stoppedAfterResolution = try XCTUnwrap(try resolved.stopMissionTransaction(
                coordinatorSessionID: coordinatorID,
                cancelledSessionIDs: [uuid(12)],
                stoppedAt: date(3)
            ))
            XCTAssertEqual(resolved.missionPlan?.status, .stopped)
            XCTAssertEqual(resolved.missionPlan?.revisionProposalResolutions.count, 1)
            XCTAssertEqual(
                resolved.missionPlan?.revisionProposalResolution(for: appended.proposalID)?.outcome,
                originalOutcome
            )
            XCTAssertNotEqual(stoppedAfterResolution.resolutionID, resolution.resolutionID)
            XCTAssertEqual(resolved.missionPlan?.revisionProposalDurabilityHold?.outcome, .stopped)
            XCTAssertEqual(
                resolved.missionPlan?.decisions.count {
                    $0.label == CoordinatorMissionUserDecisionLabel.stoppedMission.rawValue
                },
                1
            )
            let retry = try XCTUnwrap(try resolved.stopMissionTransaction(
                coordinatorSessionID: coordinatorID,
                cancelledSessionIDs: [uuid(12)],
                stoppedAt: date(4)
            ))
            XCTAssertEqual(retry.resolutionID, stoppedAfterResolution.resolutionID)
            XCTAssertEqual(retry.disposition, .existingResolutionRetry)
        }

        var changed = try makeState()
        let changedProposal = try changed.appendRevisionProposal(request(for: changed), filedAt: date(1))
        var policy = changed.missionPlan?.policySnapshot ?? .defaultPolicy
        policy.defaultPace = .auto
        let decision = CoordinatorMissionDecisionRecord(
            id: uuid(13),
            decisionClass: CoordinatorMissionDecisionClass.advance.rawValue,
            actor: .user,
            label: CoordinatorMissionUserDecisionLabel.setPaceToAuto.rawValue,
            timestamp: date(2),
            checkpointID: "mission-policy-override",
            checkpointInstanceID: "pace-change"
        )
        let changeResult = try XCTUnwrap(try changed.applyTrustedContractChangeInvalidatingRevisionProposal(
            .init(policySnapshot: policy, decisions: [decision], updatedAt: date(2)),
            coordinatorSessionID: coordinatorID
        ))
        XCTAssertEqual(
            changed.missionPlan?.revisionProposalResolution(for: changedProposal.proposalID)?.outcome,
            .invalidatedContractChanged
        )
        XCTAssertNil(changed.missionPlan?.pendingRevisionProposal)
        XCTAssertEqual(changed.missionPlan?.revisionProposalDurabilityHold?.transactionID, changeResult.resolutionID)
        XCTAssertEqual(changed.missionPlan?.decisions.last?.id, decision.id)
        let changeRetry = try XCTUnwrap(try changed.applyTrustedContractChangeInvalidatingRevisionProposal(
            .init(policySnapshot: policy, decisions: [decision], updatedAt: date(3)),
            coordinatorSessionID: coordinatorID
        ))
        XCTAssertEqual(changeRetry.resolutionID, changeResult.resolutionID)
        XCTAssertEqual(changeRetry.disposition, .existingResolutionRetry)

        var stoppedAfterContractChange = changed
        let supersedingStop = try XCTUnwrap(try stoppedAfterContractChange.stopMissionTransaction(
            coordinatorSessionID: coordinatorID,
            cancelledSessionIDs: [uuid(12)],
            stoppedAt: date(4)
        ))
        XCTAssertEqual(stoppedAfterContractChange.missionPlan?.status, .stopped)
        XCTAssertEqual(
            stoppedAfterContractChange.missionPlan?.revisionProposalResolution(for: changedProposal.proposalID)?.outcome,
            .invalidatedContractChanged
        )
        XCTAssertEqual(stoppedAfterContractChange.missionPlan?.revisionProposalDurabilityHold?.outcome, .stopped)
        XCTAssertNotEqual(supersedingStop.resolutionID, changeResult.resolutionID)

        XCTAssertTrue(changed.clearRevisionProposalDurabilityHold(transactionID: changeResult.resolutionID))
        XCTAssertFalse(changed.missionPlan?.holdsChildInteractionsForRevisionProposal == true)
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
