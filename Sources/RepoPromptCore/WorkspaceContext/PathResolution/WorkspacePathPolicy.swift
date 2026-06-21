import Foundation

package struct WorkspaceRootRef: Hashable {
    package let id: UUID
    package let name: String
    package let fullPath: String
    package let standardizedFullPath: String

    package init(id: UUID, name: String, fullPath: String) {
        self.id = id
        self.name = name
        self.fullPath = fullPath
        standardizedFullPath = StandardizedPath.absolute(fullPath)
    }

    package var compatibilityAlias: String {
        (standardizedFullPath as NSString).lastPathComponent
    }
}

package enum RootAliasResolution: Equatable {
    case notAliasPrefixed
    case bareRoot(root: WorkspaceRootRef, alias: String)
    case prefixed(root: WorkspaceRootRef, alias: String, remainder: String)
    case ambiguous(alias: String, matchingRoots: [WorkspaceRootRef])
}

package struct RootAliasOptions {
    package let requireRemainder: Bool
    package let allowCompatibilityAlias: Bool
    /// When true, suppresses alias interpretation only if a same-name top-level subpath
    /// exists under the matched root. This is a shallow top-level check only; it does not
    /// compare the full remainder chain or score deeper structure.
    /// Tool-create flows use richer literal-vs-alias depth scoring in
    /// `WorkspaceFilesViewModel.resolvedLiteralCreateResult(...)`.
    package let disambiguateRealSubpath: Bool

    package init(
        requireRemainder: Bool,
        allowCompatibilityAlias: Bool = true,
        disambiguateRealSubpath: Bool = false
    ) {
        self.requireRemainder = requireRemainder
        self.allowCompatibilityAlias = allowCompatibilityAlias
        self.disambiguateRealSubpath = disambiguateRealSubpath
    }
}

package enum PathResolutionIssue: Equatable {
    case emptyInput
    case invalidPathCharacters(input: String, reason: String)
    case ambiguousAlias(alias: String, matchingRoots: [WorkspaceRootRef])
    case ambiguousRootMatch(input: String, candidateRoots: [WorkspaceRootRef])
    case pathOutsideWorkspace(input: String, visibleRoots: [WorkspaceRootRef])
    case destinationOutsideSourceRoot(input: String, sourceRoot: WorkspaceRootRef)
    case unsupportedPseudoAbsoluteAlias(input: String)
    case unresolved(input: String)
}

package enum ClientPathFormatter {
    package static func displayPath(
        root: WorkspaceRootRef,
        relativePath: String,
        visibleRoots: [WorkspaceRootRef]
    ) -> String {
        let standardizedRelative = StandardizedPath.relative(relativePath)
        if visibleRoots.count <= 1 {
            return standardizedRelative.isEmpty ? root.name : standardizedRelative
        }

        let canonicalMatches = visibleRoots.filter { $0.name.caseInsensitiveCompare(root.name) == .orderedSame }
        if canonicalMatches.count == 1 {
            return standardizedRelative.isEmpty ? root.name : "\(root.name)/\(standardizedRelative)"
        }

        if standardizedRelative.isEmpty {
            return root.standardizedFullPath
        }
        return StandardizedPath.join(
            standardizedRoot: root.standardizedFullPath,
            standardizedRelativePath: standardizedRelative
        )
    }

    package static func displayAbsolutePath(
        fullPath: String,
        visibleRoots: [WorkspaceRootRef]
    ) -> String {
        let standardized = StandardizedPath.absolute(fullPath)
        let matchingRoot = visibleRoots
            .filter {
                let root = $0.standardizedFullPath
                return standardized == root || standardized.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        guard let root = matchingRoot else { return standardized }
        let relative = String(standardized.dropFirst(root.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return displayPath(root: root, relativePath: relative, visibleRoots: visibleRoots)
    }
}
