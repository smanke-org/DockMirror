import XCTest
@testable import DockMirrorCore

/// A simulated Mac: a Dock, the apps installed, and DockMirror's saved state.
/// `"|"` in a Dock is a spacer.
private struct SimMac {
    let id: String
    var dock: [String]
    var installed: Set<String>
    var state: LocalState
    var lastHold: SyncHold?

    var apps: [String] { dock.filter { $0 != "|" } }

    func record(at now: Date) -> DeviceRecord {
        DeviceRecord(deviceID: id, deviceName: id, appVersion: "test", updatedAt: now,
                     role: state.role, paused: state.paused, installed: installed.sorted(),
                     dock: apps, entries: state.entries)
    }
}

private final class Fleet {
    var macs: [SimMac]
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let staleAfter: TimeInterval = 30 * 86_400

    init(_ macs: [SimMac]) { self.macs = macs }

    subscript(_ id: String) -> SimMac {
        get { macs.first { $0.id == id }! }
        set { macs[macs.firstIndex { $0.id == id }!] = newValue }
    }

    /// One sync pass on one Mac, applying its plan the way the app would.
    func sync(_ id: String, allowLarge: Bool = false) {
        clock += 10
        var mac = self[id]
        let remotes = macs.filter { $0.id != id }.map { $0.record(at: clock) }
        let slots = mac.dock.map { DockSlot(bundleID: $0 == "|" ? nil : $0) }
        let input = CycleInput(dock: slots, labels: [:], installed: mac.installed, remotes: remotes,
                               now: clock, device: id, staleAfter: staleAfter, allowLargeRemoval: allowLarge)
        let result = SyncEngine.runCycle(state: mac.state, input: input)
        mac.state = result.state
        mac.lastHold = result.hold
        if result.needsWrite {
            mac.dock = SyncEngine.bundleIDs(of: result.plan, current: slots).map { $0 ?? "|" }
            mac.state.lastObserved = result.plannedApps
        }
        self[id] = mac
    }

    /// Enough passes for every change to reach every Mac.
    func settle() {
        for _ in 0..<3 { for mac in macs { sync(mac.id) } }
    }
}

final class MultiMacTests: XCTestCase {

    private func twoMacs(main: [String], mainApps: Set<String>,
                         second: [String], secondApps: Set<String>) -> Fleet {
        Fleet([
            SimMac(id: "A", dock: main, installed: mainApps, state: LocalState(role: .main)),
            SimMac(id: "B", dock: second, installed: secondApps, state: LocalState(role: .secondary)),
        ])
    }

    // MARK: - Initial seed

    func testSecondaryAdoptsMainOrderForSharedApps() {
        let fleet = twoMacs(main: ["Safari", "Mail", "Xcode", "Music"],
                            mainApps: ["Safari", "Mail", "Xcode", "Music", "Notes"],
                            second: ["Music", "Notes", "Safari"],
                            secondApps: ["Safari", "Mail", "Music", "Notes"])
        fleet.settle()
        // Xcode isn't on B. Notes is B-only in the Dock and stays, after Music,
        // the synced app it followed.
        XCTAssertEqual(fleet["B"].dock, ["Safari", "Mail", "Music", "Notes"])
        XCTAssertEqual(fleet["A"].dock, ["Safari", "Mail", "Xcode", "Music"])
    }

    func testMainWinsWhenSecondaryJoinedFirst() {
        let fleet = twoMacs(main: ["Safari", "Mail"], mainApps: ["Safari", "Mail", "Music"],
                            second: ["Music", "Mail", "Safari"], secondApps: ["Safari", "Mail", "Music"])
        // B syncs alone before A is set up.
        fleet["A"].state.role = nil
        fleet.sync("B"); fleet.sync("B")
        XCTAssertEqual(fleet["B"].dock, ["Music", "Mail", "Safari"])
        fleet["A"].state.role = .main
        fleet.settle()
        XCTAssertEqual(Array(fleet["B"].apps.filter { ["Safari", "Mail"].contains($0) }), ["Safari", "Mail"])
        // Music was never stamped by anyone, so it's left in B's Dock rather
        // than added to A's or removed from B's.
        XCTAssertTrue(fleet["B"].apps.contains("Music"))
        XCTAssertFalse(fleet["A"].apps.contains("Music"))
    }

