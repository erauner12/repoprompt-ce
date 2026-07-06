import SwiftUI

// MARK: - Content View Toolbar Content

struct ContentViewToolbarContent: ToolbarContent {
    let windowState: WindowState
    let recommendationWizardViewModel: RecommendationWizardViewModel?
    @Binding var showRecommendationsPopover: Bool
    @Binding var showMCPServerPopover: Bool
    @Binding var mainSurfaceSelection: MainSurface
    let isMainSurfaceSwitchingAvailable: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            if isMainSurfaceSwitchingAvailable {
                MainSurfaceSegmentedSwitcher(
                    selection: $mainSurfaceSelection,
                    isAvailable: isMainSurfaceSwitchingAvailable,
                    surfaces: [.agentMode, .coordinatorMode]
                )
                .frame(width: 260)
            }
        }

        ToolbarItem(placement: .automatic) {
            Spacer()
                .frame(minWidth: 28, idealWidth: 56, maxWidth: 96)
        }

        // Recommendation wizard button
        ToolbarItem(placement: .automatic) {
            if let wizardVM = recommendationWizardViewModel {
                RecommendationToolbarButtonView(
                    viewModel: wizardVM,
                    showPopover: $showRecommendationsPopover
                )
            }
        }

        // TOOLBAR POPOVER FIX: Pass bindings to prevent state loss during toolbar re-evaluation
        ToolbarItem(placement: .automatic) {
            MCPServerToggleView(windowState: windowState, showPopover: $showMCPServerPopover)
        }

        // Update pill (user-initiated Sparkle UI)
        ToolbarItem(placement: .automatic) {
            UpdateAvailableToolbarPill(sparkleManager: SparkleUpdaterManager.shared)
        }
    }
}
