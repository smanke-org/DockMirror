import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?

    /// The width Settings is laid out for, and the smallest the window can be dragged to.
    static let width: CGFloat = 440
    static let minimumSize = NSSize(width: width, height: 280)

    /// The content size the user last dragged the window to (per Mac, not synced), or nil
    /// while they haven't: then Settings opens at its own height.
    static var chosenSize: NSSize? {
        get { UserDefaults.standard.string(forKey: "settings.contentSize").map(NSSizeFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromSize), forKey: "settings.contentSize") }
    }

    func show() {
        if window == nil {
            // Sized here, not by SwiftUI: open at the content's natural height but never taller
            // than the screen (a MacBook Air can't fit it all), and scroll whatever is cut off.
            // Letting SwiftUI size a window that AppKit then clamps loops until AppKit aborts.
            // The content fills whatever size the user drags the window to.
            let hosting = NSHostingView(rootView: ScrollView(.vertical) { PreferencesView() }
                .frame(minWidth: Self.width, maxWidth: .infinity, maxHeight: .infinity))
            hosting.sizingOptions = []
            // In a plain container: a window whose content is the SwiftUI view itself resets
            // the minimum size to zero as soon as it's shown.
            let container = NSViewController()
            container.view = NSView(frame: NSRect(origin: .zero, size: Self.minimumSize))
            hosting.frame = container.view.bounds
            hosting.autoresizingMask = [.width, .height]
            container.view.addSubview(hosting)
            let window = NSWindow(contentViewController: container)
            window.title = "DockMirror Settings"
            // Resizable as well as scrolling: drag it bigger to see more at once.
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.contentMinSize = Self.minimumSize
            window.delegate = self
            window.setContentSize(fittingSize(on: NSScreen.main))
            window.center()
            self.window = window
        } else if let window, !window.isVisible {
            // Re-measured each time it opens, as what it shows changes.
            window.setContentSize(fittingSize(on: window.screen ?? NSScreen.main))
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // After an update whose notes weren't seen yet.
        if let window { WhatsNew.shared.present(on: window) }
    }

    /// This version's release notes, when asked for from Settings.
    func showWhatsNew() {
        if let window { WhatsNew.shared.present(on: window, asked: true) }
    }

    /// The natural height measured at the fixed width, no taller than the screen; once the
    /// user has dragged the window to a size, that size instead (still capped to the screen).
    private func fittingSize(on screen: NSScreen?) -> NSSize {
        let available = max((screen?.visibleFrame.height ?? 800) - 80, Self.minimumSize.height)
        if let chosen = Self.chosenSize {
            return NSSize(width: max(chosen.width, Self.minimumSize.width),
                          height: min(max(chosen.height, Self.minimumSize.height), available))
        }
        let natural = NSHostingView(rootView: PreferencesView().frame(width: Self.width)).fittingSize
        return NSSize(width: Self.width, height: min(max(natural.height, Self.minimumSize.height), available))
    }

    /// A size the user dragged to is kept, and used next time.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        Self.chosenSize = window.contentRect(forFrameRect: window.frame).size
    }

    var visibleWindow: NSWindow? { window?.isVisible == true ? window : nil }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

private struct PreferencesView: View {
    @State private var interval = SyncSettings.checkInterval
    @State private var showInDock = AppPresence.showInDock
    @State private var showInMenuBar = AppPresence.showInMenuBar
    @State private var launchAtLogin = LaunchAtLoginController.isEnabled
    @State private var confirmQuit = QuitSettings.confirmQuit
    @ObservedObject private var hub = MenuHub.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Toggle("Ask before quitting", isOn: $confirmQuit)
                    .help("Quitting DockMirror asks first, so a stray ⌘Q doesn't stop the Dock syncing.")
                Toggle("Show in Dock", isOn: $showInDock)
                    .help("Adds a Dock icon whose right-click menu opens these settings.")
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Toggle("Put in ToolHUD’s menu while ToolHUD is running", isOn: $hub.foldIntoToolHUD)
                    .help("ToolHUD shows this menu as a submenu of its own, and DockMirror’s icon leaves the menu bar until ToolHUD quits.")
                if !showInDock && !showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "DockMirror", settingsName: "Settings"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("General")
            }

            AppearanceSection(appName: "DockMirror")
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

            SyncUpdateSections()

            // The version, with the round Help button in the corner, as macOS does.
            HStack {
                Text("\(AppInfo.shortName) \(AppInfo.displayVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HelpButton(topic: "getting-started").fixedSize()
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: PreferencesWindowController.width, maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        // didSet on @State doesn't fire through a binding; onChange does.
        .onChange(of: interval) { SyncCoordinator.shared.setCheckInterval($0) }
        .onChange(of: showInDock) {
            AppPresence.showInDock = $0
            AppPresence.applyDock(keepInFront: PreferencesWindowController.shared.visibleWindow)
        }
        .onChange(of: showInMenuBar) { AppPresence.showInMenuBar = $0 }
        .onChange(of: confirmQuit) { QuitSettings.confirmQuit = $0 }
        .onChange(of: launchAtLogin) { enabled in
            if !LaunchAtLoginController.setEnabled(enabled) {
                launchAtLogin = LaunchAtLoginController.isEnabled
            }
        }
    }
}
