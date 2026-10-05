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

/// The app's login item; a seam so tests don't register the real app with macOS.
struct LoginItem: Sendable {
    var status: @Sendable () -> SMAppService.Status = { SMAppService.mainApp.status }
    var register: @Sendable () throws -> Void = { try SMAppService.mainApp.register() }
    var unregister: @Sendable () throws -> Void = { try SMAppService.mainApp.unregister() }
}

/// Everything `refresh()` reads from disk, built off the main thread (parsing the app list and sizing
/// leftover prefixes can take a while; checking Steam spawns a process).
struct Snapshot: Sendable {
    var runtimeVersion: String?
    var gptkVersion: String?
    var apps: [AppInfo]
    var appInfoError: String?
    var installed: Set<UInt32>
    var settings: [String: GameSettings]
    var orphans: [OrphanPrefix]
    var status: SteamPlayStatus
}

/// Everything the menu, setup, games and settings views show, and every action they take.
@Observable @MainActor
final class AppModel {
    let steam: SteamLocation
    let layout: ToolLayout
    let mode: SteamPlayMode
    let store: GameSettingsStore
    let loginItem: LoginItem

    private(set) var runtimeVersion: String?
    private(set) var gptkVersion: String?
    private(set) var status: SteamPlayStatus = .off
    private(set) var games: [GameRow] = []
    private(set) var orphans: [OrphanPrefix] = []
    private(set) var appInfoError: String?
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    var busy: String?
    var errorMessage: String?

    private var apps: [AppInfo] = []
    private var watcher = SteamWatcher()
    private var pollTask: Task<Void, Never>?
    /// Bumped by every change the model makes on disk.
    private(set) var generation = 0

