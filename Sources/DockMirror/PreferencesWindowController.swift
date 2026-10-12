import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView()))
            window.title = "DockMirror Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var visibleWindow: NSWindow? { window?.isVisible == true ? window : nil }
}

private struct PreferencesView: View {
    @State private var interval = SyncSettings.checkInterval
    @State private var showInDock = AppPresence.showInDock
    @State private var showInMenuBar = AppPresence.showInMenuBar
    @State private var launchAtLogin = LaunchAtLoginController.isEnabled

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
                    .help("Adds a Dock icon whose right-click menu opens these settings.")
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                if !showInDock && !showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "DockMirror", settingsName: "Settings"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Launch at Login", isOn: $launchAtLogin)
            } header: {
                Text("General")
            }

            SyncUpdateSections()

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
            AppPresence.showInDock = $0
            AppPresence.applyDock(keepInFront: PreferencesWindowController.shared.visibleWindow)
        }
        .onChange(of: showInMenuBar) { AppPresence.showInMenuBar = $0 }
        .onChange(of: launchAtLogin) { enabled in
            if !LaunchAtLoginController.setEnabled(enabled) {
                launchAtLogin = LaunchAtLoginController.isEnabled
            }
        }
    }
}
