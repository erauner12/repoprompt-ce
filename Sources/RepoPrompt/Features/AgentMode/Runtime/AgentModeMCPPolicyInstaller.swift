import Foundation

@MainActor
enum AgentModeMCPPolicyInstaller {
    static let policyTTL: TimeInterval = 60
    static let policyReason = "agent-mode-run"

    static func additionalTools(for agent: AgentProviderKind) -> Set<String> {
        AgentModeMCPToolPolicy.grantedTools(forAgent: agent)
    }

    static func install(
        agent: AgentProviderKind,
        windowID: Int,
        tabID: UUID,
        runID: UUID,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        connectionPolicyInstaller: AgentModeViewModel.ConnectionPolicyInstaller
    ) async {
        guard let clientName = agent.mcpClientNameHint else { return }
        await connectionPolicyInstaller(
            AgentModeMCPPolicyContext(
                clientName: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: policyReason,
                ttl: policyTTL,
                tabID: tabID,
                runID: runID,
                additionalTools: additionalTools(for: agent),
                purpose: .agentModeRun,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                requiresExpectedAgentPID: agent.requiresExpectedPIDOwnedAgentModeMCPRouting
            )
        )
    }
}
