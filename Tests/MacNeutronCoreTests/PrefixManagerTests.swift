import Foundation
import Testing
@testable import MacNeutronCore

private func makeManager(_ runner: FakeRunner) throws -> (PrefixManager, [String: String]) {
    let layout = try makeToolLayout()
    let env = steamEnvironment(dataPath: try makeTempDir().appending(path: "compatdata/42"))
    let context = try CompatContext(environment: env)
    let wineEnv = LaunchEnvironment.build(base: env, context: context, backend: .dxmt, logging: false)
    return (PrefixManager(context: context, layout: layout, runtimeVersion: "runtime-test", runner: runner), wineEnv)
}

@Test func freshPrefixRunsWinebootAndRecordsVersion() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try manager.prepare(backend: .dxmt, environment: env)
    #expect(runner.calls.map(\.arguments) == [["wineboot", "-u"], disableCrashDialog])
    #expect(runner.calls[0].environment["WINEPREFIX"] == manager.context.prefix.path(percentEncoded: false))
    #expect(try String(contentsOf: manager.context.versionFile, encoding: .utf8) == "runtime-test")
    #expect(!manager.needsPreparation)
}

/// A crashing game must exit, not wait forever behind Wine's crash window (Steam would show it running).
private let disableCrashDialog = ["reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog",
                                  "/t", "REG_DWORD", "/d", "0", "/f"]

@Test func failedWinebootSkipsTheCrashDialogSetting() throws {
    let runner = winebootCreatingPrefix(status: 3)
    let (manager, env) = try makeManager(runner)
    #expect(throws: PrefixError.winebootFailed(3)) { try manager.prepare(backend: .dxmt, environment: env) }
    #expect(!runner.calls.contains { $0.arguments == disableCrashDialog })
}

@Test func upToDatePrefixSkipsWineboot() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try manager.prepare(backend: .dxmt, environment: env)
    try manager.prepare(backend: .dxmt, environment: env)
    #expect(runner.calls.filter { $0.arguments.first == "wineboot" }.count == 1)
}

@Test func runtimeChangeUpgradesPrefix() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try manager.prepare(backend: .dxmt, environment: env)
    try write("runtime-old", to: manager.context.versionFile)
    try manager.prepare(backend: .dxmt, environment: env)
    #expect(runner.calls.filter { $0.arguments.first == "wineboot" }.count == 2)
}

@Test func failedWinebootKeepsPrefixAndVersion() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix(status: 3))
    let save = manager.context.prefix.appending(path: "drive_c/users/steamuser/save.dat")
    try write("progress", to: save)
    try write("runtime-old", to: manager.context.versionFile)
    #expect(throws: PrefixError.winebootFailed(3)) { try manager.prepare(backend: .dxmt, environment: env) }
    #expect(try String(contentsOf: save, encoding: .utf8) == "progress")
    #expect(try String(contentsOf: manager.context.versionFile, encoding: .utf8) == "runtime-old")
}

@Test func deploysBackendDLLsIntoBothSystemFolders() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try manager.prepare(backend: .dxmt, environment: env)
    let system32 = manager.context.prefix.appending(path: "drive_c/windows/system32/d3d11.dll")
    let syswow64 = manager.context.prefix.appending(path: "drive_c/windows/syswow64/d3d11.dll")
    #expect(try String(contentsOf: system32, encoding: .utf8) == "dxmt x64 d3d11.dll")
    #expect(try String(contentsOf: syswow64, encoding: .utf8) == "dxmt x32 d3d11.dll")
    try manager.prepare(backend: .dxvk, environment: env)
    #expect(try String(contentsOf: system32, encoding: .utf8) == "dxvk x64 d3d11.dll")
}

@Test func missingRuntimeDLLIsAnError() throws {
    // Silently skipping it once left DXMT's dxgi in place under DXVK.
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try FileManager.default.removeItem(at: manager.layout.dxvk.appending(path: "x64/d3d11.dll"))
    #expect(throws: PrefixError.self) { try manager.prepare(backend: .dxvk, environment: env) }
}

@Test func concurrentLaunchesRunWinebootOnce() async throws {
    // Steam starts iscriptevaluator (`run`) and the game close together on first launch.
    let runner = winebootCreatingPrefix(delay: 0.3)
    let (manager, env) = try makeManager(runner)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<2 {
            group.addTask { try manager.prepare(backend: .dxmt, environment: env) }
        }
        try await group.waitForAll()
    }
    #expect(runner.calls.filter { $0.arguments.first == "wineboot" }.count == 1)
}

@Test func systemRunnerReportsStatusAndCapturesOutput() throws {
    let log = try makeTempDir().appending(path: "out.log")
    let status = try SystemProcessRunner().run(URL(filePath: "/bin/sh"), ["-c", "echo \"$1\"; exit 3", "sh", "a b"],
                                               environment: [:], output: log)
    #expect(status == 3)
    #expect(try String(contentsOf: log, encoding: .utf8) == "a b\n")
}
