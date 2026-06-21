import Foundation

extension WorkspaceRootRef {
    var renderedLabel: String {
        "\(name) → \(fullPath)"
    }
}

enum WorkspaceAliasResolver {
    static func resolve(
        userPath: String,
        roots: [WorkspaceRootRef],
        options: RootAliasOptions,
        rootHasRealSubpath: ((WorkspaceRootRef, String) -> Bool)? = nil
    ) -> RootAliasResolution {
        let standardized = StandardizedPath.absolute(userPath)
        guard !standardized.hasPrefix("/") else { return .notAliasPrefixed }

        let candidate = standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !candidate.isEmpty else { return .notAliasPrefixed }

        let components = candidate.split(separator: "/").map(String.init)
        if options.requireRemainder {
            guard components.count >= 2 else { return .notAliasPrefixed }
        } else {
            guard !components.isEmpty else { return .notAliasPrefixed }
        }

        guard let alias = components.first, !alias.isEmpty else { return .notAliasPrefixed }
        guard !roots.isEmpty else { return .notAliasPrefixed }

        let canonicalMatches = roots.filter { $0.name.caseInsensitiveCompare(alias) == .orderedSame }
        if canonicalMatches.count > 1 {
            return .ambiguous(alias: alias, matchingRoots: canonicalMatches)
        }

        let resolvedRoot: WorkspaceRootRef?
        if let root = canonicalMatches.first {
            resolvedRoot = root
        } else if options.allowCompatibilityAlias {
            let compatibilityMatches = roots.filter {
                $0.compatibilityAlias.caseInsensitiveCompare(alias) == .orderedSame
            }
            if compatibilityMatches.count > 1 {
                return .ambiguous(alias: alias, matchingRoots: compatibilityMatches)
            }
            resolvedRoot = compatibilityMatches.first
        } else {
            resolvedRoot = nil
        }

        guard let root = resolvedRoot else { return .notAliasPrefixed }
        if options.disambiguateRealSubpath, rootHasRealSubpath?(root, alias) == true {
            return .notAliasPrefixed
        }

        let remainder = components.dropFirst().joined(separator: "/")
        if remainder.isEmpty {
            return .bareRoot(root: root, alias: alias)
        }
        return .prefixed(root: root, alias: alias, remainder: remainder)
    }
}

enum PathResolutionIssueRenderer {
    static func message(for issue: PathResolutionIssue) -> String {
        switch issue {
        case .emptyInput:
            return "Path is required."
        case let .invalidPathCharacters(input, reason):
            return "Path '\(StandardizedPath.diagnosticEscaped(input))' contains invalid characters: \(reason)."
        case let .ambiguousAlias(alias, matchingRoots):
            let rendered = matchingRoots.map(\.renderedLabel).joined(separator: "; ")
            return "Ambiguous root alias '\(alias)'. It matches multiple loaded roots: \(rendered). Use an absolute path or rename roots so aliases are unique."
        case let .ambiguousRootMatch(input, candidateRoots):
            let rendered = candidateRoots.map(\.renderedLabel).joined(separator: "; ")
            return "Path '\(input)' matches multiple workspace roots: \(rendered). Use a root-prefixed or absolute path to disambiguate."
        case let .pathOutsideWorkspace(input, visibleRoots):
            let rendered = visibleRoots.map(\.renderedLabel).joined(separator: "; ")
            return "The requested path '\(input)' is not inside any loaded folder. Loaded roots: \(rendered)."
        case let .destinationOutsideSourceRoot(input, sourceRoot):
            return "Path '\(input)' must remain inside the source root: \(sourceRoot.renderedLabel)."
        case let .unsupportedPseudoAbsoluteAlias(input):
            return "Path '\(input)' looks like '/RootName/...'. Drop the leading slash or use a true absolute path inside a loaded root."
        case let .unresolved(input):
            return "Could not resolve '\(input)' within the current workspace."
        }
    }
}
