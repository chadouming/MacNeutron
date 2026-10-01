import Foundation
import Testing
@testable import MacNeutronCore

private struct PrecacheFixture {
    let launcher: Launcher
    let runner: FakeRunner
    let notifier: RecordingNotifier
    let env: [String: String]
    let folder: URL
    let builds: String
    var stamp: String? { try? String(contentsOf: folder.appending(path: "replayed"), encoding: .utf8) }
    var replays: [FakeRunner.Call] { runner.calls.filter { $0.arguments.first?.hasSuffix("dxmt-replay.exe") == true } }
    var launcherLog: String { (try? String(contentsOf: launcher.log.launcherLog, encoding: .utf8)) ?? "" }
}

/// A launcher whose tool folder has our DXMT with Direct3D 12 and the replayer. The fake dxmt-replay.exe writes a
/// result line to its output and returns `replayStatus`.
private func makePrecacheFixture(replayStatus: Int32 = 0,
                                 onReplay: (@Sendable (FakeRunner.Call) -> Void)? = nil) throws -> PrecacheFixture {
    let layout = try makeToolLayout()
    try write("ours d3d12", to: layout.dxmtD3D12)
    try write("ours replay", to: layout.dxmtReplay)
    try write("fork123\n", to: layout.dxmtVersionFile)
    let runner = FakeRunner { call in
        if call.arguments.first == "wineboot", let prefix = call.environment["WINEPREFIX"] {
            try? FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        }
        if call.arguments.first?.hasSuffix("dxmt-replay.exe") == true, let output = call.output {
            try? "replay progress 2/2\r\nreplay: 2 pipelines (1 graphics, 1 compute), 2 created, 0 failed, 0 bad records, 5 ms\r\n"
                .write(to: output, atomically: true, encoding: .utf8)
            onReplay?(call)
            return replayStatus
        }
        return 0
    }
    let notifier = RecordingNotifier()
    let data = try makeTempDir().appending(path: "compatdata/42", directoryHint: .isDirectory)
    let launcher = Launcher(layout: layout, runner: runner,
                            log: LauncherLog(directory: try makeTempDir().appending(path: "Logs")),
                            notifier: notifier, preflight: Preflight(rosettaAvailable: { true }),
                            settings: GameSettingsStore(directory: try makeTempDir().appending(path: "games")),
                            steam: try makeSteamLocation())
    let env = steamEnvironment(dataPath: data, appID: "42")
    let context = try CompatContext(environment: env)
    return PrecacheFixture(launcher: launcher, runner: runner, notifier: notifier, env: env,
                           folder: ShaderPrecache.folder(for: context),
                           builds: "fork123 \(ShaderPrecache.macOSBuild())")
}

private let game = ["waitforexitandrun", "/g/Game.exe"]

@Test func theGameRecordsIntoItsCompatFolder() throws {
    let f = try makePrecacheFixture()
    _ = f.launcher.launch(game, environment: f.env)
    let run = f.runner.calls.first { $0.arguments == ["/g/Game.exe"] }
    #expect(run?.environment["DXMT_PIPELINE_RECORD"] == f.folder.path(percentEncoded: false))
    #expect(f.folder.path(percentEncoded: false).hasSuffix("compatdata/42/dxmt-pipelines"))
}

@Test func theFirstSessionStampsWithoutReplaying() throws {
    let f = try makePrecacheFixture()
    #expect(f.launcher.launch(game, environment: f.env) == 0)
    #expect(f.replays.isEmpty)
    #expect(f.stamp == f.builds + "\n")
}

@Test func recordingsWithoutAStampAreNotReplayed() throws {
    let f = try makePrecacheFixture()
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    _ = f.launcher.launch(game, environment: f.env)
    #expect(f.replays.isEmpty)
    #expect(f.stamp == f.builds + "\n")
}

@Test func theSameBuildsDoNotReplay() throws {
    let f = try makePrecacheFixture()
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    try write(f.builds + "\n", to: f.folder.appending(path: "replayed"))
    _ = f.launcher.launch(game, environment: f.env)
    #expect(f.replays.isEmpty)
}

