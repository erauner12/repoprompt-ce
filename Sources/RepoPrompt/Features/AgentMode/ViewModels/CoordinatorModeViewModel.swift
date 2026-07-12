import Combine
import Foundation
import MCP

struct CoordinatorDirectiveSubmission: Equatable {
    let visibleText: String
    let providerText: String
    let missionTemplate: CoordinatorMissionTemplateSummary?
    let missionPolicySnapshot: CoordinatorMissionPolicySnapshot?
    let coordinatorSessionID: UUID?
    let coordinatorModelID: String?
    let forceNewRuntime: Bool
    let acceptedRevisionDraftingResolutionID: UUID?

    init(
        visibleText: String,
        providerText: String,
        missionTemplate: CoordinatorMissionTemplateSummary?,
        missionPolicySnapshot: CoordinatorMissionPolicySnapshot?,
        coordinatorSessionID: UUID?,
        coordinatorModelID: String?,
        forceNewRuntime: Bool,
        acceptedRevisionDraftingResolutionID: UUID? = nil
    ) {
        self.visibleText = visibleText
        self.providerText = providerText
        self.missionTemplate = missionTemplate
        self.missionPolicySnapshot = missionPolicySnapshot
        self.coordinatorSessionID = coordinatorSessionID
        self.coordinatorModelID = coordinatorModelID
        self.forceNewRuntime = forceNewRuntime
        self.acceptedRevisionDraftingResolutionID = acceptedRevisionDraftingResolutionID
    }
}

struct CoordinatorMissionStopRequest: Equatable {
    let coordinatorSessionID: UUID
    let sessionIDs: [UUID]
}

struct CoordinatorMissionStopResult: Equatable {
    let requestedSessionIDs: [UUID]
    let cancelledSessionIDs: [UUID]
    let skippedSessionIDs: [UUID]
}

private enum CoordinatorMissionPolicyProviderText {
    static let providerOnlyHeader = "Mission Policy (provider-only)"
    static let providerOnlyMarker = "\n\n---\n\(providerOnlyHeader)"

    static func visibleTranscriptText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let markerRange = trimmed.range(of: providerOnlyMarker) else { return trimmed }
        return String(trimmed[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CoordinatorRevisionDraftingDirectivePayload: Encodable {
    let version: Int
    let proposalID: UUID
    let resolutionID: UUID
    let baseContractFingerprint: String
    let canonicalRequestIdentity: String
    let requestedChange: CoordinatorMissionCanonicalRequestedChange
    let affectedFields: [String]
    let guidance: String?
    let advisorySummary: String
    let advisoryRationale: String?
}

@MainActor
final class CoordinatorModeViewModel: ObservableObject {
    enum DirectiveSubmissionResult: Equatable {
        case accepted
        case rejected(message: String)
    }

    struct MissionComposerContext: Equatable {
        enum Route: Equatable {
            case pendingRevisionProposal(
                coordinatorSessionID: UUID,
                proposalID: UUID,
                expectedContractFingerprint: String,
                expectedCheckpointInstanceID: String
            )
            case acceptedRevisionDrafting(
                coordinatorSessionID: UUID,
                resolutionID: UUID
            )
            case revisedPlanAwaitingApproval(
                coordinatorSessionID: UUID,
                planID: UUID,
                planRevision: Int,
                expectedCheckpointInstanceID: String,
                resolutionID: UUID
            )
            case unavailableRevision(coordinatorSessionID: UUID, reason: String)
            case ordinary(coordinatorSessionID: UUID?)
        }

        let route: Route
        let placeholder: String

        var sendsOnReturn: Bool {
            switch route {
            case .pendingRevisionProposal, .unavailableRevision:
                false
            case .acceptedRevisionDrafting, .revisedPlanAwaitingApproval, .ordinary:
                true
            }
        }

        var coordinatorSessionID: UUID? {
            switch route {
            case let .pendingRevisionProposal(coordinatorSessionID, _, _, _),
                 let .acceptedRevisionDrafting(coordinatorSessionID, _),
                 let .revisedPlanAwaitingApproval(coordinatorSessionID, _, _, _, _),
                 let .unavailableRevision(coordinatorSessionID, _):
                coordinatorSessionID
            case let .ordinary(coordinatorSessionID):
                coordinatorSessionID
            }
        }

        var accessibilityLabel: String {
            switch route {
            case .pendingRevisionProposal:
                "Optional guidance for the Revise plan decision"
            case .acceptedRevisionDrafting:
                "Guidance for the revised Mission plan"
            case .revisedPlanAwaitingApproval:
                "Request another Mission plan change"
            case .unavailableRevision:
                "Mission revision guidance unavailable"
            case .ordinary:
                "Message the Mission Director"
            }
        }
    }

    enum PostApprovalContinuationStatus: Equatable {
        case none
        case deferred(checkpointInstanceID: String)
        case delivered(checkpointInstanceID: String)
        case failed(checkpointInstanceID: String, message: String)
    }

    enum ContinuationAction: Equatable {
        case proceed
        case runLightweightDiscovery
        case runDeepPlan
        case runDesignCritique
        case startSmaller
        case stopHere

        init?(checkpointActionID: String) {
            switch checkpointActionID {
            case "proceed":
                self = .proceed
            case "gather_evidence":
                self = .runLightweightDiscovery
            case "deepen_plan":
                self = .runDeepPlan
            case "independent_critique":
                self = .runDesignCritique
            case "start_smaller":
                self = .startSmaller
            case "stop":
                self = .stopHere
            default:
                return nil
            }
        }

        var checkpointActionID: String {
            switch self {
            case .proceed:
                "proceed"
            case .runLightweightDiscovery:
                "gather_evidence"
            case .runDeepPlan:
                "deepen_plan"
            case .runDesignCritique:
                "independent_critique"
            case .startSmaller:
                "start_smaller"
            case .stopHere:
                "stop"
            }
        }

        static let runtimeLedgerInstruction = """
        Runtime ledger rule: append only Director-owned decisions (actor:"director") and evidence records through coordinator_chat op=mission_plan. Judge from the bounded Mission ledger and any judgment_bundle/probe_answer evidence, not the full transcript. If evidence is thin, use a narrow read-only agent_explore.start probe and record the probe answer as evidence before deciding. Do not record user decisions; the app/MCP submit path owns user-actor checkpoint decisions. Auto decisions are visible and contestable; if the user overrules one, treat it as a user decision plus correction steer, preserve the original record, and link the Director correction with overruled_decision_id/overrule_reason/correction_reason/correction_steer_text when useful.
        """

        var requiresCurrentPlanApprovalCheckpoint: Bool {
            self != .stopHere
        }

        var directiveText: String {
            switch self {
            case .proceed:
                "Approved to proceed with the current Mission Plan phase you proposed. Proceed advances the next planned phase, not necessarily implementation. If the current phase is evidence gathering or planning, run only that phase and ask again after updating the Mission Plan. The app has already persisted the user approval decision and approval_state before this directive is sent; do not write approval_state:\"approved\" yourself. If this mission is investigation-only or issue-drafting-only, do not invent an implementation phase. Do not merge, apply, commit, push, create a PR, or perform irreversible actions unless I explicitly request that next.\n\n\(Self.runtimeLedgerInstruction)"
            case .runLightweightDiscovery:
                """
                Gather evidence before approval using visible Mission Plan nodes.

                First call coordinator_chat op=mission_status and inspect the current Mission Plan. Keep approval_state:"awaiting_approval".

                Add or update one or more evidence nodes with execution_policy:"fresh_readonly_child", concrete titles, and completion_evidence. For narrow disposable probes, leave workflow metadata absent and record routing_decisions before launch with operation "agent_explore.start", the relevant node_id/workstream_id, and reason "user requested pre-approval evidence gathering". For durable formal investigation, use the built-in workflow_name:"Investigate" and record operation "agent_run.start" with workflow_name "Investigate" plus the chosen model_id.

                Launch each evidence-gathering probe with agent_explore.start using mission_node_id set to the planned node ID. Keep the child prompt narrow, read-only, and disposable. Do not edit files and do not launch further agents.

                Launch each formal investigation node with agent_run.start using workflow_name:"Investigate", mission_node_id set to the planned node ID, worktree_create:true, detach:true, and worktree_base_ref from the planned/default base when available.

                After the evidence returns, fold findings into the Mission Plan, keep approval_state:"awaiting_approval", and ask again with the phase-aware checkpoint.

                \(Self.runtimeLedgerInstruction)
                """
            case .runDeepPlan:
                """
                Deepen the current Mission Plan before approval using a visible planning child session.

                First call coordinator_chat op=mission_status and inspect the current Mission Plan. Keep approval_state:"awaiting_approval".

                Add or update a concrete planning node with workflow_name:"Deep Plan", execution_policy:"fresh_readonly_child", status pending/running as appropriate, and completion_evidence describing the planning evidence needed. Record a routing_decision before launch with operation "agent_run.start", workflow_name "Deep Plan", the planning node_id/workstream_id, and reason "user requested deeper pre-approval planning".

                Launch the planning pass with agent_run.start using workflow_name:"Deep Plan", mission_node_id set to that planning node ID, worktree_create:true, detach:true, a session_name like "Deep Plan: <mission>", and worktree_base_ref from the planned/default base when available.

                Treat the Deep Plan output as evidence for the Mission Plan, not as a replacement source of truth. After it returns, revise the Mission Plan, keep approval_state:"awaiting_approval", and ask again with the phase-aware checkpoint.

                \(Self.runtimeLedgerInstruction)
                """
            case .runDesignCritique:
                """
                Get independent critique of the current Mission Plan before approval using a visible design-agent child session.

                First call coordinator_chat op=mission_status and inspect the current Mission Plan. Keep approval_state:"awaiting_approval".

                Add or update a Mission Plan node titled "Critique Mission Plan from a design session" with execution_policy:"plan_critique", role "design", and status pending/running as appropriate. Record a routing_decision before launch with operation "agent_run.start", model_id "design", the critique node_id/workstream_id, and reason "user requested bounded pre-approval plan critique".

                Launch the critique with agent_run.start using model_id:"design", mission_node_id set to that critique node ID, worktree_create:true, detach:true, a session_name like "Plan critique: <mission>", and worktree_base_ref from the planned/default base when available.

                Child prompt:
                Critique this RepoPrompt Coordinator Mission Plan. You are a critic, not a co-author.
                Do not implement. Do not launch agents. Do not rewrite the plan wholesale.
                Review under-specified seams, contradictions or missing dependencies, over-planning or under-decomposition, unsafe or mismatched execution policies, worktree/base strategy risks, missing evidence/tests/proof obligations, and questions whose answers would change execution order.
                Use sparse context if needed, but label any repo-specific claim that lacks file evidence.
                Return blockers before approval, recommended revisions, open questions, and a safe-to-approve verdict.

                After the design critique returns, fold actionable findings into the Mission Plan, keep approval_state:"awaiting_approval", and ask again with the phase-aware checkpoint.

                \(Self.runtimeLedgerInstruction)
                """
            case .startSmaller:
                """
                Start smaller before approval.

                First call coordinator_chat op=mission_status and inspect the current Mission Plan. Keep approval_state:"awaiting_approval".

                Revise the Mission Plan to the smallest useful first phase. Prefer one or two narrow evidence-gathering/planning nodes over broad implementation. Do not launch mutable implementation. Ask again with the smaller phase-aware plan.

                \(Self.runtimeLedgerInstruction)
                """
            case .stopHere:
                "Stop here. Do not continue this objective unless I ask again.\n\n\(Self.runtimeLedgerInstruction)"
            }
        }
    }

    enum CoordinatorSelectionState: Equatable {
        case newDraft
        case session(UUID)

        var selectedCoordinatorID: UUID? {
            switch self {
            case .newDraft:
                nil
            case let .session(sessionID):
                sessionID
            }
        }
    }

    enum RailDestination: Equatable {
        case mission
        case board
        case decisions
    }

    struct ChildInteractionResponseSubmission: Equatable {
        var text: String?
        var skip: Bool
        var answersByQuestionID: [String: AgentAskUserAnswer]
        var displayText: String

        static func text(_ text: String) -> ChildInteractionResponseSubmission {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChildInteractionResponseSubmission(
                text: trimmed,
                skip: false,
                answersByQuestionID: [:],
                displayText: trimmed
            )
        }

        var fallbackText: String {
            let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedText.isEmpty {
                return trimmedText
            }
            return displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var hasStructuredAnswers: Bool {
            !answersByQuestionID.isEmpty
        }
    }

    typealias InputProvider = @MainActor (_ sortMode: CoordinatorModeSortMode, _ selectedCoordinatorID: UUID?) -> CoordinatorModeSnapshotProjector.Input
    typealias TranscriptProvider = @MainActor (_ coordinatorSessionID: UUID?) -> [CoordinatorModeRailTranscriptEntry]
    typealias DashboardVisibilityHandler = @MainActor (_ visible: Bool) -> Void
    typealias DirectiveSubmitter = @MainActor (_ submission: CoordinatorDirectiveSubmission) async -> DirectiveSubmissionResult
    typealias ChildDirectiveSubmitter = @MainActor (_ text: String, _ row: CoordinatorModeRow) async -> DirectiveSubmissionResult
    typealias ChildInteractionResponseSubmitter = @MainActor (_ submission: ChildInteractionResponseSubmission, _ row: CoordinatorModeRow) async -> DirectiveSubmissionResult
    typealias CoordinatorInteractionResponseSubmitter = @MainActor (_ submission: ChildInteractionResponseSubmission, _ coordinatorSessionID: UUID, _ interactionID: UUID) async -> DirectiveSubmissionResult
    typealias ChildInteractionResponseRecorder = @MainActor (_ text: String, _ row: CoordinatorModeRow) -> Void
    typealias ContinuationGateHandler = @MainActor (_ gate: CoordinatorContinuationGate, _ snapshotBeforeGateCleared: CoordinatorModeSnapshot) async -> Void
    typealias CoordinatorActivationHandler = @MainActor (_ sessionID: UUID) async -> Void
    typealias CoordinatorPinHandler = @MainActor (_ option: CoordinatorModeCoordinatorOption, _ isPinned: Bool) -> Void
    struct CoordinatorArchiveMissionResult: Equatable {
        var accepted: Bool
        var alreadyArchived: Bool = false
        var unpinned: Bool = false
        var message: String?

        static func accepted(alreadyArchived: Bool = false, unpinned: Bool = false) -> Self {
            Self(accepted: true, alreadyArchived: alreadyArchived, unpinned: unpinned)
        }

        static func rejected(_ message: String) -> Self {
            Self(accepted: false, message: message)
        }
    }

    typealias CoordinatorArchiveHandler = @MainActor (_ option: CoordinatorModeCoordinatorOption) async -> CoordinatorArchiveMissionResult
    typealias MissionPlanUpdater = @MainActor (_ coordinatorSessionID: UUID, _ update: CoordinatorMissionPlanUpdate) throws -> Void
    typealias RevisionProposalAppender = @MainActor (_ coordinatorSessionID: UUID, _ request: CoordinatorMissionRevisionProposalRequest) async throws -> CoordinatorMissionRevisionProposalAppendResult
    typealias RevisionProposalResolver = @MainActor (_ request: CoordinatorMissionRevisionProposalTrustedResolutionRequest) async throws -> CoordinatorMissionRevisionProposalResolutionResult
    struct RevisionProposalAuthority: Equatable {
        let acceptedDraftingResolutionID: UUID?
        let latestAcceptedResolutionID: UUID?
        let isRevisedPlanReady: Bool
        let holdsInteractions: Bool

        init(
            acceptedDraftingResolutionID: UUID?,
            latestAcceptedResolutionID: UUID?,
            isRevisedPlanReady: Bool,
            holdsInteractions: Bool
        ) {
            self.acceptedDraftingResolutionID = acceptedDraftingResolutionID
            self.latestAcceptedResolutionID = latestAcceptedResolutionID
            self.isRevisedPlanReady = isRevisedPlanReady
            self.holdsInteractions = holdsInteractions
        }

        init(plan: CoordinatorMissionPlan?) {
            self.init(
                acceptedDraftingResolutionID: plan?.acceptedRevisionDraftingResolution?.id,
                latestAcceptedResolutionID: plan?.latestAcceptedRevisionLineage?.resolution.id,
                isRevisedPlanReady: plan?.approvalState == .awaitingApproval
                    && plan?.latestAcceptedRevisionLineage != nil,
                holdsInteractions: plan?.holdsChildInteractionsForRevisionProposal == true
            )
        }
    }

    typealias RevisionProposalAuthorityProvider = @MainActor (_ coordinatorSessionID: UUID) -> RevisionProposalAuthority
    typealias TrustedMissionStopRecorder = @MainActor (_ coordinatorSessionID: UUID, _ targetSessionIDs: [UUID]) async throws -> Void
    typealias TrustedContractChangeApplier = @MainActor (_ coordinatorSessionID: UUID, _ update: CoordinatorMissionPlanUpdate) async throws -> Void
    typealias TrustedRevisedPlanChangeRequester = @MainActor (
        _ coordinatorSessionID: UUID,
        _ planID: UUID,
        _ planRevision: Int,
        _ expectedCheckpointInstanceID: String,
        _ resolutionID: UUID
    ) async throws -> Void
    typealias MissionStopper = @MainActor (_ request: CoordinatorMissionStopRequest) async -> CoordinatorMissionStopResult
    typealias PendingFollowThroughEventProvider = @MainActor (_ coordinatorSessionID: UUID?) -> CoordinatorFollowThroughEvent?
    typealias FollowThroughEventSubmitter = @MainActor (_ event: CoordinatorFollowThroughEvent) async -> DirectiveSubmissionResult
    struct PostApprovalContinuationPersistenceToken: Equatable {
        let coordinatorSessionID: UUID
        let continuationID: UUID
        let checkpointInstanceID: String
        let planID: UUID
        let planRevision: Int
    }

    typealias FollowThroughEventResolver = @MainActor (_ event: CoordinatorFollowThroughEvent) async -> Void
    typealias FollowThroughEvaluationHandler = @MainActor (_ coordinatorSessionID: UUID) async -> Void
    typealias PostApprovalContinuationPersistenceBarrier = @MainActor (_ token: PostApprovalContinuationPersistenceToken) async throws -> Void

    @Published private(set) var snapshot: CoordinatorModeSnapshot = .empty
    @Published private(set) var railTranscriptEntries: [CoordinatorModeRailTranscriptEntry] = []
    @Published private(set) var currentRailActivityText: String?
    @Published private(set) var composerNotice: String?
    @Published private(set) var revisionProposalActionNotice: RevisionProposalActionNotice?
    @Published private(set) var revisionDraftingRetryResolutionID: UUID?
    @Published private(set) var isFreshCoordinatorRunPending = false
    @Published private(set) var executionPace: CoordinatorExecutionPace
    @Published private(set) var missionPaceSelection: CoordinatorMissionPolicyPace
    @Published private(set) var childAskSelection: CoordinatorMissionAutonomyMode
    @Published private(set) var pendingFollowThroughEvent: CoordinatorFollowThroughEvent?
    @Published private(set) var postApprovalContinuationStatus: PostApprovalContinuationStatus = .none
    @Published private(set) var railDestination: RailDestination = .mission
    @Published var selectedMissionPolicy: CoordinatorMissionPolicySnapshot = .defaultPolicy {
        didSet {
            guard selectedMissionPolicy != oldValue else { return }
            syncDraftDialSelectionsFromSelectedPolicy()
        }
    }

    @Published var sortMode: CoordinatorModeSortMode = .lastUpdated {
        didSet {
            guard sortMode != oldValue else { return }
            refresh()
        }
    }

    @Published var boardScope: CoordinatorModeBoardScope = .coordinatorFleet {
        didSet {
            guard boardScope != oldValue else { return }
            refresh()
        }
    }

    func showMissionDestination() {
        railDestination = .mission
        if boardScope != .coordinatorFleet {
            boardScope = .coordinatorFleet
        }
    }

    func showBoardDestination() {
        if boardScope != .allAgents {
            boardScope = .allAgents
        }
        railDestination = .board
    }

    func showDecisionsDestination() {
        railDestination = .decisions
    }

    private let inputProvider: InputProvider
    private let transcriptProvider: TranscriptProvider
    private let dashboardVisibilityHandler: DashboardVisibilityHandler
    private let directiveSubmitter: DirectiveSubmitter
    private let childDirectiveSubmitter: ChildDirectiveSubmitter
    private let childInteractionResponseSubmitter: ChildInteractionResponseSubmitter
    private let coordinatorInteractionResponseSubmitter: CoordinatorInteractionResponseSubmitter
    private let childInteractionResponseRecorder: ChildInteractionResponseRecorder
    private let continuationGateHandler: ContinuationGateHandler
    private let coordinatorActivationHandler: CoordinatorActivationHandler
    private let coordinatorPinHandler: CoordinatorPinHandler
    private let coordinatorArchiveHandler: CoordinatorArchiveHandler
    private let missionPlanUpdater: MissionPlanUpdater
    private let revisionProposalAppender: RevisionProposalAppender
    private let revisionProposalResolver: RevisionProposalResolver
    private let revisionProposalAuthorityProvider: RevisionProposalAuthorityProvider?
    private let trustedMissionStopRecorder: TrustedMissionStopRecorder?
    private let trustedContractChangeApplier: TrustedContractChangeApplier?
    private let trustedRevisedPlanChangeRequester: TrustedRevisedPlanChangeRequester?
    private let missionStopper: MissionStopper
    private let pendingFollowThroughEventProvider: PendingFollowThroughEventProvider
    private let followThroughEventSubmitter: FollowThroughEventSubmitter
    private let followThroughEventResolver: FollowThroughEventResolver
    private let followThroughEvaluationHandler: FollowThroughEvaluationHandler
    private let postApprovalContinuationPersistenceBarrier: PostApprovalContinuationPersistenceBarrier
    private let missionEventJournal: CoordinatorMissionEventJournal
    private let projector: CoordinatorModeSnapshotProjector
    private let userDefaults: UserDefaults
    private var lastProjectionInput: CoordinatorModeSnapshotProjector.Input?
    private var coordinatorSelectionByWorkspaceID: [UUID: CoordinatorSelectionState] = [:]
    private var lastPublishedFingerprint: CoordinatorModeSnapshotFingerprint?
    private var displayedTranscriptCoordinatorSessionID: UUID?
    private var lastDurableRailStatusEntryKey: String?
    private var displayedDelegateActionTargetIDs: Set<UUID> = []
    private var durableApprovalAuthorityTokensByCoordinatorID: [UUID: String] = [:]
    private var pendingAcceptedDirectiveDecision: PendingMissionUserDecision?
    private var pendingFreshCoordinatorModelID: String?
    private var draftDialOverridesPolicy = false
    private(set) var isVisible = false

    struct RevisionProposalActionNotice: Equatable {
        let coordinatorSessionID: UUID
        let proposalID: UUID
        let checkpointInstanceID: String
        let message: String
    }

    private struct PendingMissionUserDecision {
        let coordinatorSessionID: UUID
        let record: CoordinatorMissionDecisionRecord
    }

    init(
        inputProvider: @escaping InputProvider,
        transcriptProvider: @escaping TranscriptProvider = { _ in [] },
        dashboardVisibilityHandler: @escaping DashboardVisibilityHandler,
        directiveSubmitter: @escaping DirectiveSubmitter = { _ in
            .rejected(message: "Coordinator composer is unavailable.")
        },
        childDirectiveSubmitter: @escaping ChildDirectiveSubmitter = { _, _ in
            .rejected(message: "Session replies are unavailable.")
        },
        childInteractionResponseSubmitter: ChildInteractionResponseSubmitter? = nil,
        coordinatorInteractionResponseSubmitter: @escaping CoordinatorInteractionResponseSubmitter = { _, _, _ in
            .rejected(message: "Coordinator replies are unavailable.")
        },
        childInteractionResponseRecorder: @escaping ChildInteractionResponseRecorder = { _, _ in },
        continuationGateHandler: @escaping ContinuationGateHandler = { _, _ in },
        coordinatorActivationHandler: @escaping CoordinatorActivationHandler = { _ in },
        coordinatorPinHandler: @escaping CoordinatorPinHandler = { _, _ in },
        coordinatorArchiveHandler: @escaping CoordinatorArchiveHandler = { _ in
            .rejected("Coordinator Mission archive is unavailable.")
        },
        missionPlanUpdater: @escaping MissionPlanUpdater = { _, _ in },
        revisionProposalAppender: @escaping RevisionProposalAppender = { _, _ in
            throw MCPError.invalidParams("Coordinator Mission revision proposals are unavailable.")
        },
        revisionProposalResolver: @escaping RevisionProposalResolver = { _ in
            throw MCPError.invalidParams("Coordinator Mission revision proposal resolution is unavailable.")
        },
        revisionProposalAuthorityProvider: RevisionProposalAuthorityProvider? = nil,
        trustedMissionStopRecorder: TrustedMissionStopRecorder? = nil,
        trustedContractChangeApplier: TrustedContractChangeApplier? = nil,
        trustedRevisedPlanChangeRequester: TrustedRevisedPlanChangeRequester? = nil,
        missionStopper: @escaping MissionStopper = { request in
            CoordinatorMissionStopResult(
                requestedSessionIDs: request.sessionIDs,
                cancelledSessionIDs: [],
                skippedSessionIDs: request.sessionIDs
            )
        },
        pendingFollowThroughEventProvider: @escaping PendingFollowThroughEventProvider = { _ in nil },
        followThroughEventSubmitter: @escaping FollowThroughEventSubmitter = { _ in
            .rejected(message: "Coordinator follow-through is unavailable.")
        },
        followThroughEventResolver: @escaping FollowThroughEventResolver = { _ in },
        followThroughEvaluationHandler: @escaping FollowThroughEvaluationHandler = { _ in },
        postApprovalContinuationPersistenceBarrier: @escaping PostApprovalContinuationPersistenceBarrier = { _ in },
        missionEventJournal: CoordinatorMissionEventJournal? = nil,
        projector: CoordinatorModeSnapshotProjector = CoordinatorModeSnapshotProjector(),
        userDefaults: UserDefaults = .standard
    ) {
        self.inputProvider = inputProvider
        self.transcriptProvider = transcriptProvider
        self.dashboardVisibilityHandler = dashboardVisibilityHandler
        self.directiveSubmitter = directiveSubmitter
        self.childDirectiveSubmitter = childDirectiveSubmitter
        self.childInteractionResponseSubmitter = childInteractionResponseSubmitter ?? { submission, row in
            await childDirectiveSubmitter(submission.fallbackText, row)
        }
        self.coordinatorInteractionResponseSubmitter = coordinatorInteractionResponseSubmitter
        self.childInteractionResponseRecorder = childInteractionResponseRecorder
        self.continuationGateHandler = continuationGateHandler
        self.coordinatorActivationHandler = coordinatorActivationHandler
        self.coordinatorPinHandler = coordinatorPinHandler
        self.coordinatorArchiveHandler = coordinatorArchiveHandler
        self.missionPlanUpdater = missionPlanUpdater
        self.revisionProposalAppender = revisionProposalAppender
        self.revisionProposalResolver = revisionProposalResolver
        self.revisionProposalAuthorityProvider = revisionProposalAuthorityProvider
        self.trustedMissionStopRecorder = trustedMissionStopRecorder
        self.trustedContractChangeApplier = trustedContractChangeApplier
        self.trustedRevisedPlanChangeRequester = trustedRevisedPlanChangeRequester
        self.missionStopper = missionStopper
        self.pendingFollowThroughEventProvider = pendingFollowThroughEventProvider
        self.followThroughEventSubmitter = followThroughEventSubmitter
        self.followThroughEventResolver = followThroughEventResolver
        self.followThroughEvaluationHandler = followThroughEvaluationHandler
        self.postApprovalContinuationPersistenceBarrier = postApprovalContinuationPersistenceBarrier
        self.missionEventJournal = missionEventJournal ?? .shared
        self.projector = projector
        self.userDefaults = userDefaults
        let storedPace = CoordinatorModeAutomationPreference.executionPace(defaults: userDefaults)
        executionPace = CoordinatorExecutionPace(CoordinatorMissionPolicySnapshot.defaultPolicy.defaultPace)
        missionPaceSelection = CoordinatorMissionPolicySnapshot.defaultPolicy.defaultPace
        childAskSelection = CoordinatorMissionPolicySnapshot.defaultPolicy.resolvedAutonomy(for: .childAsk)
        if storedPace.missionPolicyPace != missionPaceSelection {
            CoordinatorModeAutomationPreference.setExecutionPace(executionPace, defaults: userDefaults)
        }
    }

    var usesAutoMode: Bool {
        missionPaceSelection == .auto
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        dashboardVisibilityHandler(visible)
        if visible {
            refresh()
        }
    }

    func refresh() {
        var input = inputProvider(sortMode, nil)
        let selectionState = input.workspaceID.flatMap { coordinatorSelectionByWorkspaceID[$0] }
        if let selectionState {
            input.selectedCoordinatorID = selectionState.selectedCoordinatorID
        }
        input.boardScope = boardScope
        lastProjectionInput = input
        let projected = projector.project(input)
        let isNewDraft = selectionState == .newDraft
        isFreshCoordinatorRunPending = isNewDraft
        publishIfChanged(isNewDraft ? pendingFreshCoordinatorSnapshot(from: projected) : projected)
    }

    private func syncDraftDialSelectionsFromSelectedPolicy() {
        draftDialOverridesPolicy = false
        missionPaceSelection = selectedMissionPolicy.defaultPace
        executionPace = CoordinatorExecutionPace(selectedMissionPolicy.defaultPace)
        childAskSelection = selectedMissionPolicy.resolvedAutonomy(for: .childAsk)
    }

    private func syncDialSelections(from rail: CoordinatorModeCoordinatorRail) {
        if rail.state == .chooseCoordinator {
            if !draftDialOverridesPolicy {
                syncDraftDialSelectionsFromSelectedPolicy()
            }
            return
        }
        guard let plan = rail.missionPlan else { return }
        if let policySnapshot = plan.policySnapshot {
            missionPaceSelection = policySnapshot.defaultPace
            executionPace = CoordinatorExecutionPace(policySnapshot.defaultPace)
            childAskSelection = policySnapshot.resolvedAutonomy(for: .childAsk)
        } else {
            childAskSelection = CoordinatorMissionPolicySnapshot.resolveAutonomy(
                plan.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key],
                for: CoordinatorMissionAutonomyClasses.childAsk.key
            )
        }
    }

    private func effectiveSelectedMissionPolicySnapshot() -> CoordinatorMissionPolicySnapshot {
        var policySnapshot = selectedMissionPolicy
        policySnapshot.defaultPace = missionPaceSelection
        policySnapshot.autonomy[CoordinatorMissionAutonomyClasses.childAsk.key] = childAskSelection
        return policySnapshot
    }

    func durableApprovalAuthorityToken(coordinatorSessionID: UUID?) -> String? {
        guard let coordinatorSessionID else { return nil }
        refresh()
        guard let plan = snapshot.coordinatorRail.availableCoordinators
            .first(where: { $0.sessionID == coordinatorSessionID })?
            .missionPlan
        else {
            durableApprovalAuthorityTokensByCoordinatorID.removeValue(forKey: coordinatorSessionID)
            return nil
        }
        let token = durableApprovalAuthorityTokensByCoordinatorID[coordinatorSessionID]
        guard plan.hasDurableApprovalAuthority(token) else {
            durableApprovalAuthorityTokensByCoordinatorID.removeValue(forKey: coordinatorSessionID)
            return nil
        }
        return token
    }

    #if DEBUG
        func test_setPostApprovalContinuationDurableAuthority(
            _ continuation: CoordinatorPostApprovalContinuationRecord
        ) {
            durableApprovalAuthorityTokensByCoordinatorID[continuation.coordinatorSessionID] = continuation.durableApprovalAuthorityToken
        }
    #endif

    func updateMissionPlan(
        coordinatorSessionID: UUID,
        update: CoordinatorMissionPlanUpdate
    ) throws {
        guard snapshot.coordinatorRail.availableCoordinators.contains(where: { $0.sessionID == coordinatorSessionID }) else {
            throw MCPError.invalidParams("Coordinator session \(coordinatorSessionID.uuidString) is not available in this window.")
        }
        try missionPlanUpdater(coordinatorSessionID, update)
        refresh()
    }

    func appendRevisionProposal(
        coordinatorSessionID: UUID,
        request: CoordinatorMissionRevisionProposalRequest
    ) async throws -> CoordinatorMissionRevisionProposalAppendResult {
        guard snapshot.coordinatorRail.availableCoordinators.contains(where: { $0.sessionID == coordinatorSessionID }) else {
            throw MCPError.invalidParams("Coordinator session \(coordinatorSessionID.uuidString) is not available in this window.")
        }
        let result = try await revisionProposalAppender(coordinatorSessionID, request)
        refresh()
        return result
    }

    @discardableResult
    func resolveRevisionProposal(
        _ request: CoordinatorMissionRevisionProposalTrustedResolutionRequest
    ) async -> DirectiveSubmissionResult {
        do {
            _ = try await revisionProposalResolver(request)
            refresh()
            composerNotice = nil
            if request.action == .keepCurrentPlan {
                Task { @MainActor [followThroughEvaluationHandler] in
                    await followThroughEvaluationHandler(request.coordinatorSessionID)
                }
            }
            return .accepted
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            composerNotice = message
            refresh()
            return .rejected(message: message)
        }
    }

    @discardableResult
    func submitRevisionProposalAction(
        coordinatorSessionID: UUID,
        action: CoordinatorMissionRevisionProposalResolutionAction,
        proposalID: UUID,
        expectedContractFingerprint: String,
        expectedCheckpointInstanceID: String,
        guidance: String? = nil
    ) async -> DirectiveSubmissionResult {
        let request = CoordinatorMissionRevisionProposalTrustedResolutionRequest(
            coordinatorSessionID: coordinatorSessionID,
            action: action,
            proposalID: proposalID,
            expectedContractFingerprint: expectedContractFingerprint,
            expectedCheckpointInstanceID: expectedCheckpointInstanceID,
            guidance: guidance
        )

        do {
            _ = try await revisionProposalResolver(request)
            refresh()
            composerNotice = nil
            revisionProposalActionNotice = nil
            revisionDraftingRetryResolutionID = nil
            if action == .keepCurrentPlan {
                Task { @MainActor [followThroughEvaluationHandler] in
                    await followThroughEvaluationHandler(coordinatorSessionID)
                }
                return .accepted
            }

            return .accepted
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            refresh()
            if action == .revisePlan,
               let plan = snapshot.coordinatorRail.availableCoordinators
               .first(where: { $0.sessionID == coordinatorSessionID })?
               .missionPlan,
               plan.approvalState == .revisionRequested,
               let lineage = plan.latestAcceptedRevisionLineage,
               lineage.proposal.id == proposalID
            {
                revisionDraftingRetryResolutionID = lineage.resolution.id
            } else {
                revisionDraftingRetryResolutionID = nil
            }
            if Self.isRevisionProposalRenderRace(error) {
                revisionProposalActionNotice = RevisionProposalActionNotice(
                    coordinatorSessionID: coordinatorSessionID,
                    proposalID: proposalID,
                    checkpointInstanceID: expectedCheckpointInstanceID,
                    message: "This plan decision changed while you were deciding. Mission state was refreshed; review the current Plan Revision card."
                )
                composerNotice = nil
            } else {
                revisionProposalActionNotice = nil
                composerNotice = message
            }
            return .rejected(message: message)
        }
    }

    @discardableResult
    func retryAcceptedRevisionDraftingDirective(
        coordinatorSessionID: UUID,
        proposalID: UUID
    ) async -> DirectiveSubmissionResult {
        refresh()
        guard let plan = snapshot.coordinatorRail.availableCoordinators
            .first(where: { $0.sessionID == coordinatorSessionID })?
            .missionPlan,
            let resolution = plan.acceptedRevisionDraftingResolution,
            let lineage = plan.acceptedRevisionLineage(resolutionID: resolution.id),
            lineage.proposal.id == proposalID
        else {
            let message = CoordinatorMissionRevisionProposalPause.heldReason
            composerNotice = message
            return .rejected(message: message)
        }
        let result = await submitAcceptedRevisionDraftingDirective(
            Self.revisionDraftingDirective(
                proposal: lineage.proposal,
                resolution: lineage.resolution
            ),
            coordinatorSessionID: coordinatorSessionID,
            expectedResolutionID: resolution.id
        )
        if result == .accepted {
            revisionDraftingRetryResolutionID = nil
        }
        return result
    }

    static func revisionDraftingDirective(
        proposal: CoordinatorMissionRevisionProposal,
        resolution: CoordinatorMissionRevisionProposalResolution
    ) -> String {
        let payload = CoordinatorRevisionDraftingDirectivePayload(
            version: 1,
            proposalID: proposal.id,
            resolutionID: resolution.id,
            baseContractFingerprint: proposal.baseContractFingerprint,
            canonicalRequestIdentity: proposal.canonicalRequestIdentity,
            requestedChange: proposal.requestedChange,
            affectedFields: proposal.affectedFields.sorted(),
            guidance: resolution.guidance,
            advisorySummary: proposal.summary,
            advisoryRationale: proposal.rationale
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            preconditionFailure("Revision drafting payload encoding must not fail.")
        }
        let json = String(decoding: data, as: UTF8.self)
        return [
            "<coordinator_revision_drafting>",
            "Draft a concrete revised Mission Plan from this accepted canonical request:",
            json,
            "Return the concrete plan for approval. Do not resume Mission execution ",
            "or treat this directive as approval.",
            "</coordinator_revision_drafting>"
        ].joined(separator: "\n")
    }

    func shouldOfferRevisionDraftingRetry(
        for presentation: CoordinatorPlanRevisionPresentation
    ) -> Bool {
        guard presentation.phase == .drafting,
              let plan = snapshot.coordinatorRail.availableCoordinators
              .first(where: { $0.sessionID == presentation.coordinatorSessionID })?
              .missionPlan,
              let lineage = plan.latestAcceptedRevisionLineage,
              lineage.proposal.id == presentation.proposalID
        else { return false }
        let submittedMarkerIsPresent = railTranscriptEntries.contains { entry in
            entry.role == .user
                && entry.text.contains("<coordinator_revision_drafting>")
                && entry.text.contains(lineage.resolution.id.uuidString)
        }
        return revisionDraftingRetryResolutionID == lineage.resolution.id
            || !submittedMarkerIsPresent
    }

    func refreshRevisionProposalCard() {
        refresh()
    }

    func revisionProposalActionNotice(
        for presentation: CoordinatorPlanRevisionPresentation
    ) -> String? {
        guard let notice = revisionProposalActionNotice,
              notice.coordinatorSessionID == presentation.coordinatorSessionID,
              notice.proposalID == presentation.proposalID,
              notice.checkpointInstanceID == presentation.expectedCheckpointInstanceID
        else { return nil }
        return notice.message
    }

    private static func isRevisionProposalRenderRace(_ error: Error) -> Bool {
        guard let ledgerError = error as? CoordinatorMissionRevisionProposalLedgerError else { return false }
        return switch ledgerError {
        case .staleBasePlan, .staleBaseContract, .staleCheckpoint, .proposalNotFound, .conflictingResolution,
             .missionTerminal:
            true
        case .missionPlanMissing, .durabilityHoldActive, .invalidRequest, .differentProposalPending:
            false
        }
    }

    @discardableResult
    func setCoordinatorMissionPace(
        coordinatorSessionID: UUID,
        pace: CoordinatorMissionPolicyPace
    ) async -> DirectiveSubmissionResult {
        guard let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == coordinatorSessionID }) else {
            let message = "Coordinator session \(coordinatorSessionID.uuidString) is not available in this window."
            composerNotice = message
            return .rejected(message: message)
        }
        guard let plan = option.missionPlan else {
            let message = "Coordinator session \(coordinatorSessionID.uuidString) does not have a Mission Plan yet."
            composerNotice = message
            return .rejected(message: message)
        }
        if plan.pendingRevisionProposal != nil
            || plan.revisionProposalDurabilityHold?.outcome == .invalidatedContractChanged
        {
            return await applyPendingProposalMissionDialOverride(
                coordinatorSessionID: coordinatorSessionID,
                plan: plan,
                pace: pace,
                childAsk: nil
            )
        }
        if plan.revisionProposalDurabilityHold != nil {
            let message = CoordinatorMissionRevisionProposalPause.heldReason
            composerNotice = message
            return .rejected(message: message)
        }
        guard !plan.status.isTerminal else {
            let message = "Mission pace cannot be changed after the Mission is \(plan.status.rawValue)."
            composerNotice = message
            return .rejected(message: message)
        }

        selectCoordinator(sessionID: coordinatorSessionID)
        refresh()
        setMissionPaceSelection(pace)
        composerNotice = nil
        return .accepted
    }

    @discardableResult
    func setCoordinatorMissionAutonomy(
        coordinatorSessionID: UUID,
        autonomyClassKey: String,
        mode: CoordinatorMissionAutonomyMode
    ) async -> DirectiveSubmissionResult {
        guard let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == coordinatorSessionID }) else {
            let message = "Coordinator session \(coordinatorSessionID.uuidString) is not available in this window."
            composerNotice = message
            return .rejected(message: message)
        }
        guard CoordinatorMissionAutonomyClasses.definition(for: autonomyClassKey) != nil else {
            let message = "Mission autonomy can only be changed for known autonomy classes."
            composerNotice = message
            return .rejected(message: message)
        }
        guard let plan = option.missionPlan else {
            let message = "Coordinator session \(coordinatorSessionID.uuidString) does not have a Mission Plan yet."
            composerNotice = message
            return .rejected(message: message)
        }
        if plan.pendingRevisionProposal != nil
            || plan.revisionProposalDurabilityHold?.outcome == .invalidatedContractChanged
        {
            guard autonomyClassKey == CoordinatorMissionAutonomyClasses.childAsk.key else {
                let message = "Mission autonomy class \(autonomyClassKey) is not exposed as a live dial."
                composerNotice = message
                return .rejected(message: message)
            }
            return await applyPendingProposalMissionDialOverride(
                coordinatorSessionID: coordinatorSessionID,
                plan: plan,
                pace: nil,
                childAsk: mode
            )
        }
        if plan.revisionProposalDurabilityHold != nil {
            let message = CoordinatorMissionRevisionProposalPause.heldReason
            composerNotice = message
            return .rejected(message: message)
        }
        guard !plan.status.isTerminal else {
            let message = "Mission autonomy cannot be changed after the Mission is \(plan.status.rawValue)."
            composerNotice = message
            return .rejected(message: message)
        }

