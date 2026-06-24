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
        var activePendingChildInteractionRow: () -> CoordinatorModeRow?
        var submitPendingChildInteractionResponse: (_ submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission, _ row: CoordinatorModeRow) async -> CoordinatorModeViewModel.DirectiveSubmissionResult
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
                submitDirective: { await coordinatorViewModel.submitCoordinatorDirective($0) },
                activePendingChildInteractionRow: { coordinatorViewModel.activePendingChildInteractionRow() },
                submitPendingChildInteractionResponse: { await coordinatorViewModel.submitPendingChildInteractionResponse($0, to: $1) }
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
            let message = normalizedString(args["message"] ?? args["response"])
            let newParent = AgentMCPToolHelpers.parseBool(args["new_parent"]) ?? false
            if newParent, message == nil {
                throw MCPError.invalidParams("message is required.")
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
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(true),
                    "routed_to": .string(routedToChildInteraction ? "child_interaction" : "coordinator")
                ])
            case let .rejected(message):
                return stateResponse(environment.snapshot(), extra: [
                    "accepted": .bool(false),
                    "routed_to": .string(routedToChildInteraction ? "child_interaction" : "coordinator"),
                    "error": .string(message)
                ])
            }

        default:
            throw MCPError.invalidParams("\(toolName) op must be one of: list, select, new, submit.")
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
