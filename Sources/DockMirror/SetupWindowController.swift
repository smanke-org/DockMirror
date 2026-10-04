import AppKit
import DockMirrorCore
import SwiftUI

/// Choosing this Mac's role, with a preview of the Dock that results.
/// Nothing changes until "Start Syncing" is pressed.
@MainActor
final class SetupWindowController {
    static let shared = SetupWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupView(close: { [weak self] in self?.window?.close() }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "DockMirror Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // Ordering the window front together with activating is what makes an
        // accessory app actually come forward on macOS 27.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct PreviewRow: Identifiable {
    enum Change { case same, added, removed }
    let id: Int
    let name: String
    let change: Change
}

private struct SetupView: View {
    let close: () -> Void
    private let coordinator = SyncCoordinator.shared
    @State private var role: MacRole = SyncCoordinator.shared.state.role ?? .secondary
    @State private var rows: [PreviewRow] = []
    @State private var otherMacs = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep this Dock in step with your other Macs")
                .font(.headline)
            Text("Apps installed on every Mac are kept in the same order. Apps only on this Mac, spacers, folders and Recents stay as they are. The Dock is backed up before every change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("This Mac is", selection: $role) {
                Text("The main Mac — its Dock is the starting layout").tag(MacRole.main)
                Text("A secondary Mac — adopt the main Mac's layout").tag(MacRole.secondary)
            }
            .pickerStyle(.radioGroup)

            Text(otherMacs == 0
                 ? "No other Macs found yet. Set up the main Mac first, or wait for iCloud Drive to catch up."
                 : "\(otherMacs) other Mac\(otherMacs == 1 ? "" : "s") found.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("This Dock after syncing").font(.subheadline.weight(.semibold))
            List(rows) { row in
                HStack {
                    Image(systemName: icon(for: row.change))
                        .foregroundStyle(color(for: row.change))
                        .frame(width: 16)
                    Text(row.name)
                        .strikethrough(row.change == .removed)
                        .foregroundStyle(row.change == .removed ? .secondary : .primary)
                }
            }
            .frame(minHeight: 260)

            HStack {
                if coordinator.state.role != nil {
                    Button("Stop Syncing This Mac") {
                        coordinator.leave()
                        close()
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                // No Return shortcut: changing the Dock takes a deliberate click.
                Button("Start Syncing") {
                    coordinator.setUp(role: role)
                    close()
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: refresh)
        .onChange(of: role) { _ in refresh() }
    }

    private func refresh() {
        otherMacs = coordinator.remotes.values.filter { $0.role != nil }.count
        let preview = coordinator.preview(role: role)
        func name(_ id: String?) -> String {
            guard let id else { return "— spacer —" }
            return preview.labels[id] ?? id
        }
        let planned = Set(preview.planned.compactMap { $0 })
        let current = Set(preview.current.compactMap { $0 })
        var result: [PreviewRow] = []
        for (index, id) in preview.planned.enumerated() {
            result.append(PreviewRow(id: index, name: name(id),
                                     change: id.map { current.contains($0) } ?? true ? .same : .added))
        }
        for id in preview.current.compactMap({ $0 }) where !planned.contains(id) {
            result.append(PreviewRow(id: result.count, name: name(id), change: .removed))
        }
        rows = result
    }

    private func icon(for change: PreviewRow.Change) -> String {
        switch change {
        case .same: return "circle.fill"
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        }
    }

    private func color(for change: PreviewRow.Change) -> Color {
        switch change {
        case .same: return .secondary.opacity(0.4)
        case .added: return .green
        case .removed: return .red
        }
    }
}
