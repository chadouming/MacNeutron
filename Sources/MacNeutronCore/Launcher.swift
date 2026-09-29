import Foundation

/// Implements the `proton` verbs Steam calls on a compatibility tool.
public struct Launcher: Sendable {
    public let layout: ToolLayout
    public let runner: any ProcessRunner
    public let log: LauncherLog
    public let notifier: any Notifier
    public let preflight: Preflight
    public let settings: GameSettingsStore
    public let steam: SteamLocation

    public init(layout: ToolLayout, runner: any ProcessRunner = SystemProcessRunner(), log: LauncherLog = .standard,
                notifier: any Notifier = AppleScriptNotifier(), preflight: Preflight = Preflight(),
                settings: GameSettingsStore = GameSettingsStore(), steam: SteamLocation = SteamLocation()) {
        self.layout = layout
        self.runner = runner
        self.log = log
        self.notifier = notifier
        self.preflight = preflight
        self.settings = settings
        self.steam = steam
    }

    /// Returns the exit code for Steam. Never throws: every failure is logged and becomes exit 1.
    public func launch(_ argv: [String], environment steamEnvironment: [String: String]) -> Int32 {
        var environment = steamEnvironment
        let request: LaunchRequest
        let context: CompatContext
        do {
            request = try LaunchRequest.parse(argv)
            context = try CompatContext(environment: environment)
        } catch {
            return fail("\(error)", argv: argv, notify: false)
        }
        do {
            // Per-game settings from the app sit underneath; variables from Steam launch options win.
            environment = try settings.load(context.appID).environment.merging(environment) { _, launchOption in launchOption }
        } catch {
            log.append("note: ignoring unreadable game settings for \(context.appID): \(error)")
        }
        do {
            try preflight.check(layout)
        } catch {
            return fail(error.description, argv: argv, notify: true)
        }

        let (backend, note) = GraphicsBackend.select(requested: environment["MACNEUTRON_GRAPHICS"],
                                                     gptkImported: layout.gptkImported)
        let logging = environment["MACNEUTRON_LOG"] == "1"
        var env = LaunchEnvironment.build(base: environment, context: context, backend: backend, layout: layout,
                                          logging: logging)
        let steamBridge = usesSteamBridge(request.verb, env)
        if steamBridge { addSteamClient(to: &env) }
        if request.verb == .run || request.verb == .waitforexitandrun { addPresenter(to: &env) }
        let gameLog = logging ? log.gameLog(appID: context.appID) : nil
        if let gameLog { writeHeader(to: gameLog, request: request, environment: env) }
        let prefix = PrefixManager(context: context, layout: layout, runtimeVersion: layout.runtimeVersion ?? "unknown",
                                   runner: runner)

        do {
            let status: Int32
            switch request.verb {
            case .runinprefix:
                status = try runGame(request, env, gameLog, throughSteam: false)
            case .run:
                try prefix.prepare(backend: backend, environment: env, steamBridge: steamBridge)
                if !steamBridge { try prefix.removeSteamBridge() }
                status = try runGame(request, env, gameLog, throughSteam: steamBridge)
            case .waitforexitandrun:
                // Prepare first (Proton's order): a launch queued on the prefix lock behind
                // `run iscriptevaluator.exe` then finds that session's wineserver alive, and
                // `-w` waits for the redistributable installers to finish.
                try prefix.prepare(backend: backend, environment: env, steamBridge: steamBridge)
                if !steamBridge { try prefix.removeSteamBridge() }
                _ = try runner.run(layout.wineserver, ["-w"], environment: env, output: nil)
                status = try runGame(request, env, gameLog, throughSteam: steamBridge)
                // Keep Steam's "running" state until every process in the prefix is gone
                // (covers launchers that start the real game and exit).
                _ = try runner.run(layout.wineserver, ["-w"], environment: env, output: nil)
            case .getcompatpath, .getnativepath:
                try prefix.prepare(backend: backend, environment: env)
                let flag = request.verb == .getcompatpath ? "-w" : "-u"
                status = try runner.run(layout.wine, ["winepath.exe", flag, request.target], environment: env, output: nil)
            }
            var line = "verb=\(request.verb.rawValue) appid=\(context.appID) backend=\(backend.rawValue)"
                + " runtime=\(layout.runtimeVersion ?? "unknown") gptk=\(layout.gptkVersion ?? "none") exit=\(status)"
            if let note { line += " note=\(note)" }
            log.append(line)
            return status
        } catch {
            return fail("\(error)", argv: argv, notify: true)
        }
    }

