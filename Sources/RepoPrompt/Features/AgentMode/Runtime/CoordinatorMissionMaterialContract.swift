import CryptoKit
import Foundation

/// Versioned, canonical representation of the user-ratified portion of a Coordinator Mission Plan.
///
/// Structural equality is the authority/CAS check. The SHA-256 fingerprint is a compact diagnostic
/// identity only and must not replace structural comparison.
struct CoordinatorMissionMaterialContractSnapshot: Codable, Equatable {
    static let currentVersion = 1

    struct KeyedAutonomy: Codable, Equatable {
        let key: String
        let mode: CoordinatorMissionAutonomyMode
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    private static func normalized(_ value: String?) -> String? {
        value.map(normalized)
    }

    private static func canonicalStringSet(_ values: [String]) -> [String] {
        Array(Set(values.map(normalized))).sorted()
    }

    private static func canonicalAutonomy(
        _ autonomy: [String: CoordinatorMissionAutonomyMode]
    ) -> [KeyedAutonomy] {
        canonicalAutonomy(autonomy.map { KeyedAutonomy(key: $0.key, mode: $0.value) })
    }

    private static func canonicalAutonomy(_ autonomy: [KeyedAutonomy]) -> [KeyedAutonomy] {
        let grouped = groupedAutonomy(autonomy)
        return grouped.keys.sorted().compactMap { key in
            guard let mode = grouped[key]?
                .map(\.mode)
                .min(by: { $0.rawValue < $1.rawValue })
            else { return nil }
            return KeyedAutonomy(key: key, mode: mode)
        }
    }

