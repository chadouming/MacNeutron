import Foundation

public enum SteamPlayStatus: Equatable, Sendable {
    case off
    case on
    case restartNeeded(Int)
    case lost
    /// Something MacNeutron needs can't be read; the message says what.
    case problem(String)
}

/// Turns Steam Play mode on and off and keeps Steam's mappings current (spec §4).
/// Invariant: `steam_dev.cfg` never exists unless both tools resolve through Steam's bundle and every
/// Mac game is mapped. Writes happen in the order that keeps it true even when interrupted.
public struct SteamPlayMode: Sendable {
    public static let runtimeToolName = MappingPlanner.runtimeTool
    public static let nativeToolName = MappingPlanner.nativeTool
    public static let devConfig = "@sSteamCmdForcePlatformType linux\n"

    /// Runs a Mac game for Steam: `<verb> <command…>`. The command may be an `.app` folder (Steam would
    /// normally open it through LaunchServices), so the bundle's executable is resolved. Steam starts
    /// tools preferring x86_64, which carries through `exec`; `arch` puts the Apple Silicon build first.
    /// `arch` replaces this process, so Steam keeps tracking the same PID.
    static let passthroughScript = """
        #!/bin/sh
        shift
        target=$1
        shift
        if [ -d "$target" ] && [ -f "$target/Contents/Info.plist" ]; then
            name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$target/Contents/Info.plist" 2>/dev/null) || name=$(basename "$target" .app)
            target="$target/Contents/MacOS/$name"
        fi
        exec /usr/bin/arch -arm64e -arm64 -x86_64 "$target" "$@"

        """

    public let steam: SteamLocation
    public let tools: URL
    public let backups: URL
    public let intentFile: URL
    public let process: any SteamControlling
    public var verifyTimeout: Duration = .seconds(60)
    public var quitTimeout: Duration = .seconds(30)

    public init(steam: SteamLocation = SteamLocation(), root: URL = MacNeutronPaths.root,
                process: any SteamControlling = SteamProcess()) {
        self.steam = steam
        self.tools = root.appending(path: "compatibilitytools.d", directoryHint: .isDirectory)
        self.backups = root.appending(path: "backups", directoryHint: .isDirectory)
        self.intentFile = root.appending(path: "steam-play-enabled")
        self.process = process
    }

    var runtimeTool: URL { tools.appending(path: Self.runtimeToolName, directoryHint: .isDirectory) }
    var nativeTool: URL { tools.appending(path: Self.nativeToolName, directoryHint: .isDirectory) }
    func link(_ name: String) -> URL { steam.bundleCompatTools.appending(path: name) }

    /// The user turned Steam Play mode on and hasn't turned it off.
    public var isWanted: Bool { exists(intentFile) }

    /// Everything `enable` writes is still in place (a Steam update can wipe its bundle).
    public var filesIntact: Bool {
        exists(steam.steamDevConfig)
            && exists(link(Self.runtimeToolName).appending(path: "toolmanifest.vdf"))
            && exists(link(Self.nativeToolName).appending(path: "toolmanifest.vdf"))
    }

    public func status(plan: [String: ToolMapping]) -> SteamPlayStatus {
        guard isWanted else { return .off }
        guard filesIntact else { return .lost }
        if process.isRunning(), let log = try? String(contentsOf: steam.compatLog, encoding: .utf8),
           Self.verify(log: Self.lastSession(of: log)) != nil {
            return .lost
        }
        do {
            let pending = try pendingChanges(plan: plan)
            return pending > 0 ? .restartNeeded(pending) : .on
        } catch {
            return .problem("\(error)")
        }
    }

    // MARK: Flows

    public func enable(plan: [String: ToolMapping]) async throws {
        try await enable(planAfterQuit: { plan })
    }

