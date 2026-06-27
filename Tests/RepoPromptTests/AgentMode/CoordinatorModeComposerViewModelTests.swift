@testable import RepoPrompt
import XCTest

@MainActor
final class CoordinatorModeComposerViewModelTests: XCTestCase {
    func testAcceptedDirectiveUsesSubmitterEchoesIntoRailAndKeepsSnapshotRowsReadOnly() async {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let coordinatorTab = uuid(101)
        let childTab = uuid(102)
        let input = input(
            persisted: [
                persisted(id: childID, tab: childTab, title: "Child", updatedAt: date(10), parent: coordinatorID)
            ],
            live: [
                live(id: coordinatorID, tab: coordinatorTab, title: "Coordinator", updatedAt: date(20), state: .idle, isMCP: true)
            ]
        )
        var submissions: [(text: String, sessionID: UUID)] = []
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                next.selectedCoordinatorID = selectedCoordinatorID
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { text, sessionID in
                submissions.append((text, sessionID))
                return .accepted
            }
        )
        viewModel.refresh()
        let rowsBeforeSubmit = viewModel.snapshot.groups

        let result = await viewModel.submitCoordinatorDirective("  Coordinate the child session  ")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.text, "Coordinate the child session")
        XCTAssertEqual(submissions.first?.sessionID, coordinatorID)
        XCTAssertEqual(viewModel.railTranscriptEntries.map(\.text), ["Coordinate the child session"])
        XCTAssertEqual(viewModel.snapshot.groups, rowsBeforeSubmit)

        viewModel.clearCoordinatorRailTranscript()
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertNil(viewModel.composerNotice)
    }

    func testMidRunCoordinatorRejectsDirectiveWithoutCallingSubmitter() async {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let input = input(
            persisted: [
                persisted(id: childID, tab: uuid(102), title: "Child", updatedAt: date(10), parent: coordinatorID)
            ],
            live: [
                live(id: coordinatorID, tab: uuid(101), title: "Coordinator", updatedAt: date(20), state: .running, isMCP: true)
            ]
        )
        var submitterCalled = false
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                next.selectedCoordinatorID = selectedCoordinatorID
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { _, _ in
                submitterCalled = true
                return .accepted
            }
        )
        viewModel.refresh()
        XCTAssertTrue(viewModel.snapshot.coordinatorRail.isComposerEnabled)
        XCTAssertFalse(viewModel.snapshot.coordinatorRail.isComposerSendEnabled)

        let result = await viewModel.submitCoordinatorDirective("message")

        XCTAssertEqual(result, .rejected(message: "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary."))
        XCTAssertFalse(submitterCalled)
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
    }

    func testUnreachableCoordinatorRejectsDirectiveWithoutCallingSubmitter() async {
        let coordinatorID = uuid(1)
        let childID = uuid(2)
        let input = input(persisted: [
            persisted(id: coordinatorID, tab: uuid(101), title: "Coordinator", updatedAt: date(20), isMCP: true),
            persisted(id: childID, tab: uuid(102), title: "Child", updatedAt: date(10), parent: coordinatorID)
        ])
        var submitterCalled = false
        let viewModel = CoordinatorModeViewModel(
            inputProvider: { sortMode, selectedCoordinatorID in
                var next = input
                next.sortMode = sortMode
                next.selectedCoordinatorID = selectedCoordinatorID
                return next
            },
            dashboardVisibilityHandler: { _ in },
            directiveSubmitter: { _, _ in
                submitterCalled = true
                return .accepted
            }
        )
        viewModel.refresh()
        XCTAssertFalse(viewModel.snapshot.coordinatorRail.isComposerEnabled)

        let result = await viewModel.submitCoordinatorDirective("message")

        XCTAssertEqual(result, .rejected(message: "Open agent chat to message this Coordinator."))
        XCTAssertFalse(submitterCalled)
        XCTAssertTrue(viewModel.railTranscriptEntries.isEmpty)
        XCTAssertEqual(viewModel.composerNotice, "Open agent chat to message this Coordinator.")
    }

    private func input(
        workspaceID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000090"),
        persisted: [CoordinatorModeSnapshotProjector.PersistedSession] = [],
        live: [CoordinatorModeSnapshotProjector.LiveSession] = [],
        selectedCoordinatorID: UUID? = nil,
        sort: CoordinatorModeSortMode = .lastUpdated
    ) -> CoordinatorModeSnapshotProjector.Input {
        CoordinatorModeSnapshotProjector.Input(
            workspaceID: workspaceID,
            windowID: 7,
            persistedSessions: persisted,
            liveSessions: live,
            selectedCoordinatorID: selectedCoordinatorID,
            sortMode: sort,
            resolvableTabIDs: Set(persisted.map(\.tabID) + live.map(\.tabID))
        )
    }

    private func persisted(
        id: UUID,
        tab: UUID,
        title: String,
        updatedAt: Date,
        state: AgentSessionRunState? = .idle,
        parent: UUID? = nil,
        isMCP: Bool = false
    ) -> CoordinatorModeSnapshotProjector.PersistedSession {
        CoordinatorModeSnapshotProjector.PersistedSession(
            id: id,
            tabID: tab,
            title: title,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP
        )
    }

    private func live(
        id: UUID,
        tab: UUID,
        title: String,
        updatedAt: Date,
        state: AgentSessionRunState,
        parent: UUID? = nil,
        isMCP: Bool = false
    ) -> CoordinatorModeSnapshotProjector.LiveSession {
        CoordinatorModeSnapshotProjector.LiveSession(
            sessionID: id,
            tabID: tab,
            title: title,
            updatedAt: updatedAt,
            runState: state,
            parentSessionID: parent,
            isMCPOriginated: isMCP
        )
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
