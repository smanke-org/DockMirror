import AppKit
import CoreServices
import DockMirrorCore

/// Runs sync passes: reads this Dock and the other Macs' files, lets
/// `SyncEngine` decide, then writes the Dock and publishes this Mac's file.
@MainActor
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    static let didUpdateNotification = Notification.Name("SyncCoordinator.didUpdate")

    private(set) var state: LocalState
    private(set) var remotes: [String: DeviceRecord] = [:]
    private(set) var lastResult: CycleResult?
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isCloudAvailable = false

    /// A Mac not heard from in this long stops narrowing the synced apps.
    var staleAfter: TimeInterval { TimeInterval(staleDays) * 86_400 }
    var staleDays: Int {
        get { max(1, UserDefaults.standard.object(forKey: Keys.staleDays) as? Int ?? 30) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.staleDays) }
    }

    /// `DOCKMIRROR_DRY_RUN=1` plans and publishes but never writes the Dock.
    private let dryRun = ProcessInfo.processInfo.environment["DOCKMIRROR_DRY_RUN"] == "1"

    private var running = false
    private var rerunRequested = false
    private var debounce: Timer?
    private var timer: Timer?
    private var eventStream: FSEventStreamRef?
    private var lastPublished: DeviceRecord?
    private var lastPublishedAt: Date?
    /// Apps whose new tile the Dock didn't keep. After two tries an app is
    /// treated as not installed here, so a tile the Dock rejects is never
    /// mistaken for the user unpinning it.
    private var insertFailures: [String: Int] = [:]
    private var pendingInserts: Set<String> = []
    private var lastInputs: (snapshot: DockPreferences.Snapshot, installed: Set<String>)?

    private enum Keys {
        static let state = "sync.state"
        static let staleDays = "sync.staleDays"
        static let remoteCache = "sync.remoteRecords"
        static let diagnostics = "diagnostics"
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.state),
           let saved = try? SyncFolder.decoder.decode(LocalState.self, from: data) {
            state = saved
        } else {
            state = LocalState()
        }
        if let data = UserDefaults.standard.data(forKey: Keys.remoteCache),
           let cached = try? SyncFolder.decoder.decode([String: DeviceRecord].self, from: data) {
            remotes = cached
        }
    }

    // MARK: - Lifecycle

    func start() {
        watchDockPreferences()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSync(after: 5) }
        }
        syncNow()
    }

    /// The Dock saves its preferences on every change, and while an app is
    /// being dragged it can save more than once. Waiting for a few quiet
    /// seconds means a sync never acts on a half-finished rearrangement.
    func scheduleSync(after delay: TimeInterval = 3) {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
    }

    private func watchDockPreferences() {
        let folder = DockPreferences.plistURL.deletingLastPathComponent().path as CFString
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            guard names.prefix(count).contains(where: { $0.hasSuffix("/com.apple.dock.plist") }) else { return }
            let coordinator = Unmanaged<SyncCoordinator>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in coordinator.scheduleSync() }
        }
        // UseCFTypes makes `paths` a CFArray of strings; without it they arrive
        // as a C array, and bridging that to NSArray crashes.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
            NSLog("DockMirror: couldn't watch the Dock preferences; relying on the timer")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    // MARK: - User actions

    func setUp(role: MacRole) {
        state.role = role
        state.paused = false
        // A fresh baseline: a main Mac re-seeds from its Dock, a secondary one
        // records nothing until the user next changes it.
        state.lastObserved = nil
        save()
        // The user just approved this exact result in the preview.
        syncNow(allowLargeRemoval: true)
    }

    func leave() {
        state.role = nil
        state.lastObserved = nil
        save()
        syncNow()
    }

    func setPaused(_ paused: Bool) {
        state.paused = paused
        save()
        syncNow()
    }

    /// Confirms a held mass removal.
    func applyLargeRemoval() {
        syncNow(allowLargeRemoval: true)
    }

    /// Declines a held removal of apps from this Dock: they go back, here.
    func putBackLocalRemoval() {
        // Accepting the current Dock as the baseline without recording it means
        // the apps are still pinned, so the plan restores them.
        state.lastObserved = DockPreferences.read().slots.compactMap(\.bundleID)
        save()
        syncNow()
    }

    /// Declines a held removal coming from another Mac: re-pins the apps,
    /// which restores them on every Mac.
    func keepIncomingRemovals(_ ids: [String]) {
        let now = Date()
        for id in ids {
            guard let entry = state.entries[id] else { continue }
            state.entries[id] = DockEntry(pinned: true, key: entry.key, updatedAt: now,
                                          by: DeviceIdentity.deviceID, label: entry.label)
        }
        save()
        syncNow()
    }

    func forget(deviceID: String) {
        guard let folder = SyncFolder.url() else { return }
        try? SyncFolder.remove(deviceID: deviceID, in: folder)
        remotes[deviceID] = nil
        cacheRemotes()
        syncNow()
    }

    /// What this Dock would become with `role`, for the setup window.
    func preview(role: MacRole) -> (current: [String?], planned: [String?], labels: [String: String]) {
        let snapshot = DockPreferences.read()
        let installed = lastInputs?.installed ?? InstalledApps.installed(among: candidates(snapshot: snapshot))
        var hypothetical = LocalState(role: role)
        hypothetical.entries = state.entries
        let input = makeInput(snapshot: snapshot, installed: installed, allowLargeRemoval: true)
        // A first pass is exactly what setup runs: it seeds (for a main Mac)
        // and plans the Dock that results.
        let result = SyncEngine.runCycle(state: hypothetical, input: input)
        var labels = snapshot.labels
        for (id, entry) in result.state.entries where labels[id] == nil { labels[id] = entry.label }
        return (snapshot.slots.map(\.bundleID), SyncEngine.bundleIDs(of: result.plan, current: snapshot.slots), labels)
    }

    // MARK: - Sync pass

    func syncNow(allowLargeRemoval: Bool = false) {
        guard !running else {
            rerunRequested = true
            return
        }
        running = true
        let folder = SyncFolder.url()
        let ownID = DeviceIdentity.deviceID

        Task {
            // iCloud file coordination can block, so it stays off the main thread.
            let fetched = await Task.detached(priority: .utility) {
                folder.map { SyncFolder.readOthers(in: $0, excluding: ownID) }
            }.value
            self.runPass(folder: folder, fetched: fetched, allowLargeRemoval: allowLargeRemoval)
            self.running = false
            if self.rerunRequested {
                self.rerunRequested = false
                self.scheduleSync(after: 1)
            }
        }
    }

    private func runPass(folder: URL?, fetched: (records: [DeviceRecord], downloading: Set<String>)?,
                         allowLargeRemoval: Bool) {
        isCloudAvailable = folder != nil
        if let fetched {
            var fresh = Dictionary(fetched.records.map { ($0.deviceID, $0) }, uniquingKeysWith: { a, b in
                a.updatedAt > b.updatedAt ? a : b
            })
            // Keep the last copy of a file iCloud is still downloading. A Mac
            // whose file is gone entirely (forgotten) drops out.
            for id in fetched.downloading where fresh[id] == nil { fresh[id] = remotes[id] }
            remotes = fresh
            cacheRemotes()
        }

        let snapshot = DockPreferences.read()
        trackInsertFailures(in: snapshot)
        let installed = InstalledApps.installed(among: candidates(snapshot: snapshot))
            .filter { (insertFailures[$0] ?? 0) < 2 }
        lastInputs = (snapshot, installed)

        let input = makeInput(snapshot: snapshot, installed: installed, allowLargeRemoval: allowLargeRemoval)
        var result = SyncEngine.runCycle(state: state, input: input)
        state = result.state
        lastError = nil

        var dockApps = snapshot.slots.compactMap(\.bundleID)
        if result.needsWrite {
            if dryRun {
                NSLog("DockMirror: dry run, would write: \(result.plannedApps)")
            } else {
                do {
                    let labels = snapshot.labels.merging(state.entries.compactMapValues(\.label)) { a, _ in a }
                    guard let tiles = DockPreferences.tiles(for: result.plan, from: snapshot, labels: labels) else {
                        throw NSError(domain: "DockMirror", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "An app to add to the Dock could not be found."])
                    }
                    try DockBackups.create()
                    try DockPreferences.write(tiles, expecting: snapshot)
                    state.lastObserved = result.plannedApps
                    dockApps = result.plannedApps
                    pendingInserts = Set(result.plan.compactMap { slot -> String? in
                        if case .insert(let id) = slot { return id }
                        return nil
                    })
                } catch DockPreferences.WriteError.changedUnderneath {
                    // The user is editing the Dock; their edit is picked up next pass.
                    scheduleSync()
                } catch {
                    lastError = error.localizedDescription
                    NSLog("DockMirror: couldn't update the Dock: \(error.localizedDescription)")
                }
            }
        }
        result.state = state
        lastResult = result
        lastSync = Date()
        save()
        publish(folder: folder, installed: installed, dock: dockApps)
        recordDiagnostics()
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    private func makeInput(snapshot: DockPreferences.Snapshot, installed: Set<String>,
                           allowLargeRemoval: Bool) -> CycleInput {
        CycleInput(dock: snapshot.slots, labels: snapshot.labels, installed: installed,
                   remotes: Array(remotes.values), now: Date(), device: DeviceIdentity.deviceID,
                   staleAfter: staleAfter, allowLargeRemoval: allowLargeRemoval)
    }

    /// Every app any Mac knows about, so each Mac reports whether it has them.
    private func candidates(snapshot: DockPreferences.Snapshot) -> Set<String> {
        var ids = Set(snapshot.slots.compactMap(\.bundleID))
        ids.formUnion(state.entries.keys)
        for remote in remotes.values {
            ids.formUnion(remote.entries.keys)
            ids.formUnion(remote.dock)
        }
        return ids
    }

    /// If the Dock dropped a tile we just added, don't let the next pass read
    /// that as the user unpinning it: put it back in the baseline as missing
    /// from the start, and count the failure.
    private func trackInsertFailures(in snapshot: DockPreferences.Snapshot) {
        guard !pendingInserts.isEmpty else { return }
        let present = Set(snapshot.slots.compactMap(\.bundleID))
        for id in pendingInserts {
            if present.contains(id) {
                insertFailures[id] = nil
            } else {
                insertFailures[id, default: 0] += 1
                state.lastObserved?.removeAll { $0 == id }
                NSLog("DockMirror: the Dock didn't keep \(id) (attempt \(insertFailures[id]!))")
            }
        }
        pendingInserts = []
    }

    // MARK: - Publishing

    private func publish(folder: URL?, installed: Set<String>, dock: [String]) {
        guard let folder else { return }
        let record = DeviceRecord(deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName,
                                  appVersion: AppInfo.version, updatedAt: Date(), role: state.role,
                                  paused: state.paused, installed: installed.sorted(), dock: dock,
                                  entries: state.entries)
        // Unchanged files are still rewritten hourly, so other Macs see this
        // one as alive and keep counting it.
        let fresh = lastPublishedAt.map { Date().timeIntervalSince($0) < 3600 } ?? false
        guard record.content != lastPublished?.content || !fresh else { return }
        lastPublished = record
        lastPublishedAt = Date()
        Task.detached(priority: .utility) {
            do {
                try SyncFolder.write(record, to: folder)
            } catch {
                NSLog("DockMirror: couldn't publish to iCloud Drive: \(error.localizedDescription)")
                await MainActor.run { self.lastPublished = nil }
            }
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? SyncFolder.encoder.encode(state) {
            UserDefaults.standard.set(data, forKey: Keys.state)
        }
    }

    private func cacheRemotes() {
        if let data = try? SyncFolder.encoder.encode(remotes) {
            UserDefaults.standard.set(data, forKey: Keys.remoteCache)
        }
    }

    /// Readable from outside the app with `defaults read com.smanke.DockMirror diagnostics`.
    private func recordDiagnostics() {
        var info: [String: Any] = [
            "version": AppInfo.version,
            "deviceID": DeviceIdentity.deviceID,
            "role": state.role?.rawValue ?? "none",
            "paused": state.paused,
            "dryRun": dryRun,
            "cloudAvailable": isCloudAvailable,
            "otherMacs": remotes.count,
            "lastSync": lastSync ?? Date(),
            "lastError": lastError ?? "",
            "insertFailures": insertFailures,
        ]
        if let result = lastResult {
            info["eligibleCount"] = result.eligible.count
            info["syncedOrder"] = SyncEngine.managedOrder(entries: state.entries, eligible: result.eligible)
            info["hold"] = result.hold.map { "\($0)" } ?? ""
        }
        UserDefaults.standard.set(info, forKey: Keys.diagnostics)
    }
}
