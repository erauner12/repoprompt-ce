import Foundation

enum CoordinatorModeFollowThroughPreference {
    static let defaultsKey = "CoordinatorMode.allowsProactiveFollowThrough"
    static let defaultValue = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? defaultValue
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: defaultsKey)
    }
}
