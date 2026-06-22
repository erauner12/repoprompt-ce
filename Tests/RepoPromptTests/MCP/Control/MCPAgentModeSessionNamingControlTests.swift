import Foundation
import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPAgentModeSessionNamingControlTests: XCTestCase {
    func testAgentModeSetStatusEffectiveSurfaceCoversEveryProviderAndRole() async throws {
        let manager = ServerNetworkManager.shared
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()
        let catalogService = window.mcpServer.windowMCPToolCatalogService
        ServiceRegistry.register(catalogService)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Effective naming surface",
            repoPaths: [],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpAgentModeSetStatusEffectiveSurfaceTests"
        )
        let tabID = try XCTUnwrap(window.promptManager.activeComposeTabID)
        let roles: [AgentModelCatalog.TaskLabelKind?] =
            [nil] + AgentModelCatalog.TaskLabelKind.allCases.map(Optional.some)

        do {
            for agent in AgentProviderKind.allCases {
                for role in roles {
                    let runID = UUID()
                    let connectionID = UUID()
                    let spec = MCPBootstrapLeaseSpec.agentMode(
                        tabID: tabID,
                        runID: runID,
                        gateID: UUID(),
                        windowID: window.windowID,
                        agent: agent,
                        taskLabelKind: role
                    )
                    let additionalTools = spec.additionalTools ?? []
                    let isPolicyGranted = !MCPPolicyGatedTools.names.contains(MCPWindowToolName.setStatus)
                        || additionalTools.contains(MCPWindowToolName.setStatus)
                    let isEffectivelyAdvertised =
                        spec.purpose == .agentModeRun
                            && !spec.restrictedTools.contains(MCPWindowToolName.setStatus)
                            && isPolicyGranted
                            && AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                                toolName: MCPWindowToolName.setStatus,
                                taskLabelKind: role,
                                allowsAgentExternalControlTools: spec.allowsAgentExternalControlTools
                            )

                    XCTAssertEqual(spec.purpose, .agentModeRun, "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")")
                    XCTAssertEqual(
                        additionalTools,
                        AgentModeMCPPolicyInstaller.additionalTools(for: agent),
                        "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                    )
                    XCTAssertTrue(
                        additionalTools.contains(MCPWindowToolName.setStatus),
                        "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                    )

                    let clientName = try XCTUnwrap(spec.clientName)
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: spec.windowID,
                        restrictedTools: spec.restrictedTools,
                        oneShot: spec.oneShot,
                        reason: spec.reason,
                        ttl: spec.ttl,
                        tabID: spec.tabID,
                        runID: spec.runID,
                        additionalTools: spec.additionalTools,
                        purpose: spec.purpose,
                        taskLabelKind: spec.taskLabelKind,
                        allowsAgentExternalControlTools: spec.allowsAgentExternalControlTools,
                        requiresExpectedAgentPID: spec.requiresExpectedAgentPID
                    )
                    if spec.requiresExpectedAgentPID {
                        await manager.registerExpectedAgentPID(
                            getpid(),
                            for: clientName,
                            runID: runID
                        )
                    }
                    let appliedPolicy = await manager.debugApplyPendingPolicy(
                        clientName: clientName,
                        connectionID: connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: clientName,
                        sessionKey: "naming-surface-\(runID.uuidString)",
                        pidGateTimeout: 0.25,
                        requireRunRouting: false
                    )
                    XCTAssertEqual(
                        appliedPolicy.outcome,
                        "applied",
                        "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                    )
                    let advertisedTools = try await manager.debugListToolNames(
                        for: connectionID,
                        hydratePersistedPolicy: false
                    )
                    XCTAssertTrue(
                        isEffectivelyAdvertised && advertisedTools.contains(MCPWindowToolName.setStatus),
                        "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                    )

                    if spec.requiresExpectedAgentPID {
                        await manager.clearExpectedAgentPID(
                            getpid(),
                            for: clientName,
                            runID: runID
                        )
                    }
                    await manager.clearClientConnectionPolicy(
                        for: clientName,
                        windowID: window.windowID,
                        runID: runID
                    )
                    await manager.removeConnection(connectionID)
                    await manager.cleanupRunRoutingState(
                        for: runID,
                        windowID: window.windowID
                    )
                }
            }
        } catch {
            ServiceRegistry.unregister(catalogService)
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            throw error
        }

        ServiceRegistry.unregister(catalogService)
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
    }

    func testSetStatusReturnsOnlyVerifiedCanonicalNameAndRejectsMissingOrBlankInput() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAgentModeSessionNamingControlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Naming Control",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "mcpAgentModeSessionNamingControlTests"
            )
            let tabID = try XCTUnwrap(window.promptManager.activeComposeTabID)
            let selectedTabID = window.promptManager.activeComposeTabID

            let result = try await MCPAgentSessionControlToolProvider.executeSetStatus(
                args: ["session_name": .string("  Canonical   Session  ")],
                targetWindow: window,
                tabID: tabID
            )
            let object = try XCTUnwrap(result.objectValue)
            XCTAssertEqual(object["ok"]?.boolValue, true)
            XCTAssertEqual(object["session_name_applied"]?.boolValue, true)
            XCTAssertEqual(object["session_name"]?.stringValue, "Canonical Session")
            XCTAssertEqual(window.workspaceManager.composeTabName(with: tabID), "Canonical Session")
            XCTAssertEqual(
                window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.name,
                "Canonical Session"
            )
            XCTAssertEqual(window.promptManager.activeComposeTabID, selectedTabID)

            for invalidArguments: [String: Value] in [
                [:],
                ["session_name": .string("  \n  ")]
            ] {
                do {
                    _ = try await MCPAgentSessionControlToolProvider.executeSetStatus(
                        args: invalidArguments,
                        targetWindow: window,
                        tabID: tabID
                    )
                    XCTFail("Expected invalid session_name to fail")
                } catch {
                    XCTAssertTrue(error is MCPError)
                }
                XCTAssertEqual(window.workspaceManager.composeTabName(with: tabID), "Canonical Session")
            }
        } catch {
            await cleanup(window: window, rootURL: rootURL)
            throw error
        }

        await cleanup(window: window, rootURL: rootURL)
    }

    private func cleanup(window: WindowState, rootURL: URL) async {
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