        selectCoordinator(sessionID: coordinatorSessionID)
        refresh()
        switch autonomyClassKey {
        case CoordinatorMissionAutonomyClasses.childAsk.key:
            setChildAskSelection(mode)
        default:
            let message = "Mission autonomy class \(autonomyClassKey) is not exposed as a live dial."
            composerNotice = message
            return .rejected(message: message)
        }
        composerNotice = nil
        return .accepted
    }

    private func recordFreshMissionPolicySnapshotIfNeeded(
        _ policySnapshot: CoordinatorMissionPolicySnapshot?,
        objective: String,
        previousCoordinatorIDs: Set<UUID>
    ) {
        guard let policySnapshot else { return }
        guard let coordinatorSessionID = freshCoordinatorSessionID(previousCoordinatorIDs: previousCoordinatorIDs) else {
            composerNotice = "Mission started, but the policy snapshot could not be recorded because the new runtime is not visible yet."
            return
        }
        do {
            try missionPlanUpdater(
                coordinatorSessionID,
                CoordinatorMissionPlanUpdate(
                    objective: objective,
                    policySnapshot: policySnapshot,
                    autonomy: policySnapshot.autonomy,
                    updatedAt: Date()
                )
            )
            refresh()
        } catch {
            composerNotice = "Mission started, but the policy snapshot could not be recorded: \(error.localizedDescription)"
        }
    }

    private func freshCoordinatorSessionID(previousCoordinatorIDs: Set<UUID>) -> UUID? {
        let input = inputProvider(sortMode, nil)
        let newCoordinatorIDs = coordinatorSessionIDs(in: input).subtracting(previousCoordinatorIDs)
        if let newestCoordinatorID = newestCoordinatorID(in: newCoordinatorIDs, input: input) {
            return newestCoordinatorID
        }
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID,
              !previousCoordinatorIDs.contains(coordinatorSessionID)
        else { return nil }
        return coordinatorSessionID
    }

    private static func providerText(
        _ baseText: String,
        policySnapshot: CoordinatorMissionPolicySnapshot?
    ) -> String {
        guard let policySnapshot else { return baseText }
        let policyLines = policyProviderLines(for: policySnapshot)
        guard !policyLines.isEmpty else { return baseText }
        return ([baseText + CoordinatorMissionPolicyProviderText.providerOnlyMarker] + policyLines).joined(separator: "\n")
    }

    private static func policyProviderLines(for policySnapshot: CoordinatorMissionPolicySnapshot) -> [String] {
        var lines = [
            "Policy: \(policySnapshot.name) [\(policySnapshot.id)]",
            "Default pace: \(policySnapshot.defaultPace.rawValue)",
            "Max concurrent child sessions: \(policySnapshot.maxConcurrent)",
            "Autonomy: \(policySnapshot.autonomy.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ", "))"
        ]
        if let definitionOfDone = policySnapshot.definitionOfDone {
            lines.append("Definition of Done: \(definitionOfDone)")
        }
        if let standingGuidance = policySnapshot.standingGuidance {
            lines.append("Standing guidance: \(standingGuidance)")
        }
        if !policySnapshot.pinnedSkillIDs.isEmpty {
            lines.append("Pinned skills: \(policySnapshot.pinnedSkillIDs.joined(separator: ", "))")
        }
        if !policySnapshot.pinnedContextIDs.isEmpty {
            lines.append("Pinned context: \(policySnapshot.pinnedContextIDs.joined(separator: ", "))")
        }
        return lines
    }

    var canStopSelectedCoordinatorMission: Bool {
        guard snapshot.coordinatorRail.state == .selected,
              snapshot.coordinatorRail.isLiveInCurrentWindow,
              let plan = snapshot.coordinatorRail.missionPlan,
              !plan.status.isTerminal
        else { return false }
        return true
    }

    @discardableResult
    func stopSelectedCoordinatorMission() async -> DirectiveSubmissionResult {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else {
            let message = "No Coordinator Mission is selected."
            composerNotice = message
            return .rejected(message: message)
        }
        return await stopCoordinatorMission(targetMissionID: coordinatorSessionID)
    }

    @discardableResult
    func stopCoordinatorMission(targetMissionID coordinatorSessionID: UUID) async -> DirectiveSubmissionResult {
        refresh()
        guard let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == coordinatorSessionID }) else {
            let message = "Coordinator Mission \(coordinatorSessionID.uuidString) is not available in this window."
            composerNotice = message
            return .rejected(message: message)
        }
        guard var plan = option.missionPlan else {
            let message = "Coordinator Mission \(coordinatorSessionID.uuidString) does not have a Mission Plan to stop."
            composerNotice = message
            return .rejected(message: message)
        }
        let targetSessionIDs = coordinatorMissionStopTargetSessionIDs(
            coordinatorSessionID: coordinatorSessionID,
            missionPlan: plan
        )
        if plan.status.isTerminal,
           plan.revisionProposalDurabilityHold?.outcome != .stopped
        {
            let message = "Mission is already \(plan.status.rawValue). Stop accepted as a no-op."
            composerNotice = message
            appendCoordinatorEventTranscriptEntry(message)
            refresh()
            return .accepted
        }

        let stoppedAt = Date()
        do {
            if plan.pendingRevisionProposal != nil
                || plan.revisionProposalDurabilityHold != nil,
                let trustedMissionStopRecorder
            {
                try await trustedMissionStopRecorder(coordinatorSessionID, targetSessionIDs)
            } else {
                let decision = stoppedMissionDecision(
                    coordinatorSessionID: coordinatorSessionID,
                    plan: plan,
                    timestamp: stoppedAt
                )
                plan.stopMission(cancelledSessionIDs: Set(targetSessionIDs), at: stoppedAt)
                try missionPlanUpdater(
                    coordinatorSessionID,
                    CoordinatorMissionPlanUpdate(
                        status: plan.status,
                        nodes: plan.nodes,
                        routingDecisions: plan.routingDecisions,
                        decisions: [decision],
                        events: [
                            CoordinatorMissionPlanEvent(
                                kind: .revised,
                                timestamp: stoppedAt,
                                summary: "Mission stopped by user."
                            )
                        ],
                        updatedAt: stoppedAt
                    )
                )
            }
        } catch {
            let message = "Mission stop could not be recorded; cancellation was not started: \(error.localizedDescription)"
            composerNotice = message
            refresh()
            return .rejected(message: message)
        }
        refresh()

        let result = await missionStopper(CoordinatorMissionStopRequest(
            coordinatorSessionID: coordinatorSessionID,
            sessionIDs: targetSessionIDs
        ))
        let message = coordinatorMissionStopMessage(result)
        composerNotice = message
        appendCoordinatorEventTranscriptEntry(message)
        refresh()
        return .accepted
    }

    private func coordinatorMissionStopMessage(_ result: CoordinatorMissionStopResult) -> String {
        let cancelledCount = result.cancelledSessionIDs.count
        let skippedCount = result.skippedSessionIDs.count
        let cancelledText = "\(cancelledCount) active \(cancelledCount == 1 ? "session" : "sessions")"
        if result.requestedSessionIDs.isEmpty {
            return "Mission stopped. No live Coordinator-linked sessions required cancellation."
        }
        guard skippedCount > 0 else {
            return "Mission stopped. Requested cancellation for \(cancelledText)."
        }
        let skippedText = "\(skippedCount) inactive or unavailable linked \(skippedCount == 1 ? "session" : "sessions")"
        return "Mission stopped. Requested cancellation for \(cancelledText); skipped \(skippedText)."
    }

    @discardableResult
    func refreshIfVisible() -> Bool {
        guard isVisible else { return false }
        refresh()
        return true
    }

    func selectCoordinator(sessionID: UUID?, workspaceID explicitWorkspaceID: UUID? = nil) {
        let workspaceID = explicitWorkspaceID ?? snapshot.workspaceID ?? inputProvider(sortMode, nil).workspaceID
        guard let workspaceID else { return }
        if sessionID != nil {
            isFreshCoordinatorRunPending = false
        }
        coordinatorSelectionByWorkspaceID[workspaceID] = sessionID.map(CoordinatorSelectionState.session) ?? .newDraft
        railDestination = .mission
        if boardScope != .coordinatorFleet {
            boardScope = .coordinatorFleet
        } else {
            refresh()
        }
        if let sessionID,
           let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == sessionID }),
           option.isPersistedOnly || !option.isLiveInCurrentWindow
        {
            Task { @MainActor in
                await coordinatorActivationHandler(sessionID)
                refresh()
            }
        }
    }

    func startNewCoordinatorRun(coordinatorModelID: String? = nil) {
        isFreshCoordinatorRunPending = true
        let trimmedCoordinatorModelID = coordinatorModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingFreshCoordinatorModelID = trimmedCoordinatorModelID?.isEmpty == false ? trimmedCoordinatorModelID : nil
        displayedTranscriptCoordinatorSessionID = nil
        lastDurableRailStatusEntryKey = nil
        displayedDelegateActionTargetIDs.removeAll()
        railTranscriptEntries.removeAll()
        currentRailActivityText = nil
        lastPublishedFingerprint = nil
        if let workspaceID = snapshot.workspaceID ?? inputProvider(sortMode, nil).workspaceID {
            coordinatorSelectionByWorkspaceID[workspaceID] = .newDraft
        }
        railDestination = .mission
        if boardScope != .coordinatorFleet {
            boardScope = .coordinatorFleet
        } else {
            refresh()
        }
        composerNotice = nil
    }

    func togglePinnedCoordinator(_ option: CoordinatorModeCoordinatorOption) {
        coordinatorPinHandler(option, !option.isPinned)
        refresh()
    }

    func archiveCoordinatorMission(sessionID: UUID) async -> CoordinatorArchiveMissionResult {
        refresh()
        guard let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == sessionID }) else {
            let message = "Coordinator session \(sessionID.uuidString) is not available in this window."
            composerNotice = message
            return .rejected(message)
        }
        guard let plan = option.missionPlan else {
            let message = "Coordinator session \(sessionID.uuidString) does not have a Mission Plan yet. Archive is only available after a Mission is completed or stopped."
            composerNotice = message
            return .rejected(message)
        }
        guard plan.status.isTerminal else {
            let message = "Archive is only available after a Mission is completed or stopped. Stop the Mission first with coordinator_chat op=stop_mission, then archive it."
            composerNotice = message
            return .rejected(message)
        }
        let result = await coordinatorArchiveHandler(option)
        refresh()
        if result.accepted {
            composerNotice = nil
        } else {
            composerNotice = result.message
        }
        return result
    }

    func clearCoordinator() {
        clearCoordinatorRailTranscript()
    }

    func clearCoordinatorRailTranscript() {
        railTranscriptEntries.removeAll()
        lastDurableRailStatusEntryKey = nil
        displayedDelegateActionTargetIDs.removeAll()
        currentRailActivityText = nil
        composerNotice = nil
    }

    func setUsesAutoMode(_ usesAutoMode: Bool) {
        setExecutionPace(usesAutoMode ? .auto : .step)
    }

    func setExecutionPace(_ executionPace: CoordinatorExecutionPace) {
        setMissionPaceSelection(executionPace.missionPolicyPace)
    }

    func setMissionPaceSelection(_ pace: CoordinatorMissionPolicyPace) {
        guard missionPaceSelection != pace else { return }
        let pendingEventBeforeChange = pendingFollowThroughEvent
        missionPaceSelection = pace
        executionPace = CoordinatorExecutionPace(pace)
        CoordinatorModeAutomationPreference.setExecutionPace(executionPace, defaults: userDefaults)

        if snapshot.coordinatorRail.state == .chooseCoordinator || snapshot.coordinatorRail.missionPlan == nil {
            draftDialOverridesPolicy = true
        } else {
            applyMissionPaceOverride(pace)
        }

        pendingFollowThroughEvent = pace == .auto
            ? nil
            : pendingFollowThroughEventProvider(snapshot.coordinatorRail.coordinatorSessionID)
        if pace == .auto,
           snapshot.coordinatorRail.isComposerSendEnabled,
           let pendingEventBeforeChange
        {
            Task { @MainActor in
                await submitPendingFollowThroughEvent(pendingEventBeforeChange)
            }
        }
    }

    func setChildAskSelection(_ mode: CoordinatorMissionAutonomyMode) {
        guard childAskSelection != mode else { return }
        childAskSelection = mode
        if snapshot.coordinatorRail.state == .chooseCoordinator || snapshot.coordinatorRail.missionPlan == nil {
            draftDialOverridesPolicy = true
        } else {
            applyMissionChildAskOverride(mode)
        }
    }

    private func applyMissionPaceOverride(_ pace: CoordinatorMissionPolicyPace) {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID,
              let plan = snapshot.coordinatorRail.missionPlan
        else { return }
        var policySnapshot = plan.policySnapshot ?? CoordinatorMissionPolicySnapshot.defaultPolicy
        policySnapshot.defaultPace = pace
        let timestamp = Date()
        applyMissionDialOverride(
            coordinatorSessionID: coordinatorSessionID,
            plan: plan,
            policySnapshot: policySnapshot,
            autonomy: nil,
            label: pace == .auto ? .setPaceToAuto : .setPaceToStep,
            decisionClass: .advance,
            checkpointSubject: "pace",
            timestamp: timestamp
        )
    }

    private func applyMissionChildAskOverride(_ mode: CoordinatorMissionAutonomyMode) {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID,
              let plan = snapshot.coordinatorRail.missionPlan
        else { return }
        let key = CoordinatorMissionAutonomyClasses.childAsk.key
        var policySnapshot = plan.policySnapshot ?? CoordinatorMissionPolicySnapshot.defaultPolicy
        var autonomy = plan.autonomy
        if autonomy.isEmpty {
            autonomy = policySnapshot.autonomy
        }
        policySnapshot.autonomy[key] = mode
        autonomy[key] = mode
        let timestamp = Date()
        let applied = applyMissionDialOverride(
            coordinatorSessionID: coordinatorSessionID,
            plan: plan,
            policySnapshot: policySnapshot,
            autonomy: autonomy,
            label: mode == .ask ? .routedChildQuestionsToMe : .routedChildQuestionsToDirector,
            decisionClass: .childAsk,
            checkpointSubject: "childAsk",
            timestamp: timestamp
        )
        if applied, mode == .auto {
            Task { @MainActor [weak self] in
                await self?.followThroughEvaluationHandler(coordinatorSessionID)
            }
        }
    }

    private func applyPendingProposalMissionDialOverride(
        coordinatorSessionID: UUID,
        plan: CoordinatorMissionPlan,
        pace: CoordinatorMissionPolicyPace?,
        childAsk: CoordinatorMissionAutonomyMode?
    ) async -> DirectiveSubmissionResult {
        guard let proposalID = plan.pendingRevisionProposal?.id
            ?? plan.revisionProposalDurabilityHold?.proposalID
        else {
            return .rejected(message: "No pending revision proposal transaction is available to invalidate.")
        }
        guard let trustedContractChangeApplier else {
            let message = CoordinatorMissionRevisionProposalPause.heldReason
            composerNotice = message
            return .rejected(message: message)
        }
        var policySnapshot = plan.policySnapshot ?? CoordinatorMissionPolicySnapshot.defaultPolicy
        var autonomy = plan.autonomy.isEmpty ? policySnapshot.autonomy : plan.autonomy
        let subject: String
        let label: CoordinatorMissionUserDecisionLabel
        let decisionClass: CoordinatorMissionDecisionClass
        if let pace {
            policySnapshot.defaultPace = pace
            subject = "pace"
            label = pace == .auto ? .setPaceToAuto : .setPaceToStep
            decisionClass = .advance
        } else if let childAsk {
            let key = CoordinatorMissionAutonomyClasses.childAsk.key
            policySnapshot.autonomy[key] = childAsk
            autonomy[key] = childAsk
            subject = "childAsk"
            label = childAsk == .ask ? .routedChildQuestionsToMe : .routedChildQuestionsToDirector
            decisionClass = .childAsk
        } else {
            return .rejected(message: "No Mission contract change was requested.")
        }
        let timestamp = Date()
        let checkpointInstanceID = [
            "mission-policy",
            coordinatorSessionID.uuidString,
            proposalID.uuidString,
            subject
        ].joined(separator: ":")
        let decisionID = CoordinatorMissionStableIdentity.uuid(
            namespace: "coordinator-mission-policy-contract-change",
            parts: [checkpointInstanceID, label.rawValue]
        )
        let decision = CoordinatorMissionDecisionRecord(
            id: decisionID,
            decisionClass: decisionClass.rawValue,
            actor: .user,
            label: label.rawValue,
            timestamp: timestamp,
            sessionID: coordinatorSessionID,
            checkpointID: Self.missionPolicyOverrideCheckpointID,
            checkpointInstanceID: checkpointInstanceID
        )
        do {
            try await trustedContractChangeApplier(
                coordinatorSessionID,
                CoordinatorMissionPlanUpdate(
                    policySnapshot: policySnapshot,
                    autonomy: childAsk == nil ? nil : autonomy,
                    decisions: [decision],
                    updatedAt: timestamp
                )
            )
            if let pace {
                missionPaceSelection = pace
                executionPace = CoordinatorExecutionPace(pace)
                CoordinatorModeAutomationPreference.setExecutionPace(executionPace, defaults: userDefaults)
            }
            if let childAsk {
                childAskSelection = childAsk
            }
            refresh()
            composerNotice = nil
            return .accepted
        } catch {
            let message = "Mission policy could not be durably updated: \(error.localizedDescription)"
            composerNotice = message
            refresh()
            return .rejected(message: message)
        }
    }

    @discardableResult
    private func applyMissionDialOverride(
        coordinatorSessionID: UUID,
        plan: CoordinatorMissionPlan,
        policySnapshot: CoordinatorMissionPolicySnapshot,
        autonomy: [String: CoordinatorMissionAutonomyMode]?,
        label: CoordinatorMissionUserDecisionLabel,
        decisionClass: CoordinatorMissionDecisionClass,
        checkpointSubject: String,
        timestamp: Date
    ) -> Bool {
        let checkpointInstanceID = [
            "mission-policy",
            coordinatorSessionID.uuidString,
            "r\(plan.revision)",
            checkpointSubject,
            "\(timestamp.timeIntervalSince1970)"
        ].joined(separator: ":")
        let record = CoordinatorMissionDecisionRecord(
            decisionClass: decisionClass.rawValue,
            actor: .user,
            label: label.rawValue,
            timestamp: timestamp,
            sessionID: coordinatorSessionID,
            checkpointID: Self.missionPolicyOverrideCheckpointID,
            checkpointInstanceID: checkpointInstanceID
        )
        do {
            try missionPlanUpdater(
                coordinatorSessionID,
                CoordinatorMissionPlanUpdate(
                    policySnapshot: policySnapshot,
                    autonomy: autonomy,
                    decisions: [record],
                    updatedAt: timestamp
                )
            )
            refresh()
            return true
        } catch {
            composerNotice = "Mission policy could not be updated: \(error.localizedDescription)"
            return false
        }
    }

    func missionComposerContext() -> MissionComposerContext {
        let rail = snapshot.coordinatorRail
        guard rail.state == .selected,
              let coordinatorSessionID = rail.coordinatorSessionID
        else {
            return MissionComposerContext(
                route: .ordinary(coordinatorSessionID: rail.coordinatorSessionID),
                placeholder: "Message the Director..."
            )
        }
        return missionComposerContext(for: coordinatorSessionID)
    }

    private func missionComposerContext(for coordinatorSessionID: UUID) -> MissionComposerContext {
        guard let plan = snapshot.coordinatorRail.availableCoordinators
            .first(where: { $0.sessionID == coordinatorSessionID })?
            .missionPlan,
            !plan.status.isTerminal
        else {
            return MissionComposerContext(
                route: .ordinary(coordinatorSessionID: coordinatorSessionID),
                placeholder: "Message the Director..."
            )
        }
        if plan.hasRevisionProposalDurabilityHold {
            return MissionComposerContext(
                route: .unavailableRevision(
                    coordinatorSessionID: coordinatorSessionID,
                    reason: CoordinatorMissionRevisionProposalPause.heldReason
                ),
                placeholder: "Waiting for the plan decision to become durable..."
            )
        }
        guard let presentation = CoordinatorPlanRevisionPresentation.project(
            coordinatorSessionID: coordinatorSessionID,
            plan: plan
        ) else {
            return MissionComposerContext(
                route: .ordinary(coordinatorSessionID: coordinatorSessionID),
                placeholder: "Message the Director..."
            )
        }

        switch presentation.phase {
        case .pendingDecision:
            guard let fingerprint = presentation.expectedContractFingerprint,
                  let checkpoint = presentation.expectedCheckpointInstanceID
            else {
                return MissionComposerContext(
                    route: .unavailableRevision(
                        coordinatorSessionID: coordinatorSessionID,
                        reason: CoordinatorMissionRevisionProposalPause.heldReason
                    ),
                    placeholder: "Refresh Mission revision state..."
                )
            }
            return MissionComposerContext(
                route: .pendingRevisionProposal(
                    coordinatorSessionID: coordinatorSessionID,
                    proposalID: presentation.proposalID,
                    expectedContractFingerprint: fingerprint,
                    expectedCheckpointInstanceID: checkpoint
                ),
                placeholder: "Revise plan, and consider..."
            )
        case .drafting:
            guard let resolution = plan.acceptedRevisionDraftingResolution else {
                return MissionComposerContext(
                    route: .unavailableRevision(
                        coordinatorSessionID: coordinatorSessionID,
                        reason: CoordinatorMissionRevisionProposalPause.heldReason
                    ),
                    placeholder: "Refresh Mission revision state..."
                )
            }
            return MissionComposerContext(
                route: .acceptedRevisionDrafting(
                    coordinatorSessionID: coordinatorSessionID,
                    resolutionID: resolution.id
                ),
                placeholder: "Add guidance for the revised plan..."
            )
        case .revisedPlanReady:
            guard let resolution = plan.latestAcceptedRevisionLineage?.resolution else {
                return MissionComposerContext(
                    route: .unavailableRevision(
                        coordinatorSessionID: coordinatorSessionID,
                        reason: CoordinatorMissionRevisionProposalPause.heldReason
                    ),
                    placeholder: "Refresh Mission revision state..."
                )
            }
            return MissionComposerContext(
                route: .revisedPlanAwaitingApproval(
                    coordinatorSessionID: coordinatorSessionID,
                    planID: plan.id,
                    planRevision: plan.revision,
                    expectedCheckpointInstanceID: planApprovalCheckpointInstanceID(
                        coordinatorSessionID: coordinatorSessionID,
                        revision: plan.revision
                    ),
                    resolutionID: resolution.id
                ),
                placeholder: "Request another change..."
            )
        case .approvedCollapsed, .keptCurrentPlanCollapsed:
            return MissionComposerContext(
                route: .ordinary(coordinatorSessionID: coordinatorSessionID),
                placeholder: "Message the Director..."
            )
        }
    }

    @discardableResult
    func submitMissionComposerDirective(
        _ text: String,
        context: MissionComposerContext
    ) async -> DirectiveSubmissionResult {
        switch context.route {
        case .pendingRevisionProposal:
            let message = "Choose Revise plan on the Plan Revision card to attach this guidance. Sending guidance alone cannot decide the proposal."
            composerNotice = message
            return .rejected(message: message)
        case let .acceptedRevisionDrafting(coordinatorSessionID, resolutionID):
            return await submitAcceptedRevisionDraftingDirective(
                text,
                coordinatorSessionID: coordinatorSessionID,
                expectedResolutionID: resolutionID
            )
        case let .revisedPlanAwaitingApproval(
            coordinatorSessionID,
            planID,
            planRevision,
            expectedCheckpointInstanceID,
            resolutionID
        ):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                composerNotice = nil
                return .rejected(message: "")
            }
            guard snapshot.coordinatorRail.coordinatorSessionID == coordinatorSessionID,
                  snapshot.coordinatorRail.isComposerEnabled,
                  snapshot.coordinatorRail.isComposerSendEnabled,
                  let trustedRevisedPlanChangeRequester
            else {
                let message = "Mission revision request is unavailable. Refresh Mission status and retry."
                composerNotice = message
                return .rejected(message: message)
            }
            do {
                try await trustedRevisedPlanChangeRequester(
                    coordinatorSessionID,
                    planID,
                    planRevision,
                    expectedCheckpointInstanceID,
                    resolutionID
                )
                refresh()
            } catch {
                let message = "Mission revision request was not durably recorded; no guidance was sent. Refresh Mission status and retry. \(error.localizedDescription)"
                composerNotice = message
                refresh()
                return .rejected(message: message)
            }
            return await submitAcceptedRevisionDraftingDirective(
                trimmed,
                coordinatorSessionID: coordinatorSessionID,
                expectedResolutionID: resolutionID
            )
        case let .unavailableRevision(_, reason):
            composerNotice = reason
            return .rejected(message: reason)
        case let .ordinary(coordinatorSessionID):
            if let coordinatorSessionID {
                refresh()
                guard case .ordinary = missionComposerContext(for: coordinatorSessionID).route else {
                    let message = CoordinatorMissionRevisionProposalPause.heldReason
                    composerNotice = message
                    return .rejected(message: message)
                }
            }
            return await submitCoordinatorDirective(
                text,
                targetCoordinatorSessionID: coordinatorSessionID
            )
        }
    }

    private func revisionProposalAuthority(coordinatorSessionID: UUID) -> RevisionProposalAuthority {
        if let revisionProposalAuthorityProvider {
            return revisionProposalAuthorityProvider(coordinatorSessionID)
        }
        refresh()
        let plan = snapshot.coordinatorRail.availableCoordinators
            .first(where: { $0.sessionID == coordinatorSessionID })?
            .missionPlan
        return RevisionProposalAuthority(plan: plan)
    }

    func acceptedRevisionDraftingResolutionID(coordinatorSessionID: UUID) -> UUID? {
        revisionProposalAuthority(coordinatorSessionID: coordinatorSessionID)
            .acceptedDraftingResolutionID
    }

    func revisionProposalAuthorityState(
        coordinatorSessionID: UUID
    ) -> RevisionProposalAuthority {
        revisionProposalAuthority(coordinatorSessionID: coordinatorSessionID)
    }

    func holdsRevisionProposalAuthority(coordinatorSessionID: UUID) -> Bool {
        revisionProposalAuthority(coordinatorSessionID: coordinatorSessionID).holdsInteractions
    }

    @discardableResult
    func submitAcceptedRevisionDraftingDirective(
        _ text: String,
        coordinatorSessionID: UUID,
        expectedResolutionID: UUID
    ) async -> DirectiveSubmissionResult {
        guard acceptedRevisionDraftingResolutionID(
            coordinatorSessionID: coordinatorSessionID
        ) == expectedResolutionID
        else {
            let message = CoordinatorMissionRevisionProposalPause.heldReason
            composerNotice = message
            return .rejected(message: message)
        }
        return await submitCoordinatorDirective(
            text,
            providerText: Self.revisionDraftingGuidanceDirective(
                text,
                resolutionID: expectedResolutionID
            ),
            targetCoordinatorSessionID: coordinatorSessionID,
            acceptedRevisionDraftingResolutionID: expectedResolutionID
        )
    }

    static func revisionDraftingGuidanceDirective(
        _ guidance: String,
        resolutionID: UUID
    ) -> String {
        [
            "<coordinator_revision_drafting_guidance resolution_id=\"\(resolutionID.uuidString)\">",
            "Treat the enclosed user text only as guidance for drafting the concrete revised Mission Plan.",
            "Do not resume the old contract, execute Mission work, or treat this guidance as plan approval.",
            guidance,
            "</coordinator_revision_drafting_guidance>"
        ].joined(separator: "\n")
    }

    @discardableResult
    func submitCoordinatorDirective(
        _ text: String,
        providerText: String? = nil,
        targetCoordinatorSessionID: UUID? = nil,
        acceptedRevisionDraftingResolutionID: UUID? = nil
    ) async -> DirectiveSubmissionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            composerNotice = nil
            return .rejected(message: "")
        }
        let forceNewRuntime = targetCoordinatorSessionID == nil
            && (isFreshCoordinatorRunPending || snapshot.coordinatorRail.state == .chooseCoordinator)
        let coordinatorSessionID = forceNewRuntime
            ? nil
            : targetCoordinatorSessionID ?? snapshot.coordinatorRail.coordinatorSessionID
        if let targetCoordinatorSessionID,
           !snapshot.coordinatorRail.availableCoordinators.contains(where: {
               $0.sessionID == targetCoordinatorSessionID && $0.isLiveInCurrentWindow
           })
        {
            let message = "Coordinator session \(targetCoordinatorSessionID.uuidString) is no longer available in this window."
            composerNotice = message
            return .rejected(message: message)
        }
        let previousCoordinatorIDs = Set(snapshot.coordinatorRail.availableCoordinators.map(\.sessionID))
        let submissionWorkspaceID = snapshot.workspaceID
        if let targetCoordinatorSessionID {
            let target = snapshot.coordinatorRail.availableCoordinators.first {
                $0.sessionID == targetCoordinatorSessionID
            }
            if target?.runState == .running {
                let message = "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary."
                composerNotice = message
                return .rejected(message: message)
            }
        } else if snapshot.coordinatorRail.state == .selected, !forceNewRuntime {
            guard snapshot.coordinatorRail.isComposerEnabled else {
                let message = "Coordinator is not available in this window."
                composerNotice = message
                return .rejected(message: message)
            }
            guard snapshot.coordinatorRail.isComposerSendEnabled else {
                let message = "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary."
                composerNotice = message
                return .rejected(message: message)
            }
        }

        let missionPolicySnapshot = forceNewRuntime ? effectiveSelectedMissionPolicySnapshot() : nil
        let submission = CoordinatorDirectiveSubmission(
            visibleText: trimmed,
            providerText: providerText ?? Self.providerText(trimmed, policySnapshot: missionPolicySnapshot),
            missionTemplate: nil,
            missionPolicySnapshot: missionPolicySnapshot,
            coordinatorSessionID: coordinatorSessionID,
            coordinatorModelID: forceNewRuntime ? pendingFreshCoordinatorModelID : nil,
            forceNewRuntime: forceNewRuntime,
            acceptedRevisionDraftingResolutionID: acceptedRevisionDraftingResolutionID
        )
        let result = await directiveSubmitter(submission)
        switch result {
        case .accepted:
            isFreshCoordinatorRunPending = false
            pendingFreshCoordinatorModelID = nil
            composerNotice = nil
            if forceNewRuntime {
                selectFreshCoordinatorRuntimeIfAvailable(
                    previousCoordinatorIDs: previousCoordinatorIDs,
                    workspaceID: submissionWorkspaceID
                )
                recordFreshMissionPolicySnapshotIfNeeded(
                    submission.missionPolicySnapshot,
                    objective: submission.visibleText,
                    previousCoordinatorIDs: previousCoordinatorIDs
                )
                selectedMissionPolicy = .defaultPolicy
                syncDraftDialSelectionsFromSelectedPolicy()
            }
            let acceptedDirectiveDecision = pendingAcceptedDirectiveDecision
            pendingAcceptedDirectiveDecision = nil
            refresh()
            if let acceptedDirectiveDecision {
                appendMissionUserDecision(acceptedDirectiveDecision)
            }
            appendUserTranscriptEntryIfMissing(submission.visibleText)
        case let .rejected(message):
            composerNotice = message.isEmpty ? nil : message
        }
        return result
    }

    @discardableResult
    func submitCoordinatorContinuation(
        _ action: ContinuationAction,
        expectedCheckpointInstanceID: String? = nil
    ) async -> DirectiveSubmissionResult {
        let checkpointContext: PlanApprovalCheckpointContext?
        if action.requiresCurrentPlanApprovalCheckpoint {
            do {
                checkpointContext = try currentPlanApprovalCheckpointContext(expected: expectedCheckpointInstanceID)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                composerNotice = message
                return .rejected(message: message)
            }
        } else {
            checkpointContext = nil
        }

        if action == .stopHere {
            guard let targetMissionID = snapshot.coordinatorRail.coordinatorSessionID else {
                let message = "No Coordinator Mission is selected."
                composerNotice = message
                return .rejected(message: message)
            }
            return await stopCoordinatorMission(targetMissionID: targetMissionID)
        }

        pendingAcceptedDirectiveDecision = nil
        if action == .proceed, let checkpointContext {
            let approvalResult = approvePlan(checkpointContext)
            guard approvalResult == .accepted else { return approvalResult }
            guard recordPostApprovalContinuationDeferral(
                checkpointContext.coordinatorSessionID,
                error: "Approved continuation is queued for the next ordinary turn boundary."
            ) else {
                let message = "Mission approval was recorded, but the post-approval continuation could not be queued durably. The Director was not resumed. Refresh Mission status and retry."
                composerNotice = message
                return .rejected(message: message)
            }
            guard let persistenceToken = postApprovalContinuationPersistenceToken(for: checkpointContext) else {
                let message = "Mission approval was recorded, but the post-approval continuation record is missing. The Director was not resumed. Refresh Mission status and retry."
                composerNotice = message
                return .rejected(message: message)
            }
            do {
                try await postApprovalContinuationPersistenceBarrier(persistenceToken)
            } catch {
                let errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let message = "Mission approval was recorded, but durable continuation persistence failed. The Director was not resumed. \(errorMessage)"
                durableApprovalAuthorityTokensByCoordinatorID.removeValue(forKey: checkpointContext.coordinatorSessionID)
                _ = recordPostApprovalContinuationFailure(checkpointContext.coordinatorSessionID, error: message)
                composerNotice = message
                return .rejected(message: message)
            }
            guard confirmDurableApprovalAuthority(checkpointContext.coordinatorSessionID) else {
                let message = "Mission approval was recorded, but durable approval authority could not be confirmed. The Director was not resumed. Refresh Mission status and retry."
                _ = recordPostApprovalContinuationFailure(checkpointContext.coordinatorSessionID, error: message)
                composerNotice = message
                return .rejected(message: message)
            }
            refresh()
            guard let authorityToken = snapshot.coordinatorRail.availableCoordinators
                .first(where: { $0.sessionID == checkpointContext.coordinatorSessionID })?
                .missionPlan?
                .expectedDurableApprovalAuthorityToken
            else {
                let message = "Mission approval was recorded, but durable approval authority could not be confirmed. The Director was not resumed. Refresh Mission status and retry."
                _ = recordPostApprovalContinuationFailure(checkpointContext.coordinatorSessionID, error: message)
                composerNotice = message
                return .rejected(message: message)
            }
            durableApprovalAuthorityTokensByCoordinatorID[checkpointContext.coordinatorSessionID] = authorityToken
            composerNotice = "Mission plan approved. The authorized continuation is queued and will be delivered once at the next ordinary turn boundary."
            Task { @MainActor [followThroughEvaluationHandler] in
                await followThroughEvaluationHandler(checkpointContext.coordinatorSessionID)
            }
            return .accepted
        }

        if action == .startSmaller, let checkpointContext {
            let revisionResult = requestPlanRevision(checkpointContext)
            guard revisionResult == .accepted else { return revisionResult }
            let resumeResult = await submitCoordinatorDirective(action.directiveText)
            if case let .rejected(message) = resumeResult {
                composerNotice = "Plan revision requested. Director could not be resumed automatically: \(message)"
            }
            return .accepted
        }

        return await submitCoordinatorDirective(action.directiveText)
    }

    @discardableResult
    func requestSelectedPlanRevision() -> Bool {
        do {
            let context = try currentPlanApprovalCheckpointContext(expected: nil, requireExpectedInstance: false)
            return requestPlanRevision(context) == .accepted
        } catch {
            composerNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    @discardableResult
    func submitPlanRevisionDirective(_ text: String) async -> DirectiveSubmissionResult {
        do {
            let targetCoordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID
            let revisionResult: DirectiveSubmissionResult
            if let coordinatorSessionID = targetCoordinatorSessionID,
               let proposal = snapshot.coordinatorRail.missionPlan?.pendingRevisionProposal
            {
                revisionResult = await submitRevisionProposalAction(
                    coordinatorSessionID: coordinatorSessionID,
                    action: .revisePlan,
                    proposalID: proposal.id,
                    expectedContractFingerprint: proposal.baseContractFingerprint,
                    expectedCheckpointInstanceID: CoordinatorMissionRevisionProposalCheckpoint.instanceID(
                        coordinatorSessionID: coordinatorSessionID,
                        proposal: proposal
                    )
                )
            } else if snapshot.coordinatorRail.missionPlan?.approvalState == .approved {
                revisionResult = try requestApprovedPlanRevision()
            } else {
                let context = try currentPlanApprovalCheckpointContext(expected: nil, requireExpectedInstance: false)
                revisionResult = requestPlanRevision(context)
            }
            guard revisionResult == .accepted else { return revisionResult }
            let submitResult = await submitCoordinatorDirective(
                text,
                targetCoordinatorSessionID: targetCoordinatorSessionID
            )
            if case let .rejected(message) = submitResult {
                composerNotice = "Plan revision requested. Director could not be resumed automatically: \(message)"
            }
            return submitResult
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            composerNotice = message
            return .rejected(message: message)
        }
    }

    @discardableResult
    func queuePlanRevisionDecisionAfterAcceptedDirective() -> Bool {
        requestSelectedPlanRevision()
    }

    @discardableResult
    func queueFollowThroughRevisionDecisionAfterAcceptedDirective(_ event: CoordinatorFollowThroughEvent) -> Bool {
        pendingAcceptedDirectiveDecision = followThroughDecision(
            event: event,
            label: .requestedPlanRevision,
            decisionClass: .advance,
            checkpointID: Self.stepCheckInCheckpointID,
            timestamp: Date()
        )
        return true
    }

    func activePendingFollowThroughEvent() -> CoordinatorFollowThroughEvent? {
        guard !usesAutoMode else { return nil }
        return pendingFollowThroughEvent
    }

    @discardableResult
    func submitPendingFollowThroughEvent(_ event: CoordinatorFollowThroughEvent) async -> DirectiveSubmissionResult {
        let pendingDecision = followThroughDecision(
            event: event,
            label: .continuedPastStepCheckIn,
            decisionClass: .advance,
            checkpointID: Self.stepCheckInCheckpointID,
            timestamp: Date()
        )
        let result = await followThroughEventSubmitter(event)
        switch result {
        case .accepted:
            composerNotice = nil
            appendMissionUserDecision(pendingDecision)
        case let .rejected(message):
            composerNotice = message.isEmpty ? nil : message
        }
        refresh()
        return result
    }

    func resolvePendingFollowThroughEvent(_ event: CoordinatorFollowThroughEvent) async {
        await followThroughEventResolver(event)
        refresh()
    }

    private static let planApprovalCheckpointID = "plan-approval"
    private static let stepCheckInCheckpointID = "step-check-in"
    private static let childQuestionCheckpointID = "child-question"
    private static let missionStopCheckpointID = "mission-stop"
    private static let missionPolicyOverrideCheckpointID = "mission-policy-override"

    private struct PlanApprovalCheckpointContext: Equatable {
        let coordinatorSessionID: UUID
        let planID: UUID
        let revision: Int
        let checkpointInstanceID: String
    }

    private func missionUserDecisionRecord(for action: ContinuationAction) -> PendingMissionUserDecision? {
        switch action {
        case .proceed:
            return planApprovalDecision(label: .approvedMissionPlan, timestamp: Date())
        case .startSmaller:
            return planApprovalDecision(label: .requestedPlanRevision, timestamp: Date())
        case .stopHere:
            guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID,
                  let plan = snapshot.coordinatorRail.missionPlan
            else { return nil }
            return PendingMissionUserDecision(
                coordinatorSessionID: coordinatorSessionID,
                record: stoppedMissionDecision(
                    coordinatorSessionID: coordinatorSessionID,
                    plan: plan,
                    timestamp: Date()
                )
            )
        case .runLightweightDiscovery, .runDeepPlan, .runDesignCritique:
            return nil
        }
    }

    private func currentPlanApprovalCheckpointContext(
        expected: String?,
        requireExpectedInstance: Bool = true
    ) throws -> PlanApprovalCheckpointContext {
        refresh()
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID,
              let plan = snapshot.coordinatorRail.missionPlan,
              !plan.nodes.isEmpty,
              !plan.status.isTerminal
        else {
            throw MCPError.invalidParams("Checkpoint approval rejected because no nonterminal Mission Plan checkpoint is currently pending. Refresh Mission status and retry.")
        }
        if plan.approvalState == .notRequired {
            try migrateLegacyNotRequiredPlanCheckpoint(coordinatorSessionID: coordinatorSessionID)
            throw MCPError.invalidParams("Legacy not_required Mission Plan checkpoint was migrated to awaiting_approval with a fresh checkpoint instance. Refresh Mission status and retry.")
        }
        guard plan.approvalState == .awaitingApproval else {
            throw MCPError.invalidParams("Checkpoint approval rejected because the Mission Plan is \(plan.approvalState.rawValue), not awaiting_approval.")
        }
        let current = planApprovalCheckpointInstanceID(
            coordinatorSessionID: coordinatorSessionID,
            revision: plan.revision
        )
        if requireExpectedInstance {
            guard let expected else {
                throw MCPError.invalidParams("Checkpoint approval rejected because the rendered checkpoint instance is missing. Refresh Mission status and retry.")
            }
            guard expected == current else {
                throw MCPError.invalidParams("Checkpoint approval rejected because the rendered checkpoint instance is stale. Current checkpoint instance is \(current). Refresh Mission status and retry.")
            }
        }
        return PlanApprovalCheckpointContext(
            coordinatorSessionID: coordinatorSessionID,
            planID: plan.id,
            revision: plan.revision,
            checkpointInstanceID: current
        )
    }

    private func planApprovalDecision(
        label: CoordinatorMissionUserDecisionLabel,
        timestamp: Date
    ) -> PendingMissionUserDecision? {
        do {
            let context = try currentPlanApprovalCheckpointContext(expected: nil, requireExpectedInstance: false)
            return PendingMissionUserDecision(
                coordinatorSessionID: context.coordinatorSessionID,
                record: planApprovalDecisionRecord(
                    label: label,
                    context: context,
                    timestamp: timestamp
                )
            )
        } catch {
            return nil
        }
    }

    private func postApprovalContinuationRecord(
        context: PlanApprovalCheckpointContext,
        directiveText: String,
        timestamp: Date
    ) -> CoordinatorPostApprovalContinuationRecord {
        let providerText = """
        <coordinator_post_approval_continuation checkpoint_instance_id=\"\(context.checkpointInstanceID)\">
        The app already persisted user approval for Mission Plan revision \(context.revision). This is the single accepted continuation authorized by that checkpoint for this live demo run; do not ask the user to submit it again.

        \(directiveText)
        </coordinator_post_approval_continuation>
        """
        return CoordinatorPostApprovalContinuationRecord(
            id: CoordinatorMissionStableIdentity.uuid(
                namespace: "coordinator-post-approval-continuation",
                parts: [context.checkpointInstanceID, directiveText]
            ),
            coordinatorSessionID: context.coordinatorSessionID,
            checkpointInstanceID: context.checkpointInstanceID,
            planID: context.planID,
            planRevision: context.revision,
            directiveText: providerText,
            status: .pending,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func planApprovalDecisionRecord(
        label: CoordinatorMissionUserDecisionLabel,
        context: PlanApprovalCheckpointContext,
        timestamp: Date
    ) -> CoordinatorMissionDecisionRecord {
        CoordinatorMissionDecisionRecord(
            userDecision: label,
            decisionClass: .plan,
            checkpointInstanceID: context.checkpointInstanceID,
            timestamp: timestamp,
            checkpointID: Self.planApprovalCheckpointID
        )
    }

    @discardableResult
    private func approvePlan(_ context: PlanApprovalCheckpointContext) -> DirectiveSubmissionResult {
        let timestamp = Date()
        do {
            try validateCurrentPlanApprovalCheckpoint(context)
            try missionPlanUpdater(
                context.coordinatorSessionID,
                CoordinatorMissionPlanUpdate(
                    status: .running,
                    approvalState: .approved,
                    decisions: [
                        planApprovalDecisionRecord(
                            label: .approvedMissionPlan,
                            context: context,
                            timestamp: timestamp
                        )
                    ],
                    events: [
                        CoordinatorMissionPlanEvent(
                            kind: .approved,
                            timestamp: timestamp,
                            summary: "Mission plan approved by user."
                        )
                    ],
                    postApprovalContinuation: postApprovalContinuationRecord(
                        context: context,
                        directiveText: ContinuationAction.proceed.directiveText,
                        timestamp: timestamp
                    ),
                    updatedAt: timestamp
                )
            )
            refresh()
            return .accepted
        } catch {
            let message = "Mission approval could not be recorded; the Director was not resumed. Refresh Mission status and retry. \(error.localizedDescription)"
            composerNotice = message
            refresh()
            return .rejected(message: message)
        }
    }

    @discardableResult
    private func requestApprovedPlanRevision() throws -> DirectiveSubmissionResult {
        refresh()
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID,
              let plan = snapshot.coordinatorRail.missionPlan,
              plan.approvalState == .approved,
              !plan.nodes.isEmpty,
              !plan.status.isTerminal
        else {
            throw MCPError.invalidParams("Approved Mission Plan revision rejected because no nonterminal approved Mission Plan is selected. Refresh Mission status and retry.")
        }
        let context = PlanApprovalCheckpointContext(
            coordinatorSessionID: coordinatorSessionID,
            planID: plan.id,
            revision: plan.revision,
            checkpointInstanceID: planRevisionCheckpointInstanceID(
                coordinatorSessionID: coordinatorSessionID,
                revision: plan.revision
            )
        )
        let timestamp = Date()
        do {
            try missionPlanUpdater(
                context.coordinatorSessionID,
                CoordinatorMissionPlanUpdate(
                    approvalState: .revisionRequested,
                    decisions: [
                        planApprovalDecisionRecord(
                            label: .requestedPlanRevision,
                            context: context,
                            timestamp: timestamp
                        )
                    ],
                    events: [
                        CoordinatorMissionPlanEvent(
                            kind: .revised,
                            timestamp: timestamp,
                            summary: "Approved Mission plan revision requested by user."
                        )
                    ],
                    updatedAt: timestamp
                )
            )
            refresh()
            return .accepted
        } catch {
            let message = "Approved plan revision request could not be recorded; the Director was not resumed. Refresh Mission status and retry. \(error.localizedDescription)"
            composerNotice = message
            refresh()
            return .rejected(message: message)
        }
    }

    @discardableResult
    private func requestPlanRevision(_ context: PlanApprovalCheckpointContext) -> DirectiveSubmissionResult {
        let timestamp = Date()
        do {
            try validateCurrentPlanApprovalCheckpoint(context)
            try missionPlanUpdater(
                context.coordinatorSessionID,
                CoordinatorMissionPlanUpdate(
                    approvalState: .revisionRequested,
                    decisions: [
                        planApprovalDecisionRecord(
                            label: .requestedPlanRevision,
                            context: context,
                            timestamp: timestamp
                        )
                    ],
                    events: [
                        CoordinatorMissionPlanEvent(
                            kind: .revised,
                            timestamp: timestamp,
                            summary: "Mission plan revision requested by user."
                        )
                    ],
                    updatedAt: timestamp
                )
            )
            refresh()
            return .accepted
        } catch {
            let message = "Plan revision request could not be recorded; the Director was not resumed. Refresh Mission status and retry. \(error.localizedDescription)"
            composerNotice = message
            refresh()
            return .rejected(message: message)
        }
    }

    @discardableResult
    private func confirmDurableApprovalAuthority(_ coordinatorSessionID: UUID) -> Bool {
        updatePostApprovalContinuation(coordinatorSessionID) { continuation in
            continuation.confirmingDurableApprovalAuthority()
        }
    }

    private func postApprovalContinuationPersistenceToken(
        for context: PlanApprovalCheckpointContext
    ) -> PostApprovalContinuationPersistenceToken? {
        refresh()
        guard let continuation = snapshot.coordinatorRail.availableCoordinators
            .first(where: { $0.sessionID == context.coordinatorSessionID })?
            .missionPlan?
            .postApprovalContinuation,
            continuation.checkpointInstanceID == context.checkpointInstanceID,
            continuation.planID == context.planID,
            continuation.planRevision == context.revision
        else { return nil }
        return PostApprovalContinuationPersistenceToken(
            coordinatorSessionID: context.coordinatorSessionID,
            continuationID: continuation.id,
            checkpointInstanceID: continuation.checkpointInstanceID,
            planID: continuation.planID,
            planRevision: continuation.planRevision
        )
    }

    private func recordPostApprovalContinuationDelivery(_ coordinatorSessionID: UUID) {
        _ = updatePostApprovalContinuation(coordinatorSessionID) { continuation in
            var state = CoordinatorFollowThroughState()
            state.recordPostApprovalContinuation(continuation)
            _ = state.markPostApprovalContinuationDelivered()
            return state.postApprovalContinuation ?? continuation
        }
    }

    @discardableResult
    private func recordPostApprovalContinuationDeferral(_ coordinatorSessionID: UUID, error: String?) -> Bool {
        updatePostApprovalContinuation(coordinatorSessionID) { continuation in
            var state = CoordinatorFollowThroughState()
            state.recordPostApprovalContinuation(continuation)
            _ = state.markPostApprovalContinuationDeferred(error: error)
            return state.postApprovalContinuation ?? continuation
        }
    }

    @discardableResult
    private func recordPostApprovalContinuationFailure(_ coordinatorSessionID: UUID, error: String) -> Bool {
        updatePostApprovalContinuation(coordinatorSessionID) { continuation in
            var state = CoordinatorFollowThroughState()
            state.recordPostApprovalContinuation(continuation)
            _ = state.markPostApprovalContinuationFailed(error: error)
            return state.postApprovalContinuation ?? continuation
        }
    }

    @discardableResult
    private func updatePostApprovalContinuation(
        _ coordinatorSessionID: UUID,
        transform: (CoordinatorPostApprovalContinuationRecord) -> CoordinatorPostApprovalContinuationRecord
    ) -> Bool {
        refresh()
        guard let continuation = snapshot.coordinatorRail.availableCoordinators
            .first(where: { $0.sessionID == coordinatorSessionID })?
            .missionPlan?
            .postApprovalContinuation
        else { return false }
        do {
            let updatedContinuation = transform(continuation)
            try missionPlanUpdater(
                coordinatorSessionID,
                CoordinatorMissionPlanUpdate(
                    postApprovalContinuation: updatedContinuation,
                    updatedAt: Date()
                )
            )
            postApprovalContinuationStatus = Self.postApprovalContinuationStatus(updatedContinuation)
            refresh()
            return true
        } catch {
            composerNotice = "Post-approval continuation state could not be updated: \(error.localizedDescription)"
            return false
        }
    }

    private func syncPostApprovalContinuationStatus(from plan: CoordinatorMissionPlan?) {
        postApprovalContinuationStatus = Self.postApprovalContinuationStatus(plan?.postApprovalContinuation)
    }

    private static func postApprovalContinuationStatus(
        _ continuation: CoordinatorPostApprovalContinuationRecord?
    ) -> PostApprovalContinuationStatus {
        guard let continuation else { return .none }
        switch continuation.status {
        case .pending, .deferred, .dispatching:
            return .deferred(checkpointInstanceID: continuation.checkpointInstanceID)
        case .delivered:
            return .delivered(checkpointInstanceID: continuation.checkpointInstanceID)
        case .failed, .invalidated:
            return .failed(
                checkpointInstanceID: continuation.checkpointInstanceID,
                message: continuation.lastError ?? continuation.status.rawValue
            )
        }
    }

    private func migrateLegacyNotRequiredPlanCheckpoint(
        coordinatorSessionID: UUID
    ) throws {
        let timestamp = Date()
        try missionPlanUpdater(
            coordinatorSessionID,
            CoordinatorMissionPlanUpdate(
                approvalState: .awaitingApproval,
                events: [
                    CoordinatorMissionPlanEvent(
                        kind: .revised,
                        timestamp: timestamp,
                        summary: "Legacy not_required Mission Plan checkpoint migrated to awaiting_approval."
                    )
                ],
                updatedAt: timestamp
            )
        )
        refresh()
    }

    private func validateCurrentPlanApprovalCheckpoint(_ context: PlanApprovalCheckpointContext) throws {
        refresh()
        guard let option = snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == context.coordinatorSessionID }),
              let plan = option.missionPlan
        else {
            throw MCPError.invalidParams("Coordinator Mission \(context.coordinatorSessionID.uuidString) is not available in this window.")
        }
        guard snapshot.coordinatorRail.coordinatorSessionID == context.coordinatorSessionID else {
            throw MCPError.invalidParams("Checkpoint target changed before the transaction could be recorded. Refresh Mission status and retry.")
        }
        guard plan.id == context.planID else {
            throw MCPError.invalidParams("Checkpoint rejected because the Mission Plan identity changed. Refresh Mission status and retry.")
        }
        guard plan.revision == context.revision else {
            let current = planApprovalCheckpointInstanceID(
                coordinatorSessionID: context.coordinatorSessionID,
                revision: plan.revision
            )
            throw MCPError.invalidParams("Checkpoint rejected because the rendered checkpoint instance is stale. Current checkpoint instance is \(current). Refresh Mission status and retry.")
        }
        if plan.approvalState == .notRequired {
            try migrateLegacyNotRequiredPlanCheckpoint(coordinatorSessionID: context.coordinatorSessionID)
            throw MCPError.invalidParams("Legacy not_required Mission Plan checkpoint was migrated to awaiting_approval with a fresh checkpoint instance. Refresh Mission status and retry.")
        }
        guard plan.approvalState == .awaitingApproval else {
            throw MCPError.invalidParams("Checkpoint rejected because the Mission Plan is \(plan.approvalState.rawValue), not awaiting_approval.")
        }
        guard !plan.nodes.isEmpty else {
            throw MCPError.invalidParams("Checkpoint rejected because the Mission Plan has no nodes to approve.")
        }
        guard !plan.status.isTerminal else {
            throw MCPError.invalidParams("Checkpoint rejected because the Mission is already \(plan.status.rawValue).")
        }
    }

    private func followThroughDecision(
        event: CoordinatorFollowThroughEvent,
        label: CoordinatorMissionUserDecisionLabel,
        decisionClass: CoordinatorMissionDecisionClass,
        checkpointID: String,
        timestamp: Date
    ) -> PendingMissionUserDecision {
        PendingMissionUserDecision(
            coordinatorSessionID: event.coordinatorSessionID,
            record: CoordinatorMissionDecisionRecord(
                userDecision: label,
                decisionClass: decisionClass,
                checkpointInstanceID: "follow-through:\(event.id)",
                timestamp: timestamp,
                sessionID: event.childSessionID ?? event.coordinatorSessionID,
                checkpointID: checkpointID
            )
        )
    }

    private func childInteractionDecision(
        row: CoordinatorModeRow,
        displayText: String,
        actor: CoordinatorMissionDecisionActor,
        timestamp: Date
    ) -> PendingMissionUserDecision? {
        guard let coordinatorSessionID = row.parentCoordinator?.sessionID ?? snapshot.coordinatorRail.coordinatorSessionID,
              let interactionID = row.pendingInteraction?.id
        else { return nil }
        let checkpointInstanceID = "child-interaction:\(interactionID.uuidString)"
        let label = CoordinatorMissionUserDecisionLabel.answeredChildQuestion
        let reason = childInteractionDecisionReason(displayText: displayText, actor: actor)
        let record = if actor == .user {
            CoordinatorMissionDecisionRecord(
                userDecision: label,
                decisionClass: .childAsk,
                checkpointInstanceID: checkpointInstanceID,
                reason: reason,
                timestamp: timestamp,
                sessionID: row.sessionID,
                interactionID: interactionID,
                checkpointID: Self.childQuestionCheckpointID
            )
        } else {
            CoordinatorMissionDecisionRecord(
                id: CoordinatorMissionStableIdentity.uuid(
                    namespace: "coordinator-mission-director-decision",
                    parts: [checkpointInstanceID, label.rawValue]
                ),
                decisionClass: CoordinatorMissionDecisionClass.childAsk.rawValue,
                actor: actor,
                label: label.rawValue,
                reason: reason,
                timestamp: timestamp,
                sessionID: row.sessionID,
                interactionID: interactionID,
                checkpointID: Self.childQuestionCheckpointID,
                checkpointInstanceID: checkpointInstanceID
            )
        }
        return PendingMissionUserDecision(
            coordinatorSessionID: coordinatorSessionID,
            record: record
        )
    }

    private func childInteractionDecisionReason(
        displayText: String,
        actor: CoordinatorMissionDecisionActor
    ) -> String? {
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch actor {
        case .user:
            guard !trimmed.isEmpty else { return nil }
            return "Answered child question with: \(trimmed)"
        case .director:
            if trimmed.isEmpty {
                return "Mission Policy routed this child question to Director."
            }
            return "Mission Policy routed this child question to Director. Answered with: \(trimmed)"
        }
    }

    private func childInteractionEvidence(
        row: CoordinatorModeRow,
        displayText: String,
        decisionID: UUID?,
        actor: CoordinatorMissionDecisionActor,
        timestamp: Date
    ) -> CoordinatorMissionEvidenceRecord? {
        guard let interactionID = row.pendingInteraction?.id else { return nil }
        let actorName = childInteractionEvidenceActorName(actor)
        let trimmedDisplayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidenceText = trimmedDisplayText.isEmpty ? "No answer text recorded." : trimmedDisplayText
        return CoordinatorMissionEvidenceRecord(
            id: CoordinatorMissionStableIdentity.uuid(
                namespace: "coordinator-mission-child-question-evidence",
                parts: [interactionID.uuidString, actor.rawValue, evidenceText]
            ),
            verdict: .meets,
            summary: "\(actorName) answered child question for \(row.title): \(evidenceText)",
            timestamp: timestamp,
            sessionID: row.sessionID,
            interactionID: interactionID,
            decisionID: decisionID,
            source: CoordinatorMissionEvidenceSource(
                kind: "child_question_answer",
                sessionID: row.sessionID,
                interactionID: interactionID,
                summary: "\(actorName)-routed child question answer."
            )
        )
    }

    private func childInteractionEvidenceActorName(_ actor: CoordinatorMissionDecisionActor) -> String {
        switch actor {
        case .user:
            "User"
        case .director:
            "Director"
        }
    }

    private func stoppedMissionDecision(
        coordinatorSessionID: UUID,
        plan: CoordinatorMissionPlan,
        timestamp: Date
    ) -> CoordinatorMissionDecisionRecord {
        CoordinatorMissionDecisionRecord(
            userDecision: .stoppedMission,
            decisionClass: .irreversible,
            checkpointInstanceID: "mission-stop:\(coordinatorSessionID.uuidString):r\(plan.revision)",
            timestamp: timestamp,
            sessionID: coordinatorSessionID,
            checkpointID: Self.missionStopCheckpointID
        )
    }

    @discardableResult
    private func appendMissionUserDecision(
        _ pendingDecision: PendingMissionUserDecision,
        evidence: CoordinatorMissionEvidenceRecord? = nil
    ) -> Bool {
        do {
            var update = CoordinatorMissionPlanUpdate(
                decisions: [pendingDecision.record],
                evidence: evidence.map { [$0] },
                updatedAt: pendingDecision.record.timestamp
            )
            if pendingDecision.record.label == CoordinatorMissionUserDecisionLabel.approvedMissionPlan.rawValue {
                update.status = .running
                update.approvalState = .approved
                update.events = [
                    CoordinatorMissionPlanEvent(
                        kind: .approved,
                        timestamp: pendingDecision.record.timestamp,
                        summary: "Mission plan approved by user."
                    )
                ]
            }
            try missionPlanUpdater(
                pendingDecision.coordinatorSessionID,
                update
            )
            refresh()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func appendMissionChildInteractionDecision(
        _ pendingDecision: PendingMissionUserDecision,
        evidence: CoordinatorMissionEvidenceRecord?,
        actor: CoordinatorMissionDecisionActor
    ) -> Bool {
        if actor == .user {
            return appendMissionUserDecision(pendingDecision, evidence: evidence)
        }
        do {
            try missionPlanUpdater(
                pendingDecision.coordinatorSessionID,
                CoordinatorMissionPlanUpdate(
                    decisions: [pendingDecision.record],
                    evidence: evidence.map { [$0] },
                    updatedAt: pendingDecision.record.timestamp
                )
            )
            refresh()
            return true
        } catch {
            return false
        }
    }

    private func planApprovalCheckpointInstanceID(coordinatorSessionID: UUID, revision: Int) -> String {
        "coordinator:\(coordinatorSessionID.uuidString):plan-approval:r\(revision)"
    }

    private func planRevisionCheckpointInstanceID(coordinatorSessionID: UUID, revision: Int) -> String {
        "coordinator:\(coordinatorSessionID.uuidString):plan-revision:r\(revision)"
    }

    private func selectFreshCoordinatorRuntimeIfAvailable(
        previousCoordinatorIDs: Set<UUID>,
        workspaceID: UUID?
    ) {
        let input = inputProvider(sortMode, nil)
        guard let workspaceID = workspaceID ?? input.workspaceID else { return }
        let newCoordinatorIDs = coordinatorSessionIDs(in: input).subtracting(previousCoordinatorIDs)
        guard let selectedCoordinatorID = newestCoordinatorID(in: newCoordinatorIDs, input: input) else { return }
        coordinatorSelectionByWorkspaceID[workspaceID] = .session(selectedCoordinatorID)
    }

    private func coordinatorSessionIDs(in input: CoordinatorModeSnapshotProjector.Input) -> Set<UUID> {
        var ids = input.demoCoordinatorSessionIDs
        ids.formUnion(input.persistedSessions.compactMap { $0.isCoordinatorRuntime ? $0.id : nil })
        ids.formUnion(input.liveSessions.compactMap { $0.isCoordinatorRuntime ? $0.sessionID : nil })
        ids.formUnion(input.coordinatorDetectionSessions.compactMap { $0.isCoordinatorRuntime ? $0.id : nil })
        return ids
    }

    private func newestCoordinatorID(
        in coordinatorIDs: Set<UUID>,
        input: CoordinatorModeSnapshotProjector.Input
    ) -> UUID? {
        coordinatorIDs.max { lhs, rhs in
            let lhsDate = coordinatorUpdatedAt(lhs, input: input)
            let rhsDate = coordinatorUpdatedAt(rhs, input: input)
            if lhsDate == rhsDate {
                return lhs.uuidString < rhs.uuidString
            }
            return lhsDate < rhsDate
        }
    }

    private func coordinatorUpdatedAt(
        _ sessionID: UUID,
        input: CoordinatorModeSnapshotProjector.Input
    ) -> Date {
        [
            input.liveSessions.first { $0.sessionID == sessionID }?.updatedAt,
            input.persistedSessions.first { $0.id == sessionID }?.updatedAt,
            input.coordinatorDetectionSessions.first { $0.id == sessionID }?.updatedAt,
            input.mcpSnapshotsBySessionID[sessionID]?.updatedAt
        ]
        .compactMap(\.self)
        .max() ?? .distantPast
    }

    private func pendingFreshCoordinatorSnapshot(from projected: CoordinatorModeSnapshot) -> CoordinatorModeSnapshot {
        let options = projected.coordinatorRail.availableCoordinators.map { option in
            CoordinatorModeCoordinatorOption(
                sessionID: option.sessionID,
                tabID: option.tabID,
                workspaceID: option.workspaceID,
                title: option.title,
                selectionSource: option.selectionSource,
                isSelected: false,
                isLiveInCurrentWindow: option.isLiveInCurrentWindow,
                isPinned: option.isPinned,
                isPersistedOnly: option.isPersistedOnly,
                childCounts: option.childCounts,
                missionTemplate: option.missionTemplate,
                missionPlan: option.missionPlan,
                missionSummary: option.missionSummary,
                runState: option.runState,
                updatedAt: option.updatedAt,
                lastActivityAt: option.lastActivityAt
            )
        }
        let rail = CoordinatorModeCoordinatorRail(
            state: .chooseCoordinator,
            coordinatorSessionID: nil,
            coordinatorTabID: nil,
            selectionSource: nil,
            title: nil,
            availableCoordinators: options,
            isLiveInCurrentWindow: false,
            isPersistedOnly: false,
            isPinned: false,
            childCounts: .empty,
            missionTemplate: nil,
            missionPlan: nil,
            missionSummary: nil,
            pendingInteraction: nil,
            openAgentChatRoute: nil,
            statusReport: nil,
            isComposerEnabled: false,
            isComposerSendEnabled: false
        )
        return CoordinatorModeSnapshot(
            workspaceID: projected.workspaceID,
            sortMode: projected.sortMode,
            boardScope: projected.boardScope,
            counts: projected.counts,
            groups: projected.groups,
            coordinatorRail: rail,
            pendingInteractions: projected.pendingInteractions,
            decisionQueue: projected.decisionQueue,
            mcpAwareness: projected.mcpAwareness,
            isEmpty: projected.isEmpty
        )
    }

    func activePendingChildInteractionRow(coordinatorSessionID explicitCoordinatorSessionID: UUID? = nil) -> CoordinatorModeRow? {
        guard let coordinatorSessionID = explicitCoordinatorSessionID ?? snapshot.coordinatorRail.coordinatorSessionID else { return nil }
        return coordinatorModeRowsForRouting(in: snapshot)
            .filter { row in
                row.parentCoordinator?.sessionID == coordinatorSessionID
                    && row.pendingInteraction?.isAvailable == true
                    && row.runState == .waitingForQuestion
                    && !row.isPersistedOnly
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.updatedAt < rhs.updatedAt
            }
            .first
    }

    func missionBoundChildInteractionRespondRedirectMessage(
        sessionID: UUID,
        interactionID: UUID
    ) -> String? {
        let rows = coordinatorModeRowsForRouting(in: snapshot)
        if let row = rows.first(where: { row in
            row.sessionID == sessionID
                && row.pendingInteraction?.id == interactionID
                && row.parentCoordinator?.sessionID != nil
                && !row.isPersistedOnly
        }),
            let coordinatorSessionID = row.parentCoordinator?.sessionID,
            let plan = snapshot.coordinatorRail.availableCoordinators
            .first(where: { $0.sessionID == coordinatorSessionID })?
            .missionPlan,
            !plan.status.isTerminal
        {
            return Self.missionBoundChildInteractionRespondRedirectMessage(coordinatorSessionID: coordinatorSessionID)
        }

        let boundCoordinator = snapshot.coordinatorRail.availableCoordinators.first { option in
            guard let plan = option.missionPlan,
                  !plan.status.isTerminal
            else {
                return false
            }
            return plan.nodes.contains { node in
                node.boundSessionID == sessionID || node.boundInteractionID == interactionID
            }
        }

        guard let coordinatorSessionID = boundCoordinator?.sessionID else {
            return nil
        }

        return Self.missionBoundChildInteractionRespondRedirectMessage(coordinatorSessionID: coordinatorSessionID)
    }

    static func missionBoundChildInteractionRespondRedirectMessage(coordinatorSessionID: UUID) -> String {
        """
        This child question belongs to Coordinator Mission \(coordinatorSessionID.uuidString). Mission-bound child answers must use coordinator_chat op=submit so the Mission ledger records the actor decision and evidence. Retry with coordinator_chat op=submit, coordinator_session_id "\(coordinatorSessionID.uuidString)", and the same answer text.
        """
    }

    func coordinatorModeRowsForRouting(in snapshot: CoordinatorModeSnapshot) -> [CoordinatorModeRow] {
        snapshot.groups.flatMap(\.rows).map { row in
            guard row.pendingInteraction == nil,
                  row.runState == .waitingForQuestion,
                  !row.isPersistedOnly,
                  let parentCoordinator = row.parentCoordinator,
                  let plan = snapshot.coordinatorRail.availableCoordinators
                  .first(where: { $0.sessionID == parentCoordinator.sessionID })?
                  .missionPlan,
                  plan.resolvedAutonomy(for: .childAsk) == .auto,
                  let pendingInteraction = rawPendingInteractionSummary(for: row)
            else { return row }

            // Director-routed child questions are hidden from the Decisions UI, but
            // service/routing code still needs the raw interaction id for ledgering.
            return row.withPendingInteraction(pendingInteraction)
        }
    }

    private func rawPendingInteractionSummary(for row: CoordinatorModeRow) -> CoordinatorModePendingInteractionSummary? {
        guard let raw = lastProjectionInput?.mcpSnapshotsBySessionID[row.sessionID],
              let interaction = raw.interaction,
              interaction.kind == .question
        else { return nil }
        return CoordinatorModePendingInteractionSummary(
            id: interaction.id,
            sessionID: raw.sessionID,
            kind: interaction.kind,
            responseType: interaction.responseType,
            title: interaction.title,
            prompt: interaction.prompt,
            context: interaction.context,
            options: interaction.options,
            fields: interaction.fields,
            details: interaction.details,
            openAgentChatRoute: row.openAgentChatRoute
        )
    }

    @discardableResult
    func submitPendingChildInteractionResponse(_ text: String, to row: CoordinatorModeRow) async -> DirectiveSubmissionResult {
        await submitPendingChildInteractionResponse(.text(text), to: row)
    }

    @discardableResult
    func submitPendingChildInteractionResponse(
        _ submission: ChildInteractionResponseSubmission,
        to row: CoordinatorModeRow,
        actor: CoordinatorMissionDecisionActor = .user
    ) async -> DirectiveSubmissionResult {
        let displayText = submission.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty || submission.skip || submission.hasStructuredAnswers else {
            return .rejected(message: "")
        }
        guard row.pendingInteraction != nil else {
            let message = "This child session is no longer waiting for input."
            composerNotice = message
            return .rejected(message: message)
        }
        let coordinatorSessionID = row.parentCoordinator?.sessionID ?? snapshot.coordinatorRail.coordinatorSessionID
        let pendingPlan = coordinatorSessionID.flatMap { coordinatorID in
            snapshot.coordinatorRail.availableCoordinators
                .first(where: { $0.sessionID == coordinatorID })?
                .missionPlan
        }
        if row.pendingInteraction?.isAvailable == false
            || pendingPlan?.holdsChildInteractionsForRevisionProposal == true
        {
            let message = CoordinatorMissionRevisionProposalPause.heldReason
            composerNotice = message
            return .rejected(message: message)
        }
        let timestamp = Date()
        let pendingDecision = childInteractionDecision(
            row: row,
            displayText: displayText,
            actor: actor,
            timestamp: timestamp
        )
        guard let pendingDecision else {
            let message = "This child answer could not be recorded because it is no longer linked to a Coordinator mission."
            composerNotice = message
            return .rejected(message: message)
        }
        let pendingEvidence = childInteractionEvidence(
            row: row,
            displayText: displayText,
            decisionID: pendingDecision.record.id,
            actor: actor,
            timestamp: timestamp
        )
        let result = await childInteractionResponseSubmitter(submission, row)
        switch result {
        case .accepted:
            composerNotice = nil
            if !appendMissionChildInteractionDecision(pendingDecision, evidence: pendingEvidence, actor: actor) {
                let message = "The child answer was sent, but the Mission ledger could not record it."
                composerNotice = message
                return .rejected(message: message)
            }
            childInteractionResponseRecorder(displayText, row)
            appendChildInteractionResponseTranscriptEntry(row: row, text: displayText)
        case let .rejected(message):
            composerNotice = message.isEmpty ? nil : message
        }
        return result
    }

    @discardableResult
    func submitCoordinatorPendingInteractionResponse(
        _ submission: ChildInteractionResponseSubmission,
        pending: CoordinatorModePendingInteractionSummary
    ) async -> DirectiveSubmissionResult {
        let displayText = submission.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty || submission.skip || submission.hasStructuredAnswers else {
            return .rejected(message: "")
        }
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else {
            return .rejected(message: "No Coordinator mission is selected.")
        }
        let result = await coordinatorInteractionResponseSubmitter(submission, coordinatorSessionID, pending.id)
        switch result {
        case .accepted:
            // Generic Coordinator-owned pending interactions are intentionally excluded from
            // v2.3 user-decision accounting; explicit app checkpoints record their own labels.
            composerNotice = nil
        case let .rejected(message):
            composerNotice = message.isEmpty ? nil : message
        }
        refresh()
        return result
    }

    #if DEBUG
        func testPublish(_ snapshot: CoordinatorModeSnapshot) {
            self.snapshot = snapshot
            missionEventJournal.record(snapshot: snapshot)
        }
    #endif

    func missionEvents(
        coordinatorSessionID: UUID,
        sinceSeq: Int,
        limit: Int
    ) -> CoordinatorMissionEventJournal.Batch {
        missionEventJournal.events(
            for: coordinatorSessionID,
            sinceSeq: sinceSeq,
            limit: limit
        )
    }

    private func publishIfChanged(_ nextSnapshot: CoordinatorModeSnapshot) {
        let nextCoordinatorSessionID = nextSnapshot.coordinatorRail.coordinatorSessionID
        if displayedTranscriptCoordinatorSessionID != nextCoordinatorSessionID {
            railTranscriptEntries.removeAll()
            composerNotice = nil
            displayedTranscriptCoordinatorSessionID = nextCoordinatorSessionID
            currentRailActivityText = nil
            lastDurableRailStatusEntryKey = nil
            displayedDelegateActionTargetIDs.removeAll()
        }
        updateRailStatusPresentation(from: nextSnapshot.coordinatorRail)
        updateRailActionPresentation(from: nextSnapshot)
        syncPostApprovalContinuationStatus(from: nextSnapshot.coordinatorRail.missionPlan)
        syncDialSelections(from: nextSnapshot.coordinatorRail)
        syncRailConversationTranscript(for: nextCoordinatorSessionID)
        mergeMissionLedgerEntries(from: nextSnapshot.coordinatorRail.missionPlan)
        let nextPendingFollowThroughEvent = usesAutoMode
            ? nil
            : pendingFollowThroughEventProvider(nextCoordinatorSessionID)
        if pendingFollowThroughEvent != nextPendingFollowThroughEvent {
            pendingFollowThroughEvent = nextPendingFollowThroughEvent
        }
        let nextFingerprint = nextSnapshot.fingerprint
        guard lastPublishedFingerprint != nextFingerprint else { return }
        lastPublishedFingerprint = nextFingerprint
        missionEventJournal.record(snapshot: nextSnapshot)
        snapshot = nextSnapshot
    }

    private func appendUserTranscriptEntryIfMissing(_ text: String) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }
        let alreadyVisible = railTranscriptEntries.contains { entry in
            entry.role == .user
                && entry.action == nil
                && entry.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText
        }
        guard !alreadyVisible else { return }
        railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
            id: UUID(),
            role: .user,
            text: normalizedText,
            createdAt: Date(),
            action: nil
        ))
    }

    private func appendChildInteractionResponseTranscriptEntry(row: CoordinatorModeRow, text: String) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }
        let displayText = "You answered \(row.title):\n\n\(normalizedText)"
        let alreadyVisible = railTranscriptEntries.contains { entry in
            entry.role == .event
                && entry.action == nil
                && entry.text.trimmingCharacters(in: .whitespacesAndNewlines) == displayText
        }
        guard !alreadyVisible else { return }
        railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
            id: UUID(),
            role: .event,
            text: displayText,
            createdAt: Date(),
            action: nil
        ))
    }

    private func appendCoordinatorEventTranscriptEntry(_ text: String) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }
        guard !railTranscriptEntries.contains(where: { entry in
            entry.role == .event
                && entry.action == nil
                && entry.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText
        }) else { return }
        railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
            id: UUID(),
            role: .event,
            text: normalizedText,
            createdAt: Date(),
            action: nil
        ))
    }

    private func coordinatorMissionStopTargetSessionIDs(
        coordinatorSessionID: UUID,
        missionPlan: CoordinatorMissionPlan?
    ) -> [UUID] {
        var ids: [UUID] = []
        func append(_ id: UUID?) {
            guard let id, !ids.contains(id) else { return }
            ids.append(id)
        }

        append(coordinatorSessionID)

        let rows = snapshot.groups.flatMap(\.rows)
        let directChildIDs = Set(rows.compactMap { row in
            row.parentSessionID == coordinatorSessionID ? row.sessionID : nil
        })
        var descendantIDs = directChildIDs
        var didAppend = true
        while didAppend {
            didAppend = false
            for row in rows where row.parentSessionID.map(descendantIDs.contains) == true {
                didAppend = descendantIDs.insert(row.sessionID).inserted || didAppend
            }
        }

        for row in rows {
            let belongsToCoordinator = row.parentCoordinator?.sessionID == coordinatorSessionID
                || descendantIDs.contains(row.sessionID)
            guard belongsToCoordinator else { continue }
            append(row.sessionID)
            for childSessionID in row.childSessionIDs {
                append(childSessionID)
            }
        }

        if let missionPlan {
            for workstream in missionPlan.workstreams {
                for sessionID in workstream.linkedSessionIDs {
                    append(sessionID)
                }
            }
            for node in missionPlan.nodes {
                append(node.boundSessionID)
            }
        }

        return ids
    }

    private func syncRailConversationTranscript(for coordinatorSessionID: UUID?) {
        let transcriptEntries = transcriptProvider(coordinatorSessionID).map(Self.visibleTranscriptEntry)
        guard !transcriptEntries.isEmpty else { return }

        var mergedEntries = railTranscriptEntries.filter { entry in
            entry.role == .event || entry.action != nil || entry.ledger != nil
        }
        var seenIDs = Set(mergedEntries.map(\.id))
        var seenDisplayKeys = Set(mergedEntries.map(Self.displayKey(for:)))
        for entry in transcriptEntries where !seenIDs.contains(entry.id) {
            let displayKey = Self.displayKey(for: entry)
            guard !seenDisplayKeys.contains(displayKey) else { continue }
            mergedEntries.append(entry)
            seenIDs.insert(entry.id)
            seenDisplayKeys.insert(displayKey)
        }
        mergedEntries.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
        railTranscriptEntries = mergedEntries
    }

    private func mergeMissionLedgerEntries(from plan: CoordinatorMissionPlan?) {
        var mergedEntries = railTranscriptEntries.filter { $0.ledger == nil }
        guard let plan else {
            railTranscriptEntries = mergedEntries
            return
        }

        var seenLedgerIDs = Set<UUID>()
        let ledgerEntries = missionLedgerTranscriptEntries(from: plan).filter { entry in
            seenLedgerIDs.insert(entry.id).inserted
        }
        mergedEntries.append(contentsOf: ledgerEntries)
        mergedEntries.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
        railTranscriptEntries = mergedEntries
    }

    private func missionLedgerTranscriptEntries(from plan: CoordinatorMissionPlan) -> [CoordinatorModeRailTranscriptEntry] {
        var entries: [CoordinatorModeRailTranscriptEntry] = []
        let wrapUpID = deterministicMissionLedgerEntryID(planID: plan.id, kind: "wrapup")

        entries.append(contentsOf: plan.decisions.map { decision in
            CoordinatorModeRailTranscriptEntry(
                id: decision.id,
                role: .event,
                text: decision.label,
                createdAt: decision.timestamp,
                action: nil,
                ledger: .decision(decision)
            )
        })
        entries.append(contentsOf: plan.evidence.map { evidence in
            CoordinatorModeRailTranscriptEntry(
                id: evidence.id,
                role: .event,
                text: evidence.summary,
                createdAt: evidence.timestamp,
                action: nil,
                ledger: .evidence(evidence)
            )
        })
        entries.append(contentsOf: plan.routingDecisions.map { decision in
            CoordinatorModeRailTranscriptEntry(
                id: decision.id,
                role: .event,
                text: decision.reason,
                createdAt: decision.timestamp,
                action: nil,
                ledger: .routing(decision)
            )
        })
        entries.append(contentsOf: missionPlanEventTranscriptEntries(from: plan))

        if plan.status == .completed {
            entries.append(CoordinatorModeRailTranscriptEntry(
                id: wrapUpID,
                role: .event,
                text: "Mission wrap-up",
                createdAt: plan.updatedAt,
                action: nil,
                ledger: .wrapUp(
                    userCount: plan.decisions.count(where: { $0.actor == .user }),
                    directorCount: plan.decisions.count(where: { $0.actor == .director })
                )
            ))
        }

        return entries
    }

    private func missionPlanEventTranscriptEntries(from plan: CoordinatorMissionPlan) -> [CoordinatorModeRailTranscriptEntry] {
        let events = plan.events.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.timestamp < rhs.timestamp
        }
        let revisionEvents = events.filter(\.kind.isRevisionMarker)
        let firstRenderedRevision = max(1, plan.revision - revisionEvents.count + 1)
        var renderedRevisionIndex = 0
        var foldedProgressEventCount = 0
        var pendingBookkeepingRun: (
            event: CoordinatorMissionPlanEvent,
            previousRevision: Int,
            revision: Int,
            foldedEventCount: Int
        )?
        var entries: [CoordinatorModeRailTranscriptEntry] = []

        func appendUpdate(
            event: CoordinatorMissionPlanEvent,
            previousRevision: Int?,
            revision: Int,
            summary: String?,
            foldedEventCount: Int
        ) {
            let update = CoordinatorModePlanUpdateSummary(
                id: event.id,
                eventKind: event.kind,
                previousRevision: previousRevision,
                revision: revision,
                summary: summary,
                foldedEventCount: foldedEventCount
            )
            entries.append(CoordinatorModeRailTranscriptEntry(
                id: event.id,
                role: .event,
                text: [update.title, update.revisionText].compactMap(\.self).joined(separator: " · "),
                createdAt: event.timestamp,
                action: nil,
                ledger: .planUpdate(update)
            ))
        }

        func flushBookkeepingRun() {
            guard let run = pendingBookkeepingRun else { return }
            appendUpdate(
                event: run.event,
                previousRevision: run.previousRevision,
                revision: run.revision,
                summary: nil,
                foldedEventCount: run.foldedEventCount
            )
            pendingBookkeepingRun = nil
        }

        for event in events {
            if event.kind.isFoldedTranscriptProgress {
                foldedProgressEventCount += 1
                continue
            }

            if event.kind.isRevisionMarker {
                let revision = firstRenderedRevision + renderedRevisionIndex
                let previousRevision = event.kind == .revised ? max(1, revision - 1) : nil
                renderedRevisionIndex += 1
                let summary = Self.usefulPlanEventSummary(event.summary)

                if event.kind == .revised, event.isBookkeepingOnly == true, summary == nil {
                    if let run = pendingBookkeepingRun {
                        pendingBookkeepingRun = (
                            event: run.event,
                            previousRevision: run.previousRevision,
                            revision: revision,
                            foldedEventCount: run.foldedEventCount + foldedProgressEventCount
                        )
                    } else {
                        pendingBookkeepingRun = (
                            event: event,
                            previousRevision: previousRevision ?? revision,
                            revision: revision,
                            foldedEventCount: foldedProgressEventCount
                        )
                    }
                    foldedProgressEventCount = 0
                    continue
                }

                flushBookkeepingRun()
                appendUpdate(
                    event: event,
                    previousRevision: previousRevision,
                    revision: revision,
                    summary: summary,
                    foldedEventCount: foldedProgressEventCount
                )
                foldedProgressEventCount = 0
                continue
            }

            flushBookkeepingRun()
            foldedProgressEventCount = 0
            entries.append(CoordinatorModeRailTranscriptEntry(
                id: event.id,
                role: .event,
                text: event.summary ?? event.kind.rawValue,
                createdAt: event.timestamp,
                action: nil,
                ledger: .planEvent(event)
            ))
        }

        flushBookkeepingRun()
        return entries
    }

    private static func usefulPlanEventSummary(_ summary: String?) -> String? {
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        if trimmed.caseInsensitiveCompare("Mission plan updated") == .orderedSame {
            return nil
        }
        return trimmed
    }

    private func deterministicMissionLedgerEntryID(planID: UUID, kind: String) -> UUID {
        CoordinatorMissionStableIdentity.uuid(
            namespace: "coordinator-mode-ledger-entry",
            parts: [planID.uuidString, kind]
        )
    }

    private static func displayKey(for entry: CoordinatorModeRailTranscriptEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionKey = if let targetID = entry.action?.targetSessionID {
            "action:\(targetID.uuidString)"
        } else {
            "action:nil"
        }
        return "\(entry.role.rawValue)|\(actionKey)|\(text)"
    }

    private static func visibleTranscriptEntry(_ entry: CoordinatorModeRailTranscriptEntry) -> CoordinatorModeRailTranscriptEntry {
        guard entry.role == .user else { return entry }
        let visibleText = CoordinatorMissionPolicyProviderText.visibleTranscriptText(from: entry.text)
        guard visibleText != entry.text else { return entry }
        return CoordinatorModeRailTranscriptEntry(
            id: entry.id,
            role: entry.role,
            text: visibleText,
            createdAt: entry.createdAt,
            action: entry.action,
            ledger: entry.ledger
        )
    }

    private func updateRailActionPresentation(from snapshot: CoordinatorModeSnapshot) {
        guard let coordinatorSessionID = snapshot.coordinatorRail.coordinatorSessionID else {
            displayedDelegateActionTargetIDs.removeAll()
            return
        }

        let rows = directDelegatedRows(in: snapshot, coordinatorSessionID: coordinatorSessionID)
            .filter { !displayedDelegateActionTargetIDs.contains($0.sessionID) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.startedAt ?? lhs.updatedAt
                let rhsDate = rhs.startedAt ?? rhs.updatedAt
                if lhsDate == rhsDate {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhsDate < rhsDate
            }

        for row in rows {
            let actionCreatedAt = row.startedAt ?? row.updatedAt
            displayedDelegateActionTargetIDs.insert(row.sessionID)
            railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
                id: row.sessionID,
                role: .event,
                text: "Delegated to \(row.title)",
                createdAt: actionCreatedAt,
                action: CoordinatorModeCoordinatorAction(
                    ownerCoordinatorSessionID: coordinatorSessionID,
                    ownerTitle: snapshot.coordinatorRail.title ?? "Coordinator",
                    targetSessionID: row.sessionID,
                    targetTitle: row.title,
                    verb: .delegate,
                    phase: .resolved,
                    statusGroup: row.statusGroup,
                    workflow: row.workflow,
                    workstream: row.workstream
                )
            ))
        }
    }

    private func directDelegatedRows(
        in snapshot: CoordinatorModeSnapshot,
        coordinatorSessionID: UUID
    ) -> [CoordinatorModeRow] {
        snapshot.groups
            .flatMap(\.rows)
            .filter { row in
                row.parentSessionID == coordinatorSessionID && !row.isCoordinator
            }
    }

    private func updateRailStatusPresentation(from rail: CoordinatorModeCoordinatorRail) {
        guard let report = rail.statusReport,
              let text = railStatusConversationText(from: report)
        else {
            currentRailActivityText = nil
            return
        }

        switch railStatusVisibility(for: report) {
        case .ephemeral:
            currentRailActivityText = railEphemeralActivityText(from: report) ?? text
            return
        case .durable:
            currentRailActivityText = nil
        }

        let key = [
            String(describing: report.status),
            report.statusText ?? "",
            report.assistantPreview ?? "",
            report.terminalOutput ?? "",
            report.failureReason.map { String(describing: $0) } ?? ""
        ].joined(separator: "\u{1F}")
        guard key != lastDurableRailStatusEntryKey else { return }

        lastDurableRailStatusEntryKey = key
        let role: CoordinatorModeRailTranscriptEntry.Role = report.status.isTerminal ? .coordinator : .event

        railTranscriptEntries.append(CoordinatorModeRailTranscriptEntry(
            id: UUID(),
            role: role,
            text: text,
            createdAt: Date(),
            action: nil
        ))
    }

    private enum RailStatusVisibility {
        case durable
        case ephemeral
    }

    private func railStatusVisibility(for report: CoordinatorModeSessionStatusReport) -> RailStatusVisibility {
        if report.status.isTerminal || report.status == .waitingForInput || report.failureReason != nil {
            return .durable
        }
        if report.status == .running {
            return .ephemeral
        }
        return .durable
    }

    private func railEphemeralActivityText(from report: CoordinatorModeSessionStatusReport) -> String? {
        let statusText = report.statusText
        return statusText.flatMap { text -> String? in
            switch normalizedTransportStatusText(text) {
            case "queued to start":
                return "Queued to start"
            case "connecting":
                return "Connecting"
            case "sending message":
                return "Sending message"
            case "waiting for response":
                return "Waiting for response"
            case "codex is active", "thinking":
                return "Coordinator is thinking"
            case "compacting context":
                return "Compacting context"
            default:
                return text
            }
        } ?? "Coordinator is working"
    }

    private func railStatusConversationText(from report: CoordinatorModeSessionStatusReport) -> String? {
        if report.status == .completed, let terminalOutput = report.terminalOutput {
            return terminalOutput
        }
        if report.failureReason == .cancelled {
            return cancelledRailStatusText(from: report)
        }

        var parts: [String] = []
        if let statusText = report.statusText {
            parts.append(statusText)
        }
        if let failureReason = report.failureReason {
            parts.append("Failure: \(failureReason.displayLabel)")
        }
        if let assistantPreview = report.assistantPreview {
            parts.append(assistantPreview)
        }
        if let terminalOutput = report.terminalOutput {
            parts.append(terminalOutput)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func cancelledRailStatusText(from report: CoordinatorModeSessionStatusReport) -> String {
        let sourceText = [report.statusText, report.assistantPreview, report.terminalOutput]
            .compactMap(\.self)
            .joined(separator: "\n")
            .lowercased()
        return sourceText.contains("stop") ? "Stopped" : "Cancelled"
    }

    private func normalizedTransportStatusText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
            .lowercased()
    }
}

