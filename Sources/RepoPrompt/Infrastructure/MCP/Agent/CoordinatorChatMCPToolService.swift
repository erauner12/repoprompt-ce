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
        var activePendingChildInteractionRow: () -> CoordinatorModeRow?
        var submitPendingChildInteractionResponse: (_ submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission, _ row: CoordinatorModeRow) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
        var updateMissionPlan: (_ coordinatorSessionID: UUID, _ update: CoordinatorMissionPlanUpdate) throws -> Void
    }

    private let toolName: String
    private let makeEnvironment: () throws -> Environment
    private let captureRequestMetadata: () async -> RequestMetadata

    init(
        toolName: String,
        requireTargetWindow: @escaping MCPWindowToolDependencies.RequireTargetWindow,
        captureRequestMetadata: @escaping () async -> RequestMetadata
    ) {
        self.toolName = toolName
        self.captureRequestMetadata = captureRequestMetadata
        makeEnvironment = {
            let coordinatorViewModel = try requireTargetWindow().agentModeViewModel.coordinatorModeViewModel
            return Environment(
                snapshot: { coordinatorViewModel.snapshot },
                refresh: { coordinatorViewModel.refresh() },
                selectCoordinator: { coordinatorViewModel.selectCoordinator(sessionID: $0) },
                startNewCoordinatorRun: { coordinatorViewModel.startNewCoordinatorRun() },
                stopSelectedCoordinatorMission: { await coordinatorViewModel.stopSelectedCoordinatorMission() },
                submitDirective: { await coordinatorViewModel.submitCoordinatorDirective($0) },
                activePendingChildInteractionRow: { coordinatorViewModel.activePendingChildInteractionRow() },
                submitPendingChildInteractionResponse: { await coordinatorViewModel.submitPendingChildInteractionResponse($0, to: $1) },
                updateMissionPlan: { try coordinatorViewModel.updateMissionPlan(coordinatorSessionID: $0, update: $1) }
            )
        }
    }

    init(
        toolName: String,
        captureRequestMetadata: @escaping () async -> RequestMetadata = {
            RequestMetadata(connectionID: nil, clientName: nil, windowID: nil)
        },
        makeEnvironment: @escaping () throws -> Environment
    ) {
        self.toolName = toolName
        self.captureRequestMetadata = captureRequestMetadata
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
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(true),
                    "routed_to": .string("coordinator"),
                    "started_new_mission": .bool(true),
                    "selected_existing_mission": .bool(false),
                    "mission_key": AgentMCPToolHelpers.stringOrNull(missionKey)
                ])
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
            let newParent = AgentMCPToolHelpers.parseBool(args["new_parent"]) ?? false
            let compact = AgentMCPToolHelpers.parseBool(args["compact"]) ?? true
            if newParent, message == nil {
                throw MCPError.invalidParams("message is required.")
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
                guard let message, !message.isEmpty else {
                    throw MCPError.invalidParams("message is required.")
                }
                result = await environment.submitDirective(message)
                routedToChildInteraction = false
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
            throw MCPError.invalidParams("\(toolName) op must be one of: list, select, new, ensure_mission, start_mission, stop_mission, submit, mission_plan, mission_status, wait_for_update.")
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
        let events = try parseMissionPlanEvents(args["events"], nodes: effectiveNodes)
        if missionKey == nil,
           objective == nil,
           !predecessorUpdate.hasPredecessorContext,
           status == nil,
           approvalState == nil,
           workstreams == nil,
           nodes == nil,
           routingDecisions == nil,
           events.isEmpty
        {
            throw MCPError.invalidParams("mission_plan requires at least one of mission_key, objective, predecessor context, status, approval_state, workstreams, nodes, routing_decisions, or events.")
        }
        return try CoordinatorMissionPlanUpdate(
            objective: objective,
            missionKey: missionKey,
            predecessorMissionID: predecessorUpdate.update.predecessorMissionID,
            predecessorTitle: predecessorUpdate.update.predecessorTitle,
            predecessorSummary: predecessorUpdate.update.predecessorSummary,
            status: status,
            approvalState: approvalState,
            workstreams: workstreams,
            nodes: nodes,
            replaceWorkstreams: replaceWorkstreams,
            replaceNodes: replaceNodes,
            routingDecisions: routingDecisions,
            events: events,
            updatedAt: parseOptionalDate(args["updated_at"] ?? args["updatedAt"], name: "updated_at") ?? Date()
        )
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
                "fingerprint": .string(compactMissionStatusFingerprint(option: option, plan: nil, rows: rows)),
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
            missingBoundRows: missingBoundRows
        ) + routingWarnings
        let runStateSummary = option.runState?.rawValue ?? "unknown"
        let debugSummary = "\(option.title): \(plan.status.rawValue), \(runStateSummary), r\(plan.revision), \(terminalCount)/\(plan.nodes.count) terminal nodes, \(activeNodes.count) active/blocking."

        return .object([
            "compact": .bool(true),
            "fingerprint": .string(compactMissionStatusFingerprint(option: option, plan: plan, rows: rows)),
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
                "approval_state": .string(plan.approvalState.rawValue)
            ]),
            "node_counts": missionPlanNodeCountsValue(nodeCounts),
            "workstreams": .array(plan.workstreams.map { workstream in
                compactMissionStatusWorkstreamValue(workstream, plan: plan, rowsBySessionID: rowsBySessionID)
            }),
            "active_nodes": .array(activeNodes.map { compactMissionStatusNodeValue($0, rowsBySessionID: rowsBySessionID) }),
            "running_delegated_nodes_without_bound_sessions": .array(
                runningDelegatedNodesWithoutBoundSessions.map { compactMissionStatusNodeValue($0, rowsBySessionID: rowsBySessionID) }
            ),
            "missing_bound_rows": .array(missingBoundRows.map { compactMissionStatusNodeValue($0, rowsBySessionID: rowsBySessionID) }),
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
        rows: [CoordinatorModeRow]
    ) -> String {
        var parts = [
            "coordinator",
            option.sessionID.uuidString,
            option.runState?.rawValue ?? "run_state:nil",
            option.isSelected ? "selected:true" : "selected:false"
        ]
        guard let plan else {
            return stableFingerprint(parts)
        }

        parts.append(contentsOf: [
            "plan",
            "\(plan.revision)",
            plan.status.rawValue,
            plan.approvalState.rawValue,
            "\(plan.nodes.count)",
            "\(plan.workstreams.count)",
            plan.missionKey ?? "mission_key:nil",
            plan.predecessorMissionID?.uuidString ?? "predecessor:nil",
            plan.predecessorTitle ?? "predecessor_title:nil",
            plan.predecessorSummary ?? "predecessor_summary:nil"
        ])
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
                node.boundSessionID?.uuidString ?? "bound_session:nil",
                node.boundInteractionID?.uuidString ?? "bound_interaction:nil"
            ])
        }
        let childRows = rows
            .filter { $0.parentSessionID == option.sessionID }
            .sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
        for row in childRows {
            parts.append(contentsOf: [
                "row",
                row.sessionID.uuidString,
                row.runState.rawValue,
                row.statusGroup.rawValue,
                row.workflow?.id ?? "workflow:nil",
                row.pendingInteraction?.id.uuidString ?? "interaction:nil"
            ])
        }
        return stableFingerprint(parts)
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
                    message: CoordinatorModeViewModel.ContinuationAction.proceed.directiveText
                ),
                compactMissionCheckpointAction(
                    label: "Revise",
                    message: "Revise the plan: "
                ),
                compactMissionCheckpointAction(
                    label: "Gather evidence",
                    message: CoordinatorModeViewModel.ContinuationAction.runLightweightDiscovery.directiveText
                ),
                compactMissionCheckpointAction(
                    label: "Deepen plan",
                    message: CoordinatorModeViewModel.ContinuationAction.runDeepPlan.directiveText
                ),
                compactMissionCheckpointAction(
                    label: "Get independent critique",
                    message: CoordinatorModeViewModel.ContinuationAction.runDesignCritique.directiveText
                ),
                compactMissionCheckpointAction(
                    label: "Start smaller",
                    message: CoordinatorModeViewModel.ContinuationAction.startSmaller.directiveText
                ),
                compactMissionCheckpointAction(
                    label: "Stop",
                    message: CoordinatorModeViewModel.ContinuationAction.stopHere.directiveText
                )
            ])
        ])
    }

    private func compactMissionCheckpointAction(label: String, message: String) -> Value {
        .object([
            "label": .string(label),
            "submit_op": .string("submit"),
            "submit_message": .string(message)
        ])
    }

    private func compactMissionStatusWarnings(
        option: CoordinatorModeCoordinatorOption,
        plan: CoordinatorMissionPlan,
        activeNodes: [CoordinatorMissionPlanNode],
        runningDelegatedNodesWithoutBoundSessions: [CoordinatorMissionPlanNode],
        missingBoundRows: [CoordinatorMissionPlanNode]
    ) -> [String] {
        var warnings: [String] = []
        if option.runState?.isActive != true, !activeNodes.isEmpty {
            warnings.append("coordinator_run_state_is_not_active_but_plan_has_active_nodes")
        }
        if plan.status == .running, option.runState?.isActive != true {
            warnings.append("plan_is_running_but_coordinator_run_state_is_not_active")
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
        rowsBySessionID: [UUID: CoordinatorModeRow]
    ) -> Value {
        let boundRow = node.boundSessionID.flatMap { rowsBySessionID[$0] }
        return .object([
            "id": .string(node.id.uuidString),
            "title": .string(node.title),
            "status": .string(node.status.rawValue),
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
                "satisfied": .bool(dependency?.status.isMissionStatusSatisfied == true)
            ])
        }
        let dependenciesSatisfied = dependencyStates.allSatisfy { value in
            value.objectValue?["satisfied"]?.boolValue == true
        }
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
            "updated_at": .string(AgentMCPToolHelpers.timestamp(plan.updatedAt)),
            "workstreams": .array(plan.workstreams.map(missionWorkstreamValue)),
            "nodes": .array(plan.nodes.map(missionPlanNodeValue)),
            "routing_decisions": .array(plan.routingDecisions.map(missionRoutingDecisionValue)),
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

private extension CoordinatorMissionPlanNodeStatus {
    var isMissionStatusSatisfied: Bool {
        switch self {
        case .completed, .skipped:
            true
        case .pending, .running, .blocked, .cancelled:
            false
        }
    }
}
