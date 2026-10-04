import AppKit

/// Whether an app is really installed on this Mac.
///
/// Launch Services also knows about copies in the Trash, on mounted disk
/// images and in build folders. Counting those would sync an app onto a Dock
/// that can't keep it, so only copies in ordinary locations count.
enum InstalledApps {
    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).first(where: isOrdinaryLocation)
    }

    /// Results are reused for 10 minutes: a pass checks every app any Mac has
    /// pinned, and asking Launch Services for each one every time adds up.
    /// An app installed or deleted meanwhile is noticed on the next refresh,
    /// or straight away with Sync Now.
    @MainActor
    static func installed(among bundleIDs: Set<String>) -> Set<String> {
        let now = Date()
        if now.timeIntervalSince(cacheDate) > cacheLifetime {
            cache = [:]
            cacheDate = now
        }
        return bundleIDs.filter { id in
            if let known = cache[id] { return known }
            let found = url(for: id) != nil
            cache[id] = found
            return found
        }
    }

    @MainActor
    static func invalidate() {
        cache = [:]
    }

    private static let cacheLifetime: TimeInterval = 600
    @MainActor private static var cache: [String: Bool] = [:]
    @MainActor private static var cacheDate = Date.distantPast

    private static func isOrdinaryLocation(_ url: URL) -> Bool {
        let path = url.path
        let excluded = ["/.Trash/", "/DerivedData/", "/.build/", "/Build/Products/"]
        guard !excluded.contains(where: path.contains), !path.hasPrefix("/Volumes/") else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}
