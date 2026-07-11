import CryptoKit
import Foundation

enum CoordinatorMissionRevisionProposalRepresentation: String, Codable, Equatable {
    case summaryOnly = "summary_only"
}

struct CoordinatorMissionRevisionProposalActor: Codable, Equatable {
    let coordinatorSessionID: UUID
    let runtimeSessionID: UUID
    let modelID: String?
    let role: String

    init(
        coordinatorSessionID: UUID,
        runtimeSessionID: UUID,
        modelID: String? = nil,
        role: String = "director"
    ) {
        self.coordinatorSessionID = coordinatorSessionID
        self.runtimeSessionID = runtimeSessionID
        self.modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.role = role.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "director"
    }
}

struct CoordinatorMissionCanonicalRequestedChange: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let value: String

    init(rawValue: String, version: Int = Self.currentVersion) {
        self.version = version
        value = Self.canonicalize(rawValue)
    }

    private static func canonicalize(_ rawValue: String) -> String {
        let normalized = rawValue.precomposedStringWithCanonicalMapping
        var result = ""
        var pendingWhitespace = false
        for character in normalized {
            if character.isWhitespace {
                pendingWhitespace = !result.isEmpty
            } else {
                if pendingWhitespace {
                    result.append(" ")
                    pendingWhitespace = false
                }
                result.append(character)
            }
        }
        return result
    }
}

struct CoordinatorMissionRevisionProposalRequest: Equatable {
    let expectedBasePlanID: UUID
    let expectedBaseContractFingerprint: String
    let summary: String
    let rationale: String?
    let affectedFields: [String]
    let remedy: String
    let supportingEvidenceIDs: [UUID]
    let requestedChange: String
    let actor: CoordinatorMissionRevisionProposalActor

    init(
        expectedBasePlanID: UUID,
        expectedBaseContractFingerprint: String,
        summary: String,
        rationale: String? = nil,
        affectedFields: [String],
        remedy: String,
        supportingEvidenceIDs: [UUID] = [],
        requestedChange: String,
        actor: CoordinatorMissionRevisionProposalActor
    ) {
        self.expectedBasePlanID = expectedBasePlanID
        self.expectedBaseContractFingerprint = expectedBaseContractFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rationale = rationale?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.affectedFields = affectedFields
        self.remedy = remedy
        self.supportingEvidenceIDs = supportingEvidenceIDs
        self.requestedChange = requestedChange
        self.actor = actor
    }
}

struct CoordinatorMissionRevisionProposal: Codable, Equatable, Identifiable {
    static let canonicalRequestIdentityVersion = 1

    let id: UUID
    let canonicalRequestIdentity: String
    let canonicalRequestIdentityVersion: Int
    let basePlanID: UUID
    let baseContractSnapshot: CoordinatorMissionMaterialContractSnapshot
    let baseContractFingerprint: String
    let representation: CoordinatorMissionRevisionProposalRepresentation
    let summary: String
    let rationale: String?
    let affectedFields: [String]
    let remedy: String
    let supportingEvidenceIDs: [UUID]
    let requestedChange: CoordinatorMissionCanonicalRequestedChange
    let actor: CoordinatorMissionRevisionProposalActor
    let filedAt: Date
}

enum CoordinatorMissionRevisionProposalResolutionOutcome: String, Codable, Equatable {
    case acceptedForConcreteRevision = "accepted_for_concrete_revision"
    case rejected
    case invalidatedContractChanged = "invalidated_contract_changed"
    case invalidatedMissionTerminal = "invalidated_mission_terminal"
    case stopped
}

enum CoordinatorMissionRevisionProposalResolutionAction: String, Codable, Equatable {
    case revisePlan = "revise_plan"
    case keepCurrentPlan = "keep_current_plan"

    var outcome: CoordinatorMissionRevisionProposalResolutionOutcome {
        switch self {
        case .revisePlan: .acceptedForConcreteRevision
        case .keepCurrentPlan: .rejected
        }
    }
}

struct CoordinatorMissionRevisionProposalTrustedResolutionRequest: Equatable {
    let coordinatorSessionID: UUID
    let action: CoordinatorMissionRevisionProposalResolutionAction
    let proposalID: UUID
    let expectedContractFingerprint: String
    let expectedCheckpointInstanceID: String

