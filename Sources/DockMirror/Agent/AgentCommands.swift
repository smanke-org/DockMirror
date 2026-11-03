import AppKit
import DockMirrorCore

/// Everything an agent can do in DockMirror. Add a command here and the CLI, `help`, and the
/// MCP tools all get it. Each `run` is on the main actor and calls the same code as the menu bar
/// menu, the setup window and the dockmirror:// links.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show whether this Mac is set up (`role`: main, secondary or none), paused, when it last synced, how many apps are synced across how many Macs, the last error, and any big removal waiting for an answer (`hold`).",
                     example: "dockmirror status --json", readOnly: true) { _ in
            status()
        },

        // MARK: Reading

        AgentCommand(name: "dock list", summary: "List this Mac's Dock apps in order, as DockMirror reads them. Returns `apps` (position, name, bundleID, synced: whether it is kept in the same place on every Mac), `total`, and `syncedOrder` (the agreed order of the synced apps). Spacers show as kind spacer.",
                     params: [limitParam, offsetParam],
                     example: "dockmirror dock list --json", readOnly: true) { args in
            let coordinator = SyncCoordinator.shared
            let snapshot = DockPreferences.read()
            let labels = snapshot.labels
            let eligible = coordinator.lastResult?.eligible
            let order = eligible.map { SyncEngine.managedOrder(entries: coordinator.state.entries, eligible: $0) } ?? []
            let synced = Set(order)
            let rows: [JSONObject] = snapshot.slots.enumerated().map { index, slot in
                guard let id = slot.bundleID else {
                    return ["position": index + 1, "kind": "spacer", "name": "(spacer)"]
                }
                var row: JSONObject = ["position": index + 1, "kind": "app", "bundleID": id,
                                       "name": labels[id] ?? coordinator.state.entries[id]?.label ?? id]
                // Unknown until a pass has worked out which apps every Mac has.
                if eligible != nil { row["synced"] = synced.contains(id) }
                return row
            }
            var result = try page(rows, args, key: "apps", defaultLimit: 100)
            result["syncedOrder"] = order
            if eligible == nil { result["note"] = "no sync has run yet, so which apps are synced isn't known. Run `dockmirror sync now`" }
            return result
        },
        AgentCommand(name: "macs list", summary: "List the Macs in the sync, this one first. Returns `macs` (id, name, role, paused, lastSeen in UTC, counted: whether it limits which apps are synced, appVersion, dockApps) and `total`.",
                     example: "dockmirror macs list --json", readOnly: true) { _ in
            let coordinator = SyncCoordinator.shared
            var this: JSONObject = ["id": short(DeviceIdentity.deviceID), "name": DeviceIdentity.deviceName, "thisMac": true,
                                    "role": roleName(coordinator.state.role), "paused": coordinator.state.paused,
                                    "appVersion": AppInfo.version, "counted": coordinator.state.role != nil]
            this["lastSeen"] = coordinator.lastSync.map(JSON.date) ?? NSNull()
            let others = coordinator.remotes.values.sorted { $0.deviceName < $1.deviceName }.map { record -> JSONObject in
                ["id": short(record.deviceID), "name": record.deviceName, "thisMac": false, "role": roleName(record.role),
                 "paused": record.paused, "lastSeen": JSON.date(record.updatedAt), "counted": coordinator.isCounted(record),
                 "appVersion": record.appVersion, "dockApps": record.dock.count]
            }
            return ["macs": [this] + others, "total": others.count + 1,
                    "staleDays": coordinator.staleDays]
        },
        AgentCommand(name: "backups list", summary: "List the Dock backups DockMirror took before each change, newest first. Returns `backups` (id, date in UTC, path), `total` and `nextOffset` when there are more.",
                     params: [limitParam, offsetParam],
                     example: "dockmirror backups list --limit 5 --json", readOnly: true) { args in
            let rows = DockBackups.list().map { backup -> JSONObject in
                ["id": backupID(backup), "date": JSON.date(backup.date), "path": backup.url.path]
            }
            return try page(rows, args, key: "backups", defaultLimit: 50)
        },
        AgentCommand(name: "setup preview", summary: "Show what this Dock would become if this Mac started syncing in a role, as the setup window does. Changes nothing. Returns `apps` (the Dock after syncing, each marked kept or added), `removed`, and `otherMacs`.",
                     params: [roleParam],
                     example: "dockmirror setup preview --role secondary --json", readOnly: true) { args in
            try preview(role: try role(args))
        },

        // MARK: Syncing

        AgentCommand(name: "sync now", summary: "Sync this Mac with the others right away, as Sync Now in the menu does (it also re-checks which apps are installed). Waits for the pass and returns the status. Other Macs' changes can rearrange this Dock.",
                     example: "dockmirror sync now --json") { _ in
            try requireSetUp()
            InstalledApps.invalidate()
            return try await syncAndWait { SyncCoordinator.shared.syncNow() }
        },
        AgentCommand(name: "sync pause", summary: "Pause syncing this Mac, as Pause Syncing in the menu does. Edits made meanwhile are picked up on resume.",
                     example: "dockmirror sync pause --json") { _ in
            try await setPaused(true)
        },
        AgentCommand(name: "sync resume", summary: "Resume syncing this Mac. It syncs straight away, so other Macs' changes made meanwhile can rearrange this Dock.",
                     example: "dockmirror sync resume --json") { _ in
            try await setPaused(false)
        },
        AgentCommand(name: "setup start", summary: "Start syncing this Mac in a role, as Start Syncing in the setup window does. This Dock is rewritten to the preview and the Dock restarts; a main Mac's layout becomes the starting layout for every Mac. Without --yes it only shows the preview.",
                     params: [roleParam],
                     example: "dockmirror setup start --role secondary --yes --json", destructive: true) { args in
            let role = try role(args)
            let coordinator = SyncCoordinator.shared
            if let current = coordinator.state.role {
                throw AgentError.invalid("this Mac is already syncing as the \(roleName(current)) Mac. To change its role, run `dockmirror setup stop` first")
            }
            guard args.confirmed else {
                var result = try preview(role: role)
                result["hint"] = "add --yes (over MCP, set yes to true) to start syncing as the \(roleName(role)) Mac. This Dock becomes the list above and the Dock restarts"
                    + (role == .main ? "; its layout becomes the starting layout for every Mac" : "")
                return result
            }
            return try await syncAndWait { coordinator.setUp(role: role) }
        },
        AgentCommand(name: "setup stop", summary: "Stop syncing this Mac, as Stop Syncing This Mac in the setup window does. The Dock stays as it is; `dockmirror setup start` joins again.",
                     example: "dockmirror setup stop --json") { _ in
            let coordinator = SyncCoordinator.shared
            guard coordinator.state.role != nil else { return ["changed": false, "role": "none"] }
            var result = try await syncAndWait { coordinator.leave() }
            result["changed"] = true
            return result
        },
        AgentCommand(name: "removal apply", summary: "Go ahead with a big removal DockMirror is holding (see `hold` in `dockmirror status`): Remove Them from All Macs, or Remove Them Here Too. Without --yes it only shows which apps would go.",
                     example: "dockmirror removal apply --yes --json", destructive: true) { args in
            let held = try heldRemoval()
            guard args.confirmed else {
                return ["wouldRemove": apps(held.ids), "from": held.local ? "every Mac" : "this Mac's Dock",
                        "hint": "add --yes (over MCP, set yes to true) to remove them" + (held.local ? " from every Mac's Dock" : " from this Dock") + ". The Dock restarts"]
            }
            return try await syncAndWait { SyncCoordinator.shared.applyLargeRemoval() }
        },
        AgentCommand(name: "removal keep", summary: "Turn down a big removal DockMirror is holding: Put Them Back on This Dock (removed here), or Keep Them on Every Mac (removed on another Mac).",
                     example: "dockmirror removal keep --json") { _ in
            let held = try heldRemoval()
            let coordinator = SyncCoordinator.shared
            var result = try await syncAndWait {
                if held.local { coordinator.putBackLocalRemoval() } else { coordinator.keepIncomingRemovals(held.ids) }
            }
            result["kept"] = apps(held.ids)
            return result
        },
        AgentCommand(name: "macs forget", summary: "Forget another Mac, as Forget This Mac… in the Macs menu does: its file is removed from iCloud Drive, so it stops limiting which apps are synced. A Mac still running DockMirror comes back. Without --yes it only shows which Mac.",
                     params: [.init(name: "id", required: true, positional: true, help: "the Mac's id from `dockmirror macs list` (any unique start)")],
                     example: "dockmirror macs forget 3f2a9c1e --yes --json", destructive: true) { args in
            let coordinator = SyncCoordinator.shared
            let key = try args.required("id").lowercased()
            if DeviceIdentity.deviceID.hasPrefix(key) {
                throw AgentError.invalid("that is this Mac. To stop syncing it, run `dockmirror setup stop`")
            }
            let matches = coordinator.remotes.values.filter { $0.deviceID.hasPrefix(key) }
            guard matches.count == 1, let record = matches.first else {
                if matches.isEmpty { throw AgentError.notFound("no other Mac with id \(key). Run `dockmirror macs list`") }
                throw AgentError.invalid("\(matches.count) Macs have ids starting \(key). Give more of the id")
            }
            let summary: JSONObject = ["id": short(record.deviceID), "name": record.deviceName,
                                       "lastSeen": JSON.date(record.updatedAt)]
            guard args.confirmed else {
                return ["wouldForget": summary,
                        "hint": "add --yes (over MCP, set yes to true) to forget it. Its file is removed from iCloud Drive; if DockMirror still runs on it, it comes back"]
            }
            guard SyncFolder.url() != nil else { throw AgentError.invalid("iCloud Drive is off, so there is nothing to remove") }
            coordinator.forget(deviceID: record.deviceID)
            return ["forgot": summary]
        },
        AgentCommand(name: "backups restore", summary: "Put the whole Dock back as it was in a backup, as Restore Dock in the menu does: apps, folders and Dock settings. The current Dock is backed up first, syncing is paused, and the Dock restarts. Without --yes it only shows which backup.",
                     params: [.init(name: "id", required: true, positional: true, help: "the backup's id from `dockmirror backups list` (any unique start), or latest")],
                     example: "dockmirror backups restore 2026-11-03T09-41-12 --yes --json", destructive: true) { args in
            let key = try args.required("id")
            let backups = DockBackups.list()
            let matches = key.lowercased() == "latest" ? Array(backups.prefix(1)) : backups.filter { backupID($0).hasPrefix(key) }
            guard matches.count == 1, let backup = matches.first else {
                if matches.isEmpty { throw AgentError.notFound("no backup \(key). Run `dockmirror backups list`") }
                throw AgentError.invalid("\(matches.count) backups start \(key). Give more of the id")
            }
            let summary: JSONObject = ["id": backupID(backup), "date": JSON.date(backup.date)]
            guard args.confirmed else {
                return ["wouldRestore": summary,
                        "hint": "add --yes (over MCP, set yes to true) to restore it. The whole Dock goes back to then (the current one is backed up first), syncing is paused, and the Dock restarts. Resume with `dockmirror sync resume` to share it"]
            }
            if AgentSocket.isTestRun { throw AgentError.invalid("a test copy never changes the Dock") }
            do {
                try SyncCoordinator.shared.restore(backup)
            } catch {
                throw AgentError.invalid("the backup could not be restored: \(error.localizedDescription)")
            }
            return ["restored": summary, "paused": true, "next": "run `dockmirror sync resume` to share the restored layout"]
        },

        // MARK: Windows

        AgentCommand(name: "open", summary: "Bring up a DockMirror window: setup (Setup & Preview), settings, or help.",
                     params: [.init(name: "page", required: true, positional: true, help: "setup, settings or help")],
                     example: "dockmirror open setup --json") { args in
            switch try args.required("page").lowercased() {
            case "setup": SetupWindowController.shared.show()
            case "settings":
                // Settings are the installed app's own: a test copy shares them.
                if AgentSocket.isTestRun { throw AgentError.invalid("a test copy doesn't open Settings, which it shares with the installed app") }
                PreferencesWindowController.shared.show()
            case "help": HelpWindow.shared.show()
            default: throw AgentError.usage("the page must be setup, settings or help")
            }
            return ["open": try args.required("page").lowercased()]
        },
    ]

    // MARK: Params

    static let roleParam = AgentCommand.Param(name: "role", required: true,
                                              help: "main (its Dock is the starting layout) or secondary (adopts the main Mac's layout)")
    static let limitParam = AgentCommand.Param(name: "limit", kind: .integer, help: "at most this many")
    static let offsetParam = AgentCommand.Param(name: "offset", kind: .integer, help: "skip this many, for the next page")

    static func role(_ args: Args) throws -> MacRole {
        let raw = try args.required("role").lowercased()
        guard let role = MacRole(rawValue: raw) else { throw AgentError.usage("--role must be main or secondary, not \"\(raw)\"") }
        return role
    }

    // MARK: Results

    static func short(_ id: String) -> String { String(id.prefix(8)) }

    static func roleName(_ role: MacRole?) -> String { role?.rawValue ?? "none" }

    static func backupID(_ backup: DockBackups.Backup) -> String {
        String(backup.url.deletingPathExtension().lastPathComponent.dropFirst("dock-".count))
    }

    /// Bundle IDs with the names the Dock shows for them.
    @MainActor
    static func apps(_ ids: [String]) -> [JSONObject] {
        let labels = DockPreferences.read().labels
        return ids.map { ["bundleID": $0, "name": labels[$0] ?? SyncCoordinator.shared.state.entries[$0]?.label ?? $0] }
    }

    @MainActor
    static func status() -> JSONObject {
        let coordinator = SyncCoordinator.shared
        var result: JSONObject = ["app": AppInfo.displayName, "version": AppInfo.version, "testCopy": AgentSocket.isTestRun,
                                  "role": roleName(coordinator.state.role), "paused": coordinator.state.paused,
                                  "iCloudDrive": SyncFolder.url() != nil, "dryRun": coordinator.dryRun,
                                  "checkInterval": SyncSettings.checkInterval.title,
                                  "otherMacs": coordinator.remotes.count,
                                  "countedMacs": coordinator.remotes.values.filter(coordinator.isCounted).count + 1]
        result["lastSync"] = coordinator.lastSync.map(JSON.date) ?? NSNull()
        result["lastError"] = coordinator.lastError ?? NSNull()
        if let last = coordinator.lastResult {
            result["syncedApps"] = SyncEngine.managedOrder(entries: coordinator.state.entries, eligible: last.eligible).count
        }
        switch coordinator.lastResult?.hold {
        case .largeLocalRemoval(let ids)?:
            result["hold"] = ["kind": "removed-here", "apps": apps(ids),
                              "next": "ask the person: `dockmirror removal apply` removes them from every Mac, `dockmirror removal keep` puts them back here"] as JSONObject
        case .largeIncomingRemoval(let ids)?:
            result["hold"] = ["kind": "removed-elsewhere", "apps": apps(ids),
                              "next": "ask the person: `dockmirror removal apply` removes them here too, `dockmirror removal keep` keeps them on every Mac"] as JSONObject
        case .notSetUp?, .paused?, nil:
            result["hold"] = NSNull()
        }
        return result
    }

    @MainActor
    static func preview(role: MacRole) throws -> JSONObject {
        let coordinator = SyncCoordinator.shared
        let preview = coordinator.preview(role: role)
        let current = Set(preview.current.compactMap { $0 })
        let planned = Set(preview.planned.compactMap { $0 })
        func name(_ id: String) -> String { preview.labels[id] ?? id }
        let rows: [JSONObject] = preview.planned.enumerated().map { index, id in
            guard let id else { return ["position": index + 1, "kind": "spacer", "name": "(spacer)", "change": "kept"] }
            return ["position": index + 1, "kind": "app", "bundleID": id, "name": name(id),
                    "change": current.contains(id) ? "kept" : "added"]
        }
        let removed = preview.current.compactMap { $0 }.filter { !planned.contains($0) }
            .map { ["bundleID": $0, "name": name($0)] as JSONObject }
        return ["role": roleName(role), "apps": rows, "removed": removed,
                "otherMacs": coordinator.remotes.values.filter { $0.role != nil }.count]
    }

    static func page(_ all: [JSONObject], _ args: Args, key: String, defaultLimit: Int) throws -> JSONObject {
        let limit = try args.int("limit", default: defaultLimit)
        let offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be 1 or more, and --offset 0 or more") }
        let slice = all.dropFirst(offset).prefix(limit)
        var result: JSONObject = [key: Array(slice), "total": all.count]
        if offset + slice.count < all.count { result["nextOffset"] = offset + slice.count }
        return result
    }

    // MARK: Actions

    @MainActor
    static func requireSetUp() throws {
        guard SyncCoordinator.shared.state.role != nil else {
            throw AgentError.invalid("this Mac isn't set up yet. See `dockmirror setup preview --role secondary`, then `dockmirror setup start`")
        }
    }

    @MainActor
    static func setPaused(_ paused: Bool) async throws -> JSONObject {
        try requireSetUp()
        let coordinator = SyncCoordinator.shared
        guard coordinator.state.paused != paused else { return ["paused": paused, "changed": false] }
        var result = try await syncAndWait { coordinator.setPaused(paused) }
        result["changed"] = true
        return result
    }

    /// A big removal on hold: removed on this Mac (`local`) or coming from another one.
    @MainActor
    static func heldRemoval() throws -> (ids: [String], local: Bool) {
        switch SyncCoordinator.shared.lastResult?.hold {
        case .largeLocalRemoval(let ids)?: return (ids, true)
        case .largeIncomingRemoval(let ids)?: return (ids, false)
        default: throw AgentError.invalid("no big removal is waiting for an answer. `dockmirror status` shows one under hold")
        }
    }

    /// Runs an action that starts a sync pass, then waits for that pass to finish (up to a
    /// minute) and returns the status.
    @MainActor
    static func syncAndWait(_ action: () -> Void) async throws -> JSONObject {
        let coordinator = SyncCoordinator.shared
        let before = coordinator.lastSync
        action()
        for _ in 0..<600 {
            if coordinator.lastSync != before { return status() }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AgentError.busy("the sync is taking longer than a minute (iCloud Drive may be slow). Check `dockmirror status` in a moment")
    }
}
