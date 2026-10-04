import AppKit
import DockMirrorCore

/// Reads and writes the Dock's pinned apps (`persistent-apps` in
/// `com.apple.dock`), and keeps backups of the whole Dock domain.
///
/// Everything goes through CFPreferences or `defaults`, never the plist file
/// itself: cfprefsd caches the domain, so editing the file directly would be
/// overwritten by the next write from the Dock. Folders and stacks
/// (`persistent-others`), Recents and every Dock setting are never touched.
enum DockPreferences {
    private static let domain = "com.apple.dock" as CFString
    private static let appsKey = "persistent-apps" as CFString

    /// The plist file, watched for changes (not read or written directly).
    static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.dock.plist")

    struct Snapshot: Equatable {
        /// The tiles exactly as the Dock stored them, written back unchanged.
        let tiles: [NSDictionary]

        var slots: [DockSlot] { tiles.map { DockSlot(bundleID: DockPreferences.bundleID(of: $0)) } }

        var labels: [String: String] {
            var result: [String: String] = [:]
            for tile in tiles {
                guard let id = DockPreferences.bundleID(of: tile),
                      let data = tile["tile-data"] as? NSDictionary,
                      let label = data["file-label"] as? String else { continue }
                result[id] = label
            }
            return result
        }
    }

    static func read() -> Snapshot {
        CFPreferencesAppSynchronize(domain)
        let tiles = CFPreferencesCopyAppValue(appsKey, domain) as? [NSDictionary] ?? []
        return Snapshot(tiles: tiles)
    }

    /// Bundle ID of an app tile; nil for spacers and anything else.
    static func bundleID(of tile: NSDictionary) -> String? {
        guard (tile["tile-type"] as? String) == "file-tile",
              let data = tile["tile-data"] as? NSDictionary,
              let id = data["bundle-identifier"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Builds the tiles for `plan`. Returns nil if an app to add can't be
    /// found, so a half-built Dock is never written.
    static func tiles(for plan: [PlannedSlot], from snapshot: Snapshot, labels: [String: String]) -> [NSDictionary]? {
        var result: [NSDictionary] = []
        for slot in plan {
            switch slot {
            case .existing(let index):
                result.append(snapshot.tiles[index])
            case .insert(let id):
                guard let url = InstalledApps.url(for: id) else { return nil }
                result.append(newTile(bundleID: id, url: url, label: labels[id]))
            }
        }
        return result
    }

    /// The minimal tile the Dock accepts; it fills in the bookmark, GUID and
    /// dates itself when it next saves.
    private static func newTile(bundleID: String, url: URL, label: String?) -> NSDictionary {
        let name = label ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return [
            "tile-type": "file-tile",
            "tile-data": [
                "bundle-identifier": bundleID,
                "file-label": name,
                "file-type": 41,
                "file-data": [
                    "_CFURLString": url.absoluteString,
                    "_CFURLStringType": 15,
                ],
            ],
        ] as NSDictionary
    }

    enum WriteError: LocalizedError {
        case changedUnderneath
        case didNotStick

        var errorDescription: String? {
            switch self {
            case .changedUnderneath: return "The Dock changed while syncing; will try again."
            case .didNotStick: return "macOS did not accept the new Dock layout."
            }
        }
    }

    /// Replaces the pinned apps and restarts the Dock to show them.
    ///
    /// `expected` is the Dock the plan was made from. If it has changed since
    /// (the user is mid-drag, or just added something), nothing is written.
    static func write(_ tiles: [NSDictionary], expecting expected: Snapshot) throws {
        guard read() == expected else { throw WriteError.changedUnderneath }
        CFPreferencesSetAppValue(appsKey, tiles as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw WriteError.didNotStick }
        guard read().slots == Snapshot(tiles: tiles).slots else { throw WriteError.didNotStick }
        restartDock()
    }

    static func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
        task.waitUntilExit()
    }
}

/// Timestamped copies of the whole Dock domain, taken before every write.
enum DockBackups {
    static let keep = 50

    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("DockMirror/Backups", isDirectory: true)
    }

    struct Backup {
        let url: URL
        let date: Date
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    /// Exports `com.apple.dock` with `defaults`, which reads through cfprefsd
    /// and so captures what the Dock is actually using.
    @discardableResult
    static func create() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("dock-\(formatter.string(from: Date())).plist")
        let status = run("/usr/bin/defaults", ["export", "com.apple.dock", url.path])
        guard status == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "DockMirror.Backup", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't back up the Dock, so it was not changed."])
        }
        prune()
        return url
    }

    static func list() -> [Backup] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("dock-"), let date = formatter.date(from: String(name.dropFirst(5))) else { return nil }
            return Backup(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Puts the whole Dock domain back as it was, then restarts the Dock.
    static func restore(_ backup: Backup) throws {
        // The current state is backed up first, so a restore can be undone.
        try create()
        let status = run("/usr/bin/defaults", ["import", "com.apple.dock", backup.url.path])
        guard status == 0 else {
            throw NSError(domain: "DockMirror.Backup", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "The backup could not be restored."])
        }
        DockPreferences.restartDock()
    }

    private static func prune() {
        for backup in list().dropFirst(keep) {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
