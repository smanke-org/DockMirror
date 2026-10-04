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

    static func installed(among bundleIDs: Set<String>) -> Set<String> {
        bundleIDs.filter { url(for: $0) != nil }
    }

    private static func isOrdinaryLocation(_ url: URL) -> Bool {
        let path = url.path
        let excluded = ["/.Trash/", "/DerivedData/", "/.build/", "/Build/Products/"]
        guard !excluded.contains(where: path.contains), !path.hasPrefix("/Volumes/") else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}
