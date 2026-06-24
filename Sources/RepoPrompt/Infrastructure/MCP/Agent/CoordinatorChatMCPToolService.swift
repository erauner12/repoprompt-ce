import Foundation
import MCP

@MainActor
struct CoordinatorChatMCPToolService {
    struct Environment {
        var snapshot: () -> CoordinatorModeSnapshot
        var refresh: () -> Void
        var selectCoordinator: (_ sessionID: UUID?) -> Void
        var startNewCoordinatorRun: () -> Void
        var submitDirective: (_ text: String) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
    }

    private let toolName: String
    private let makeEnvironment: () throws -> Environment

    init(
        toolName: String,
        requireTargetWindow: @escaping MCPWindowToolDependencies.RequireTargetWindow
    ) {
        self.toolName = toolName
        makeEnvironment = {
            let coordinatorViewModel = try requireTargetWindow().agentModeViewModel.coordinatorModeViewModel
            return Environment(
                snapshot: { coordinatorViewModel.snapshot },
                refresh: { coordinatorViewModel.refresh() },
                selectCoordinator: { coordinatorViewModel.selectCoordinator(sessionID: $0) },
                startNewCoordinatorRun: { coordinatorViewModel.startNewCoordinatorRun() },
                submitDirective: { await coordinatorViewModel.submitCoordinatorDirective($0) }
            )
        }
    }

    init(
        toolName: String,
        makeEnvironment: @escaping () throws -> Environment
    ) {
        self.toolName = toolName
        self.makeEnvironment = makeEnvironment
    }

    func execute(args: [String: Value]) async throws -> Value {
        let environment = try makeEnvironment()
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
            environment.startNewCoordinatorRun()
            environment.refresh()
            return stateResponse(environment.snapshot(), extra: [
                "new_parent_pending": .bool(true)
            ])

        case "submit":
            let message = try AgentMCPToolHelpers.requireNonEmptyString(args["message"], name: "message")
            let newParent = AgentMCPToolHelpers.parseBool(args["new_parent"]) ?? false

            environment.refresh()
            if newParent {
                environment.startNewCoordinatorRun()
            } else if let rawSessionID = args["coordinator_session_id"] {
                let sessionID = try requireCoordinatorSessionID(rawSessionID)
                try validateCoordinatorExists(sessionID, in: environment.snapshot())
                environment.selectCoordinator(sessionID)
            }

            let result = await environment.submitDirective(message)
            environment.refresh()

            switch result {
            case .accepted:
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(true)
                ])
            case let .rejected(message):
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(false),
                    "error": .string(message)
                ])
            }

        default:
            throw MCPError.invalidParams("\(toolName) op must be one of: list, select, new, submit.")
        }
    }

    private func requireCoordinatorSessionID(_ value: Value?) throws -> UUID {
        let raw = try AgentMCPToolHelpers.requireNonEmptyString(value, name: "coordinator_session_id")
        guard let sessionID = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("coordinator_session_id must be a UUID.")
        }
        return sessionID
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
            "coordinators": .array(snapshot.coordinatorRail.availableCoordinators.map(coordinatorValue)),
            "counts": countsValue(snapshot.counts)
        ]
        payload.merge(extra) { _, new in new }
        return .object(payload)
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
            "run_state": AgentMCPToolHelpers.stringOrNull(option.runState?.rawValue),
            "updated_at": .string(AgentMCPToolHelpers.timestamp(option.updatedAt)),
            "last_activity_at": .string(AgentMCPToolHelpers.timestamp(option.lastActivityAt))
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