    /// Builds the plan only once Steam has quit: Steam rewrites its app list on exit.
    public func enable(planAfterQuit makePlan: () throws -> [String: ToolMapping]) async throws {
        guard steam.isInstalled else { throw SteamPlayError.steamNotInstalled }
        _ = try readConfig()  // before touching Steam: an unreadable file must leave it running
        let wasRunning = process.isRunning()
        try await process.quit(timeout: quitTimeout)
        var backup: URL?
        do {
            let plan = try makePlan()
            _ = try readConfig()  // Steam may have rewritten it on exit
            backup = try backupConfig()
            try installNativeTool()
            try linkTools()
            try applyMappings(plan)
            try write(Self.devConfig, to: steam.steamDevConfig)  // last
        } catch {
            try? FileManager.default.removeItem(at: steam.steamDevConfig)
            unlinkTools()
            if wasRunning { try? process.launch() }  // back in Mac mode, as the user had it
            throw error
        }
        // Recorded before Steam starts in Linux mode, so a crash during verification can't hide that it's on.
        try write("", to: intentFile)
        let logBefore = (try? Data(contentsOf: steam.compatLog)) ?? Data()
        try process.launch()
        if let problem = await waitForVerification(after: logBefore.count, head: logBefore.prefix(256)) {
            await rollBack(restoring: backup)
            throw SteamPlayError.verificationFailed(problem)
        }
    }

    public func disable() async throws {
        try await process.quit(timeout: quitTimeout)
        try? FileManager.default.removeItem(at: steam.steamDevConfig)  // first
        unlinkTools()
        try applyMappings([:])
        try? FileManager.default.removeItem(at: intentFile)
        try process.launch()
    }

    /// Brings `config.vdf` up to date with `plan`. Call only while Steam is closed.
    /// Refuses any plan that would drop a Mac game's `macneutron-native` mapping: with Steam in Linux mode,
    /// that game's files would be deleted at the next start. Apps never legitimately leave the plan.
    @discardableResult
    public func sync(plan: [String: ToolMapping]) throws -> Bool {
        guard isWanted, filesIntact, try pendingChanges(plan: plan) > 0 else { return false }
        let dropped = try currentMappings().filter { $0.value.tool == Self.nativeToolName && plan[$0.key] == nil }
        guard dropped.isEmpty else { throw SteamPlayError.planDropsMacGames(dropped.count) }
        try applyMappings(plan)
        return true
    }

    // MARK: Building blocks

    public func pendingChanges(plan: [String: ToolMapping]) throws -> Int {
        let block = try readConfig().node(at: Self.mappingPath)?.children ?? []
        let current = MappingPlanner.current(in: block)
        let claimed = MappingPlanner.claimedByOtherTools(in: block)
        let keys = Set(current.keys).union(plan.keys).subtracting(claimed)
        return keys.filter { current[$0] != plan[$0] }.count
    }

    public func currentMappings() throws -> [String: ToolMapping] {
        MappingPlanner.current(in: try readConfig().node(at: Self.mappingPath)?.children ?? [])
    }