    func testUnsetUpMacDoesNotChangeItsDock() {
        let fleet = twoMacs(main: ["Safari", "Mail"], mainApps: ["Safari", "Mail"],
                            second: ["Mail"], secondApps: ["Safari", "Mail"])
        fleet["B"].state.role = nil
        fleet.settle()
        XCTAssertEqual(fleet["B"].dock, ["Mail"])
        XCTAssertEqual(fleet["B"].lastHold, .notSetUp)
    }

    // MARK: - Bidirectional edits

    func testMoveOnSecondarySpreadsToMain() {
        let fleet = twoMacs(main: ["Safari", "Mail", "Music"], mainApps: ["Safari", "Mail", "Music"],
                            second: [], secondApps: ["Safari", "Mail", "Music"])
        fleet.settle()
        fleet["B"].dock = ["Music", "Safari", "Mail"]
        fleet.settle()
        XCTAssertEqual(fleet["A"].dock, ["Music", "Safari", "Mail"])
    }

    func testAddAndRemoveSpread() {
        let all: Set<String> = ["Safari", "Mail", "Music", "Notes"]
        let fleet = twoMacs(main: ["Safari", "Mail", "Music"], mainApps: all, second: [], secondApps: all)
        fleet.settle()
        fleet["A"].dock = ["Safari", "Notes", "Mail", "Music"]
        fleet.settle()
        XCTAssertEqual(fleet["B"].dock, ["Safari", "Notes", "Mail", "Music"])
        fleet["B"].dock = ["Safari", "Notes", "Music"]
        fleet.settle()
        XCTAssertEqual(fleet["A"].dock, ["Safari", "Notes", "Music"])
    }

    func testConcurrentEditsToDifferentAppsBothSurvive() {
        let all: Set<String> = ["Safari", "Mail", "Music", "Notes", "Maps"]
        let fleet = twoMacs(main: ["Safari", "Mail", "Music", "Notes"], mainApps: all, second: [], secondApps: all)
        fleet.settle()
        // Before either syncs: A moves Notes to the front, B adds Maps at the end.
        fleet["A"].dock = ["Notes", "Safari", "Mail", "Music"]
        fleet["B"].dock = ["Safari", "Mail", "Music", "Notes", "Maps"]
        fleet.settle()
        XCTAssertEqual(fleet["A"].dock, ["Notes", "Safari", "Mail", "Music", "Maps"])
        XCTAssertEqual(fleet["B"].dock, fleet["A"].dock)
    }

    func testConcurrentMovesOfSameAppLatestWins() {
        let all: Set<String> = ["Safari", "Mail", "Music", "Notes"]
        let fleet = twoMacs(main: ["Safari", "Mail", "Music", "Notes"], mainApps: all, second: [], secondApps: all)
        fleet.settle()
        // Both move Notes (an adjacent swap would be ambiguous about which app moved).
        fleet["A"].dock = ["Notes", "Safari", "Mail", "Music"]
        fleet["B"].dock = ["Safari", "Notes", "Mail", "Music"]
        fleet.sync("A")
        fleet.sync("B")   // later stamp
        fleet.settle()
        XCTAssertEqual(fleet["A"].dock, ["Safari", "Notes", "Mail", "Music"])
        XCTAssertEqual(fleet["B"].dock, ["Safari", "Notes", "Mail", "Music"])
    }

    // MARK: - Installed set

