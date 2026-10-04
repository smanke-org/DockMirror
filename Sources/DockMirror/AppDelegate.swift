import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateSettings.registerDefaults()
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
}
