import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. `Help.resolve` swaps `{…}` tokens for the user's own settings, such
/// as their shortcuts, so the text matches what they've set up.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// DockMirror has no shortcuts the user sets, so nothing needs swapping.
    static func resolve(_ text: String) -> String { text }
    static var debugTokens: String { "" }
    static let testTabs = ["Settings"]
    static func topic(forSettingsTab tab: String) -> String { "getting-started" }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("DockMirror keeps the apps in your Dock in the same order on all your Macs. Add, remove or rearrange an app on one Mac, and the others follow."),
            .text("Only apps installed on every Mac are synced. Apps that are only on one Mac, spacers, folders, Recents and Dock settings stay as they are."),
            .heading("Setting up"),
            .text("Choose Set Up… in the menu bar menu on each Mac. Pick one Mac as the main Mac; its Dock is the starting layout. The others are secondary Macs and adopt the main Mac's layout. The setup window previews what the Dock will look like before you start."),
            .tip("DockMirror backs up the Dock before every change, so any change can be undone from Restore Dock in the menu bar menu."),
        ]),

        HelpTopic(id: "syncing", title: "How Syncing Works", symbol: "arrow.triangle.2.circlepath", blocks: [
            .text("Each Mac writes its Dock layout to a DockMirror folder in iCloud Drive and checks the other Macs' layouts regularly (set how often in Settings › Sync). Edits on any Mac sync both ways; if two Macs change the same app, the newest change wins."),
            .keys([
                ("Sync Now (⌘S)", "Check the other Macs right away (menu bar menu)"),
                ("Pause Syncing", "Stop syncing this Mac until you resume"),
                ("Check Other Macs", "Choose how often to check"),
                ("Macs", "Every Mac in the sync, when each last synced, and Forget This Mac…"),
                ("Setup & Preview…", "Change this Mac's role, preview the result, or Stop Syncing This Mac"),
            ]),
        ]),

        HelpTopic(id: "removals", title: "Big Removals", symbol: "exclamationmark.triangle", blocks: [
            .text("If several apps disappear from a Dock at once, DockMirror waits for you instead of syncing straight away, in case it was a mistake. The menu bar menu lists the apps and asks:"),
            .keys([
                ("Removed on this Mac", "Remove Them from All Macs, or Put Them Back on This Dock"),
                ("Removed on another Mac", "Remove Them Here Too, or Keep Them on Every Mac"),
            ]),
        ]),

        HelpTopic(id: "restore", title: "Restoring the Dock", symbol: "clock.arrow.circlepath", blocks: [
            .text("Before every change, DockMirror saves a backup of your Dock. Restore Dock in the menu bar menu lists recent backups; choose one to put the Dock back as it was. Show Backups in Finder opens the folder."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .keys([
                ("dockmirror://sync", "Sync now"),
                ("dockmirror://pause", "Pause or resume syncing"),
                ("dockmirror://setup", "Open setup"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's DockMirror buttons use them."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("An app doesn't sync"),
            .text("It must be installed on every Mac in the sync. Apps that are only on some Macs stay where each Mac has them."),
            .heading("Another Mac never shows up"),
            .text("Check that both Macs use the same iCloud account with iCloud Drive turned on, and that DockMirror is set up on both. iCloud Drive can take a few minutes to deliver changes."),
            .heading("The Dock changed in a way I didn't want"),
            .text("Choose a backup from Restore Dock in the menu bar menu."),
        ]),
    ] }
}

// MARK: - Window

/// ObservableObject rather than @Observable, so this works on macOS 13.
@MainActor
final class HelpState: ObservableObject {
    @Published var selection: String? = "getting-started"
    @Published var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "DockMirror Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DockMirrorHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @ObservedObject var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) { _ in
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "DockMirror Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
