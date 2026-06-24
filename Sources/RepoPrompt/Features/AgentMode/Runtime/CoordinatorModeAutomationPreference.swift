import Foundation

enum CoordinatorModeAutomationPreference {
    static let defaultsKey = "CoordinatorMode.usesAutoMode"
    static let legacyDefaultsKey = "CoordinatorMode.allowsProactiveFollowThrough"
    static let defaultValue = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool
            ?? defaults.object(forKey: legacyDefaultsKey) as? Bool
            ?? defaultValue
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: defaultsKey)
    }
}
