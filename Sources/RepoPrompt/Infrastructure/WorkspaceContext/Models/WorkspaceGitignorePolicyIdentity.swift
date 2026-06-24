import Foundation

enum WorkspaceGitignorePolicyIdentity: String, Hashable {
    case mandatoryV1 = "mandatory-gitignore-v1"

    static let current = WorkspaceGitignorePolicyIdentity.mandatoryV1
}
