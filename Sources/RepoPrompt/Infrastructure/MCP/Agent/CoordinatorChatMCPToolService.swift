import Foundation
import MCP

@MainActor
struct CoordinatorChatMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata

    struct Environment {
        var snapshot: () -> CoordinatorModeSnapshot
        var refresh: () -> Void
        var selectCoordinator: (_ sessionID: UUID?) -> Void
        var startNewCoordinatorRun: () -> Void
        var stopSelectedCoordinatorMission: () async -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var submitDirective: (_ text: String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var submitContinuation: (_ action: CoordinatorModeViewModel.ContinuationAction) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var activePendingChildInteractionRow: () -> CoordinatorModeRow?
        var submitPendingChildInteractionResponse: (_ submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission, _ row: CoordinatorModeRow) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var updateMissionPlan: (_ coordinatorSessionID: UUID, _ update: CoordinatorMissionPlanUpdate) throws -> Void
        var missionEvents: (_ coordinatorSessionID: UUID, _ sinceSeq: Int, _ limit: Int) -> CoordinatorMissionEventJournal.Batch
    }

    private let toolName: String
    private let makeEnvironment: () throws -> Environment
    private let captureRequestMetadata: () async -> RequestMetadata
    private let initialMissionPlanTimeoutSeconds: TimeInterval
    private let initialMissionPlanPollIntervalSeconds: TimeInterval
    private let sleep: (UInt64) async -> Void

    init(
        toolName: String,
        requireTargetWindow: @escaping MCPWindowToolDependencies.RequireTargetWindow,
        captureRequestMetadata: @escaping () async -> RequestMetadata,
        initialMissionPlanTimeoutSeconds: TimeInterval = 10,
        initialMissionPlanPollIntervalSeconds: TimeInterval = 0.25,
        sleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.toolName = toolName
        self.captureRequestMetadata = captureRequestMetadata
        self.initialMissionPlanTimeoutSeconds = initialMissionPlanTimeoutSeconds
        self.initialMissionPlanPollIntervalSeconds = initialMissionPlanPollIntervalSeconds
        self.sleep = sleep
        makeEnvironment = {
            let coordinatorViewModel = try requireTargetWindow().agentModeViewModel.coordinatorModeViewModel
            return Environment(
                snapshot: { coordinatorViewModel.snapshot },
                refresh: { coordinatorViewModel.refresh() },
                selectCoordinator: { coordinatorViewModel.selectCoordinator(sessionID: $0) },
                startNewCoordinatorRun: { coordinatorViewModel.startNewCoordinatorRun() },
                stopSelectedCoordinatorMission: { await coordinatorViewModel.stopSelectedCoordinatorMission() },
                submitDirective: { await coordinatorViewModel.submitCoordinatorDirective($0) },
                submitContinuation: { await coordinatorViewModel.submitCoordinatorContinuation($0) },
                activePendingChildInteractionRow: { coordinatorViewModel.activePendingChildInteractionRow() },
                submitPendingChildInteractionResponse: { await coordinatorViewModel.submitPendingChildInteractionResponse($0, to: $1) },
                updateMissionPlan: { try coordinatorViewModel.updateMissionPlan(coordinatorSessionID: $0, update: $1) },
                missionEvents: { coordinatorViewModel.missionEvents(coordinatorSessionID: $0, sinceSeq: $1, limit: $2) }
            )
        }
    }

    init(
        toolName: String,
        captureRequestMetadata: @escaping () async -> RequestMetadata = {
            RequestMetadata(connectionID: nil, clientName: nil, windowID: nil)
        },
        initialMissionPlanTimeoutSeconds: TimeInterval = 10,
        initialMissionPlanPollIntervalSeconds: TimeInterval = 0.25,
        sleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        makeEnvironment: @escaping () throws -> Environment
    ) {
        self.toolName = toolName
        self.captureRequestMetadata = captureRequestMetadata
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
            return stateResponse(environment.snapshot())

        case "select":
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
            environment.startNewCoordinatorRun()
            environment.refresh()
            return stateResponse(environment.snapshot(), extra: [
                "new_parent_pending": .bool(true)
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
            let predecessorUpdate = try parseMissionPredecessorUpdate(args)

            environment.refresh()
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
            environment.startNewCoordinatorRun()
            let result = await environment.submitDirective(message)
            environment.refresh()

            switch result {
            case .accepted:
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
                    "mission_key": AgentMCPToolHelpers.stringOrNull(missionKey)
                ].merging(waitResult.extra) { _, new in new })
            case let .rejected(message):
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(false),
                    "routed_to": .string("coordinator"),
                    "started_new_mission": .bool(true),
                    "selected_existing_mission": .bool(false),
                    "mission_key": AgentMCPToolHelpers.stringOrNull(missionKey),
                    "error": .string(message)
                ])
            }

        case "stop_mission":
            environment.refresh()
            if let rawSessionID = args["coordinator_session_id"] {
                let sessionID = try requireCoordinatorSessionID(rawSessionID)
                try validateCoordinatorExists(sessionID, in: environment.snapshot())
                environment.selectCoordinator(sessionID)
                environment.refresh()
            }
            let result = await environment.stopSelectedCoordinatorMission()
            environment.refresh()
            switch result {
            case .accepted:
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(true),
                    "routed_to": .string("coordinator_stop")
                ])
            case let .rejected(message):
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(false),
                    "routed_to": .string("coordinator_stop"),
                    "error": .string(message)
                ])
            }

        case "submit":
            let message = normalizedString(args["message"] ?? args["response"])
            let continuationAction = try parseCheckpointContinuationAction(args)
            let newParent = AgentMCPToolHelpers.parseBool(args["new_parent"]) ?? false
            let compact = AgentMCPToolHelpers.parseBool(args["compact"]) ?? true
            if newParent, message == nil {
                throw MCPError.invalidParams("message is required.")
            }
            if newParent, continuationAction != nil {
                throw MCPError.invalidParams("checkpoint_action is only valid for existing Coordinator Missions.")
            }
            if newParent {
                try validateExternalMissionCreation(metadata)
            }

            environment.refresh()
            if newParent {
                environment.startNewCoordinatorRun()
            } else if let rawSessionID = args["coordinator_session_id"] {
                let sessionID = try requireCoordinatorSessionID(rawSessionID)
                try validateCoordinatorExists(sessionID, in: environment.snapshot())
                environment.selectCoordinator(sessionID)
            }

            let pendingChildRow = newParent ? nil : environment.activePendingChildInteractionRow()
            let result: CoordinatorModeViewModel.DirectiveSubmissionResult
            let routedToChildInteraction: Bool
            if let pendingChildRow {
                let submission = try pendingChildSubmission(args: args, message: message)
                result = await environment.submitPendingChildInteractionResponse(submission, pendingChildRow)
                routedToChildInteraction = true
            } else {
                if let continuationAction {
                    result = await environment.submitContinuation(continuationAction)
                    routedToChildInteraction = false
                } else {
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

        case "mission_plan":
            environment.refresh()
            let snapshot = environment.snapshot()
            let coordinatorSessionID = try resolveCoordinatorSessionID(args["coordinator_session_id"], in: snapshot)
            try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
            let existingPlan = snapshot.coordinatorRail.availableCoordinators
                .first(where: { $0.sessionID == coordinatorSessionID })?
                .missionPlan
            let update = try parseMissionPlanUpdate(args, existingPlan: existingPlan)
            try environment.updateMissionPlan(coordinatorSessionID, update)
            environment.refresh()
            return stateResponse(environment.snapshot(), extra: [
                "updated": .bool(true),
                "routed_to": .string("mission_plan")
            ])

        case "mission_status":
            environment.refresh()
            let snapshot = environment.snapshot()
            let coordinatorSessionID = try resolveCoordinatorSessionID(args["coordinator_session_id"], in: snapshot)
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
            let coordinatorSessionID = try resolveCoordinatorSessionID(args["coordinator_session_id"], in: snapshot)
            try validateCoordinatorExists(coordinatorSessionID, in: snapshot)
            let sinceSeq = try parseOptionalNonNegativeInt(args["since_seq"] ?? args["sinceSeq"], name: "since_seq") ?? 0
            let limit = try parseOptionalPositiveInt(args["limit"], name: "limit") ?? 200
            let batch = environment.missionEvents(coordinatorSessionID, sinceSeq, min(limit, 500))
            return compactStateResponse(snapshot, extra: missionEventsResponseValue(batch))

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
                latestCoordinatorSessionID = try resolveCoordinatorSessionID(args["coordinator_session_id"], in: latestSnapshot)
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
            throw MCPError.invalidParams("\(toolName) op must be one of: list, select, new, ensure_mission, start_mission, stop_mission, submit, mission_plan, mission_status, mission_events, wait_for_update.")
        }
    }

    private func validateExternalMissionCreation(_ metadata: RequestMetadata) throws {
        if metadata.isCoordinatorRuntime || metadata.taskLabelKind == .coordinator || metadata.runPurpose == .agentModeRun {
            throw MCPError.invalidParams("Coordinator runtime sessions cannot create other Coordinator Missions. Record a follow-up recommendation in the current Mission and wait for an external user or CLI driver to start it.")
        }
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

    private func parseMissionPlanUpdate(
        _ args: [String: Value],
        existingPlan: CoordinatorMissionPlan?
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
            return try CoordinatorMissionPlanNode(
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

    private func resolveCoordinatorSessionID(_ value: Value?, in snapshot: CoordinatorModeSnapshot) throws -> UUID {
        if let value {
            return try requireCoordinatorSessionID(value)
        }
        if let selectedID = snapshot.coordinatorRail.coordinatorSessionID {
            return selectedID
        }
        throw MCPError.invalidParams("coordinator_session_id is required when no Coordinator Mission is selected.")
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
        let routingWarnings = compactMissionRoutingWarnings(plan: plan, rowsBySessionID: rowsBySessionID)
        let warnings = compactMissionStatusWarnings(
            option: option,
            plan: plan,
            activeNodes: activeNodes,
            runningDelegatedNodesWithoutBoundSessions: runningDelegatedNodesWithoutBoundSessions,
            missingBoundRows: missingBoundRows,
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
                "shape_summary": missionShapeSummaryValue(plan.shapeSummary),
                "policy_snapshot": missionPolicySnapshotSummaryValue(plan.policySnapshot),
                "autonomy_summary": missionAutonomySummaryValue(plan.autonomy)
            ]),
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
            "checkpoint": compactMissionCheckpointValue(plan),
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

    private func compactMissionCheckpointValue(_ plan: CoordinatorMissionPlan) -> Value {
        guard plan.approvalState == .awaitingApproval,
              !plan.nodes.isEmpty,
              plan.status != .stopped,
              plan.status != .completed
        else {
            return .null
        }

        return .object([
            "kind": .string("plan_approval"),
            "title": .string("Approval required"),
            "description": .string("Submit one of these messages with coordinator_chat op=submit to continue through the existing Coordinator checkpoint contract."),
            "actions": .array([
                compactMissionCheckpointAction(
                    label: "Proceed",
                    action: .proceed,
                    message: CoordinatorModeViewModel.ContinuationAction.proceed.directiveText
                ),
                compactMissionCheckpointAction(
                    label: "Revise",
                    message: "Revise the plan: "
                ),
                compactMissionCheckpointAction(
                    label: "Gather evidence",
                    action: .runLightweightDiscovery,
                    message: CoordinatorModeViewModel.ContinuationAction.runLightweightDiscovery.directiveText
                ),
                compactMissionCheckpointAction(
                    label: "Deepen plan",
                    action: .runDeepPlan,
                    message: CoordinatorModeViewModel.ContinuationAction.runDeepPlan.directiveText
                ),
                compactMissionCheckpointAction(
                    label: "Get independent critique",
                    action: .runDesignCritique,
                    message: CoordinatorModeViewModel.ContinuationAction.runDesignCritique.directiveText
                ),
                compactMissionCheckpointAction(
                    label: "Start smaller",
                    action: .startSmaller,
                    message: CoordinatorModeViewModel.ContinuationAction.startSmaller.directiveText
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
        message: String
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
        return warnings
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
        guard plan.status == .completed else { return .null }
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
            "updated_at": .string(AgentMCPToolHelpers.timestamp(plan.updatedAt)),
            "workstreams": .array(plan.workstreams.map(missionWorkstreamValue)),
            "nodes": .array(plan.nodes.map(missionPlanNodeValue)),
            "routing_decisions": .array(plan.routingDecisions.map(missionRoutingDecisionValue)),
            "decisions": .array(plan.decisions.map(missionDecisionRecordValue)),
            "evidence": .array(plan.evidence.map(missionEvidenceRecordValue)),
            "events": .array(plan.events.map(missionPlanEventValue))
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