@Test func changedBuildsReplayEveryRecordingBeforeTheGame() throws {
    let f = try makePrecacheFixture()
    let a = f.folder.appending(path: "A.exe.pipelines"), b = f.folder.appending(path: "B.exe.pipelines")
    try write("rec", to: a)
    try write("rec", to: b)
    try write("old 1A2\n", to: f.folder.appending(path: "replayed"))
    #expect(f.launcher.launch(game, environment: f.env) == 0)
    #expect(f.replays.map { $0.arguments } == [
        [f.launcher.layout.dxmtReplay.path(percentEncoded: false), "Z:" + a.path(percentEncoded: false)],
        [f.launcher.layout.dxmtReplay.path(percentEncoded: false), "Z:" + b.path(percentEncoded: false)],
    ])
    #expect(f.replays.allSatisfy { $0.environment["DXMT_PIPELINE_RECORD"] == nil })
    let calls = f.runner.calls
    let lastReplay = try #require(calls.lastIndex { $0.arguments.first?.hasSuffix("dxmt-replay.exe") == true })
    let gameRun = try #require(calls.firstIndex { $0.arguments == ["/g/Game.exe"] })
    #expect(lastReplay < gameRun)
    #expect(f.stamp == f.builds + "\n")
    #expect(f.notifier.posted == ["Preparing shaders for this game (DXMT or macOS changed)"])
    #expect(f.launcherLog.contains(
        "precache: A.exe.pipelines exit=0 replay: 2 pipelines (1 graphics, 1 compute), 2 created, 0 failed, 0 bad records, 5 ms"))
}

@Test func aFailedReplayStillStartsTheGame() throws {
    let f = try makePrecacheFixture(replayStatus: 1)
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    try write("old 1A2\n", to: f.folder.appending(path: "replayed"))
    #expect(f.launcher.launch(game, environment: f.env) == 0)
    #expect(f.runner.calls.contains { $0.arguments == ["/g/Game.exe"] })
    #expect(f.stamp == f.builds + "\n")
    #expect(f.launcherLog.contains("precache: Game.exe.pipelines exit=1 "))
}

@Test func theRunVerbNeitherReplaysNorStamps() throws {
    let f = try makePrecacheFixture()
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    try write("old 1A2\n", to: f.folder.appending(path: "replayed"))
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    #expect(f.replays.isEmpty)
    #expect(f.stamp == "old 1A2\n")
}

@Test func precacheCanBeTurnedOff() throws {
    let f = try makePrecacheFixture()
    try write("rec", to: f.folder.appending(path: "Game.exe.pipelines"))
    try write("old 1A2\n", to: f.folder.appending(path: "replayed"))
    var env = f.env
    env["MACNEUTRON_PRECACHE"] = "0"
    _ = f.launcher.launch(game, environment: env)
    #expect(f.replays.isEmpty)
    #expect(f.runner.calls.first { $0.arguments == ["/g/Game.exe"] }?.environment["DXMT_PIPELINE_RECORD"] == nil)
    #expect(f.stamp == "old 1A2\n")
}

@Test func stoppingDuringTheReplayStartsNoGame() throws {
    final class Box: @unchecked Sendable { var launcher: Launcher? }
    let box = Box()
    // Steam's Stop (SIGTERM) arrives while the first recording replays.
    let f = try makePrecacheFixture { call in box.launcher?.terminate(environment: call.environment) }
    box.launcher = f.launcher
    try write("rec", to: f.folder.appending(path: "A.exe.pipelines"))
    try write("rec", to: f.folder.appending(path: "B.exe.pipelines"))
    try write("old 1A2\n", to: f.folder.appending(path: "replayed"))
    _ = f.launcher.launch(game, environment: f.env)
    #expect(f.replays.count == 1)
    #expect(!f.runner.calls.contains { $0.arguments == ["/g/Game.exe"] })
    #expect(f.stamp == "old 1A2\n")  // the next launch prepares the shaders again
}

