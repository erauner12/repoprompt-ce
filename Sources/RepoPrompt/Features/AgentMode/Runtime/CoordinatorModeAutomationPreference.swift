import Foundation

enum CoordinatorExecutionPace: String, Codable, Equatable, CaseIterable {
    case step
    case auto

    var usesAutoMode: Bool {
        self == .auto
    }
}

enum CoordinatorModeAutomationPreference {
    static let paceDefaultsKey = "CoordinatorMode.executionPace"
    static let defaultsKey = "CoordinatorMode.usesAutoMode"
    static let legacyDefaultsKey = "CoordinatorMode.allowsProactiveFollowThrough"
    static let defaultPace: CoordinatorExecutionPace = .step

    static func executionPace(defaults: UserDefaults = .standard) -> CoordinatorExecutionPace {
        if let rawValue = defaults.string(forKey: paceDefaultsKey),
           let pace = CoordinatorExecutionPace(rawValue: rawValue)
        {
            return pace
        }
        if let enabled = defaults.object(forKey: defaultsKey) as? Bool {
            return enabled ? .auto : .step
        }
        if let enabled = defaults.object(forKey: legacyDefaultsKey) as? Bool {
            return enabled ? .auto : .step
        }
        return defaultPace
    }

    static func setExecutionPace(_ pace: CoordinatorExecutionPace, defaults: UserDefaults = .standard) {
        defaults.set(pace.rawValue, forKey: paceDefaultsKey)
        defaults.set(pace.usesAutoMode, forKey: defaultsKey)
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        executionPace(defaults: defaults).usesAutoMode
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        setExecutionPace(isEnabled ? .auto : .step, defaults: defaults)
    }
}
