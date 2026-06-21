import Foundation

struct WorkspaceSearchRootPathIndexIdentity: Equatable, Hashable {
    let rootID: UUID
    let lifetimeID: UUID
    let topologyGeneration: UInt64
}

/// Immutable root-local search projection retained by catalog snapshots and active readers.
///
/// Small shard patches share one materialized base index and rebuild only a bounded overlay.
/// Every published generation owns immutable overlay/tombstone values, so older readers can safely
/// continue querying the base and overlay generation they captured.
final class WorkspaceSearchRootPathIndex: @unchecked Sendable {
    enum BuildKind {
        case full
        case overlay
        case reused
    }

    struct Candidate {
        let entry: WorkspaceSearchCatalogEntry
        let score: Int32
        let tieBreakKey: String
    }

    static let maxOverlayChangedFileCount = 32

    private final class MaterializedBase: @unchecked Sendable {
        let entries: [WorkspaceSearchCatalogEntry]
        let index: PathSearchIndex

        init(entries: [WorkspaceSearchCatalogEntry]) {
            self.entries = entries
            #if DEBUG
                let keyStart = WorkspaceFileSearchDebugTiming.now()
                let keys = entries.map(\.pathSearchIndexKey)
                let keyEnd = WorkspaceFileSearchDebugTiming.now()
                WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexKey(
                    nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: keyStart, through: keyEnd)
                )
                let indexStart = WorkspaceFileSearchDebugTiming.now()
                index = PathSearchIndex(paths: keys)
                let indexEnd = WorkspaceFileSearchDebugTiming.now()
                WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexConstruction(
                    nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: indexStart, through: indexEnd)
                )
            #else
                index = PathSearchIndex(paths: entries.map(\.pathSearchIndexKey))
            #endif
        }
    }

    let identity: WorkspaceSearchRootPathIndexIdentity
    let rootPath: String
    let entries: [WorkspaceSearchCatalogEntry]
    let buildKind: BuildKind

    private let base: MaterializedBase
    private let overlayEntries: [WorkspaceSearchCatalogEntry]
    private let overlayIndex: PathSearchIndex?
    private let tombstonedBaseEntryIDs: Set<UUID>
    private let accumulatedChangedFileIDs: Set<UUID>

    init(
        identity: WorkspaceSearchRootPathIndexIdentity,
        rootPath: String,
        entries: [WorkspaceSearchCatalogEntry]
    ) {
        self.identity = identity
        self.rootPath = rootPath
        self.entries = entries
        buildKind = .full
        base = MaterializedBase(entries: entries)
        overlayEntries = []
        overlayIndex = nil
        tombstonedBaseEntryIDs = []
        accumulatedChangedFileIDs = []
    }

    private init(
        identity: WorkspaceSearchRootPathIndexIdentity,
        rootPath: String,
        entries: [WorkspaceSearchCatalogEntry],
        buildKind: BuildKind,
        base: MaterializedBase,
        overlayEntries: [WorkspaceSearchCatalogEntry],
        preparedOverlayIndex: PathSearchIndex? = nil,
        tombstonedBaseEntryIDs: Set<UUID>,
        accumulatedChangedFileIDs: Set<UUID>
    ) {
        self.identity = identity
        self.rootPath = rootPath
        self.entries = entries
        self.buildKind = buildKind
        self.base = base
        self.overlayEntries = overlayEntries
        overlayIndex = preparedOverlayIndex ?? (
            overlayEntries.isEmpty
                ? nil
                : PathSearchIndex(paths: overlayEntries.map(\.pathSearchIndexKey))
        )
        self.tombstonedBaseEntryIDs = tombstonedBaseEntryIDs
        self.accumulatedChangedFileIDs = accumulatedChangedFileIDs
    }

    var count: Int {
        entries.count
    }

    func applyingPatch(
        identity: WorkspaceSearchRootPathIndexIdentity,
        entries: [WorkspaceSearchCatalogEntry],
        changedFileIDs: Set<UUID>
    ) -> WorkspaceSearchRootPathIndex {
        guard identity.rootID == self.identity.rootID,
              identity.lifetimeID == self.identity.lifetimeID
        else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }

        guard !changedFileIDs.isEmpty else {
            return WorkspaceSearchRootPathIndex(
                identity: identity,
                rootPath: rootPath,
                entries: entries,
                buildKind: .reused,
                base: base,
                overlayEntries: overlayEntries,
                preparedOverlayIndex: overlayIndex,
                tombstonedBaseEntryIDs: tombstonedBaseEntryIDs,
                accumulatedChangedFileIDs: accumulatedChangedFileIDs
            )
        }

        let nextChangedFileIDs = accumulatedChangedFileIDs.union(changedFileIDs)
        guard nextChangedFileIDs.count < Self.maxOverlayChangedFileCount else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }

        var nextTombstonedBaseEntryIDs = tombstonedBaseEntryIDs
        var nextOverlayEntriesByID = Dictionary(
            uniqueKeysWithValues: overlayEntries.map { ($0.id, $0) }
        )
        let currentEntriesByChangedID = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
                changedFileIDs.contains(entry.id) ? (entry.id, entry) : nil
            }
        )
        let baseEntryIDs = Set(base.entries.lazy.compactMap { entry in
            changedFileIDs.contains(entry.id) ? entry.id : nil
        })

        for fileID in changedFileIDs {
            nextOverlayEntriesByID.removeValue(forKey: fileID)
            if baseEntryIDs.contains(fileID) {
                nextTombstonedBaseEntryIDs.insert(fileID)
            }
            if let currentEntry = currentEntriesByChangedID[fileID] {
                nextOverlayEntriesByID[fileID] = currentEntry
            }
        }

        let nextOverlayEntries = entries.compactMap { nextOverlayEntriesByID[$0.id] }
        return WorkspaceSearchRootPathIndex(
            identity: identity,
            rootPath: rootPath,
            entries: entries,
            buildKind: .overlay,
            base: base,
            overlayEntries: nextOverlayEntries,
            tombstonedBaseEntryIDs: nextTombstonedBaseEntryIDs,
            accumulatedChangedFileIDs: nextChangedFileIDs
        )
    }

    func search(_ query: String, limit: Int) -> [Candidate] {
        guard limit > 0 else { return [] }

        let boundedBaseLimit = min(base.entries.count, limit)
        let baseOverfetch = min(
            tombstonedBaseEntryIDs.count,
            base.entries.count - boundedBaseLimit
        )
        let baseCandidates = base.index
            .searchSynchronously(query, limit: boundedBaseLimit + baseOverfetch)
            .compactMap { candidate -> Candidate? in
                guard base.entries.indices.contains(candidate.index) else { return nil }
                let entry = base.entries[candidate.index]
                guard !tombstonedBaseEntryIDs.contains(entry.id) else { return nil }
                return Candidate(
                    entry: entry,
                    score: candidate.score,
                    tieBreakKey: candidate.tieBreakKey
                )
            }

        let overlayCandidates = overlayIndex?
            .searchSynchronously(query, limit: min(limit, overlayEntries.count))
            .compactMap { candidate -> Candidate? in
                guard overlayEntries.indices.contains(candidate.index) else { return nil }
                return Candidate(
                    entry: overlayEntries[candidate.index],
                    score: candidate.score,
                    tieBreakKey: candidate.tieBreakKey
                )
            } ?? []

        var baseIndex = 0
        var overlayIndex = 0
        var results: [Candidate] = []
        results.reserveCapacity(limit)
        while results.count < limit,
              baseIndex < baseCandidates.count || overlayIndex < overlayCandidates.count
        {
            if overlayIndex >= overlayCandidates.count {
                results.append(baseCandidates[baseIndex])
                baseIndex += 1
            } else if baseIndex >= baseCandidates.count {
                results.append(overlayCandidates[overlayIndex])
                overlayIndex += 1
            } else if Self.candidatePrecedes(
                overlayCandidates[overlayIndex],
                baseCandidates[baseIndex]
            ) {
                results.append(overlayCandidates[overlayIndex])
                overlayIndex += 1
            } else {
                results.append(baseCandidates[baseIndex])
                baseIndex += 1
            }
        }
        return results
    }

    private static func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        switch WorkspaceFileContextStore.compareUTF8Binary(lhs.tieBreakKey, rhs.tieBreakKey) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            break
        }
        return WorkspaceFileContextStore.searchCatalogEntryPrecedes(lhs.entry, rhs.entry)
    }
}

extension WorkspaceSearchCatalogEntry {
    var pathSearchIndexKey: String {
        // Preserve the existing one-record index behavior for both UI display paths and absolute
        // path consumers. This exact string is also the global lexical tie-break key.
        displayPath + "\n" + standardizedFullPath
    }
}

// MARK: - LRU Cache Actor

/// Thread-safe LRU cache implementation using actors
actor LRUCacheActor<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        var timestamp: Date
    }

    private var cache: [Key: Entry] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: Key) -> Value? {
        if var entry = cache[key] {
            entry.timestamp = Date()
            cache[key] = entry
            return entry.value
        }
        return nil
    }

    func set(_ value: Value, for key: Key) {
        cache[key] = Entry(value: value, timestamp: Date())

        // Evict oldest if over capacity
        if cache.count > capacity {
            let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }
            if let oldestKey = oldest?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
    }

    func clear() {
        cache.removeAll()
    }
}
