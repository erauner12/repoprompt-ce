import SwiftUI

// MARK: - Coordinator/Director visual tokens

/// Shared visual language for Coordinator-backed Director surfaces.
///
/// Swift symbols intentionally stay Coordinator-named while user-facing copy remains Director.
/// The palette is anchored to Agent Mode's restrained system-material language so future parity
/// waves can reuse the same card, pill, and status primitives instead of restyling per view.
enum CoordinatorTheme {
    enum Palette {
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        static let panelBackground = Color(nsColor: .controlBackgroundColor)
        static let elevatedPanelBackground = Color(nsColor: .controlBackgroundColor).opacity(0.86)
        static let recessedPanelBackground = Color(nsColor: .windowBackgroundColor).opacity(0.82)
        static let hairline = Color.secondary.opacity(0.16)
        static let strongHairline = Color.secondary.opacity(0.26)
        static let seam = Color.secondary.opacity(0.12)
        static let shadow = Color.black.opacity(0.16)

        static func selectedFill(_ tint: Color = .accentColor) -> Color {
            tint.opacity(0.18)
        }

        static func selectedStroke(_ tint: Color = .accentColor) -> Color {
            tint.opacity(0.34)
        }

        static func hoverStroke() -> Color {
            Color.white.opacity(0.24)
        }
    }

    enum Radius {
        static let panel: CGFloat = 18
        static let card: CGFloat = 12
        static let compactCard: CGFloat = 10
        static let pill: CGFloat = 999
    }

    enum Stroke {
        static let hairline: CGFloat = 0.75
        static let selected: CGFloat = 1.2
    }

    enum Opacity {
        static let cardFill = 0.58
        static let groupedFill = 0.42
        static let railCardFill = 0.46
        static let emptyColumnFill = 0.18
        static let statusChipFill = 0.09
        static let statusChipStroke = 0.22
        static let listRowFill = 0.28
    }

    enum Semantic {
        case info
        case success
        case warning
        case purple
        case danger
        case neutral

        var tint: Color {
            switch self {
            case .info: Color(hex: "#58A6FF") ?? .blue
            case .success: Color(hex: "#3FB950") ?? .green
            case .warning: Color(hex: "#D29922") ?? .orange
            case .purple: Color(hex: "#BC8CFF") ?? .purple
            case .danger: Color(hex: "#F85149") ?? .red
            case .neutral: .secondary
            }
        }
    }
}

struct CoordinatorPill: View {
    let title: String
    let tint: Color
    let font: Font
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    var foregroundOpacity = 0.92
    var fillOpacity = CoordinatorTheme.Opacity.statusChipFill
    var strokeOpacity = CoordinatorTheme.Opacity.statusChipStroke

    var body: some View {
        Text(title)
            .font(font)
            .lineLimit(1)
            .foregroundStyle(tint.opacity(foregroundOpacity))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Capsule(style: .continuous).fill(tint.opacity(fillOpacity)))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(strokeOpacity), lineWidth: 0.5)
            )
    }
}

struct CoordinatorStatusPlate: View {
    let title: String
    let tint: Color
    let font: Font
    let dotSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    var systemImage: String?

    var body: some View {
        HStack(spacing: max(dotSize * 0.65, 4)) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(font)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: dotSize, height: dotSize)
            }
            Text(title)
                .font(font)
                .lineLimit(1)
        }
        .foregroundStyle(tint.opacity(0.94))
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.10)))
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 0.5)
        )
    }
}

extension View {
    func coordinatorThemeControlCapsule() -> some View {
        background(
            Capsule(style: .continuous)
                .fill(CoordinatorTheme.Palette.elevatedPanelBackground)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(CoordinatorTheme.Palette.strongHairline, lineWidth: CoordinatorTheme.Stroke.hairline)
        )
        .clipShape(Capsule(style: .continuous))
    }
}
