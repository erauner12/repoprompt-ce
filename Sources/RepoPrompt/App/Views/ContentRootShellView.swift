import Combine
import SwiftUI

// MARK: - Content Root Shell

struct ContentRootShellView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var workspaceApprovalManager: WorkspaceApprovalManager
    @Binding var showWorkspaceSwitchOverlay: Bool
    @Binding var mainSurfaceSelection: MainSurface
    @StateObject private var coordinatorRootsSidebarStore: AgentWorkspaceRootsSidebarStore

    init(
        viewModel: ContentViewModel,
        workspaceApprovalManager: WorkspaceApprovalManager,
        showWorkspaceSwitchOverlay: Binding<Bool>,
        mainSurfaceSelection: Binding<MainSurface>
    ) {
        self.viewModel = viewModel
        self.workspaceApprovalManager = workspaceApprovalManager
        _showWorkspaceSwitchOverlay = showWorkspaceSwitchOverlay
        _mainSurfaceSelection = mainSurfaceSelection
        _coordinatorRootsSidebarStore = StateObject(wrappedValue: AgentWorkspaceRootsSidebarStore(
            rootProjections: { viewModel.state.workspaceFilesViewModel.visibleRootShellProjections },
            rootChanges: viewModel.state.workspaceFilesViewModel.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            gitContextLookup: { viewModel.promptManager.gitViewModel.gitWorktreeContext(forStandardizedRootPath: $0) },
            gitContextChanges: viewModel.promptManager.gitViewModel.gitWorktreeContextChanges,
            workspaceManager: viewModel.state.workspaceManager,
            windowID: viewModel.state.windowID
        ))
    }

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
                agentModeVM: viewModel.state.agentModeViewModel,
                promptManager: viewModel.promptManager,
                workspaceSearchService: viewModel.state.workspaceSearchService,
                selectionCoordinator: viewModel.state.selectionCoordinator,
                rootsStore: coordinatorRootsSidebarStore,
                apiSettingsVM: viewModel.state.apiSettingsViewModel,
                currentTabID: viewModel.promptManager.activeComposeTabID,
                onManageWorkspaces: {
                    NotificationCenter.default.post(
                        name: .showManageWorkspacesTab,
                        object: nil,
                        userInfo: ["windowID": viewModel.state.windowID]
                    )
                },
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
                promptManager: viewModel.promptManager
            )
        }
    }
}
