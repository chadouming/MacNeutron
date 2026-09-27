import Foundation
import Testing
@testable import MacNeutronCore

func makeMode(session: String = okSession, config: String = steamConfigFixture,
              running: Bool = false) throws -> (SteamPlayMode, FakeSteam) {
    let (steam, root) = try makeFakeSteam(config: config)
    let fake = FakeSteam(steam: steam, running: running, session: session)
    var mode = SteamPlayMode(steam: steam, root: root, process: fake)
    mode.verifyTimeout = .seconds(2)
    return (mode, fake)
}

let samplePlan = [
    "0": ToolMapping(tool: "macneutron", priority: 75),
    "1062090": ToolMapping(tool: "macneutron-native", priority: 250),
    "2977660": ToolMapping(tool: "macneutron", priority: 250),
]

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

@Test func enableWritesEverythingAndVerifies() async throws {
    let (mode, fake) = try makeMode()
    try await mode.enable(plan: samplePlan)
    #expect(mode.isWanted)
    #expect(mode.filesIntact)
    #expect(try mode.currentMappings() == samplePlan)
    #expect(fake.launchesWithDevConfig == [true])
    #expect(mode.status(plan: samplePlan) == .on)
    #expect(try String(contentsOf: mode.steam.steamDevConfig, encoding: .utf8) == "@sSteamCmdForcePlatformType linux\n")
}

@Test func failedVerificationRollsBackWithDevConfigRemovedFirst() async throws {
    let (mode, fake) = try makeMode(session: macModeSession)
    let original = try String(contentsOf: mode.steam.configVDF, encoding: .utf8)
    await #expect(throws: SteamPlayError.verificationFailed("Steam started as a Mac client and ignored MacNeutron")) {
        try await mode.enable(plan: samplePlan)
    }
    #expect(!exists(mode.steam.steamDevConfig))
    #expect(!exists(mode.link("macneutron")))
    #expect(try String(contentsOf: mode.steam.configVDF, encoding: .utf8) == original)
    #expect(!mode.isWanted)
    #expect(fake.launchesWithDevConfig == [true, false])
}

@Test func unreadableConfigChangesNothing() async throws {
    let (mode, fake) = try makeMode(config: "\"InstallConfigStore\"\n{\n")
    await #expect(throws: SteamPlayError.self) { try await mode.enable(plan: samplePlan) }
    #expect(!exists(mode.steam.steamDevConfig))
    #expect(!exists(mode.link("macneutron")))
    #expect(fake.launchesWithDevConfig.isEmpty)
}

@Test func mappingsAreNeverWrittenWhileSteamRuns() throws {
    let (mode, _) = try makeMode(running: true)
    #expect(throws: SteamPlayError.steamRunning) { try mode.applyMappings(samplePlan) }
}

@Test func everyWriteIsBackedUpFirst() throws {
    let (mode, _) = try makeMode()
    let original = try Data(contentsOf: mode.steam.configVDF)
    try mode.applyMappings(samplePlan)
    let backups = try FileManager.default.contentsOfDirectory(at: mode.backups, includingPropertiesForKeys: nil)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == original)
    #expect(try String(contentsOf: mode.steam.configVDF, encoding: .utf8).contains("\"proton_9\""))
}

@Test func syncOnlyWritesWhenThePlanChanged() async throws {
    let (mode, fake) = try makeMode()
    try await mode.enable(plan: samplePlan)
    try await fake.quit(timeout: .seconds(1))
    #expect(try mode.sync(plan: samplePlan) == false)
    var newPlan = samplePlan
    newPlan["3419430"] = ToolMapping(tool: "macneutron-native", priority: 250)
    #expect(try mode.sync(plan: newPlan) == true)
    #expect(try mode.currentMappings() == newPlan)
}

@Test func statusShowsPendingChangesAndLostFiles() async throws {
    let (mode, _) = try makeMode()
    #expect(mode.status(plan: samplePlan) == .off)
    try await mode.enable(plan: samplePlan)
    var newPlan = samplePlan
    newPlan["1"] = ToolMapping(tool: "macneutron", priority: 250)
    newPlan["2977660"] = nil
    #expect(mode.status(plan: newPlan) == .restartNeeded(2))
    try FileManager.default.removeItem(at: mode.steam.steamDevConfig)  // what a Steam update does
    #expect(mode.status(plan: samplePlan) == .lost)
}

