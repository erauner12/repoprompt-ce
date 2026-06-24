import AppKit
import Combine
import Foundation

@MainActor
final class CoordinatorMissionTemplateStore: ObservableObject {
    static let shared = CoordinatorMissionTemplateStore()

    @Published private(set) var customTemplates: [CoordinatorMissionTemplate] = []

    private let directoryURL: URL
    private var fileURLsByID: [UUID: URL] = [:]

    var builtInTemplates: [CoordinatorMissionTemplate] {
        [.scopedChange, .deepPlanOrchestrateReview]
    }

    var allTemplates: [CoordinatorMissionTemplate] {
        builtInTemplates + customTemplates
    }

    static var templatesDirectoryURL: URL {
        MCPFilesystemConstants.identity.applicationSupportRootURL()
            .appendingPathComponent("CoordinatorMissionTemplates", isDirectory: true)
    }

    convenience init() {
        self.init(directoryURL: Self.templatesDirectoryURL)
    }

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else {
            customTemplates = []
            fileURLsByID = [:]
            return
        }

        do {
            let files = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey])
                .filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var templates: [CoordinatorMissionTemplate] = []
            var urls: [UUID: URL] = [:]
            for file in files {
                guard let template = parseTemplateFile(at: file),
                      let customID = template.customID
                else { continue }
                templates.append(template)
                urls[customID] = file
            }
            customTemplates = templates
            fileURLsByID = urls
        } catch {
            print("[CoordinatorMissionTemplateStore] Failed to list templates: \(error)")
        }
    }

    @discardableResult
    func createTemplate(name: String) throws -> CoordinatorMissionTemplate {
        let id = UUID()
        let content = Self.generateMarkdown(
            id: id,
            name: name,
            icon: "sparkles",
            accentColor: "#0A84FF",
            tooltip: "Custom Coordinator Mission template",
            description: "Wraps a new Coordinator Mission.",
            templateBody: """
            # \(name)

            $MISSION
            """
        )
        return try writeTemplateFile(id: id, name: name, content: content)
    }

    @discardableResult
    func cloneBuiltIn(_ template: CoordinatorMissionTemplate, name: String) throws -> CoordinatorMissionTemplate {
        let id = UUID()
        let content = Self.generateMarkdown(
            id: id,
            name: name,
            icon: template.iconName,
            accentColor: template.accentColorHex,
            tooltip: template.tooltipText,
            description: template.descriptionText,
            templateBody: CoordinatorMissionTemplate.stripYAMLFrontmatter(template.template)
        )
        return try writeTemplateFile(id: id, name: name, content: content)
    }

    func deleteTemplate(_ template: CoordinatorMissionTemplate) throws {
        guard let url = fileURL(for: template) else { return }
        try FileManager.default.removeItem(at: url)
        refresh()
    }

    func fileURL(for template: CoordinatorMissionTemplate) -> URL? {
        guard let customID = template.customID else { return nil }
        return fileURLsByID[customID]
    }

    func markdown(for template: CoordinatorMissionTemplate) -> String {
        guard let url = fileURL(for: template),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return template.template }
        return content
    }

    @discardableResult
    func updateTemplate(_ template: CoordinatorMissionTemplate, markdown: String) throws -> CoordinatorMissionTemplate {
        guard let customID = template.customID,
              let url = fileURL(for: template)
        else { return template }
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        refresh()
        return customTemplates.first(where: { $0.customID == customID }) ?? template
    }

    func openInFinder() {
        try? ensureTemplatesDirectoryExists()
        NSWorkspace.shared.open(directoryURL)
    }

    func revealInFinder(_ template: CoordinatorMissionTemplate) {
        guard let url = fileURL(for: template) else {
            openInFinder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func parseTemplateFile(at url: URL) -> CoordinatorMissionTemplate? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let parsed = Self.parseFrontmatter(content)
        let id = parsed.frontmatter["id"].flatMap(UUID.init(uuidString:))
            ?? uuidFromFilename(url)
            ?? UUID(uuidString: deterministicUUID(from: url.lastPathComponent))
            ?? UUID()
        let name = parsed.frontmatter["name"] ?? url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized

        return CoordinatorMissionTemplate(
            source: .custom(id),
            displayName: name,
            iconName: parsed.frontmatter["icon"] ?? "sparkles",
            accentColorHex: parsed.frontmatter["accent_color"],
            tooltipText: parsed.frontmatter["tooltip"],
            descriptionText: parsed.frontmatter["description"],
            template: content
        )
    }

    private static func parseFrontmatter(_ content: String) -> (frontmatter: [String: String], body: String) {
        var frontmatter: [String: String] = [:]
        var body = content

        if content.hasPrefix("---") {
            let searchRange = content.index(content.startIndex, offsetBy: 3) ..< content.endIndex
            if let closingRange = content.range(of: "\n---", range: searchRange) {
                let text = String(content[content.index(content.startIndex, offsetBy: 3) ..< closingRange.lowerBound])
                body = String(content[closingRange.upperBound...]).trimmingCharacters(in: .newlines)
                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let colon = trimmed.firstIndex(of: ":") else { continue }
                    let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                    var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    frontmatter[key] = value
                }
            }
        }

        return (frontmatter, body)
    }

    private func ensureTemplatesDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func writeTemplateFile(id: UUID, name: String, content: String) throws -> CoordinatorMissionTemplate {
        try ensureTemplatesDirectoryExists()
        let fileURL = uniqueTemplateFileURL(baseSlug: Self.sanitizedFilename(from: name))
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        refresh()
        return customTemplates.first(where: { $0.customID == id })
            ?? CoordinatorMissionTemplate(
                source: .custom(id),
                displayName: name,
                iconName: "sparkles",
                accentColorHex: nil,
                tooltipText: nil,
                descriptionText: nil,
                template: content
            )
    }

    private func uniqueTemplateFileURL(baseSlug: String) -> URL {
        let fm = FileManager.default
        var candidate = directoryURL.appendingPathComponent("\(baseSlug).md")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(baseSlug)-\(suffix).md")
            suffix += 1
        }
        return candidate
    }

    private func uuidFromFilename(_ url: URL) -> UUID? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("template-") else { return nil }
        return UUID(uuidString: String(stem.dropFirst("template-".count)))
    }

    private func deterministicUUID(from input: String) -> String {
        var hash: UInt64 = 5381
        for byte in input.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let hex = String(format: "%016llx", hash)
        let padded = hex.padding(toLength: 32, withPad: "0", startingAt: 0)
        let idx = padded.startIndex
        let i = { padded.index(idx, offsetBy: $0) }
        return "\(padded[idx ..< i(8)])-\(padded[i(8) ..< i(12)])-\(padded[i(12) ..< i(16)])-\(padded[i(16) ..< i(20)])-\(padded[i(20) ..< i(32)])"
    }

    private static func sanitizedFilename(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_ "))
        let sanitized = name.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(sanitized))
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return result.isEmpty ? "mission-template" : result
    }

    static func generateMarkdown(
        id: UUID,
        name: String,
        icon: String?,
        accentColor: String?,
        tooltip: String?,
        description: String?,
        templateBody: String
    ) -> String {
        var lines = ["---"]
        lines.append("id: \(id.uuidString)")
        lines.append("name: \"\(name)\"")
        if let icon { lines.append("icon: \"\(icon)\"") }
        if let accentColor { lines.append("accent_color: \"\(accentColor)\"") }
        if let tooltip { lines.append("tooltip: \"\(tooltip)\"") }
        if let description { lines.append("description: \"\(description)\"") }
        lines.append("---")
        lines.append("")
        lines.append(templateBody)
        return lines.joined(separator: "\n")
    }
}
