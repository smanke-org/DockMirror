import AppKit
import DockMirrorCore

/// The menu bar item and its menu, rebuilt each time it opens.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let coordinator = SyncCoordinator.shared

    private let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    override init() {
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        NotificationCenter.default.addObserver(forName: SyncCoordinator.didUpdateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    private func updateIcon() {
        let needsAttention = coordinator.lastResult?.hold.map(isAttention) ?? false
        let name = needsAttention ? "exclamationmark.triangle" : (coordinator.state.paused ? "pause.rectangle" : "dock.rectangle")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "DockMirror")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func isAttention(_ hold: SyncHold) -> Bool {
        switch hold {
        case .largeLocalRemoval, .largeIncomingRemoval: return true
        case .notSetUp, .paused: return false
        }
    }

    // MARK: - Building the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled(statusLine()))
        if let detail = detailLine() { menu.addItem(disabled(detail)) }
        if let error = coordinator.lastError { menu.addItem(disabled("⚠︎ \(error)")) }
        addHoldItems(to: menu)
        menu.addItem(.separator())

        if coordinator.state.role == nil {
            menu.addItem(item("Set Up…", #selector(openSetup)))
        } else {
            menu.addItem(item("Sync Now", #selector(syncNow), key: "s"))
            let pause = item("Pause Syncing", #selector(togglePause))
            pause.state = coordinator.state.paused ? .on : .off
            menu.addItem(pause)
            menu.addItem(item("Setup & Preview…", #selector(openSetup)))
            menu.addItem(intervalMenu())
        }
        menu.addItem(macsMenu())
        menu.addItem(restoreMenu())
        menu.addItem(.separator())

        menu.addItem(item("Preferences…", #selector(openPreferences), key: ","))
        if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(disabled("\(AppInfo.shortName) \(AppInfo.displayVersion)"))
        menu.addItem(item("Quit DockMirror", #selector(quit), key: "q"))
    }

    private func statusLine() -> String {
        if !coordinator.isCloudAvailable { return "iCloud Drive is off — not syncing" }
        switch coordinator.lastResult?.hold {
        case .notSetUp?: return "Not set up yet"
        case .paused?: return "Paused"
        default: break
        }
        guard let last = coordinator.lastSync else { return "Starting…" }
        return "Synced \(relative.localizedString(for: last, relativeTo: Date()))"
    }

    private func detailLine() -> String? {
        guard let result = coordinator.lastResult, coordinator.state.role != nil else { return nil }
        let synced = SyncEngine.managedOrder(entries: coordinator.state.entries, eligible: result.eligible).count
        let macs = coordinator.remotes.values.filter { isActive($0) }.count + 1
        return "\(synced) app\(synced == 1 ? "" : "s") synced across \(macs) Mac\(macs == 1 ? "" : "s")"
    }

    private func addHoldItems(to menu: NSMenu) {
        switch coordinator.lastResult?.hold {
        case .largeLocalRemoval(let ids)?:
            menu.addItem(.separator())
            menu.addItem(disabled("\(ids.count) apps were removed from this Dock at once:"))
            menu.addItem(disabled("   " + names(ids)))
            menu.addItem(item("Remove Them from All Macs", #selector(applyLargeRemoval)))
            menu.addItem(item("Put Them Back on This Dock", #selector(putBack)))
        case .largeIncomingRemoval(let ids)?:
            menu.addItem(.separator())
            menu.addItem(disabled("Other Macs removed \(ids.count) apps from the Dock:"))
            menu.addItem(disabled("   " + names(ids)))
            menu.addItem(item("Remove Them Here Too", #selector(applyLargeRemoval)))
            let keep = item("Keep Them on Every Mac", #selector(keepIncoming(_:)))
            keep.representedObject = ids
            menu.addItem(keep)
        default:
            break
        }
    }

    private func names(_ ids: [String]) -> String {
        let labels = DockPreferences.read().labels
        let list = ids.prefix(6).map { labels[$0] ?? coordinator.state.entries[$0]?.label ?? $0 }
        return list.joined(separator: ", ") + (ids.count > 6 ? ", …" : "")
    }

    private func isActive(_ record: DeviceRecord) -> Bool {
        record.role != nil && Date().timeIntervalSince(record.updatedAt) <= coordinator.staleAfter
    }

    private func macsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Macs", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(disabled("\(DeviceIdentity.deviceName) (this Mac) — \(roleName(coordinator.state.role))"))
        let others = coordinator.remotes.values.sorted { $0.deviceName < $1.deviceName }
        if others.isEmpty { submenu.addItem(disabled("No other Macs yet")) }
        for record in others {
            let seen = relative.localizedString(for: record.updatedAt, relativeTo: Date())
            var title = "\(record.deviceName) — \(roleName(record.role)), seen \(seen)"
            if record.paused { title += ", paused" }
            if record.role != nil && !isActive(record) { title += " (not counted)" }
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            let forget = item("Forget This Mac…", #selector(forgetMac(_:)))
            forget.representedObject = record.deviceID
            actions.addItem(forget)
            entry.submenu = actions
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("Macs not seen in \(coordinator.staleDays) days stop counting"))
        parent.submenu = submenu
        return parent
    }

    private func intervalMenu() -> NSMenuItem {
        let current = SyncSettings.checkInterval
        let parent = NSMenuItem(title: "Check Other Macs", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for interval in SyncInterval.allCases {
            if interval == .manual { submenu.addItem(.separator()) }
            let entry = item(interval.title, #selector(setInterval(_:)))
            entry.tag = interval.rawValue
            entry.state = interval == current ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled(current == .manual
            ? "Nothing syncs until you click Sync Now"
            : "Changes to this Dock still sync right away"))
        parent.submenu = submenu
        return parent
    }

    private func roleName(_ role: MacRole?) -> String {
        switch role {
        case .main?: return "main"
        case .secondary?: return "secondary"
        case nil: return "not set up"
        }
    }

    private func restoreMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Restore Dock", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let backups = DockBackups.list()
        if backups.isEmpty { submenu.addItem(disabled("No backups yet")) }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for backup in backups.prefix(15) {
            let entry = item(formatter.string(from: backup.date), #selector(restoreBackup(_:)))
            entry.representedObject = backup.url
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(item("Show Backups in Finder", #selector(showBackups)))
        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func openSetup() { SetupWindowController.shared.show() }
    @objc private func syncNow() {
        // A deliberate Sync Now also re-checks which apps are installed.
        InstalledApps.invalidate()
        coordinator.syncNow()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let interval = SyncInterval(rawValue: sender.tag) else { return }
        coordinator.setCheckInterval(interval)
    }
    @objc private func togglePause() { coordinator.setPaused(!coordinator.state.paused) }
    @objc private func applyLargeRemoval() { coordinator.applyLargeRemoval() }
    @objc private func putBack() { coordinator.putBackLocalRemoval() }

    @objc private func keepIncoming(_ sender: NSMenuItem) {
        coordinator.keepIncomingRemovals(sender.representedObject as? [String] ?? [])
    }

    @objc private func forgetMac(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let record = coordinator.remotes[id] else { return }
        guard confirm("Forget \(record.deviceName)?",
                      "Its file is removed from iCloud Drive, so it no longer limits which apps are synced. If DockMirror is still running on it, it will reappear.",
                      action: "Forget") else { return }
        coordinator.forget(deviceID: id)
    }

    @objc private func restoreBackup(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let backup = DockBackups.list().first(where: { $0.url == url }) else { return }
        let date = DateFormatter.localizedString(from: backup.date, dateStyle: .medium, timeStyle: .short)
        guard confirm("Restore the Dock from \(date)?",
                      "The whole Dock goes back to how it was then, including folders and settings. The current Dock is backed up first. Syncing is paused so the restored layout isn't immediately replaced; resume it from the menu to share it with your other Macs.",
                      action: "Restore") else { return }
        do {
            coordinator.setPaused(true)
            try DockBackups.restore(backup)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Restore failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            bringForward(alert)
            alert.runModal()
        }
    }

    @objc private func showBackups() {
        try? FileManager.default.createDirectory(at: DockBackups.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(DockBackups.folder)
    }

    @objc private func openPreferences() { PreferencesWindowController.shared.show() }

    @objc private func checkForUpdates() { UpdateController.checkForUpdates() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Confirmation

    /// Cancel is the default button, so a stray Return never confirms.
    private func confirm(_ title: String, _ text: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Cancel")
        let confirm = alert.addButton(withTitle: action)
        confirm.keyEquivalent = ""
        bringForward(alert)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func bringForward(_ alert: NSAlert) {
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }
}
