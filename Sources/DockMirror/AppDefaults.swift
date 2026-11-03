import Foundation

/// Where the sync state, the other Macs' cached records and the sync settings are kept.
/// Normally `UserDefaults.standard`; an agent CLI test copy (a Debug build run with
/// `APP_STORE=<folder>`) gets a domain of its own, so it never touches the real app's sync state.
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if AgentSocket.isTestRun, let suite = UserDefaults(suiteName: testSuite) { return suite }
        #endif
        return .standard
    }()

    /// The test copy's domain, deleted after a test with `defaults delete`.
    static let testSuite = "com.smanke.DockMirror.agenttest"

    /// The test copy's own folder (`APP_STORE`), for its sync files and backups. nil otherwise,
    /// and always nil in Release builds.
    static var testFolder: URL? {
        #if DEBUG
        if AgentSocket.isTestRun, let path = ProcessInfo.processInfo.environment["APP_STORE"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return nil
    }
}
