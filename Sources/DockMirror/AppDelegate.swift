import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything saves a setting: an empty domain means a brand-new install.
        let newInstall = SettingsSync.domainIsEmpty()
        UpdateSettings.registerDefaults()
        let mainMenu = AppPresence.mainMenu(appName: "DockMirror", settingsTitle: "Settings…",
                                            target: self, settings: #selector(openPreferences))
        // Right below About in the app menu.
        let otherApps = NSMenuItem(title: "Our other apps…", action: #selector(showOtherApps), keyEquivalent: "")
        otherApps.target = self
        mainMenu.items.first?.submenu?.insertItem(otherApps, at: 1)
        NSApp.mainMenu = mainMenu
        if AppPresence.showInDock { AppPresence.applyDock() }
        statusMenu = StatusMenuController()
        SyncCoordinator.shared.start()

        // DOCKMIRROR_SHOW_SETUP=1 opens setup at launch, for testing it without the menu.
        if SyncCoordinator.shared.state.role == nil
            || ProcessInfo.processInfo.environment["DOCKMIRROR_SHOW_SETUP"] == "1" {
            SetupWindowController.shared.show()
        }

        // An automatic update must not restart DockMirror while it is changing the Dock.
        AutoUpdater.shared.appBusyReason = { SyncCoordinator.shared.isBusy ? "the Dock is being synced" : nil }
        SettingsSync.shared.onApply = { SyncCoordinator.shared.setCheckInterval(SyncSettings.checkInterval) }
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()
        AutoUpdater.shared.start()
    }

    /// The Dock icon's right-click menu, shown when "Show in Dock" is on.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(openPreferences))
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

    /// `dockmirror://sync`, `pause` (pause or resume) and `setup` (from ToolHUD, Shortcuts or
    /// a script) do what the menu items do; anything else opens Settings. A Mac that isn't
    /// set up yet gets the setup window instead of a sync.
    func application(_ application: NSApplication, open urls: [URL]) {
        let coordinator = SyncCoordinator.shared
        for url in urls where url.scheme == "dockmirror" {
            switch url.host {
            case "sync" where coordinator.state.role != nil:
                // A deliberate Sync Now also re-checks which apps are installed.
                InstalledApps.invalidate()
                coordinator.syncNow()
            case "pause" where coordinator.state.role != nil:
                coordinator.setPaused(!coordinator.state.paused)
            case "sync", "pause", "setup":
                SetupWindowController.shared.show()
            default:
                openPreferences()
            }
        }
    }

    /// The developer's site, which lists every app.
    @objc func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }
}
