@testable import RepoPrompt
import XCTest

final class AgentWorktreeIndicatorTests: XCTestCase {
    func testCopyIdentityPrefersTrimmedWorktreeNameOverBranch() {
        let indicator = makeIndicator(
            worktreeName: "  rp-agent-feature  ",
            branch: "feature/branch"
        )

        XCTAssertEqual(indicator.copyIdentity?.value, "rp-agent-feature")
        XCTAssertEqual(indicator.copyIdentity?.source, .worktreeName)
    }

    func testCopyIdentityFallsBackToTrimmedBranch() {
        let indicator = makeIndicator(
            worktreeName: " \n\t ",
            branch: "  feature/branch  "
        )

        XCTAssertEqual(indicator.copyIdentity?.value, "feature/branch")
        XCTAssertEqual(indicator.copyIdentity?.source, .branch)
    }

    func testCopyIdentityIsNilWhenWorktreeNameAndBranchAreMissingOrBlank() {
        XCTAssertNil(makeIndicator(worktreeName: nil, branch: nil).copyIdentity)
        XCTAssertNil(makeIndicator(worktreeName: "  ", branch: "\n\t").copyIdentity)
    }

    func testCopyIdentityIgnoresVisualLabelAndResolvedLabelFallbacks() {
        let indicator = makeIndicator(
            worktreeName: nil,
            branch: nil,
            visualLabel: "Visual Alias",
            resolvedIdentityLabel: "Resolved Alias"
        )

        XCTAssertNil(indicator.copyIdentity)
        XCTAssertEqual(indicator.label, "Visual Alias")
    }

    func testCopyIdentityIgnoresOpaqueWorktreeIDSuffixFallback() {
        let indicator = makeIndicator(
            worktreeID: "wt_1234567890abcdef",
            worktreeName: nil,
            branch: nil,
            visualLabel: nil,
            resolvedIdentityLabel: nil
        )

        XCTAssertNil(indicator.copyIdentity)
        XCTAssertEqual(indicator.label, "90abcdef")
    }

    func testCopyIdentityDoesNotDependOnWorktreeAvailability() {
        let indicator = makeIndicator(
            worktreeName: "rp-agent-stale",
            branch: "feature/stale",
            isAvailable: false
        )

        XCTAssertFalse(indicator.isAvailable)
        XCTAssertEqual(indicator.copyIdentity?.value, "rp-agent-stale")
        XCTAssertEqual(indicator.copyIdentity?.source, .worktreeName)
    }

    private func makeIndicator(
        worktreeID: String = "wt_feature123",
        worktreeName: String?,
        branch: String?,
        visualLabel: String? = nil,
        resolvedIdentityLabel: String? = nil,
        isAvailable: Bool = true
    ) -> AgentWorktreeIndicator {
        let summary = AgentSessionWorktreeBindingSummary(
            id: "bind_repo-main_wt-feature",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            logicalRootPath: "/Users/example/dev/repo",
            logicalRootName: "repo",
            worktreeID: worktreeID,
            worktreeRootPath: "/Users/example/dev/.repoprompt-worktrees/repo/rp-agent-feature",
            worktreeName: worktreeName,
            branch: branch,
            visualLabel: visualLabel,
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123)
        )
        let resolvedIdentity = WorktreeVisualIdentity(
            label: resolvedIdentityLabel,
            colorHex: "#3366FF"
        )
        return AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: resolvedIdentity,
            isAvailable: isAvailable
        )
    }
}
