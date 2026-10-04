import Foundation

/// What a Mac keeps between syncs.
public struct LocalState: Codable, Equatable, Sendable {
    public var role: MacRole?
    public var paused = false
    public var entries: EntryMap = [:]
    /// Pinned apps as of the last sync, the baseline for spotting the user's
    /// edits. nil until the first sync after setup.
    public var lastObserved: [String]?

    public init(role: MacRole? = nil) { self.role = role }
}

/// Why a sync stopped short of changing anything.
public enum SyncHold: Equatable, Sendable {
    /// Not set up yet: showing a preview only.
    case notSetUp
    case paused
    /// The user removed many apps here at once (or macOS reset the Dock).
    case largeLocalRemoval([String])
    /// Other Macs' changes would remove many apps from this Dock.
    case largeIncomingRemoval([String])
}

public struct CycleResult: Equatable, Sendable {
    public var state: LocalState
    public var change: LocalChange
    public var eligible: Set<String>
    public var plan: [PlannedSlot]
    /// Whether the Dock has to be rewritten to match `plan`.
    public var needsWrite: Bool
    public var hold: SyncHold?
    /// Pinned apps once `plan` is applied; becomes `lastObserved` after a
    /// successful write.
    public var plannedApps: [String]
}

public struct CycleInput: Sendable {
    public var dock: [DockSlot]
    public var labels: [String: String]
    /// Bundle IDs installed on this Mac (among the apps any Mac knows about).
    public var installed: Set<String>
    public var remotes: [DeviceRecord]
    public var now: Date
    public var device: String
    public var staleAfter: TimeInterval
    /// The user confirmed a held large removal.
    public var allowLargeRemoval: Bool

    public init(dock: [DockSlot], labels: [String: String], installed: Set<String>, remotes: [DeviceRecord],
                now: Date, device: String, staleAfter: TimeInterval, allowLargeRemoval: Bool = false) {
        self.dock = dock
        self.labels = labels
        self.installed = installed
        self.remotes = remotes
        self.now = now
        self.device = device
        self.staleAfter = staleAfter
        self.allowLargeRemoval = allowLargeRemoval
    }
}

extension SyncEngine {
    /// One sync pass: take in other Macs' changes, record this Mac's, and plan
    /// this Dock. Pure — the caller reads the Dock, writes it, and publishes.
    public static func runCycle(state: LocalState, input: CycleInput) -> CycleResult {
        var state = state
        let apps = uniqued(input.dock.compactMap(\.bundleID))
        let installedLocally: (String) -> Bool = { input.installed.contains($0) }
        let eligible = self.eligible(localInstalled: input.installed, remotes: input.remotes,
                                     now: input.now, staleAfter: input.staleAfter)

        state.entries = EntryMerge.merge([state.entries] + input.remotes.map(\.entries))

        func result(change: LocalChange = LocalChange(), hold: SyncHold?) -> CycleResult {
            let plan = self.plan(current: input.dock, entries: state.entries, eligible: eligible)
            return CycleResult(state: state, change: change, eligible: eligible, plan: plan,
                               needsWrite: hold == nil && !isNoChange(plan, current: input.dock),
                               hold: hold,
                               plannedApps: bundleIDs(of: plan, current: input.dock).compactMap { $0 })
        }

        guard let role = state.role else { return result(hold: .notSetUp) }
        // Paused: nothing recorded, and `lastObserved` is left alone so edits
        // made meanwhile are picked up on resume.
        if state.paused { return result(hold: .paused) }

        var change = LocalChange()
        if let previous = state.lastObserved {
            let before = state.entries
            change = recordLocalChanges(previous: previous, current: apps, entries: &state.entries,
                                        eligible: eligible, installedLocally: installedLocally,
                                        labels: input.labels, now: input.now, device: input.device)
            let synced = previous.filter { eligible.contains($0) }.count
            if !input.allowLargeRemoval && isLargeRemoval(removing: change.removed.count, outOf: synced) {
                state.entries = before
                return result(change: change, hold: .largeLocalRemoval(change.removed))
            }
        } else if role == .main {
            seedFromMain(dock: apps, entries: &state.entries, installedLocally: installedLocally,
                         labels: input.labels, now: input.now, device: input.device)
        }
        // From here the user's edits are folded in, so this Dock is the baseline
        // even if the plan below is held.
        state.lastObserved = apps

        let planned = plan(current: input.dock, entries: state.entries, eligible: eligible)
        let removing = removals(plan: planned, current: input.dock)
        if !input.allowLargeRemoval && isLargeRemoval(removing: removing.count, outOf: apps.count) {
            return result(change: change, hold: .largeIncomingRemoval(removing))
        }
        return result(change: change, hold: nil)
    }
}