extension AgentModeViewModel {
    @MainActor
    @discardableResult
    func refreshCoordinatorModeIfVisible() -> Bool {
        visibleCoordinatorModeViewModel?.refreshIfVisible() ?? false
    }

    @MainActor
    @discardableResult
    func refreshCoordinatorModeForChildLifecycleIfVisible() -> Bool {
        let refreshed = visibleCoordinatorModeViewModel?.refreshIfVisible() ?? false
        Task { @MainActor [weak self] in
            await self?.evaluateCoordinatorFollowThrough(trigger: .lifecycle)
        }
        return refreshed
    }

    @MainActor
    func makeCoordinatorModeViewModel() -> CoordinatorModeViewModel {
        CoordinatorModeViewModel { [weak self] sortMode, selectedCoordinatorID in
            guard let self else {
                return CoordinatorModeSnapshotProjector.Input(
                    workspaceID: nil,
                    windowID: nil,
                    selectedCoordinatorID: selectedCoordinatorID,
                    sortMode: sortMode
                )
            }
            return coordinatorModeSnapshotInput(
                sortMode: sortMode,
                selectedCoordinatorID: selectedCoordinatorID
            )
        } transcriptProvider: { [weak self] coordinatorSessionID in
            self?.coordinatorModeRailTranscriptEntries(for: coordinatorSessionID) ?? []
        } dashboardVisibilityHandler: { [weak self] visible in
            self?.setCoordinatorModeDashboardUpdatesVisible(visible)
        } directiveSubmitter: { [weak self] submission in
            guard let self else {
                return .rejected(message: "Coordinator composer is unavailable.")
            }
            switch await submitCoordinatorDirectiveToAgentMode(submission) {
            case .submitted:
                return .accepted
            case let .blocked(message):
                return .rejected(message: message)
            }
        } childDirectiveSubmitter: { [weak self] text, row in
            guard let self else {
                return .rejected(message: "Session replies are unavailable.")
            }
            switch await submitChildDirectiveToAgentMode(text, row: row) {
            case .submitted:
                return .accepted
            case let .blocked(message):
                return .rejected(message: message)
            }
        } childInteractionResponseSubmitter: { [weak self] submission, row in
            guard let self else {
                return .rejected(message: "Session replies are unavailable.")
            }
            switch await submitChildInteractionResponseToAgentMode(submission, row: row) {
            case .submitted:
                return .accepted
            case let .blocked(message):
                return .rejected(message: message)
            }
        } coordinatorInteractionResponseSubmitter: { [weak self] submission, coordinatorSessionID, interactionID in
            guard let self else {
                return .rejected(message: "Coordinator replies are unavailable.")
            }
            switch await submitCoordinatorInteractionResponseToAgentMode(
                submission,
                coordinatorSessionID: coordinatorSessionID,
                interactionID: interactionID
            ) {
            case .submitted:
                return .accepted
            case let .blocked(message):
                return .rejected(message: message)
            }
        } childInteractionResponseRecorder: { [weak self] text, row in
            self?.rememberCoordinatorChildInteractionResponse(text, row: row)
        } continuationGateHandler: { [weak self] gate, snapshotBeforeGateCleared in
            if let ownerID = gate.ownerCoordinatorSessionID {
                await self?.evaluateCoordinatorFollowThrough(
                    coordinatorSessionID: ownerID,
                    snapshot: snapshotBeforeGateCleared,
                    trigger: .gateCleared(gate)
                )
            } else {
                await self?.evaluateCoordinatorFollowThrough(
                    trigger: .gateCleared(gate),
                    snapshot: snapshotBeforeGateCleared
                )
            }
        } coordinatorActivationHandler: { [weak self] sessionID in
            await self?.activateCoordinatorRuntimeSession(sessionID)
        } coordinatorPinHandler: { [weak self] option, isPinned in
            self?.setCoordinatorRuntimePinned(isPinned, option: option)
        } coordinatorArchiveHandler: { [weak self] option in
            guard let self else {
                return .rejected("Coordinator Mission archive is unavailable.")
            }
            return await archiveCoordinatorRuntimeMission(option)
        } missionPlanUpdater: { [weak self] coordinatorSessionID, update in
            guard let self else {
                throw MCPError.invalidParams("Coordinator Mission Plan state is unavailable.")
            }
            try updateCoordinatorMissionPlan(
                coordinatorSessionID: coordinatorSessionID,
                update: update
            )
        } revisionProposalAppender: { [weak self] coordinatorSessionID, request in
            guard let self else {
                throw MCPError.invalidParams("Coordinator Mission revision proposal state is unavailable.")
            }
            return try await appendCoordinatorMissionRevisionProposal(
                coordinatorSessionID: coordinatorSessionID,
                request: request
            )
        } revisionProposalResolver: { [weak self] request in
            guard let self else {
                throw MCPError.invalidParams("Coordinator Mission revision proposal resolution state is unavailable.")
            }
            return try await resolveCoordinatorMissionRevisionProposal(request)
        } revisionProposalAuthorityProvider: { [weak self] coordinatorSessionID in
            let plan = self?.sessions.values.first(where: {
                $0.activeAgentSessionID == coordinatorSessionID && $0.isCoordinatorRuntime
            })?.coordinatorFollowThroughState?.missionPlan
            return CoordinatorModeViewModel.RevisionProposalAuthority(plan: plan)
        } trustedMissionStopRecorder: { [weak self] coordinatorSessionID, targetSessionIDs in
            guard let self else {
                throw MCPError.invalidParams("Coordinator Mission stop persistence is unavailable.")
            }
            try await recordTrustedCoordinatorMissionStop(
                coordinatorSessionID: coordinatorSessionID,
                targetSessionIDs: targetSessionIDs
            )
        } trustedContractChangeApplier: { [weak self] coordinatorSessionID, update in
            guard let self else {
                throw MCPError.invalidParams("Coordinator Mission contract-change persistence is unavailable.")
            }
            try await applyTrustedCoordinatorMissionContractChange(
                coordinatorSessionID: coordinatorSessionID,
                update: update
            )
        } trustedRevisedPlanChangeRequester: { [weak self] coordinatorSessionID, planID, planRevision, checkpoint, resolutionID in
            guard let self else {
                throw MCPError.invalidParams("Coordinator Mission revision persistence is unavailable.")
            }
            try await requestTrustedRevisedPlanChange(
                coordinatorSessionID: coordinatorSessionID,
                planID: planID,
                planRevision: planRevision,
                expectedCheckpointInstanceID: checkpoint,
                resolutionID: resolutionID
            )
        } missionStopper: { [weak self] request in
            guard let self else {
                return CoordinatorMissionStopResult(
                    requestedSessionIDs: request.sessionIDs,
                    cancelledSessionIDs: [],
                    skippedSessionIDs: request.sessionIDs
                )
            }
            return await stopCoordinatorMissionRuntime(request)
        } pendingFollowThroughEventProvider: { [weak self] coordinatorSessionID in
            self?.pendingCoordinatorFollowThroughEvent(coordinatorSessionID: coordinatorSessionID)
        } followThroughEventSubmitter: { [weak self] event in
            guard let self else {
                return .rejected(message: "Coordinator follow-through is unavailable.")
            }
            return await submitPendingCoordinatorFollowThroughEvent(event)
        } followThroughEventResolver: { [weak self] event in
            self?.resolvePendingCoordinatorFollowThroughEvent(event)
        } followThroughEvaluationHandler: { [weak self] coordinatorSessionID in
            guard let self else { return }
            coordinatorModeViewModel.refresh()
            await evaluateCoordinatorFollowThrough(
                coordinatorSessionID: coordinatorSessionID,
                snapshot: coordinatorModeViewModel.snapshot,
                trigger: .lifecycle
            )
        } postApprovalContinuationPersistenceBarrier: { [weak self] token in
            guard let self else {
                throw MCPError.invalidParams("Coordinator Mission persistence is unavailable.")
            }
            try await flushCoordinatorPostApprovalContinuationPersistence(token)
        }
    }

