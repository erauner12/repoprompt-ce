import Foundation
import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentRunMCPToolServiceStartDefaultTests: XCTestCase {
    func testAgentRunRespondRejectsMissionBoundChildQuestionUnderAskMode() async throws {
        let window = WindowState()
        let viewModel = window.agentModeViewModel
        let coordinatorID = UUID()
        let coordinatorTabID = UUID()
        let coordinatorSession = await viewModel.ensureSessionReady(tabID: coordinatorTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: coordinatorID, on: coordinatorSession)
        coordinatorSession.isCoordinatorRuntime = true
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = .ask
        coordinatorSession.coordinatorFollowThroughState = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Answer child question.",
            status: .running,
            approvalState: .approved,
            policySnapshot: policy,
            autonomy: policy.autonomy
        ))

        let childID = UUID()
        let childTabID = UUID()
        let childSession = await viewModel.ensureSessionReady(tabID: childTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: childID, on: childSession)
        childSession.parentSessionID = coordinatorID
        childSession.isMCPOriginated = true
        try await viewModel.mcpActivateControlContext(
            forTabID: childTabID,
            sessionID: childID,
            originatingConnectionID: nil,
            startPending: true
        )
        let interaction = AgentAskUserInteraction(
            id: UUID(),
            title: "Child checkpoint",
            context: nil,
            questions: [
                AgentAskUserQuestion(
                    id: "marker_choice",
                    question: "Choose Alpha or Beta.",
                    context: nil,
                    options: [
                        AgentAskUserOption(label: "Alpha", description: nil),
                        AgentAskUserOption(label: "Beta", description: nil)
                    ],
                    allowsMultiple: false,
                    allowsCustom: false
                )
            ]
        )
        childSession.pendingAskUser = AgentAskUserPendingState(
            interaction: interaction,
            timeoutStartedAt: interaction.askedAt
        )
        childSession.runState = .waitingForQuestion
        viewModel.publishMCPStateChange(for: childSession)

        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "coordinator-runtime-test",
                    windowID: window.windowID,
                    runPurpose: .agentModeRun,
                    isCoordinatorRuntime: true
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by respond tests")
            }
        )
        service.testAgentModeViewModel = viewModel

        do {
            _ = try await service.execute(args: [
                "op": .string("respond"),
                "session_id": .string(childID.uuidString),
                "interaction_id": .string(interaction.id.uuidString),
                "response": .string("Alpha")
            ])
            XCTFail("Mission-bound child questions must not be answerable through raw agent_run.respond.")
        } catch let error as MCPError {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("coordinator_chat op=submit"), message)
            XCTAssertTrue(message.contains(coordinatorID.uuidString), message)
        }
        XCTAssertNotNil(childSession.pendingAskUser)
    }

    func testAgentRunRespondRejectsMissionBoundChildQuestionByPlanBinding() async throws {
        let window = WindowState()
        let viewModel = window.agentModeViewModel
        let coordinatorID = UUID()
        let coordinatorTabID = UUID()
        let coordinatorSession = await viewModel.ensureSessionReady(tabID: coordinatorTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: coordinatorID, on: coordinatorSession)
        coordinatorSession.isCoordinatorRuntime = true

        let childID = UUID()
        let childTabID = UUID()
        let childSession = await viewModel.ensureSessionReady(tabID: childTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: childID, on: childSession)
        childSession.isMCPOriginated = true
        try await viewModel.mcpActivateControlContext(
            forTabID: childTabID,
            sessionID: childID,
            originatingConnectionID: nil,
            startPending: true
        )
        let interaction = AgentAskUserInteraction(
            id: UUID(),
            title: "Child checkpoint",
            context: nil,
            questions: [
                AgentAskUserQuestion(
                    id: "marker_choice",
                    question: "Choose Alpha or Beta.",
                    context: nil,
                    options: [
                        AgentAskUserOption(label: "Alpha", description: nil),
                        AgentAskUserOption(label: "Beta", description: nil)
                    ],
                    allowsMultiple: false,
                    allowsCustom: false
                )
            ]
        )
        childSession.pendingAskUser = AgentAskUserPendingState(
            interaction: interaction,
            timeoutStartedAt: interaction.askedAt
        )
        childSession.runState = .waitingForQuestion
        viewModel.publishMCPStateChange(for: childSession)

        let workstreamID = UUID()
        let nodeID = UUID()
        var policy = CoordinatorMissionPolicySnapshot.defaultPolicy
        policy.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = .auto
        coordinatorSession.coordinatorFollowThroughState = CoordinatorFollowThroughState(missionPlan: CoordinatorMissionPlan(
            objective: "Answer bound child question.",
            status: .running,
            approvalState: .approved,
            policySnapshot: policy,
            autonomy: policy.autonomy,
            workstreams: [
                CoordinatorMissionWorkstreamSummary(
                    id: workstreamID,
                    title: "Scripted child",
                    purpose: "Ask one child question.",
                    role: "explore",
                    defaultPolicy: .freshReadOnlyChild,
                    worktreeStrategy: CoordinatorMissionWorktreeStrategy(
                        mode: .noneReadOnly,
                        reason: "Read-only smoke."
                    )
                )
            ],
            nodes: [
                CoordinatorMissionPlanNode(
                    id: nodeID,
                    title: "Ask marker question",
                    workstreamID: workstreamID,
                    executionPolicy: .freshReadOnlyChild,
                    status: .running,
                    boundSessionID: childID,
                    boundInteractionID: interaction.id
                )
            ]
        ))

        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "coordinator-runtime-test",
                    windowID: window.windowID,
                    runPurpose: .agentModeRun,
                    isCoordinatorRuntime: true
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by respond tests")
            }
        )
        service.testAgentModeViewModel = viewModel

        do {
            _ = try await service.execute(args: [
                "op": .string("respond"),
                "session_id": .string(childID.uuidString),
                "interaction_id": .string(interaction.id.uuidString),
                "response": .string("Alpha")
            ])
            XCTFail("Mission-bound child questions must not be answerable through raw agent_run.respond, even without parentSessionID.")
        } catch let error as MCPError {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("coordinator_chat op=submit"), message)
            XCTAssertTrue(message.contains(coordinatorID.uuidString), message)
        }
        XCTAssertNil(childSession.parentSessionID)
        XCTAssertNotNil(childSession.pendingAskUser)
    }

    func testUntargetedStartWithoutModelIDResolvesThroughPairDefault() throws {
        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil)
        XCTAssertEqual(defaultLabel, .pair)

        var requestedRole: AgentModelCatalog.TaskLabelKind?
        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: nil,
            defaultTaskLabel: defaultLabel,
            availability: .current,
            roleSelectionProvider: { role, _ in
                requestedRole = role
                return AgentModelCatalog.NormalizedAgentSelection(agent: .codexExec, modelRaw: "pair-default-model")
            }
        )

        XCTAssertEqual(requestedRole, .pair)
        XCTAssertEqual(resolved.taskLabelKind, .pair)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(resolved.modelRaw, "pair-default-model")
    }

    func testFreshPairEngineerAndExploreStartsUseCodexSafeManagedDefaults() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        CodexAgentToolPreferences.setMCPServerEnabled(
            normalizedName: "external-tools",
            isEnabled: true,
            defaults: defaults
        )
        let service = makeBindingService(defaults: defaults)

        for role in [AgentModelCatalog.TaskLabelKind.pair, .engineer, .explore] {
            let selection = try AgentMCPSelectionResolver.resolve(
                modelID: role.rawValue,
                defaultTaskLabel: nil,
                availability: .current,
                roleSelectionProvider: { requestedRole, _ in
                    XCTAssertEqual(requestedRole, role)
                    return AgentModelCatalog.NormalizedAgentSelection(
                        agent: .codexExec,
                        modelRaw: "\(role.rawValue)-codex-model"
                    )
                }
            )
            XCTAssertEqual(selection.agentRaw, AgentProviderKind.codexExec.rawValue)

            let profile = service.permissionProfileForMCPActivation(
                isSubagent: true,
                provider: .codex
            )
            XCTAssertEqual(profile, .mcpSafeDefaults)

            let snapshot = service.controlsBinding(
                selectedAgent: .codexExec,
                selectedModelRaw: selection.modelRaw,
                permissionProfile: profile,
                isSubagent: true,
                externallyManagedReason: nil
            )
            XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
            XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .workspaceWrite)
            XCTAssertEqual(snapshot.runtimePermission.codexApprovalPolicy, .onRequest)
            XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .autoReview)
            XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, true)
            XCTAssertEqual(snapshot.codexTools?.mcpServerStatesByNormalizedName["external-tools"], false)
            XCTAssertTrue(profile.codexBashToolEnabled(userConfigured: false))
            XCTAssertTrue(profile.codexSuppressesThirdPartyMCPServers)
        }
    }

    func testInheritedRestrictiveCodexSettingsRemainRestrictive() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.inheritProviderSettings, defaults: defaults)
        CodexAgentToolPreferences.setPermissionLevel(.readOnly, defaults: defaults)
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .userConfigured)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testCustomRestrictiveCodexOverrideWinsOverSafeManagedDefaults() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom, defaults: defaults)
        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            .codex(.readOnly),
            for: .codex,
            defaults: defaults
        )
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .providerOverride(.codex(.readOnly)))
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testSubagentPolicyStorageFailureUsesCodexSafeManagedSnapshot() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let secureStore = AgentPermissionSecureStore(
            secureStrings: AgentRunFailingSecurePlainStringStore(),
            notificationCenter: NotificationCenter()
        )
        let service = makeBindingService(defaults: defaults, secureStore: secureStore)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .mcpSafeDefaults)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .autoReview)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, true)
        XCTAssertEqual(snapshot.codexTools?.mcpServerStatesByNormalizedName["external-tools"], false)
        XCTAssertTrue(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertTrue(profile.codexSuppressesThirdPartyMCPServers)
        XCTAssertEqual(secureStore.diagnostic(for: .subagent)?.kind, .keychainInteractionNotAllowed)
    }

    func testExplicitTargetTabWithOmittedModelIDPreservesCurrentSelection() {
        let targetTabID = UUID()

        XCTAssertNil(AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: targetTabID))
    }

    func testWorkflowDefaultDoesNotOverridePairForUntargetedStart() {
        XCTAssertEqual(AgentWorkflow.oracleExport.defaultTaskLabelKind, .explore)

        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(
            resolvedTabID: nil,
            workflow: AgentWorkflow.oracleExport.definition
        )

        XCTAssertEqual(defaultLabel, .pair)
    }

    private func makeBindingService(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> AgentModeProviderBindingService {
        AgentModeProviderBindingService(
            preferences: AgentProviderPreferenceSnapshotStore(
                defaults: defaults,
                securePermissions: secureStore,
                codexMCPServerEntries: {
                    [
                        MCPIntegrationHelper.CodexServerEntry(
                            rawName: "external-tools",
                            normalizedName: "external-tools",
                            cliPathComponent: "external-tools"
                        )
                    ]
                }
            )
        )
    }

    func testExplicitModelIDTakesPrecedenceOverStartPairDefault() throws {
        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil)

        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: "codexExec:explicit-model",
            defaultTaskLabel: defaultLabel,
            availability: AgentModelCatalog.AvailabilityContext(codexAvailable: true)
        )

        XCTAssertNil(resolved.taskLabelKind)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(resolved.modelRaw, "explicit-model")
    }

    func testScriptedModelIDResolvesToHiddenDebugTarget() throws {
        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: "scripted",
            availability: AgentModelCatalog.AvailabilityContext(codexAvailable: true)
        )

        XCTAssertNil(resolved.taskLabelKind)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(resolved.modelRaw, AgentScriptedChildModelID.modelRaw)
        XCTAssertFalse(AgentModelCatalog.discoveryAgents(availability: .current).contains { agent in
            agent.models.contains { model in
                model.id == AgentScriptedChildModelID.modelRaw || model.modelID?.contains(AgentScriptedChildModelID.modelRaw) == true
            }
        })
    }

    func testCoordinatorRoleResolvesAsDedicatedLaunchRole() throws {
        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: "coordinator",
            availability: AgentModelCatalog.AvailabilityContext(codexAvailable: true),
            roleSelectionProvider: { role, _ in
                XCTAssertEqual(role, .coordinator)
                return AgentModelCatalog.NormalizedAgentSelection(
                    agent: .codexExec,
                    modelRaw: AgentModel.gpt55CodexHigh.rawValue
                )
            }
        )

        XCTAssertEqual(resolved.taskLabelKind, .coordinator)
        XCTAssertTrue(try XCTUnwrap(resolved.taskLabelKind).requiresDedicatedLaunchPath)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.codexExec.rawValue)
    }
}

private final class AgentRunFailingSecurePlainStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }
}
