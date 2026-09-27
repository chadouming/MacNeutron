import AppKit
import MacNeutronCore
import Observation
import ServiceManagement

/// One row of the games window.
struct GameRow: Identifiable, Equatable {
    let app: AppInfo
    let installed: Bool
    var settings: GameSettings

    var id: UInt32 { app.appID }
    var name: String { app.name.isEmpty ? "App \(app.appID)" : app.name }
    var isDualPlatform: Bool { app.oslist.contains("macos") && app.oslist.contains("windows") }
    var runsWithMacNeutron: Bool { !app.oslist.contains("macos") || (isDualPlatform && settings.runAs == .windows) }
}

/// Everything the menu, setup, games and settings views show, and every action they take.
@Observable @MainActor
final class AppModel {
    let steam: SteamLocation
    let layout: ToolLayout
    let mode: SteamPlayMode
    let store: GameSettingsStore

    private(set) var runtimeVersion: String?
    private(set) var gptkVersion: String?
    private(set) var status: SteamPlayStatus = .off
    private(set) var games: [GameRow] = []
    private(set) var orphans: [OrphanPrefix] = []
    private(set) var appInfoError: String?
    var busy: String?
    var errorMessage: String?

    private var apps: [AppInfo] = []
    private var watcher = SteamWatcher()
    private var pollTask: Task<Void, Never>?

    init(steam: SteamLocation = SteamLocation(), layout: ToolLayout = ToolLayout(root: ToolLayout.defaultRoot),
         mode: SteamPlayMode = SteamPlayMode(), store: GameSettingsStore = GameSettingsStore()) {
        self.steam = steam
        self.layout = layout
        self.mode = mode
        self.store = store
        // Keep the passthrough script current across app updates (it's only rewritten here and on enable).
        if mode.isWanted { try? mode.installNativeTool() }
        refresh()
        startWatchingSteam()
    }

    var setupComplete: Bool { runtimeVersion != nil && mode.isWanted }
    var steamInstalled: Bool { steam.isInstalled }

    /// The `macneutron` CLI inside the app bundle (or next to the executable during development).
    var helper: URL {
        let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Helpers/macneutron")
        return FileManager.default.fileExists(atPath: bundled.path(percentEncoded: false))
            ? bundled : executable.deletingLastPathComponent().appending(path: "macneutron")
    }

    func refresh() {
        runtimeVersion = layout.runtimeVersion
        gptkVersion = layout.gptkVersion
        do {
            apps = try AppInfoReader.read(steam.appInfo)
            appInfoError = nil
        } catch {
            // Keep the last good list: an empty one would plan away every Mac game's protection.
            appInfoError = "\(error)"
        }
        let installed = steam.installedAppIDs()
        let settings = store.all()
        games = apps.filter { MappingPlanner.mappableTypes.contains($0.type) && !$0.oslist.isDisjoint(with: ["windows", "macos"]) }
            .map { GameRow(app: $0, installed: installed.contains($0.appID), settings: settings[String($0.appID)] ?? GameSettings()) }
            .sorted { ($0.installed ? 0 : 1, $0.name.lowercased()) < ($1.installed ? 0 : 1, $1.name.lowercased()) }
        orphans = OrphanPrefixes.find(in: steam)
        status = mode.status(plan: plan())
    }

    func plan() -> [String: ToolMapping] {
        MappingPlanner.plan(apps: apps, runAs: store.runAsOverrides())
    }

    // MARK: Setup

    func installRuntime() async {
        await run("Downloading and installing the runtime (461 MB, first time only)…") { [layout, helper] in
            let tarball = try await RuntimeInstaller.cachedDownload(.current)
            try await Task.detached {
                try RuntimeInstaller.install(tarball: tarball, pin: .current, layout: layout, launcherBinary: helper)
            }.value
        }
    }

    func importGPTK(from dmg: URL) async {
        await run("Importing the Game Porting Toolkit…") { [layout] in
            _ = try await Task.detached { try GPTKDiskImage.importGPTK(from: dmg, into: layout) }.value
        }
    }

