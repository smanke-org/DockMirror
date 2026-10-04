import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateSettings.registerDefaults()
        NSApp.mainMenu = AppPresence.mainMenu(appName: "DockMirror", settingsTitle: "Preferences…",
                                              target: self, settings: #selector(openPreferences))
        if AppPresence.showInDock { AppPresence.applyDock() }
        statusMenu = StatusMenuController()
        SyncCoordinator.shared.start()

        // DOCKMIRROR_SHOW_SETUP=1 opens setup at launch, for testing it without the menu.
        if SyncCoordinator.shared.state.role == nil
            || ProcessInfo.processInfo.environment["DOCKMIRROR_SHOW_SETUP"] == "1" {
            SetupWindowController.shared.show()
        }

        // Silent: it only records an available update for the menu to offer.
        if UpdateSettings.checkForUpdatesAtLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                UpdateController.checkForUpdates(silent: true)
            }
        }
    }

    /// The Dock icon's right-click menu, shown when "Show in Dock" is on.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AppPresence.dockMenu(title: "Preferences…", target: self, action: #selector(openPreferences))
    }

    /// Clicking the Dock icon, or opening the app again from Applications or
    /// Spotlight, opens Preferences — the way back when both icons are hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PreferencesWindowController.shared.show()
        return true
    }

    @objc func openPreferences() {
        PreferencesWindowController.shared.show()
    }
}
