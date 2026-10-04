import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateSettings.registerDefaults()
        NSApp.mainMenu = makeMainMenu()
        if DockIconSettings.showInDock { DockIconSettings.apply() }
        statusMenu = StatusMenuController()
        SyncCoordinator.shared.start()

        if SyncCoordinator.shared.state.role == nil {
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
        let menu = NSMenu()
        let item = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// Clicking the Dock icon, or opening the app again from Finder while it
    /// runs, opens Preferences rather than doing nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PreferencesWindowController.shared.show() }
        return true
    }

    @objc func openPreferences() {
        PreferencesWindowController.shared.show()
    }

    /// Only visible while the app has a Dock icon; gives it the standard
    /// app menu, with Preferences… on ⌘, and Quit.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DockMirror",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DockMirror", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DockMirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }
}
