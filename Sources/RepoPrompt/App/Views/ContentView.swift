import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var viewModel: ContentViewModel
    @StateObject private var workspaceApprovalManager = WorkspaceApprovalManager.shared

    @State private var showWorkspaceSetup = false

    /// Sheet for naming a brand-new preset
    @State private var showCreatePresetSheet = false

    // Stable state for toolbar popovers so they survive toolbar re-evaluation
    @State private var showMCPServerPopover = false
    @State private var showMCPStatusSheet = false
    @State private var showRecommendationsPopover = false
    @State private var showWorkspaceSwitchOverlay = false
    @SceneStorage("repoprompt.mainSurfaceSelection") private var mainSurfaceRawValue = MainSurface.defaultSurface.rawValue

    /// Recommendation wizard view model (lazy initialized)
    @State private var recommendationWizardViewModel: RecommendationWizardViewModel?

    /// Initialize with a single WindowState,
    /// then build a ContentViewModel from it.
    init(windowState: WindowState) {
        _viewModel = StateObject(wrappedValue: ContentViewModel(state: windowState))
    }

    var body: some View {
        ContentRootShellView(
            viewModel: viewModel,
            workspaceApprovalManager: workspaceApprovalManager,
            showWorkspaceSwitchOverlay: $showWorkspaceSwitchOverlay,
            mainSurfaceSelection: mainSurfaceSelection
        )
        .toolbar {
            ContentViewToolbarContent(
                windowState: viewModel.state,
                recommendationWizardViewModel: recommendationWizardViewModel,
                showRecommendationsPopover: $showRecommendationsPopover,
                showMCPServerPopover: $showMCPServerPopover,
                mainSurfaceSelection: mainSurfaceSelection,
                isMainSurfaceSwitchingAvailable: viewModel.canSelectMainSurface
            )
        }
        .onAppear {
            showWorkspaceSwitchOverlay = viewModel.workspaceManager.isWorkspaceSwitchOverlayVisible

            // Evaluate initial route (workspace entry vs main) and auto-onboarding
            viewModel.evaluateInitialRouteIfNeeded()
            syncMainSurfaceSelectionToWindowTitle()

            // Initialize recommendation wizard view model
            if recommendationWizardViewModel == nil {
                let engine = AutoRecommendationEngine(
                    settingsStore: GlobalSettingsStore.shared,
                    apiSettingsViewModel: viewModel.apiSettingsViewModel
                )
                recommendationWizardViewModel = RecommendationWizardViewModel(
                    engine: engine,
                    settingsStore: GlobalSettingsStore.shared,
                    workspaceManager: viewModel.workspaceManager,
                    windowID: viewModel.state.windowID
                )
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .workspaceSwitchOverlayDidChange,
                object: viewModel.workspaceManager
            )
        ) { notification in
            if let isVisible = notification.userInfo?["isVisible"] as? Bool {
                showWorkspaceSwitchOverlay = isVisible
            }
        }
        .focusedSceneValue(\.mainSurfaceSelection, mainSurfaceSelection)
        .focusedSceneValue(\.isMainSurfaceSwitchingAvailable, viewModel.canSelectMainSurface)
        .onChange(of: viewModel.canSelectMainSurface) { _, canSelect in
            if !canSelect {
                mainSurfaceRawValue = MainSurface.defaultSurface.rawValue
            }
            syncMainSurfaceSelectionToWindowTitle()
        }
        .onChange(of: mainSurfaceRawValue) { _, _ in
            syncMainSurfaceSelectionToWindowTitle()
        }
        .workspaceSwitchConfirmation(manager: viewModel.workspaceManager)
        .modifier(ContentViewSheetPresenter(
            viewModel: viewModel,
            showWorkspaceSetup: $showWorkspaceSetup,
            showCreatePresetSheet: $showCreatePresetSheet,
            showMCPStatusSheet: $showMCPStatusSheet,
            recommendationWizardViewModel: recommendationWizardViewModel
        ))
        .modifier(ContentViewNotificationHandler(
            windowState: viewModel.state,
            onShowWizard: { viewModel.presentSetupGuide() },
            onShowMCPPopover: { showMCPServerPopover = true },
            onShowCreatePresetSheet: { showCreatePresetSheet = true },
            onShowMCPStatusSheet: { showMCPStatusSheet = true },
            onShowRecommendationWizard: {
                recommendationWizardViewModel?.refresh(navigation: .resetToIntro)
                showRecommendationsPopover = true
            },
            onAppWillRestartForUpdate: { closeAllSheets() }
        ))
        // Close all sheets when a connection approval request comes in
        .onChange(of: viewModel.state.mcpServer.isApprovalOverlayVisible) { _, isVisible in
            if isVisible {
                closeAllSheets()
            }
        }
        // Close all sheets when a workspace approval request comes in
        .onChange(of: workspaceApprovalManager.isApprovalOverlayVisible) { _, isVisible in
            if isVisible {
                closeAllSheets()
            }
        }
        .environmentObject(viewModel.workspaceManager)
    }

    private var mainSurfaceSelection: Binding<MainSurface> {
        Binding {
            guard AppLaunchConfiguration.current.forcedRootRoute != .main else {
                return .agentMode
            }
            guard viewModel.canSelectMainSurface else {
                return .agentMode
            }
            return MainSurface(rawValue: mainSurfaceRawValue) ?? .defaultSurface
        } set: { newValue in
            guard AppLaunchConfiguration.current.forcedRootRoute != .main,
                  viewModel.canSelectMainSurface
            else {
                mainSurfaceRawValue = MainSurface.defaultSurface.rawValue
                return
            }
            mainSurfaceRawValue = newValue.rawValue
        }
    }

    private func syncMainSurfaceSelectionToWindowTitle() {
        viewModel.state.setMainSurfaceForWindowTitle(mainSurfaceSelection.wrappedValue)
    }

    private func closeAllSheets() {
        withAnimation {
            showWorkspaceSetup = false
            showCreatePresetSheet = false
            showMCPStatusSheet = false
        }
    }
}
