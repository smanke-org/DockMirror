import Foundation

/// One tile in `persistent-apps`, reduced to what sync cares about.
/// Spacers and anything without a bundle identifier have `bundleID == nil`.
public struct DockSlot: Equatable, Sendable {
    public var bundleID: String?
    public init(bundleID: String?) { self.bundleID = bundleID }
}

/// One tile of the Dock the engine wants: an existing tile, by its index in
/// the current Dock, or an app to add.
public enum PlannedSlot: Equatable, Sendable {
    case existing(Int)
    case insert(String)
}

/// What the user changed on this Mac since the last sync.
public struct LocalChange: Equatable, Sendable {
    public var added: [String] = []
    public var removed: [String] = []
    public var moved: [String] = []
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && moved.isEmpty }
    public init(added: [String] = [], removed: [String] = [], moved: [String] = []) {
        self.added = added
        self.removed = removed
        self.moved = moved
    }
}

public enum SyncEngine {

    // MARK: - Which apps are synced

    /// Apps installed on this Mac and on every other Mac that has joined and
    /// been seen within `staleAfter`. A Mac that has gone quiet stops narrowing
    /// the set, so a sold or retired Mac can't freeze everyone's Dock.
    public static func eligible(localInstalled: Set<String>, remotes: [DeviceRecord],
                                now: Date, staleAfter: TimeInterval) -> Set<String> {
        var result = localInstalled
        for remote in remotes where remote.role != nil && now.timeIntervalSince(remote.updatedAt) <= staleAfter {
            result.formIntersection(remote.installed)
        }
        return result
    }

    /// The synced apps in agreed order.
    public static func managedOrder(entries: EntryMap, eligible: Set<String>) -> [String] {
        entries
            .filter { $0.value.pinned && eligible.contains($0.key) }
            .sorted { ($0.value.key, $0.key) < ($1.value.key, $1.key) }
            .map(\.key)
    }

    // MARK: - Seeding

    /// Makes this Mac's Dock the starting point for every Mac.
    ///
    /// Pins its apps in its order, and unpins any app another Mac had pinned
    /// that is installed here but not in this Dock — so the main Mac's layout
    /// wins outright rather than being merged with whatever was there before.
    public static func seedFromMain(dock: [String], entries: inout EntryMap,
                                    installedLocally: (String) -> Bool,
                                    labels: [String: String], now: Date, device: String) {
        let apps = uniqued(dock)
        for (id, key) in zip(apps, FractionalIndex.evenlySpaced(apps.count)) {
            entries[id] = DockEntry(pinned: true, key: key, updatedAt: now, by: device,
                                    label: labels[id] ?? entries[id]?.label)
        }
        let docked = Set(apps)
        for (id, entry) in entries where entry.pinned && !docked.contains(id) && installedLocally(id) {
            entries[id] = DockEntry(pinned: false, key: entry.key, updatedAt: now, by: device, label: entry.label)
        }
    }

    // MARK: - Recording local edits

    /// Works out what the user changed between `previous` (the Dock as of the
    /// last sync) and `current`, and stamps only those apps.
    ///
    /// - Added apps are pinned. Moved apps get a new key between their
    ///   neighbours. Neither touches any other app's entry.
    /// - A removal is recorded only while the app is still installed here —
    ///   uninstalling an app is not a request to unpin it on every Mac — and
    ///   only for an app that was being synced or had been pinned before, so
    ///   tidying away a local-only app doesn't later remove it elsewhere.
    @discardableResult
    public static func recordLocalChanges(previous: [String], current: [String], entries: inout EntryMap,
                                          eligible: Set<String>, installedLocally: (String) -> Bool,
                                          labels: [String: String], now: Date, device: String) -> LocalChange {
        let old = uniqued(previous)
        let new = uniqued(current)
        let oldSet = Set(old)
        let newSet = Set(new)

        let stable = Set(longestCommonSubsequence(old, new))
        var change = LocalChange()
        change.added = new.filter { !oldSet.contains($0) }
        change.moved = new.filter { oldSet.contains($0) && !stable.contains($0) }
        change.removed = old.filter { id in
            guard !newSet.contains(id), installedLocally(id) else { return false }
            return eligible.contains(id) || entries[id]?.pinned == true
        }
        guard !change.isEmpty else { return change }

        // Apps whose keys can be trusted as fixed points: untouched, synced, and
        // in key order. Anything else this Mac has shows in an order that can
        // disagree with the keys (local-only apps aren't arranged by sync), so
        // only the longest run that is still ascending is used.
        let candidates = new.filter { id in
            stable.contains(id) && eligible.contains(id) && entries[id]?.pinned == true
        }
        let anchors = Set(longestIncreasingRun(candidates) { entries[$0]!.key })

        let rekey = Set(change.added + change.moved)
        var lastKey: String?
        for (index, id) in new.enumerated() {
            if anchors.contains(id) {
                lastKey = entries[id]!.key
                continue
            }
            guard rekey.contains(id) else { continue }
            let nextAnchor = new[(index + 1)...].first { anchors.contains($0) }
            let key = FractionalIndex.between(lastKey, nextAnchor.map { entries[$0]!.key })
            entries[id] = DockEntry(pinned: true, key: key, updatedAt: now, by: device,
                                    label: labels[id] ?? entries[id]?.label)
            lastKey = key
        }

        for id in change.removed {
            let existing = entries[id]
            entries[id] = DockEntry(pinned: false, key: existing?.key ?? FractionalIndex.between(nil, nil),
                                    updatedAt: now, by: device, label: existing?.label ?? labels[id])
        }
        return change
    }

