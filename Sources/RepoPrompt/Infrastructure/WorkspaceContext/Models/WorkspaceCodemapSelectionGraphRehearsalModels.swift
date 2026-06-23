import Foundation

struct WorkspaceCodemapSelectionGraphRehearsalKey: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let schemaVersion: UInt32
    let policyVersion: UInt32

    init(
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        schemaVersion: UInt32 = CodeMapSelectionGraphContribution.currentSchemaVersion,
        policyVersion: UInt32 = CodeMapSelectionGraphContribution.currentPolicyVersion
    ) {
        rootEpoch = snapshot.rootEpoch
        catalogGeneration = snapshot.catalogGeneration
        repositoryAuthority = snapshot.repositoryAuthority
        contributionGeneration = snapshot.contributionGeneration
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
    }
}

struct WorkspaceCodemapSelectionGraphRehearsalSizeAccounting: Hashable {
    static let zero = Self(nodes: 0, postings: 0, edges: 0, bytes: 0)

    let nodes: UInt64
    let postings: UInt64
    let edges: UInt64
    let bytes: UInt64

    init(_ accounting: WorkspaceCodemapSelectionGraphSizeAccounting) {
        nodes = accounting.nodes
        postings = accounting.postings
        edges = accounting.edges
        bytes = accounting.bytes
    }

    init(nodes: UInt64, postings: UInt64, edges: UInt64, bytes: UInt64) {
        self.nodes = nodes
        self.postings = postings
        self.edges = edges
        self.bytes = bytes
    }
}

struct WorkspaceCodemapSelectionGraphRehearsalPublishedSummary: Hashable {
    let key: WorkspaceCodemapSelectionGraphRehearsalKey
    let nodeCount: UInt64
    let uniqueEdgeCount: UInt64
    let sizeAccounting: WorkspaceCodemapSelectionGraphRehearsalSizeAccounting
    let isEmpty: Bool
}

struct WorkspaceCodemapSelectionGraphRehearsalPolicy: Hashable {
    static let initial = Self(
        maximumActiveRebuildCount: 1,
        maximumReservedBindingCount: 100_000,
        maximumInputBindingCount: 100_000,
        maximumSelectedSourceCountPerQuery: 4096,
        maximumResolvedTargetCountPerQuery: 100_000,
        maximumReferenceFailureCountPerQuery: 100_000,
        graphSizePolicy: .initial
    )

    let maximumActiveRebuildCount: Int
    let maximumReservedBindingCount: Int
    let maximumInputBindingCount: Int
    let maximumSelectedSourceCountPerQuery: Int
    let maximumResolvedTargetCountPerQuery: Int
    let maximumReferenceFailureCountPerQuery: Int
    let graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy

    init(
        maximumActiveRebuildCount: Int,
        maximumReservedBindingCount: Int,
        maximumInputBindingCount: Int,
        maximumSelectedSourceCountPerQuery: Int,
        maximumResolvedTargetCountPerQuery: Int,
        maximumReferenceFailureCountPerQuery: Int,
        graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy
    ) {
        precondition(maximumActiveRebuildCount > 0)
        precondition(maximumReservedBindingCount > 0)
        precondition(maximumInputBindingCount > 0)
        precondition(maximumSelectedSourceCountPerQuery > 0)
        precondition(maximumResolvedTargetCountPerQuery > 0)
        precondition(maximumReferenceFailureCountPerQuery > 0)
        self.maximumActiveRebuildCount = maximumActiveRebuildCount
        self.maximumReservedBindingCount = maximumReservedBindingCount
        self.maximumInputBindingCount = maximumInputBindingCount
        self.maximumSelectedSourceCountPerQuery = maximumSelectedSourceCountPerQuery
        self.maximumResolvedTargetCountPerQuery = maximumResolvedTargetCountPerQuery
        self.maximumReferenceFailureCountPerQuery = maximumReferenceFailureCountPerQuery
        self.graphSizePolicy = graphSizePolicy
    }
}

enum WorkspaceCodemapSelectionGraphRehearsalExternalUnavailableReason: Hashable {
    case rootUnloaded
    case authorityRevoked
}

enum WorkspaceCodemapSelectionGraphRehearsalValidationReason: Hashable {
    case bindingNotResolved
    case terminalBinding
    case bindingRootEpochMismatch
    case catalogGenerationMismatch
    case repositoryAuthorityMismatch
    case duplicateFileID
    case duplicateRelativePath
    case inconsistentCompletionAuthority
    case contributionSchemaMismatch
    case contributionPolicyMismatch
}

enum WorkspaceCodemapSelectionGraphRehearsalBusyReason: Hashable {
    case actorActiveRebuildLimit
    case actorReservedBindingLimit
    case processAdmission(CodeMapSelectionGraphRehearsalAdmissionBusyReason)
}

enum WorkspaceCodemapSelectionGraphRehearsalRejectionReason: Hashable {
    case rootEpochMismatch
    case staleSnapshot(
        received: WorkspaceCodemapSelectionGraphContributionGeneration,
        current: WorkspaceCodemapSelectionGraphContributionGeneration
    )
    case equalGenerationAuthorityConflict
    case rootUnavailable(WorkspaceCodemapSelectionGraphRehearsalExternalUnavailableReason)
    case invalidSnapshot(WorkspaceCodemapSelectionGraphRehearsalValidationReason)
    case inputBindingLimit(attempted: Int, limit: Int)
    case graphSize(WorkspaceCodemapSelectionGraphSizeRejection)
    case modelStore(WorkspaceCodemapSelectionGraphContributionRejection)
    case edge(WorkspaceCodemapSelectionGraphEdgeRejection)
    case accountingOverflow
}

