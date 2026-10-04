import AppKit
import SwiftUI

/// Whether DockMirror shows an icon in the Dock as well as in the menu bar.
/// Off by default; when on, the Dock icon's menu offers Preferences….
enum DockIconSettings {
    private static let key = "showInDock"

    static var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    @MainActor
    static func apply() {
        if showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            // Going back to .accessory while the app is active and showing a
            // window doesn't take if done synchronously; a runloop turn later does.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
                // Dropping out of the Dock deactivates the app; keep Preferences in front.
                PreferencesWindowController.shared.bringForwardIfOpen()
            }
        }
    }
}

@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView()))
            window.title = "DockMirror Preferences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func bringForwardIfOpen() {
        guard let window, window.isVisible else { return }
        // Leaving the Dock deactivates the app, and macOS then refuses a plain
        // activate; ordering the window front regardless keeps it in view.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }
}

private struct PreferencesView: View {
    @State private var interval = SyncSettings.checkInterval
    @State private var showInDock = DockIconSettings.showInDock
    @State private var launchAtLogin = LaunchAtLoginController.isEnabled
    @State private var checkForUpdates = UpdateSettings.checkForUpdatesAtLaunch

    var body: some View {
        Form {
            Section {
                Picker("Check other Macs", selection: $interval) {
                    ForEach(SyncInterval.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(interval == .manual
                     ? "Nothing syncs until you choose Sync Now from the menu."
                     : "Changes to this Dock are shared right away. A longer interval means other Macs' changes arrive here later, with less work in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Sync")
            }

            Section {
                Toggle("Show in Dock", isOn: $showInDock)
                Text("Adds a Dock icon whose menu opens these preferences. DockMirror stays in the menu bar either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Toggle("Check for Updates at Launch", isOn: $checkForUpdates)
            } header: {
                Text("General")
            }

            Text("\(AppInfo.shortName) \(AppInfo.displayVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        // didSet on @State doesn't fire through a binding; onChange does.
        .onChange(of: interval) { SyncCoordinator.shared.setCheckInterval($0) }
        .onChange(of: showInDock) {
            DockIconSettings.showInDock = $0
            DockIconSettings.apply()
        }
        .onChange(of: launchAtLogin) { enabled in
            if !LaunchAtLoginController.setEnabled(enabled) {
                launchAtLogin = LaunchAtLoginController.isEnabled
            }
        }
        .onChange(of: checkForUpdates) { UpdateSettings.checkForUpdatesAtLaunch = $0 }
    }
}