    init(steam: SteamLocation = SteamLocation(), layout: ToolLayout = ToolLayout(root: ToolLayout.defaultRoot),
         mode: SteamPlayMode = SteamPlayMode(), store: GameSettingsStore = GameSettingsStore(),
         loginItem: LoginItem = LoginItem()) {
        self.steam = steam
        self.layout = layout
        self.mode = mode
        self.store = store
        self.loginItem = loginItem
        // Keep the passthrough script current across app updates (it's only rewritten here and on enable).
        if mode.isWanted { try? mode.installNativeTool() }
        // Read now, not in the first refresh: the scene decides at launch whether to open the setup window.
        runtimeVersion = layout.runtimeVersion
        gptkVersion = layout.gptkVersion
        Task { await refresh() }
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

    func refresh() async {
        let (steam, layout, store, mode, fallback) = (self.steam, self.layout, self.store, self.mode, apps)
        let mine = generation
        let snapshot = await Task.detached {
            Self.loadSnapshot(steam: steam, layout: layout, store: store, mode: mode, fallbackApps: fallback)
        }.value
        apply(snapshot, generation: mine)
    }

    /// Drops a snapshot read before a settings change or cleanup: it would put the old state back.
    func apply(_ snapshot: Snapshot, generation mine: Int) {
        guard mine == generation else { return }
        runtimeVersion = snapshot.runtimeVersion
        gptkVersion = snapshot.gptkVersion
        apps = snapshot.apps
        appInfoError = snapshot.appInfoError
        games = snapshot.apps
            .filter { MappingPlanner.mappableTypes.contains($0.type) && !$0.oslist.isDisjoint(with: ["windows", "macos"]) }
            .map { GameRow(app: $0, installed: snapshot.installed.contains($0.appID),
                           settings: snapshot.settings[String($0.appID)] ?? GameSettings()) }
            .sorted { ($0.installed ? 0 : 1, $0.name.lowercased()) < ($1.installed ? 0 : 1, $1.name.lowercased()) }
        orphans = snapshot.orphans
        status = snapshot.status
        loginItemStatus = loginItem.status()
    }

    /// Reads everything from disk. On an unreadable app list it keeps `fallbackApps`: an empty list
    /// would plan away every Mac game's protection.
    nonisolated static func loadSnapshot(steam: SteamLocation, layout: ToolLayout, store: GameSettingsStore,
                                         mode: SteamPlayMode, fallbackApps: [AppInfo]) -> Snapshot {
        var apps = fallbackApps
        var appInfoError: String?
        do { apps = try AppInfoReader.read(steam.appInfo) } catch { appInfoError = "\(error)" }
        let plan = MappingPlanner.plan(apps: apps, runAs: store.runAsOverrides())
        return Snapshot(runtimeVersion: layout.runtimeVersion, gptkVersion: layout.gptkVersion, apps: apps,
                        appInfoError: appInfoError, installed: steam.installedAppIDs(), settings: store.all(),
                        orphans: OrphanPrefixes.find(in: steam), status: mode.status(plan: plan))
    }

    func plan() -> [String: ToolMapping] {
        MappingPlanner.plan(apps: apps, runAs: store.runAsOverrides())
    }

    // MARK: Setup

    func enableSteamPlay() async {
        guard appInfoError == nil else {
            errorMessage = "MacNeutron can't read Steam's app list, so it can't protect your Mac games: \(appInfoError ?? "")"
            return
        }
        await run("Turning on Steam Play mode and restarting Steam…") { [mode, steam, store] in
            // enable quits Steam itself (after its checks, so a failure leaves Steam running) and then asks
            // for the plan: Steam rewrites its app list on exit.
            try await mode.enable(planAfterQuit: { @Sendable in
                let apps: [AppInfo]
                do { apps = try AppInfoReader.read(steam.appInfo) } catch { throw AppInfoUnreadable(detail: "\(error)") }
                return MappingPlanner.plan(apps: apps, runAs: store.runAsOverrides())
            })
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
            await self.refresh()
            if self.appInfoError == nil { try mode.sync(plan: self.plan()) }
            try mode.process.launch()
        }
    }

    // MARK: Games

    /// Saves a game's settings. A "Runs as" change is written to Steam right away when Steam is closed;
    /// otherwise it waits for a restart ("restart needed").
    func update(_ appID: UInt32, _ change: (inout GameSettings) -> Void) async {
        guard let index = games.firstIndex(where: { $0.id == appID }) else { return }
        generation += 1  // a refresh already reading from disk would put the old settings back
        change(&games[index].settings)
        do {
            try store.save(games[index].settings, for: String(appID))
        } catch {
            errorMessage = "Couldn't save settings for \(games[index].name): \(error.localizedDescription)"
        }
        let (mode, plan, readable) = (self.mode, plan(), appInfoError == nil)
        let result = await Task.detached { () -> (SteamPlayStatus, String?) in
            var failure: String?
            if readable, !mode.process.isRunning() {
                do { try mode.sync(plan: plan) } catch { failure = "\(error)" }
            }
            return (mode.status(plan: plan), failure)
        }.value
        status = result.0
        if let failure = result.1 { errorMessage = failure }
    }

    func cleanUp(_ selected: [OrphanPrefix]) async {
        generation += 1
        do { try OrphanPrefixes.delete(selected) } catch { errorMessage = error.localizedDescription }
        await refresh()
    }

    // MARK: Settings

    /// On, or waiting for the user's approval in System Settings.
    var launchesAtLogin: Bool { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try loginItem.register() } else { try loginItem.unregister() }
        } catch {
            errorMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
        loginItemStatus = loginItem.status()
    }

    // MARK: Plumbing

    private func run(_ message: String, _ work: @escaping () async throws -> Void) async {
        guard busy == nil else { return }  // one Steam-changing action at a time
        busy = message
        errorMessage = nil
        do { try await work() } catch { errorMessage = "\(error)" }
        busy = nil
        await refresh()
    }

    /// Every 3 s: when Steam quits, bring its mappings up to date; 20 s after it starts, re-check the files.
    /// Once a minute, re-read Steam's app list so games bought meanwhile show up as "restart needed".
    /// The Steam check and the disk reads run off the main thread.
    private func startWatchingSteam() {
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                ticks += 1
                guard let self else { return }
                if ticks % 20 == 0, self.busy == nil { await self.refresh() }
                let mode = self.mode
                let running = await Task.detached { mode.process.isRunning() }.value
                switch self.watcher.observe(running: running) {
                case .quit?:
                    await self.refresh()  // Steam rewrites its app list on exit
                    if self.busy == nil, self.appInfoError == nil {
                        do { try self.mode.sync(plan: self.plan()) } catch { self.errorMessage = "\(error)" }
                        await self.refresh()
                    }
                case .launched?:
                    try? await Task.sleep(for: .seconds(20))
                    await self.refresh()
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