    init(
        coordinatorSessionID: UUID,
        action: CoordinatorMissionRevisionProposalResolutionAction,
        proposalID: UUID,
        expectedContractFingerprint: String,
        expectedCheckpointInstanceID: String
    ) {
        self.coordinatorSessionID = coordinatorSessionID
        self.action = action
        self.proposalID = proposalID
        self.expectedContractFingerprint = expectedContractFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.expectedCheckpointInstanceID = expectedCheckpointInstanceID
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CoordinatorMissionRevisionProposalDurabilityHold: Codable, Equatable {
    let transactionID: UUID
    let proposalID: UUID
    let outcome: CoordinatorMissionRevisionProposalResolutionOutcome
    let installedAt: Date
}

enum CoordinatorMissionRevisionProposalCheckpoint {
    static let checkpointID = "revision-proposal"

    static func instanceID(
        coordinatorSessionID: UUID,
        proposal: CoordinatorMissionRevisionProposal
    ) -> String {
        [
            "coordinator",
            coordinatorSessionID.uuidString,
            "revision-proposal",
            proposal.id.uuidString,
            "contract-\(proposal.baseContractFingerprint)"
        ].joined(separator: ":")
    }

    static func userDecisionID(
        proposalID: UUID,
        outcome: CoordinatorMissionRevisionProposalResolutionOutcome
    ) -> UUID {
        CoordinatorMissionStableIdentity.uuid(
            namespace: "coordinator-mission-revision-proposal-user-decision",
            parts: [proposalID.uuidString, outcome.rawValue]
        )
    }
}

struct CoordinatorMissionRevisionProposalResolution: Codable, Equatable, Identifiable {
    let id: UUID
    let proposalID: UUID
    let outcome: CoordinatorMissionRevisionProposalResolutionOutcome
    let userDecisionID: UUID?
    let checkpointID: String?
    let checkpointInstanceID: String?
    let resultingPlanID: UUID
    let resultingContractFingerprint: String
    let resolvedAt: Date
}

struct CoordinatorMissionRevisionProposalResolutionRequest: Equatable {
    let proposalID: UUID
    let outcome: CoordinatorMissionRevisionProposalResolutionOutcome
    let userDecisionID: UUID?
    let checkpointID: String?
    let checkpointInstanceID: String?

    init(
        proposalID: UUID,
        outcome: CoordinatorMissionRevisionProposalResolutionOutcome,
        userDecisionID: UUID? = nil,
        checkpointID: String? = nil,
        checkpointInstanceID: String? = nil
    ) {
        self.proposalID = proposalID
        self.outcome = outcome
        self.userDecisionID = userDecisionID
        self.checkpointID = checkpointID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.checkpointInstanceID = checkpointInstanceID?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

enum CoordinatorMissionRevisionProposalAppendDisposition: Equatable {
    case appended
    case existingPendingRetry
}

struct CoordinatorMissionRevisionProposalAppendResult: Equatable {
    let proposalID: UUID
    let disposition: CoordinatorMissionRevisionProposalAppendDisposition
}

enum CoordinatorMissionRevisionProposalResolutionDisposition: Equatable {
    case appended
    case existingResolutionRetry
}

struct CoordinatorMissionRevisionProposalResolutionResult: Equatable {
    let resolutionID: UUID
    let disposition: CoordinatorMissionRevisionProposalResolutionDisposition
}

enum CoordinatorMissionRevisionProposalLedgerError: Error, Equatable, LocalizedError {
    case missionPlanMissing
    case missionTerminal
    case staleBasePlan
    case staleBaseContract
    case staleCheckpoint
    case durabilityHoldActive
    case invalidRequest(String)
    case differentProposalPending(UUID)
    case proposalNotFound(UUID)
    case conflictingResolution(UUID)

    var errorDescription: String? {
        switch self {
        case .missionPlanMissing:
            "Mission Plan is missing."
        case .missionTerminal:
            "Terminal Missions cannot mutate revision proposal state."
        case .staleBasePlan:
            "The revision proposal targets a stale Mission Plan."
        case .staleBaseContract:
            "The revision proposal targets a stale material contract."
        case .staleCheckpoint:
            "The revision proposal checkpoint is stale."
        case .durabilityHoldActive:
            "A revision proposal resolution is awaiting durable persistence."
        case let .invalidRequest(reason):
            "Invalid revision proposal: \(reason)"
        case let .differentProposalPending(proposalID):
            "A different revision proposal is already pending: \(proposalID.uuidString)."
        case let .proposalNotFound(proposalID):
            "Revision proposal not found: \(proposalID.uuidString)."
        case let .conflictingResolution(proposalID):
            "Revision proposal already has a conflicting resolution: \(proposalID.uuidString)."
        }
    }
}

enum CoordinatorMissionRevisionProposalIdentity {
    static func canonicalRequestIdentity(
        baseContractFingerprint: String,
        affectedFields: [String],
        remedy: String,
        supportingEvidenceIDs: [UUID],
        requestedChange: CoordinatorMissionCanonicalRequestedChange,
        version: Int = CoordinatorMissionRevisionProposal.canonicalRequestIdentityVersion
    ) throws -> String {
        let payload = CanonicalRequestIdentityPayload(
            version: version,
            baseContractFingerprint: baseContractFingerprint,
            affectedFields: canonicalAffectedFields(affectedFields),
            remedy: canonicalRemedy(remedy),
            supportingEvidenceIDs: canonicalEvidenceIDs(supportingEvidenceIDs),
            requestedChange: requestedChange
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try SHA256.hash(data: encoder.encode(payload))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func resolutionID(
        proposalID: UUID,
        outcome: CoordinatorMissionRevisionProposalResolutionOutcome,
        userDecisionID: UUID?,
        checkpointID: String?,
        checkpointInstanceID: String?
    ) -> UUID {
        CoordinatorMissionStableIdentity.uuid(
            namespace: "coordinator-mission-revision-proposal-resolution",
            parts: [
                proposalID.uuidString,
                outcome.rawValue,
                userDecisionID?.uuidString ?? "",
                checkpointID ?? "",
                checkpointInstanceID ?? ""
            ]
        )
    }

    private struct CanonicalRequestIdentityPayload: Encodable {
        let version: Int
        let baseContractFingerprint: String
        let affectedFields: [String]
        let remedy: String
        let supportingEvidenceIDs: [UUID]
        let requestedChange: CoordinatorMissionCanonicalRequestedChange
    }

    static func canonicalAffectedFields(_ values: [String]) -> [String] {
        canonicalStrings(values)
    }

    static func canonicalRemedy(_ value: String) -> String {
        canonicalString(value)
    }

    static func canonicalEvidenceIDs(_ values: [UUID]) -> [UUID] {
        Array(Set(values)).sorted { $0.uuidString < $1.uuidString }
    }

    private static func canonicalStrings(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { value in
            canonicalString(value).nilIfEmpty
        })).sorted()
    }

    private static func canonicalString(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CoordinatorMissionRevisionProposalPause {
    static let heldReason = "held pending revision proposal"
}

extension CoordinatorMissionPlan {
    var hasRevisionProposalDurabilityHold: Bool {
        revisionProposalDurabilityHold != nil
    }

    var holdsChildInteractionsForRevisionProposal: Bool {
        if pendingRevisionProposal != nil || hasRevisionProposalDurabilityHold {
            return true
        }
        return approvalState != .approved
            && revisionProposalResolutions.last?.outcome == .acceptedForConcreteRevision
    }

    var acceptedRevisionDraftingResolution: CoordinatorMissionRevisionProposalResolution? {
        guard !status.isTerminal,
              approvalState == .revisionRequested,
              pendingRevisionProposal == nil,
              !hasRevisionProposalDurabilityHold,
              let resolution = revisionProposalResolutions.last,
              resolution.outcome == .acceptedForConcreteRevision,
              revisionProposals.contains(where: { $0.id == resolution.proposalID })
        else {
            return nil
        }
        return resolution
    }

    var pendingRevisionProposal: CoordinatorMissionRevisionProposal? {
        revisionProposals.first { proposal in
            !revisionProposalResolutions.contains { $0.proposalID == proposal.id }
        }
    }

    func revisionProposalResolution(
        for proposalID: UUID
    ) -> CoordinatorMissionRevisionProposalResolution? {
        revisionProposalResolutions.first { $0.proposalID == proposalID }
    }

    func makeRevisionProposalResolution(
        _ request: CoordinatorMissionRevisionProposalResolutionRequest,
        resultingContractFingerprint: String,
        resolvedAt: Date
    ) -> CoordinatorMissionRevisionProposalResolution {
        CoordinatorMissionRevisionProposalResolution(
            id: CoordinatorMissionRevisionProposalIdentity.resolutionID(
                proposalID: request.proposalID,
                outcome: request.outcome,
                userDecisionID: request.userDecisionID,
                checkpointID: request.checkpointID,
                checkpointInstanceID: request.checkpointInstanceID
            ),
            proposalID: request.proposalID,
            outcome: request.outcome,
            userDecisionID: request.userDecisionID,
            checkpointID: request.checkpointID,
            checkpointInstanceID: request.checkpointInstanceID,
            resultingPlanID: id,
            resultingContractFingerprint: resultingContractFingerprint,
            resolvedAt: resolvedAt
        )
    }

    mutating func resolvePendingRevisionProposalForTerminal(
        outcome: CoordinatorMissionRevisionProposalResolutionOutcome,
        resolvedAt: Date
    ) {
        guard let pendingRevisionProposal else { return }
        let request = CoordinatorMissionRevisionProposalResolutionRequest(
            proposalID: pendingRevisionProposal.id,
            outcome: outcome
        )
        revisionProposalResolutions.append(makeRevisionProposalResolution(
            request,
            resultingContractFingerprint: pendingRevisionProposal.baseContractFingerprint,
            resolvedAt: resolvedAt
        ))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