    // MARK: - Planning this Mac's Dock

    /// The Dock this Mac should have.
    ///
    /// Synced apps — eligible apps that have an entry — appear in agreed order,
    /// and unpinned ones are removed. Everything else (local-only apps, apps
    /// no Mac has stamped yet, spacers) stays, travelling with the synced app
    /// it currently follows so it keeps its place in the user's arrangement.
    public static func plan(current: [DockSlot], entries: EntryMap, eligible: Set<String>) -> [PlannedSlot] {
        let order = managedOrder(entries: entries, eligible: eligible)

        func isSynced(_ id: String) -> Bool { eligible.contains(id) && entries[id] != nil }

        var firstIndex: [String: Int] = [:]
        var leading: [Int] = []
        var following: [String: [Int]] = [:]
        var anchor: String?

        for (index, slot) in current.enumerated() {
            if let id = slot.bundleID, isSynced(id) {
                if firstIndex[id] != nil { continue }          // duplicate tile
                firstIndex[id] = index
                if entries[id]!.pinned { anchor = id }
                continue
            }
            if let anchor {
                following[anchor, default: []].append(index)
            } else {
                leading.append(index)
            }
        }

        var result = leading.map(PlannedSlot.existing)
        for id in order {
            result.append(firstIndex[id].map(PlannedSlot.existing) ?? .insert(id))
            result += (following[id] ?? []).map(PlannedSlot.existing)
        }
        return result
    }

    /// Bundle IDs of the planned Dock, for comparing and previewing.
    public static func bundleIDs(of plan: [PlannedSlot], current: [DockSlot]) -> [String?] {
        plan.map { slot in
            switch slot {
            case .existing(let index): return current[index].bundleID
            case .insert(let id): return id
            }
        }
    }

    public static func isNoChange(_ plan: [PlannedSlot], current: [DockSlot]) -> Bool {
        plan == current.indices.map(PlannedSlot.existing)
    }

    // MARK: - Guarding against mass removals

    /// A change that removes many apps at once is far more likely to be macOS
    /// resetting the Dock, or a restore from backup, than a deliberate edit —
    /// and spreading it would empty every Mac's Dock. Such changes wait for the
    /// user to confirm them.
    public static func isLargeRemoval(removing count: Int, outOf total: Int) -> Bool {
        count >= 5 || (count >= 3 && count * 2 >= total)
    }

    /// How many apps applying `plan` would take off this Mac's Dock.
    public static func removals(plan: [PlannedSlot], current: [DockSlot]) -> [String] {
        let kept = Set(plan.compactMap { slot -> Int? in
            if case .existing(let index) = slot { return index }
            return nil
        })
        return current.indices.compactMap { index in
            kept.contains(index) ? nil : current[index].bundleID
        }
    }

    // MARK: - Helpers

    static func uniqued(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [String] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append(a[i]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    /// The longest subsequence whose keys strictly increase.
    static func longestIncreasingRun(_ items: [String], key: (String) -> String) -> [String] {
        guard !items.isEmpty else { return [] }
        let keys = items.map(key)
        var length = Array(repeating: 1, count: items.count)
        var previous = Array(repeating: -1, count: items.count)
        for i in items.indices {
            for j in 0..<i where keys[j] < keys[i] && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        var index = length.indices.max { length[$0] < length[$1] }!
        var result: [String] = []
        while index >= 0 {
            result.append(items[index])
            index = previous[index]
        }
        return result.reversed()
    }
}
