import Foundation

enum AgentRunCoordinatorWorktreePolicy {
    enum Decision: Equatable {
        case allow
        case requireExplicitWorktree(String)
    }

    static let explicitWorktreeRequiredMessage = """
    Mutable Coordinator-delegated work must start in an explicit isolated worktree. Use agent_run.start with worktree_create=true or an existing worktree_id before launching the child. Read-only delegation may omit a worktree.
    """

    static func decision(
        isCoordinatorParent: Bool,
        message: String,
        workflow: AgentWorkflowDefinition?,
        hasExplicitWorktree: Bool
    ) -> Decision {
        guard isCoordinatorParent else { return .allow }
        guard !hasExplicitWorktree else { return .allow }
        guard requiresExplicitWorktree(message: message, workflow: workflow) else { return .allow }
        return .requireExplicitWorktree(explicitWorktreeRequiredMessage)
    }

    private static func requiresExplicitWorktree(
        message: String,
        workflow: AgentWorkflowDefinition?
    ) -> Bool {
        let normalized = normalize(message)
        if containsAnyUnnegatedPhrase(normalized, in: hardWorktreePhrases) {
            return true
        }

        if workflowSuggestsMutation(workflow) {
            return true
        }

        let tokens = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let mutation = !tokens.isDisjoint(with: mutationTokens)
        guard mutation else { return false }

        if containsAnyPhrase(normalized, in: readOnlyPhrases) {
            return false
        }
        return true
    }

    private static func workflowSuggestsMutation(_ workflow: AgentWorkflowDefinition?) -> Bool {
        guard let workflow else { return false }
        if let builtIn = workflow.builtInWorkflow {
            switch builtIn {
            case .build, .refactor, .optimize, .orchestrate:
                return true
            case .deepPlan, .investigate, .oracleExport, .review:
                return false
            }
        }
        let normalizedName = normalize(workflow.displayName)
        return containsAnyPhrase(normalizedName, in: ["build", "implement", "refactor", "optimize", "orchestrate"])
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func containsAnyPhrase(_ normalized: String, in phrases: [String]) -> Bool {
        phrases.contains { normalized.contains($0) }
    }

    private static func containsAnyUnnegatedPhrase(_ normalized: String, in phrases: [String]) -> Bool {
        phrases.contains { phrase in
            var searchStart = normalized.startIndex
            while let range = normalized.range(of: phrase, range: searchStart ..< normalized.endIndex) {
                defer { searchStart = range.upperBound }
                guard !isNegated(normalized, before: range.lowerBound) else { continue }
                return true
            }
            return false
        }
    }

    private static func isNegated(_ normalized: String, before phraseStart: String.Index) -> Bool {
        let sentenceStart = normalized[..<phraseStart].lastIndex { character in
            character == "." || character == "?" || character == "!" || character == "\n"
        }.map { normalized.index(after: $0) } ?? normalized.startIndex

        let prefix = String(normalized[sentenceStart ..< phraseStart])
        return negationPhrases.contains { prefix.contains($0) }
    }

    private static let hardWorktreePhrases: [String] = [
        "merge preview",
        "review packet",
        "worktree merge",
        "create a pr",
        "create pull request",
        "open a pr",
        "open pull request",
        "prepare a pr",
        "prepare pull request",
        "commit the change",
        "commit changes",
        "apply the change",
        "apply changes",
        "make dev-test",
        "swift test",
        "run focused test",
        "run the focused test",
        "run validation",
        "validate the change"
    ]

    private static let readOnlyPhrases: [String] = [
        "do not edit",
        "no edits",
        "without editing",
        "read only",
        "read-only",
        "inspect only",
        "only inspect",
        "summarize",
        "answer in",
        "tell me",
        "report back",
        "look into",
        "investigate"
    ]

    private static let negationPhrases: [String] = [
        "do not",
        "don't",
        "must not",
        "no ",
        "never",
        "without"
    ]

    private static let mutationTokens: Set<String> = [
        "add",
        "apply",
        "build",
        "change",
        "commit",
        "create",
        "delete",
        "edit",
        "fix",
        "implement",
        "merge",
        "modify",
        "patch",
        "pr",
        "remove",
        "rename",
        "replace",
        "update",
        "write"
    ]
}