    static let mappingPath = ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]

    /// Replaces MacNeutron's entries in `CompatToolMapping` with `plan`: backup, edit, re-parse check, atomic write.
    public func applyMappings(_ plan: [String: ToolMapping]) throws {
        guard !process.isRunning() else { throw SteamPlayError.steamRunning }
        var nodes = try readConfig()
        let existing = nodes.node(at: Self.mappingPath)?.children ?? []
        nodes.setBlock(at: Self.mappingPath, children: MappingPlanner.merged(existing, with: plan))
        let text = KeyValues.serialize(nodes)
        guard let check = try? KeyValues.parse(text), check == nodes else {
            throw SteamPlayError.configUnreadable("the edited file didn't read back identically")
        }
        _ = try backupConfig()
        try write(text, to: steam.configVDF)
    }

    func readConfig() throws -> [KVNode] {
        guard exists(steam.configVDF) else { return [] }
        do {
            return try KeyValues.parse(try String(contentsOf: steam.configVDF, encoding: .utf8))
        } catch {
            throw SteamPlayError.configUnreadable("\(error)")
        }
    }

    /// Copies `config.vdf` to `backups/config-<timestamp>.vdf`, keeping the newest 10.
    @discardableResult
    func backupConfig() throws -> URL? {
        guard exists(steam.configVDF) else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            .replacingOccurrences(of: ":", with: "-")
        let backup = backups.appending(path: "config-\(stamp).vdf")
        try fm.copyItem(at: steam.configVDF, to: backup)
        let all = (try? fm.contentsOfDirectory(atPath: backups.path(percentEncoded: false)))?
            .filter { $0.hasPrefix("config-") }.sorted() ?? []
        for old in all.dropLast(10) { try? fm.removeItem(at: backups.appending(path: old)) }
        return backup
    }

    public func installNativeTool() throws {
        try write("""
            "compatibilitytools"
            {
              "compat_tools"
              {
                "\(Self.nativeToolName)"
                {
                  "install_path" "."
                  "display_name" "macOS native"
                  "from_oslist"  "macos"
                  "to_oslist"    "linux"
                }
              }
            }

            """, to: nativeTool.appending(path: "compatibilitytool.vdf"))
        try write("\"manifest\"\n{\n  \"version\" \"2\"\n  \"commandline\" \"/passthrough.sh %verb%\"\n}\n",
                  to: nativeTool.appending(path: "toolmanifest.vdf"))
        let script = nativeTool.appending(path: "passthrough.sh")
        try write(Self.passthroughScript, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
    }

    func linkTools() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: steam.bundleCompatTools, withIntermediateDirectories: true)
        for (name, target) in [(Self.runtimeToolName, runtimeTool), (Self.nativeToolName, nativeTool)] {
            let url = link(name)
            try? fm.removeItem(at: url)
            try fm.createSymbolicLink(at: url, withDestinationURL: target)
        }
    }

    func unlinkTools() {
        for name in [Self.runtimeToolName, Self.nativeToolName] { try? FileManager.default.removeItem(at: link(name)) }
    }

    private func rollBack(restoring backup: URL?) async {
        try? FileManager.default.removeItem(at: steam.steamDevConfig)  // first
        try? FileManager.default.removeItem(at: intentFile)
        try? await process.quit(timeout: quitTimeout)
        unlinkTools()
        if let backup {
            try? FileManager.default.removeItem(at: steam.configVDF)
            try? FileManager.default.copyItem(at: backup, to: steam.configVDF)
        }
        try? process.launch()
    }

    private func waitForVerification(after size: Int, head: Data) async -> String? {
        let deadline = ContinuousClock.now + verifyTimeout
        var problem: String? = "Steam didn't write its compatibility log"
        repeat {
            if let data = try? Data(contentsOf: steam.compatLog) {
                // Steam appends each session; a file that no longer begins as it did (the first line has a
                // timestamp) was started over, so all of it is the new session.
                let session = data.count >= size && data.starts(with: head) ? data.dropFirst(size) : data[...]
                if !session.isEmpty {
                    problem = Self.verify(log: String(decoding: session, as: UTF8.self))
                    if problem == nil { return nil }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        } while ContinuousClock.now < deadline
        return problem
    }

    /// nil when a Steam session's compat log shows both tools registered in Linux mode; otherwise the problem.
    static func verify(log: String) -> String? {
        if log.contains("Ignoring tool \(runtimeToolName)") {
            return "Steam started as a Mac client and ignored MacNeutron"
        }
        guard log.contains("Registering tool \(runtimeToolName),"), log.contains("Registering tool \(nativeToolName),") else {
            return "Steam didn't find MacNeutron's tools"
        }
        guard log.contains("Recording non-user mapping") else {
            return "Steam didn't switch to Steam Play mode"
        }
        return nil
    }

    /// The text from the last "Client version:" line on: the current Steam session.
    static func lastSession(of log: String) -> String {
        guard let range = log.range(of: "Client version:", options: .backwards) else { return log }
        return String(log[range.lowerBound...])
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
