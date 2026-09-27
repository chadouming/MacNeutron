import MacNeutronCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingTurnOff = false

    var body: some View {
        Form {
            Toggle("Open MacNeutron at login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchAtLogin($0) }))
            LabeledContent("Runtime") {
                Button("Repair runtime") { Task { await model.installRuntime() } }
            }
            LabeledContent("Setup") {
                Button("Run setup again") { show("setup", with: openWindow) }
            }
            LabeledContent("Steam Play mode") {
                Button("Turn off Steam Play mode", role: .destructive) { confirmingTurnOff = true }
                    .disabled(!model.mode.isWanted)
            }
            if let busy = model.busy { ProgressView(busy).controlSize(.small) }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .disabled(model.busy != nil)
        .confirmationDialog("Turn off Steam Play mode?", isPresented: $confirmingTurnOff) {
            Button("Turn off and restart Steam", role: .destructive) { Task { await model.disableSteamPlay() } }
        } message: {
            Text("Windows games will be removed from disk and need downloading again if you turn this back on. Saves inside their prefixes are kept.")
        }
    }
}

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Leftover data from games you've uninstalled").font(.headline)
            if model.orphans.isEmpty {
                Text("Nothing to clean up.").foregroundStyle(.secondary)
            }
            ForEach(model.orphans, id: \.appID) { orphan in
                Toggle(isOn: Binding(get: { selected.contains(orphan.appID) },
                                     set: { if $0 { selected.insert(orphan.appID) } else { selected.remove(orphan.appID) } })) {
                    HStack {
                        Text(model.games.first { String($0.id) == orphan.appID }?.name ?? "App \(orphan.appID)")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: orphan.bytes, countStyle: .file)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Delete selected", role: .destructive) {
                    model.cleanUp(model.orphans.filter { selected.contains($0.appID) })
                    selected.removeAll()
                }
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
