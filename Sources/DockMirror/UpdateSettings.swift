import Foundation

/// Update-related preferences. Kept in
/// `UserDefaults`, so they survive restarts.
enum UpdateSettings {
    private enum Key {
        static let checkForUpdatesAtLaunch = "checkForUpdatesAtLaunch"
        static let skippedUpdateVersion = "skippedUpdateVersion"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [Key.checkForUpdatesAtLaunch: true])
    }

    /// Look for a newer release shortly after launch. Silent unless there is
    /// something to install, so it can't turn into a dialog on every launch.
    static var checkForUpdatesAtLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Key.checkForUpdatesAtLaunch) }
        set { UserDefaults.standard.set(newValue, forKey: Key.checkForUpdatesAtLaunch) }
    }

    /// A version the user chose to skip. The launch check stays quiet about
    /// it; asking again on every launch would just be nagging. Checking
    /// manually still offers it.
    static var skippedUpdateVersion: String? {
        get { UserDefaults.standard.string(forKey: Key.skippedUpdateVersion) }
        set { UserDefaults.standard.set(newValue, forKey: Key.skippedUpdateVersion) }
    }
}
