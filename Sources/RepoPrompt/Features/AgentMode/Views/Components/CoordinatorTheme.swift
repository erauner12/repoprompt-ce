import SwiftUI

// MARK: - Coordinator/Director visual tokens

/// Shared visual language for Coordinator-backed Director surfaces.
///
/// Swift symbols intentionally stay Coordinator-named while user-facing copy remains Director.
/// The palette is anchored to the Command Center mock's dark panel language so future parity
/// waves can reuse the same card, pill, and status primitives instead of restyling per view.
enum CoordinatorTheme {
    enum Palette {
        static let windowBackground = Color(hex: "#17191B") ?? Color(nsColor: .windowBackgroundColor)
        static let panelBackground = Color(hex: "#202326") ?? Color(nsColor: .controlBackgroundColor)
        static let elevatedPanelBackground = Color(hex: "#25292D") ?? Color(nsColor: .controlBackgroundColor)
        static let recessedPanelBackground = Color(hex: "#151719") ?? Color(nsColor: .windowBackgroundColor)
        static let hairline = Color.white.opacity(0.10)
        static let strongHairline = Color.white.opacity(0.16)
        static let seam = Color.white.opacity(0.08)
        static let shadow = Color.black.opacity(0.30)

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
        static let cardFill = 0.76
        static let groupedFill = 0.54
        static let railCardFill = 0.62
        static let emptyColumnFill = 0.34
        static let statusChipFill = 0.15
        static let statusChipStroke = 0.34
        static let listRowFill = 0.40
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
        .background(Capsule(style: .continuous).fill(tint.opacity(0.13)))
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: 0.5)
        )
    }
}

extension View {
    func coordinatorThemeControlCapsule() -> some View {
        background(
            Capsule(style: .continuous)
                .fill(CoordinatorTheme.Palette.elevatedPanelBackground.opacity(0.86))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(CoordinatorTheme.Palette.strongHairline, lineWidth: CoordinatorTheme.Stroke.hairline)
        )
        .clipShape(Capsule(style: .continuous))
    }
}