@Test func disableRemovesOnlyWhatEnableAdded() async throws {
    let (mode, fake) = try makeMode()
    try await mode.enable(plan: samplePlan)
    try await mode.disable()
    #expect(!exists(mode.steam.steamDevConfig))
    #expect(!exists(mode.link("macneutron-native")))
    #expect(try mode.currentMappings().isEmpty)
    #expect(try String(contentsOf: mode.steam.configVDF, encoding: .utf8).contains("\"proton_9\""))
    #expect(!mode.isWanted)
    #expect(fake.launchesWithDevConfig == [true, false])
}

@Test func passthroughRunsTheMacGameItself() async throws {
    let (mode, _) = try makeMode()
    try await mode.enable(plan: samplePlan)
    let out = try makeTempDir().appending(path: "out.txt")
    let status = try SystemProcessRunner().run(mode.link("macneutron-native").appending(path: "passthrough.sh"),
                                               ["waitforexitandrun", "/bin/echo", "a b"], environment: [:], output: out)
    #expect(status == 0)
    #expect(try String(contentsOf: out, encoding: .utf8) == "a b\n")
}

@Test(arguments: [
    (okSession, nil),
    (macModeSession, "Steam started as a Mac client and ignored MacNeutron"),
    ("Client version: 1\nRegistering tool macneutron, AppID 0\nRecording non-user mapping", "Steam didn't find MacNeutron's tools"),
    ("Client version: 1\nRegistering tool macneutron, AppID 0\nRegistering tool macneutron-native, AppID 0\n",
     "Steam didn't switch to Steam Play mode"),
] as [(String, String?)])
func verifiesCompatLogSessions(log: String, problem: String?) {
    #expect(SteamPlayMode.verify(log: log) == problem)
}

@Test func lastSessionIgnoresEarlierRuns() {
    #expect(SteamPlayMode.verify(log: SteamPlayMode.lastSession(of: macModeSession + okSession)) == nil)
    #expect(SteamPlayMode.verify(log: SteamPlayMode.lastSession(of: okSession + macModeSession)) != nil)
}


@Test func passthroughLaunchesAppBundles() async throws {
    // Steam's launch entry for many Mac games is the .app folder itself (Timberborn's is).
    let (mode, _) = try makeMode()
    try await mode.enable(plan: samplePlan)
    let app = try makeTempDir().appending(path: "My Game.app", directoryHint: .isDirectory)
    try write("#!/bin/sh\necho \"$@\"\n", to: app.appending(path: "Contents/MacOS/Game Binary"), executable: true)
    let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Game Binary"], format: .xml, options: 0)
    try info.write(to: app.appending(path: "Contents/Info.plist"))
    let out = try makeTempDir().appending(path: "out.txt")
    let status = try SystemProcessRunner().run(mode.link("macneutron-native").appending(path: "passthrough.sh"),
                                               ["waitforexitandrun", app.path(percentEncoded: false), "a b"],
                                               environment: [:], output: out)
    #expect(status == 0)
    #expect(try String(contentsOf: out, encoding: .utf8) == "a b\n")
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: Preflight.rosettaRuntime.path(percentEncoded: false))))
func passthroughPrefersTheAppleSiliconBuild() async throws {
    // Steam starts tools preferring x86_64; without an override a universal game would run under Rosetta.
    let (mode, _) = try makeMode()
    try await mode.enable(plan: samplePlan)
    let out = try makeTempDir().appending(path: "arch.txt")
    let script = mode.link("macneutron-native").appending(path: "passthrough.sh").path(percentEncoded: false)
    let status = try SystemProcessRunner().run(URL(filePath: "/usr/bin/arch"),
                                               ["-x86_64", "/bin/sh", script, "waitforexitandrun", "/usr/bin/uname", "-m"],
                                               environment: [:], output: out)
    #expect(status == 0)
    #expect(try String(contentsOf: out, encoding: .utf8) == "arm64\n")
}
