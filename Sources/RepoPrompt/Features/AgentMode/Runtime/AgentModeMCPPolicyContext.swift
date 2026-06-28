import Foundation

/// Named policy payload for Agent Mode MCP bootstrap/connection routing.
///
/// Keep this behavior-preserving: Coordinator-specific marker or privilege fields
/// are added by the dependent Coordinator role change, not this prerequisite.
struct AgentModeMCPPolicyContext {
    let clientName: String
    let windowID: Int
    let restrictedTools: Set<String>
    let oneShot: Bool
    let reason: String?
    let ttl: TimeInterval
    let tabID: UUID?
    let runID: UUID?
    let additionalTools: Set<String>?
    let purpose: MCPRunPurpose
    let taskLabelKind: AgentModelCatalog.TaskLabelKind?
    let allowsAgentExternalControlTools: Bool
    let requiresExpectedAgentPID: Bool
    let isCoordinatorRuntime: Bool

    init(
        clientName: String,
        windowID: Int,
        restrictedTools: Set<String>,
        oneShot: Bool,
        reason: String?,
        ttl: TimeInterval,
        tabID: UUID?,
        runID: UUID?,
        additionalTools: Set<String>?,
        purpose: MCPRunPurpose,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        allowsAgentExternalControlTools: Bool,
        requiresExpectedAgentPID: Bool,
        isCoordinatorRuntime: Bool = false
    ) {
        self.clientName = clientName
        self.windowID = windowID
        self.restrictedTools = restrictedTools
        self.oneShot = oneShot
        self.reason = reason
        self.ttl = ttl
        self.tabID = tabID
        self.runID = runID
        self.additionalTools = additionalTools
        self.purpose = purpose
        self.taskLabelKind = taskLabelKind
        self.allowsAgentExternalControlTools = allowsAgentExternalControlTools
        self.requiresExpectedAgentPID = requiresExpectedAgentPID
        self.isCoordinatorRuntime = isCoordinatorRuntime || taskLabelKind == .coordinator
    }
}
