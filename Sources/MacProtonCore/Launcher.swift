import Foundation

/// Implements the `proton` verbs Steam calls on a compatibility tool.
public struct Launcher: Sendable {
    public let layout: ToolLayout
    public let runner: any ProcessRunner
    public let log: LauncherLog
    public let notifier: any Notifier
    public let preflight: Preflight

    public init(layout: ToolLayout, runner: any ProcessRunner = SystemProcessRunner(), log: LauncherLog = .standard,
                notifier: any Notifier = AppleScriptNotifier(), preflight: Preflight = Preflight()) {
        self.layout = layout
        self.runner = runner
        self.log = log
        self.notifier = notifier
        self.preflight = preflight
    }

    /// Returns the exit code for Steam. Never throws: every failure is logged and becomes exit 1.
    public func launch(_ argv: [String], environment: [String: String]) -> Int32 {
        let request: LaunchRequest
        let context: CompatContext
        do {
            request = try LaunchRequest.parse(argv)
            context = try CompatContext(environment: environment)
        } catch {
            return fail("\(error)", argv: argv, notify: false)
        }
        do {
            try preflight.check(layout)
        } catch {
            return fail(error.description, argv: argv, notify: true)
        }

        let (backend, note) = GraphicsBackend.select(requested: environment["MACPROTON_GRAPHICS"],
                                                     gptkImported: layout.gptkImported)
        let logging = environment["MACPROTON_LOG"] == "1"
        let env = LaunchEnvironment.build(base: environment, context: context, backend: backend, logging: logging)
        let gameLog = logging ? log.gameLog(appID: context.appID) : nil
        if let gameLog { writeHeader(to: gameLog, request: request, environment: env) }
        let prefix = PrefixManager(context: context, layout: layout, runtimeVersion: layout.runtimeVersion ?? "unknown",
                                   runner: runner)

        do {
            let status: Int32
            switch request.verb {
            case .runinprefix:
                status = try runGame(request, env, gameLog)
            case .run:
                try prefix.prepare(backend: backend, environment: env)
                status = try runGame(request, env, gameLog)
            case .waitforexitandrun:
                // Prepare first (Proton's order): a launch queued on the prefix lock behind
                // `run iscriptevaluator.exe` then finds that session's wineserver alive, and
                // `-w` waits for the redistributable installers to finish.
                try prefix.prepare(backend: backend, environment: env)
                _ = try runner.run(layout.wineserver, ["-w"], environment: env, output: nil)
                status = try runGame(request, env, gameLog)
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

    private func runGame(_ request: LaunchRequest, _ env: [String: String], _ gameLog: URL?) throws -> Int32 {
        try runner.run(layout.wine, [request.target] + request.arguments, environment: env, output: gameLog)
    }

    private func writeHeader(to gameLog: URL, request: LaunchRequest, environment: [String: String]) {
        var text = "=== \(Date().formatted(.iso8601)) \(request.verb.rawValue) \(request.target) \(request.arguments)\n"
        for key in environment.keys.sorted() { text += "\(key)=\(environment[key]!)\n" }
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
        FileHandle.standardError.write(Data("macproton: \(message)\n".utf8))
        if notify { notifier.post(title: "MacProton", message: message) }
        return 1
    }
}
