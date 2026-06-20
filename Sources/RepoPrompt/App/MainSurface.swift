import SwiftUI

enum MainSurface: String, CaseIterable, Identifiable {
    case agentMode
    case coordinatorMode

    static let defaultSurface: MainSurface = .agentMode

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .agentMode: "Agent"
        case .coordinatorMode: "Coordinator"
        }
    }

    var systemImage: String {
        switch self {
        case .agentMode: "bubble.left.and.bubble.right"
        case .coordinatorMode: "rectangle.3.group"
        }
    }
}

struct MainSurfaceSegmentedSwitcher: View {
    @Binding var selection: MainSurface
    let isAvailable: Bool

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var controlHeight: CGFloat {
        fontPreset.scaledClamped(30, min: 30, max: 38)
    }

    private var cornerRadius: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var horizontalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 10)
    }

    private var labelFont: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainSurface.allCases) { surface in
                Button {
                    guard isAvailable else { return }
                    selection = surface
                } label: {
                    Text(surface.displayName)
                        .font(labelFont)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(maxWidth: .infinity)
                        .frame(height: controlHeight - 6)
                        .padding(.horizontal, horizontalPadding)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == surface ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: max(cornerRadius - 3, 6), style: .continuous)
                        .fill(selection == surface ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
                .disabled(!isAvailable)
            }
        }
        .padding(3)
        .frame(height: controlHeight)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .opacity(isAvailable ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main surface")
    }
}

private struct MainSurfaceSelectionFocusedKey: FocusedValueKey {
    typealias Value = Binding<MainSurface>
}

private struct MainSurfaceSwitchingAvailableFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var mainSurfaceSelection: Binding<MainSurface>? {
        get { self[MainSurfaceSelectionFocusedKey.self] }
        set { self[MainSurfaceSelectionFocusedKey.self] = newValue }
    }

    var isMainSurfaceSwitchingAvailable: Bool? {
        get { self[MainSurfaceSwitchingAvailableFocusedKey.self] }
        set { self[MainSurfaceSwitchingAvailableFocusedKey.self] = newValue }
    }
}

struct MainSurfaceCommands: Commands {
    @FocusedValue(\.mainSurfaceSelection) private var mainSurfaceSelection
    @FocusedValue(\.isMainSurfaceSwitchingAvailable) private var isMainSurfaceSwitchingAvailable

    private var canSwitch: Bool {
        isMainSurfaceSwitchingAvailable == true && mainSurfaceSelection != nil
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Show Agent Mode") {
                mainSurfaceSelection?.wrappedValue = .agentMode
            }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(!canSwitch)

            Button("Show Coordinator") {
                mainSurfaceSelection?.wrappedValue = .coordinatorMode
            }
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(!canSwitch)
        }
    }
}
