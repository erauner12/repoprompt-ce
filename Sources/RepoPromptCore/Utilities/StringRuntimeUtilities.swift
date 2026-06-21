import Foundation
import RepoPromptC

package enum StringLineUtilities {
    package static func splitPreservingLineEndings(_ content: String) -> ([String], String) {
        content.withCString { contentPtr in
            guard let result = repo_split_content_preserving_endings(contentPtr) else { return ([], "\n") }
            defer { repo_free_split_result(result) }
            var lines: [String] = []
            lines.reserveCapacity(Int(result.pointee.line_count))
            for index in 0 ..< result.pointee.line_count {
                if let line = result.pointee.lines.advanced(by: Int(index)).pointee {
                    lines.append(String(cString: line))
                }
            }
            let ending = result.pointee.detected_ending != nil
                ? String(cString: result.pointee.detected_ending)
                : "\n"
            return (lines, ending)
        }
    }

    package static func splitPreservingAllLineEndings(_ content: String) -> [(line: String, ending: String)] {
        guard !content.isEmpty else { return [] }
        var result: [(String, String)] = []
        let scalars = content.unicodeScalars
        var lineStart = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\r" {
                let line = String(scalars[lineStart ..< index])
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    result.append((line, "\r\n"))
                    index = scalars.index(after: next)
                } else { result.append((line, "\r"))
                    index = next
                }
                lineStart = index
            } else if scalar == "\n" {
                result.append((String(scalars[lineStart ..< index]), "\n"))
                index = scalars.index(after: index)
                lineStart = index
            } else { index = scalars.index(after: index) }
        }
        if lineStart < scalars.endIndex { result.append((String(scalars[lineStart...]), "")) }
        return result
    }

    package static func fnv1a64(_ value: String) -> UInt64 {
        value.withCString { repo_fnv1a64($0) }
    }
}
