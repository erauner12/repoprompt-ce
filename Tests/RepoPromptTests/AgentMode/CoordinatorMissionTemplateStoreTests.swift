@testable import RepoPrompt
import XCTest

@MainActor
final class CoordinatorMissionTemplateStoreTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorMissionTemplateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        directoryURL = nil
        try super.tearDownWithError()
    }

    func testBuiltInScopedChangeAppears() {
        let store = CoordinatorMissionTemplateStore(directoryURL: directoryURL)

        XCTAssertEqual(store.builtInTemplates.map(\.displayName), [
            "Scoped Change",
            "Deep Plan -> Orchestrate -> Review"
        ])
        XCTAssertTrue(store.allTemplates.contains(.scopedChange))
        XCTAssertTrue(store.allTemplates.contains(.deepPlanOrchestrateReview))
    }

    func testBuiltInDeepPlanOrchestrateReviewWrapsWorkflowStages() {
        let wrapped = CoordinatorMissionTemplate.deepPlanOrchestrateReview.wrap("ship the coordinator demo")

        XCTAssertTrue(wrapped.contains("Deep Plan"))
        XCTAssertTrue(wrapped.contains("Orchestrate"))
        XCTAssertTrue(wrapped.contains("Review"))
        XCTAssertTrue(wrapped.contains("durable primary implementation lane"))
        XCTAssertTrue(wrapped.contains("fix loop"))
        XCTAssertTrue(wrapped.contains("ship the coordinator demo"))
    }

    func testCustomMarkdownParsesFrontmatter() throws {
        let id = UUID()
        let markdown = """
        ---
        id: \(id.uuidString)
        name: "Demo Template"
        icon: "wand.and.stars"
        accent_color: "#FF00AA"
        tooltip: "Tooltip"
        description: "Description"
        ---

        Please do this:
        $MISSION
        """
        try markdown.write(to: directoryURL.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        let store = CoordinatorMissionTemplateStore(directoryURL: directoryURL)

        let template = try XCTUnwrap(store.customTemplates.first)
        XCTAssertEqual(template.customID, id)
        XCTAssertEqual(template.displayName, "Demo Template")
        XCTAssertEqual(template.iconName, "wand.and.stars")
        XCTAssertEqual(template.accentColorHex, "#FF00AA")
        XCTAssertEqual(template.tooltipText, "Tooltip")
        XCTAssertEqual(template.descriptionText, "Description")
        XCTAssertEqual(template.wrap("ship it"), "Please do this:\nship it")
    }

    func testCreateCloneAndDeleteCustomTemplates() throws {
        let store = CoordinatorMissionTemplateStore(directoryURL: directoryURL)

        let created = try store.createTemplate(name: "Fresh Mission")
        XCTAssertEqual(store.customTemplates.map(\.displayName), ["Fresh Mission"])
        XCTAssertNotNil(store.fileURL(for: created))

        let cloned = try store.cloneBuiltIn(.scopedChange, name: "Scoped Custom")
        XCTAssertEqual(Set(store.customTemplates.map(\.displayName)), ["Fresh Mission", "Scoped Custom"])
        XCTAssertTrue(cloned.wrap("tight change").contains("Run this as a scoped Coordinator change."))
        XCTAssertTrue(cloned.wrap("tight change").contains("tight change"))

        try store.deleteTemplate(created)
        XCTAssertEqual(store.customTemplates.map(\.displayName), ["Scoped Custom"])
        XCTAssertNil(store.fileURL(for: created))
    }

    func testUpdateTemplateSavesMarkdownAndRefreshesMetadata() throws {
        let store = CoordinatorMissionTemplateStore(directoryURL: directoryURL)
        let template = try store.createTemplate(name: "Editable")
        let updatedMarkdown = try """
        ---
        id: \(XCTUnwrap(template.customID).uuidString)
        name: "Edited"
        icon: "pencil"
        accent_color: "#00FF00"
        tooltip: "Edited tooltip"
        description: "Edited description"
        ---

        Edited body:
        $MISSION
        """

        let updated = try store.updateTemplate(template, markdown: updatedMarkdown)

        XCTAssertEqual(updated.displayName, "Edited")
        XCTAssertEqual(updated.iconName, "pencil")
        XCTAssertEqual(updated.accentColorHex, "#00FF00")
        XCTAssertEqual(updated.tooltipText, "Edited tooltip")
        XCTAssertEqual(updated.descriptionText, "Edited description")
        XCTAssertEqual(store.markdown(for: updated), updatedMarkdown)
        XCTAssertEqual(updated.wrap("demo"), "Edited body:\ndemo")
    }

    func testMissionAndArgumentsPlaceholdersAndAppendFallback() {
        XCTAssertEqual(
            CoordinatorMissionTemplate.wrap(template: "Plan:\n$MISSION", missionText: "fix docs"),
            "Plan:\nfix docs"
        )
        XCTAssertEqual(
            CoordinatorMissionTemplate.wrap(template: "Plan:\n$ARGUMENTS", missionText: "fix tests"),
            "Plan:\nfix tests"
        )
        XCTAssertEqual(
            CoordinatorMissionTemplate.wrap(template: "Plan first.", missionText: "then run review"),
            "Plan first.\n\nthen run review"
        )
    }
}