enum WorkspaceCodemapSelectionGraphRehearsalRebuildDisposition: Hashable {
    case published(WorkspaceCodemapSelectionGraphRehearsalPublishedSummary)
    case publishedEmpty(WorkspaceCodemapSelectionGraphRehearsalPublishedSummary)
    case busy(
        WorkspaceCodemapSelectionGraphRehearsalKey,
        WorkspaceCodemapSelectionGraphRehearsalBusyReason
    )
    case cancelled(WorkspaceCodemapSelectionGraphRehearsalKey)
    case rejected(
        WorkspaceCodemapSelectionGraphRehearsalKey?,
        WorkspaceCodemapSelectionGraphRehearsalRejectionReason
    )
    case superseded(WorkspaceCodemapSelectionGraphRehearsalKey)
}

struct WorkspaceCodemapSelectionGraphRehearsalQuerySource: Hashable {
    let fileID: UUID
    let requestGeneration: UInt64
}

struct WorkspaceCodemapSelectionGraphRehearsalQuery: Hashable {
    let key: WorkspaceCodemapSelectionGraphRehearsalKey
    let selectedSources: [WorkspaceCodemapSelectionGraphRehearsalQuerySource]
}

struct WorkspaceCodemapSelectionGraphRehearsalEndpoint: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let requestGeneration: UInt64
}

struct WorkspaceCodemapSelectionGraphRehearsalSourceCoverage: Hashable {
    let source: WorkspaceCodemapSelectionGraphRehearsalQuerySource
    let state: WorkspaceCodemapSelectionGraphSourceCoverageState
}

struct WorkspaceCodemapSelectionGraphRehearsalResolution: Hashable {
    let source: WorkspaceCodemapSelectionGraphRehearsalEndpoint
    let target: WorkspaceCodemapSelectionGraphRehearsalEndpoint
}

struct WorkspaceCodemapSelectionGraphRehearsalReferenceFailureRecord: Hashable {
    let source: WorkspaceCodemapSelectionGraphRehearsalEndpoint
    let referencedName: String
    let failure: WorkspaceCodemapSelectionGraphReferenceFailure
}

struct WorkspaceCodemapSelectionGraphRehearsalQueryResult: Hashable {
    let key: WorkspaceCodemapSelectionGraphRehearsalKey
    let selectedSources: [WorkspaceCodemapSelectionGraphRehearsalQuerySource]
    let targets: [WorkspaceCodemapSelectionGraphRehearsalEndpoint]
    let resolutions: [WorkspaceCodemapSelectionGraphRehearsalResolution]
    let sourceCoverage: [WorkspaceCodemapSelectionGraphRehearsalSourceCoverage]
    let definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage
    let referenceFailures: [WorkspaceCodemapSelectionGraphRehearsalReferenceFailureRecord]
    let publishedSummary: WorkspaceCodemapSelectionGraphRehearsalPublishedSummary
}

enum WorkspaceCodemapSelectionGraphRehearsalQueryUnavailableReason: Hashable {
    case notBuilt
    case rebuilding
    case staleCurrentness(currentKey: WorkspaceCodemapSelectionGraphRehearsalKey?)
    case actorAdmissionRejected(WorkspaceCodemapSelectionGraphRehearsalBusyReason)
    case processAdmissionRejected(CodeMapSelectionGraphRehearsalAdmissionBusyReason)
    case cancelled
    case budgetExceeded
    case invalidSnapshot
    case explicitRootUnavailable(WorkspaceCodemapSelectionGraphRehearsalExternalUnavailableReason)
    case invalidQuery
}

enum WorkspaceCodemapSelectionGraphRehearsalQueryDisposition: Hashable {
    case readyPartial(WorkspaceCodemapSelectionGraphRehearsalQueryResult)
    case unavailable(WorkspaceCodemapSelectionGraphRehearsalQueryUnavailableReason)
}

enum WorkspaceCodemapSelectionGraphRehearsalDiagnosticEventKind: Hashable {
    case buildStarted
    case beforePublication
}

struct WorkspaceCodemapSelectionGraphRehearsalDiagnosticEvent: Hashable {
    let operationID: UInt64
    let key: WorkspaceCodemapSelectionGraphRehearsalKey
    let kind: WorkspaceCodemapSelectionGraphRehearsalDiagnosticEventKind
}

struct WorkspaceCodemapSelectionGraphRehearsalDiagnostics {
    static let none = Self { _ in }

    let handle: @Sendable (WorkspaceCodemapSelectionGraphRehearsalDiagnosticEvent) -> Void
}

struct WorkspaceCodemapSelectionGraphRehearsalAccounting: Equatable {
    let activeRebuildCount: Int
    let reservedInputBindingCount: Int
    let publishedSummary: WorkspaceCodemapSelectionGraphRehearsalPublishedSummary?
    let currentObservedKey: WorkspaceCodemapSelectionGraphRehearsalKey?
    let currentUnavailableReason: WorkspaceCodemapSelectionGraphRehearsalQueryUnavailableReason?
    let publishedCount: UInt64
    let emptyPublishedCount: UInt64
    let actorBusyCount: UInt64
    let processBusyCount: UInt64
    let cancelledCount: UInt64
    let budgetRejectedCount: UInt64
    let invalidSnapshotCount: UInt64
    let supersededPublicationCount: UInt64
}