    private static func decodedCanonicalAutonomy(_ autonomy: [KeyedAutonomy]) throws -> [KeyedAutonomy] {
        let grouped = groupedAutonomy(autonomy)
        for key in grouped.keys.sorted() {
            let modes = Set(grouped[key, default: []].map(\.mode.rawValue))
            guard modes.count <= 1 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Conflicting autonomy modes for NFC-normalized key \(key)."
                ))
            }
        }
        return canonicalAutonomy(autonomy)
    }

    private static func groupedAutonomy(
        _ autonomy: [KeyedAutonomy]
    ) -> [String: [(key: String, mode: CoordinatorMissionAutonomyMode)]] {
        Dictionary(grouping: autonomy.map { entry in
            (key: normalized(entry.key), mode: entry.mode)
        }, by: { $0.key })
    }

    struct Shape: Codable, Equatable {
        let id: String
        let displayName: String
        let reason: String?
        let namedClose: String?

        init(_ shape: CoordinatorMissionShapeSummary) {
            id = CoordinatorMissionMaterialContractSnapshot.normalized(shape.id)
            displayName = CoordinatorMissionMaterialContractSnapshot.normalized(shape.displayName)
            reason = CoordinatorMissionMaterialContractSnapshot.normalized(shape.reason)
            namedClose = CoordinatorMissionMaterialContractSnapshot.normalized(shape.namedClose)
        }

        fileprivate init(canonicalizing shape: Self) {
            id = CoordinatorMissionMaterialContractSnapshot.normalized(shape.id)
            displayName = CoordinatorMissionMaterialContractSnapshot.normalized(shape.displayName)
            reason = CoordinatorMissionMaterialContractSnapshot.normalized(shape.reason)
            namedClose = CoordinatorMissionMaterialContractSnapshot.normalized(shape.namedClose)
        }
    }

    struct Policy: Codable, Equatable {
        let id: String
        let name: String
        let defaultPace: CoordinatorMissionPolicyPace
        let autonomy: [KeyedAutonomy]
        let maxConcurrent: Int
        let definitionOfDone: String?
        let standingGuidance: String?
        let pinnedSkillIDs: [String]
        let pinnedContextIDs: [String]

        init(_ policy: CoordinatorMissionPolicySnapshot) {
            id = CoordinatorMissionMaterialContractSnapshot.normalized(policy.id)
            name = CoordinatorMissionMaterialContractSnapshot.normalized(policy.name)
            defaultPace = policy.defaultPace
            autonomy = CoordinatorMissionMaterialContractSnapshot.canonicalAutonomy(policy.autonomy)
            maxConcurrent = policy.maxConcurrent
            definitionOfDone = CoordinatorMissionMaterialContractSnapshot.normalized(policy.definitionOfDone)
            standingGuidance = CoordinatorMissionMaterialContractSnapshot.normalized(policy.standingGuidance)
            pinnedSkillIDs = CoordinatorMissionMaterialContractSnapshot.canonicalStringSet(policy.pinnedSkillIDs)
            pinnedContextIDs = CoordinatorMissionMaterialContractSnapshot.canonicalStringSet(policy.pinnedContextIDs)
        }

        fileprivate init(canonicalizing policy: Self) throws {
            id = CoordinatorMissionMaterialContractSnapshot.normalized(policy.id)
            name = CoordinatorMissionMaterialContractSnapshot.normalized(policy.name)
            defaultPace = policy.defaultPace
            autonomy = try CoordinatorMissionMaterialContractSnapshot.decodedCanonicalAutonomy(policy.autonomy)
            maxConcurrent = policy.maxConcurrent
            definitionOfDone = CoordinatorMissionMaterialContractSnapshot.normalized(policy.definitionOfDone)
            standingGuidance = CoordinatorMissionMaterialContractSnapshot.normalized(policy.standingGuidance)
            pinnedSkillIDs = CoordinatorMissionMaterialContractSnapshot.canonicalStringSet(policy.pinnedSkillIDs)
            pinnedContextIDs = CoordinatorMissionMaterialContractSnapshot.canonicalStringSet(policy.pinnedContextIDs)
        }
    }

    struct WorktreeStrategy: Codable, Equatable {
        let mode: CoordinatorMissionWorktreeMode
        let baseRef: String?
        let baseReason: String?
        let reason: String?

        init(_ strategy: CoordinatorMissionWorktreeStrategy) {
            mode = strategy.mode
            baseRef = CoordinatorMissionMaterialContractSnapshot.normalized(strategy.baseRef)
            baseReason = CoordinatorMissionMaterialContractSnapshot.normalized(strategy.baseReason)
            reason = CoordinatorMissionMaterialContractSnapshot.normalized(strategy.reason)
        }

        fileprivate init(canonicalizing strategy: Self) {
            mode = strategy.mode
            baseRef = CoordinatorMissionMaterialContractSnapshot.normalized(strategy.baseRef)
            baseReason = CoordinatorMissionMaterialContractSnapshot.normalized(strategy.baseReason)
            reason = CoordinatorMissionMaterialContractSnapshot.normalized(strategy.reason)
        }
    }

    struct Workstream: Codable, Equatable {
        let id: UUID
        let title: String
        let purpose: String
        let role: String?
        let defaultPolicy: CoordinatorMissionExecutionPolicy
        let worktreeStrategy: WorktreeStrategy

        init(_ workstream: CoordinatorMissionWorkstreamSummary) {
            id = workstream.id
            title = CoordinatorMissionMaterialContractSnapshot.normalized(workstream.title)
            purpose = CoordinatorMissionMaterialContractSnapshot.normalized(workstream.purpose)
            role = CoordinatorMissionMaterialContractSnapshot.normalized(workstream.role)
            defaultPolicy = workstream.defaultPolicy
            worktreeStrategy = WorktreeStrategy(workstream.worktreeStrategy)
        }

        fileprivate init(canonicalizing workstream: Self) {
            id = workstream.id
            title = CoordinatorMissionMaterialContractSnapshot.normalized(workstream.title)
            purpose = CoordinatorMissionMaterialContractSnapshot.normalized(workstream.purpose)
            role = CoordinatorMissionMaterialContractSnapshot.normalized(workstream.role)
            defaultPolicy = workstream.defaultPolicy
            worktreeStrategy = WorktreeStrategy(canonicalizing: workstream.worktreeStrategy)
        }
    }

    struct WorkflowHint: Codable, Equatable {
        let id: String?
        let name: String
        let iconName: String?
        let accentColorHex: String?

        init(_ workflowHint: CoordinatorMissionPlanNodeWorkflowHint) {
            id = CoordinatorMissionMaterialContractSnapshot.normalized(workflowHint.id)
            name = CoordinatorMissionMaterialContractSnapshot.normalized(workflowHint.name)
            iconName = CoordinatorMissionMaterialContractSnapshot.normalized(workflowHint.iconName)
            accentColorHex = CoordinatorMissionMaterialContractSnapshot.normalized(workflowHint.accentColorHex)
        }

        fileprivate init(canonicalizing workflowHint: Self) {
            id = CoordinatorMissionMaterialContractSnapshot.normalized(workflowHint.id)
            name = CoordinatorMissionMaterialContractSnapshot.normalized(workflowHint.name)
            iconName = CoordinatorMissionMaterialContractSnapshot.normalized(workflowHint.iconName)
            accentColorHex = CoordinatorMissionMaterialContractSnapshot.normalized(workflowHint.accentColorHex)
        }
    }

    struct Node: Codable, Equatable {
        let id: UUID
        let title: String
        let detail: String?
        let workflowHint: WorkflowHint?
        let doneCriteria: String?
        let workstreamID: UUID
        let dependsOn: [UUID]
        let role: String?
        let executionPolicy: CoordinatorMissionExecutionPolicy

        init(_ node: CoordinatorMissionPlanNode) {
            id = node.id
            title = CoordinatorMissionMaterialContractSnapshot.normalized(node.title)
            detail = CoordinatorMissionMaterialContractSnapshot.normalized(node.detail)
            workflowHint = node.workflowHint.map(WorkflowHint.init)
            doneCriteria = CoordinatorMissionMaterialContractSnapshot.normalized(node.doneCriteria)
            workstreamID = node.workstreamID
            dependsOn = Array(Set(node.dependsOn)).sorted { $0.uuidString < $1.uuidString }
            role = CoordinatorMissionMaterialContractSnapshot.normalized(node.role)
            executionPolicy = node.executionPolicy
        }

        fileprivate init(canonicalizing node: Self) {
            id = node.id
            title = CoordinatorMissionMaterialContractSnapshot.normalized(node.title)
            detail = CoordinatorMissionMaterialContractSnapshot.normalized(node.detail)
            workflowHint = node.workflowHint.map { WorkflowHint(canonicalizing: $0) }
            doneCriteria = CoordinatorMissionMaterialContractSnapshot.normalized(node.doneCriteria)
            workstreamID = node.workstreamID
            dependsOn = Array(Set(node.dependsOn)).sorted { $0.uuidString < $1.uuidString }
            role = CoordinatorMissionMaterialContractSnapshot.normalized(node.role)
            executionPolicy = node.executionPolicy
        }
    }

    let version: Int
    let missionKey: String?
    let objective: String?
    let predecessorMissionID: UUID?
    let predecessorTitle: String?
    let predecessorSummary: String?
    let shape: Shape?
    let policy: Policy?
    let autonomy: [KeyedAutonomy]
    let workstreams: [Workstream]
    let nodes: [Node]

    init(plan: CoordinatorMissionPlan, version: Int = Self.currentVersion) {
        self.version = version
        missionKey = Self.normalized(plan.missionKey)
        objective = Self.normalized(plan.objective)
        predecessorMissionID = plan.predecessorMissionID
        predecessorTitle = Self.normalized(plan.predecessorTitle)
        predecessorSummary = Self.normalized(plan.predecessorSummary)
        shape = plan.shapeSummary.map(Shape.init)
        policy = plan.policySnapshot.map(Policy.init)
        autonomy = Self.canonicalAutonomy(plan.autonomy)
        workstreams = plan.workstreams
            .map(Workstream.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        nodes = plan.nodes
            .map(Node.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case missionKey
        case objective
        case predecessorMissionID
        case predecessorTitle
        case predecessorSummary
        case shape
        case policy
        case autonomy
        case workstreams
        case nodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        missionKey = try Self.normalized(container.decodeIfPresent(String.self, forKey: .missionKey))
        objective = try Self.normalized(container.decodeIfPresent(String.self, forKey: .objective))
        predecessorMissionID = try container.decodeIfPresent(UUID.self, forKey: .predecessorMissionID)
        predecessorTitle = try Self.normalized(container.decodeIfPresent(String.self, forKey: .predecessorTitle))
        predecessorSummary = try Self.normalized(container.decodeIfPresent(String.self, forKey: .predecessorSummary))
        shape = try container.decodeIfPresent(Shape.self, forKey: .shape).map { Shape(canonicalizing: $0) }
        policy = try container.decodeIfPresent(Policy.self, forKey: .policy).map { try Policy(canonicalizing: $0) }
        autonomy = try Self.decodedCanonicalAutonomy(container.decode([KeyedAutonomy].self, forKey: .autonomy))
        workstreams = try container.decode([Workstream].self, forKey: .workstreams)
            .map { Workstream(canonicalizing: $0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        nodes = try container.decode([Node].self, forKey: .nodes)
            .map { Node(canonicalizing: $0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func sha256Fingerprint() throws -> String {
        try SHA256.hash(data: canonicalData())
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Authoritative structural comparison of two canonical material contracts.
/// Canonical before/after payloads are retained for future exact-ratification.
struct CoordinatorMissionMaterialContractDelta: Equatable {
    enum Change: String, Equatable, CaseIterable {
        case added
        case removed
        case changed
        case unchanged
    }

    enum PromiseClassification: String, Equatable {
        case withinStatedAffectedAreas
        case outsideStatedAffectedAreas
        case unchanged
    }

    struct Field: Equatable {
        let path: String
        let affectedArea: String
        let change: Change
        let promiseClassification: PromiseClassification
        let beforeCanonicalValue: Data?
        let afterCanonicalValue: Data?
    }

    let fields: [Field]

    var materialChanges: [Field] {
        fields.filter { $0.change != .unchanged }
    }

    var unexpectedChanges: [Field] {
        materialChanges.filter { $0.promiseClassification == .outsideStatedAffectedAreas }
    }

    var requestedChanges: [Field] {
        materialChanges.filter { $0.promiseClassification == .withinStatedAffectedAreas }
    }

    var unchangedFields: [Field] {
        fields.filter { $0.change == .unchanged }
    }
}

/// Produces a deterministic structural delta over canonical snapshots.
func materialContractDelta(
    from before: CoordinatorMissionMaterialContractSnapshot,
    to after: CoordinatorMissionMaterialContractSnapshot,
    proposalAffectedFields: [String]
) -> CoordinatorMissionMaterialContractDelta {
    typealias Delta = CoordinatorMissionMaterialContractDelta
    struct Candidate {
        let path: String
        let area: String
        let before: Data?
        let after: Data?
    }

    let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    func encoded(_ value: (some Encodable)?) -> Data? {
        guard let value else { return nil }
        return try? encoder.encode(value)
    }
    func scalar<T: Encodable>(_ path: String, _ area: String, _ lhs: T?, _ rhs: T?) -> Candidate {
        Candidate(path: path, area: area, before: encoded(lhs), after: encoded(rhs))
    }
    func normalizedArea(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    var candidates: [Candidate] = [
        scalar("mission_key", "mission_key", before.missionKey, after.missionKey),
        scalar("objective", "objective", before.objective, after.objective),
        scalar("predecessor.id", "predecessor", before.predecessorMissionID, after.predecessorMissionID),
        scalar("predecessor.title", "predecessor", before.predecessorTitle, after.predecessorTitle),
        scalar("predecessor.summary", "predecessor", before.predecessorSummary, after.predecessorSummary),
        scalar("shape", "shape", before.shape, after.shape),
        scalar("policy", "policy", before.policy, after.policy),
        scalar("autonomy", "autonomy", before.autonomy, after.autonomy)
    ]

    let beforeWorkstreams = Dictionary(uniqueKeysWithValues: before.workstreams.map { ($0.id, $0) })
    let afterWorkstreams = Dictionary(uniqueKeysWithValues: after.workstreams.map { ($0.id, $0) })
    for id in Set(beforeWorkstreams.keys).union(afterWorkstreams.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
        let lhs = beforeWorkstreams[id]
        let rhs = afterWorkstreams[id]
        let prefix = "workstreams.\(id.uuidString.lowercased())"
        guard let lhs, let rhs else {
            candidates.append(scalar(prefix, "workstreams", lhs, rhs))
            continue
        }
        candidates.append(contentsOf: [
            scalar("\(prefix).title", "workstreams", lhs.title, rhs.title),
            scalar("\(prefix).purpose", "workstreams", lhs.purpose, rhs.purpose),
            scalar("\(prefix).role", "workstreams", lhs.role, rhs.role),
            scalar("\(prefix).default_policy", "workstreams", lhs.defaultPolicy, rhs.defaultPolicy),
            scalar(
                "\(prefix).planned_worktree_strategy",
                "workstreams",
                lhs.worktreeStrategy,
                rhs.worktreeStrategy
            )
        ])
    }

    let beforeNodes = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
    let afterNodes = Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.id, $0) })
    for id in Set(beforeNodes.keys).union(afterNodes.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
        let lhs = beforeNodes[id]
        let rhs = afterNodes[id]
        let prefix = "nodes.\(id.uuidString.lowercased())"
        guard let lhs, let rhs else {
            candidates.append(scalar(prefix, "nodes", lhs, rhs))
            continue
        }
        candidates.append(contentsOf: [
            scalar("\(prefix).title", "nodes", lhs.title, rhs.title),
            scalar("\(prefix).detail", "nodes", lhs.detail, rhs.detail),
            scalar("\(prefix).workflow", "nodes", lhs.workflowHint, rhs.workflowHint),
            scalar("\(prefix).done_criteria", "nodes", lhs.doneCriteria, rhs.doneCriteria),
            scalar("\(prefix).workstream_id", "nodes", lhs.workstreamID, rhs.workstreamID),
            scalar("\(prefix).depends_on", "nodes", lhs.dependsOn, rhs.dependsOn),
            scalar("\(prefix).role", "nodes", lhs.role, rhs.role),
            scalar("\(prefix).execution_policy", "nodes", lhs.executionPolicy, rhs.executionPolicy)
        ])
    }

    let statedAreas = Set(proposalAffectedFields.map(normalizedArea).filter { !$0.isEmpty })
    let fields = candidates
        .filter { $0.before != nil || $0.after != nil }
        .sorted { $0.path < $1.path }
        .map { candidate -> Delta.Field in
            let change: Delta.Change = if candidate.before == candidate.after {
                .unchanged
            } else if candidate.before == nil {
                .added
            } else if candidate.after == nil {
                .removed
            } else {
                .changed
            }
            let topLevelArea = candidate.path.split(separator: ".").first.map(String.init) ?? candidate.area
            let classification: Delta.PromiseClassification = if change == .unchanged {
                .unchanged
            } else if statedAreas.contains(normalizedArea(candidate.area))
                || statedAreas.contains(normalizedArea(topLevelArea))
            {
                .withinStatedAffectedAreas
            } else {
                .outsideStatedAffectedAreas
            }
            return Delta.Field(
                path: candidate.path,
                affectedArea: candidate.area,
                change: change,
                promiseClassification: classification,
                beforeCanonicalValue: candidate.before,
                afterCanonicalValue: candidate.after
            )
        }
    return Delta(fields: fields)
}

enum CoordinatorMissionMaterialContractComparator {
    static func matches(
        _ lhs: CoordinatorMissionMaterialContractSnapshot,
        _ rhs: CoordinatorMissionMaterialContractSnapshot
    ) -> Bool {
        lhs == rhs
    }

    static func matches(
        _ snapshot: CoordinatorMissionMaterialContractSnapshot,
        current plan: CoordinatorMissionPlan
    ) -> Bool {
        matches(snapshot, CoordinatorMissionMaterialContractSnapshot(plan: plan))
    }

    static func workstreamsMatch(
        _ lhs: CoordinatorMissionWorkstreamSummary,
        _ rhs: CoordinatorMissionWorkstreamSummary
    ) -> Bool {
        CoordinatorMissionMaterialContractSnapshot.Workstream(lhs)
            == CoordinatorMissionMaterialContractSnapshot.Workstream(rhs)
    }

    static func nodesMatch(
        _ lhs: CoordinatorMissionPlanNode,
        _ rhs: CoordinatorMissionPlanNode
    ) -> Bool {
        CoordinatorMissionMaterialContractSnapshot.Node(lhs)
            == CoordinatorMissionMaterialContractSnapshot.Node(rhs)
    }

    static func policiesMatch(
        _ lhs: CoordinatorMissionPolicySnapshot,
        _ rhs: CoordinatorMissionPolicySnapshot
    ) -> Bool {
        CoordinatorMissionMaterialContractSnapshot.Policy(lhs)
            == CoordinatorMissionMaterialContractSnapshot.Policy(rhs)
    }
}

extension CoordinatorMissionPlan {
    var materialContractSnapshot: CoordinatorMissionMaterialContractSnapshot {
        CoordinatorMissionMaterialContractSnapshot(plan: self)
    }

    func materialContractFingerprint() throws -> String {
        try materialContractSnapshot.sha256Fingerprint()
    }
}
