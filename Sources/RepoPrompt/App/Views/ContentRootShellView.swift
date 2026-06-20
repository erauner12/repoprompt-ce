import SwiftUI

// MARK: - Content Root Shell

struct ContentRootShellView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var workspaceApprovalManager: WorkspaceApprovalManager
    @Binding var showWorkspaceSwitchOverlay: Bool
    @Binding var mainSurfaceSelection: MainSurface

    var body: some View {
        ZStack {
            routedContent
                .blur(radius: showWorkspaceSwitchOverlay ? 6 : 0, opaque: false)
                .animation(.easeInOut(duration: 0.12), value: showWorkspaceSwitchOverlay)

            if showWorkspaceSwitchOverlay {
                WorkspaceSwitchLoadingOverlay {
                    await viewModel.workspaceManager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
                }
                .zIndex(999)
            }

            // MCP Client Approval Overlay
            if let clientID = viewModel.state.mcpServer.pendingClientID,
               viewModel.state.mcpServer.isApprovalOverlayVisible
            {
                MCPApprovalOverlayView(clientID: clientID)
                    .environmentObject(viewModel.state.mcpServer)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(1000)
            }

            // Workspace Operation Approval Overlay
            if let request = workspaceApprovalManager.pendingRequest,
               workspaceApprovalManager.isApprovalOverlayVisible
            {
                WorkspaceApprovalOverlayView(
                    approvalManager: workspaceApprovalManager,
                    request: request
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1001)
            }
        }
    }

    @ViewBuilder
    private var routedContent: some View {
        if viewModel.rootRoute == .workspaceEntry {
            WorkspaceEntryRootView(
                workspaceManager: viewModel.workspaceManager,
                windowState: viewModel.state,
                tab: $viewModel.workspaceEntryTab,
                onboardingViewModel: viewModel.onboardingViewModel,
                onCreateOnboardingViewModelIfNeeded: { viewModel.ensureOnboardingViewModel() },
                onContinueToMain: {
                    viewModel.continueFromOnboarding()
                }
            )
        } else if viewModel.canSelectMainSurface, mainSurfaceSelection == .coordinatorMode {
            CoordinatorModeView(
                viewModel: viewModel.state.agentModeViewModel.coordinatorModeViewModel,
                mainSurfaceSelection: $mainSurfaceSelection,
                isMainSurfaceSwitchingAvailable: viewModel.canSelectMainSurface,
                onOpenAgentChat: { route in
                    mainSurfaceSelection = .agentMode
                    Task { @MainActor in
                        _ = await viewModel.state.routeToAgentSession(route)
                    }
                }
            )
        } else {
            AgentModeView(
                windowState: viewModel.state,
                agentModeVM: viewModel.state.agentModeViewModel,
                promptManager: viewModel.promptManager,
                mainSurfaceSelection: $mainSurfaceSelection,
                isMainSurfaceSwitchingAvailable: viewModel.canSelectMainSurface
            )
        }
    }
}
