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
}
