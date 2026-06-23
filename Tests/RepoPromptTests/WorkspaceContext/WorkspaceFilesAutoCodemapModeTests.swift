import Combine
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceFilesAutoCodemapModeTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testSelectionProjectionRevisionEmitsSynchronouslyOnceForSelectionBatch() {
        let fixture = makeFixture(fileName: "First.swift")
        let secondFile = FileViewModel(
            file: File(
                name: "Second.swift",
                path: URL(fileURLWithPath: fixture.file.rootFolderPath)
                    .appendingPathComponent("Second.swift").path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: fixture.file.rootFolderPath,
            rootIdentifier: fixture.file.rootIdentifier,
            rootFolderPath: fixture.file.rootFolderPath,
            fileSystemService: nil
        )
        var revisions: [UInt64] = []
        var snapshots: [StoredSelection] = []
        let cancellable = fixture.viewModel.selectionProjectionRevisionPublisher
            .sink { revision in
                revisions.append(revision)
                snapshots.append(fixture.viewModel.snapshotSelection())
            }
        defer { cancellable.cancel() }

        fixture.viewModel.performSelectionBatch {
            fixture.viewModel.selectFileForTesting(fixture.file)
            fixture.viewModel.selectFileForTesting(secondFile)
            XCTAssertTrue(revisions.isEmpty)
        }

        XCTAssertEqual(revisions, [1])
        XCTAssertEqual(Set(snapshots.first?.selectedPaths ?? []), Set([
            fixture.file.standardizedFullPath,
            secondFile.standardizedFullPath
        ]))
    }

    func testSelectionProjectionRevisionCoversCodemapModeAndSlicesWithoutDuplicates() {
        let fixture = makeFixture(fileName: "Selection.swift")
        fixture.viewModel.selectFileForTesting(fixture.file)
        let initialRevision = fixture.viewModel.selectionStateRevision
        var revisions: [UInt64] = []
        let cancellable = fixture.viewModel.selectionProjectionRevisionPublisher
            .sink { revisions.append($0) }
        defer { cancellable.cancel() }

        fixture.viewModel.codemapAutoEnabled = false
        XCTAssertEqual(revisions, [initialRevision + 1])
        fixture.viewModel.codemapAutoEnabled = false
        XCTAssertEqual(revisions, [initialRevision + 1])

        let slice = LineRange(start: 1, end: 2)
        fixture.viewModel.seedSelectionSlicesForTesting([slice], for: fixture.file)
        XCTAssertEqual(revisions, [initialRevision + 1, initialRevision + 2])
        fixture.viewModel.seedSelectionSlicesForTesting([slice], for: fixture.file)
        XCTAssertEqual(revisions, [initialRevision + 1, initialRevision + 2])
        XCTAssertEqual(fixture.viewModel.snapshotSelection().slices[fixture.file.standardizedFullPath], [slice])
    }

    func testSelectionProjectionRevisionCoalescesMultiDimensionCodemapMutation() {
        let fixture = makeFixture(fileName: "Codemap.swift")
        fixture.viewModel.selectFileForTesting(fixture.file)
        fixture.viewModel.seedSelectionSlicesForTesting([LineRange(start: 1, end: 2)], for: fixture.file)
        var revisions: [UInt64] = []
        var snapshots: [StoredSelection] = []
        let cancellable = fixture.viewModel.selectionProjectionRevisionPublisher
            .sink { revision in
                revisions.append(revision)
                snapshots.append(fixture.viewModel.snapshotSelection())
            }
        defer { cancellable.cancel() }

        fixture.viewModel.setFileAsCodemap(fixture.file)

        let finalRevision = fixture.viewModel.selectionStateRevision
        XCTAssertEqual(revisions, [finalRevision])
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].selectedPaths.isEmpty)
        XCTAssertTrue(snapshots[0].slices.isEmpty)
        XCTAssertEqual(snapshots[0].autoCodemapPaths, [fixture.file.standardizedFullPath])
        XCTAssertFalse(snapshots[0].codemapAutoEnabled)
        fixture.viewModel.setFileAsCodemap(fixture.file)
        XCTAssertEqual(revisions, [finalRevision])
    }

    func testBulkCodemapOnlySelectionEmitsOneFinalProjectionRevision() async {
        let fixture = makeFixture(fileName: "Seed.swift")
        let fileCount = 1000
        let files = (0 ..< fileCount).map { index in
            FileViewModel(
                file: File(
                    name: "File\(index).swift",
                    path: URL(fileURLWithPath: fixture.file.rootFolderPath)
                        .appendingPathComponent("File\(index).swift").path,
                    modificationDate: Date(timeIntervalSince1970: 1000)
                ),
                rootPath: fixture.file.rootFolderPath,
                rootIdentifier: fixture.file.rootIdentifier,
                rootFolderPath: fixture.file.rootFolderPath,
                fileSystemService: nil
            )
        }
        for file in files {
            file.setCodeMap(makeFileAPI(path: file.standardizedFullPath, symbolName: "symbol"))
            fixture.viewModel.injectIndexedFileForTesting(file)
        }

        var revisions: [UInt64] = []
        var snapshots: [StoredSelection] = []
        let cancellable = fixture.viewModel.selectionProjectionRevisionPublisher
            .sink { revision in
                revisions.append(revision)
                snapshots.append(fixture.viewModel.snapshotSelection())
            }
        defer { cancellable.cancel() }

        await fixture.viewModel.applyCodemapOnlySelection(paths: files.map(\.standardizedFullPath))

        XCTAssertEqual(revisions, [fixture.viewModel.selectionStateRevision])
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(Set(snapshots[0].autoCodemapPaths), Set(files.map(\.standardizedFullPath)))
        XCTAssertTrue(snapshots[0].selectedPaths.isEmpty)
        XCTAssertTrue(snapshots[0].slices.isEmpty)
        XCTAssertFalse(snapshots[0].codemapAutoEnabled)
    }

    func testBulkSlicePromotionAndFullClearEachEmitOneFinalProjectionRevision() async throws {
        #if DEBUG
            let rootURL = try temporaryRoots.makeRoot(suiteName: "BulkSliceProjection")
            let firstURL = rootURL.appendingPathComponent("First.swift")
            let secondURL = rootURL.appendingPathComponent("Second.swift")
            try "let first = true\n".write(to: firstURL, atomically: true, encoding: .utf8)
            try "let second = true\n".write(to: secondURL, atomically: true, encoding: .utf8)

            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            _ = try manager.attachRootShell(for: root, workspaceID: UUID())
            manager.setActiveTabID(UUID())
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                generation: 1,
                upsertedFiles: store.files(inRoot: root.id)
            ))

            let first = try XCTUnwrap(manager.findFileByFullPath(firstURL.path))
            let second = try XCTUnwrap(manager.findFileByFullPath(secondURL.path))
            manager.setFileAsCodemap(first)
            manager.setFileAsCodemap(second)

            var revisions: [UInt64] = []
            var snapshots: [StoredSelection] = []
            let cancellable = manager.selectionProjectionRevisionPublisher
                .sink { revision in
                    revisions.append(revision)
                    snapshots.append(manager.snapshotSelection())
                }
            defer { cancellable.cancel() }

            _ = try await manager.setSelectionSlices(
                entries: [
                    .init(path: firstURL.path, ranges: [LineRange(start: 1, end: 1)]),
                    .init(path: secondURL.path, ranges: [LineRange(start: 1, end: 1)])
                ],
                mode: .set,
                persistWorkspace: false
            )

            XCTAssertEqual(revisions, [manager.selectionStateRevision])
            XCTAssertEqual(snapshots.count, 1)
            XCTAssertEqual(Set(snapshots[0].selectedPaths), Set([first.standardizedFullPath, second.standardizedFullPath]))
            XCTAssertEqual(Set(snapshots[0].slices.keys), Set([first.standardizedFullPath, second.standardizedFullPath]))
            XCTAssertTrue(snapshots[0].autoCodemapPaths.isEmpty)
            XCTAssertFalse(snapshots[0].codemapAutoEnabled)

            manager.setFileAsCodemap(second)
            revisions.removeAll()
            snapshots.removeAll()

            await manager.clearSelection()

            XCTAssertEqual(revisions, [manager.selectionStateRevision])
            XCTAssertEqual(snapshots, [StoredSelection()])

            await manager.unloadAllRootFolders()
        #endif
    }

    func testExplicitCodemapRemovalDisablesAutoForPresentAndEmptySelections() {
        do {
            let fixture = makeFixture(fileName: "Present.swift")
            fixture.viewModel.setFileAsCodemap(fixture.file)
            fixture.viewModel.codemapAutoEnabled = true

            fixture.viewModel.removeCodemapFile(fixture.file)

            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertFalse(fixture.viewModel.isAutoCodemapFile(fixture.file))
        }

        do {
            let fixture = makeFixture(fileName: "Empty.swift")
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)

            fixture.viewModel.clearAutoCodemapFiles()

            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        }

        do {
            let fixture = makeFixture(fileName: "Absent.swift")

            fixture.viewModel.removeCodemapFile(fixture.file)

            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        }
    }

    func testOrdinaryFileRemovalPreservesAutoAndFullClearRestoresIt() async {
        do {
            let fixture = makeFixture(fileName: "Selected.swift")
            fixture.viewModel.selectFileForTesting(fixture.file)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)

            fixture.viewModel.removeFileFromAllSelections(fixture.file)

            XCTAssertTrue(fixture.viewModel.selectedFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
        }

        do {
            let fixture = makeFixture(fileName: "Clear.swift")
            fixture.viewModel.setFileAsCodemap(fixture.file)
            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
            XCTAssertEqual(fixture.viewModel.autoCodemapFiles.map(\.id), [fixture.file.id])

            await fixture.viewModel.clearSelection()

            XCTAssertTrue(fixture.viewModel.selectedFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
        }
    }

    func testVisibleAutoCodemapExcludesSessionRootsAndPreservesSlicesAndManualMode() async throws {
        #if DEBUG
            let visibleRootURL = try temporaryRoots.makeRoot(suiteName: "VisibleAutoCodemapRoot")
            let hiddenRootURL = try temporaryRoots.makeRoot(suiteName: "HiddenAutoCodemapWorktree")
            let selectedURL = visibleRootURL.appendingPathComponent("Selected.swift")
            let visibleDependencyURL = visibleRootURL.appendingPathComponent("VisibleDependency.swift")
            let hiddenDependencyURL = hiddenRootURL.appendingPathComponent("HiddenDependency.swift")
            try "let selected = true\n".write(to: selectedURL, atomically: true, encoding: .utf8)
            try "struct DependencyType {}\n".write(to: visibleDependencyURL, atomically: true, encoding: .utf8)
            try "struct DependencyType {}\n".write(to: hiddenDependencyURL, atomically: true, encoding: .utf8)

            let store = WorkspaceFileContextStore()
            let visibleRoot = try await store.loadRoot(path: visibleRootURL.path)
            let hiddenRoot = try await store.loadRoot(path: hiddenRootURL.path, kind: .sessionWorktree)
            let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
            await manager.setCodeScanEnabled(false)
            _ = try manager.attachRootShell(for: visibleRoot, workspaceID: UUID())
            _ = try manager.attachRootShell(for: hiddenRoot, workspaceID: UUID())

            let visibleRecords = await store.files(inRoot: visibleRoot.id)
            let hiddenRecords = await store.files(inRoot: hiddenRoot.id)
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: visibleRoot.id,
                rootPath: visibleRoot.standardizedFullPath,
                generation: 1,
                upsertedFiles: visibleRecords
            ))
            await manager.applyWorkspaceAppliedIndexEventForTesting(WorkspaceAppliedIndexBatchEvent(
                rootID: hiddenRoot.id,
                rootPath: hiddenRoot.standardizedFullPath,
                generation: 1,
                upsertedFiles: hiddenRecords
            ))

            let selected = try XCTUnwrap(manager.findFileByFullPath(selectedURL.path))
            let visibleDependency = try XCTUnwrap(manager.findFileByFullPath(visibleDependencyURL.path))
            let hiddenDependency = try XCTUnwrap(manager.findFileByFullPath(hiddenDependencyURL.path))
            XCTAssertLessThan(hiddenDependency.standardizedFullPath, visibleDependency.standardizedFullPath)
            let selectedAPI = makeFileAPI(
                path: selectedURL.path,
                symbolName: "selectedSymbol",
                referencedTypes: ["DependencyType"]
            )
            let visibleAPI = makeFileAPI(
                path: visibleDependencyURL.path,
                symbolName: "visibleDependencySymbol",
                className: "DependencyType"
            )
            let hiddenAPI = makeFileAPI(
                path: hiddenDependencyURL.path,
                symbolName: "hiddenDependencySymbol",
                className: "DependencyType"
            )
            selected.setCodeMap(selectedAPI)
            visibleDependency.setCodeMap(visibleAPI)
            hiddenDependency.setCodeMap(hiddenAPI)
            await store.applyObservedCodemapResults([
                WorkspaceObservedCodemapResult(fullPath: selectedURL.path, modificationDate: Date(), fileAPI: selectedAPI),
                WorkspaceObservedCodemapResult(fullPath: visibleDependencyURL.path, modificationDate: Date(), fileAPI: visibleAPI),
                WorkspaceObservedCodemapResult(fullPath: hiddenDependencyURL.path, modificationDate: Date(), fileAPI: hiddenAPI)
            ])

            manager.selectFileForTesting(selected)
            let slice = LineRange(start: 1, end: 1)
            manager.seedSelectionSlicesForTesting([slice], for: selected)
            await manager.flushAutoCodemapSyncNowIfNeeded()

            let automatic = manager.snapshotSelection()
            XCTAssertEqual(automatic.autoCodemapPaths, [visibleDependency.standardizedFullPath])
            XCTAssertFalse(automatic.autoCodemapPaths.contains(hiddenDependency.standardizedFullPath))
            XCTAssertEqual(automatic.slices[selected.standardizedFullPath], [slice])
            XCTAssertTrue(automatic.codemapAutoEnabled)

            manager.setFileAsCodemap(visibleDependency)
            let manualBeforeFlush = manager.snapshotSelection()
            await manager.flushAutoCodemapSyncNowIfNeeded()
            let manualAfterFlush = manager.snapshotSelection()
            XCTAssertFalse(manualAfterFlush.codemapAutoEnabled)
            XCTAssertEqual(manualAfterFlush.autoCodemapPaths, manualBeforeFlush.autoCodemapPaths)
            XCTAssertEqual(manualAfterFlush.slices, manualBeforeFlush.slices)

            await manager.unloadAllRootFolders()
        #endif
    }

    private func makeFixture(fileName: String) -> (
        viewModel: WorkspaceFilesViewModel,
        file: FileViewModel
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilesAutoCodemapModeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootID = UUID()
        let file = FileViewModel(
            file: File(
                name: fileName,
                path: rootURL.appendingPathComponent(fileName).path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: rootURL.path,
            rootIdentifier: rootID,
            rootFolderPath: rootURL.path,
            fileSystemService: nil
        )
        return (WorkspaceFilesViewModel(), file)
    }

    private func makeFileAPI(
        path: String,
        symbolName: String,
        className: String? = nil,
        referencedTypes: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: className.map { [ClassInfo(name: $0, methods: [], properties: [])] } ?? [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: referencedTypes
        )
    }
}
