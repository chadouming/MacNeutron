import AppKit
import MacNeutronCore
import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var choosingDMG = false

    private var nativeGames: [GameRow] { model.games.filter { !$0.runsWithMacNeutron } }
    private var windowsGames: [GameRow] { model.games.filter(\.runsWithMacNeutron) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set up MacNeutron", systemImage: "atom").font(.title2)

            Step(done: model.runtimeVersion != nil, title: "Install runtime",
                 detail: model.runtimeVersion.map { "Wine \($0) installed" } ?? "Downloads the Wine runtime (461 MB).") {
                Button(model.runtimeVersion == nil ? "Install" : "Reinstall") { Task { await model.installRuntime() } }
            }

            Step(done: model.gptkVersion != nil, title: "Import Game Porting Toolkit (optional)",
                 detail: model.gptkVersion.map { "D3DMetal \($0) imported. Drop a newer .dmg here to update." }
                     ?? "Drop Apple's Game_Porting_Toolkit .dmg here, or choose it. Without it, games use DXMT.") {
                Button("Choose…") { choosingDMG = true }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let dmg = urls.first(where: { $0.pathExtension == "dmg" }) else { return false }
                Task { await model.importGPTK(from: dmg) }
                return true
            }

            Step(done: model.mode.isWanted, title: "Turn on Steam Play mode",
                 detail: "Steam restarts. Your Mac games stay native and protected.") {
                Button("Turn on and restart Steam") { Task { await model.enableSteamPlay() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.runtimeVersion == nil || !model.steamInstalled)
            }
            if !model.mode.isWanted {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        Label("Stay native (\(nativeGames.count))", systemImage: "apple.logo")
                        Label("Run with MacNeutron (\(windowsGames.count))", systemImage: "square.grid.2x2")
                    }
                    .foregroundStyle(.secondary)
                    GridRow {
                        Text(summary(nativeGames))
                        Text(summary(windowsGames))
                    }
                }
                .font(.callout)
                .padding(.leading, 30)
            }

            if let busy = model.busy { ProgressView(busy).controlSize(.small) }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.steamInstalled { Text("Install Steam for Mac first.").foregroundStyle(.red) }
        }
        .padding(20)
        .frame(width: 560)
        .disabled(model.busy != nil)
        .fileImporter(isPresented: $choosingDMG, allowedContentTypes: [.diskImage]) { result in
            if case .success(let dmg) = result { Task { await model.importGPTK(from: dmg) } }
        }
        .onAppear {
            Task { await model.refresh() }
            raiseWindows()  // a menu-bar app isn't active on its own, so the window would open behind everything
        }
    }

    private func summary(_ rows: [GameRow]) -> String {
        let installed = rows.filter(\.installed).map(\.name)
        let names = installed.isEmpty ? rows.prefix(3).map(\.name) : installed.prefix(4).map { $0 }
        return names.isEmpty ? "None" : names.joined(separator: ", ") + (rows.count > names.count ? "…" : "")
    }
}

private struct Step<Action: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            action
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}
