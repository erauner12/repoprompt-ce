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
                Picker("Main Surface", selection: $mainSurfaceSelection) {
                    ForEach(MainSurface.allCases) { surface in
                        Label(surface.displayName, systemImage: surface.systemImage)
                            .tag(surface)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 86)
                .accessibilityLabel("Main surface")
            }
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
