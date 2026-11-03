import AppKit

/// Whether quitting asks first, so a stray ⌘Q doesn't stop the Dock syncing. On by default.
enum QuitSettings {
    static let key = "confirmQuit"

    static var confirmQuit: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Quits DockMirror without asking: for quitting itself (installing an update, ending a test).
@MainActor
enum QuitConfirmation {
    private(set) static var confirmed = false

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // A test run of the agent CLI (APP_STORE): its own sync folder, backups and settings,
        // and the agent socket. It never writes the Dock (every pass is a dry run), and nothing
        // else starts: no Dock or folder watching, timers, menu bar item, ToolHUD menu,
        // settings sync or updater. Passes run only when a command asks for one.
        if AgentSocket.isTestRun {
            _ = SyncCoordinator.shared
            AgentSocket.listen { await AgentRouter.handle($0) }
            return
        }
        #endif
        // Before anything saves a setting: an empty domain means a brand-new install.
        let newInstall = SettingsSync.domainIsEmpty()
        UpdateSettings.registerDefaults()
        AppAppearance.start()
        let mainMenu = AppPresence.mainMenu(appName: "DockMirror", settingsTitle: "Settings…",
                                            target: self, settings: #selector(openPreferences))
        // Right below About in the app menu.
        let otherApps = NSMenuItem(title: "Our other apps…", action: #selector(showOtherApps), keyEquivalent: "")
        otherApps.target = self
        mainMenu.items.first?.submenu?.insertItem(otherApps, at: 1)
        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        let helpOpen = NSMenuItem(title: "DockMirror Help", action: #selector(showHelp), keyEquivalent: "?")
        helpOpen.target = self
        help.addItem(helpOpen)
        helpItem.submenu = help
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = mainMenu
        if AppPresence.showInDock { AppPresence.applyDock() }
        statusMenu = StatusMenuController()
        #if DEBUG
        // A test run shares the installed app's settings, so it checks Help or quitting and
        // stops before sync or anything else starts.
        if let snapshot = ProcessInfo.processInfo.environment["DOCKMIRROR_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: statusMenu)
            return
        }
        if let how = ProcessInfo.processInfo.environment["DOCKMIRROR_DEBUG_QUIT_TEST"] {
            DebugQuitTest.run(how)
            return
        }
        // The update prompt, What's New and Settings drawn to PNGs; starts nothing else.
        if let folder = ProcessInfo.processInfo.environment["DOCKMIRROR_DEBUG_UPDATE_NOTES"] {
            DebugUpdateNotes.run(folder: folder)
            return
        }
        #endif
        SyncCoordinator.shared.start()
        // `dockmirror` and the MCP server talk to the app through this.
        AgentSocket.listen { await AgentRouter.handle($0) }

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
        AutoUpdater.shared.start(newInstall: newInstall)
    }

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when DockMirror quits itself to install an update.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard QuitSettings.confirmQuit, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }

        // A menu bar app needs to be a regular one for the alert to come to the front; the
        // old policy goes back a runloop turn later, once the alert is gone (AppKit ignores
        // it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit DockMirror?"
        alert.informativeText = "This Mac's Dock stops syncing with your other Macs until you open DockMirror again."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { QuitSettings.confirmQuit = false }
        return .terminateNow
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

    @objc func showHelp() { HelpWindow.shared.show() }


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
