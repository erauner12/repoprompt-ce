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
        case .coordinatorMode: "Director"
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
    let surfaces: [MainSurface]

    @ObservedObject private var fontScale = FontScaleManager.shared

    init(
        selection: Binding<MainSurface>,
        isAvailable: Bool,
        surfaces: [MainSurface] = MainSurface.allCases
    ) {
        _selection = selection
        self.isAvailable = isAvailable
        self.surfaces = surfaces
    }

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var controlHeight: CGFloat {
        fontPreset.scaledClamped(34, min: 34, max: 42)
    }

    private var innerHeight: CGFloat {
        max(controlHeight - 8, 26)
    }

    private var horizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var labelFont: Font {
        fontPreset.swiftUIFont(sizeAtNormal: 12.5, weight: .semibold)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(surfaces) { surface in
                Button {
                    guard isAvailable else { return }
                    selection = surface
                } label: {
                    Text(surface.displayName)
                        .font(labelFont)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(maxWidth: .infinity)
                        .frame(height: innerHeight)
                        .padding(.horizontal, horizontalPadding)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == surface ? Color.accentColor : Color.secondary)
                .background(
                    Capsule(style: .continuous)
                        .fill(selection == surface ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
                .disabled(!isAvailable)
            }
        }
        .padding(4)
        .frame(height: controlHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.22))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.secondary.opacity(0.24), lineWidth: 0.75)
        )
        .clipShape(Capsule(style: .continuous))
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
            Toggle("Director", isOn: selectedBinding(for: .coordinatorMode))
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!canSwitch)

            Toggle("Agent Mode", isOn: selectedBinding(for: .agentMode))
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!canSwitch)
        }
    }

    private func selectedBinding(for surface: MainSurface) -> Binding<Bool> {
        Binding {
            mainSurfaceSelection?.wrappedValue == surface
        } set: { isOn in
            guard isOn else { return }
            mainSurfaceSelection?.wrappedValue = surface
        }
    }
}