    @MainActor
    func coordinatorModeRailTranscriptEntries(for coordinatorSessionID: UUID?) -> [CoordinatorModeRailTranscriptEntry] {
        guard let coordinatorSessionID,
              let session = sessions.values.first(where: { session in
                  session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
              })
        else { return [] }

        var entries: [CoordinatorModeRailTranscriptEntry] = session.items.compactMap { item in
            guard let role = coordinatorModeRailRole(for: item.kind) else { return nil }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AgentDisplayableText.hasDisplayableBody(text) else { return nil }
            if role == .user, isCoordinatorFollowThroughResumeDirective(text) {
                return nil
            }
            return CoordinatorModeRailTranscriptEntry(
                id: item.id,
                role: role,
                text: text,
                createdAt: item.timestamp,
                action: nil
            )
        }
        let childResponseEntries = session.coordinatorFollowThroughState?.childInteractionResponses.map { record in
            CoordinatorModeRailTranscriptEntry(
                id: record.id,
                role: .event,
                text: record.transcriptText,
                createdAt: record.answeredAt,
                action: nil
            )
        } ?? []
        entries.append(contentsOf: childResponseEntries)
        entries.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
        return entries
    }

    private func coordinatorModeRailRole(for itemKind: AgentChatItemKind) -> CoordinatorModeRailTranscriptEntry.Role? {
        switch itemKind {
        case .user:
            .user
        case .assistant, .assistantInline, .error:
            .coordinator
        case .toolCall, .toolResult, .system, .thinking:
            nil
        }
    }

