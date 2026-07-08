import Foundation

enum AgentScriptedChildModelID {
    static let selector = "scripted"
    static let modelRaw = "__repoprompt_director_e2e_scripted_child_v1"

    static func isScriptedSelector(_ raw: String?) -> Bool {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(selector) == .orderedSame
    }

    static func isScriptedModelRaw(_ raw: String?) -> Bool {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(modelRaw) == .orderedSame
    }
}
