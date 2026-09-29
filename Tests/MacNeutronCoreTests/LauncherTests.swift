import Foundation
import Testing
@testable import MacNeutronCore

final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var posted: [String] { lock.withLock { messages } }
    func post(title: String, message: String) { lock.withLock { messages.append(message) } }
}

private struct Fixture {
    let launcher: Launcher
    let runner: FakeRunner
    let notifier: RecordingNotifier
    let env: [String: String]
    var launcherLog: String { (try? String(contentsOf: launcher.log.launcherLog, encoding: .utf8)) ?? "" }
}

private func makeFixture(runner: FakeRunner = winebootCreatingPrefix(), rosetta: Bool = true,
                         bridge: Bool = false) throws -> Fixture {
    let notifier = RecordingNotifier()
    let layout = try makeToolLayout()
    if bridge { try installFakeSteamBridge(in: layout) }
    let steam = try makeSteamLocation(loginUsers: loginUsersFile(loginUser(account: 1, timestamp: 100, mostRecent: true)))
    let launcher = Launcher(layout: layout, runner: runner,
                            log: LauncherLog(directory: try makeTempDir().appending(path: "Logs")),
                            notifier: notifier, preflight: Preflight(rosettaAvailable: { rosetta }),
                            settings: GameSettingsStore(directory: try makeTempDir().appending(path: "games")),
                            steam: steam)
    let env = steamEnvironment(dataPath: try makeTempDir().appending(path: "compatdata/42"), appID: "42")
    return Fixture(launcher: launcher, runner: runner, notifier: notifier, env: env)
}

@Test func waitForExitAndRunPreparesWaitsRunsThenWaits() throws {
    // Proton's order: preparing first means a launch that queued on the prefix lock behind
    // `run iscriptevaluator.exe` finds that session's wineserver alive and waits it out.
    let runner = FakeRunner { call in
        if call.arguments.first == "wineboot", let prefix = call.environment["WINEPREFIX"] {
            try? FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        }
        return call.arguments.first == "/g/Game.exe" ? 7 : 0
    }
    let f = try makeFixture(runner: runner)
    let status = f.launcher.launch(["waitforexitandrun", "/g/Game.exe", "-windowed"], environment: f.env)
    #expect(status == 7)
    #expect(runner.calls.map { [$0.tool] + $0.arguments } == [
        ["wine", "wineboot", "-u"],
        ["wine", "reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f"],
        ["wineserver", "-w"],
        ["wine", "/g/Game.exe", "-windowed"],
        ["wineserver", "-w"],
    ])
}

@Test func runDoesNotWaitForWineserver() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["run", "/g/iscriptevaluator.exe", "--get-current-step", "42"], environment: f.env) == 0)
    #expect(!f.runner.calls.contains { $0.tool == "wineserver" })
    #expect(f.runner.calls.last?.arguments == ["/g/iscriptevaluator.exe", "--get-current-step", "42"])
}

@Test func runInPrefixSkipsPreparation() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["runinprefix", "/g/tool.exe"], environment: f.env) == 0)
    #expect(f.runner.calls.map(\.arguments) == [["/g/tool.exe"]])
}

@Test func getCompatPathConvertsThroughWinepath() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["getcompatpath", "/g/save"], environment: f.env) == 0)
    #expect(f.runner.calls.last?.arguments == ["winepath.exe", "-w", "/g/save"])
}

@Test func gameArgumentsPassThroughUnchanged() throws {
    let f = try makeFixture()
    let args = ["/Steam Library/My Game/Game.exe", "--name=\"Player One\"", "a b", "ünïcode", ""]
    _ = f.launcher.launch(["run"] + args, environment: f.env)
    #expect(f.runner.calls.last?.arguments == args)
}

@Test func unknownVerbFailsWithoutRunningAnything() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["destroyprefix", "/g/Game.exe"], environment: f.env) == 1)
    #expect(f.runner.calls.isEmpty)
}

@Test func launchingOutsideSteamFailsCleanly() throws {
    let f = try makeFixture()
    #expect(f.launcher.launch(["run", "/g/Game.exe"], environment: ["PATH": "/usr/bin"]) == 1)
    #expect(f.runner.calls.isEmpty)
}