    private static func canAcceptCoordinatorDirective(runState: AgentSessionRunState) -> Bool {
        switch runState {
        case .running: false
        case .idle, .waitingForUser, .waitingForQuestion, .waitingForApproval, .completed, .cancelled, .failed: true
        }
    }

    @MainActor
    func submitCoordinatorDirectiveToAgentMode(
        _ text: String,
        coordinatorSessionID: UUID?,
        forceNewRuntime: Bool = false,
        beforeSubmit: (@MainActor () throws -> Void)? = nil,
        targetedBeforeSubmit: (@MainActor (_ tabID: UUID, _ session: TabSession) throws -> Void)? = nil
    ) async -> UserTurnSubmissionResult {
        await submitCoordinatorDirectiveToAgentMode(
            CoordinatorDirectiveSubmission(
                visibleText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                providerText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                missionTemplate: nil,
                missionPolicySnapshot: nil,
                coordinatorSessionID: coordinatorSessionID,
                coordinatorModelID: nil,
                forceNewRuntime: forceNewRuntime
            ),
            beforeSubmit: beforeSubmit,
            targetedBeforeSubmit: targetedBeforeSubmit
        )
    }

    @MainActor
    func submitCoordinatorDirectiveToAgentMode(
        _ submission: CoordinatorDirectiveSubmission,
        beforeSubmit: (@MainActor () throws -> Void)? = nil,
        targetedBeforeSubmit: (@MainActor (_ tabID: UUID, _ session: TabSession) throws -> Void)? = nil
    ) async -> UserTurnSubmissionResult {
        let runtime: (tabID: UUID, sessionID: UUID)
        do {
            runtime = try await resolveOrCreateCoordinatorRuntimeDemoTarget(
                preferredSessionID: submission.coordinatorSessionID,
                forceNewRuntime: submission.forceNewRuntime,
                coordinatorModelID: submission.coordinatorModelID
            )
        } catch {
            return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard let session = sessions[runtime.tabID] else {
            return .blocked(message: "Coordinator composer is unavailable for this session state.")
        }
        guard Self.canAcceptCoordinatorDirective(runState: session.runState) else {
            return .blocked(message: "Coordinator is mid-run. Send directives when it reaches an ordinary turn boundary.")
        }
        guard let target = makeComposerSubmitTarget(tabID: runtime.tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == runtime.sessionID
        else {
            return .blocked(message: "Coordinator composer is unavailable for this session state.")
        }
        let result = await submitUserTurnCreatingSessionIfNeeded(
            text: submission.providerText,
            target: target,
            beforeSubmit: {
                try targetedBeforeSubmit?(runtime.tabID, session)
                if let expectedResolutionID = submission.acceptedRevisionDraftingResolutionID {
                    guard submission.coordinatorSessionID == runtime.sessionID,
                          session.coordinatorFollowThroughState?
                          .missionPlan?
                          .acceptedRevisionDraftingResolution?
                          .id == expectedResolutionID
                    else {
                        throw MCPError.invalidParams(CoordinatorMissionRevisionProposalPause.heldReason)
                    }
                }
                try beforeSubmit?()
            }
        ) {
            nil
        }
        if case .submitted = result,
           !isCoordinatorFollowThroughResumeDirective(submission.providerText)
        {
            rememberCoordinatorObjective(
                submission.visibleText,
                tabID: runtime.tabID,
                missionTemplate: submission.missionTemplate
            )
            completeStateOnlyMissionPlanIfRequested(
                by: submission.visibleText,
                tabID: runtime.tabID
            )
        }
        return result
    }

    @MainActor
    private func evaluateCoordinatorFollowThrough(
        trigger: CoordinatorAutoModeBoundaryClassifier.Trigger,
        snapshot explicitSnapshot: CoordinatorModeSnapshot? = nil
    ) async {
        if explicitSnapshot == nil {
            coordinatorModeViewModel.refresh()
        }
        let snapshot = explicitSnapshot ?? coordinatorModeViewModel.snapshot
        let rows = coordinatorModeRows(in: snapshot)
        let coordinatorIDs = Set(
            rows.compactMap { $0.parentCoordinator?.sessionID }
                + snapshot.coordinatorRail.availableCoordinators.map(\.sessionID)
        )
        for coordinatorID in coordinatorIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            await evaluateCoordinatorFollowThrough(
                coordinatorSessionID: coordinatorID,
                rows: rows,
                trigger: trigger
            )
        }
    }

    @MainActor
    private func evaluateCoordinatorFollowThrough(
        coordinatorSessionID: UUID,
        snapshot explicitSnapshot: CoordinatorModeSnapshot,
        trigger: CoordinatorAutoModeBoundaryClassifier.Trigger
    ) async {
        await evaluateCoordinatorFollowThrough(
            coordinatorSessionID: coordinatorSessionID,
            rows: coordinatorModeRows(in: explicitSnapshot),
            trigger: trigger
        )
    }

    @MainActor
    private func evaluateCoordinatorFollowThrough(
        coordinatorSessionID: UUID,
        rows: [CoordinatorModeRow],
        trigger: CoordinatorAutoModeBoundaryClassifier.Trigger
    ) async {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else { return }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        if reconcileAcceptedCoordinatorPostApprovalContinuation(
            coordinatorSessionID: coordinatorSessionID,
            tabID: tabID,
            session: session,
            state: &state
        ) {
            return
        }
        guard state.originalObjectiveSummary?.isEmpty == false else { return }
        guard state.missionPlan?.status.isTerminal != true else { return }
        guard let plan = state.missionPlan,
              plan.approvalState == .approved
        else { return }
        let shouldAutoSubmit = state.missionPlan?.policySnapshot?.defaultPace == .auto

        let ownedRows = rows.filter { $0.parentCoordinator?.sessionID == coordinatorSessionID }
        var shouldPersistObservedPhases = true
        defer {
            if shouldPersistObservedPhases {
                var latest = session.coordinatorFollowThroughState ?? state
                latest.updateObservedPhases(from: ownedRows)
                persistCoordinatorFollowThroughState(latest, tabID: tabID, session: session)
            }
        }
        if state.completeTerminalBoundRunningMissionPlanNodes(from: ownedRows) {
            persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
            coordinatorModeViewModel.refreshIfVisible()
        }

        if state.missionPlan?.pendingRevisionProposal != nil
            || state.missionPlan?.hasRevisionProposalDurabilityHold == true
        {
            if state.postApprovalContinuation?.status == .dispatching
                || state.postApprovalContinuation?.status.isDeliverable == true,
                state.markPostApprovalContinuationDeferred(
                    error: CoordinatorMissionRevisionProposalPause.heldReason
                )
            {
                persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
            }
            return
        }

        guard plan.hasDurableApprovalAuthority(
            coordinatorModeViewModel.durableApprovalAuthorityToken(coordinatorSessionID: coordinatorSessionID)
        ) else { return }

        if let continuation = state.postApprovalContinuation,
           continuation.status == .dispatching
        {
            shouldPersistObservedPhases = false
            if inFlightCoordinatorPostApprovalContinuationIDs.contains(continuation.id) {
                return
            }
            guard state.markPostApprovalContinuationDeferred(
                error: "Recovered an interrupted same-process continuation dispatch."
            ) else { return }
            persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
        }

        if let continuation = state.postApprovalContinuation,
           continuation.status.isDeliverable
        {
            shouldPersistObservedPhases = false
            if Self.canAcceptCoordinatorDirective(runState: session.runState) {
                await submitCoordinatorPostApprovalContinuation(continuation, tabID: tabID, session: session)
            } else if state.markPostApprovalContinuationDeferred(
                error: "Coordinator is mid-run. Continue when it reaches an ordinary turn boundary."
            ) {
                persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
            }
            return
        }

        if case .gateCleared = trigger {
            let classifier = CoordinatorAutoModeBoundaryClassifier()
            let input = CoordinatorAutoModeBoundaryClassifier.Input(
                autoModeEnabled: true,
                coordinatorSessionID: coordinatorSessionID,
                coordinatorRunState: session.runState,
                rows: rows,
                state: state,
                trigger: trigger
            )
            switch classifier.classify(input) {
            case let .resume(event):
                state.removePendingEvents { pending in
                    pending.kind != .gateCleared
                        && (
                            (event.childSessionID != nil && pending.childSessionID == event.childSessionID)
                                || (event.gate?.subjectID != nil && pending.gate?.subjectID == event.gate?.subjectID)
                        )
                }
                persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
                if shouldAutoSubmit {
                    await submitCoordinatorFollowThroughEvent(event, tabID: tabID, session: session)
                } else {
                    state.enqueue(event)
                    persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
                    coordinatorModeViewModel.refreshIfVisible()
                }
            case .hold(.coordinatorActive):
                var idleInput = input
                idleInput.coordinatorRunState = .idle
                if case let .resume(event) = classifier.classify(idleInput) {
                    state.removePendingEvents { pending in
                        pending.kind != .gateCleared
                            && (
                                (event.childSessionID != nil && pending.childSessionID == event.childSessionID)
                                    || (event.gate?.subjectID != nil && pending.gate?.subjectID == event.gate?.subjectID)
                            )
                    }
                    state.enqueue(event)
                    persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
                }
            case .hold:
                break
            }
            return
        }

        if Self.canAcceptCoordinatorDirective(runState: session.runState), let pending = state.pendingEvents.first {
            if shouldAutoSubmit {
                await submitCoordinatorFollowThroughEvent(pending, tabID: tabID, session: session)
            }
            return
        }

        let classifier = CoordinatorAutoModeBoundaryClassifier()
        var input = CoordinatorAutoModeBoundaryClassifier.Input(
            autoModeEnabled: true,
            coordinatorSessionID: coordinatorSessionID,
            coordinatorRunState: session.runState,
            rows: rows,
            state: state,
            trigger: trigger
        )
        let decision = classifier.classify(input)
        switch decision {
        case let .resume(event):
            if shouldAutoSubmit {
                await submitCoordinatorFollowThroughEvent(event, tabID: tabID, session: session)
            } else {
                state.enqueue(event)
                persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
                coordinatorModeViewModel.refreshIfVisible()
            }
        case .hold(.coordinatorActive):
            input.coordinatorRunState = .idle
            if case let .resume(event) = classifier.classify(input) {
                state.enqueue(event)
                persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
            }
        case .hold:
            break
        }
    }

    @MainActor
    private func reconcileAcceptedCoordinatorPostApprovalContinuation(
        coordinatorSessionID: UUID,
        tabID: UUID,
        session: TabSession,
        state: inout CoordinatorFollowThroughState
    ) -> Bool {
        clearAcceptedCoordinatorPostApprovalContinuationReceiptsIfSafelyInvalidated(
            coordinatorSessionID: coordinatorSessionID,
            state: state
        )
        guard let continuation = state.postApprovalContinuation else { return false }
        let identity = CoordinatorPostApprovalContinuationIdentity(continuation)
        guard acceptedCoordinatorPostApprovalContinuationReceipts.contains(identity) else { return false }

        if continuation.status.isDeliverable || continuation.status == .dispatching,
           state.missionPlan?.id == continuation.planID,
           state.reconcileAcceptedPostApprovalContinuationDelivery()
        {
            persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
            acceptedCoordinatorPostApprovalContinuationReceipts.remove(identity)
            coordinatorModeViewModel.refreshIfVisible()
        } else if continuation.status == .delivered {
            acceptedCoordinatorPostApprovalContinuationReceipts.remove(identity)
        }
        return true
    }

    @MainActor
    private func clearAcceptedCoordinatorPostApprovalContinuationReceiptsIfSafelyInvalidated(
        coordinatorSessionID: UUID,
        state: CoordinatorFollowThroughState
    ) {
        let planInvalidated = state.missionPlan?.status.isTerminal == true
            || state.missionPlan?.approvalState == .revisionRequested
            || state.missionPlan?.approvalState == .awaitingApproval
        let continuationInvalidated = state.postApprovalContinuation?.status == .invalidated
        guard planInvalidated || continuationInvalidated else { return }
        let invalidatedReceipts = acceptedCoordinatorPostApprovalContinuationReceipts.filter {
            $0.coordinatorSessionID == coordinatorSessionID
        }
        for receipt in invalidatedReceipts {
            acceptedCoordinatorPostApprovalContinuationReceipts.remove(receipt)
        }
    }

    @MainActor
    private func submitCoordinatorPostApprovalContinuation(
        _ continuation: CoordinatorPostApprovalContinuationRecord,
        tabID: UUID,
        session: TabSession
    ) async {
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        guard state.postApprovalContinuation?.id == continuation.id,
              state.markPostApprovalContinuationDispatching()
        else { return }
        inFlightCoordinatorPostApprovalContinuationIDs.insert(continuation.id)
        defer { inFlightCoordinatorPostApprovalContinuationIDs.remove(continuation.id) }
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)

        let result: UserTurnSubmissionResult
        #if DEBUG
            if let test_coordinatorContinuationSubmitter {
                do {
                    try validatePostApprovalContinuationEnqueueAuthority(continuation)
                    result = await test_coordinatorContinuationSubmitter(continuation)
                } catch {
                    result = .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            } else {
                result = await submitCoordinatorPostApprovalContinuationDirective(continuation)
            }
        #else
            result = await submitCoordinatorPostApprovalContinuationDirective(continuation)
        #endif
        #if DEBUG
            test_afterCoordinatorContinuationSubmitResult?(continuation, result)
        #endif
        let identity = CoordinatorPostApprovalContinuationIdentity(continuation)
        if result == .submitted {
            acceptedCoordinatorPostApprovalContinuationReceipts.insert(identity)
        }
        guard let currentSession = sessions[tabID],
              currentSession.activeAgentSessionID == continuation.coordinatorSessionID,
              currentSession.isCoordinatorRuntime
        else {
            coordinatorModeViewModel.refreshIfVisible()
            return
        }
        state = currentSession.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        guard let currentPlan = state.missionPlan,
              let currentContinuation = state.postApprovalContinuation,
              CoordinatorPostApprovalContinuationIdentity(currentContinuation) == identity,
              currentPlan.id == continuation.planID,
              currentContinuation.status == .dispatching
        else {
            clearAcceptedCoordinatorPostApprovalContinuationReceiptsIfSafelyInvalidated(
                coordinatorSessionID: continuation.coordinatorSessionID,
                state: state
            )
            coordinatorModeViewModel.refreshIfVisible()
            return
        }
        switch result {
        case .submitted:
            if state.markPostApprovalContinuationDelivered() {
                persistCoordinatorFollowThroughState(state, tabID: tabID, session: currentSession)
                acceptedCoordinatorPostApprovalContinuationReceipts.remove(identity)
            }
        case let .blocked(message):
            let changed = if message.localizedCaseInsensitiveContains("mid-run")
                || message.localizedCaseInsensitiveContains(CoordinatorMissionRevisionProposalPause.heldReason)
            {
                state.markPostApprovalContinuationDeferred(error: message)
            } else {
                state.markPostApprovalContinuationFailed(error: message)
            }
            if changed {
                persistCoordinatorFollowThroughState(state, tabID: tabID, session: currentSession)
            }
        }
        coordinatorModeViewModel.refreshIfVisible()
    }

    @MainActor
    private func submitCoordinatorPostApprovalContinuationDirective(
        _ continuation: CoordinatorPostApprovalContinuationRecord
    ) async -> UserTurnSubmissionResult {
        await submitCoordinatorDirectiveToAgentMode(
            continuation.directiveText,
            coordinatorSessionID: continuation.coordinatorSessionID,
            forceNewRuntime: false,
            targetedBeforeSubmit: { [weak self] tabID, session in
                guard let self else {
                    throw MCPError.invalidParams("Coordinator continuation authority is unavailable.")
                }
                try validatePostApprovalContinuationAtFinalEnqueue(
                    continuation,
                    tabID: tabID,
                    expectedSession: session
                )
            }
        )
    }

    @MainActor
    private func validatePostApprovalContinuationAtFinalEnqueue(
        _ continuation: CoordinatorPostApprovalContinuationRecord,
        tabID: UUID,
        expectedSession: TabSession
    ) throws {
        #if DEBUG
            test_beforeCoordinatorContinuationEnqueueAuthorityValidation?(continuation)
        #endif
        guard sessions[tabID] === expectedSession,
              expectedSession.activeAgentSessionID == continuation.coordinatorSessionID,
              expectedSession.isCoordinatorRuntime
        else {
            throw MCPError.invalidParams("Post-approval continuation enqueue rejected because the target Coordinator session changed.")
        }
        try validatePostApprovalContinuationEnqueueAuthority(continuation, in: expectedSession)
    }

    @MainActor
    @discardableResult
    private func submitCoordinatorFollowThroughEvent(
        _ event: CoordinatorFollowThroughEvent,
        tabID: UUID,
        session: TabSession
    ) async -> CoordinatorModeViewModel.DirectiveSubmissionResult {
        guard Self.canAcceptCoordinatorDirective(runState: session.runState) else {
            var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
            state.enqueue(event)
            state.markDeferred(event)
            persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
            return .rejected(message: "Coordinator is mid-run. Continue when it reaches an ordinary turn boundary.")
        }
        let result = await submitCoordinatorDirectiveToAgentMode(
            event.resumeDirective,
            coordinatorSessionID: event.coordinatorSessionID,
            forceNewRuntime: false,
            targetedBeforeSubmit: { tabID, expectedSession in
                guard self.sessions[tabID] === expectedSession,
                      let plan = expectedSession.coordinatorFollowThroughState?.missionPlan,
                      !plan.status.isTerminal,
                      plan.pendingRevisionProposal == nil,
                      !plan.hasRevisionProposalDurabilityHold
                else {
                    throw MCPError.invalidParams(CoordinatorMissionRevisionProposalPause.heldReason)
                }
            }
        )
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        switch result {
        case .submitted:
            state.markSubmitted(event)
            persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
            return .accepted
        case let .blocked(message):
            state.enqueue(event)
            state.markDeferred(event)
            persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
            return .rejected(message: message)
        }
    }

    @MainActor
    private func rememberCoordinatorChildInteractionResponse(_ text: String, row: CoordinatorModeRow) {
        guard let coordinatorID = row.parentCoordinator?.sessionID,
              let match = sessions.first(where: { _, session in
                  session.activeAgentSessionID == coordinatorID && session.isCoordinatorRuntime
              })
        else { return }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        state.rememberChildInteractionResponse(row: row, text: text)
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
    }

    @MainActor
    private func rememberCoordinatorObjective(
        _ text: String,
        tabID: UUID,
        missionTemplate: CoordinatorMissionTemplateSummary? = nil
    ) {
        guard let session = sessions[tabID], session.isCoordinatorRuntime else { return }
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        state.rememberObjective(text, missionTemplate: missionTemplate, resetMissionPlan: false)
        if let coordinatorID = session.activeAgentSessionID {
            let existingRows = coordinatorModeRows(in: coordinatorModeViewModel.snapshot)
                .filter { $0.parentCoordinator?.sessionID == coordinatorID }
            state.updateObservedPhases(from: existingRows)
        }
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
    }

    @MainActor
    private func updateCoordinatorMissionPlan(
        coordinatorSessionID: UUID,
        update: CoordinatorMissionPlanUpdate
    ) throws {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            throw MCPError.invalidParams("Coordinator session \(coordinatorSessionID.uuidString) is not live in this window.")
        }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        try state.applyMissionPlanUpdate(update)
        clearAcceptedCoordinatorPostApprovalContinuationReceiptsIfSafelyInvalidated(
            coordinatorSessionID: coordinatorSessionID,
            state: state
        )
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
    }