    func testUninstallingStopsManagingWithoutRemovingElsewhere() {
        let all: Set<String> = ["Safari", "Mail", "Xcode"]
        let fleet = twoMacs(main: ["Safari", "Xcode", "Mail"], mainApps: all, second: [], secondApps: all)
        fleet.settle()
        XCTAssertEqual(fleet["B"].dock, ["Safari", "Xcode", "Mail"])
        // Xcode is deleted from B; its Dock tile goes with it.
        fleet["B"].installed.remove("Xcode")
        fleet["B"].dock = ["Safari", "Mail"]
        fleet.settle()
        XCTAssertEqual(fleet["A"].dock, ["Safari", "Xcode", "Mail"])
        XCTAssertEqual(fleet["A"].state.entries["Xcode"]?.pinned, true)
    }

    func testAppInstalledLaterIsAddedInPlace() {
        let fleet = twoMacs(main: ["Safari", "Xcode", "Mail"], mainApps: ["Safari", "Mail", "Xcode"],
                            second: [], secondApps: ["Safari", "Mail"])
        fleet.settle()
        XCTAssertEqual(fleet["B"].dock, ["Safari", "Mail"])
        fleet["B"].installed.insert("Xcode")
        fleet.settle()
        XCTAssertEqual(fleet["B"].dock, ["Safari", "Xcode", "Mail"])
    }

    func testThirdMacNarrowsSyncedSet() {
        let fleet = Fleet([
            SimMac(id: "A", dock: ["Safari", "Xcode", "Mail"], installed: ["Safari", "Xcode", "Mail"],
                   state: LocalState(role: .main)),
            SimMac(id: "B", dock: [], installed: ["Safari", "Xcode", "Mail"], state: LocalState(role: .secondary)),
            SimMac(id: "C", dock: ["Safari"], installed: ["Safari", "Mail"], state: LocalState()),
        ])
        fleet.settle()
        XCTAssertEqual(fleet["B"].dock, ["Safari", "Xcode", "Mail"])
        // C joins later.
        fleet["C"].state.role = .secondary
        fleet.settle()
        XCTAssertEqual(fleet["C"].dock, ["Safari", "Mail"])
        // Xcode isn't on C, so it isn't synced — B keeps the tile it already got.
        XCTAssertEqual(fleet["B"].dock, ["Safari", "Xcode", "Mail"])
    }

    func testStaleMacStopsNarrowing() {
        let fleet = Fleet([
            SimMac(id: "A", dock: ["Safari", "Xcode"], installed: ["Safari", "Xcode"], state: LocalState(role: .main)),
            SimMac(id: "B", dock: [], installed: ["Safari", "Xcode"], state: LocalState(role: .secondary)),
        ])
        let old = DeviceRecord(deviceID: "C", deviceName: "C", appVersion: "t",
                               updatedAt: fleet.clock - 60 * 86_400, role: .secondary, paused: false,
                               installed: ["Safari"], dock: ["Safari"], entries: [:])
        let eligible = SyncEngine.eligible(localInstalled: ["Safari", "Xcode"],
                                           remotes: [old], now: fleet.clock, staleAfter: fleet.staleAfter)
        XCTAssertEqual(eligible, ["Safari", "Xcode"])
    }

    // MARK: - Local-only content

    func testLocalOnlyAppsAndSpacersKeepTheirPlace() {
        let fleet = twoMacs(main: ["Safari", "Mail", "Music"], mainApps: ["Safari", "Mail", "Music"],
                            second: ["Terminal", "Mail", "|", "Photoshop", "Safari"],
                            secondApps: ["Safari", "Mail", "Music", "Terminal", "Photoshop"])
        fleet.settle()
        XCTAssertEqual(fleet["B"].dock, ["Terminal", "Safari", "Mail", "|", "Photoshop", "Music"])
    }

