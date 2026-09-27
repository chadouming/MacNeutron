import AppKit
import MacNeutronCore
import SwiftUI

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status.menuTitle)
        Text("Runtime \(model.runtimeVersion ?? "not installed") · D3DMetal \(model.gptkVersion ?? "not imported")")
        if let busy = model.busy { Text(busy) }
        switch model.status {
        case .restartNeeded, .lost:
            Button(model.status == .lost ? "Restore Steam Play mode" : "Restart Steam") {
                Task { await model.restartSteam() }
            }
        default:
            EmptyView()
        }
        Divider()
        if !model.setupComplete {
            Button("Finish setup…") { show("setup", with: openWindow) }
        }
        Button("Games…") {
            model.refresh()
            show("games", with: openWindow)
        }
        Button("Open Steam") { try? model.mode.process.launch() }
        if !model.orphans.isEmpty {
            let bytes = model.orphans.reduce(Int64(0)) { $0 + $1.bytes }
            Button("Free up space (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))") {
                show("cleanup", with: openWindow)
            }
        }
        Button("Show logs") { NSWorkspace.shared.open(LauncherLog.standard.directory) }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit MacNeutron") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