    @MainActor
    private func appendCoordinatorMissionRevisionProposal(
        coordinatorSessionID: UUID,
        request: CoordinatorMissionRevisionProposalRequest
    ) async throws -> CoordinatorMissionRevisionProposalAppendResult {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            throw MCPError.invalidParams("Coordinator session \(coordinatorSessionID.uuidString) is not live in this window.")
        }
        let tabID = match.key
        let session = match.value
        guard request.actor.coordinatorSessionID == coordinatorSessionID,
              request.actor.runtimeSessionID == coordinatorSessionID,
              request.actor.role == "director"
        else {
            throw MCPError.invalidParams("Coordinator Mission revision proposal actor does not match the owning Director runtime.")
        }
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        guard let originalPlan = state.missionPlan else {
            throw MCPError.invalidParams("Coordinator Mission Plan state is unavailable.")
        }
        guard originalPlan.approvalState == .approved else {
            throw MCPError.invalidParams("Coordinator Mission revision proposals require an approved Mission Plan.")
        }
        let result = try state.appendRevisionProposal(request)
        guard let expectedPlan = state.missionPlan,
              let expectedProposal = expectedPlan.revisionProposals.first(where: { $0.id == result.proposalID })
        else {
            throw MCPError.invalidParams("Coordinator Mission revision proposal append did not install canonical state.")
        }
        try validateRevisionProposal(
            expectedProposal,
            request: request,
            originalPlan: originalPlan,
            result: result
        )
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
        let minimumGeneration = session.saveRequestGeneration
        guard await persistRevisionProposal(tabID: tabID, minimumGeneration: minimumGeneration) else {
            throw MCPError.invalidParams("Coordinator Mission persistence did not durably save the revision proposal before success.")
        }
        guard sessions[tabID] === session,
              let persistedPlan = session.coordinatorFollowThroughState?.missionPlan,
              persistedPlan == expectedPlan,
              persistedPlan.pendingRevisionProposal?.id == result.proposalID,
              persistedPlan.decisions == originalPlan.decisions,
              persistedPlan.revisionProposalResolutions == originalPlan.revisionProposalResolutions,
              persistedPlan.id == request.expectedBasePlanID,
              persistedPlan.approvalState == .approved,
              !persistedPlan.status.isTerminal,
              persistedPlan.materialContractSnapshot == originalPlan.materialContractSnapshot,
              try persistedPlan.materialContractFingerprint() == request.expectedBaseContractFingerprint,
              let persistedProposal = persistedPlan.revisionProposals.first(where: { $0.id == result.proposalID })
        else {
            throw MCPError.invalidParams("Coordinator Mission revision proposal changed before durable persistence completed.")
        }
        try validateRevisionProposal(
            persistedProposal,
            request: request,
            originalPlan: originalPlan,
            result: result
        )
        let matchingEvents = persistedPlan.events.filter {
            $0.kind == .revisionProposalFiled && $0.proposalID == result.proposalID
        }
        guard matchingEvents.count == 1,
              matchingEvents[0].sessionID == request.actor.runtimeSessionID,
              expectedPlan.events == persistedPlan.events
        else {
            throw MCPError.invalidParams("Coordinator Mission revision proposal event changed before durable persistence completed.")
        }
        return result
    }

    @MainActor
    private func resolveCoordinatorMissionRevisionProposal(
        _ request: CoordinatorMissionRevisionProposalTrustedResolutionRequest
    ) async throws -> CoordinatorMissionRevisionProposalResolutionResult {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == request.coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            throw MCPError.invalidParams("Coordinator session \(request.coordinatorSessionID.uuidString) is not live in this window.")
        }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        let result = try state.resolveRevisionProposalTransaction(request)
        if result.disposition == .existingResolutionRetry,
           state.missionPlan?.revisionProposalDurabilityHold == nil
        {
            return result
        }
        guard let expectedPlan = state.missionPlan,
              expectedPlan.revisionProposalDurabilityHold?.transactionID == result.resolutionID
        else {
            throw MCPError.invalidParams("Coordinator Mission revision proposal resolution did not install its durability hold.")
        }
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
        let minimumGeneration = session.saveRequestGeneration
        guard await persistRevisionProposal(tabID: tabID, minimumGeneration: minimumGeneration) else {
            throw MCPError.invalidParams("Coordinator Mission persistence did not durably save the revision proposal resolution; authority remains held and the action is retryable.")
        }
        guard sessions[tabID] === session,
              session.coordinatorFollowThroughState?.missionPlan == expectedPlan,
              expectedPlan.revisionProposalDurabilityHold?.transactionID == result.resolutionID,
              !expectedPlan.status.isTerminal
        else {
            throw MCPError.invalidParams("Coordinator Mission revision proposal resolution changed before durable persistence completed; authority remains held.")
        }
        state = try await clearAndPersistRevisionProposalDurabilityHold(
            in: session.coordinatorFollowThroughState ?? state,
            transactionID: result.resolutionID,
            tabID: tabID,
            session: session
        )
        clearAcceptedCoordinatorPostApprovalContinuationReceiptsIfSafelyInvalidated(
            coordinatorSessionID: request.coordinatorSessionID,
            state: state
        )

        if request.action == .revisePlan {
            guard let lineage = state.missionPlan?.acceptedRevisionLineage(
                resolutionID: result.resolutionID
            )
            else {
                throw MCPError.invalidParams(
                    "Durable revision proposal lineage is unavailable for drafting."
                )
            }
            let directive = CoordinatorModeViewModel.revisionDraftingDirective(
                proposal: lineage.proposal,
                resolution: lineage.resolution
            )
            let submission = CoordinatorDirectiveSubmission(
                visibleText: directive,
                providerText: directive,
                missionTemplate: nil,
                missionPolicySnapshot: nil,
                coordinatorSessionID: request.coordinatorSessionID,
                coordinatorModelID: nil,
                forceNewRuntime: false,
                acceptedRevisionDraftingResolutionID: lineage.resolution.id
            )
            #if DEBUG
                test_revisionDraftingDirectiveWillSubmit?(directive, lineage.resolution.id)
                let submissionResult = if let test_revisionDraftingDirectiveSubmitter {
                    await test_revisionDraftingDirectiveSubmitter(submission)
                } else {
                    await submitCoordinatorDirectiveToAgentMode(submission)
                }
            #else
                let submissionResult = await submitCoordinatorDirectiveToAgentMode(submission)
            #endif
            guard case .submitted = submissionResult else {
                throw MCPError.invalidParams(
                    "The revision decision is durable, but the trusted drafting directive could not be submitted."
                )
            }
        }
        return result
    }

    @MainActor
    private func clearAndPersistRevisionProposalDurabilityHold(
        in state: CoordinatorFollowThroughState,
        transactionID: UUID,
        tabID: UUID,
        session: TabSession
    ) async throws -> CoordinatorFollowThroughState {
        var cleared = state
        guard let hold = cleared.missionPlan?.revisionProposalDurabilityHold,
              hold.transactionID == transactionID,
              cleared.clearRevisionProposalDurabilityHold(transactionID: transactionID)
        else {
            throw MCPError.invalidParams("Coordinator Mission revision proposal durability hold could not be cleared.")
        }
        persistCoordinatorFollowThroughState(cleared, tabID: tabID, session: session)
        let minimumGeneration = session.saveRequestGeneration
        guard await persistRevisionProposal(tabID: tabID, minimumGeneration: minimumGeneration),
              sessions[tabID] === session,
              session.coordinatorFollowThroughState == cleared,
              cleared.missionPlan?.revisionProposalDurabilityHold == nil
        else {
            var failedClosed = session.coordinatorFollowThroughState ?? cleared
            failedClosed.missionPlan?.revisionProposalDurabilityHold = hold
            persistCoordinatorFollowThroughState(failedClosed, tabID: tabID, session: session)
            throw MCPError.invalidParams("Coordinator Mission durability-hold clearance was not durably saved; authority remains held and the action is retryable.")
        }
        return cleared
    }

    @MainActor
    private func persistRevisionProposal(
        tabID: UUID,
        minimumGeneration: UInt64
    ) async -> Bool {
        #if DEBUG
            if let test_revisionProposalPersistenceBarrier {
                return await test_revisionProposalPersistenceBarrier(tabID, minimumGeneration)
            }
        #endif
        return await flushSave(for: tabID, requiringMinimumSaveGeneration: minimumGeneration)
    }

    private func validateRevisionProposal(
        _ proposal: CoordinatorMissionRevisionProposal,
        request: CoordinatorMissionRevisionProposalRequest,
        originalPlan: CoordinatorMissionPlan,
        result: CoordinatorMissionRevisionProposalAppendResult
    ) throws {
        let affectedFields = CoordinatorMissionRevisionProposalIdentity.canonicalAffectedFields(request.affectedFields)
        let remedy = CoordinatorMissionRevisionProposalIdentity.canonicalRemedy(request.remedy)
        let evidenceIDs = CoordinatorMissionRevisionProposalIdentity.canonicalEvidenceIDs(request.supportingEvidenceIDs)
        let requestedChange = CoordinatorMissionCanonicalRequestedChange(rawValue: request.requestedChange)
        let canonicalRequestIdentity = try CoordinatorMissionRevisionProposalIdentity.canonicalRequestIdentity(
            baseContractFingerprint: request.expectedBaseContractFingerprint,
            affectedFields: affectedFields,
            remedy: remedy,
            supportingEvidenceIDs: evidenceIDs,
            requestedChange: requestedChange
        )
        guard proposal.id == result.proposalID,
              proposal.canonicalRequestIdentity == canonicalRequestIdentity,
              proposal.canonicalRequestIdentityVersion == CoordinatorMissionRevisionProposal.canonicalRequestIdentityVersion,
              proposal.basePlanID == request.expectedBasePlanID,
              proposal.baseContractSnapshot == originalPlan.materialContractSnapshot,
              proposal.baseContractFingerprint == request.expectedBaseContractFingerprint,
              proposal.representation == .summaryOnly,
              proposal.affectedFields == affectedFields,
              proposal.remedy == remedy,
              proposal.supportingEvidenceIDs == evidenceIDs,
              proposal.requestedChange == requestedChange,
              proposal.actor == request.actor
        else {
            throw MCPError.invalidParams("Coordinator Mission revision proposal does not match the canonical persisted request.")
        }
        if result.disposition == .appended {
            guard proposal.summary == request.summary,
                  proposal.rationale == request.rationale
            else {
                throw MCPError.invalidParams("Coordinator Mission revision proposal summary changed before persistence.")
            }
        }
    }

    @MainActor
    private func requestTrustedRevisedPlanChange(
        coordinatorSessionID: UUID,
        planID: UUID,
        planRevision: Int,
        expectedCheckpointInstanceID: String,
        resolutionID: UUID
    ) async throws {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            throw MCPError.invalidParams("Coordinator session \(coordinatorSessionID.uuidString) is not live in this window.")
        }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        let originalState = state
        guard let plan = state.missionPlan,
              plan.id == planID,
              plan.revision == planRevision,
              plan.approvalState == .awaitingApproval,
              !plan.status.isTerminal,
              plan.latestAcceptedRevisionLineage?.resolution.id == resolutionID
        else {
            throw MCPError.invalidParams("The rendered revised Mission Plan changed before another revision was requested.")
        }
        let currentCheckpoint = "coordinator:\(coordinatorSessionID.uuidString):plan-approval:r\(planRevision)"
        guard expectedCheckpointInstanceID == currentCheckpoint else {
            throw MCPError.invalidParams("The rendered revised Mission Plan checkpoint is stale.")
        }
        let timestamp = Date()
        let decision = CoordinatorMissionDecisionRecord(
            userDecision: .requestedPlanRevision,
            decisionClass: .plan,
            checkpointInstanceID: currentCheckpoint,
            timestamp: timestamp,
            checkpointID: "plan-approval"
        )
        try state.applyMissionPlanUpdate(CoordinatorMissionPlanUpdate(
            approvalState: .revisionRequested,
            decisions: [decision],
            events: [
                CoordinatorMissionPlanEvent(
                    kind: .revised,
                    timestamp: timestamp,
                    summary: "Another concrete Mission plan revision requested by user."
                )
            ],
            updatedAt: timestamp
        ))
        guard let expectedPlan = state.missionPlan,
              expectedPlan.approvalState == .revisionRequested,
              expectedPlan.latestAcceptedRevisionLineage?.resolution.id == resolutionID,
              expectedPlan.decisions.contains(where: {
                  $0.checkpointInstanceID == currentCheckpoint
                      && $0.label == CoordinatorMissionUserDecisionLabel.requestedPlanRevision.rawValue
              })
        else {
            throw MCPError.invalidParams("Coordinator Mission revision request did not install canonical held state.")
        }
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
        let minimumGeneration = session.saveRequestGeneration
        let persisted = await persistRevisionProposal(tabID: tabID, minimumGeneration: minimumGeneration)
        guard persisted,
              sessions[tabID] === session,
              session.coordinatorFollowThroughState?.missionPlan == expectedPlan
        else {
            if sessions[tabID] === session {
                persistCoordinatorFollowThroughState(originalState, tabID: tabID, session: session)
            }
            throw MCPError.invalidParams("Coordinator Mission revision request was not durably saved before drafting guidance.")
        }
    }

    @MainActor
    private func applyTrustedCoordinatorMissionContractChange(
        coordinatorSessionID: UUID,
        update: CoordinatorMissionPlanUpdate
    ) async throws {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            throw MCPError.invalidParams("Coordinator session \(coordinatorSessionID.uuidString) is not live in this window.")
        }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        let result = try state.applyTrustedContractChangeInvalidatingRevisionProposal(
            update,
            coordinatorSessionID: coordinatorSessionID
        )
        guard let result,
              let expectedPlan = state.missionPlan,
              expectedPlan.revisionProposalDurabilityHold?.transactionID == result.resolutionID
        else {
            throw MCPError.invalidParams("Coordinator Mission contract change did not invalidate the pending proposal atomically.")
        }
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
        let minimumGeneration = session.saveRequestGeneration
        guard await persistRevisionProposal(tabID: tabID, minimumGeneration: minimumGeneration) else {
            throw MCPError.invalidParams("Coordinator Mission contract change was not durably saved; authority remains held and the action is retryable.")
        }
        guard sessions[tabID] === session,
              session.coordinatorFollowThroughState?.missionPlan == expectedPlan
        else {
            throw MCPError.invalidParams("Coordinator Mission contract changed again before durable persistence completed.")
        }
        state = try await clearAndPersistRevisionProposalDurabilityHold(
            in: session.coordinatorFollowThroughState ?? state,
            transactionID: result.resolutionID,
            tabID: tabID,
            session: session
        )
        clearAcceptedCoordinatorPostApprovalContinuationReceiptsIfSafelyInvalidated(
            coordinatorSessionID: coordinatorSessionID,
            state: state
        )
    }

    @MainActor
    private func recordTrustedCoordinatorMissionStop(
        coordinatorSessionID: UUID,
        targetSessionIDs: [UUID]
    ) async throws {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            throw MCPError.invalidParams("Coordinator session \(coordinatorSessionID.uuidString) is not live in this window.")
        }
        let tabID = match.key
        let session = match.value
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        let result = try state.stopMissionTransaction(
            coordinatorSessionID: coordinatorSessionID,
            cancelledSessionIDs: Set(targetSessionIDs)
        )
        guard let expectedPlan = state.missionPlan, expectedPlan.status == .stopped else {
            throw MCPError.invalidParams("Coordinator Mission Stop did not install terminal state.")
        }
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
        let minimumGeneration = session.saveRequestGeneration
        guard await persistRevisionProposal(tabID: tabID, minimumGeneration: minimumGeneration) else {
            throw MCPError.invalidParams("Coordinator Mission Stop was not durably saved; cancellation was not started.")
        }
        guard sessions[tabID] === session,
              session.coordinatorFollowThroughState?.missionPlan == expectedPlan,
              session.coordinatorFollowThroughState?.missionPlan?.status == .stopped
        else {
            throw MCPError.invalidParams("Coordinator Mission Stop state changed before durable persistence completed.")
        }
        if let result {
            state = try await clearAndPersistRevisionProposalDurabilityHold(
                in: session.coordinatorFollowThroughState ?? state,
                transactionID: result.resolutionID,
                tabID: tabID,
                session: session
            )
        }
        clearAcceptedCoordinatorPostApprovalContinuationReceiptsIfSafelyInvalidated(
            coordinatorSessionID: coordinatorSessionID,
            state: state
        )
    }

    @MainActor
    private func stopCoordinatorMissionRuntime(
        _ request: CoordinatorMissionStopRequest
    ) async -> CoordinatorMissionStopResult {
        var cancelledSessionIDs: [UUID] = []
        var skippedSessionIDs: [UUID] = []
        for sessionID in request.sessionIDs {
            guard let match = sessions.first(where: { _, session in
                session.activeAgentSessionID == sessionID
            }) else {
                skippedSessionIDs.append(sessionID)
                continue
            }
            let tabID = match.key
            let session = match.value
            guard session.runState.isActive else {
                skippedSessionIDs.append(sessionID)
                continue
            }
            await cancelAgentRun(tabID: tabID, completion: .terminalPublished)
            cancelledSessionIDs.append(sessionID)
        }
        return CoordinatorMissionStopResult(
            requestedSessionIDs: request.sessionIDs,
            cancelledSessionIDs: cancelledSessionIDs,
            skippedSessionIDs: skippedSessionIDs
        )
    }

    @MainActor
    private func persistCoordinatorFollowThroughState(
        _ state: CoordinatorFollowThroughState,
        tabID: UUID,
        session: TabSession
    ) {
        session.coordinatorFollowThroughState = state
        session.isDirty = true
        scheduleSave(for: tabID)
    }

    @MainActor
    private func flushCoordinatorPostApprovalContinuationPersistence(
        _ token: CoordinatorModeViewModel.PostApprovalContinuationPersistenceToken
    ) async throws {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == token.coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            throw MCPError.invalidParams("Coordinator Mission persistence failed because the Coordinator session is no longer live.")
        }
        let tabID = match.key
        let session = match.value
        let minimumGeneration = session.saveRequestGeneration
        try validatePostApprovalContinuationPersistenceToken(token, in: session)
        let didFlush: Bool
        #if DEBUG
            if let test_postApprovalContinuationPersistenceBarrier {
                didFlush = await test_postApprovalContinuationPersistenceBarrier(tabID, minimumGeneration)
            } else {
                didFlush = await flushSave(for: tabID, requiringMinimumSaveGeneration: minimumGeneration)
            }
        #else
            didFlush = await flushSave(for: tabID, requiringMinimumSaveGeneration: minimumGeneration)
        #endif
        guard didFlush else {
            throw MCPError.invalidParams("Coordinator Mission persistence did not durably save the approved continuation before dispatch.")
        }
        guard sessions[tabID] === session else {
            throw MCPError.invalidParams("Coordinator Mission persistence target changed before dispatch.")
        }
        try validatePostApprovalContinuationPersistenceToken(token, in: session)
    }

    @MainActor
    private func validatePostApprovalContinuationPersistenceToken(
        _ token: CoordinatorModeViewModel.PostApprovalContinuationPersistenceToken,
        in session: TabSession
    ) throws {
        guard let plan = session.coordinatorFollowThroughState?.missionPlan,
              let continuation = plan.postApprovalContinuation,
              continuation.id == token.continuationID,
              continuation.coordinatorSessionID == token.coordinatorSessionID,
              continuation.checkpointInstanceID == token.checkpointInstanceID,
              continuation.planID == token.planID,
              continuation.planRevision == token.planRevision
        else {
            throw MCPError.invalidParams("Post-approval continuation changed before it was durably saved.")
        }
        guard plan.id == token.planID,
              plan.approvalState == .approved,
              !plan.status.isTerminal
        else {
            throw MCPError.invalidParams("Approved Mission Plan authority changed before continuation dispatch.")
        }
        guard continuation.status == .pending || continuation.status == .deferred else {
            throw MCPError.invalidParams("Post-approval continuation is \(continuation.status.rawValue), not pending or deferred.")
        }
    }

    @MainActor
    private func validatePostApprovalContinuationEnqueueAuthority(
        _ expected: CoordinatorPostApprovalContinuationRecord
    ) throws {
        guard let session = sessions.values.first(where: { session in
            session.activeAgentSessionID == expected.coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            throw MCPError.invalidParams("Post-approval continuation enqueue rejected because the Coordinator Mission is unavailable.")
        }
        try validatePostApprovalContinuationEnqueueAuthority(expected, in: session)
    }

    @MainActor
    private func validatePostApprovalContinuationEnqueueAuthority(
        _ expected: CoordinatorPostApprovalContinuationRecord,
        in session: TabSession
    ) throws {
        guard let plan = session.coordinatorFollowThroughState?.missionPlan,
              let continuation = plan.postApprovalContinuation
        else {
            throw MCPError.invalidParams("Post-approval continuation enqueue rejected because the Coordinator Mission is unavailable.")
        }
        guard continuation.id == expected.id,
              continuation.coordinatorSessionID == expected.coordinatorSessionID,
              continuation.checkpointInstanceID == expected.checkpointInstanceID,
              continuation.planID == expected.planID,
              continuation.planRevision == expected.planRevision
        else {
            throw MCPError.invalidParams("Post-approval continuation enqueue rejected because the continuation identity changed.")
        }
        guard plan.pendingRevisionProposal == nil,
              !plan.hasRevisionProposalDurabilityHold
        else {
            throw MCPError.invalidParams(CoordinatorMissionRevisionProposalPause.heldReason)
        }
        guard continuation.status == .dispatching,
              plan.id == expected.planID,
              plan.approvalState == .approved,
              plan.hasDurableApprovalAuthority(coordinatorModeViewModel.durableApprovalAuthorityToken(coordinatorSessionID: expected.coordinatorSessionID)),
              !plan.status.isTerminal
        else {
            throw MCPError.invalidParams("Post-approval continuation enqueue rejected because Mission authority changed before dispatch.")
        }
    }

    private func isCoordinatorFollowThroughResumeDirective(_ text: String) -> Bool {
        text.contains("<coordinator_follow_through_resume")
            || text.contains("<coordinator_post_approval_continuation")
            || text.contains("<coordinator_revision_drafting>")
    }

    @MainActor
    private func completeStateOnlyMissionPlanIfRequested(by text: String, tabID: UUID) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains("complete"),
              normalized.contains("mission plan"),
              normalized.contains("review.dependencies_satisfied is true")
        else { return }
        guard let session = sessions[tabID], session.isCoordinatorRuntime else { return }
        var state = session.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        guard let coordinatorSessionID = session.activeAgentSessionID,
              state.missionPlan?.hasDurableApprovalAuthority(coordinatorModeViewModel.durableApprovalAuthorityToken(coordinatorSessionID: coordinatorSessionID)) == true,
              state.completeSatisfiedCoordinatorOnlyRunningMissionPlanNodes()
        else { return }
        persistCoordinatorFollowThroughState(state, tabID: tabID, session: session)
    }

    private func coordinatorModeRows(in snapshot: CoordinatorModeSnapshot) -> [CoordinatorModeRow] {
        coordinatorModeViewModel.coordinatorModeRowsForRouting(in: snapshot)
    }

    @MainActor
    private func pendingCoordinatorFollowThroughEvent(coordinatorSessionID: UUID?) -> CoordinatorFollowThroughEvent? {
        guard let coordinatorSessionID,
              let session = sessions.values.first(where: { session in
                  session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
              })
        else { return nil }
        return session.coordinatorFollowThroughState?.pendingEvents.first
    }

    @MainActor
    private func submitPendingCoordinatorFollowThroughEvent(
        _ event: CoordinatorFollowThroughEvent
    ) async -> CoordinatorModeViewModel.DirectiveSubmissionResult {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == event.coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            return .rejected(message: "Coordinator follow-through is unavailable.")
        }
        return await submitCoordinatorFollowThroughEvent(event, tabID: match.key, session: match.value)
    }

    @MainActor
    private func resolvePendingCoordinatorFollowThroughEvent(_ event: CoordinatorFollowThroughEvent) {
        guard let match = sessions.first(where: { _, session in
            session.activeAgentSessionID == event.coordinatorSessionID && session.isCoordinatorRuntime
        }) else { return }
        var state = match.value.coordinatorFollowThroughState ?? CoordinatorFollowThroughState()
        state.markSubmitted(event)
        persistCoordinatorFollowThroughState(state, tabID: match.key, session: match.value)
    }

    @MainActor
    func submitChildDirectiveToAgentMode(
        _ text: String,
        row: CoordinatorModeRow
    ) async -> UserTurnSubmissionResult {
        guard let tabID = row.tabID else {
            return .blocked(message: "This session is not live in the current window.")
        }
        guard let session = sessions[tabID] else {
            return .blocked(message: "This session is no longer available.")
        }
        guard session.activeAgentSessionID == row.sessionID else {
            return .blocked(message: "This session changed before the reply could be sent.")
        }
        guard row.runState != .running else {
            return .blocked(message: "This session is mid-run. Reply when it reaches a turn boundary.")
        }
        if let pendingInteraction = row.pendingInteraction {
            do {
                _ = try await mcpResolvePendingInteraction(
                    sessionID: row.sessionID,
                    interactionID: pendingInteraction.id,
                    payload: MCPInteractionResponsePayload(
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        skip: false,
                        decisionRaw: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        amendment: nil,
                        answersByQuestionID: [:],
                        elicitationActionRaw: text.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    beforeResolve: { [weak self] in
                        guard let self else {
                            throw MCPError.invalidParams("Coordinator child-answer authority is unavailable.")
                        }
                        try validateChildInteractionAnswerAuthority(row: row)
                    }
                )
                return .submitted
            } catch {
                return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        guard let target = makeComposerSubmitTarget(tabID: tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == row.sessionID
        else {
            return .blocked(message: "This session cannot receive a reply yet.")
        }
        return await submitUserTurnCreatingSessionIfNeeded(text: text, target: target) {
            nil
        }
    }

    @MainActor
    private func validateChildInteractionAnswerAuthority(row: CoordinatorModeRow) throws {
        guard let coordinatorSessionID = row.parentCoordinator?.sessionID,
              let coordinatorSession = sessions.values.first(where: {
                  $0.activeAgentSessionID == coordinatorSessionID && $0.isCoordinatorRuntime
              }),
              let plan = coordinatorSession.coordinatorFollowThroughState?.missionPlan
        else {
            throw MCPError.invalidParams("Coordinator child-answer authority is unavailable.")
        }
        guard !plan.holdsChildInteractionsForRevisionProposal else {
            throw MCPError.invalidParams(CoordinatorMissionRevisionProposalPause.heldReason)
        }
    }

    @MainActor
    func submitChildInteractionResponseToAgentMode(
        _ submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission,
        row: CoordinatorModeRow
    ) async -> UserTurnSubmissionResult {
        guard let tabID = row.tabID else {
            return .blocked(message: "This session is not live in the current window.")
        }
        guard let session = sessions[tabID] else {
            return .blocked(message: "This session is no longer available.")
        }
        guard session.activeAgentSessionID == row.sessionID else {
            return .blocked(message: "This session changed before the reply could be sent.")
        }
        guard let pendingInteraction = row.pendingInteraction else {
            return .blocked(message: "This child session is no longer waiting for input.")
        }
        do {
            _ = try await mcpResolvePendingInteraction(
                sessionID: row.sessionID,
                interactionID: pendingInteraction.id,
                payload: MCPInteractionResponsePayload(
                    text: submission.text,
                    skip: submission.skip,
                    explicitSkip: submission.skip,
                    decisionRaw: submission.text,
                    amendment: nil,
                    answersByQuestionID: [:],
                    askUserAnswersByQuestionID: submission.answersByQuestionID,
                    hasStructuredAnswerObjects: submission.hasStructuredAnswers,
                    elicitationActionRaw: submission.text
                ),
                beforeResolve: { [weak self] in
                    guard let self else {
                        throw MCPError.invalidParams("Coordinator child-answer authority is unavailable.")
                    }
                    try validateChildInteractionAnswerAuthority(row: row)
                }
            )
            return .submitted
        } catch {
            return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    @MainActor
    func submitCoordinatorInteractionResponseToAgentMode(
        _ submission: CoordinatorModeViewModel.ChildInteractionResponseSubmission,
        coordinatorSessionID: UUID,
        interactionID: UUID
    ) async -> UserTurnSubmissionResult {
        guard sessions.values.contains(where: { session in
            session.activeAgentSessionID == coordinatorSessionID && session.isCoordinatorRuntime
        }) else {
            return .blocked(message: "This Coordinator mission is no longer available.")
        }
        do {
            _ = try await mcpResolvePendingInteraction(
                sessionID: coordinatorSessionID,
                interactionID: interactionID,
                payload: MCPInteractionResponsePayload(
                    text: submission.text,
                    skip: submission.skip,
                    explicitSkip: submission.skip,
                    decisionRaw: submission.text,
                    amendment: nil,
                    answersByQuestionID: [:],
                    askUserAnswersByQuestionID: submission.answersByQuestionID,
                    hasStructuredAnswerObjects: submission.hasStructuredAnswers,
                    elicitationActionRaw: submission.text
                )
            )
            return .submitted
        } catch {
            return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    @MainActor
    private func clearCoordinatorRuntimeDemoTarget(preferredSessionID: UUID?) {
        for (tabID, session) in sessions {
            let isPreferredLiveSession = preferredSessionID != nil && session.activeAgentSessionID == preferredSessionID
            guard session.isCoordinatorRuntimeDemo || isPreferredLiveSession else { continue }
            session.isCoordinatorRuntimeDemo = false
            renameCoordinatorRuntimeDemoTabForReset(tabID)
        }
    }

    @MainActor
    private func renameCoordinatorRuntimeDemoTabForReset(_ tabID: UUID) {
        guard coordinatorModeTabName(for: tabID) == Self.coordinatorRuntimeDemoSessionName else { return }
        let clearedName = "\(Self.coordinatorRuntimeDemoSessionName) (cleared)"
        var tab = workspaceManager?.composeTab(with: tabID)
        tab?.name = clearedName
        tab?.lastModified = Date()
        if let tab {
            workspaceManager?.updateComposeTab(tab)
            if let workspace = workspaceManager?.workspaces.first(where: { workspace in
                workspace.composeTabs.contains(where: { $0.id == tabID })
            }) {
                promptManager?.loadComposeTabsFromWorkspace(workspace)
            }
        } else {
            promptManager?.renameComposeTab(tabID, to: clearedName)
        }
    }

    #if DEBUG
        @MainActor
        func test_clearCoordinatorRuntimeDemoTarget(preferredSessionID: UUID?) {
            clearCoordinatorRuntimeDemoTarget(preferredSessionID: preferredSessionID)
        }

        @MainActor
        func test_resolveOrCreateCoordinatorRuntimeDemoTarget(
            preferredSessionID: UUID?,
            forceNewRuntime: Bool = false,
            coordinatorModelID: String? = nil
        ) async throws -> (tabID: UUID, sessionID: UUID) {
            try await resolveOrCreateCoordinatorRuntimeDemoTarget(
                preferredSessionID: preferredSessionID,
                forceNewRuntime: forceNewRuntime,
                coordinatorModelID: coordinatorModelID
            )
        }

        @MainActor
        func test_refreshCoordinatorModeForChildLifecycleIfVisible() -> Bool {
            refreshCoordinatorModeForChildLifecycleIfVisible()
        }
    #endif

    @MainActor
    private func resolveOrCreateCoordinatorRuntimeDemoTarget(
        preferredSessionID: UUID?,
        forceNewRuntime: Bool = false,
        coordinatorModelID: String? = nil
    ) async throws -> (tabID: UUID, sessionID: UUID) {
        if forceNewRuntime {
            return try await createCoordinatorRuntimeDemoTarget(coordinatorModelID: coordinatorModelID)
        }

        if let preferredSessionID,
           let match = sessions.first(where: { $0.value.activeAgentSessionID == preferredSessionID })
        {
            let session = match.value
            session.isCoordinatorRuntimeDemo = true
            try await ensureCoordinatorRuntimeDemoControl(tabID: match.key, sessionID: preferredSessionID)
            return (match.key, preferredSessionID)
        }

        if let preferredSessionID,
           ownerValidatedSessionIndex[preferredSessionID]?.isCoordinatorRuntime == true
        {
            let target = try await mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: preferredSessionID,
                createIfNeeded: true,
                sessionName: ownerValidatedSessionIndex[preferredSessionID]?.name ?? Self.coordinatorRuntimeDemoSessionName
            )
            guard let sessionID = target.sessionID else {
                throw MCPError.invalidParams("The Coordinator runtime tab could not be bound to the selected session.")
            }
            try await ensureCoordinatorRuntimeDemoControl(tabID: target.tabID, sessionID: sessionID)
            return (target.tabID, sessionID)
        }

        return try await createCoordinatorRuntimeDemoTarget(coordinatorModelID: coordinatorModelID)
    }

    @MainActor
    private func activateCoordinatorRuntimeSession(_ sessionID: UUID) async {
        do {
            let target = try await mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: sessionID,
                createIfNeeded: true,
                sessionName: ownerValidatedSessionIndex[sessionID]?.name ?? Self.coordinatorRuntimeDemoSessionName
            )
            guard let resolvedSessionID = target.sessionID else { return }
            try await ensureCoordinatorRuntimeDemoControl(tabID: target.tabID, sessionID: resolvedSessionID)
        } catch {
            #if DEBUG
                AgentModePerfDiagnostics.event(
                    "coordinator.runtime.activateFailed",
                    fields: ["sessionID": sessionID.uuidString, "error": String(describing: error)]
                )
            #endif
        }
    }

    @MainActor
    private func setCoordinatorRuntimePinned(
        _ isPinned: Bool,
        option: CoordinatorModeCoordinatorOption
    ) {
        guard let tabID = option.tabID else { return }
        promptManager?.setComposeTabPinned(isPinned, for: tabID)
    }

    @MainActor
    private func archiveCoordinatorRuntimeMission(
        _ option: CoordinatorModeCoordinatorOption
    ) async -> CoordinatorModeViewModel.CoordinatorArchiveMissionResult {
        let unpinned = option.isPinned
        if unpinned, let tabID = option.tabID {
            promptManager?.setComposeTabPinned(false, for: tabID)
        }
        if option.isPersistedOnly, !option.isLiveInCurrentWindow {
            if option.isSelected {
                visibleCoordinatorModeViewModel?.selectCoordinator(sessionID: nil, workspaceID: option.workspaceID)
            }
            return .accepted(alreadyArchived: true, unpinned: unpinned)
        }
        guard let tabID = option.tabID else {
            return .rejected("Coordinator Mission \(option.sessionID.uuidString) cannot be archived because no backing compose tab is available.")
        }

        var archivedIndexEntry = ownerValidatedSessionIndex[option.sessionID]
        archivedIndexEntry?.isCoordinatorRuntime = true
        archivedIndexEntry?.coordinatorMissionTemplate = option.missionTemplate
        archivedIndexEntry?.coordinatorMissionPlan = option.missionPlan
        let archivedRunStateRaw: String? = switch option.missionPlan?.status {
        case .completed:
            AgentSessionRunState.completed.rawValue
        case .stopped:
            AgentSessionRunState.cancelled.rawValue
        case .draft, .approved, .running, .blocked, .none:
            option.runState?.rawValue
        }
        if let runStateRaw = archivedRunStateRaw {
            archivedIndexEntry?.lastRunStateRaw = runStateRaw
        }

        await promptManager?.stashTab(tabID, allowReplacement: true)
        if let entry = archivedIndexEntry {
            applyLocalSessionIndexUpsert(entry)
        }
        if option.isSelected {
            visibleCoordinatorModeViewModel?.selectCoordinator(sessionID: nil, workspaceID: option.workspaceID)
        }
        visibleCoordinatorModeViewModel?.refresh()

        if let updated = visibleCoordinatorModeViewModel?.snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == option.sessionID }),
           updated.isPersistedOnly,
           !updated.isLiveInCurrentWindow,
           !updated.isPinned
        {
            return .accepted(alreadyArchived: false, unpinned: unpinned)
        }

        // Stashing can be refused by transient tab/activation state. Archival is
        // retention-only, so as a fallback detach the live tab binding while
        // restoring the preserved coordinator index record.
        _ = await finalizeDeletedAgentSessionReferences(
            sessionID: option.sessionID,
            workspaceID: option.workspaceID,
            knownTabIDs: [tabID],
            reason: "coordinator_archive"
        )
        if let entry = archivedIndexEntry {
            applyLocalSessionIndexUpsert(entry)
        }
        if option.isSelected {
            visibleCoordinatorModeViewModel?.selectCoordinator(sessionID: nil, workspaceID: option.workspaceID)
        }
        visibleCoordinatorModeViewModel?.refresh()

        if let updated = visibleCoordinatorModeViewModel?.snapshot.coordinatorRail.availableCoordinators.first(where: { $0.sessionID == option.sessionID }),
           updated.isPersistedOnly,
           !updated.isLiveInCurrentWindow,
           !updated.isPinned
        {
            return .accepted(alreadyArchived: false, unpinned: unpinned)
        }

        return .rejected("Coordinator Mission \(option.sessionID.uuidString) could not be archived because its compose tab could not be stashed. Open another session tab or stop interacting with the selected tab, then retry archive_mission.")
    }

    @MainActor
    private func createCoordinatorRuntimeDemoTarget(coordinatorModelID: String? = nil) async throws -> (tabID: UUID, sessionID: UUID) {
        let tabID = try await mcpCreateCoordinatorRuntimeTab(name: Self.coordinatorRuntimeDemoSessionName)
        let session = await ensureSessionReady(tabID: tabID)
        guard let sessionID = ensureSessionBoundToTab(session) else {
            throw MCPError.invalidParams("The Coordinator runtime tab could not be bound to an agent session.")
        }
        session.isCoordinatorRuntime = true
        try await ensureCoordinatorRuntimeDemoControl(tabID: tabID, sessionID: sessionID, coordinatorModelID: coordinatorModelID)
        return (tabID, sessionID)
    }

    @MainActor
    private func ensureCoordinatorRuntimeDemoControl(tabID: UUID, sessionID: UUID, coordinatorModelID: String? = nil) async throws {
        let session = await ensureSessionReady(tabID: tabID)
        session.isCoordinatorRuntime = true
        if session.mcpControlContext?.sessionID != sessionID ||
            session.mcpControlContext?.taskLabelKind != .coordinator
        {
            try await mcpActivateControlContext(
                forTabID: tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                taskLabelKind: .coordinator,
                startPending: false
            )
        }
        let modelSelection = try Self.resolvedCoordinatorRuntimeModelSelection(coordinatorModelID)
        let resolvedModel = AgentExternalMCPRunStarter.extractReasoningEffort(from: modelSelection.modelRaw)
        try await mcpConfigureSession(
            tabID: tabID,
            agentRaw: modelSelection.agentRaw,
            modelRaw: resolvedModel.model,
            reasoningEffortRaw: resolvedModel.effort
        )
    }

    @MainActor
    private static func resolvedCoordinatorRuntimeModelSelection(_ coordinatorModelID: String?) throws -> AgentMCPSelectionResolver.ResolvedSelection {
        #if DEBUG
            if let coordinatorModelID,
               AgentScriptedChildModelID.isScriptedSelector(coordinatorModelID)
            {
                throw MCPError.invalidParams("coordinator_model_id 'scripted' is only available for child sessions; Coordinator runtimes must use a real model target.")
            }
        #endif
        return try AgentMCPSelectionResolver.resolve(
            modelID: coordinatorModelID,
            defaultTaskLabel: .coordinator
        )
    }

    @MainActor
    func coordinatorModeSnapshotInput(
        sortMode: CoordinatorModeSortMode = .lastUpdated,
        selectedCoordinatorID: UUID? = nil
    ) -> CoordinatorModeSnapshotProjector.Input {
        let workspaceID = coordinatorModeActiveWorkspaceID
        let resolvableTabIDs = coordinatorModeResolvableTabIDs()
        let tabStateByID = coordinatorModeTabStateByID()
        let persistedSessions = ownerValidatedSessionIndex.values.map { entry in
            var persisted = CoordinatorModeSnapshotProjector.PersistedSession(
                entry: entry,
                updatedAt: ownerValidatedSessionListSortDates[entry.tabID]
                    ?? AgentSessionRestoreSupport.sidebarActivityDate(for: entry)
            )
            if let tab = tabStateByID[entry.tabID] {
                persisted.title = tab.name
                persisted.isPinned = tab.isPinned
            }
            return persisted
        }
        let liveSessions = sessions.values.compactMap { session -> CoordinatorModeSnapshotProjector.LiveSession? in
            guard let sessionID = session.activeAgentSessionID,
                  resolvableTabIDs.contains(session.tabID)
            else { return nil }
            let workflow = session.items.last(where: { $0.kind == .user })?.workflow
            let tab = tabStateByID[session.tabID]
            return CoordinatorModeSnapshotProjector.LiveSession(
                sessionID: sessionID,
                tabID: session.tabID,
                title: tab?.name ?? ownerValidatedSessionIndex[sessionID]?.name ?? "Agent Session",
                startedAt: session.lastUserMessageAt,
                updatedAt: session.lastUserMessageAt ?? session.lastActivityAt,
                runState: session.runState,
                agentKind: session.selectedAgent.rawValue,
                agentModel: session.selectedModelRaw,
                parentSessionID: session.parentSessionID,
                isMCPOriginated: session.isMCPOriginated,
                worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries,
                workflow: workflow.map(CoordinatorModeWorkflowDisplaySummary.init),
                isCoordinatorInternal: session.isCoordinatorInternalSession,
                isCoordinatorRuntime: session.isCoordinatorRuntime,
                isPinned: tab?.isPinned ?? false,
                coordinatorMissionTemplate: session.coordinatorFollowThroughState?.missionTemplate,
                coordinatorMissionPlan: session.coordinatorFollowThroughState?.missionPlan
            )
        }
        var mcpSnapshotsBySessionID: [UUID: AgentRunMCPSnapshot] = [:]
        for tabID in mcpControlledTabIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let session = sessions[tabID],
                  let snapshot = mcpSnapshot(for: session)
            else { continue }
            mcpSnapshotsBySessionID[snapshot.sessionID] = snapshot
        }

        return CoordinatorModeSnapshotProjector.Input(
            workspaceID: workspaceID,
            windowID: coordinatorModeWindowID,
            persistedSessions: persistedSessions,
            liveSessions: liveSessions,
            mcpSnapshotsBySessionID: mcpSnapshotsBySessionID,
            dashboard: coordinatorModeDashboard,
            coordinatorDetectionSessions: persistedSessions.map(CoordinatorModeSnapshotProjector.CoordinatorDetectionSession.init),
            selectedCoordinatorID: selectedCoordinatorID,
            sortMode: sortMode,
            resolvableTabIDs: resolvableTabIDs,
            demoCoordinatorSessionIDs: Set(sessions.values.compactMap { session in
                session.isCoordinatorRuntimeDemo ? session.activeAgentSessionID : nil
            }),
            coordinatorInternalSessionIDs: Set(sessions.values.compactMap { session in
                session.isCoordinatorInternalSession ? session.activeAgentSessionID : nil
            })
        )
    }

    private static let coordinatorRuntimeDemoSessionName = "Coordinator Runtime Demo"

    @MainActor
    private func coordinatorModeResolvableTabIDs() -> Set<UUID> {
        let composeTabs = promptManager?.currentComposeTabs ?? workspaceManager?.activeWorkspace?.composeTabs ?? []
        let stashedTabs = workspaceManager?.activeWorkspace?.stashedTabs.map(\.tab) ?? []
        return Set((composeTabs + stashedTabs).map(\.id))
    }

    @MainActor
    private func coordinatorModeTabStateByID() -> [UUID: ComposeTabState] {
        let composeTabs = promptManager?.currentComposeTabs ?? workspaceManager?.activeWorkspace?.composeTabs ?? []
        let stashedTabs = workspaceManager?.activeWorkspace?.stashedTabs.map(\.tab) ?? []
        return Dictionary((composeTabs + stashedTabs).map { ($0.id, $0) }, uniquingKeysWith: { active, _ in active })
    }

    @MainActor
    private func coordinatorModeTabName(for tabID: UUID) -> String? {
        promptManager?.currentComposeTabs.first(where: { $0.id == tabID })?.name
            ?? workspaceManager?.composeTabName(with: tabID)
    }

    #if DEBUG
        func test_flushCoordinatorPostApprovalContinuationPersistence(
            _ token: CoordinatorModeViewModel.PostApprovalContinuationPersistenceToken
        ) async throws {
            try await flushCoordinatorPostApprovalContinuationPersistence(token)
        }

        func test_validatePostApprovalContinuationEnqueueAuthority(
            _ continuation: CoordinatorPostApprovalContinuationRecord
        ) throws {
            try validatePostApprovalContinuationEnqueueAuthority(continuation)
        }

        func test_submitCoordinatorPostApprovalContinuationAtFinalEnqueue(
            _ continuation: CoordinatorPostApprovalContinuationRecord
        ) async -> UserTurnSubmissionResult {
            guard let match = sessions.first(where: { _, session in
                session.activeAgentSessionID == continuation.coordinatorSessionID && session.isCoordinatorRuntime
            }),
                let target = makeComposerSubmitTarget(tabID: match.key, session: match.value)
            else {
                return .blocked(message: "Post-approval continuation final enqueue target is unavailable.")
            }
            return await submitUserTurnCreatingSessionIfNeeded(
                text: continuation.directiveText,
                target: target,
                beforeSubmit: { [weak self] in
                    guard let self else {
                        throw MCPError.invalidParams("Coordinator continuation authority is unavailable.")
                    }
                    try validatePostApprovalContinuationAtFinalEnqueue(
                        continuation,
                        tabID: match.key,
                        expectedSession: match.value
                    )
                },
                createAndActivateSessionTab: { nil }
            )
        }

        func test_evaluateCoordinatorPostApprovalContinuation(coordinatorSessionID: UUID) async {
            coordinatorModeViewModel.refresh()
            await evaluateCoordinatorFollowThrough(
                coordinatorSessionID: coordinatorSessionID,
                snapshot: coordinatorModeViewModel.snapshot,
                trigger: CoordinatorAutoModeBoundaryClassifier.Trigger.lifecycle
            )
        }
    #endif
}

private extension CoordinatorModeRow {
    func withPendingInteraction(_ pendingInteraction: CoordinatorModePendingInteractionSummary) -> CoordinatorModeRow {
        CoordinatorModeRow(
            id: id,
            sessionID: sessionID,
            tabID: tabID,
            title: title,
            providerName: providerName,
            modelName: modelName,
            runState: runState,
            statusGroup: statusGroup,
            parentSessionID: parentSessionID,
            parentCoordinator: parentCoordinator,
            childSessionIDs: childSessionIDs,
            isMCPOriginated: isMCPOriginated,
            isPersistedOnly: isPersistedOnly,
            isCoordinator: isCoordinator,
            startedAt: startedAt,
            updatedAt: updatedAt,
            priority: priority,
            workstream: workstream,
            workstreamSummary: workstreamSummary,
            workflow: workflow,
            mergeAttention: mergeAttention,
            pendingInteraction: pendingInteraction,
            openAgentChatRoute: openAgentChatRoute,
            statusReport: statusReport,
            origin: origin
        )
    }
}

private extension CoordinatorMissionPlanEventKind {
    var isRevisionMarker: Bool {
        switch self {
        case .created, .revised:
            true
        case .approved, .revisionProposalFiled, .nodeStarted, .nodeCompleted, .nodeBlocked, .sessionBound, .gateCleared:
            false
        }
    }

    var isFoldedTranscriptProgress: Bool {
        switch self {
        case .nodeStarted, .nodeCompleted, .sessionBound:
            true
        case .created, .revised, .approved, .revisionProposalFiled, .nodeBlocked, .gateCleared:
            false
        }
    }
}
