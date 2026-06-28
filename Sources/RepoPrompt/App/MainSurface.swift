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
