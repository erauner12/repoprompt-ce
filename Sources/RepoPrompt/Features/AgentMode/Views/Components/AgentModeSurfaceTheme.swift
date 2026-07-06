import SwiftUI

enum AgentModeSurfaceTheme {
    enum Palette {
        static let detailBackground = Color(nsColor: .controlBackgroundColor)
        static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
        static let sidebarSeparator = Color(nsColor: .separatorColor).opacity(0.48)

        static let searchIcon = Color(nsColor: .labelColor).opacity(0.6)
        static let searchStroke = Color(nsColor: .systemGray).opacity(0.75)

        static let selectedSidebarRowFill = Color.accentColor.opacity(0.15)
        static let hoveredSidebarRowStroke = Color(nsColor: .systemGray).opacity(0.5)

        static let sidebarCardFill = Color(nsColor: .controlBackgroundColor).opacity(0.7)
        static let sidebarCardStroke = Color(nsColor: .separatorColor).opacity(0.55)

        static let workflowCardFill = Color.primary.opacity(0.02)
        static let workflowCardHoverFill = Color.primary.opacity(0.04)
        static let workflowCardStroke = Color.primary.opacity(0.06)
        static let workflowCardHoverStroke = Color.primary.opacity(0.12)

        static func selectedWorkflowCardFill(_ tint: Color = .accentColor) -> Color {
            tint.opacity(0.12)
        }

        static func selectedWorkflowCardStroke(_ tint: Color = .accentColor) -> Color {
            tint.opacity(0.55)
        }
    }
}