    /// Steam's Stop button sends SIGTERM: kill every Wine process in the game's prefix.
    public func terminate(environment: [String: String]) {
        guard let context = try? CompatContext(environment: environment) else { return }
        var env = environment
        env["WINEPREFIX"] = context.prefix.path(percentEncoded: false)
        _ = try? runner.run(layout.wineserver, ["-k"], environment: env, output: nil)
    }

    private func runGame(_ request: LaunchRequest, _ env: [String: String], _ gameLog: URL?,
                         throughSteam: Bool) throws -> Int32 {
        let game = [request.target] + request.arguments
        let command = throughSteam ? [SteamBridge.steamExe, SteamBridge.windowsPath(request.target)] + request.arguments : game
        return try runner.run(layout.wine, command, environment: env, output: gameLog)
    }

    /// `run` and `waitforexitandrun` start the game through `steam.exe` when the bridge is installed,
    /// as Proton does; the log says why when they don't.
    private func usesSteamBridge(_ verb: Verb, _ environment: [String: String]) -> Bool {
        guard verb == .run || verb == .waitforexitandrun else { return false }
        if environment["MACNEUTRON_NO_STEAM_BRIDGE"] == "1" {
            log.append("note: Steam bridge disabled by launch option")
            return false
        }
        guard layout.steamBridgeInstalled else {
            log.append("note: Steam bridge not installed")
            return false
        }
        return true
    }

    /// Loads the MetalFX presenter into the game's Wine processes, after any libraries the player set,
    /// unless the game opts out.
    private func addPresenter(to env: inout [String: String]) {
        guard env["MACNEUTRON_NO_METALFX"] != "1" else { return }
        guard layout.presenterInstalled else {
            log.append("note: MetalFX presenter not installed")
            return
        }
        let libraries = [env["DYLD_INSERT_LIBRARIES"], layout.presenterLibrary.path(percentEncoded: false)]
        env["DYLD_INSERT_LIBRARIES"] = libraries.compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ":")
    }

    /// Tells the runtime's lsteamclient where macOS Steam's client library is, and steam.exe who is logged in.
    private func addSteamClient(to env: inout [String: String]) {
        let passed = env["STEAM_COMPAT_CLIENT_INSTALL_PATH"]
        let client = SteamBridge.clientDirectory(steamValue: passed, steam: steam)
        env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = client
        log.append("note: Steam client folder \(client) (Steam passed \(passed ?? "nothing"))")
        if !FileManager.default.fileExists(atPath: client + "/steamclient.dylib") {
            log.append("note: steamclient.dylib not found in \(client)")
        }
        guard env["MACNEUTRON_STEAM_ACCOUNT"] == nil else { return }
        if let account = steam.activeAccountID() {
            env["MACNEUTRON_STEAM_ACCOUNT"] = String(account)
        } else {
            log.append("note: no Steam account found in loginusers.vdf")
        }
    }

    private func writeHeader(to gameLog: URL, request: LaunchRequest, environment: [String: String]) {
        var text = "=== \(Date().formatted(.iso8601)) \(request.verb.rawValue) \(request.target) \(request.arguments)\n"
        // People post these logs in bug reports; the account ID leads straight to a Steam profile.
        for key in environment.keys.sorted() {
            text += "\(key)=\(key == "MACNEUTRON_STEAM_ACCOUNT" ? "<redacted>" : environment[key]!)\n"
        }
        if let handle = try? FileHandle(forWritingTo: gameLog) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: gameLog)
        }
    }

    private func fail(_ message: String, argv: [String], notify: Bool) -> Int32 {
        log.append("error: \(message) argv=\(argv)")
        FileHandle.standardError.write(Data("macneutron: \(message)\n".utf8))
        if notify { notifier.post(title: "MacNeutron", message: message) }
        return 1
    }
}