    func testRemovingLocalOnlyAppIsNotSpread() {
        let fleet = twoMacs(main: ["Safari"], mainApps: ["Safari", "Notes"],
                            second: ["Safari", "Terminal"], secondApps: ["Safari", "Terminal", "Notes"])
        fleet.settle()
        fleet["B"].dock = ["Safari"]
        fleet.settle()
        XCTAssertNil(fleet["B"].state.entries["Terminal"])
    }

    // MARK: - Safety

    func testMassRemovalIsHeld() {
        let all: Set<String> = ["a", "b", "c", "d", "e", "f", "g"]
        let fleet = twoMacs(main: ["a", "b", "c", "d", "e", "f", "g"], mainApps: all, second: [], secondApps: all)
        fleet.settle()
        // macOS reset A's Dock.
        fleet["A"].dock = ["a"]
        fleet.settle()
        XCTAssertEqual(fleet["B"].dock, ["a", "b", "c", "d", "e", "f", "g"])
        guard case .largeLocalRemoval(let removed)? = fleet["A"].lastHold else {
            return XCTFail("expected hold, got \(String(describing: fleet["A"].lastHold))")
        }
        XCTAssertEqual(removed.count, 6)

        // The user confirms it.
        fleet.sync("A", allowLarge: true)
        fleet.sync("B", allowLarge: true)
        XCTAssertEqual(fleet["B"].dock, ["a"])
    }

    func testIncomingMassRemovalIsHeld() {
        let all: Set<String> = ["a", "b", "c", "d", "e", "f"]
        let fleet = twoMacs(main: ["a", "b", "c", "d", "e", "f"], mainApps: all, second: [], secondApps: all)
        fleet.settle()
        fleet["A"].dock = ["a"]
        fleet.sync("A", allowLarge: true)
        fleet.sync("B")
        XCTAssertEqual(fleet["B"].dock, ["a", "b", "c", "d", "e", "f"])
        if case .largeIncomingRemoval = fleet["B"].lastHold {} else { XCTFail("expected incoming hold") }
    }

    func testPausedMacIsUntouchedAndCatchesUpOnResume() {
        let all: Set<String> = ["Safari", "Mail", "Music"]
        let fleet = twoMacs(main: ["Safari", "Mail", "Music"], mainApps: all, second: [], secondApps: all)
        fleet.settle()
        fleet["B"].state.paused = true
        fleet["B"].dock = ["Music", "Safari", "Mail"]
        fleet["A"].dock = ["Safari", "Music", "Mail"]
        fleet.settle()
        XCTAssertEqual(fleet["B"].dock, ["Music", "Safari", "Mail"])
        // Resuming records B's edit made during the pause, which is newer.
        fleet["B"].state.paused = false
        fleet.settle()
        XCTAssertEqual(fleet["A"].dock, ["Music", "Safari", "Mail"])
        XCTAssertEqual(fleet["B"].dock, ["Music", "Safari", "Mail"])
    }

    func testSteadyStateMakesNoWrites() {
        let all: Set<String> = ["Safari", "Mail"]
        let fleet = twoMacs(main: ["Safari", "Mail"], mainApps: all, second: ["Mail"], secondApps: all)
        fleet.settle()
        let before = fleet.macs.map(\.state.entries)
        fleet.settle()
        XCTAssertEqual(fleet.macs.map(\.state.entries), before)
    }

    func testMergeIsOrderIndependent() {
        let t = Date(timeIntervalSince1970: 100)
        let a: EntryMap = ["x": DockEntry(pinned: true, key: "a", updatedAt: t, by: "A")]
        let b: EntryMap = ["x": DockEntry(pinned: false, key: "a", updatedAt: t + 1, by: "B"),
                           "y": DockEntry(pinned: true, key: "b", updatedAt: t, by: "B")]
        XCTAssertEqual(EntryMerge.merge([a, b]), EntryMerge.merge([b, a]))
        XCTAssertEqual(EntryMerge.merge([a, b, a]), EntryMerge.merge([b, a]))
        XCTAssertEqual(EntryMerge.merge([a, b])["x"]?.pinned, false)
    }
}
