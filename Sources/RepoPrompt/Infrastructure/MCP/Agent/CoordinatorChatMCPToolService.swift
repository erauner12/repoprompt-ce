import Foundation
import MCP

@MainActor
struct CoordinatorChatMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata

    struct Environment {
        var snapshot: () -> CoordinatorModeSnapshot
        var refresh: () -> Void
        var selectCoordinator: (_ sessionID: UUID?) -> Void
        var startNewCoordinatorRun: (_ coordinatorModelID: String?) -> Void
        var stopCoordinatorMission: (_ targetMissionID: UUID) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var submitDirective: (_ text: String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var submitContinuation: (_ action: CoordinatorModeViewModel.ContinuationAction, _ expectedCheckpointInstanceID: String?) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var activePendingChildInteractionRow: (_ coordinatorSessionID: UUID?) -> CoordinatorModeRow?
        var submitPendingChildInteractionResponse: (_ submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission, _ row: CoordinatorModeRow, _ actor: CoordinatorMissionDecisionActor) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var durableApprovalAuthorityToken: (_ coordinatorSessionID: UUID) -> String?
        var updateMissionPlan: (_ coordinatorSessionID: UUID, _ update: CoordinatorMissionPlanUpdate) throws -> Void
        var appendRevisionProposal: (_ coordinatorSessionID: UUID, _ request: CoordinatorMissionRevisionProposalRequest) async throws -> CoordinatorMissionRevisionProposalAppendResult
        var missionEvents: (_ coordinatorSessionID: UUID, _ sinceSeq: Int, _ limit: Int) -> CoordinatorMissionEventJournal.Batch
        var setMissionPace: (_ coordinatorSessionID: UUID, _ pace: CoordinatorMissionPolicyPace) -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var setMissionAutonomy: (_ coordinatorSessionID: UUID, _ autonomyClassKey: String, _ mode: CoordinatorMissionAutonomyMode) -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var archiveMission: (_ coordinatorSessionID: UUID) async -> CoordinatorModeViewModel.CoordinatorArchiveMissionResult
    }

    private static let supportedOps = [
        "list",
        "list_missions",
        "doctor",
        "select",
        "new",
        "ensure_mission",
        "start_mission",
        "stop_mission",
        "archive_mission",
        "submit",
        "mission_plan",
        "mission_status",
        "mission_events",
        "receipt",
        "set_pace",
        "set_autonomy",
        "wait_for_update"
    ]

    private let toolName: String
    private let makeEnvironment: () throws -> Environment
    private let captureRequestMetadata: () async -> RequestMetadata
    private let resolveRuntimeCoordinatorSessionID: (RequestMetadata) async -> UUID?
    private let initialMissionPlanTimeoutSeconds: TimeInterval
    private let initialMissionPlanPollIntervalSeconds: TimeInterval
    private let sleep: (UInt64) async -> Void

    private enum CallerClassification: Equatable {
        case externalCaller
        case owningCoordinatorRuntime(UUID)
        case internalNonOwnerAgentModeWorker

        var runtimeCoordinatorSessionID: UUID? {
            if case let .owningCoordinatorRuntime(sessionID) = self { return sessionID }
            return nil
        }
    }

    init(
        toolName: String,
        requireTargetWindow: @escaping MCPWindowToolDependencies.RequireTargetWindow,
        captureRequestMetadata: @escaping () async -> RequestMetadata,
        resolveRuntimeCoordinatorSessionID: @escaping (RequestMetadata) async -> UUID? = { _ in nil },
        initialMissionPlanTimeoutSeconds: TimeInterval = 10,
        initialMissionPlanPollIntervalSeconds: TimeInterval = 0.25,
        sleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.toolName = toolName
        self.captureRequestMetadata = captureRequestMetadata
        self.resolveRuntimeCoordinatorSessionID = resolveRuntimeCoordinatorSessionID
        self.initialMissionPlanTimeoutSeconds = initialMissionPlanTimeoutSeconds
        self.initialMissionPlanPollIntervalSeconds = initialMissionPlanPollIntervalSeconds
        self.sleep = sleep
        makeEnvironment = {
            let coordinatorViewModel = try requireTargetWindow().agentModeViewModel.coordinatorModeViewModel
            return Environment(
                snapshot: { coordinatorViewModel.snapshot },
                refresh: { coordinatorViewModel.refresh() },
                selectCoordinator: { coordinatorViewModel.selectCoordinator(sessionID: $0) },
                startNewCoordinatorRun: { coordinatorViewModel.startNewCoordinatorRun(coordinatorModelID: $0) },
                stopCoordinatorMission: { await coordinatorViewModel.stopCoordinatorMission(targetMissionID: $0) },
                submitDirective: { await coordinatorViewModel.submitCoordinatorDirective($0) },
                submitContinuation: { await coordinatorViewModel.submitCoordinatorContinuation($0, expectedCheckpointInstanceID: $1) },
                activePendingChildInteractionRow: { coordinatorViewModel.activePendingChildInteractionRow(coordinatorSessionID: $0) },
                submitPendingChildInteractionResponse: { await coordinatorViewModel.submitPendingChildInteractionResponse($0, to: $1, actor: $2) },
                durableApprovalAuthorityToken: { coordinatorViewModel.durableApprovalAuthorityToken(coordinatorSessionID: $0) },
                updateMissionPlan: { try coordinatorViewModel.updateMissionPlan(coordinatorSessionID: $0, update: $1) },
                appendRevisionProposal: { try await coordinatorViewModel.appendRevisionProposal(coordinatorSessionID: $0, request: $1) },
                missionEvents: { coordinatorViewModel.missionEvents(coordinatorSessionID: $0, sinceSeq: $1, limit: $2) },
                setMissionPace: { coordinatorViewModel.setCoordinatorMissionPace(coordinatorSessionID: $0, pace: $1) },
                setMissionAutonomy: { coordinatorViewModel.setCoordinatorMissionAutonomy(coordinatorSessionID: $0, autonomyClassKey: $1, mode: $2) },
                archiveMission: { await coordinatorViewModel.archiveCoordinatorMission(sessionID: $0) }
            )
        }
    }

    init(
        toolName: String,
        captureRequestMetadata: @escaping () async -> RequestMetadata = {
            RequestMetadata(connectionID: nil, clientName: nil, windowID: nil)
        },
        resolveRuntimeCoordinatorSessionID: @escaping (RequestMetadata) async -> UUID? = { _ in nil },
        initialMissionPlanTimeoutSeconds: TimeInterval = 10,
        initialMissionPlanPollIntervalSeconds: TimeInterval = 0.25,
        sleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        makeEnvironment: @escaping () throws -> Environment
    ) {
        self.toolName = toolName
        self.captureRequestMetadata = captureRequestMetadata
        self.resolveRuntimeCoordinatorSessionID = resolveRuntimeCoordinatorSessionID
        self.initialMissionPlanTimeoutSeconds = initialMissionPlanTimeoutSeconds
        self.initialMissionPlanPollIntervalSeconds = initialMissionPlanPollIntervalSeconds
        self.sleep = sleep
        self.makeEnvironment = makeEnvironment
    }

    func execute(args: [String: Value]) async throws -> Value {
        let environment = try makeEnvironment()
        let metadata = await captureRequestMetadata()
        let op = try AgentMCPToolHelpers.requireNonEmptyString(args["op"], name: "op")
            .lowercased()

        switch op {
        case "list":
            environment.refresh()
            let snapshot = environment.snapshot()
            if metadata.isCoordinatorRuntime {
                let coordinatorSessionID = try await resolveCoordinatorSessionID(
                    args["coordinator_session_id"],
                    in: snapshot,
                    metadata: metadata
                )
                try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
                return compactStateResponse(snapshot, extra: [
                    "runtime_scoped": .bool(true),
                    "mission_status": compactMissionStatusValue(
                        coordinatorSessionID: coordinatorSessionID,
                        snapshot: snapshot
                    )
                ])
            }
            return stateResponse(snapshot)

        case "list_missions":
            environment.refresh()
            let includeArchived = AgentMCPToolHelpers.parseBool(args["include_archived"] ?? args["includeArchived"]) ?? true
            let runtimeScopeSessionID: UUID?
            if metadata.isCoordinatorRuntime {
                guard let resolvedRuntimeID = await resolveRuntimeCoordinatorSessionID(metadata) else {
                    throw MCPError.invalidParams("list_missions is scoped to the caller Mission for Coordinator runtime calls, but RepoPrompt cannot resolve the caller Mission.")
                }
                if let requestedValue = args["coordinator_session_id"] {
                    let requestedID = try requireCoordinatorSessionID(requestedValue)
                    if requestedID != resolvedRuntimeID {
                        throw MCPError.invalidParams("Coordinator runtime list_missions calls are scoped to the caller Mission and cannot inspect other Coordinator Missions.")
                    }
                }
                runtimeScopeSessionID = resolvedRuntimeID
            } else {
                runtimeScopeSessionID = nil
            }
            return compactStateResponse(environment.snapshot(), extra: [
                "missions": missionInventoryValue(
                    environment.snapshot(),
                    includeArchived: includeArchived,
                    scopedTo: runtimeScopeSessionID
                ),
                "include_archived": .bool(includeArchived),
                "runtime_scoped": .bool(runtimeScopeSessionID != nil)
            ])

        case "doctor":
            environment.refresh()
            return compactStateResponse(environment.snapshot(), extra: [
                "doctor": doctorValue(environment.snapshot())
            ])

        case "select":
            try validateExternalUserAction(metadata, action: "select Coordinator Missions")
            environment.refresh()
            let sessionID = try requireCoordinatorSessionID(args["coordinator_session_id"])
            try validateCoordinatorExists(sessionID, in: environment.snapshot())
            environment.selectCoordinator(sessionID)
            environment.refresh()
            return stateResponse(environment.snapshot(), extra: [
                "selected": .bool(true)
            ])

        case "new":
            try validateExternalMissionCreation(metadata)
            let coordinatorModelID = normalizedString(args["coordinator_model_id"] ?? args["coordinatorModelID"])
            environment.startNewCoordinatorRun(coordinatorModelID)
            environment.refresh()
            return stateResponse(environment.snapshot(), extra: [
                "new_parent_pending": .bool(true),
                "coordinator_model_id": AgentMCPToolHelpers.stringOrNull(coordinatorModelID)
            ])

        case "ensure_mission", "start_mission":
            try validateExternalMissionCreation(metadata)
            guard let message = normalizedString(args["message"] ?? args["response"]),
                  !message.isEmpty
            else {
                throw MCPError.invalidParams("message is required.")
            }
            let missionKey = normalizedString(args["mission_key"] ?? args["missionKey"])
            if op == "ensure_mission", missionKey == nil {
                throw MCPError.invalidParams("mission_key is required for ensure_mission.")
            }
            let coordinatorModelID = normalizedString(args["coordinator_model_id"] ?? args["coordinatorModelID"])
            let predecessorUpdate = try parseMissionPredecessorUpdate(args)

            environment.refresh()
            let previousCoordinatorIDs = coordinatorSessionIDs(in: environment.snapshot())
            if let existingSessionID = missionKey.flatMap({ findReusableMissionID(missionKey: $0, in: environment.snapshot()) }) {
                environment.selectCoordinator(existingSessionID)
                environment.refresh()
                return compactStateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(true),
                    "routed_to": .string("coordinator"),
                    "started_new_mission": .bool(false),
                    "selected_existing_mission": .bool(true),
                    "mission_key": .string(missionKey ?? "")
                ])
            }
            environment.startNewCoordinatorRun(coordinatorModelID)
            let result = await environment.submitDirective(message)
            environment.refresh()

            switch result {
            case .accepted:
                selectFreshCoordinatorIfAvailable(
                    previousCoordinatorIDs: previousCoordinatorIDs,
                    in: environment
                )
                var update = predecessorUpdate.update
                update.missionKey = missionKey
                if predecessorUpdate.hasPredecessorContext,
                   let coordinatorSessionID = environment.snapshot().coordinatorRail.coordinatorSessionID
                {
                    try environment.updateMissionPlan(coordinatorSessionID, update)
                    environment.refresh()
                } else if missionKey != nil,
                          let coordinatorSessionID = environment.snapshot().coordinatorRail.coordinatorSessionID
                {
                    try environment.updateMissionPlan(coordinatorSessionID, update)
                    environment.refresh()
                }
                var waitResult = await waitForInitialMissionPlanPublication(in: environment)
                if !waitResult.isVisible {
                    waitResult = try publishFallbackInitialMissionPlan(
                        in: environment,
                        directive: message,
                        missionKey: missionKey
                    )
                }
                return stateResponse(waitResult.snapshot, extra: [
                    "accepted": .bool(true),
                    "routed_to": .string("coordinator"),
                    "started_new_mission": .bool(true),
                    "selected_existing_mission": .bool(false),
                    "mission_key": AgentMCPToolHelpers.stringOrNull(missionKey),
                    "coordinator_model_id": AgentMCPToolHelpers.stringOrNull(coordinatorModelID)
                ].merging(waitResult.extra) { _, new in new })
            case let .rejected(message):
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(false),
                    "routed_to": .string("coordinator"),
                    "started_new_mission": .bool(true),
                    "selected_existing_mission": .bool(false),
                    "mission_key": AgentMCPToolHelpers.stringOrNull(missionKey),
                    "coordinator_model_id": AgentMCPToolHelpers.stringOrNull(coordinatorModelID),
                    "error": .string(message)
                ])
            }

        case "stop_mission":
            try validateExternalUserAction(metadata, action: "stop Coordinator Missions")
            environment.refresh()
            let targetMissionID: UUID
            if let rawSessionID = args["coordinator_session_id"] {
                targetMissionID = try requireCoordinatorSessionID(rawSessionID)
            } else if let selectedID = environment.snapshot().coordinatorRail.coordinatorSessionID {
                targetMissionID = selectedID
            } else {
                throw MCPError.invalidParams("coordinator_session_id is required when no Coordinator Mission is selected.")
            }
            try validateCoordinatorExists(targetMissionID, in: environment.snapshot())
            let result = await environment.stopCoordinatorMission(targetMissionID)
            environment.refresh()
            switch result {
            case .accepted:
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(true),
                    "routed_to": .string("coordinator_stop"),
                    "coordinator_session_id": .string(targetMissionID.uuidString)
                ])
            case let .rejected(message):
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(false),
                    "routed_to": .string("coordinator_stop"),
                    "coordinator_session_id": .string(targetMissionID.uuidString),
                    "error": .string(message)
                ])
            }

        case "archive_mission":
            try validateExternalUserAction(metadata, action: "archive Coordinator Missions")
            environment.refresh()
            let snapshot = environment.snapshot()
            let coordinatorSessionID = try requireCoordinatorSessionID(args["coordinator_session_id"])
            try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
            guard let plan = snapshot.coordinatorRail.availableCoordinators
                .first(where: { $0.sessionID == coordinatorSessionID })?
                .missionPlan
            else {
                throw MCPError.invalidParams("archive_mission requires a Coordinator Mission with a recorded Mission Plan.")
            }
            guard plan.status.isTerminal else {
                throw MCPError.invalidParams("archive_mission is only available after a Mission is completed or stopped. Stop the Mission first with coordinator_chat op=stop_mission, then archive it.")
            }
            let result = await environment.archiveMission(coordinatorSessionID)
            environment.refresh()
            let updatedSnapshot = environment.snapshot()
            let extra: [String: Value] = [
                "accepted": .bool(result.accepted),
                "routed_to": .string("archive_mission"),
                "coordinator_session_id": .string(coordinatorSessionID.uuidString),
                "already_archived": .bool(result.alreadyArchived),
                "unpinned": .bool(result.unpinned),
                "missions": missionInventoryValue(updatedSnapshot, includeArchived: true),
                "error": AgentMCPToolHelpers.stringOrNull(result.accepted ? nil : result.message)
            ]
            return compactStateResponse(updatedSnapshot, extra: extra)

        case "submit":
            let message = normalizedString(args["message"] ?? args["response"])
            let continuationAction = try parseCheckpointContinuationAction(args)
            let expectedCheckpointInstanceID = try parseExpectedCheckpointInstanceID(args)
            let newParent = AgentMCPToolHelpers.parseBool(args["new_parent"]) ?? false
            let coordinatorModelID = normalizedString(args["coordinator_model_id"] ?? args["coordinatorModelID"])
            let compact = AgentMCPToolHelpers.parseBool(args["compact"]) ?? true
            if newParent, message == nil {
                throw MCPError.invalidParams("message is required.")
            }
            if newParent, continuationAction != nil {
                throw MCPError.invalidParams("checkpoint_action is only valid for existing Coordinator Missions.")
            }
            if expectedCheckpointInstanceID != nil, continuationAction == nil {
                throw MCPError.invalidParams("expected_checkpoint_instance_id is only valid with checkpoint_action.")
            }
            let caller = try await classifyCaller(
                metadata,
                requiresResolvedRuntime: metadata.isCoordinatorRuntime && !newParent && continuationAction == nil
            )
            if newParent {
                try validateExternalMissionCreation(caller)
            }
            if continuationAction != nil {
                try validateExternalUserAction(caller, action: "submit Coordinator checkpoint actions")
            }

            environment.refresh()
            if !newParent, continuationAction == nil {
                try validateInternalNonOwnerCannotSubmit(caller)
            }
            var scopedCoordinatorSessionID: UUID?
            if newParent {
                environment.startNewCoordinatorRun(coordinatorModelID)
            } else if args["coordinator_session_id"] != nil || metadata.isCoordinatorRuntime {
                try validateInternalNonOwnerCannotSubmit(caller)
                let sessionID = try await resolveCoordinatorSessionID(
                    args["coordinator_session_id"],
                    in: environment.snapshot(),
                    metadata: metadata
                )
                try validateCoordinatorExists(sessionID, in: environment.snapshot())
                scopedCoordinatorSessionID = sessionID
                if !metadata.isCoordinatorRuntime {
                    environment.selectCoordinator(sessionID)
                    environment.refresh()
                }
            }

            let selectedSnapshot = environment.snapshot()
            let pendingChildRow = newParent || continuationAction != nil
                ? nil
                : environment.activePendingChildInteractionRow(scopedCoordinatorSessionID)
            let result: CoordinatorModeViewModel.DirectiveSubmissionResult
            let routedToChildInteraction: Bool
            if let pendingChildRow {
                try validateAgentModeCallerCanAnswerChildInteraction(caller)
                let actor = try decisionActorForChildSubmit(caller)
                try validateRuntimeChildInteractionSubmitAllowed(
                    actor: actor,
                    row: pendingChildRow,
                    snapshot: selectedSnapshot,
                    caller: caller,
                    durableApprovalAuthorityToken: environment.durableApprovalAuthorityToken
                )
                let submission = try pendingChildSubmission(args: args, message: message)
                result = await environment.submitPendingChildInteractionResponse(
                    submission,
                    pendingChildRow,
                    actor
                )
                routedToChildInteraction = true
            } else {
                if let continuationAction {
                    if shouldValidateCurrentCheckpointSubmit(for: continuationAction),
                       let message = checkpointInstanceMismatchMessage(
                           expected: expectedCheckpointInstanceID,
                           snapshot: selectedSnapshot
                       )
                    {
                        result = .rejected(message: message)
                    } else {
                        result = await environment.submitContinuation(continuationAction, expectedCheckpointInstanceID)
                    }
                    routedToChildInteraction = false
                } else {
                    try validateInternalNonOwnerCannotSubmit(caller)
                    if case .owningCoordinatorRuntime = caller {
                        throw MCPError.invalidParams("Coordinator runtime submit is limited to owner-scoped childAsk:auto responses. No eligible pending child question is active for this Mission, so the submit was rejected without mutating UI selection or sending a Coordinator user turn.")
                    }
                    guard let message, !message.isEmpty else {
                        throw MCPError.invalidParams("message is required.")
                    }
                    result = await environment.submitDirective(message)
                    routedToChildInteraction = false
                }
            }
            environment.refresh()

            switch result {
            case .accepted:
                let extra: [String: Value] = [
                    "accepted": .bool(true),
                    "routed_to": .string(routedToChildInteraction ? "child_interaction" : "coordinator")
                ]
                return compact
                    ? compactStateResponse(environment.snapshot(), extra: extra)
                    : stateResponse(environment.snapshot(), extra: extra)
            case let .rejected(message):
                let extra: [String: Value] = [
                    "accepted": .bool(false),
                    "routed_to": .string(routedToChildInteraction ? "child_interaction" : "coordinator"),
                    "error": .string(message)
                ]
                return compact
                    ? compactStateResponse(environment.snapshot(), extra: extra)
                    : stateResponse(environment.snapshot(), extra: extra)
            }

        case "propose_revision":
            let caller = try await classifyCaller(metadata, requiresResolvedRuntime: true)
            guard case let .owningCoordinatorRuntime(runtimeCoordinatorSessionID) = caller else {
                throw MCPError.invalidParams("propose_revision is restricted to the verified owning Coordinator runtime.")
            }
            let parsed = try parseRevisionProposal(args)
            if let requestedCoordinatorSessionID = parsed.requestedCoordinatorSessionID,
               requestedCoordinatorSessionID != runtimeCoordinatorSessionID
            {
                throw MCPError.invalidParams("Coordinator runtime propose_revision calls are scoped to the caller Mission and cannot target another Mission.")
            }
            environment.refresh()
            let snapshot = environment.snapshot()
            try validateCoordinatorExists(runtimeCoordinatorSessionID, in: snapshot)
            guard let plan = snapshot.coordinatorRail.availableCoordinators
                .first(where: { $0.sessionID == runtimeCoordinatorSessionID })?
                .missionPlan
            else {
                throw MCPError.invalidParams("propose_revision requires an existing Mission Plan owned by the caller runtime.")
            }
            guard plan.approvalState == .approved else {
                throw MCPError.invalidParams("propose_revision requires an approved Mission Plan.")
            }
            guard !plan.status.isTerminal else {
                throw MCPError.invalidParams("propose_revision cannot mutate a terminal Mission.")
            }
            guard parsed.expectedBasePlanID == plan.id else {
                throw MCPError.invalidParams("propose_revision targets a stale Mission Plan.")
            }
            guard try parsed.expectedBaseContractFingerprint == (plan.materialContractFingerprint()) else {
                throw MCPError.invalidParams("propose_revision targets a stale material contract.")
            }
            let request = CoordinatorMissionRevisionProposalRequest(
                expectedBasePlanID: parsed.expectedBasePlanID,
                expectedBaseContractFingerprint: parsed.expectedBaseContractFingerprint,
                summary: parsed.summary,
                rationale: parsed.rationale,
                affectedFields: parsed.affectedFields,
                remedy: parsed.remedy,
                supportingEvidenceIDs: parsed.supportingEvidenceIDs,
                requestedChange: parsed.requestedChange,
                actor: CoordinatorMissionRevisionProposalActor(
                    coordinatorSessionID: runtimeCoordinatorSessionID,
                    runtimeSessionID: runtimeCoordinatorSessionID
                )
            )
            let result: CoordinatorMissionRevisionProposalAppendResult
            do {
                result = try await environment.appendRevisionProposal(runtimeCoordinatorSessionID, request)
            } catch let error as CoordinatorMissionRevisionProposalLedgerError {
                throw MCPError.invalidParams(error.localizedDescription)
            }
            environment.refresh()
            return compactStateResponse(environment.snapshot(), extra: [
                "accepted": .bool(true),
                "routed_to": .string("revision_proposal"),
                "coordinator_session_id": .string(runtimeCoordinatorSessionID.uuidString),
                "proposal_id": .string(result.proposalID.uuidString),
                "existing_pending_retry": .bool(result.disposition == .existingPendingRetry),
                "persisted": .bool(true)
            ])

        case "mission_plan":
            let caller = try await classifyCaller(
                metadata,
                requiresResolvedRuntime: metadata.isCoordinatorRuntime
            )
            try validateInternalNonOwnerCannotUpdateMissionPlan(caller)
            environment.refresh()
            let snapshot = environment.snapshot()
            let coordinatorSessionID = try await resolveCoordinatorSessionID(
                args["coordinator_session_id"],
                in: snapshot,
                metadata: metadata
            )
            try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
            let existingPlan = snapshot.coordinatorRail.availableCoordinators
                .first(where: { $0.sessionID == coordinatorSessionID })?
                .missionPlan
            let update = try parseMissionPlanUpdate(
                args,
                existingPlan: existingPlan,
                caller: caller,
                durableApprovalAuthorityToken: environment.durableApprovalAuthorityToken(coordinatorSessionID)
            )
            try environment.updateMissionPlan(coordinatorSessionID, update)
            environment.refresh()
            let updatedSnapshot = environment.snapshot()
            let updatedPlan = updatedSnapshot.coordinatorRail.availableCoordinators
                .first(where: { $0.sessionID == coordinatorSessionID })?
                .missionPlan
            return stateResponse(updatedSnapshot, extra: [
                "updated": .bool(true),
                "routed_to": .string("mission_plan"),
                "coordinator_session_id": .string(coordinatorSessionID.uuidString),
                "mission_plan": missionPlanValue(updatedPlan)
            ])

        case "mission_status":
            environment.refresh()
            let snapshot = environment.snapshot()
            let coordinatorSessionID = try await resolveCoordinatorSessionID(
                args["coordinator_session_id"],
                in: snapshot,
                metadata: metadata
            )
            try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
            let compact = AgentMCPToolHelpers.parseBool(args["compact"] ?? args["summary"]) ?? false
            let statusValue = compact
                ? compactMissionStatusValue(coordinatorSessionID: coordinatorSessionID, snapshot: snapshot)
                : missionStatusValue(coordinatorSessionID: coordinatorSessionID, snapshot: snapshot)
            let extra = ["mission_status": statusValue]
            return compact
                ? compactStateResponse(snapshot, extra: extra)
                : stateResponse(snapshot, extra: extra)

        case "mission_events":
            environment.refresh()
            let snapshot = environment.snapshot()
            let coordinatorSessionID = try await resolveCoordinatorSessionID(
                args["coordinator_session_id"],
                in: snapshot,
                metadata: metadata
            )
            try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
            let sinceSeq = try parseOptionalNonNegativeInt(args["since_seq"] ?? args["sinceSeq"], name: "since_seq") ?? 0
            let limit = try parseOptionalPositiveInt(args["limit"], name: "limit") ?? 200
            let batch = environment.missionEvents(coordinatorSessionID, sinceSeq, min(limit, 500))
            return compactStateResponse(snapshot, extra: missionEventsResponseValue(batch))

        case "receipt":
            environment.refresh()
            let snapshot = environment.snapshot()
            let coordinatorSessionID = try await resolveCoordinatorSessionID(
                args["coordinator_session_id"],
                in: snapshot,
                metadata: metadata
            )
            try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
            let format = normalizedString(args["format"])?.lowercased() ?? "markdown"
            guard format == "markdown" || format == "md" else {
                throw MCPError.invalidParams("receipt format must be markdown.")
            }
            guard let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == coordinatorSessionID }),
                  let plan = option.missionPlan
            else {
                return compactStateResponse(snapshot, extra: [
                    "receipt_ready": .bool(false),
                    "format": .string("markdown"),
                    "error": .string("Mission receipt is not available because no Mission Plan is recorded.")
                ])
            }
            guard plan.status.isTerminal else {
                return compactStateResponse(snapshot, extra: [
                    "receipt_ready": .bool(false),
                    "format": .string("markdown"),
                    "receipt_ready_summary": missionReceiptReadySummaryValue(plan),
                    "error": .string("Mission receipt is not ready until the Mission is completed or stopped.")
                ])
            }
            return compactStateResponse(snapshot, extra: [
                "receipt_ready": .bool(true),
                "format": .string("markdown"),
                "coordinator_session_id": .string(coordinatorSessionID.uuidString),
                "title": .string(option.title),
                "receipt_ready_summary": missionReceiptReadySummaryValue(plan),
                "markdown": .string(CoordinatorMissionReceiptProjection(plan: plan).markdown)
            ])

        case "set_pace":
            try validateExternalUserAction(metadata, action: "change Mission pace")
            environment.refresh()
            let snapshot = environment.snapshot()
            let coordinatorSessionID = try await resolveCoordinatorSessionID(
                args["coordinator_session_id"],
                in: snapshot,
                metadata: metadata
            )
            try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
            let pace = try parseMissionPace(args["pace"] ?? args["default_pace"] ?? args["defaultPace"])
            let result = environment.setMissionPace(coordinatorSessionID, pace)
            environment.refresh()
            let updatedSnapshot = environment.snapshot()
            let missionStatus = compactMissionStatusValue(
                coordinatorSessionID: coordinatorSessionID,
                snapshot: updatedSnapshot
            )
            switch result {
            case .accepted:
                return compactStateResponse(updatedSnapshot, extra: [
                    "accepted": .bool(true),
                    "mission_status": missionStatus,
                    "routed_to": .string("set_pace"),
                    "pace": .string(pace.rawValue)
                ])
            case let .rejected(message):
                return compactStateResponse(updatedSnapshot, extra: [
                    "accepted": .bool(false),
                    "mission_status": missionStatus,
                    "routed_to": .string("set_pace"),
                    "pace": .string(pace.rawValue),
                    "error": .string(message)
                ])
            }

        case "set_autonomy":
            try validateExternalUserAction(metadata, action: "change Mission autonomy")
            environment.refresh()
            let snapshot = environment.snapshot()
            let coordinatorSessionID = try await resolveCoordinatorSessionID(
                args["coordinator_session_id"],
                in: snapshot,
                metadata: metadata
            )
            try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
            let autonomyClassKey = try parseMissionAutonomyClassKey(
                args["autonomy_class"] ?? args["autonomyClass"] ?? args["decision_class"] ?? args["decisionClass"] ?? args["class"]
            )
            let mode = try parseMissionAutonomyMode(args["mode"] ?? args["autonomy"] ?? args["value"])
            let result = environment.setMissionAutonomy(coordinatorSessionID, autonomyClassKey, mode)
            environment.refresh()
            let updatedSnapshot = environment.snapshot()
            let missionStatus = compactMissionStatusValue(
                coordinatorSessionID: coordinatorSessionID,
                snapshot: updatedSnapshot
            )
            switch result {
            case .accepted:
                return compactStateResponse(updatedSnapshot, extra: [
                    "accepted": .bool(true),
                    "mission_status": missionStatus,
                    "routed_to": .string("set_autonomy"),
                    "autonomy_class": .string(autonomyClassKey),
                    "mode": .string(mode.rawValue)
                ])
            case let .rejected(message):
                return compactStateResponse(updatedSnapshot, extra: [
                    "accepted": .bool(false),
                    "mission_status": missionStatus,
                    "routed_to": .string("set_autonomy"),
                    "autonomy_class": .string(autonomyClassKey),
                    "mode": .string(mode.rawValue),
                    "error": .string(message)
                ])
            }

        case "wait_for_update":
            let timeout = try parseCoordinatorWaitTimeout(args["timeout_seconds"] ?? args["timeout"])
            let sinceFingerprint = normalizedString(args["since_fingerprint"] ?? args["sinceFingerprint"])
            let deadline = Date().addingTimeInterval(timeout)
            var latestSnapshot: CoordinatorModeSnapshot
            var latestCoordinatorSessionID: UUID
            var latestStatus: Value
            repeat {
                environment.refresh()
                latestSnapshot = environment.snapshot()
                latestCoordinatorSessionID = try await resolveCoordinatorSessionID(
                    args["coordinator_session_id"],
                    in: latestSnapshot,
                    metadata: metadata
                )
                try validateCoordinatorExists(latestCoordinatorSessionID, in: latestSnapshot)
                latestStatus = compactMissionStatusValue(
                    coordinatorSessionID: latestCoordinatorSessionID,
                    snapshot: latestSnapshot
                )
                let fingerprint = latestStatus.objectValue?["fingerprint"]?.stringValue
                if sinceFingerprint == nil || fingerprint != sinceFingerprint {
                    return compactStateResponse(latestSnapshot, extra: [
                        "changed": .bool(true),
                        "timed_out": .bool(false),
                        "mission_status": latestStatus
                    ])
                }
                if Date() >= deadline {
                    return compactStateResponse(latestSnapshot, extra: [
                        "changed": .bool(false),
                        "timed_out": .bool(true),
                        "mission_status": latestStatus
                    ])
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            } while true

        default:
            throw MCPError.invalidParams("\(toolName) op must be one of: \(Self.supportedOps.joined(separator: ", ")).")
        }
    }

    private func classifyCaller(
        _ metadata: RequestMetadata,
        requiresResolvedRuntime: Bool = false
    ) async throws -> CallerClassification {
        if metadata.isCoordinatorRuntime {
            if let runtimeCoordinatorID = await resolveRuntimeCoordinatorSessionID(metadata) {
                return .owningCoordinatorRuntime(runtimeCoordinatorID)
            }
            if requiresResolvedRuntime {
                throw MCPError.invalidParams("Coordinator runtime calls cannot resolve the caller Mission. Runtime Mission-scoped operations do not fall back to the selected UI Mission.")
            }
            return .internalNonOwnerAgentModeWorker
        }
        if metadata.runPurpose == .agentModeRun || metadata.runPurpose == .discoverRun || metadata.taskLabelKind != nil {
            return .internalNonOwnerAgentModeWorker
        }
        return .externalCaller
    }

    private func validateExternalMissionCreation(_ metadata: RequestMetadata) throws {
        if metadata.isCoordinatorRuntime || metadata.taskLabelKind == .coordinator || metadata.runPurpose == .agentModeRun || metadata.runPurpose == .discoverRun {
            throw MCPError.invalidParams("Coordinator runtime sessions cannot create other Coordinator Missions. Record a follow-up recommendation in the current Mission and wait for an external user or CLI driver to start it.")
        }
    }

    private func validateExternalMissionCreation(_ caller: CallerClassification) throws {
        guard caller == .externalCaller else {
            throw MCPError.invalidParams("Coordinator runtime sessions cannot create other Coordinator Missions. Record a follow-up recommendation in the current Mission and wait for an external user or CLI driver to start it.")
        }
    }

    private func validateExternalUserAction(_ metadata: RequestMetadata, action: String) throws {
        if metadata.isCoordinatorRuntime || metadata.taskLabelKind == .coordinator || metadata.runPurpose == .agentModeRun || metadata.runPurpose == .discoverRun {
            throw MCPError.invalidParams("Coordinator runtime sessions cannot \(action). User-action parity operations must be driven by an external user or CLI driver.")
        }
    }

    private func validateExternalUserAction(_ caller: CallerClassification, action: String) throws {
        guard caller == .externalCaller else {
            throw MCPError.invalidParams("Coordinator runtime sessions cannot \(action). User-action parity operations must be driven by an external user or CLI driver.")
        }
    }

    private func validateAgentModeCallerCanAnswerChildInteraction(_ caller: CallerClassification) throws {
        guard caller != .internalNonOwnerAgentModeWorker else {
            throw MCPError.invalidParams("Internal Agent Mode callers cannot answer Coordinator Mission child questions as the user. Only the resolved owning Coordinator runtime may answer Director-routed child questions; external user/CLI callers may answer user-routed questions.")
        }
    }

    private func validateInternalNonOwnerCannotSubmit(_ caller: CallerClassification) throws {
        guard caller != .internalNonOwnerAgentModeWorker else {
            throw MCPError.invalidParams("Internal non-owner Agent Mode workers cannot submit Coordinator user turns, mutate selected or explicit Missions, or produce user decisions. Use the owning Coordinator runtime for Director-routed work, or wait for an external user/CLI caller.")
        }
    }

    private func validateInternalNonOwnerCannotUpdateMissionPlan(_ caller: CallerClassification) throws {
        guard caller != .internalNonOwnerAgentModeWorker else {
            throw MCPError.invalidParams("Internal non-owner Agent Mode workers cannot mutate Coordinator Mission Plans. mission_plan is restricted to external callers and the owning Coordinator runtime.")
        }
    }

    private func decisionActorForChildSubmit(_ caller: CallerClassification) throws -> CoordinatorMissionDecisionActor {
        switch caller {
        case .owningCoordinatorRuntime:
            return .director
        case .internalNonOwnerAgentModeWorker:
            throw MCPError.invalidParams("Internal Agent Mode workers cannot answer Coordinator child questions as the external user. Only the owning Coordinator runtime may answer childAsk:auto questions; otherwise wait for a genuine external user/CLI answer.")
        case .externalCaller:
            return .user
        }
    }

    private func validateRuntimeChildInteractionSubmitAllowed(
        actor: CoordinatorMissionDecisionActor,
        row: CoordinatorModeRow,
        snapshot: CoordinatorModeSnapshot,
        caller: CallerClassification,
        durableApprovalAuthorityToken: (UUID) -> String?
    ) throws {
        guard actor == .director else { return }
        guard let runtimeCoordinatorID = caller.runtimeCoordinatorSessionID else {
            throw MCPError.invalidParams("Coordinator runtime cannot answer child questions because RepoPrompt cannot resolve the caller Mission.")
        }
        let coordinatorSessionID = row.parentCoordinator?.sessionID ?? snapshot.coordinatorRail.coordinatorSessionID
        guard coordinatorSessionID == runtimeCoordinatorID else {
            throw MCPError.invalidParams("Coordinator runtime child answers are scoped to the caller Mission and cannot answer another Mission's child question.")
        }
        guard let plan = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == runtimeCoordinatorID })?.missionPlan
        else {
            throw MCPError.invalidParams("Coordinator runtime cannot answer child questions without a Mission Plan that routes child questions to Director.")
        }
        guard plan.resolvedAutonomy(for: .childAsk) == .auto else {
            throw MCPError.invalidParams("Coordinator runtime cannot answer this child question because current Mission Policy routes child questions to Me. Wait for an external answer, or for an external user action to route child questions to Director.")
        }
        guard (plan.approvalState == .approved && plan.hasDurableApprovalAuthority(durableApprovalAuthorityToken(runtimeCoordinatorID)))
            || runtimeChildQuestionIsOwnedByEligiblePreapprovalNode(row: row, plan: plan)
        else {
            throw MCPError.invalidParams("Coordinator runtime cannot answer this child question before the approved Mission has an app-confirmed durable approval authority token, unless the question is bound to an exact eligible pre-approval planning/evidence node.")
        }
    }

    private func runtimeChildQuestionIsOwnedByEligiblePreapprovalNode(
        row: CoordinatorModeRow,
        plan: CoordinatorMissionPlan
    ) -> Bool {
        guard plan.approvalState == .awaitingApproval else { return false }
        let interactionID = row.pendingInteraction?.id
        guard let node = plan.nodes.first(where: { node in
            node.boundSessionID == row.sessionID
                || (interactionID != nil && node.boundInteractionID == interactionID)
        }) else { return false }
        guard isEligiblePreApprovalPlanningNode(node, workstreams: plan.workstreams) else { return false }
        return node.boundSessionID == row.sessionID || node.boundInteractionID == interactionID
    }

    private func findReusableMissionID(missionKey: String, in snapshot: CoordinatorModeSnapshot) -> UUID? {
        let normalizedKey = missionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return nil }
        return snapshot.coordinatorRail.availableCoordinators
            .first { option in
                guard let plan = option.missionPlan,
                      plan.missionKey == normalizedKey,
                      plan.status != .stopped,
                      plan.status != .completed
                else { return false }
                return true
            }?
            .sessionID
    }

    private func parseCoordinatorWaitTimeout(_ value: Value?) throws -> TimeInterval {
        let parsed = try AgentMCPToolHelpers.parseTimeoutSeconds(value) ?? 30
        guard parsed <= 300 else {
            throw MCPError.invalidParams("timeout_seconds must be 300 seconds or less.")
        }
        return parsed
    }

    private struct ParsedRevisionProposal {
        let requestedCoordinatorSessionID: UUID?
        let expectedBasePlanID: UUID
        let expectedBaseContractFingerprint: String
        let summary: String
        let rationale: String?
        let affectedFields: [String]
        let remedy: String
        let supportingEvidenceIDs: [UUID]
        let requestedChange: String
    }

    private func parseRevisionProposal(_ args: [String: Value]) throws -> ParsedRevisionProposal {
        let acceptedKeys: Set = [
            "op", "context_id", "_tabID", "_windowID",
            "coordinator_session_id", "coordinatorSessionID",
            "base_plan_id", "basePlanID",
            "base_contract_fingerprint", "baseContractFingerprint",
            "summary", "rationale",
            "affected_fields", "affectedFields",
            "remedy",
            "supporting_evidence_ids", "supportingEvidenceIDs",
            "requested_change", "requestedChange"
        ]
        let rejectedKeys = args.keys.filter { !acceptedKeys.contains($0) }.sorted()
        guard rejectedKeys.isEmpty else {
            throw MCPError.invalidParams(
                "propose_revision is summary-only and rejects unsupported or authority-bearing fields: \(rejectedKeys.joined(separator: ", ")). Exact replacement plans/diffs, canonical identities, approval/contract/user-decision/node/binding/resolution fields, and immediate approval requests are not accepted."
            )
        }

        let requestedCoordinatorSessionID = try parseAliasedOptionalUUID(
            snakeValue: args["coordinator_session_id"],
            camelValue: args["coordinatorSessionID"],
            name: "coordinator_session_id"
        )
        guard let expectedBasePlanID = try parseAliasedOptionalUUID(
            snakeValue: args["base_plan_id"],
            camelValue: args["basePlanID"],
            name: "base_plan_id"
        ) else {
            throw MCPError.invalidParams("base_plan_id is required.")
        }
        let expectedBaseContractFingerprint = try parseAliasedRequiredString(
            snakeValue: args["base_contract_fingerprint"],
            camelValue: args["baseContractFingerprint"],
            name: "base_contract_fingerprint"
        )
        let summary = try AgentMCPToolHelpers.requireNonEmptyString(args["summary"], name: "summary")
        let rationale = normalizedString(args["rationale"])
        let affectedFields = try parseAliasedAffectedFields(
            snakeValue: args["affected_fields"],
            camelValue: args["affectedFields"]
        )
        let remedy = try AgentMCPToolHelpers.requireNonEmptyString(args["remedy"], name: "remedy")
        let supportingEvidenceIDs = try parseAliasedEvidenceIDs(
            snakeValue: args["supporting_evidence_ids"],
            camelValue: args["supportingEvidenceIDs"]
        )
        let requestedChange = try parseAliasedRequestedChange(
            snakeValue: args["requested_change"],
            camelValue: args["requestedChange"]
        )
        return ParsedRevisionProposal(
            requestedCoordinatorSessionID: requestedCoordinatorSessionID,
            expectedBasePlanID: expectedBasePlanID,
            expectedBaseContractFingerprint: expectedBaseContractFingerprint,
            summary: summary,
            rationale: rationale,
            affectedFields: affectedFields,
            remedy: remedy,
            supportingEvidenceIDs: supportingEvidenceIDs,
            requestedChange: requestedChange
        )
    }

    private func parseAliasedOptionalUUID(
        snakeValue: Value?,
        camelValue: Value?,
        name: String
    ) throws -> UUID? {
        let snake = try optionalUUID(snakeValue, name: name)
        let camel = try optionalUUID(camelValue, name: name)
        try rejectConflictingAliases(snake: snake, camel: camel, name: name)
        return snake ?? camel
    }

    private func parseAliasedRequiredString(
        snakeValue: Value?,
        camelValue: Value?,
        name: String
    ) throws -> String {
        let snake = try snakeValue.map {
            try AgentMCPToolHelpers.requireNonEmptyString($0, name: name)
        }
        let camel = try camelValue.map {
            try AgentMCPToolHelpers.requireNonEmptyString($0, name: name)
        }
        try rejectConflictingAliases(snake: snake, camel: camel, name: name)
        guard let value = snake ?? camel else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return value
    }

    private func parseAliasedAffectedFields(
        snakeValue: Value?,
        camelValue: Value?
    ) throws -> [String] {
        let snake = try snakeValue.map { try parseRequiredStringArray($0, name: "affected_fields") }
        let camel = try camelValue.map { try parseRequiredStringArray($0, name: "affected_fields") }
        let normalizedSnake = snake.map(CoordinatorMissionRevisionProposalIdentity.canonicalAffectedFields)
        let normalizedCamel = camel.map(CoordinatorMissionRevisionProposalIdentity.canonicalAffectedFields)
        try rejectConflictingAliases(
            snake: normalizedSnake,
            camel: normalizedCamel,
            name: "affected_fields"
        )
        guard let fields = normalizedSnake ?? normalizedCamel else {
            throw MCPError.invalidParams("affected_fields must be a non-empty array of strings.")
        }
        return fields
    }

    private func parseAliasedEvidenceIDs(
        snakeValue: Value?,
        camelValue: Value?
    ) throws -> [UUID] {
        let snake = try snakeValue.map { try parseUUIDArray($0, name: "supporting_evidence_ids") }
        let camel = try camelValue.map { try parseUUIDArray($0, name: "supporting_evidence_ids") }
        let normalizedSnake = snake.map(CoordinatorMissionRevisionProposalIdentity.canonicalEvidenceIDs)
        let normalizedCamel = camel.map(CoordinatorMissionRevisionProposalIdentity.canonicalEvidenceIDs)
        try rejectConflictingAliases(
            snake: normalizedSnake,
            camel: normalizedCamel,
            name: "supporting_evidence_ids"
        )
        return normalizedSnake ?? normalizedCamel ?? []
    }

    private func parseAliasedRequestedChange(
        snakeValue: Value?,
        camelValue: Value?
    ) throws -> String {
        let snake = try snakeValue.map {
            try AgentMCPToolHelpers.requireNonEmptyString($0, name: "requested_change")
        }
        let camel = try camelValue.map {
            try AgentMCPToolHelpers.requireNonEmptyString($0, name: "requested_change")
        }
        let normalizedSnake = snake.map { CoordinatorMissionCanonicalRequestedChange(rawValue: $0) }
        let normalizedCamel = camel.map { CoordinatorMissionCanonicalRequestedChange(rawValue: $0) }
        try rejectConflictingAliases(
            snake: normalizedSnake,
            camel: normalizedCamel,
            name: "requested_change"
        )
        guard let value = snake ?? camel else {
            throw MCPError.invalidParams("requested_change is required.")
        }
        return value
    }

    private func rejectConflictingAliases<T: Equatable>(
        snake: T?,
        camel: T?,
        name: String
    ) throws {
        if let snake, let camel, snake != camel {
            throw MCPError.invalidParams("Conflicting \(name) snake_case and camelCase aliases are not allowed.")
        }
    }

    private func parseRequiredStringArray(_ value: Value, name: String) throws -> [String] {
        guard let values = value.arrayValue else {
            throw MCPError.invalidParams("\(name) must be a non-empty array of strings.")
        }
        let parsed = try values.enumerated().map { index, value in
            try AgentMCPToolHelpers.requireNonEmptyString(value, name: "\(name)[\(index)]")
        }
        guard !parsed.isEmpty else {
            throw MCPError.invalidParams("\(name) must be a non-empty array of strings.")
        }
        return parsed
    }

    private func parseUUIDArray(_ value: Value, name: String) throws -> [UUID] {
        guard let values = value.arrayValue else {
            throw MCPError.invalidParams("\(name) must be an array of UUID strings.")
        }
        return try values.enumerated().map { index, value in
            guard let raw = value.stringValue,
                  let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                throw MCPError.invalidParams("\(name)[\(index)] must be a UUID string.")
            }
            return id
        }
    }

    private func parseMissionPlanUpdate(
        _ args: [String: Value],
        existingPlan: CoordinatorMissionPlan?,
        caller: CallerClassification,
        durableApprovalAuthorityToken: String? = nil
    ) throws -> CoordinatorMissionPlanUpdate {
        let missionKey = normalizedString(args["mission_key"] ?? args["missionKey"])
        let objective = normalizedString(args["objective"])
        let predecessorUpdate = try parseMissionPredecessorUpdate(args)
        let status = try parseOptionalMissionPlanStatus(args["status"])
        let approvalState = try parseOptionalMissionPlanApprovalState(args["approval_state"] ?? args["approvalState"])
        let hasShapeSummary = args.keys.contains("shape_summary") || args.keys.contains("shapeSummary")
        let shapeSummary = try hasShapeSummary
            ? parseMissionShapeSummary(args["shape_summary"] ?? args["shapeSummary"])
            : nil
        let hasPolicySnapshot = args.keys.contains("policy_snapshot") || args.keys.contains("policySnapshot")
        let policySnapshot = try hasPolicySnapshot
            ? parseMissionPolicySnapshot(args["policy_snapshot"] ?? args["policySnapshot"])
            : nil
        let hasAutonomy = args.keys.contains("autonomy") || args.keys.contains("autonomy_map") || args.keys.contains("autonomyMap")
        let autonomy = try hasAutonomy
            ? parseMissionAutonomyMap(args["autonomy"] ?? args["autonomy_map"] ?? args["autonomyMap"], name: "autonomy")
            : nil
        let replaceWorkstreams = AgentMCPToolHelpers.parseBool(args["replace_workstreams"] ?? args["replaceWorkstreams"]) ?? false
        let replaceNodes = AgentMCPToolHelpers.parseBool(args["replace_nodes"] ?? args["replaceNodes"]) ?? false
        let workstreams = try args.keys.contains("workstreams")
            ? parseMissionWorkstreams(args["workstreams"], existingPlan: replaceWorkstreams ? nil : existingPlan)
            : nil
        let effectiveWorkstreams = workstreams ?? existingPlan?.workstreams ?? []
        let nodes = try args.keys.contains("nodes")
            ? parseMissionPlanNodes(args["nodes"], workstreams: effectiveWorkstreams, existingPlan: replaceNodes ? nil : existingPlan)
            : nil
        let effectiveNodes = nodes ?? existingPlan?.nodes ?? []
        let hasRoutingDecisions = args.keys.contains("routing_decisions") || args.keys.contains("routingDecisions")
        let routingDecisions = try hasRoutingDecisions
            ? parseMissionRoutingDecisions(args["routing_decisions"] ?? args["routingDecisions"], nodes: effectiveNodes, workstreams: effectiveWorkstreams)
            : nil
        let hasDecisions = args.keys.contains("decisions") || args.keys.contains("decision_ledger") || args.keys.contains("decisionLedger")
        let decisions = try hasDecisions
            ? parseMissionDecisionRecords(args["decisions"] ?? args["decision_ledger"] ?? args["decisionLedger"], nodes: effectiveNodes, workstreams: effectiveWorkstreams)
            : nil
        let hasEvidence = args.keys.contains("evidence") || args.keys.contains("evidence_ledger") || args.keys.contains("evidenceLedger")
        let evidence = try hasEvidence
            ? parseMissionEvidenceRecords(args["evidence"] ?? args["evidence_ledger"] ?? args["evidenceLedger"], nodes: effectiveNodes, workstreams: effectiveWorkstreams)
            : nil
        let events = try parseMissionPlanEvents(args["events"], nodes: effectiveNodes)
        if missionKey == nil,
           objective == nil,
           !predecessorUpdate.hasPredecessorContext,
           status == nil,
           approvalState == nil,
           shapeSummary == nil,
           policySnapshot == nil,
           autonomy == nil,
           workstreams == nil,
           nodes == nil,
           routingDecisions == nil,
           decisions == nil,
           evidence == nil,
           events.isEmpty
        {
            throw MCPError.invalidParams("mission_plan requires at least one of mission_key, objective, predecessor context, status, approval_state, shape_summary, policy_snapshot, autonomy, workstreams, nodes, routing_decisions, decisions, evidence, or events.")
        }
        try validateTerminalMissionPlanReceiptFreeze(
            existingPlan: existingPlan,
            args: args,
            status: status,
            approvalState: approvalState
        )
        try validateMissionPlanUpdateApprovalGate(
            existingPlan: existingPlan,
            missionKey: missionKey,
            objective: objective,
            predecessorMissionID: predecessorUpdate.update.predecessorMissionID,
            predecessorTitle: predecessorUpdate.update.predecessorTitle,
            predecessorSummary: predecessorUpdate.update.predecessorSummary,
            status: status,
            approvalState: approvalState,
            shapeSummary: shapeSummary,
            hasShapeSummary: hasShapeSummary,
            policySnapshot: policySnapshot,
            hasPolicySnapshot: hasPolicySnapshot,
            autonomy: autonomy,
            hasAutonomy: hasAutonomy,
            workstreams: workstreams,
            nodes: nodes,
            effectiveWorkstreams: effectiveWorkstreams,
            replaceWorkstreams: replaceWorkstreams,
            replaceNodes: replaceNodes,
            caller: caller,
            durableApprovalAuthorityToken: durableApprovalAuthorityToken
        )
        try validateCompletedMissionPlanNodesAreTerminal(
            status: status ?? existingPlan?.status,
            nodes: effectiveNodes
        )
        try validateChildAskAutoCompletionLedger(
            existingPlan: existingPlan,
            policySnapshot: policySnapshot,
            autonomy: autonomy,
            nodes: nodes,
            decisions: decisions,
            evidence: evidence
        )
        return try CoordinatorMissionPlanUpdate(
            objective: objective,
            missionKey: missionKey,
            predecessorMissionID: predecessorUpdate.update.predecessorMissionID,
            predecessorTitle: predecessorUpdate.update.predecessorTitle,
            predecessorSummary: predecessorUpdate.update.predecessorSummary,
            status: status,
            approvalState: approvalState,
            shapeSummary: shapeSummary,
            policySnapshot: policySnapshot,
            autonomy: autonomy,
            workstreams: workstreams,
            nodes: nodes,
            replaceWorkstreams: replaceWorkstreams,
            replaceNodes: replaceNodes,
            routingDecisions: routingDecisions,
            decisions: decisions,
            evidence: evidence,
            events: events,
            updatedAt: parseOptionalDate(args["updated_at"] ?? args["updatedAt"], name: "updated_at") ?? Date()
        )
    }

    private func validateMissionPlanUpdateApprovalGate(
        existingPlan: CoordinatorMissionPlan?,
        missionKey: String?,
        objective: String?,
        predecessorMissionID: UUID?,
        predecessorTitle: String?,
        predecessorSummary: String?,
        status: CoordinatorMissionPlanStatus?,
        approvalState: CoordinatorMissionPlanApprovalState?,
        shapeSummary: CoordinatorMissionShapeSummary?,
        hasShapeSummary: Bool,
        policySnapshot: CoordinatorMissionPolicySnapshot?,
        hasPolicySnapshot: Bool,
        autonomy: [String: CoordinatorMissionAutonomyMode]?,
        hasAutonomy: Bool,
        workstreams: [CoordinatorMissionWorkstreamSummary]?,
        nodes: [CoordinatorMissionPlanNode]?,
        effectiveWorkstreams: [CoordinatorMissionWorkstreamSummary],
        replaceWorkstreams: Bool,
        replaceNodes: Bool,
        caller: CallerClassification,
        durableApprovalAuthorityToken: String? = nil
    ) throws {
        if status == .stopped {
            throw MCPError.invalidParams("mission_plan cannot stop Coordinator Missions; Stop is app/external-user owned. Use coordinator_chat op=stop_mission or checkpoint_action stop.")
        }
        if approvalState == .notRequired {
            throw MCPError.invalidParams("mission_plan cannot set approval_state to not_required; concrete Mission Plans require the user checkpoint approval boundary.")
        }
        if approvalState == .approved, existingPlan == nil {
            throw MCPError.invalidParams("mission_plan cannot create a fresh Mission Plan with approval_state approved; approve through the user checkpoint/continuation path.")
        }
        if approvalState == .approved,
           let existingApprovalState = existingPlan?.approvalState,
           existingApprovalState != .approved
        {
            throw MCPError.invalidParams("mission_plan cannot advance approval_state to approved; approve the current Mission Plan through the user checkpoint/continuation path.")
        }
        try validateMissionPlanUserOwnedPolicyFields(
            existingPlan: existingPlan,
            policySnapshot: policySnapshot,
            hasPolicySnapshot: hasPolicySnapshot,
            autonomy: autonomy,
            hasAutonomy: hasAutonomy,
            caller: caller
        )
        if let existingPlan, existingPlan.status.isTerminal {
            try validateTerminalMissionPlanUpdate(
                existingPlan: existingPlan,
                status: status,
                approvalState: approvalState,
                nodes: nodes
            )
        }
        if existingPlan?.approvalState == .approved {
            if let approvalState, approvalState != .approved {
                throw MCPError.invalidParams("mission_plan cannot downgrade approval_state from approved to \(approvalState.rawValue).")
            }
            if status == .draft {
                throw MCPError.invalidParams("mission_plan cannot downgrade an approved Mission status back to draft.")
            }
            try validateApprovedMissionContractImmutability(
                existingPlan: existingPlan,
                missionKey: missionKey,
                objective: objective,
                predecessorMissionID: predecessorMissionID,
                predecessorTitle: predecessorTitle,
                predecessorSummary: predecessorSummary,
                shapeSummary: shapeSummary,
                hasShapeSummary: hasShapeSummary,
                policySnapshot: policySnapshot,
                hasPolicySnapshot: hasPolicySnapshot,
                autonomy: autonomy,
                hasAutonomy: hasAutonomy,
                workstreams: workstreams,
                nodes: nodes,
                replaceWorkstreams: replaceWorkstreams,
                replaceNodes: replaceNodes
            )
        }
        let effectiveApprovalState = approvalState ?? existingPlan?.approvalState ?? .awaitingApproval
        if case .owningCoordinatorRuntime = caller,
           effectiveApprovalState == .approved,
           existingPlan?.hasDurableApprovalAuthority(durableApprovalAuthorityToken) != true
        {
            throw MCPError.invalidParams("Coordinator runtime Mission updates require the app-confirmed durable approval authority token. Refresh Mission status and wait for the post-approval handoff barrier before recording runtime progress.")
        }
        guard effectiveApprovalState == .approved else {
            if let status, missionPlanStatusRequiresApproval(status) {
                throw MCPError.invalidParams("mission_plan cannot advance status to \(status.rawValue) before approval_state is approved.")
            }
            let progressingNodes = nodes?.filter { missionPlanNodeStatusRequiresApproval($0.status) } ?? []
            if let disallowedNode = progressingNodes.first(where: {
                !allowsPreApprovalPlanningNodeProgress(
                    incoming: $0,
                    existingPlan: existingPlan,
                    effectiveWorkstreams: effectiveWorkstreams
                )
            }) {
                throw MCPError.invalidParams("nodes[].status \(disallowedNode.status.rawValue) requires approval_state approved before runtime progress can be recorded, except for the exact node-bound pre-approval planning/probe/design-critique exceptions.")
            }
            return
        }
    }

    private func validateTerminalMissionPlanReceiptFreeze(
        existingPlan: CoordinatorMissionPlan?,
        args: [String: Value],
        status: CoordinatorMissionPlanStatus?,
        approvalState: CoordinatorMissionPlanApprovalState?
    ) throws {
        guard let existingPlan, existingPlan.status.isTerminal else { return }
        if let status, status != existingPlan.status {
            throw MCPError.invalidParams("mission_plan cannot reopen a terminal Mission that is already \(existingPlan.status.rawValue). Terminal Mission state is monotonic.")
        }
        if let approvalState, approvalState != existingPlan.approvalState {
            throw MCPError.invalidParams("mission_plan cannot change approval_state after a Mission is terminal.")
        }
        let allowedKeys: Set = [
            "op",
            "coordinator_session_id",
            "coordinatorSessionID",
            "status",
            "approval_state",
            "approvalState",
            "updated_at",
            "updatedAt"
        ]
        let receiptAffectingKeys = args.keys.filter { !allowedKeys.contains($0) }.sorted()
        guard receiptAffectingKeys.isEmpty else {
            throw MCPError.invalidParams("mission_plan cannot update receipt-affecting fields after a Mission is terminal. Frozen field(s): \(receiptAffectingKeys.joined(separator: ", ")).")
        }
    }

    private func validateMissionPlanUserOwnedPolicyFields(
        existingPlan: CoordinatorMissionPlan?,
        policySnapshot: CoordinatorMissionPolicySnapshot?,
        hasPolicySnapshot: Bool,
        autonomy: [String: CoordinatorMissionAutonomyMode]?,
        hasAutonomy: Bool,
        caller: CallerClassification
    ) throws {
        guard let existingPlan else {
            if caller.runtimeCoordinatorSessionID != nil {
                if hasPolicySnapshot, let policySnapshot, policySnapshot != .defaultPolicy {
                    throw MCPError.invalidParams("mission_plan cannot establish arbitrary Mission policy authority on first plan creation from the Coordinator runtime. Use app/external user policy defaults or user-action controls.")
                }
                if hasAutonomy,
                   let autonomy,
                   autonomyContractDiffers(existing: CoordinatorMissionPolicySnapshot.defaultAutonomy, incoming: autonomy)
                {
                    throw MCPError.invalidParams("mission_plan cannot establish arbitrary Mission autonomy authority on first plan creation from the Coordinator runtime. Use app/external user policy defaults or user-action controls.")
                }
            }
            return
        }
        if hasPolicySnapshot, let policySnapshot {
            guard let existingPolicy = existingPlan.policySnapshot else {
                throw MCPError.invalidParams("mission_plan cannot establish or mutate Mission policy authority before approval; choose Mission policy through the app/external user-action controls.")
            }
            guard CoordinatorMissionMaterialContractComparator.policiesMatch(policySnapshot, existingPolicy) else {
                throw MCPError.invalidParams("mission_plan cannot change user-owned Mission policy authority, including pace, autonomy, max_concurrent, standing guidance, pinned skills, or pinned contexts; use external UI/MCP user-action paths so a user decision is recorded.")
            }
        }
        if hasAutonomy,
           let autonomy,
           autonomyContractDiffers(existing: existingPlan.autonomy, incoming: autonomy)
        {
            throw MCPError.invalidParams("mission_plan cannot change user-owned Mission autonomy authority; use external UI/MCP user-action paths so a user decision is recorded.")
        }
    }

    private func validateTerminalMissionPlanUpdate(
        existingPlan: CoordinatorMissionPlan,
        status: CoordinatorMissionPlanStatus?,
        approvalState: CoordinatorMissionPlanApprovalState?,
        nodes: [CoordinatorMissionPlanNode]?
    ) throws {
        if let status, status != existingPlan.status {
            throw MCPError.invalidParams("mission_plan cannot reopen a terminal Mission that is already \(existingPlan.status.rawValue). Terminal Mission state is monotonic.")
        }
        if let approvalState, approvalState != existingPlan.approvalState {
            throw MCPError.invalidParams("mission_plan cannot change approval_state after a Mission is terminal.")
        }
        if let reopeningNode = nodes?.first(where: { !$0.status.isTerminal }) {
            throw MCPError.invalidParams("mission_plan cannot reopen terminal Mission node \"\(reopeningNode.title)\" with status \(reopeningNode.status.rawValue). Terminal node state is monotonic.")
        }
    }

    private func validateApprovedMissionContractImmutability(
        existingPlan: CoordinatorMissionPlan?,
        missionKey: String?,
        objective: String?,
        predecessorMissionID: UUID?,
        predecessorTitle: String?,
        predecessorSummary: String?,
        shapeSummary: CoordinatorMissionShapeSummary?,
        hasShapeSummary: Bool,
        policySnapshot: CoordinatorMissionPolicySnapshot?,
        hasPolicySnapshot: Bool,
        autonomy: [String: CoordinatorMissionAutonomyMode]?,
        hasAutonomy: Bool,
        workstreams: [CoordinatorMissionWorkstreamSummary]?,
        nodes: [CoordinatorMissionPlanNode]?,
        replaceWorkstreams: Bool,
        replaceNodes: Bool
    ) throws {
        guard let existingPlan else { return }
        if let missionKey, missionKey != existingPlan.missionKey {
            throw materialApprovedContractChangeError("mission_key")
        }
        if let objective, objective != existingPlan.objective {
            throw materialApprovedContractChangeError("objective")
        }
        if let predecessorMissionID, predecessorMissionID != existingPlan.predecessorMissionID {
            throw materialApprovedContractChangeError("predecessor_mission_id")
        }
        if let predecessorTitle, predecessorTitle != existingPlan.predecessorTitle {
            throw materialApprovedContractChangeError("predecessor_title")
        }
        if let predecessorSummary, predecessorSummary != existingPlan.predecessorSummary {
            throw materialApprovedContractChangeError("predecessor_summary")
        }
        if hasShapeSummary, shapeSummary != existingPlan.shapeSummary {
            throw materialApprovedContractChangeError("shape_summary")
        }
        if hasPolicySnapshot,
           let policySnapshot,
           let existingPolicy = existingPlan.policySnapshot,
           !CoordinatorMissionMaterialContractComparator.policiesMatch(policySnapshot, existingPolicy)
        {
            throw materialApprovedContractChangeError("policy_snapshot")
        }
        if hasPolicySnapshot, (policySnapshot == nil) != (existingPlan.policySnapshot == nil) {
            throw materialApprovedContractChangeError("policy_snapshot")
        }
        if hasAutonomy,
           let autonomy,
           autonomyContractDiffers(existing: existingPlan.autonomy, incoming: autonomy)
        {
            throw materialApprovedContractChangeError("autonomy")
        }
        if replaceWorkstreams {
            throw materialApprovedContractChangeError("replace_workstreams")
        }
        if replaceNodes, nodes != nil {
            throw materialApprovedContractChangeError("replace_nodes")
        }
        let existingWorkstreamsByID = Dictionary(uniqueKeysWithValues: existingPlan.workstreams.map { ($0.id, $0) })
        for workstream in workstreams ?? [] {
            guard let existing = existingWorkstreamsByID[workstream.id] else {
                throw materialApprovedContractChangeError("workstreams")
            }
            if workstreamContractDiffers(existing: existing, incoming: workstream) {
                throw materialApprovedContractChangeError("workstreams")
            }
        }
        let existingNodesByID = Dictionary(uniqueKeysWithValues: existingPlan.nodes.map { ($0.id, $0) })
        for node in nodes ?? [] {
            guard let existing = existingNodesByID[node.id] else {
                throw materialApprovedContractChangeError("nodes")
            }
            if nodeContractDiffers(existing: existing, incoming: node) {
                throw materialApprovedContractChangeError("nodes")
            }
        }
    }

    private func allowsPreApprovalPlanningNodeProgress(
        incoming: CoordinatorMissionPlanNode,
        existingPlan: CoordinatorMissionPlan?,
        effectiveWorkstreams: [CoordinatorMissionWorkstreamSummary]
    ) -> Bool {
        guard let existingPlan,
              existingPlan.approvalState == .awaitingApproval,
              existingPlan.status == .draft || existingPlan.status == .approved,
              let existing = existingPlan.nodes.first(where: { $0.id == incoming.id }),
              !nodeContractDiffers(existing: existing, incoming: incoming)
        else { return false }

        guard isEligiblePreApprovalPlanningNode(incoming, workstreams: effectiveWorkstreams) else {
            return false
        }
        if incoming.status.isTerminal {
            guard incoming.boundSessionID != nil || incoming.boundInteractionID != nil else { return false }
            guard let evidence = incoming.completionEvidence?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !evidence.isEmpty,
                  !CoordinatorFollowThroughState.isStaleCompletionEvidence(evidence)
            else { return false }
        }
        return true
    }

    private func isEligiblePreApprovalPlanningNode(
        _ node: CoordinatorMissionPlanNode,
        workstreams: [CoordinatorMissionWorkstreamSummary]
    ) -> Bool {
        switch node.executionPolicy {
        case .freshReadOnlyChild:
            guard let workflowName = node.workflowHint?.name else {
                return hasPreApprovalReadOnlyMetadata(for: node, workstreams: workstreams)
            }
            return isPreApprovalPlanningWorkflow(workflowName)
                && hasPreApprovalIsolatedWorktreeMetadata(for: node, workstreams: workstreams)
        case .planCritique:
            return node.workflowHint == nil
                && hasPreApprovalIsolatedWorktreeMetadata(for: node, workstreams: workstreams)
        case .coordinatorOnly, .steerPrimary, .freshSiblingOnSameWorktree, .freshWorktree, .askUser:
            return false
        }
    }

    private func isPreApprovalPlanningWorkflow(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "investigate" || normalized == "deep plan"
    }

    private func hasPreApprovalReadOnlyMetadata(
        for node: CoordinatorMissionPlanNode,
        workstreams: [CoordinatorMissionWorkstreamSummary]
    ) -> Bool {
        guard let workstream = workstreams.first(where: { $0.id == node.workstreamID }) else { return false }
        return workstream.worktreeStrategy.mode == .noneReadOnly
            || hasPreApprovalIsolatedWorktreeMetadata(for: node, workstreams: workstreams)
    }

    private func hasPreApprovalIsolatedWorktreeMetadata(
        for node: CoordinatorMissionPlanNode,
        workstreams: [CoordinatorMissionWorkstreamSummary]
    ) -> Bool {
        guard let workstream = workstreams.first(where: { $0.id == node.workstreamID }) else { return false }
        return workstream.worktreeStrategy.mode == .createIsolated
            && workstream.worktreeStrategy.baseRef?.isEmpty == false
    }

    private func autonomyContractDiffers(
        existing: [String: CoordinatorMissionAutonomyMode],
        incoming: [String: CoordinatorMissionAutonomyMode]
    ) -> Bool {
        incoming.contains { key, value in
            CoordinatorMissionPolicySnapshot.resolveAutonomy(existing[key], for: key) != CoordinatorMissionPolicySnapshot.resolveAutonomy(value, for: key)
        }
    }

    private func workstreamContractDiffers(
        existing: CoordinatorMissionWorkstreamSummary,
        incoming: CoordinatorMissionWorkstreamSummary
    ) -> Bool {
        !CoordinatorMissionMaterialContractComparator.workstreamsMatch(existing, incoming)
            || runtimeWorktreeBindingDiffers(existing: existing.worktreeID, incoming: incoming.worktreeID)
    }

    private func runtimeWorktreeBindingDiffers(existing: String?, incoming: String?) -> Bool {
        guard let existing else { return false }
        return incoming != existing
    }

    private func nodeContractDiffers(
        existing: CoordinatorMissionPlanNode,
        incoming: CoordinatorMissionPlanNode
    ) -> Bool {
        !CoordinatorMissionMaterialContractComparator.nodesMatch(existing, incoming)
    }

    private func materialApprovedContractChangeError(_ field: String) -> MCPError {
        MCPError.invalidParams("mission_plan cannot materially rewrite approved contract field \(field). Request a trusted user-visible plan revision that mints a new revision-bound approval checkpoint before changing objective, shape, workstreams, node contract, worktree strategy, policy/autonomy, or done criteria.")
    }

    private func validateCompletedMissionPlanNodesAreTerminal(
        status: CoordinatorMissionPlanStatus?,
        nodes: [CoordinatorMissionPlanNode]
    ) throws {
        guard status == .completed,
              let incompleteNode = nodes.first(where: { !$0.status.isTerminal })
        else { return }
        throw MCPError.invalidParams(
            "mission_plan status completed requires every node to be terminal; node \"\(incompleteNode.title)\" is \(incompleteNode.status.rawValue). Leave the Mission running until pending/running work completes, or mark the node skipped/cancelled with evidence before completing."
        )
    }

    private func validateChildAskAutoCompletionLedger(
        existingPlan: CoordinatorMissionPlan?,
        policySnapshot: CoordinatorMissionPolicySnapshot?,
        autonomy: [String: CoordinatorMissionAutonomyMode]?,
        nodes: [CoordinatorMissionPlanNode]?,
        decisions: [CoordinatorMissionDecisionRecord]?,
        evidence: [CoordinatorMissionEvidenceRecord]?
    ) throws {
        guard resolvedChildAskAutonomy(
            existingPlan: existingPlan,
            policySnapshot: policySnapshot,
            autonomy: autonomy
        ) == .auto else { return }
        let completedInteractionIDs = Set((nodes ?? []).compactMap { node -> UUID? in
            guard node.status == .completed,
                  node.boundInteractionID != nil
            else { return nil }
            return node.boundInteractionID
        })
        guard !completedInteractionIDs.isEmpty else { return }

        let effectiveDecisions = (existingPlan?.decisions ?? []) + (decisions ?? [])
        let effectiveEvidence = (existingPlan?.evidence ?? []) + (evidence ?? [])
        for interactionID in completedInteractionIDs {
            let hasChildAskDecision = effectiveDecisions.contains { decision in
                decision.resolvedAutonomyClass == .childAsk
                    && decision.interactionID == interactionID
            }
            let hasEvidence = effectiveEvidence.contains { record in
                record.interactionID == interactionID
            }
            guard hasChildAskDecision, hasEvidence else {
                throw MCPError.invalidParams("childAsk:auto completed nodes bound to child interactions require a childAsk decision and evidence record for the same interaction_id before completion.")
            }
        }
    }

    private func resolvedChildAskAutonomy(
        existingPlan: CoordinatorMissionPlan?,
        policySnapshot: CoordinatorMissionPolicySnapshot?,
        autonomy: [String: CoordinatorMissionAutonomyMode]?
    ) -> CoordinatorMissionAutonomyMode {
        let childAskKey = CoordinatorMissionDecisionClass.childAsk.rawValue
        if let autonomyValue = autonomy?[childAskKey] {
            return CoordinatorMissionPolicySnapshot.resolveAutonomy(autonomyValue, for: childAskKey)
        }
        if let policyValue = policySnapshot?.autonomy[childAskKey] {
            return CoordinatorMissionPolicySnapshot.resolveAutonomy(policyValue, for: childAskKey)
        }
        if let existingPlan {
            return existingPlan.resolvedAutonomy(for: .childAsk)
        }
        return CoordinatorMissionPolicySnapshot.resolveAutonomy(nil, for: childAskKey)
    }

    private func missionPlanStatusRequiresApproval(_ status: CoordinatorMissionPlanStatus) -> Bool {
        switch status {
        case .running, .blocked, .completed, .stopped:
            true
        case .draft, .approved:
            false
        }
    }

    private func missionPlanNodeStatusRequiresApproval(_ status: CoordinatorMissionPlanNodeStatus) -> Bool {
        switch status {
        case .running, .blocked, .completed, .skipped, .cancelled:
            true
        case .pending:
            false
        }
    }

    private func parseCheckpointContinuationAction(_ args: [String: Value]) throws -> CoordinatorModeViewModel.ContinuationAction? {
        guard let raw = normalizedString(
            args["checkpoint_action"]
                ?? args["checkpointAction"]
                ?? args["checkpoint_action_id"]
                ?? args["checkpointActionID"]
        ) else { return nil }
        guard let action = CoordinatorModeViewModel.ContinuationAction(checkpointActionID: raw) else {
            throw MCPError.invalidParams("checkpoint_action must be one of: proceed, gather_evidence, deepen_plan, independent_critique, start_smaller, stop.")
        }
        return action
    }

    private func parseExpectedCheckpointInstanceID(_ args: [String: Value]) throws -> String? {
        normalizedString(
            args["expected_checkpoint_instance_id"]
                ?? args["expectedCheckpointInstanceID"]
                ?? args["checkpoint_instance_id"]
                ?? args["checkpointInstanceID"]
        )
    }

    private func checkpointInstanceMismatchMessage(
        expected: String?,
        snapshot: CoordinatorModeSnapshot
    ) -> String? {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID,
              let plan = snapshot.coordinatorRail.missionPlan,
              plan.approvalState == .awaitingApproval
        else {
            return "Checkpoint submit rejected because no plan approval checkpoint is currently pending. Refresh coordinator_chat op=mission_status before resubmitting."
        }
        let current = planApprovalCheckpointInstanceID(
            coordinatorSessionID: coordinatorSessionID,
            revision: plan.revision
        )
        guard let expected else {
            return "Checkpoint submit rejected: expected_checkpoint_instance_id is required. Refresh coordinator_chat op=mission_status and resubmit with expected_checkpoint_instance_id=\(current)."
        }
        guard expected != current else { return nil }
        return "Stale checkpoint submit rejected: expected checkpoint_instance_id \(expected), but current checkpoint_instance_id is \(current). Refresh coordinator_chat op=mission_status and resubmit with expected_checkpoint_instance_id=\(current)."
    }

    private func shouldValidateCurrentCheckpointSubmit(for action: CoordinatorModeViewModel.ContinuationAction) -> Bool {
        // Stale-check consent-granting actions only. Stop withdraws consent and must remain
        // available even if a plan revision races the user's click.
        action != .stopHere
    }

    private func planApprovalCheckpointInstanceID(coordinatorSessionID: UUID, revision: Int) -> String {
        "coordinator:\(coordinatorSessionID.uuidString):plan-approval:r\(revision)"
    }

    private func parseMissionPredecessorUpdate(_ args: [String: Value]) throws -> (
        hasPredecessorContext: Bool,
        update: CoordinatorMissionPlanUpdate
    ) {
        let hasPredecessorID = args.keys.contains("predecessor_mission_id") || args.keys.contains("predecessorMissionID")
        let hasPredecessorTitle = args.keys.contains("predecessor_title") || args.keys.contains("predecessorTitle")
        let hasPredecessorSummary = args.keys.contains("predecessor_summary") || args.keys.contains("predecessorSummary")
        let predecessorMissionID = hasPredecessorID
            ? try optionalUUID(args["predecessor_mission_id"] ?? args["predecessorMissionID"], name: "predecessor_mission_id")
            : nil
        let predecessorTitle = hasPredecessorTitle
            ? normalizedString(args["predecessor_title"] ?? args["predecessorTitle"])
            : nil
        let predecessorSummary = hasPredecessorSummary
            ? normalizedString(args["predecessor_summary"] ?? args["predecessorSummary"])
            : nil
        return (
            hasPredecessorID || hasPredecessorTitle || hasPredecessorSummary,
            CoordinatorMissionPlanUpdate(
                predecessorMissionID: predecessorMissionID,
                predecessorTitle: predecessorTitle,
                predecessorSummary: predecessorSummary
            )
        )
    }

    private func parseMissionShapeSummary(_ value: Value?) throws -> CoordinatorMissionShapeSummary? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("shape_summary must be an object.")
        }
        return try CoordinatorMissionShapeSummary(
            id: AgentMCPToolHelpers.requireNonEmptyString(object["id"], name: "shape_summary.id"),
            displayName: AgentMCPToolHelpers.requireNonEmptyString(object["display_name"] ?? object["displayName"], name: "shape_summary.display_name"),
            reason: normalizedString(object["reason"]),
            namedClose: normalizedString(object["named_close"] ?? object["namedClose"])
        )
    }

    private func parseMissionPolicySnapshot(_ value: Value?) throws -> CoordinatorMissionPolicySnapshot? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("policy_snapshot must be an object.")
        }
        let paceRaw = try AgentMCPToolHelpers.requireNonEmptyString(object["default_pace"] ?? object["defaultPace"], name: "policy_snapshot.default_pace")
        guard let pace = CoordinatorMissionPolicyPace(rawValue: paceRaw) else {
            throw MCPError.invalidParams("policy_snapshot.default_pace must be one of: \(CoordinatorMissionPolicyPace.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let autonomy = try object.keys.contains("autonomy")
            ? parseMissionAutonomyMap(object["autonomy"], name: "policy_snapshot.autonomy")
            : CoordinatorMissionPolicySnapshot.defaultAutonomy
        return try CoordinatorMissionPolicySnapshot(
            id: AgentMCPToolHelpers.requireNonEmptyString(object["id"], name: "policy_snapshot.id"),
            name: AgentMCPToolHelpers.requireNonEmptyString(object["name"], name: "policy_snapshot.name"),
            defaultPace: pace,
            autonomy: autonomy,
            maxConcurrent: parseOptionalPositiveInt(
                object["max_concurrent"] ?? object["maxConcurrent"],
                name: "policy_snapshot.max_concurrent"
            ) ?? CoordinatorMissionPolicySnapshot.defaultMaxConcurrent,
            definitionOfDone: normalizedString(object["definition_of_done"] ?? object["definitionOfDone"]),
            standingGuidance: normalizedString(object["standing_guidance"] ?? object["standingGuidance"]),
            pinnedSkillIDs: parseOptionalStringArray(
                object["pinned_skill_ids"] ?? object["pinnedSkillIDs"],
                name: "policy_snapshot.pinned_skill_ids"
            ) ?? [],
            pinnedContextIDs: parseOptionalStringArray(
                object["pinned_context_ids"] ?? object["pinnedContextIDs"],
                name: "policy_snapshot.pinned_context_ids"
            ) ?? []
        )
    }

    private func parseMissionPace(_ value: Value?) throws -> CoordinatorMissionPolicyPace {
        let raw = try AgentMCPToolHelpers.requireNonEmptyString(value, name: "pace")
            .lowercased()
        guard let pace = CoordinatorMissionPolicyPace(rawValue: raw) else {
            throw MCPError.invalidParams("pace must be one of: \(CoordinatorMissionPolicyPace.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return pace
    }

    private func parseMissionAutonomyMode(_ value: Value?) throws -> CoordinatorMissionAutonomyMode {
        let raw = try AgentMCPToolHelpers.requireNonEmptyString(value, name: "mode")
            .lowercased()
        guard let mode = CoordinatorMissionAutonomyMode(rawValue: raw) else {
            throw MCPError.invalidParams("mode must be one of: \(CoordinatorMissionAutonomyMode.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return mode
    }

    private func parseMissionAutonomyClassKey(_ value: Value?) throws -> String {
        let raw = try AgentMCPToolHelpers.requireNonEmptyString(value, name: "autonomy_class")
        if let exact = CoordinatorMissionAutonomyClasses.definition(for: raw) {
            return exact.key
        }
        if let folded = CoordinatorMissionAutonomyClasses.all.first(where: { $0.key.lowercased() == raw.lowercased() }) {
            return folded.key
        }
        if raw.lowercased() == "child_ask" || raw.lowercased() == "child-ask" {
            return CoordinatorMissionAutonomyClasses.childAsk.key
        }
        throw MCPError.invalidParams("autonomy_class must be one of: \(CoordinatorMissionAutonomyClasses.all.map(\.key).joined(separator: ", ")).")
    }

    private func parseMissionAutonomyMap(_ value: Value?, name: String) throws -> [String: CoordinatorMissionAutonomyMode] {
        guard let object = value?.objectValue else {
            throw MCPError.invalidParams("\(name) must be an object mapping decision class strings to ask/auto.")
        }
        var autonomy: [String: CoordinatorMissionAutonomyMode] = [:]
        for key in object.keys.sorted() {
            let rawMode = try AgentMCPToolHelpers.requireNonEmptyString(object[key], name: "\(name).\(key)")
            guard let mode = CoordinatorMissionAutonomyMode(rawValue: rawMode) else {
                throw MCPError.invalidParams("\(name).\(key) must be one of: \(CoordinatorMissionAutonomyMode.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            autonomy[key] = mode
        }
        return autonomy
    }

    private func parseMissionWorkstreams(
        _ value: Value?,
        existingPlan: CoordinatorMissionPlan?
    ) throws -> [CoordinatorMissionWorkstreamSummary] {
        guard let array = value?.arrayValue else {
            throw MCPError.invalidParams("workstreams must be an array.")
        }
        let existingByTitle = Dictionary(
            (existingPlan?.workstreams ?? []).map { ($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        return try array.map { element in
            guard let object = element.objectValue else {
                throw MCPError.invalidParams("Each workstream must be an object.")
            }
            let title = try AgentMCPToolHelpers.requireNonEmptyString(object["title"], name: "workstreams[].title")
            let id = try optionalUUID(object["id"], name: "workstreams[].id")
                ?? existingByTitle[title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
                ?? UUID()
            let existing = existingPlan?.workstreams.first(where: { $0.id == id })
            let purpose = try parseMissionWorkstreamPurpose(object, existing: existing)
            let policy = try parseMissionWorkstreamPolicy(object, existing: existing)
            let worktreeStrategy = try parseMissionWorkstreamWorktreeStrategy(object, existing: existing)
            return try CoordinatorMissionWorkstreamSummary(
                id: id,
                title: title,
                purpose: purpose,
                role: object.keys.contains("role") ? normalizedString(object["role"]) : existing?.role,
                defaultPolicy: policy,
                worktreeStrategy: worktreeStrategy,
                primarySessionID: parseMissionWorkstreamPrimarySessionID(object, existing: existing),
                relatedSessionIDs: parseMissionWorkstreamRelatedSessionIDs(object, existing: existing)
            )
        }
    }

    private func parseMissionWorkstreamPurpose(
        _ object: [String: Value],
        existing: CoordinatorMissionWorkstreamSummary?
    ) throws -> String {
        if let purpose = normalizedString(object["purpose"]) {
            return purpose
        }
        if let purpose = existing?.purpose {
            return purpose
        }
        throw MCPError.invalidParams("workstreams[].purpose is required for new workstreams.")
    }

    private func parseMissionWorkstreamPolicy(
        _ object: [String: Value],
        existing: CoordinatorMissionWorkstreamSummary?
    ) throws -> CoordinatorMissionExecutionPolicy {
        guard let rawValue = object["default_policy"] ?? object["defaultPolicy"] else {
            if let policy = existing?.defaultPolicy {
                return policy
            }
            throw MCPError.invalidParams("workstreams[].default_policy is required for new workstreams.")
        }
        let policyRaw = try AgentMCPToolHelpers.requireNonEmptyString(rawValue, name: "workstreams[].default_policy")
        guard let policy = CoordinatorMissionExecutionPolicy(rawValue: policyRaw) else {
            throw MCPError.invalidParams("workstreams[].default_policy must be one of: \(CoordinatorMissionExecutionPolicy.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return policy
    }

    private func parseMissionWorkstreamWorktreeStrategy(
        _ object: [String: Value],
        existing: CoordinatorMissionWorkstreamSummary?
    ) throws -> CoordinatorMissionWorktreeStrategy {
        let value = object["worktree_strategy"] ?? object["worktreeStrategy"] ?? object["worktree_plan"] ?? object["worktreePlan"]
        guard let value else {
            if let strategy = existing?.worktreeStrategy {
                return strategy
            }
            throw MCPError.invalidParams("workstreams[].worktree_strategy is required for new workstreams.")
        }
        return try parseWorktreeStrategy(value, name: "workstreams[].worktree_strategy", existing: existing?.worktreeStrategy)
    }

    private func parseMissionWorkstreamPrimarySessionID(
        _ object: [String: Value],
        existing: CoordinatorMissionWorkstreamSummary?
    ) throws -> UUID? {
        guard object.keys.contains("primary_session_id") || object.keys.contains("primarySessionID") else {
            return existing?.primarySessionID
        }
        return try optionalUUID(object["primary_session_id"] ?? object["primarySessionID"], name: "workstreams[].primary_session_id")
    }

    private func parseMissionWorkstreamRelatedSessionIDs(
        _ object: [String: Value],
        existing: CoordinatorMissionWorkstreamSummary?
    ) throws -> [UUID] {
        guard object.keys.contains("related_session_ids") || object.keys.contains("relatedSessionIDs") else {
            return existing?.relatedSessionIDs ?? []
        }
        return try optionalUUIDArray(object["related_session_ids"] ?? object["relatedSessionIDs"], name: "workstreams[].related_session_ids") ?? []
    }

    private func parseWorktreeStrategy(
        _ value: Value?,
        name: String,
        existing: CoordinatorMissionWorktreeStrategy?
    ) throws -> CoordinatorMissionWorktreeStrategy {
        guard let object = value?.objectValue else {
            throw MCPError.invalidParams("\(name) must be an object with mode.")
        }
        let modeRaw = try AgentMCPToolHelpers.requireNonEmptyString(object["mode"], name: "\(name).mode")
        guard let mode = CoordinatorMissionWorktreeMode(rawValue: modeRaw) else {
            throw MCPError.invalidParams("\(name).mode must be one of: \(CoordinatorMissionWorktreeMode.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return CoordinatorMissionWorktreeStrategy(
            mode: mode,
            worktreeID: strategyString(
                object,
                snakeKey: "worktree_id",
                camelKey: "worktreeID",
                fallback: existing?.worktreeID
            ),
            baseRef: strategyString(
                object,
                snakeKey: "base_ref",
                camelKey: "baseRef",
                alternateSnakeKey: "worktree_base_ref",
                alternateCamelKey: "worktreeBaseRef",
                fallback: existing?.baseRef
            ),
            baseReason: strategyString(
                object,
                snakeKey: "base_reason",
                camelKey: "baseReason",
                alternateSnakeKey: "worktree_base_reason",
                alternateCamelKey: "worktreeBaseReason",
                fallback: existing?.baseReason
            ),
            reason: object.keys.contains("reason") ? normalizedString(object["reason"]) : existing?.reason
        )
    }

    private func strategyString(
        _ object: [String: Value],
        snakeKey: String,
        camelKey: String,
        alternateSnakeKey: String? = nil,
        alternateCamelKey: String? = nil,
        fallback: String?
    ) -> String? {
        let keys = [snakeKey, camelKey, alternateSnakeKey, alternateCamelKey].compactMap(\.self)
        guard keys.contains(where: { object.keys.contains($0) }) else { return fallback }
        for key in keys {
            if let parsed = normalizedString(object[key]) {
                return parsed
            }
        }
        return nil
    }

    private func parseMissionPlanNodes(
        _ value: Value?,
        workstreams: [CoordinatorMissionWorkstreamSummary],
        existingPlan: CoordinatorMissionPlan?
    ) throws -> [CoordinatorMissionPlanNode] {
        guard let array = value?.arrayValue else {
            throw MCPError.invalidParams("nodes must be an array.")
        }
        let existingByTitle = Dictionary(
            (existingPlan?.nodes ?? []).map { ($0.title.normalizedMissionPlanKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingByID = Dictionary(
            (existingPlan?.nodes ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return try array.map { element in
            guard let object = element.objectValue else {
                throw MCPError.invalidParams("Each node must be an object.")
            }
            let title = try AgentMCPToolHelpers.requireNonEmptyString(object["title"], name: "nodes[].title")
            let explicitID = try optionalUUID(object["id"], name: "nodes[].id")
            let existingNode = explicitID.flatMap { existingByID[$0] } ?? existingByTitle[title.normalizedMissionPlanKey]
            let id = explicitID
                ?? existingNode?.id
                ?? UUID()
            let workstreamID = try parseMissionPlanNodeWorkstreamID(
                object,
                workstreams: workstreams,
                existing: existingNode
            )
            let policy = try parseMissionPlanNodePolicy(object, existing: existingNode)
            let status = try parseOptionalMissionPlanNodeStatus(object["status"]) ?? existingNode?.status ?? .pending
            let node = try CoordinatorMissionPlanNode(
                id: id,
                title: title,
                detail: object.keys.contains("detail") ? normalizedString(object["detail"]) : existingNode?.detail,
                workflowHint: parseMissionPlanNodeWorkflowHint(object, existing: existingNode?.workflowHint),
                completionEvidence: parseMissionPlanNodeCompletionEvidence(object, existing: existingNode?.completionEvidence),
                doneCriteria: parseMissionPlanNodeDoneCriteria(object, existing: existingNode?.doneCriteria),
                workstreamID: workstreamID,
                dependsOn: parseMissionPlanNodeDependencies(object, existing: existingNode),
                role: object.keys.contains("role") ? normalizedString(object["role"]) : existingNode?.role,
                executionPolicy: policy,
                status: status,
                boundSessionID: parseMissionPlanNodeBoundSessionID(object, existing: existingNode),
                boundInteractionID: parseMissionPlanNodeBoundInteractionID(object, existing: existingNode)
            )
            try validateMissionPlanNodeRunningBinding(node)
            try validateCompletedMissionPlanNodeEvidence(node)
            return node
        }
    }

    private func validateMissionPlanNodeRunningBinding(_ node: CoordinatorMissionPlanNode) throws {
        guard node.status == .running else { return }
        switch node.executionPolicy {
        case .coordinatorOnly:
            return
        case .askUser:
            guard node.boundInteractionID != nil else {
                throw MCPError.invalidParams("nodes[].status running with execution_policy:\"ask_user\" requires bound_interaction_id. Keep the node pending until a user interaction is created.")
            }
        case .freshReadOnlyChild, .steerPrimary, .freshSiblingOnSameWorktree, .freshWorktree, .planCritique:
            guard node.boundSessionID != nil else {
                throw MCPError.invalidParams("nodes[].status running with execution_policy:\"\(node.executionPolicy.rawValue)\" requires bound_session_id returned by agent_explore.start or agent_run.start. Record routing_decisions while the node is pending, then bind the session after launch.")
            }
        }
    }

    private func validateCompletedMissionPlanNodeEvidence(_ node: CoordinatorMissionPlanNode) throws {
        guard node.status == .completed else { return }
        let evidence = (node.completionEvidence ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty else {
            throw MCPError.invalidParams("nodes[].completion_evidence is required when nodes[].status is completed.")
        }
        if CoordinatorFollowThroughState.isStaleCompletionEvidence(evidence) {
            throw MCPError.invalidParams("nodes[].completion_evidence for completed nodes must describe result evidence, not stale waiting/bound state.")
        }
    }

    private func parseMissionPlanNodePolicy(
        _ object: [String: Value],
        existing: CoordinatorMissionPlanNode?
    ) throws -> CoordinatorMissionExecutionPolicy {
        guard let rawValue = object["execution_policy"] ?? object["executionPolicy"] else {
            if let policy = existing?.executionPolicy {
                return policy
            }
            throw MCPError.invalidParams("nodes[].execution_policy is required for new nodes.")
        }
        let policyRaw = try AgentMCPToolHelpers.requireNonEmptyString(rawValue, name: "nodes[].execution_policy")
        guard let policy = CoordinatorMissionExecutionPolicy(rawValue: policyRaw) else {
            throw MCPError.invalidParams("nodes[].execution_policy must be one of: \(CoordinatorMissionExecutionPolicy.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return policy
    }

    private func parseMissionPlanNodeDependencies(
        _ object: [String: Value],
        existing: CoordinatorMissionPlanNode?
    ) throws -> [UUID] {
        guard object.keys.contains("depends_on") || object.keys.contains("dependsOn") else {
            return existing?.dependsOn ?? []
        }
        return try optionalUUIDArray(object["depends_on"] ?? object["dependsOn"], name: "nodes[].depends_on") ?? []
    }

    private func parseMissionPlanNodeBoundSessionID(
        _ object: [String: Value],
        existing: CoordinatorMissionPlanNode?
    ) throws -> UUID? {
        guard object.keys.contains("bound_session_id") || object.keys.contains("boundSessionID") else {
            return existing?.boundSessionID
        }
        return try optionalUUID(object["bound_session_id"] ?? object["boundSessionID"], name: "nodes[].bound_session_id")
    }

    private func parseMissionPlanNodeBoundInteractionID(
        _ object: [String: Value],
        existing: CoordinatorMissionPlanNode?
    ) throws -> UUID? {
        guard object.keys.contains("bound_interaction_id") || object.keys.contains("boundInteractionID") else {
            return existing?.boundInteractionID
        }
        return try optionalUUID(object["bound_interaction_id"] ?? object["boundInteractionID"], name: "nodes[].bound_interaction_id")
    }

    private func parseMissionPlanNodeWorkflowHint(
        _ object: [String: Value],
        existing: CoordinatorMissionPlanNodeWorkflowHint?
    ) throws -> CoordinatorMissionPlanNodeWorkflowHint? {
        let hasWorkflowField = object.keys.contains("workflow")
            || object.keys.contains("workflow_hint")
            || object.keys.contains("workflowHint")
            || object.keys.contains("workflow_id")
            || object.keys.contains("workflowID")
            || object.keys.contains("workflow_name")
            || object.keys.contains("workflowName")
        guard hasWorkflowField else { return existing }

        let nestedValue = object["workflow"] ?? object["workflow_hint"] ?? object["workflowHint"]
        if nestedValue == .null {
            return nil
        }
        let nested = nestedValue?.objectValue
        let id = normalizedString(nested?["id"] ?? object["workflow_id"] ?? object["workflowID"])
        let name = normalizedString(
            nested?["name"]
                ?? nested?["display_name"]
                ?? nested?["displayName"]
                ?? object["workflow_name"]
                ?? object["workflowName"]
        ) ?? existing?.name
        guard let name else {
            throw MCPError.invalidParams("nodes[].workflow_name or nodes[].workflow.name is required when workflow metadata is provided.")
        }
        return CoordinatorMissionPlanNodeWorkflowHint(
            id: id ?? existing?.id,
            name: name,
            iconName: normalizedString(nested?["icon_name"] ?? nested?["iconName"] ?? object["workflow_icon_name"] ?? object["workflowIconName"])
                ?? existing?.iconName,
            accentColorHex: normalizedString(nested?["accent_color_hex"] ?? nested?["accentColorHex"] ?? object["workflow_accent_color_hex"] ?? object["workflowAccentColorHex"])
                ?? existing?.accentColorHex
        )
    }

    private func parseMissionPlanNodeCompletionEvidence(
        _ object: [String: Value],
        existing: String?
    ) -> String? {
        let hasEvidenceField = object.keys.contains("completion_evidence") || object.keys.contains("completionEvidence")
        guard hasEvidenceField else { return existing }
        return normalizedString(object["completion_evidence"] ?? object["completionEvidence"])
    }

    private func parseMissionPlanNodeDoneCriteria(
        _ object: [String: Value],
        existing: String?
    ) -> String? {
        let hasDoneCriteriaField = object.keys.contains("done_criteria") || object.keys.contains("doneCriteria")
        guard hasDoneCriteriaField else { return existing }
        return normalizedString(object["done_criteria"] ?? object["doneCriteria"])
    }

    private func parseMissionPlanNodeWorkstreamID(
        _ object: [String: Value],
        workstreams: [CoordinatorMissionWorkstreamSummary],
        existing: CoordinatorMissionPlanNode?
    ) throws -> UUID {
        if let workstreamID = try optionalUUID(object["workstream_id"] ?? object["workstreamID"], name: "nodes[].workstream_id") {
            return workstreamID
        }
        if let title = normalizedString(object["workstream_title"] ?? object["workstreamTitle"]) {
            if let workstream = workstreams.first(where: { $0.title.normalizedMissionPlanKey == title.normalizedMissionPlanKey }) {
                return workstream.id
            }
            throw MCPError.invalidParams("nodes[].workstream_title must match a declared workstream title.")
        }
        if let workstreamID = existing?.workstreamID {
            return workstreamID
        }
        throw MCPError.invalidParams("nodes[].workstream_id or nodes[].workstream_title is required for new nodes.")
    }

    private func parseMissionDecisionRecords(
        _ value: Value?,
        nodes: [CoordinatorMissionPlanNode],
        workstreams: [CoordinatorMissionWorkstreamSummary]
    ) throws -> [CoordinatorMissionDecisionRecord] {
        guard let array = value?.arrayValue else {
            throw MCPError.invalidParams("decisions must be an array.")
        }
        return try array.map { element in
            guard let object = element.objectValue else {
                throw MCPError.invalidParams("Each decisions entry must be an object.")
            }
            let actorRaw = try AgentMCPToolHelpers.requireNonEmptyString(object["actor"], name: "decisions[].actor")
            guard let actor = CoordinatorMissionDecisionActor(rawValue: actorRaw) else {
                throw MCPError.invalidParams("decisions[].actor must be one of: \(CoordinatorMissionDecisionActor.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            guard actor == .director else {
                throw MCPError.invalidParams("mission_plan decisions must use actor \"director\". User decisions are recorded by the app/MCP submit path.")
            }
            guard let id = try optionalUUID(object["id"], name: "decisions[].id") else {
                throw MCPError.invalidParams("decisions[].id is required so retries dedupe by ID.")
            }
            return try CoordinatorMissionDecisionRecord(
                id: id,
                decisionClass: AgentMCPToolHelpers.requireNonEmptyString(object["decision_class"] ?? object["decisionClass"], name: "decisions[].decision_class"),
                actor: actor,
                label: AgentMCPToolHelpers.requireNonEmptyString(object["label"], name: "decisions[].label"),
                reason: normalizedString(object["reason"]),
                timestamp: parseOptionalDate(object["timestamp"], name: "decisions[].timestamp") ?? Date(),
                nodeID: parseLedgerNodeID(object, nodes: nodes, fieldPrefix: "decisions[]"),
                workstreamID: parseLedgerWorkstreamID(object, workstreams: workstreams, fieldPrefix: "decisions[]"),
                sessionID: optionalUUID(object["session_id"] ?? object["sessionID"], name: "decisions[].session_id"),
                interactionID: optionalUUID(object["interaction_id"] ?? object["interactionID"], name: "decisions[].interaction_id"),
                checkpointID: normalizedString(object["checkpoint_id"] ?? object["checkpointID"]),
                checkpointInstanceID: normalizedString(object["checkpoint_instance_id"] ?? object["checkpointInstanceID"]),
                overruledDecisionID: optionalUUID(object["overruled_decision_id"] ?? object["overruledDecisionID"], name: "decisions[].overruled_decision_id"),
                overruleReason: normalizedString(object["overrule_reason"] ?? object["overruleReason"]),
                correctionReason: normalizedString(object["correction_reason"] ?? object["correctionReason"]),
                correctionSteerText: normalizedString(object["correction_steer_text"] ?? object["correctionSteerText"])
            )
        }
    }

    private func parseMissionEvidenceRecords(
        _ value: Value?,
        nodes: [CoordinatorMissionPlanNode],
        workstreams: [CoordinatorMissionWorkstreamSummary]
    ) throws -> [CoordinatorMissionEvidenceRecord] {
        guard let array = value?.arrayValue else {
            throw MCPError.invalidParams("evidence must be an array.")
        }
        return try array.map { element in
            guard let object = element.objectValue else {
                throw MCPError.invalidParams("Each evidence entry must be an object.")
            }
            let verdictRaw = try AgentMCPToolHelpers.requireNonEmptyString(object["verdict"], name: "evidence[].verdict")
            guard let verdict = CoordinatorMissionEvidenceVerdict(rawValue: verdictRaw) else {
                throw MCPError.invalidParams("evidence[].verdict must be one of: \(CoordinatorMissionEvidenceVerdict.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            guard let id = try optionalUUID(object["id"], name: "evidence[].id") else {
                throw MCPError.invalidParams("evidence[].id is required so retries dedupe by ID.")
            }
            return try CoordinatorMissionEvidenceRecord(
                id: id,
                verdict: verdict,
                summary: AgentMCPToolHelpers.requireNonEmptyString(object["summary"], name: "evidence[].summary"),
                timestamp: parseOptionalDate(object["timestamp"], name: "evidence[].timestamp") ?? Date(),
                nodeID: parseLedgerNodeID(object, nodes: nodes, fieldPrefix: "evidence[]"),
                workstreamID: parseLedgerWorkstreamID(object, workstreams: workstreams, fieldPrefix: "evidence[]"),
                sessionID: optionalUUID(object["session_id"] ?? object["sessionID"], name: "evidence[].session_id"),
                interactionID: optionalUUID(object["interaction_id"] ?? object["interactionID"], name: "evidence[].interaction_id"),
                decisionID: optionalUUID(object["decision_id"] ?? object["decisionID"], name: "evidence[].decision_id"),
                source: parseMissionEvidenceSource(
                    object["source"] ?? object["evidence_source"] ?? object["evidenceSource"],
                    nodes: nodes,
                    fieldPrefix: "evidence[].source"
                ),
                judgmentBundle: parseMissionJudgmentBundle(
                    object["judgment_bundle"] ?? object["judgmentBundle"] ?? object["judgment"]
                )
            )
        }
    }

    private func parseMissionEvidenceSource(
        _ value: Value?,
        nodes: [CoordinatorMissionPlanNode],
        fieldPrefix: String
    ) throws -> CoordinatorMissionEvidenceSource? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("\(fieldPrefix) must be an object.")
        }
        let operation = try parseOptionalMissionRoutingOperation(object["operation"], name: "\(fieldPrefix).operation")
        return try CoordinatorMissionEvidenceSource(
            kind: AgentMCPToolHelpers.requireNonEmptyString(object["kind"], name: "\(fieldPrefix).kind"),
            operation: operation,
            routingDecisionID: optionalUUID(object["routing_decision_id"] ?? object["routingDecisionID"], name: "\(fieldPrefix).routing_decision_id"),
            nodeID: parseLedgerNodeID(object, nodes: nodes, fieldPrefix: fieldPrefix),
            sessionID: optionalUUID(object["session_id"] ?? object["sessionID"], name: "\(fieldPrefix).session_id"),
            interactionID: optionalUUID(object["interaction_id"] ?? object["interactionID"], name: "\(fieldPrefix).interaction_id"),
            answerID: normalizedString(object["answer_id"] ?? object["answerID"]),
            summary: normalizedString(object["summary"])
        )
    }

    private func parseMissionJudgmentBundle(_ value: Value?) throws -> CoordinatorMissionJudgmentBundle? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("judgment_bundle must be an object.")
        }
        return try CoordinatorMissionJudgmentBundle(
            doneCriteria: normalizedString(object["done_criteria"] ?? object["doneCriteria"]),
            structuredEvidence: normalizedString(object["structured_evidence"] ?? object["structuredEvidence"]),
            diffStats: parseMissionDiffStats(object["diff_stats"] ?? object["diffStats"]),
            probeAnswer: parseMissionProbeAnswerSummary(object["probe_answer"] ?? object["probeAnswer"]),
            transcriptFraming: normalizedString(object["transcript_framing"] ?? object["transcriptFraming"])
                ?? CoordinatorMissionJudgmentBundle.notTranscriptFraming
        )
    }

    private func parseMissionDiffStats(_ value: Value?) throws -> CoordinatorMissionDiffStats? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("judgment_bundle.diff_stats must be an object.")
        }
        return try CoordinatorMissionDiffStats(
            filesChanged: parseOptionalNonNegativeInt(object["files_changed"] ?? object["filesChanged"], name: "judgment_bundle.diff_stats.files_changed"),
            insertions: parseOptionalNonNegativeInt(object["insertions"], name: "judgment_bundle.diff_stats.insertions"),
            deletions: parseOptionalNonNegativeInt(object["deletions"], name: "judgment_bundle.diff_stats.deletions"),
            summary: normalizedString(object["summary"])
        )
    }

    private func parseMissionProbeAnswerSummary(_ value: Value?) throws -> CoordinatorMissionProbeAnswerSummary? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("judgment_bundle.probe_answer must be an object.")
        }
        return try CoordinatorMissionProbeAnswerSummary(
            answerID: normalizedString(object["answer_id"] ?? object["answerID"]),
            source: normalizedString(object["source"]),
            answer: normalizedString(object["answer"]),
            sessionID: optionalUUID(object["session_id"] ?? object["sessionID"], name: "judgment_bundle.probe_answer.session_id"),
            interactionID: optionalUUID(object["interaction_id"] ?? object["interactionID"], name: "judgment_bundle.probe_answer.interaction_id"),
            routingDecisionID: optionalUUID(object["routing_decision_id"] ?? object["routingDecisionID"], name: "judgment_bundle.probe_answer.routing_decision_id")
        )
    }

    private func parseLedgerNodeID(
        _ object: [String: Value],
        nodes: [CoordinatorMissionPlanNode],
        fieldPrefix: String
    ) throws -> UUID? {
        if let nodeID = try optionalUUID(object["node_id"] ?? object["nodeID"], name: "\(fieldPrefix).node_id") {
            return nodeID
        }
        guard let title = normalizedString(object["node_title"] ?? object["nodeTitle"]) else { return nil }
        guard let node = nodes.first(where: { $0.title.normalizedMissionPlanKey == title.normalizedMissionPlanKey }) else {
            throw MCPError.invalidParams("\(fieldPrefix).node_title must match a declared node title.")
        }
        return node.id
    }

    private func parseLedgerWorkstreamID(
        _ object: [String: Value],
        workstreams: [CoordinatorMissionWorkstreamSummary],
        fieldPrefix: String
    ) throws -> UUID? {
        if let workstreamID = try optionalUUID(object["workstream_id"] ?? object["workstreamID"], name: "\(fieldPrefix).workstream_id") {
            return workstreamID
        }
        guard let title = normalizedString(object["workstream_title"] ?? object["workstreamTitle"]) else { return nil }
        guard let workstream = workstreams.first(where: { $0.title.normalizedMissionPlanKey == title.normalizedMissionPlanKey }) else {
            throw MCPError.invalidParams("\(fieldPrefix).workstream_title must match a declared workstream title.")
        }
        return workstream.id
    }

    private func parseMissionPlanEvents(
        _ value: Value?,
        nodes: [CoordinatorMissionPlanNode]
    ) throws -> [CoordinatorMissionPlanEvent] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw MCPError.invalidParams("events must be an array.")
        }
        return try array.map { element in
            guard let object = element.objectValue else {
                throw MCPError.invalidParams("Each event must be an object.")
            }
            let kindRaw = try AgentMCPToolHelpers.requireNonEmptyString(object["kind"], name: "events[].kind")
            guard let kind = CoordinatorMissionPlanEventKind(rawValue: kindRaw) else {
                throw MCPError.invalidParams("events[].kind must be one of: \(CoordinatorMissionPlanEventKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let explicitNodeID = try optionalUUID(object["node_id"] ?? object["nodeID"], name: "events[].node_id")
            let nodeID = try explicitNodeID ?? parseMissionPlanEventNodeTitle(object, nodes: nodes)
            return try CoordinatorMissionPlanEvent(
                id: optionalUUID(object["id"], name: "events[].id") ?? UUID(),
                kind: kind,
                nodeID: nodeID,
                sessionID: optionalUUID(object["session_id"] ?? object["sessionID"], name: "events[].session_id"),
                interactionID: optionalUUID(object["interaction_id"] ?? object["interactionID"], name: "events[].interaction_id"),
                timestamp: parseOptionalDate(object["timestamp"], name: "events[].timestamp") ?? Date(),
                summary: normalizedString(object["summary"])
            )
        }
    }

    private func parseMissionPlanEventNodeTitle(
        _ object: [String: Value],
        nodes: [CoordinatorMissionPlanNode]
    ) throws -> UUID? {
        guard let title = normalizedString(object["node_title"] ?? object["nodeTitle"]) else { return nil }
        guard let node = nodes.first(where: { $0.title.normalizedMissionPlanKey == title.normalizedMissionPlanKey }) else {
            throw MCPError.invalidParams("events[].node_title must match a declared node title.")
        }
        return node.id
    }

    private func parseMissionRoutingDecisions(
        _ value: Value?,
        nodes: [CoordinatorMissionPlanNode],
        workstreams: [CoordinatorMissionWorkstreamSummary]
    ) throws -> [CoordinatorMissionRoutingDecision] {
        guard let array = value?.arrayValue else {
            throw MCPError.invalidParams("routing_decisions must be an array.")
        }
        return try array.map { element in
            guard let object = element.objectValue else {
                throw MCPError.invalidParams("Each routing_decisions entry must be an object.")
            }
            let decisionRaw = try AgentMCPToolHelpers.requireNonEmptyString(object["decision"], name: "routing_decisions[].decision")
            guard let decision = CoordinatorMissionRoutingDecisionKind(rawValue: decisionRaw) else {
                throw MCPError.invalidParams("routing_decisions[].decision must be one of: \(CoordinatorMissionRoutingDecisionKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let operationRaw = try AgentMCPToolHelpers.requireNonEmptyString(object["operation"], name: "routing_decisions[].operation")
            guard let operation = CoordinatorMissionRoutingOperation(rawValue: operationRaw) else {
                throw MCPError.invalidParams("routing_decisions[].operation must be one of: \(CoordinatorMissionRoutingOperation.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let reason = try AgentMCPToolHelpers.requireNonEmptyString(object["reason"], name: "routing_decisions[].reason")
            return try CoordinatorMissionRoutingDecision(
                id: optionalUUID(object["id"], name: "routing_decisions[].id") ?? UUID(),
                timestamp: parseOptionalDate(object["timestamp"], name: "routing_decisions[].timestamp") ?? Date(),
                nodeID: parseRoutingDecisionNodeID(object, nodes: nodes),
                workstreamID: parseRoutingDecisionWorkstreamID(object, workstreams: workstreams),
                decision: decision,
                operation: operation,
                sessionID: optionalUUID(object["session_id"] ?? object["sessionID"], name: "routing_decisions[].session_id"),
                priorSessionID: optionalUUID(object["prior_session_id"] ?? object["priorSessionID"], name: "routing_decisions[].prior_session_id"),
                worktreeID: normalizedString(object["worktree_id"] ?? object["worktreeID"]),
                workflowName: normalizedString(object["workflow_name"] ?? object["workflowName"]),
                modelID: normalizedString(object["model_id"] ?? object["modelID"]),
                role: normalizedString(object["role"]),
                reason: reason,
                contextSummary: normalizedString(object["context_summary"] ?? object["contextSummary"])
            )
        }
    }

    private func parseRoutingDecisionNodeID(
        _ object: [String: Value],
        nodes: [CoordinatorMissionPlanNode]
    ) throws -> UUID? {
        if let nodeID = try optionalUUID(object["node_id"] ?? object["nodeID"], name: "routing_decisions[].node_id") {
            return nodeID
        }
        guard let title = normalizedString(object["node_title"] ?? object["nodeTitle"]) else { return nil }
        guard let node = nodes.first(where: { $0.title.normalizedMissionPlanKey == title.normalizedMissionPlanKey }) else {
            throw MCPError.invalidParams("routing_decisions[].node_title must match a declared node title.")
        }
        return node.id
    }

    private func parseRoutingDecisionWorkstreamID(
        _ object: [String: Value],
        workstreams: [CoordinatorMissionWorkstreamSummary]
    ) throws -> UUID? {
        if let workstreamID = try optionalUUID(object["workstream_id"] ?? object["workstreamID"], name: "routing_decisions[].workstream_id") {
            return workstreamID
        }
        guard let title = normalizedString(object["workstream_title"] ?? object["workstreamTitle"]) else { return nil }
        guard let workstream = workstreams.first(where: { $0.title.normalizedMissionPlanKey == title.normalizedMissionPlanKey }) else {
            throw MCPError.invalidParams("routing_decisions[].workstream_title must match a declared workstream title.")
        }
        return workstream.id
    }

    private func parseOptionalMissionPlanStatus(_ value: Value?) throws -> CoordinatorMissionPlanStatus? {
        guard let raw = normalizedString(value) else { return nil }
        guard let status = CoordinatorMissionPlanStatus(rawValue: raw) else {
            throw MCPError.invalidParams("status must be one of: \(CoordinatorMissionPlanStatus.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return status
    }

    private func parseOptionalMissionPlanApprovalState(_ value: Value?) throws -> CoordinatorMissionPlanApprovalState? {
        guard let raw = normalizedString(value) else { return nil }
        guard let state = CoordinatorMissionPlanApprovalState(rawValue: raw) else {
            throw MCPError.invalidParams("approval_state must be one of: \(CoordinatorMissionPlanApprovalState.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return state
    }

    private func parseOptionalMissionPlanNodeStatus(_ value: Value?) throws -> CoordinatorMissionPlanNodeStatus? {
        guard let raw = normalizedString(value) else { return nil }
        guard let status = CoordinatorMissionPlanNodeStatus(rawValue: raw) else {
            throw MCPError.invalidParams("nodes[].status must be one of: \(CoordinatorMissionPlanNodeStatus.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return status
    }

    private func parseOptionalMissionRoutingOperation(_ value: Value?, name: String) throws -> CoordinatorMissionRoutingOperation? {
        guard let raw = normalizedString(value) else { return nil }
        guard let operation = CoordinatorMissionRoutingOperation(rawValue: raw) else {
            throw MCPError.invalidParams("\(name) must be one of: \(CoordinatorMissionRoutingOperation.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return operation
    }

    private func parseOptionalPositiveInt(_ value: Value?, name: String) throws -> Int? {
        guard let value else { return nil }
        guard let int = value.intValue, int >= 1 else {
            throw MCPError.invalidParams("\(name) must be a positive integer.")
        }
        return int
    }

    private func parseOptionalNonNegativeInt(_ value: Value?, name: String) throws -> Int? {
        guard let value else { return nil }
        guard let int = value.intValue, int >= 0 else {
            throw MCPError.invalidParams("\(name) must be a non-negative integer.")
        }
        return int
    }

    private func parseOptionalDate(_ value: Value?, name: String) throws -> Date? {
        guard let raw = normalizedString(value) else { return nil }
        if let date = AgentMCPToolHelpers.timestampFormatter.date(from: raw) {
            return date
        }
        let fallbackFormatter = ISO8601DateFormatter()
        if let date = fallbackFormatter.date(from: raw) {
            return date
        }
        throw MCPError.invalidParams("\(name) must be an ISO 8601 timestamp.")
    }

    private func optionalUUID(_ value: Value?, name: String) throws -> UUID? {
        guard let raw = normalizedString(value) else { return nil }
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("\(name) must be a UUID.")
        }
        return uuid
    }

    private func optionalUUIDArray(_ value: Value?, name: String) throws -> [UUID]? {
        guard let value else { return nil }
        guard let array = value.arrayValue else {
            throw MCPError.invalidParams("\(name) must be an array of UUID strings.")
        }
        return try array.map { element in
            guard let raw = element.stringValue, let uuid = UUID(uuidString: raw) else {
                throw MCPError.invalidParams("\(name) must contain only UUID strings.")
            }
            return uuid
        }
    }

    private func parseOptionalStringArray(_ value: Value?, name: String) throws -> [String]? {
        guard let value else { return nil }
        guard let array = value.arrayValue else {
            throw MCPError.invalidParams("\(name) must be an array of strings.")
        }
        return try array.map { element in
            try AgentMCPToolHelpers.requireNonEmptyString(element, name: name)
        }
    }

    private func pendingChildSubmission(
        args: [String: Value],
        message: String?
    ) throws -> CoordinatorModeViewModel.ChildInteractionResponseSubmission {
        let parsedAnswers = try args["answers"].map(parseAnswers)
        let explicitSkip: Bool
        if let skipValue = args["skip"] {
            guard let skipBool = skipValue.boolValue else {
                throw MCPError.invalidParams("skip must be a boolean.")
            }
            explicitSkip = skipBool
        } else {
            explicitSkip = false
        }
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if explicitSkip {
            if parsedAnswers?.isEmpty == false || trimmedMessage?.isEmpty == false {
                throw MCPError.invalidParams("skip cannot be combined with message or answers.")
            }
            return CoordinatorModeViewModel.ChildInteractionResponseSubmission(
                text: nil,
                skip: true,
                answersByQuestionID: [:],
                displayText: "Skipped child checkpoint"
            )
        }
        let answers = parsedAnswers ?? [:]
        let displayText = structuredAnswerDisplayText(answers, fallback: trimmedMessage)
        guard !answers.isEmpty || !(trimmedMessage ?? "").isEmpty else {
            throw MCPError.invalidParams("message or answers are required for the pending child interaction.")
        }
        return CoordinatorModeViewModel.ChildInteractionResponseSubmission(
            text: trimmedMessage,
            skip: false,
            answersByQuestionID: answers,
            displayText: displayText
        )
    }

    private func requireCoordinatorSessionID(_ value: Value?) throws -> UUID {
        let raw = try AgentMCPToolHelpers.requireNonEmptyString(value, name: "coordinator_session_id")
        guard let sessionID = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("coordinator_session_id must be a UUID.")
        }
        return sessionID
    }

    private func resolveCoordinatorSessionID(
        _ value: Value?,
        in snapshot: CoordinatorModeSnapshot,
        metadata: RequestMetadata
    ) async throws -> UUID {
        if metadata.isCoordinatorRuntime {
            guard let runtimeCoordinatorID = await resolveRuntimeCoordinatorSessionID(metadata) else {
                throw MCPError.invalidParams("coordinator_session_id is required for Coordinator runtime calls when RepoPrompt cannot resolve the caller Mission. Runtime Mission-scoped operations do not fall back to the selected UI Mission.")
            }
            if let value {
                let requestedID = try requireCoordinatorSessionID(value)
                guard requestedID == runtimeCoordinatorID else {
                    throw MCPError.invalidParams("Coordinator runtime calls are scoped to the caller Mission and cannot write or inspect another Coordinator Mission.")
                }
            }
            return runtimeCoordinatorID
        }
        if let value {
            return try requireCoordinatorSessionID(value)
        }
        if let selectedID = snapshot.coordinatorRail.coordinatorSessionID {
            return selectedID
        }
        throw MCPError.invalidParams("coordinator_session_id is required when no Coordinator Mission is selected.")
    }

    private func coordinatorSessionIDs(in snapshot: CoordinatorModeSnapshot) -> Set<UUID> {
        Set(snapshot.coordinatorRail.availableCoordinators.map(\.sessionID))
    }

    private func selectFreshCoordinatorIfAvailable(
        previousCoordinatorIDs: Set<UUID>,
        in environment: Environment
    ) {
        let freshCoordinator = environment.snapshot().coordinatorRail.availableCoordinators
            .filter { !previousCoordinatorIDs.contains($0.sessionID) }
            .max { lhs, rhs in
                if lhs.lastActivityAt == rhs.lastActivityAt {
                    if lhs.updatedAt == rhs.updatedAt {
                        return lhs.sessionID.uuidString < rhs.sessionID.uuidString
                    }
                    return lhs.updatedAt < rhs.updatedAt
                }
                return lhs.lastActivityAt < rhs.lastActivityAt
            }
        guard let freshCoordinator else { return }
        environment.selectCoordinator(freshCoordinator.sessionID)
        environment.refresh()
    }

    private func normalizedString(_ value: Value?) -> String? {
        guard let value = value?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseAnswers(_ value: Value) throws -> [String: AgentAskUserAnswer] {
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("answers must be an object keyed by question ID.")
        }
        var answers = [String: AgentAskUserAnswer]()
        for entry in object {
            let questionID = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !questionID.isEmpty else {
                throw MCPError.invalidParams("answers cannot contain an empty question ID.")
            }
            answers[questionID] = try parseAnswerValue(entry.value, questionID: questionID)
        }
        return answers
    }

    private func parseAnswerValue(_ value: Value, questionID: String) throws -> AgentAskUserAnswer {
        if let answer = value.stringValue {
            return AgentAskUserAnswer(answers: [answer], selectedOptions: [], customResponse: nil, skipped: false)
        }
        if let answerArray = value.arrayValue {
            let answers = try parseAnswerStringArray(answerArray, name: "answers['\(questionID)']")
            return AgentAskUserAnswer(answers: answers, selectedOptions: [], customResponse: nil, skipped: false)
        }
        guard let answerObject = value.objectValue else {
            throw MCPError.invalidParams("answers['\(questionID)'] must be a string, array of strings, or object.")
        }
        let skipped = answerObject["skipped"]?.boolValue == true || answerObject["skip"]?.boolValue == true
        let selectedOptions = try parseOptionalAnswerStrings(
            answerObject["selected_options"] ?? answerObject["selectedOptions"],
            name: "answers['\(questionID)'].selected_options"
        ) ?? []
        let customResponse = normalizedString(answerObject["custom_response"] ?? answerObject["customResponse"])
        let explicitAnswers = try parseOptionalAnswerStrings(answerObject["answers"], name: "answers['\(questionID)'].answers")
        let resolvedAnswers = explicitAnswers ?? (selectedOptions + (customResponse.map { [$0] } ?? []))
        if skipped {
            guard resolvedAnswers.isEmpty, selectedOptions.isEmpty, customResponse == nil else {
                throw MCPError.invalidParams("answers['\(questionID)'] cannot be skipped and answered at the same time.")
            }
            return AgentAskUserAnswer(answers: [], selectedOptions: [], customResponse: nil, skipped: true)
        }
        return AgentAskUserAnswer(
            answers: resolvedAnswers,
            selectedOptions: selectedOptions,
            customResponse: customResponse,
            skipped: false
        )
    }

    private func parseOptionalAnswerStrings(_ value: Value?, name: String) throws -> [String]? {
        guard let value else { return nil }
        if let answer = value.stringValue {
            return [answer]
        }
        guard let answerArray = value.arrayValue else {
            throw MCPError.invalidParams("\(name) must be a string or array of strings.")
        }
        return try parseAnswerStringArray(answerArray, name: name)
    }

    private func parseAnswerStringArray(_ values: [Value], name: String) throws -> [String] {
        try values.map { element -> String in
            guard let text = element.stringValue else {
                throw MCPError.invalidParams("\(name) must contain only strings.")
            }
            return text
        }
    }

    private func structuredAnswerDisplayText(_ answers: [String: AgentAskUserAnswer], fallback: String?) -> String {
        if !answers.isEmpty {
            return answers.keys.sorted().map { questionID in
                guard let answer = answers[questionID] else { return "\(questionID):" }
                let value = answer.skipped ? "Skipped" : answer.answers.joined(separator: ", ")
                return "\(questionID): \(value)"
            }
            .joined(separator: "\n")
        }
        return fallback ?? ""
    }

    private func validateCoordinatorExists(_ sessionID: UUID, in snapshot: CoordinatorModeSnapshot) throws {
        guard snapshot.coordinatorRail.availableCoordinators.contains(where: { $0.sessionID == sessionID }) else {
            throw MCPError.invalidParams("Coordinator session \(sessionID.uuidString) is not available in this window.")
        }
    }

    private struct InitialMissionPlanWaitResult {
        var snapshot: CoordinatorModeSnapshot
        var isVisible: Bool
        var extra: [String: Value]
    }

    private func waitForInitialMissionPlanPublication(
        in environment: Environment
    ) async -> InitialMissionPlanWaitResult {
        environment.refresh()
        var latest = environment.snapshot()
        if hasVisibleInitialApprovalPlan(latest) {
            return InitialMissionPlanWaitResult(snapshot: latest, isVisible: true, extra: [:])
        }
        if initialMissionPlanTimeoutSeconds <= 0 {
            return initialMissionPlanTimeoutResult(snapshot: latest)
        }

        let deadline = Date().addingTimeInterval(initialMissionPlanTimeoutSeconds)
        let pollNanoseconds = UInt64(max(initialMissionPlanPollIntervalSeconds, 0.01) * 1_000_000_000)
        while Date() < deadline {
            await sleep(pollNanoseconds)
            environment.refresh()
            latest = environment.snapshot()
            if hasVisibleInitialApprovalPlan(latest) {
                return InitialMissionPlanWaitResult(snapshot: latest, isVisible: true, extra: [:])
            }
            if hasTerminalMissionPlanWithoutInitialApproval(latest) {
                return initialMissionPlanTimeoutResult(
                    snapshot: latest,
                    warning: "Mission ended before publishing a visible awaiting-approval plan."
                )
            }
        }

        environment.refresh()
        latest = environment.snapshot()
        if hasVisibleInitialApprovalPlan(latest) {
            return InitialMissionPlanWaitResult(snapshot: latest, isVisible: true, extra: [:])
        }
        return initialMissionPlanTimeoutResult(snapshot: latest)
    }

    private func publishFallbackInitialMissionPlan(
        in environment: Environment,
        directive: String,
        missionKey: String?
    ) throws -> InitialMissionPlanWaitResult {
        environment.refresh()
        let snapshot = environment.snapshot()
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else {
            return initialMissionPlanTimeoutResult(snapshot: snapshot)
        }

        let objective = normalizedString(.string(directive)) ?? directive
        let identityParts = [
            coordinatorSessionID.uuidString,
            missionKey ?? objective
        ]
        let workstreamID = CoordinatorMissionStableIdentity.uuid(
            namespace: "coordinator-chat-initial-plan-workstream",
            parts: identityParts
        )
        let nodeID = CoordinatorMissionStableIdentity.uuid(
            namespace: "coordinator-chat-initial-plan-node",
            parts: identityParts
        )
        let updatedAt = Date()
        try environment.updateMissionPlan(
            coordinatorSessionID,
            CoordinatorMissionPlanUpdate(
                objective: objective,
                missionKey: missionKey,
                status: .draft,
                approvalState: .awaitingApproval,
                workstreams: [
                    CoordinatorMissionWorkstreamSummary(
                        id: workstreamID,
                        title: "Scoped mission intake",
                        purpose: "Keep the mission bounded to the external directive and pause before any delegated child sessions.",
                        role: "coordinator",
                        defaultPolicy: .askUser,
                        worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                            mode: .noneReadOnly,
                            reason: "No child sessions or repository changes are authorized until the initial Mission Plan is approved."
                        )
                    )
                ],
                nodes: [
                    CoordinatorMissionPlanNode(
                        id: nodeID,
                        title: "Approve scoped Mission Plan",
                        detail: "Review the directive, tighten the scope if needed, and approve before the Director starts any child sessions.",
                        completionEvidence: "A visible Mission Plan is approved or revised by the user before delegation.",
                        workstreamID: workstreamID,
                        executionPolicy: .askUser
                    )
                ],
                replaceWorkstreams: true,
                replaceNodes: true,
                updatedAt: updatedAt
            )
        )
        environment.refresh()
        let updatedSnapshot = environment.snapshot()
        guard hasVisibleInitialApprovalPlan(updatedSnapshot) else {
            return initialMissionPlanTimeoutResult(snapshot: updatedSnapshot)
        }
        return InitialMissionPlanWaitResult(snapshot: updatedSnapshot, isVisible: true, extra: [
            "initial_plan_visible": .bool(true),
            "initial_plan_fallback_published": .bool(true)
        ])
    }

    private func hasVisibleInitialApprovalPlan(_ snapshot: CoordinatorModeSnapshot) -> Bool {
        guard let plan = snapshot.coordinatorRail.missionPlan else { return false }
        return plan.approvalState == .awaitingApproval
            && !plan.nodes.isEmpty
            && plan.status != .completed
            && plan.status != .stopped
    }

    private func hasTerminalMissionPlanWithoutInitialApproval(_ snapshot: CoordinatorModeSnapshot) -> Bool {
        guard let plan = snapshot.coordinatorRail.missionPlan else { return false }
        return plan.status == .completed || plan.status == .stopped
    }

    private func initialMissionPlanTimeoutResult(
        snapshot: CoordinatorModeSnapshot,
        warning: String? = nil
    ) -> InitialMissionPlanWaitResult {
        InitialMissionPlanWaitResult(snapshot: snapshot, isVisible: false, extra: [
            "initial_plan_visible": .bool(false),
            "initial_plan_wait_timed_out": .bool(warning == nil),
            "initial_plan_timeout_seconds": .double(initialMissionPlanTimeoutSeconds),
            "warning": .string(warning ?? "Timed out waiting for an awaiting-approval Mission Plan.")
        ])
    }

    private func stateResponse(
        _ snapshot: CoordinatorModeSnapshot,
        extra: [String: Value] = [:]
    ) -> Value {
        var payload: [String: Value] = [
            "selected_coordinator_session_id": AgentMCPToolHelpers.stringOrNull(snapshot.coordinatorRail.coordinatorSessionID?.uuidString),
            "selected_title": AgentMCPToolHelpers.stringOrNull(snapshot.coordinatorRail.title),
            "selection_source": AgentMCPToolHelpers.stringOrNull(snapshot.coordinatorRail.selectionSource?.rawValue),
            "is_live_in_current_window": .bool(snapshot.coordinatorRail.isLiveInCurrentWindow),
            "composer_enabled": .bool(snapshot.coordinatorRail.isComposerEnabled),
            "composer_send_enabled": .bool(snapshot.coordinatorRail.isComposerSendEnabled),
            "mission_template": missionTemplateValue(snapshot.coordinatorRail.missionTemplate),
            "mission_plan": missionPlanValue(snapshot.coordinatorRail.missionPlan),
            "coordinators": .array(snapshot.coordinatorRail.availableCoordinators.map(coordinatorValue)),
            "counts": countsValue(snapshot.counts)
        ]
        payload.merge(extra) { _, new in new }
        return .object(payload)
    }

    private func compactStateResponse(
        _ snapshot: CoordinatorModeSnapshot,
        extra: [String: Value] = [:]
    ) -> Value {
        var payload: [String: Value] = [
            "selected_coordinator_session_id": AgentMCPToolHelpers.stringOrNull(snapshot.coordinatorRail.coordinatorSessionID?.uuidString),
            "selected_title": AgentMCPToolHelpers.stringOrNull(snapshot.coordinatorRail.title),
            "selection_source": AgentMCPToolHelpers.stringOrNull(snapshot.coordinatorRail.selectionSource?.rawValue),
            "composer_enabled": .bool(snapshot.coordinatorRail.isComposerEnabled),
            "composer_send_enabled": .bool(snapshot.coordinatorRail.isComposerSendEnabled),
            "coordinator_count": .int(snapshot.coordinatorRail.availableCoordinators.count),
            "counts": countsValue(snapshot.counts)
        ]
        payload.merge(extra) { _, new in new }
        return .object(payload)
    }

    private func doctorValue(_ snapshot: CoordinatorModeSnapshot) -> Value {
        #if DEBUG
            let scriptedChildAvailable = true
        #else
            let scriptedChildAvailable = false
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let bundleIdentifier = Bundle.main.bundleIdentifier

        return .object([
            "ok": .bool(true),
            "app": .object([
                "bundle_identifier": AgentMCPToolHelpers.stringOrNull(bundleIdentifier),
                "version": AgentMCPToolHelpers.stringOrNull(version),
                "build": AgentMCPToolHelpers.stringOrNull(build),
                "build_sha": .null
            ]),
            "coordinator_chat": .object([
                "supported_ops": .array(Self.supportedOps.map(Value.string)),
                "features": .object([
                    "mission_events": .bool(true),
                    "receipt_markdown": .bool(true),
                    "set_pace": .bool(true),
                    "set_autonomy": .bool(true),
                    "structured_child_input": .bool(true),
                    "scripted_child": .bool(scriptedChildAvailable),
                    "list_missions": .bool(true),
                    "archive_mission": .bool(true)
                ]),
                "runtime_gate": .object([
                    "external_user_actions_block_runtime": .bool(true),
                    "archive_blocks_runtime": .bool(true)
                ])
            ]),
            "child_backends": .object([
                "structured_user_input_advertised": .bool(MCPToolCapabilities.toolNames(for: [.userInteraction]).contains("ask_user")),
                "scripted_child_available": .bool(scriptedChildAvailable),
                "scripted_selector": .string(AgentScriptedChildModelID.selector)
            ]),
            "selected_window": .object([
                "selected_coordinator_session_id": AgentMCPToolHelpers.stringOrNull(snapshot.coordinatorRail.coordinatorSessionID?.uuidString),
                "coordinator_count": .int(snapshot.coordinatorRail.availableCoordinators.count),
                "mission_count": .int(snapshot.coordinatorRail.availableCoordinators.count(where: { $0.missionPlan != nil })),
                "archived_count": .int(snapshot.coordinatorRail.availableCoordinators.count(where: { $0.isPersistedOnly && !$0.isLiveInCurrentWindow }))
            ])
        ])
    }

    private func missionInventoryValue(
        _ snapshot: CoordinatorModeSnapshot,
        includeArchived: Bool,
        scopedTo sessionID: UUID? = nil
    ) -> Value {
        let options = snapshot.coordinatorRail.availableCoordinators.filter { option in
            if let sessionID, option.sessionID != sessionID {
                return false
            }
            return includeArchived || !(option.isPersistedOnly && !option.isLiveInCurrentWindow)
        }
        return .array(options.map(missionInventoryItemValue))
    }

    private func missionInventoryItemValue(_ option: CoordinatorModeCoordinatorOption) -> Value {
        let plan = option.missionPlan
        let decisionCounts = plan.map { missionDecisionCountsByActorValue($0.decisions) } ?? .null
        let evidenceCounts = plan.map { missionEvidenceCountsValue($0.evidence) } ?? .null
        let isArchived = option.isPersistedOnly && !option.isLiveInCurrentWindow
        return .object([
            "coordinator_session_id": .string(option.sessionID.uuidString),
            "title": .string(option.title),
            "mission_key": AgentMCPToolHelpers.stringOrNull(plan?.missionKey),
            "selected": .bool(option.isSelected),
            "live": .bool(option.isLiveInCurrentWindow),
            "archived": .bool(isArchived),
            "pinned": .bool(option.isPinned),
            "terminal": .bool(plan?.status.isTerminal ?? false),
            "status": AgentMCPToolHelpers.stringOrNull(plan?.status.rawValue),
            "approval_state": AgentMCPToolHelpers.stringOrNull(plan?.approvalState.rawValue),
            "run_state": AgentMCPToolHelpers.stringOrNull(option.runState?.rawValue),
            "receipt_ready": .bool(plan?.status.isTerminal ?? false),
            "decision_counts_by_actor": decisionCounts,
            "evidence_counts": evidenceCounts,
            "updated_at": .string(AgentMCPToolHelpers.timestamp(option.updatedAt)),
            "last_activity_at": .string(AgentMCPToolHelpers.timestamp(option.lastActivityAt))
        ])
    }

    private func missionStatusValue(coordinatorSessionID: UUID, snapshot: CoordinatorModeSnapshot) -> Value {
        guard let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == coordinatorSessionID }) else {
            return .null
        }
        let rows = snapshot.groups.flatMap(\.rows)
        guard let plan = option.missionPlan else {
            return .object([
                "coordinator_session_id": .string(option.sessionID.uuidString),
                "title": .string(option.title),
                "has_plan": .bool(false),
                "debug_summary": .string("No Mission Plan is recorded for \(option.title).")
            ])
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0) })
        let rowsBySessionID = Dictionary(
            rows.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let nodeCounts = Dictionary(grouping: plan.nodes, by: \.status).mapValues(\.count)
        let terminalCount = (nodeCounts[.completed] ?? 0) + (nodeCounts[.skipped] ?? 0) + (nodeCounts[.cancelled] ?? 0)
        let activeCount = (nodeCounts[.running] ?? 0) + (nodeCounts[.blocked] ?? 0)
        let debugSummary = "\(option.title): \(plan.status.rawValue), r\(plan.revision), \(terminalCount)/\(plan.nodes.count) terminal nodes, \(activeCount) active/blocking."

        return .object([
            "coordinator_session_id": .string(option.sessionID.uuidString),
            "title": .string(option.title),
            "selected": .bool(option.isSelected),
            "has_plan": .bool(true),
            "debug_summary": .string(debugSummary),
            "plan": missionPlanValue(plan),
            "approval_recovery": missionApprovalRecoveryValue(plan),
            "shape_summary": missionShapeSummaryValue(plan.shapeSummary),
            "policy_snapshot": missionPolicySnapshotValue(plan.policySnapshot),
            "autonomy_summary": missionAutonomySummaryValue(plan.autonomy),
            "decision_counts_by_actor": missionDecisionCountsByActorValue(plan.decisions),
            "evidence_counts": missionEvidenceCountsValue(plan.evidence),
            "recent_ledger_entries": missionRecentLedgerEntriesValue(plan: plan, limit: 20),
            "receipt_ready_summary": missionReceiptReadySummaryValue(plan),
            "node_counts": missionPlanNodeCountsValue(nodeCounts),
            "workstreams": .array(plan.workstreams.map { workstream in
                missionStatusWorkstreamValue(workstream, rowsBySessionID: rowsBySessionID)
            }),
            "nodes": .array(plan.nodes.map { node in
                missionStatusNodeValue(
                    node,
                    plan: plan,
                    nodesByID: nodesByID,
                    rowsBySessionID: rowsBySessionID
                )
            }),
            "recent_events": .array(
                plan.events
                    .sorted { lhs, rhs in
                        if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                        return lhs.timestamp > rhs.timestamp
                    }
                    .prefix(10)
                    .map(missionPlanEventValue)
            ),
            "routing_decisions_recent": .array(
                plan.routingDecisions
                    .sorted { lhs, rhs in
                        if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                        return lhs.timestamp > rhs.timestamp
                    }
                    .prefix(20)
                    .map(missionRoutingDecisionValue)
            )
        ])
    }

    private func missionApprovalRecoveryValue(_ plan: CoordinatorMissionPlan) -> Value {
        guard plan.approvalState == .notRequired else { return .null }
        return .object([
            "legacy_state": .string(CoordinatorMissionPlanApprovalState.notRequired.rawValue),
            "authorizing": .bool(false),
            "requires_fresh_approval_checkpoint": .bool(true),
            "guidance": .string("Legacy approval_state not_required is output-only and non-authorizing. Restore an awaiting_approval plan and require a fresh visible revision-bound approval checkpoint before ordinary delegation, runtime progress, or follow-through resume.")
        ])
    }

    private func compactMissionStatusValue(coordinatorSessionID: UUID, snapshot: CoordinatorModeSnapshot) -> Value {
        guard let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == coordinatorSessionID }) else {
            return .null
        }
        let rows = snapshot.groups.flatMap(\.rows)
        guard let plan = option.missionPlan else {
            return .object([
                "compact": .bool(true),
                "fingerprint": .string(compactMissionStatusFingerprint(option: option, plan: nil, rows: rows, counts: snapshot.counts)),
                "coordinator_session_id": .string(option.sessionID.uuidString),
                "title": .string(option.title),
                "selected": .bool(option.isSelected),
                "run_state": AgentMCPToolHelpers.stringOrNull(option.runState?.rawValue),
                "has_plan": .bool(false),
                "debug_summary": .string("No Mission Plan is recorded for \(option.title)."),
                "liveness_warnings": .array([])
            ])
        }

        let rowsBySessionID = Dictionary(
            rows.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let nodesByID = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0) })
        let dependencySatisfactionByNodeID = missionPlanDependencySatisfactionByNodeID(plan, nodesByID: nodesByID)
        let readyNodeIDs = missionPlanReadyNodeIDs(
            plan,
            dependencySatisfactionByNodeID: dependencySatisfactionByNodeID
        )
        let nodeCounts = Dictionary(grouping: plan.nodes, by: \.status).mapValues(\.count)
        let terminalCount = (nodeCounts[.completed] ?? 0) + (nodeCounts[.skipped] ?? 0) + (nodeCounts[.cancelled] ?? 0)
        let activeNodes = plan.nodes.filter { $0.status == .running || $0.status == .blocked }
        let runningDelegatedNodesWithoutBoundSessions = plan.nodes.filter { node in
            node.status == .running && node.executionPolicy != .coordinatorOnly && node.boundSessionID == nil
        }
        let missingBoundRows = plan.nodes.filter { node in
            guard let boundSessionID = node.boundSessionID else { return false }
            return rowsBySessionID[boundSessionID] == nil && !node.status.isTerminal
        }
        let completedChildMissingChildAskLedgerNodes = plan.nodes.filter { node in
            guard plan.resolvedAutonomy(for: .childAsk) == .auto,
                  node.status == .running,
                  let interactionID = node.boundInteractionID,
                  let boundSessionID = node.boundSessionID,
                  compactMissionRunStateIsTerminal(rowsBySessionID[boundSessionID]?.runState) == true
            else { return false }
            let hasChildAskDecision = plan.decisions.contains { decision in
                decision.resolvedAutonomyClass == .childAsk
                    && decision.interactionID == interactionID
            }
            let hasEvidence = plan.evidence.contains { evidence in
                evidence.interactionID == interactionID
            }
            return !(hasChildAskDecision && hasEvidence)
        }
        let routingWarnings = compactMissionRoutingWarnings(plan: plan, rowsBySessionID: rowsBySessionID)
        let warnings = compactMissionStatusWarnings(
            option: option,
            plan: plan,
            activeNodes: activeNodes,
            runningDelegatedNodesWithoutBoundSessions: runningDelegatedNodesWithoutBoundSessions,
            missingBoundRows: missingBoundRows,
            completedChildMissingChildAskLedgerNodes: completedChildMissingChildAskLedgerNodes,
            readyNodeIDs: readyNodeIDs
        ) + routingWarnings
        let runStateSummary = option.runState?.rawValue ?? "unknown"
        let debugSummary = "\(option.title): \(plan.status.rawValue), \(runStateSummary), r\(plan.revision), \(terminalCount)/\(plan.nodes.count) terminal nodes, \(activeNodes.count) active/blocking."

        return .object([
            "compact": .bool(true),
            "fingerprint": .string(compactMissionStatusFingerprint(
                option: option,
                plan: plan,
                rows: rows,
                counts: snapshot.counts,
                readyNodeIDs: readyNodeIDs,
                dependencySatisfactionByNodeID: dependencySatisfactionByNodeID
            )),
            "coordinator_session_id": .string(option.sessionID.uuidString),
            "title": .string(option.title),
            "selected": .bool(option.isSelected),
            "run_state": AgentMCPToolHelpers.stringOrNull(option.runState?.rawValue),
            "has_plan": .bool(true),
            "debug_summary": .string(debugSummary),
            "plan": .object([
                "revision": .int(plan.revision),
                "mission_key": AgentMCPToolHelpers.stringOrNull(plan.missionKey),
                "objective": AgentMCPToolHelpers.stringOrNull(plan.objective),
                "predecessor_mission_id": AgentMCPToolHelpers.stringOrNull(plan.predecessorMissionID?.uuidString),
                "predecessor_title": AgentMCPToolHelpers.stringOrNull(plan.predecessorTitle),
                "predecessor_summary": AgentMCPToolHelpers.stringOrNull(plan.predecessorSummary),
                "status": .string(plan.status.rawValue),
                "approval_state": .string(plan.approvalState.rawValue),
                "post_approval_continuation": postApprovalContinuationValue(plan.postApprovalContinuation),
                "shape_summary": missionShapeSummaryValue(plan.shapeSummary),
                "policy_snapshot": missionPolicySnapshotSummaryValue(plan.policySnapshot),
                "autonomy_summary": missionAutonomySummaryValue(plan.autonomy)
            ]),
            "approval_recovery": missionApprovalRecoveryValue(plan),
            "decision_counts_by_actor": missionDecisionCountsByActorValue(plan.decisions),
            "evidence_counts": missionEvidenceCountsValue(plan.evidence),
            "recent_ledger_entries": missionRecentLedgerEntriesValue(plan: plan, limit: 5),
            "receipt_ready_summary": missionReceiptReadySummaryValue(plan),
            "node_counts": missionPlanNodeCountsValue(nodeCounts),
            "workstreams": .array(plan.workstreams.map { workstream in
                compactMissionStatusWorkstreamValue(workstream, plan: plan, rowsBySessionID: rowsBySessionID)
            }),
            "ready_node_ids": .array(readyNodeIDs.map { .string($0.uuidString) }),
            "active_nodes": .array(activeNodes.map {
                compactMissionStatusNodeValue(
                    $0,
                    rowsBySessionID: rowsBySessionID,
                    depsSatisfied: dependencySatisfactionByNodeID[$0.id] == true
                )
            }),
            "running_delegated_nodes_without_bound_sessions": .array(
                runningDelegatedNodesWithoutBoundSessions.map {
                    compactMissionStatusNodeValue(
                        $0,
                        rowsBySessionID: rowsBySessionID,
                        depsSatisfied: dependencySatisfactionByNodeID[$0.id] == true
                    )
                }
            ),
            "missing_bound_rows": .array(missingBoundRows.map {
                compactMissionStatusNodeValue(
                    $0,
                    rowsBySessionID: rowsBySessionID,
                    depsSatisfied: dependencySatisfactionByNodeID[$0.id] == true
                )
            }),
            "liveness_warnings": .array(warnings.map(Value.string)),
            "checkpoint": compactMissionCheckpointValue(plan, coordinatorSessionID: coordinatorSessionID),
            "recent_events": .array(
                plan.events
                    .sorted { lhs, rhs in
                        if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                        return lhs.timestamp > rhs.timestamp
                    }
                    .prefix(5)
                    .map(missionPlanEventValue)
            ),
            "routing_decisions_recent": .array(
                plan.routingDecisions
                    .sorted { lhs, rhs in
                        if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                        return lhs.timestamp > rhs.timestamp
                    }
                    .prefix(5)
                    .map(missionRoutingDecisionValue)
            )
        ])
    }

    private func compactMissionStatusWorkstreamValue(
        _ workstream: CoordinatorMissionWorkstreamSummary,
        plan: CoordinatorMissionPlan,
        rowsBySessionID: [UUID: CoordinatorModeRow]
    ) -> Value {
        let primaryRow = workstream.primarySessionID.flatMap { rowsBySessionID[$0] }
        let boundRows = workstream.linkedSessionIDs.compactMap { rowsBySessionID[$0] }
        return .object([
            "id": .string(workstream.id.uuidString),
            "title": .string(workstream.title),
            "default_policy": .string(workstream.defaultPolicy.rawValue),
            "worktree_id": AgentMCPToolHelpers.stringOrNull(workstream.worktreeStrategy.worktreeID),
            "worktree_mode": .string(workstream.worktreeStrategy.mode.rawValue),
            "base_ref": AgentMCPToolHelpers.stringOrNull(workstream.worktreeStrategy.baseRef),
            "primary_session_id": AgentMCPToolHelpers.stringOrNull(workstream.primarySessionID?.uuidString),
            "primary_session_state": AgentMCPToolHelpers.stringOrNull(primaryRow?.runState.rawValue),
            "primary_session_status_group": AgentMCPToolHelpers.stringOrNull(primaryRow?.statusGroup.rawValue),
            "bound_row_count": .int(boundRows.count),
            "next_recommended_route": .string(compactMissionNextRecommendedRoute(workstream: workstream, plan: plan))
        ])
    }

    private func missionEventsResponseValue(_ batch: CoordinatorMissionEventJournal.Batch) -> [String: Value] {
        [
            "events": .array(batch.events.map(missionEventJournalEntryValue)),
            "next_seq": .int(batch.nextSeq),
            "oldest_seq": batch.oldestSeq.map(Value.int) ?? .null,
            "latest_seq": batch.latestSeq.map(Value.int) ?? .null,
            "truncated": .bool(batch.truncated),
            "event_source": .string("mission_events")
        ]
    }

    private func missionEventJournalEntryValue(_ entry: CoordinatorMissionEventJournal.Entry) -> Value {
        .object([
            "seq": .int(entry.seq),
            "observed_at": .string(AgentMCPToolHelpers.timestamp(entry.observedAt)),
            "coordinator_session_id": .string(entry.coordinatorSessionID.uuidString),
            "fingerprint": .string(entry.fingerprint),
            "title": .string(entry.title),
            "selected": .bool(entry.selected),
            "run_state": AgentMCPToolHelpers.stringOrNull(entry.runState),
            "has_plan": .bool(entry.hasPlan),
            "plan": entry.plan.map(missionEventPlanSummaryValue) ?? .null,
            "node_counts": .object(Dictionary(uniqueKeysWithValues: entry.nodeCounts.sorted(by: { $0.key < $1.key }).map { key, value in
                (key, .int(value))
            })),
            "ready_node_ids": .array(entry.readyNodeIDs.map { .string($0.uuidString) }),
            "active_node_ids": .array(entry.activeNodeIDs.map { .string($0.uuidString) }),
            "nodes": .array(entry.nodes.map(missionEventNodeSummaryValue)),
            "recent_event_ids": .array(entry.recentEventIDs.map { .string($0.uuidString) }),
            "routing_decision_ids": .array(entry.routingDecisionIDs.map { .string($0.uuidString) }),
            "decision_ids": .array(entry.decisionIDs.map { .string($0.uuidString) }),
            "evidence_ids": .array(entry.evidenceIDs.map { .string($0.uuidString) }),
            "liveness_warnings": .array(entry.livenessWarnings.map(Value.string))
        ])
    }

    private func missionEventPlanSummaryValue(_ plan: CoordinatorMissionEventJournal.PlanSummary) -> Value {
        .object([
            "revision": .int(plan.revision),
            "mission_key": AgentMCPToolHelpers.stringOrNull(plan.missionKey),
            "status": .string(plan.status),
            "approval_state": .string(plan.approvalState),
            "terminal_node_count": .int(plan.terminalNodeCount),
            "node_count": .int(plan.nodeCount)
        ])
    }

    private func missionEventNodeSummaryValue(_ node: CoordinatorMissionEventJournal.NodeSummary) -> Value {
        .object([
            "id": .string(node.id.uuidString),
            "title": .string(node.title),
            "status": .string(node.status),
            "execution_policy": .string(node.executionPolicy),
            "workstream_id": .string(node.workstreamID.uuidString),
            "depends_on": .array(node.dependsOn.map { .string($0.uuidString) }),
            "deps_satisfied": .bool(node.depsSatisfied),
            "bound_session_id": AgentMCPToolHelpers.stringOrNull(node.boundSessionID?.uuidString),
            "bound_interaction_id": AgentMCPToolHelpers.stringOrNull(node.boundInteractionID?.uuidString)
        ])
    }

    private func missionPlanReadyNodeIDs(_ plan: CoordinatorMissionPlan) -> [UUID] {
        let nodesByID = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0) })
        let dependencySatisfactionByNodeID = missionPlanDependencySatisfactionByNodeID(plan, nodesByID: nodesByID)
        return missionPlanReadyNodeIDs(plan, dependencySatisfactionByNodeID: dependencySatisfactionByNodeID)
    }

    private func missionPlanReadyNodeIDs(
        _ plan: CoordinatorMissionPlan,
        dependencySatisfactionByNodeID: [UUID: Bool]
    ) -> [UUID] {
        plan.nodes.compactMap { node in
            guard node.status == .pending,
                  dependencySatisfactionByNodeID[node.id] == true
            else { return nil }
            return node.id
        }
    }

    private func missionPlanDependencySatisfactionByNodeID(
        _ plan: CoordinatorMissionPlan,
        nodesByID: [UUID: CoordinatorMissionPlanNode]
    ) -> [UUID: Bool] {
        Dictionary(uniqueKeysWithValues: plan.nodes.map { node in
            (node.id, missionPlanDependenciesSatisfied(node, nodesByID: nodesByID))
        })
    }

    private func missionPlanDependenciesSatisfied(
        _ node: CoordinatorMissionPlanNode,
        nodesByID: [UUID: CoordinatorMissionPlanNode]
    ) -> Bool {
        node.dependsOn.allSatisfy { dependencyID in
            nodesByID[dependencyID]?.status == .completed
        }
    }

    private func compactMissionNextRecommendedRoute(
        workstream: CoordinatorMissionWorkstreamSummary,
        plan: CoordinatorMissionPlan
    ) -> String {
        if workstream.primarySessionID != nil {
            return "steer_primary"
        }
        let hasPendingWorkstreamNodes = plan.nodes.contains { node in
            node.workstreamID == workstream.id && !node.status.isTerminal
        }
        guard hasPendingWorkstreamNodes else { return "none" }
        switch workstream.defaultPolicy {
        case .freshReadOnlyChild:
            return "start_fresh_readonly_child"
        case .freshWorktree:
            return "start_fresh_worktree"
        case .freshSiblingOnSameWorktree:
            return "start_fresh_sibling_on_same_worktree"
        case .steerPrimary:
            return "steer_primary"
        case .coordinatorOnly:
            return "coordinator_hold"
        case .askUser:
            return "hold_for_user"
        case .planCritique:
            return "start_plan_critique"
        }
    }

    private func compactMissionStatusFingerprint(
        option: CoordinatorModeCoordinatorOption,
        plan: CoordinatorMissionPlan?,
        rows: [CoordinatorModeRow],
        counts: CoordinatorModeCounts,
        readyNodeIDs: [UUID] = [],
        dependencySatisfactionByNodeID: [UUID: Bool] = [:]
    ) -> String {
        var parts = [
            "coordinator",
            option.sessionID.uuidString,
            option.runState?.rawValue ?? "run_state:nil",
            option.isSelected ? "selected:true" : "selected:false",
            "counts",
            "\(counts.totalRows)",
            "\(counts.liveRows)",
            "\(counts.stalePersistedOnly)",
            "\(counts.needsYou)",
            "\(counts.working)",
            "\(counts.blocked)",
            "\(counts.review)",
            "\(counts.done)"
        ]
        guard let plan else {
            return stableFingerprint(parts)
        }

        parts.append("plan")
        parts.append(String(plan.revision))
        parts.append(plan.status.rawValue)
        parts.append(plan.approvalState.rawValue)
        parts.append(String(plan.nodes.count))
        parts.append(String(plan.workstreams.count))
        parts.append(String(plan.decisions.count))
        parts.append(String(plan.evidence.count))
        parts.append(plan.missionKey ?? "mission_key:nil")
        parts.append(plan.predecessorMissionID?.uuidString ?? "predecessor:nil")
        parts.append(plan.predecessorTitle ?? "predecessor_title:nil")
        parts.append(plan.predecessorSummary ?? "predecessor_summary:nil")
        parts.append(plan.shapeSummary?.id ?? "shape:nil")
        parts.append(plan.shapeSummary?.displayName ?? "shape_display:nil")
        parts.append(plan.shapeSummary?.reason ?? "shape_reason:nil")
        parts.append(plan.shapeSummary?.namedClose ?? "shape_named_close:nil")
        parts.append(plan.policySnapshot?.id ?? "policy:nil")
        parts.append(plan.policySnapshot?.name ?? "policy_name:nil")
        parts.append(plan.policySnapshot?.defaultPace.rawValue ?? "policy_pace:nil")
        parts.append(String(plan.policySnapshot?.maxConcurrent ?? CoordinatorMissionPolicySnapshot.defaultMaxConcurrent))
        parts.append(plan.policySnapshot?.definitionOfDone ?? "policy_dod:nil")
        parts.append(plan.policySnapshot?.standingGuidance ?? "policy_guidance:nil")
        if let continuation = plan.postApprovalContinuation {
            parts.append(contentsOf: [
                "post_approval_continuation",
                continuation.id.uuidString,
                continuation.status.rawValue,
                String(continuation.attempts),
                continuation.lastError ?? "error:nil"
            ])
        }
        for (key, mode) in plan.autonomy.sorted(by: { $0.key < $1.key }) {
            parts.append(contentsOf: ["autonomy", key, mode.rawValue])
        }
        if let policySnapshot = plan.policySnapshot {
            for (key, mode) in policySnapshot.autonomy.sorted(by: { $0.key < $1.key }) {
                parts.append(contentsOf: ["policy_autonomy", key, mode.rawValue])
            }
            parts.append(String(policySnapshot.maxConcurrent))
            parts.append(policySnapshot.pinnedSkillIDs.sorted().joined(separator: ","))
            parts.append(policySnapshot.pinnedContextIDs.sorted().joined(separator: ","))
        }
        for workstream in plan.workstreams {
            parts.append(contentsOf: [
                "workstream",
                workstream.id.uuidString,
                workstream.primarySessionID?.uuidString ?? "primary:nil",
                workstream.worktreeStrategy.worktreeID ?? "worktree:nil"
            ])
        }
        for node in plan.nodes {
            parts.append(contentsOf: [
                "node",
                node.id.uuidString,
                node.status.rawValue,
                node.executionPolicy.rawValue,
                dependencySatisfactionByNodeID[node.id] == true ? "deps_satisfied:true" : "deps_satisfied:false",
                node.completionEvidence ?? "completion_evidence:nil",
                node.doneCriteria ?? "done_criteria:nil",
                node.boundSessionID?.uuidString ?? "bound_session:nil",
                node.boundInteractionID?.uuidString ?? "bound_interaction:nil"
            ])
        }
        parts.append(contentsOf: [
            "ready_node_ids",
            readyNodeIDs.map(\.uuidString).joined(separator: ",")
        ])
        for decision in plan.decisions {
            let decisionParts: [String] = [
                "decision",
                decision.id.uuidString,
                decision.decisionClass,
                decision.actor.rawValue,
                decision.label,
                decision.reason ?? "reason:nil",
                AgentMCPToolHelpers.timestamp(decision.timestamp),
                decision.nodeID?.uuidString ?? "node:nil",
                decision.workstreamID?.uuidString ?? "workstream:nil",
                decision.sessionID?.uuidString ?? "session:nil",
                decision.interactionID?.uuidString ?? "interaction:nil",
                decision.checkpointID ?? "checkpoint:nil",
                decision.checkpointInstanceID ?? "checkpoint_instance:nil",
                decision.overruledDecisionID?.uuidString ?? "overruled_decision:nil",
                decision.overruleReason ?? "overrule_reason:nil",
                decision.correctionReason ?? "correction_reason:nil",
                decision.correctionSteerText ?? "correction_steer_text:nil"
            ]
            parts.append(contentsOf: decisionParts)
        }
        for evidence in plan.evidence {
            let evidenceParts: [String] = [
                "evidence",
                evidence.id.uuidString,
                evidence.verdict.rawValue,
                evidence.summary,
                AgentMCPToolHelpers.timestamp(evidence.timestamp),
                evidence.nodeID?.uuidString ?? "node:nil",
                evidence.workstreamID?.uuidString ?? "workstream:nil",
                evidence.sessionID?.uuidString ?? "session:nil",
                evidence.interactionID?.uuidString ?? "interaction:nil",
                evidence.decisionID?.uuidString ?? "decision:nil"
            ]
            parts.append(contentsOf: evidenceParts)
            appendEvidenceSourceFingerprint(evidence.source, to: &parts)
            appendJudgmentBundleFingerprint(evidence.judgmentBundle, to: &parts)
        }
        let childRows = compactMissionDescendantRows(option: option, rows: rows)
        parts.append(contentsOf: [
            "descendant_rows",
            "\(childRows.count)"
        ])
        for row in childRows {
            parts.append(contentsOf: [
                "row",
                row.sessionID.uuidString,
                row.parentSessionID?.uuidString ?? "parent:nil",
                row.runState.rawValue,
                row.statusGroup.rawValue,
                row.workflow?.id ?? "workflow:nil",
                row.pendingInteraction?.id.uuidString ?? "interaction:nil",
                row.childSessionIDs.map(\.uuidString).sorted().joined(separator: ",")
            ])
        }
        return stableFingerprint(parts)
    }

    private func appendEvidenceSourceFingerprint(
        _ source: CoordinatorMissionEvidenceSource?,
        to parts: inout [String]
    ) {
        guard let source else {
            parts.append("evidence_source:nil")
            return
        }
        parts.append(contentsOf: [
            "evidence_source",
            source.kind,
            source.operation?.rawValue ?? "operation:nil",
            source.routingDecisionID?.uuidString ?? "routing_decision:nil",
            source.nodeID?.uuidString ?? "source_node:nil",
            source.sessionID?.uuidString ?? "source_session:nil",
            source.interactionID?.uuidString ?? "source_interaction:nil",
            source.answerID ?? "answer:nil",
            source.summary ?? "source_summary:nil"
        ])
    }

    private func appendJudgmentBundleFingerprint(
        _ bundle: CoordinatorMissionJudgmentBundle?,
        to parts: inout [String]
    ) {
        guard let bundle else {
            parts.append("judgment_bundle:nil")
            return
        }
        parts.append(contentsOf: [
            "judgment_bundle",
            bundle.doneCriteria ?? "done_criteria:nil",
            bundle.structuredEvidence ?? "structured_evidence:nil",
            bundle.transcriptFraming
        ])
        if let diffStats = bundle.diffStats {
            parts.append(contentsOf: [
                "diff_stats",
                diffStats.filesChanged.map(String.init) ?? "files_changed:nil",
                diffStats.insertions.map(String.init) ?? "insertions:nil",
                diffStats.deletions.map(String.init) ?? "deletions:nil",
                diffStats.summary ?? "diff_summary:nil"
            ])
        } else {
            parts.append("diff_stats:nil")
        }
        if let probeAnswer = bundle.probeAnswer {
            parts.append(contentsOf: [
                "probe_answer",
                probeAnswer.answerID ?? "answer:nil",
                probeAnswer.source ?? "source:nil",
                probeAnswer.answer ?? "answer_text:nil",
                probeAnswer.sessionID?.uuidString ?? "session:nil",
                probeAnswer.interactionID?.uuidString ?? "interaction:nil",
                probeAnswer.routingDecisionID?.uuidString ?? "routing_decision:nil"
            ])
        } else {
            parts.append("probe_answer:nil")
        }
    }

    private func compactMissionDescendantRows(
        option: CoordinatorModeCoordinatorOption,
        rows: [CoordinatorModeRow]
    ) -> [CoordinatorModeRow] {
        var descendantIDs = Set<UUID>()
        var changed = true
        while changed {
            changed = false
            for row in rows {
                let isDirectChild = row.parentSessionID == option.sessionID
                    || row.parentCoordinator?.sessionID == option.sessionID
                let isDescendant = row.parentSessionID.map(descendantIDs.contains) ?? false
                guard isDirectChild || isDescendant else { continue }
                if descendantIDs.insert(row.sessionID).inserted {
                    changed = true
                }
            }
        }
        return rows
            .filter { descendantIDs.contains($0.sessionID) }
            .sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    private func compactMissionRoutingWarnings(
        plan: CoordinatorMissionPlan,
        rowsBySessionID: [UUID: CoordinatorModeRow]
    ) -> [String] {
        var warnings = Set<String>()
        let workstreamsByID = Dictionary(uniqueKeysWithValues: plan.workstreams.map { ($0.id, $0) })
        for workstream in plan.workstreams where workstream.primarySessionID != nil {
            let freshBoundNodes = plan.nodes.filter { node in
                node.workstreamID == workstream.id
                    && node.boundSessionID != nil
                    && (node.executionPolicy == .freshWorktree || node.executionPolicy == .freshReadOnlyChild)
            }
            if freshBoundNodes.count > 1 {
                warnings.insert("workstream_has_multiple_fresh_sessions")
            }
            if freshBoundNodes.contains(where: { !$0.status.isTerminal }) {
                warnings.insert("node_should_steer_primary_but_started_fresh")
            }
        }
        for node in plan.nodes {
            guard let workstream = workstreamsByID[node.workstreamID],
                  workstream.worktreeStrategy.mode != .noneReadOnly,
                  compactMissionNodeNeedsTaskWorktree(node),
                  let boundSessionID = node.boundSessionID,
                  let row = rowsBySessionID[boundSessionID],
                  row.workstream == nil
            else { continue }
            warnings.insert("task_aware_child_missing_worktree_binding")
        }
        return warnings.sorted()
    }

    private func compactMissionNodeNeedsTaskWorktree(_ node: CoordinatorMissionPlanNode) -> Bool {
        switch node.executionPolicy {
        case .freshWorktree, .steerPrimary, .freshSiblingOnSameWorktree:
            true
        case .coordinatorOnly, .freshReadOnlyChild, .planCritique, .askUser:
            node.workflowHint != nil
        }
    }

    private func stableFingerprint(_ parts: [String]) -> String {
        let joined = parts.joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func compactMissionCheckpointValue(_ plan: CoordinatorMissionPlan, coordinatorSessionID: UUID) -> Value {
        guard plan.approvalState == .awaitingApproval,
              !plan.nodes.isEmpty,
              plan.status != .stopped,
              plan.status != .completed
        else {
            return .null
        }

        let checkpointInstanceID = planApprovalCheckpointInstanceID(
            coordinatorSessionID: coordinatorSessionID,
            revision: plan.revision
        )
        return .object([
            "kind": .string("plan_approval"),
            "checkpoint_id": .string("plan-approval"),
            "checkpoint_instance_id": .string(checkpointInstanceID),
            "title": .string("Approval required"),
            "description": .string("Submit one of these messages with coordinator_chat op=submit to continue through the existing Coordinator checkpoint contract."),
            "actions": .array([
                compactMissionCheckpointAction(
                    label: "Proceed",
                    action: .proceed,
                    message: CoordinatorModeViewModel.ContinuationAction.proceed.directiveText,
                    checkpointInstanceID: checkpointInstanceID
                ),
                compactMissionCheckpointAction(
                    label: "Revise",
                    message: "Revise the plan: "
                ),
                compactMissionCheckpointAction(
                    label: "Gather evidence",
                    action: .runLightweightDiscovery,
                    message: CoordinatorModeViewModel.ContinuationAction.runLightweightDiscovery.directiveText,
                    checkpointInstanceID: checkpointInstanceID
                ),
                compactMissionCheckpointAction(
                    label: "Deepen plan",
                    action: .runDeepPlan,
                    message: CoordinatorModeViewModel.ContinuationAction.runDeepPlan.directiveText,
                    checkpointInstanceID: checkpointInstanceID
                ),
                compactMissionCheckpointAction(
                    label: "Get independent critique",
                    action: .runDesignCritique,
                    message: CoordinatorModeViewModel.ContinuationAction.runDesignCritique.directiveText,
                    checkpointInstanceID: checkpointInstanceID
                ),
                compactMissionCheckpointAction(
                    label: "Start smaller",
                    action: .startSmaller,
                    message: CoordinatorModeViewModel.ContinuationAction.startSmaller.directiveText,
                    checkpointInstanceID: checkpointInstanceID
                ),
                compactMissionCheckpointAction(
                    label: "Stop",
                    action: .stopHere,
                    message: CoordinatorModeViewModel.ContinuationAction.stopHere.directiveText
                )
            ])
        ])
    }

    private func compactMissionCheckpointAction(
        label: String,
        action: CoordinatorModeViewModel.ContinuationAction? = nil,
        message: String,
        checkpointInstanceID: String? = nil
    ) -> Value {
        let guidance = CoordinatorModeViewModel.ContinuationAction.runtimeLedgerInstruction
        let submitMessage = message.contains(guidance) ? message : "\(message)\n\n\(guidance)"
        var object: [String: Value] = [
            "label": .string(label),
            "submit_op": .string("submit"),
            "submit_message": .string(submitMessage),
            "mission_plan_append_guidance": .string(guidance)
        ]
        if let action {
            object["checkpoint_action"] = .string(action.checkpointActionID)
        }
        if let checkpointInstanceID {
            object["expected_checkpoint_instance_id"] = .string(checkpointInstanceID)
        }
        return .object(object)
    }

    /// Builds compact liveness warnings for runtime telemetry.
    ///
    /// `eligible_nodes_idle` can fire transiently between a child-terminal event and the
    /// follow-through resume turn that starts newly ready work; it is telemetry, not an error.
    private func compactMissionStatusWarnings(
        option: CoordinatorModeCoordinatorOption,
        plan: CoordinatorMissionPlan,
        activeNodes: [CoordinatorMissionPlanNode],
        runningDelegatedNodesWithoutBoundSessions: [CoordinatorMissionPlanNode],
        missingBoundRows: [CoordinatorMissionPlanNode],
        completedChildMissingChildAskLedgerNodes: [CoordinatorMissionPlanNode],
        readyNodeIDs: [UUID]
    ) -> [String] {
        var warnings: [String] = []
        if option.runState?.isActive != true, !activeNodes.isEmpty {
            warnings.append("coordinator_run_state_is_not_active_but_plan_has_active_nodes")
        }
        if plan.status == .running, option.runState?.isActive != true {
            warnings.append("plan_is_running_but_coordinator_run_state_is_not_active")
        }
        if plan.status == .running,
           !plan.nodes.contains(where: { $0.status == .running }),
           !readyNodeIDs.isEmpty,
           option.runState?.isActive != true
        {
            warnings.append("eligible_nodes_idle")
        }
        if !runningDelegatedNodesWithoutBoundSessions.isEmpty {
            warnings.append("running_delegated_nodes_without_bound_sessions")
        }
        if !missingBoundRows.isEmpty {
            warnings.append("bound_sessions_missing_from_board_rows")
        }
        if !completedChildMissingChildAskLedgerNodes.isEmpty {
            warnings.append("completed_child_missing_childask_ledger")
        }
        return warnings
    }

    private func compactMissionRunStateIsTerminal(_ runState: AgentSessionRunState?) -> Bool {
        switch runState {
        case .completed, .cancelled, .failed:
            true
        case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval, nil:
            false
        }
    }

    private func compactMissionStatusNodeValue(
        _ node: CoordinatorMissionPlanNode,
        rowsBySessionID: [UUID: CoordinatorModeRow],
        depsSatisfied: Bool
    ) -> Value {
        let boundRow = node.boundSessionID.flatMap { rowsBySessionID[$0] }
        return .object([
            "id": .string(node.id.uuidString),
            "title": .string(node.title),
            "status": .string(node.status.rawValue),
            "deps_satisfied": .bool(depsSatisfied),
            "execution_policy": .string(node.executionPolicy.rawValue),
            "workflow_name": AgentMCPToolHelpers.stringOrNull(node.workflowHint?.name),
            "bound_session_id": AgentMCPToolHelpers.stringOrNull(node.boundSessionID?.uuidString),
            "bound_row_status_group": AgentMCPToolHelpers.stringOrNull(boundRow?.statusGroup.rawValue),
            "bound_row_run_state": AgentMCPToolHelpers.stringOrNull(boundRow?.runState.rawValue)
        ])
    }

    private func missionStatusWorkstreamValue(
        _ workstream: CoordinatorMissionWorkstreamSummary,
        rowsBySessionID: [UUID: CoordinatorModeRow]
    ) -> Value {
        let boundRows = workstream.linkedSessionIDs.compactMap { rowsBySessionID[$0] }
        var payload = missionWorkstreamValue(workstream).objectValue ?? [:]
        payload["bound_row_count"] = .int(boundRows.count)
        payload["bound_rows"] = .array(boundRows.map(missionStatusBoundRowValue))
        return .object(payload)
    }

    private func missionStatusNodeValue(
        _ node: CoordinatorMissionPlanNode,
        plan: CoordinatorMissionPlan,
        nodesByID: [UUID: CoordinatorMissionPlanNode],
        rowsBySessionID: [UUID: CoordinatorModeRow]
    ) -> Value {
        var payload = missionPlanNodeValue(node).objectValue ?? [:]
        let dependencyStates = node.dependsOn.map { dependencyID -> Value in
            let dependency = nodesByID[dependencyID]
            return .object([
                "id": .string(dependencyID.uuidString),
                "title": AgentMCPToolHelpers.stringOrNull(dependency?.title),
                "status": AgentMCPToolHelpers.stringOrNull(dependency?.status.rawValue),
                "satisfied": .bool(dependency?.status == .completed)
            ])
        }
        let dependenciesSatisfied = missionPlanDependenciesSatisfied(node, nodesByID: nodesByID)
        let workstream = plan.workstreams.first { $0.id == node.workstreamID }
        payload["workstream_title"] = AgentMCPToolHelpers.stringOrNull(workstream?.title)
        payload["dependencies"] = .array(dependencyStates)
        payload["dependencies_satisfied"] = .bool(dependenciesSatisfied)
        if let boundSessionID = node.boundSessionID, let row = rowsBySessionID[boundSessionID] {
            payload["bound_row"] = missionStatusBoundRowValue(row)
            payload["actual_workflow"] = missionStatusWorkflowValue(row.workflow)
            payload["workflow_matches_plan"] = missionStatusWorkflowMatchesPlan(planned: node.workflowHint, actual: row.workflow)
        } else {
            payload["bound_row"] = .null
            payload["actual_workflow"] = .null
            payload["workflow_matches_plan"] = .null
        }
        payload["planned_workflow"] = missionPlanNodeWorkflowHintValue(node.workflowHint)
        return .object(payload)
    }

    private func missionStatusBoundRowValue(_ row: CoordinatorModeRow) -> Value {
        .object([
            "session_id": .string(row.sessionID.uuidString),
            "title": .string(row.title),
            "status_group": .string(row.statusGroup.rawValue),
            "run_state": .string(row.runState.rawValue),
            "route_available": .bool(row.openAgentChatRoute != nil),
            "workflow": AgentMCPToolHelpers.stringOrNull(row.workflow?.displayName),
            "workflow_id": AgentMCPToolHelpers.stringOrNull(row.workflow?.id),
            "workflow_name": AgentMCPToolHelpers.stringOrNull(row.workflow?.displayName),
            "worktree": row.workstream.map(missionStatusWorktreeValue) ?? .null
        ])
    }

    private func missionStatusWorkflowValue(_ workflow: CoordinatorModeWorkflowDisplaySummary?) -> Value {
        guard let workflow else { return .null }
        return .object([
            "id": .string(workflow.id),
            "name": .string(workflow.displayName),
            "icon_name": .string(workflow.iconName),
            "accent_color_hex": AgentMCPToolHelpers.stringOrNull(workflow.accentColorHex)
        ])
    }

    private func missionStatusWorkflowMatchesPlan(
        planned: CoordinatorMissionPlanNodeWorkflowHint?,
        actual: CoordinatorModeWorkflowDisplaySummary?
    ) -> Value {
        guard let planned else { return .null }
        guard let actual else { return .bool(false) }
        return .bool(workflowHint(planned, matches: actual))
    }

    private func workflowHint(
        _ planned: CoordinatorMissionPlanNodeWorkflowHint,
        matches actual: CoordinatorModeWorkflowDisplaySummary
    ) -> Bool {
        let actualKeys = [
            actual.id,
            actual.displayName
        ].map(normalizedWorkflowComparisonKey)
        let plannedKeys = [
            planned.id,
            planned.name
        ].compactMap(\.self).map(normalizedWorkflowComparisonKey)
        return !Set(actualKeys).isDisjoint(with: plannedKeys)
    }

    private func normalizedWorkflowComparisonKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func missionStatusWorktreeValue(_ worktree: CoordinatorModeRow.Workstream) -> Value {
        .object([
            "label": .string(worktree.label),
            "branch": AgentMCPToolHelpers.stringOrNull(worktree.branch),
            "color_hex": AgentMCPToolHelpers.stringOrNull(worktree.colorHex)
        ])
    }

    private func missionPlanNodeCountsValue(_ counts: [CoordinatorMissionPlanNodeStatus: Int]) -> Value {
        .object(Dictionary(uniqueKeysWithValues: CoordinatorMissionPlanNodeStatus.allCases.map { status in
            (status.rawValue, Value.int(counts[status] ?? 0))
        }))
    }

    private func coordinatorValue(_ option: CoordinatorModeCoordinatorOption) -> Value {
        .object([
            "session_id": .string(option.sessionID.uuidString),
            "title": .string(option.title),
            "tab_id": AgentMCPToolHelpers.stringOrNull(option.tabID?.uuidString),
            "workspace_id": AgentMCPToolHelpers.stringOrNull(option.workspaceID?.uuidString),
            "selection_source": .string(option.selectionSource.rawValue),
            "selected": .bool(option.isSelected),
            "live_in_current_window": .bool(option.isLiveInCurrentWindow),
            "pinned": .bool(option.isPinned),
            "persisted_only": .bool(option.isPersistedOnly),
            "child_counts": coordinatorChildCountsValue(option.childCounts),
            "mission_template": missionTemplateValue(option.missionTemplate),
            "mission_plan": missionPlanValue(option.missionPlan),
            "run_state": AgentMCPToolHelpers.stringOrNull(option.runState?.rawValue),
            "updated_at": .string(AgentMCPToolHelpers.timestamp(option.updatedAt)),
            "last_activity_at": .string(AgentMCPToolHelpers.timestamp(option.lastActivityAt))
        ])
    }

    private func missionTemplateValue(_ template: CoordinatorMissionTemplateSummary?) -> Value {
        guard let template else { return .null }
        return .object([
            "id": .string(template.id),
            "display_name": .string(template.displayName),
            "icon_name": .string(template.iconName),
            "accent_color_hex": AgentMCPToolHelpers.stringOrNull(template.accentColorHex)
        ])
    }

    private func missionShapeSummaryValue(_ shape: CoordinatorMissionShapeSummary?) -> Value {
        guard let shape else { return .null }
        return .object([
            "id": .string(shape.id),
            "display_name": .string(shape.displayName),
            "reason": AgentMCPToolHelpers.stringOrNull(shape.reason),
            "named_close": AgentMCPToolHelpers.stringOrNull(shape.namedClose)
        ])
    }

    private func missionPolicySnapshotSummaryValue(_ policy: CoordinatorMissionPolicySnapshot?) -> Value {
        guard let policy else { return .null }
        return .object([
            "id": .string(policy.id),
            "name": .string(policy.name),
            "default_pace": .string(policy.defaultPace.rawValue),
            "max_concurrent": .int(policy.maxConcurrent),
            "definition_of_done": AgentMCPToolHelpers.stringOrNull(policy.definitionOfDone)
        ])
    }

    private func missionPolicySnapshotValue(_ policy: CoordinatorMissionPolicySnapshot?) -> Value {
        guard let policy else { return .null }
        var payload = missionPolicySnapshotSummaryValue(policy).objectValue ?? [:]
        payload["autonomy"] = missionAutonomyMapValue(policy.autonomy)
        payload["standing_guidance"] = AgentMCPToolHelpers.stringOrNull(policy.standingGuidance)
        payload["pinned_skill_ids"] = .array(policy.pinnedSkillIDs.map(Value.string))
        payload["pinned_context_ids"] = .array(policy.pinnedContextIDs.map(Value.string))
        return .object(payload)
    }

    private func missionAutonomyMapValue(_ autonomy: [String: CoordinatorMissionAutonomyMode]) -> Value {
        .object(Dictionary(uniqueKeysWithValues: autonomy.sorted(by: { $0.key < $1.key }).map { key, mode in
            (key, Value.string(mode.rawValue))
        }))
    }

    private func missionAutonomySummaryValue(_ autonomy: [String: CoordinatorMissionAutonomyMode]) -> Value {
        let decisionClasses = Set(autonomy.keys).union(CoordinatorMissionDecisionClass.allCases.map(\.rawValue))
        let effectiveModes = decisionClasses.map { decisionClass in
            (
                decisionClass,
                CoordinatorMissionPolicySnapshot.resolveAutonomy(autonomy[decisionClass], for: decisionClass)
            )
        }
        let askClasses = effectiveModes
            .filter { $0.1 == .ask }
            .map(\.0)
            .sorted()
        let autoClasses = effectiveModes
            .filter { $0.1 == .auto }
            .map(\.0)
            .sorted()
        return .object([
            "ask": .array(askClasses.map(Value.string)),
            "auto": .array(autoClasses.map(Value.string)),
            "unknown_class_default": .string(CoordinatorMissionAutonomyMode.ask.rawValue),
            "irreversible_default": .string(CoordinatorMissionAutonomyMode.ask.rawValue)
        ])
    }

    private func missionDecisionCountsByActorValue(_ decisions: [CoordinatorMissionDecisionRecord]) -> Value {
        let grouped = Dictionary(grouping: decisions, by: \.actor).mapValues(\.count)
        return .object(Dictionary(uniqueKeysWithValues: CoordinatorMissionDecisionActor.allCases.map { actor in
            (actor.rawValue, Value.int(grouped[actor] ?? 0))
        }))
    }

    private func missionEvidenceCountsValue(_ evidence: [CoordinatorMissionEvidenceRecord]) -> Value {
        let grouped = Dictionary(grouping: evidence, by: \.verdict).mapValues(\.count)
        var payload = Dictionary(uniqueKeysWithValues: CoordinatorMissionEvidenceVerdict.allCases.map { verdict in
            (verdict.rawValue, Value.int(grouped[verdict] ?? 0))
        })
        payload["total"] = .int(evidence.count)
        return .object(payload)
    }

    private func missionRecentLedgerEntriesValue(plan: CoordinatorMissionPlan, limit: Int) -> Value {
        let decisionEntries = plan.decisions.map { decision in
            (
                timestamp: decision.timestamp,
                id: decision.id.uuidString,
                value: Value.object([
                    "kind": .string("decision"),
                    "timestamp": .string(AgentMCPToolHelpers.timestamp(decision.timestamp)),
                    "record": missionDecisionRecordValue(decision)
                ])
            )
        }
        let evidenceEntries = plan.evidence.map { evidence in
            (
                timestamp: evidence.timestamp,
                id: evidence.id.uuidString,
                value: Value.object([
                    "kind": .string("evidence"),
                    "timestamp": .string(AgentMCPToolHelpers.timestamp(evidence.timestamp)),
                    "record": missionEvidenceRecordValue(evidence)
                ])
            )
        }
        let entries = (decisionEntries + evidenceEntries)
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.id < rhs.id }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(limit)
            .map(\.value)
        return .array(entries)
    }

    private func missionReceiptReadySummaryValue(_ plan: CoordinatorMissionPlan) -> Value {
        guard plan.status.isTerminal else { return .null }
        return .object([
            "ready": .bool(true),
            "objective": AgentMCPToolHelpers.stringOrNull(plan.objective),
            "shape": missionShapeSummaryValue(plan.shapeSummary),
            "policy": missionPolicySnapshotSummaryValue(plan.policySnapshot),
            "decision_counts_by_actor": missionDecisionCountsByActorValue(plan.decisions),
            "evidence_counts": missionEvidenceCountsValue(plan.evidence),
            "updated_at": .string(AgentMCPToolHelpers.timestamp(plan.updatedAt))
        ])
    }

    private func missionPlanValue(_ plan: CoordinatorMissionPlan?) -> Value {
        guard let plan else { return .null }
        return .object([
            "id": .string(plan.id.uuidString),
            "revision": .int(plan.revision),
            "mission_key": AgentMCPToolHelpers.stringOrNull(plan.missionKey),
            "objective": AgentMCPToolHelpers.stringOrNull(plan.objective),
            "predecessor_mission_id": AgentMCPToolHelpers.stringOrNull(plan.predecessorMissionID?.uuidString),
            "predecessor_title": AgentMCPToolHelpers.stringOrNull(plan.predecessorTitle),
            "predecessor_summary": AgentMCPToolHelpers.stringOrNull(plan.predecessorSummary),
            "status": .string(plan.status.rawValue),
            "approval_state": .string(plan.approvalState.rawValue),
            "shape_summary": missionShapeSummaryValue(plan.shapeSummary),
            "policy_snapshot": missionPolicySnapshotValue(plan.policySnapshot),
            "autonomy": missionAutonomyMapValue(plan.autonomy),
            "post_approval_continuation": postApprovalContinuationValue(plan.postApprovalContinuation),
            "updated_at": .string(AgentMCPToolHelpers.timestamp(plan.updatedAt)),
            "workstreams": .array(plan.workstreams.map(missionWorkstreamValue)),
            "nodes": .array(plan.nodes.map(missionPlanNodeValue)),
            "routing_decisions": .array(plan.routingDecisions.map(missionRoutingDecisionValue)),
            "decisions": .array(plan.decisions.map(missionDecisionRecordValue)),
            "evidence": .array(plan.evidence.map(missionEvidenceRecordValue)),
            "events": .array(plan.events.map(missionPlanEventValue))
        ])
    }

    private func postApprovalContinuationValue(_ continuation: CoordinatorPostApprovalContinuationRecord?) -> Value {
        guard let continuation else { return .null }
        return .object([
            "id": .string(continuation.id.uuidString),
            "coordinator_session_id": .string(continuation.coordinatorSessionID.uuidString),
            "checkpoint_instance_id": .string(continuation.checkpointInstanceID),
            "plan_id": .string(continuation.planID.uuidString),
            "plan_revision": .int(continuation.planRevision),
            "status": .string(continuation.status.rawValue),
            "attempts": .int(continuation.attempts),
            "last_error": AgentMCPToolHelpers.stringOrNull(continuation.lastError),
            "created_at": .string(AgentMCPToolHelpers.timestamp(continuation.createdAt)),
            "updated_at": .string(AgentMCPToolHelpers.timestamp(continuation.updatedAt))
        ])
    }

    private func missionWorkstreamValue(_ workstream: CoordinatorMissionWorkstreamSummary) -> Value {
        .object([
            "id": .string(workstream.id.uuidString),
            "title": .string(workstream.title),
            "purpose": .string(workstream.purpose),
            "role": AgentMCPToolHelpers.stringOrNull(workstream.role),
            "default_policy": .string(workstream.defaultPolicy.rawValue),
            "default_policy_display_name": .string(workstream.defaultPolicy.displayName),
            "worktree_strategy": .object([
                "mode": .string(workstream.worktreeStrategy.mode.rawValue),
                "display_name": .string(workstream.worktreeStrategy.mode.displayName),
                "worktree_id": AgentMCPToolHelpers.stringOrNull(workstream.worktreeStrategy.worktreeID),
                "base_ref": AgentMCPToolHelpers.stringOrNull(workstream.worktreeStrategy.baseRef),
                "base_reason": AgentMCPToolHelpers.stringOrNull(workstream.worktreeStrategy.baseReason),
                "reason": AgentMCPToolHelpers.stringOrNull(workstream.worktreeStrategy.reason)
            ]),
            "primary_session_id": AgentMCPToolHelpers.stringOrNull(workstream.primarySessionID?.uuidString),
            "related_session_ids": .array(workstream.relatedSessionIDs.map { .string($0.uuidString) }),
            "worktree_id": AgentMCPToolHelpers.stringOrNull(workstream.worktreeID)
        ])
    }

    private func missionPlanNodeValue(_ node: CoordinatorMissionPlanNode) -> Value {
        .object([
            "id": .string(node.id.uuidString),
            "title": .string(node.title),
            "detail": AgentMCPToolHelpers.stringOrNull(node.detail),
            "workflow": missionPlanNodeWorkflowHintValue(node.workflowHint),
            "workflow_id": AgentMCPToolHelpers.stringOrNull(node.workflowHint?.id),
            "workflow_name": AgentMCPToolHelpers.stringOrNull(node.workflowHint?.name),
            "completion_evidence": AgentMCPToolHelpers.stringOrNull(node.completionEvidence),
            "done_criteria": AgentMCPToolHelpers.stringOrNull(node.doneCriteria),
            "workstream_id": .string(node.workstreamID.uuidString),
            "depends_on": .array(node.dependsOn.map { .string($0.uuidString) }),
            "role": AgentMCPToolHelpers.stringOrNull(node.role),
            "execution_policy": .string(node.executionPolicy.rawValue),
            "status": .string(node.status.rawValue),
            "bound_session_id": AgentMCPToolHelpers.stringOrNull(node.boundSessionID?.uuidString),
            "bound_interaction_id": AgentMCPToolHelpers.stringOrNull(node.boundInteractionID?.uuidString)
        ])
    }

    private func missionPlanNodeWorkflowHintValue(_ workflowHint: CoordinatorMissionPlanNodeWorkflowHint?) -> Value {
        guard let workflowHint else { return .null }
        return .object([
            "id": AgentMCPToolHelpers.stringOrNull(workflowHint.id),
            "name": .string(workflowHint.name),
            "icon_name": AgentMCPToolHelpers.stringOrNull(workflowHint.iconName),
            "accent_color_hex": AgentMCPToolHelpers.stringOrNull(workflowHint.accentColorHex)
        ])
    }

    private func missionPlanEventValue(_ event: CoordinatorMissionPlanEvent) -> Value {
        .object([
            "id": .string(event.id.uuidString),
            "kind": .string(event.kind.rawValue),
            "node_id": AgentMCPToolHelpers.stringOrNull(event.nodeID?.uuidString),
            "session_id": AgentMCPToolHelpers.stringOrNull(event.sessionID?.uuidString),
            "interaction_id": AgentMCPToolHelpers.stringOrNull(event.interactionID?.uuidString),
            "timestamp": .string(AgentMCPToolHelpers.timestamp(event.timestamp)),
            "summary": AgentMCPToolHelpers.stringOrNull(event.summary)
        ])
    }

    private func missionDecisionRecordValue(_ decision: CoordinatorMissionDecisionRecord) -> Value {
        .object([
            "id": .string(decision.id.uuidString),
            "decision_class": .string(decision.decisionClass),
            "resolved_autonomy_class": AgentMCPToolHelpers.stringOrNull(decision.resolvedAutonomyClass?.rawValue),
            "actor": .string(decision.actor.rawValue),
            "label": .string(decision.label),
            "reason": AgentMCPToolHelpers.stringOrNull(decision.reason),
            "timestamp": .string(AgentMCPToolHelpers.timestamp(decision.timestamp)),
            "node_id": AgentMCPToolHelpers.stringOrNull(decision.nodeID?.uuidString),
            "workstream_id": AgentMCPToolHelpers.stringOrNull(decision.workstreamID?.uuidString),
            "session_id": AgentMCPToolHelpers.stringOrNull(decision.sessionID?.uuidString),
            "interaction_id": AgentMCPToolHelpers.stringOrNull(decision.interactionID?.uuidString),
            "checkpoint_id": AgentMCPToolHelpers.stringOrNull(decision.checkpointID),
            "checkpoint_instance_id": AgentMCPToolHelpers.stringOrNull(decision.checkpointInstanceID),
            "overruled_decision_id": AgentMCPToolHelpers.stringOrNull(decision.overruledDecisionID?.uuidString),
            "overrule_reason": AgentMCPToolHelpers.stringOrNull(decision.overruleReason),
            "correction_reason": AgentMCPToolHelpers.stringOrNull(decision.correctionReason),
            "correction_steer_text": AgentMCPToolHelpers.stringOrNull(decision.correctionSteerText)
        ])
    }

    private func missionEvidenceRecordValue(_ evidence: CoordinatorMissionEvidenceRecord) -> Value {
        .object([
            "id": .string(evidence.id.uuidString),
            "verdict": .string(evidence.verdict.rawValue),
            "summary": .string(evidence.summary),
            "timestamp": .string(AgentMCPToolHelpers.timestamp(evidence.timestamp)),
            "node_id": AgentMCPToolHelpers.stringOrNull(evidence.nodeID?.uuidString),
            "workstream_id": AgentMCPToolHelpers.stringOrNull(evidence.workstreamID?.uuidString),
            "session_id": AgentMCPToolHelpers.stringOrNull(evidence.sessionID?.uuidString),
            "interaction_id": AgentMCPToolHelpers.stringOrNull(evidence.interactionID?.uuidString),
            "decision_id": AgentMCPToolHelpers.stringOrNull(evidence.decisionID?.uuidString),
            "source": missionEvidenceSourceValue(evidence.source),
            "judgment_bundle": missionJudgmentBundleValue(evidence.judgmentBundle)
        ])
    }

    private func missionEvidenceSourceValue(_ source: CoordinatorMissionEvidenceSource?) -> Value {
        guard let source else { return .null }
        return .object([
            "kind": .string(source.kind),
            "operation": AgentMCPToolHelpers.stringOrNull(source.operation?.rawValue),
            "routing_decision_id": AgentMCPToolHelpers.stringOrNull(source.routingDecisionID?.uuidString),
            "node_id": AgentMCPToolHelpers.stringOrNull(source.nodeID?.uuidString),
            "session_id": AgentMCPToolHelpers.stringOrNull(source.sessionID?.uuidString),
            "interaction_id": AgentMCPToolHelpers.stringOrNull(source.interactionID?.uuidString),
            "answer_id": AgentMCPToolHelpers.stringOrNull(source.answerID),
            "summary": AgentMCPToolHelpers.stringOrNull(source.summary)
        ])
    }

    private func missionJudgmentBundleValue(_ bundle: CoordinatorMissionJudgmentBundle?) -> Value {
        guard let bundle else { return .null }
        return .object([
            "done_criteria": AgentMCPToolHelpers.stringOrNull(bundle.doneCriteria),
            "structured_evidence": AgentMCPToolHelpers.stringOrNull(bundle.structuredEvidence),
            "diff_stats": missionDiffStatsValue(bundle.diffStats),
            "probe_answer": missionProbeAnswerSummaryValue(bundle.probeAnswer),
            "transcript_framing": .string(bundle.transcriptFraming)
        ])
    }

    private func missionDiffStatsValue(_ diffStats: CoordinatorMissionDiffStats?) -> Value {
        guard let diffStats else { return .null }
        return .object([
            "files_changed": diffStats.filesChanged.map(Value.int) ?? .null,
            "insertions": diffStats.insertions.map(Value.int) ?? .null,
            "deletions": diffStats.deletions.map(Value.int) ?? .null,
            "summary": AgentMCPToolHelpers.stringOrNull(diffStats.summary)
        ])
    }

    private func missionProbeAnswerSummaryValue(_ probeAnswer: CoordinatorMissionProbeAnswerSummary?) -> Value {
        guard let probeAnswer else { return .null }
        return .object([
            "answer_id": AgentMCPToolHelpers.stringOrNull(probeAnswer.answerID),
            "source": AgentMCPToolHelpers.stringOrNull(probeAnswer.source),
            "answer": AgentMCPToolHelpers.stringOrNull(probeAnswer.answer),
            "session_id": AgentMCPToolHelpers.stringOrNull(probeAnswer.sessionID?.uuidString),
            "interaction_id": AgentMCPToolHelpers.stringOrNull(probeAnswer.interactionID?.uuidString),
            "routing_decision_id": AgentMCPToolHelpers.stringOrNull(probeAnswer.routingDecisionID?.uuidString)
        ])
    }

    private func missionRoutingDecisionValue(_ decision: CoordinatorMissionRoutingDecision) -> Value {
        .object([
            "id": .string(decision.id.uuidString),
            "timestamp": .string(AgentMCPToolHelpers.timestamp(decision.timestamp)),
            "node_id": AgentMCPToolHelpers.stringOrNull(decision.nodeID?.uuidString),
            "workstream_id": AgentMCPToolHelpers.stringOrNull(decision.workstreamID?.uuidString),
            "decision": .string(decision.decision.rawValue),
            "decision_display_name": .string(decision.decision.displayName),
            "operation": .string(decision.operation.rawValue),
            "operation_display_name": .string(decision.operation.displayName),
            "session_id": AgentMCPToolHelpers.stringOrNull(decision.sessionID?.uuidString),
            "prior_session_id": AgentMCPToolHelpers.stringOrNull(decision.priorSessionID?.uuidString),
            "worktree_id": AgentMCPToolHelpers.stringOrNull(decision.worktreeID),
            "workflow_name": AgentMCPToolHelpers.stringOrNull(decision.workflowName),
            "model_id": AgentMCPToolHelpers.stringOrNull(decision.modelID),
            "role": AgentMCPToolHelpers.stringOrNull(decision.role),
            "reason": .string(decision.reason),
            "context_summary": AgentMCPToolHelpers.stringOrNull(decision.contextSummary)
        ])
    }

    private func coordinatorChildCountsValue(_ counts: CoordinatorModeCoordinatorChildCounts) -> Value {
        .object([
            "total": .int(counts.total),
            "needs_you": .int(counts.needsYou),
            "working": .int(counts.working),
            "blocked": .int(counts.blocked),
            "review": .int(counts.review),
            "done": .int(counts.done)
        ])
    }

    private func countsValue(_ counts: CoordinatorModeCounts) -> Value {
        .object([
            "total": .int(counts.totalRows),
            "needs_you": .int(counts.needsYou),
            "working": .int(counts.working),
            "blocked": .int(counts.blocked),
            "review": .int(counts.review),
            "done": .int(counts.done),
            "stale_persisted_only": .int(counts.stalePersistedOnly),
            "live_rows": .int(counts.liveRows)
        ])
    }
}

private extension String {
    var normalizedMissionPlanKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