@Test func invalidGraphicsSettingStillLaunchesWithDefault() throws {
    let f = try makeFixture()
    var env = f.env
    env["MACNEUTRON_GRAPHICS"] = "vulkan"
    #expect(f.launcher.launch(["run", "/g/Game.exe"], environment: env) == 0)
    #expect(f.runner.calls.last?.environment["WINEDLLOVERRIDES"]?.hasPrefix("dxgi=n,b;d3d10core=n,b;d3d11=n,b") == true)
    let logged = try String(contentsOf: f.launcher.log.launcherLog, encoding: .utf8)
    #expect(logged.contains("backend=dxmt"))
    #expect(logged.contains("note=unknown MACNEUTRON_GRAPHICS 'vulkan'"))
}

@Test func missingRosettaNotifiesAndFails() throws {
    let f = try makeFixture(rosetta: false)
    #expect(f.launcher.launch(["run", "/g/Game.exe"], environment: f.env) == 1)
    #expect(f.runner.calls.isEmpty)
    #expect(f.notifier.posted.first?.contains("softwareupdate --install-rosetta") == true)
}

@Test func failedPrefixSetupNotifiesAndSkipsGame() throws {
    let f = try makeFixture(runner: winebootCreatingPrefix(status: 5))
    #expect(f.launcher.launch(["waitforexitandrun", "/g/Game.exe"], environment: f.env) == 1)
    #expect(!f.runner.calls.contains { $0.arguments.first == "/g/Game.exe" })
    #expect(f.notifier.posted.count == 1)
}

@Test func macneutronLogSendsGameOutputToPerGameLog() throws {
    let f = try makeFixture()
    var env = f.env
    env["MACNEUTRON_LOG"] = "1"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    let gameLog = f.launcher.log.gameLog(appID: "42")
    #expect(f.runner.calls.last?.output == gameLog)
    #expect(try String(contentsOf: gameLog, encoding: .utf8).contains("WINEDEBUG=+err,+warn,+loaddll,+steamclient"))
}

@Test func everyLaunchIsLoggedWithVersions() throws {
    let f = try makeFixture()
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    let line = try String(contentsOf: f.launcher.log.launcherLog, encoding: .utf8)
    #expect(line.contains("verb=run appid=42 backend=dxmt runtime=runtime-test gptk=none exit=0"))
}

@Test func terminateKillsThePrefixWineserver() throws {
    let f = try makeFixture()
    f.launcher.terminate(environment: f.env)
    #expect(f.runner.calls.map { [$0.tool] + $0.arguments } == [["wineserver", "-k"]])
    #expect(f.runner.calls[0].environment["WINEPREFIX"]?.hasSuffix("compatdata/42/pfx/") == true)
}

@Test func gameSettingsApplyUnderneathLaunchOptions() throws {
    let f = try makeFixture()
    try f.launcher.settings.save(GameSettings(graphics: "dxvk", log: true, msync: false), for: "42")
    var env = f.env
    env["MACNEUTRON_GRAPHICS"] = "dxmt"  // typed into Steam's launch options: wins
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    let wine = try #require(f.runner.calls.last?.environment)
    #expect(wine["WINEDLLOVERRIDES"]?.hasPrefix("dxgi=n,b;d3d10core=n,b;d3d11=n,b") == true)  // dxmt
    #expect(wine["WINEDEBUG"] == "+err,+warn,+loaddll,+steamclient")
    #expect(wine["WINEMSYNC"] == nil)
}

@Test func unreadableGameSettingsAreIgnored() throws {
    let f = try makeFixture()
    try write("{ not json", to: f.launcher.settings.directory.appending(path: "42.json"))
    #expect(f.launcher.launch(["run", "/g/Game.exe"], environment: f.env) == 0)
    #expect(try String(contentsOf: f.launcher.log.launcherLog, encoding: .utf8).contains("ignoring unreadable game settings for 42"))
}

