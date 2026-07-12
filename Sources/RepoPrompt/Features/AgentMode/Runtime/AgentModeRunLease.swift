import Foundation

extension MCPBootstrapLeaseSpec {
    @MainActor
    static func agentMode(
        tabID: UUID,
        runID: UUID,
        gateID: UUID,
        windowID: Int,
        agent: AgentProviderKind,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false
    ) -> MCPBootstrapLeaseSpec {
        let policyContext = agent.mcpClientNameHint.map { clientName in
            AgentModeMCPPolicyContext(
                clientName: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: AgentModeMCPPolicyInstaller.policyReason,
                ttl: AgentModeMCPPolicyInstaller.policyTTL,
                tabID: tabID,
                runID: runID,
                additionalTools: AgentModeMCPPolicyInstaller.additionalTools(for: agent),
                purpose: .agentModeRun,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                requiresExpectedAgentPID: agent.requiresExpectedPIDOwnedAgentModeMCPRouting
            )
        }
        return MCPBootstrapLeaseSpec(
            runID: runID,
            gateID: gateID,
            windowID: windowID,
            tabID: tabID,
            clientName: agent.mcpClientNameHint,
            restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
            additionalTools: AgentModeMCPPolicyInstaller.additionalTools(for: agent),
            oneShot: true,
            reason: AgentModeMCPPolicyInstaller.policyReason,
            ttl: AgentModeMCPPolicyInstaller.policyTTL,
            purpose: .agentModeRun,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            requiresExpectedAgentPID: agent.requiresExpectedPIDOwnedAgentModeMCPRouting,
            agentModePolicyContext: policyContext
        )
    }
}

extension MCPBootstrapLease {
    static func agentModePolicyInstaller(
        _ connectionPolicyInstaller: @escaping AgentModeViewModel.ConnectionPolicyInstaller
    ) -> (MCPBootstrapLeaseSpec) async -> Void {
        { leaseSpec in
            guard let context = leaseSpec.agentModePolicyContext else { return }
            await connectionPolicyInstaller(context)
        }
    }

    static func agentModePolicyClearer(
        pendingPolicyClearer: (@Sendable () async -> Void)? = nil
    ) -> (MCPBootstrapLeaseSpec) async -> Void {
        if let pendingPolicyClearer {
            return { _ in await pendingPolicyClearer() }
        }

        return { leaseSpec in
            guard let clientName = leaseSpec.clientName else { return }
            await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                for: clientName,
                windowID: leaseSpec.windowID,
                runID: leaseSpec.runID
            )
        }
    }
}
