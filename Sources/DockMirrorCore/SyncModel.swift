import Foundation

/// What every Mac agrees about one app: whether it is pinned, and where.
///
/// Each app is its own last-writer-wins register. A Mac only stamps the apps
/// the user actually touched on it, so an edit to Safari on one Mac and an edit
/// to Mail on another both survive the merge.
public struct DockEntry: Codable, Equatable, Sendable {
    public var pinned: Bool
    /// A `FractionalIndex` key. Kept on removal, so re-pinning has a sensible spot.
    public var key: String
    public var updatedAt: Date
    /// Device ID of the Mac that made the change; breaks timestamp ties.
    public var by: String
    /// The Dock's label for the app, for display only.
    public var label: String?

    public init(pinned: Bool, key: String, updatedAt: Date, by: String, label: String? = nil) {
        self.pinned = pinned
        self.key = key
        self.updatedAt = updatedAt
        self.by = by
        self.label = label
    }

    /// Whether this entry should replace `other` in a merge.
    public func supersedes(_ other: DockEntry) -> Bool {
        (updatedAt, by) > (other.updatedAt, other.by)
    }
}

/// Bundle identifier -> entry.
public typealias EntryMap = [String: DockEntry]

public enum EntryMerge {
    /// Per-app last writer wins. Commutative and idempotent, so it does not
    /// matter in which order, or how often, Macs read each other's files.
    public static func merge(_ maps: [EntryMap]) -> EntryMap {
        var result: EntryMap = [:]
        for map in maps {
            for (id, entry) in map {
                if let existing = result[id], !entry.supersedes(existing) { continue }
                result[id] = entry
            }
        }
        return result
    }
}

public enum MacRole: String, Codable, Sendable {
    /// Its Dock order seeded every other Mac.
    case main
    case secondary
}

/// One Mac's file in the shared folder. Each Mac writes only its own.
public struct DeviceRecord: Codable, Equatable, Sendable {
    public var schema: Int = 1
    public var deviceID: String
    public var deviceName: String
    public var appVersion: String
    public var updatedAt: Date
    /// nil until the Mac has been set up. Such a Mac is shown, but does not
    /// narrow the set of synced apps until it joins.
    public var role: MacRole?
    public var paused: Bool
    /// Which of the known apps are installed on this Mac.
    public var installed: [String]
    /// This Mac's pinned apps in Dock order, for display and diagnostics.
    public var dock: [String]
    /// This Mac's merged view of every Mac's entries, so a change keeps
    /// spreading even after the Mac that made it goes to sleep.
    public var entries: EntryMap

    public init(deviceID: String, deviceName: String, appVersion: String, updatedAt: Date,
                role: MacRole?, paused: Bool, installed: [String], dock: [String], entries: EntryMap) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.updatedAt = updatedAt
        self.role = role
        self.paused = paused
        self.installed = installed
        self.dock = dock
        self.entries = entries
    }

    /// Everything except the timestamp, to tell whether anything changed.
    public var content: DeviceRecord {
        var copy = self
        copy.updatedAt = .distantPast
        return copy
    }
}