@Test func gameGoesThroughSteamExeWhenTheBridgeIsInstalled() throws {
    let f = try makeFixture(bridge: true)
    #expect(f.launcher.launch(["waitforexitandrun", "/Steam Library/My Game/Game.exe", "-windowed"], environment: f.env) == 0)
    let game = try #require(f.runner.calls.first { $0.arguments.first == SteamBridge.steamExe })
    #expect(game.arguments == [#"C:\Program Files (x86)\Steam\steam.exe"#, #"Z:\Steam Library\My Game\Game.exe"#, "-windowed"])
    #expect(game.environment["STEAM_COMPAT_CLIENT_INSTALL_PATH"]
        == String(f.launcher.steam.bundleMacOS.path(percentEncoded: false).dropLast()))
    #expect(game.environment["MACNEUTRON_STEAM_ACCOUNT"] == "1")
    let prefix = try CompatContext(environment: f.env).prefix
    #expect(FileManager.default.fileExists(
        atPath: prefix.appending(path: "drive_c/Program Files (x86)/Steam/steamclient64.dll").path(percentEncoded: false)))
}

@Test func runInPrefixNeverGoesThroughSteamExe() throws {
    let f = try makeFixture(bridge: true)
    _ = f.launcher.launch(["runinprefix", "/g/tool.exe"], environment: f.env)
    #expect(f.runner.calls.map(\.arguments) == [["/g/tool.exe"]])
}

@Test func escapeHatchStartsTheGameDirectly() throws {
    let f = try makeFixture(bridge: true)
    var env = f.env
    env["MACNEUTRON_NO_STEAM_BRIDGE"] = "1"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    #expect(f.runner.calls.last?.arguments == ["/g/Game.exe"])
    #expect(f.launcherLog.contains("note: Steam bridge disabled by launch option"))
}

@Test func missingBridgeStartsTheGameDirectly() throws {
    let f = try makeFixture()
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    #expect(f.runner.calls.last?.arguments == ["/g/Game.exe"])
    #expect(f.launcherLog.contains("note: Steam bridge not installed"))
}

@Test func accountFromLaunchOptionsWins() throws {
    let f = try makeFixture(bridge: true)
    var env = f.env
    env["MACNEUTRON_STEAM_ACCOUNT"] = "99"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    #expect(f.runner.calls.last?.environment["MACNEUTRON_STEAM_ACCOUNT"] == "99")
}

@Test func steamsClientPathIsLoggedAndCheckedForTheLibrary() throws {
    let f = try makeFixture(bridge: true)
    try FileManager.default.removeItem(at: f.launcher.steam.bundleMacOS.appending(path: "steamclient.dylib"))
    var env = f.env
    env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = "/nowhere"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    #expect(f.launcherLog.contains("(Steam passed /nowhere)"))
    #expect(f.launcherLog.contains("note: steamclient.dylib not found in"))
}

@Test func escapeHatchTakesTheBridgeOutOfThePrefix() throws {
    // Seen in acceptance: a game's steam_api loads the client DLL an earlier launch left (its registry
    // values persist), and without Steam's client path the bridge aborts the game. Without the files,
    // the game just finds no Steam.
    let f = try makeFixture(bridge: true)
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    let folder = try CompatContext(environment: f.env).prefix.appending(path: "drive_c/Program Files (x86)/Steam")
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "steamclient64.dll").path(percentEncoded: false)))
    var env = f.env
    env["MACNEUTRON_NO_STEAM_BRIDGE"] = "1"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    for name in ["steam.exe", "steamclient64.dll", "steamclient.dll"] {
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false)))
    }
}

@Test func anyDirectStartTakesLeftoverBridgeFilesOut() throws {
    // Same abort as with the escape hatch when the runtime or tool folder loses a bridge file.
    let f = try makeFixture(bridge: true)
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    try FileManager.default.removeItem(at: f.launcher.layout.steamHelper)
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    let folder = try CompatContext(environment: f.env).prefix.appending(path: "drive_c/Program Files (x86)/Steam")
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "steamclient64.dll").path(percentEncoded: false)))
}

@Test func gameLogsHideTheSteamAccount() throws {
    // People post game logs in bug reports; the account ID leads straight to a Steam profile.
    let f = try makeFixture(bridge: true)
    var env = f.env
    env["MACNEUTRON_LOG"] = "1"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    let log = try String(contentsOf: f.launcher.log.gameLog(appID: "42"), encoding: .utf8)
    #expect(log.contains("MACNEUTRON_STEAM_ACCOUNT=<redacted>"))
    #expect(!log.contains("MACNEUTRON_STEAM_ACCOUNT=1\n"))
    #expect(f.runner.calls.last?.environment["MACNEUTRON_STEAM_ACCOUNT"] == "1")
}