    func enableSteamPlay() async {
        guard appInfoError == nil else {
            errorMessage = "MacNeutron can't read Steam's app list, so it can't protect your Mac games: \(appInfoError ?? "")"
            return
        }
        await run("Turning on Steam Play mode and restarting Steam…") { [mode] in
            // Steam rewrites its app list on exit, so plan only after it has quit.
            try await mode.process.quit(timeout: .seconds(30))
            self.refresh()
            if let error = self.appInfoError { throw AppInfoUnreadable(detail: error) }
            try await mode.enable(plan: self.plan())
        }
    }

    func disableSteamPlay() async {
        await run("Turning off Steam Play mode and restarting Steam…") { [mode] in try await mode.disable() }
    }

    /// Quit Steam, write pending mappings (or restore lost files), start Steam again.
    func restartSteam() async {
        if status == .lost {
            await enableSteamPlay()
            return
        }
        await run("Restarting Steam…") { [mode] in
            try await mode.process.quit(timeout: .seconds(30))
            self.refresh()
            if self.appInfoError == nil { try mode.sync(plan: self.plan()) }
            try mode.process.launch()
        }
    }

    // MARK: Games

    func update(_ appID: UInt32, _ change: (inout GameSettings) -> Void) {
        guard let index = games.firstIndex(where: { $0.id == appID }) else { return }
        change(&games[index].settings)
        do {
            try store.save(games[index].settings, for: String(appID))
        } catch {
            errorMessage = "Couldn't save settings for \(games[index].name): \(error.localizedDescription)"
        }
        status = mode.status(plan: plan())
    }

    func cleanUp(_ selected: [OrphanPrefix]) {
        do { try OrphanPrefixes.delete(selected) } catch { errorMessage = error.localizedDescription }
        orphans = OrphanPrefixes.find(in: steam)
    }

    // MARK: Settings

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
    }

    // MARK: Plumbing

    private func run(_ message: String, _ work: @escaping () async throws -> Void) async {
        guard busy == nil else { return }  // one Steam-changing action at a time
        busy = message
        errorMessage = nil
        do { try await work() } catch { errorMessage = "\(error)" }
        busy = nil
        refresh()
    }

    /// Every 3 s: when Steam quits, bring its mappings up to date; 20 s after it starts, re-check the files.
    /// Once a minute, re-read Steam's app list so games bought meanwhile show up as "restart needed".
    private func startWatchingSteam() {
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                ticks += 1
                if ticks % 20 == 0, self?.busy == nil { self?.refresh() }
                guard let self else { return }
                switch self.watcher.observe(running: self.mode.process.isRunning()) {
                case .quit?:
                    self.refresh()  // Steam rewrites its app list on exit
                    if self.busy == nil, self.appInfoError == nil {
                        do { try self.mode.sync(plan: self.plan()) } catch { self.errorMessage = "\(error)" }
                    }
                    self.status = self.mode.status(plan: self.plan())
                case .launched?:
                    try? await Task.sleep(for: .seconds(20))
                    self.refresh()
                case nil:
                    break
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct AppInfoUnreadable: Error, CustomStringConvertible {
    let detail: String
    var description: String { "MacNeutron can't read Steam's app list, so it can't protect your Mac games: \(detail)" }
}

extension SteamPlayStatus {
    var menuTitle: String {
        switch self {
        case .off: "Steam Play mode off"
        case .on: "Steam Play mode on"
        case .restartNeeded(let count): "Restart Steam to apply \(count) \(count == 1 ? "change" : "changes")"
        case .lost: "Steam Play mode was turned off by a Steam update"
        case .problem(let message): message
        }
    }

    var symbol: String {
        switch self {
        case .off: "atom"
        case .on: "atom"
        case .restartNeeded: "exclamationmark.circle"
        case .lost, .problem: "exclamationmark.triangle"
        }
    }
}
