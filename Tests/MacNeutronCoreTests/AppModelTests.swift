import Foundation
import ServiceManagement
import Testing
@testable import MacNeutronApp
@testable import MacNeutronCore

private let timberborn = AppInfo(appID: 1062090, name: "Timberborn", type: "game", oslist: ["windows", "macos"])
private let bongoCat = AppInfo(appID: 3419430, name: "Bongo Cat", type: "game", oslist: ["windows", "macos"])
private let cats = AppInfo(appID: 2977660, name: "Cats", type: "game", oslist: ["windows"])

/// A login item that remembers what it was asked to do.
final class FakeLoginItem: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SMAppService.Status = .notRegistered
    let statusAfterRegister: SMAppService.Status
    init(statusAfterRegister: SMAppService.Status) { self.statusAfterRegister = statusAfterRegister }
    var item: LoginItem {
        LoginItem(status: { self.lock.withLock { self.current } },
                  register: { self.lock.withLock { self.current = self.statusAfterRegister } },
                  unregister: { self.lock.withLock { self.current = .notRegistered } })
    }
}

@MainActor
private func makeModel(steamRunning: Bool = false,
                       loginItem: LoginItem = FakeLoginItem(statusAfterRegister: .enabled).item) async throws
    -> (AppModel, SteamPlayMode, FakeSteam) {
    let (mode, fake) = try makeMode()
    let apps = [timberborn, bongoCat, cats]
    try FileManager.default.createDirectory(at: mode.steam.appInfo.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makeAppInfoV29(apps).write(to: mode.steam.appInfo)
    try await mode.enable(plan: MappingPlanner.plan(apps: apps, runAs: [:]))
    if !steamRunning { try await fake.quit(timeout: .seconds(1)) }
    let model = AppModel(steam: mode.steam, layout: try makeToolLayout(), mode: mode,
                         store: GameSettingsStore(directory: try makeTempDir().appending(path: "games")), loginItem: loginItem)
    await model.refresh()
    return (model, mode, fake)
}

@MainActor @Test func runsAsChangeAppliesImmediatelyWhenSteamIsClosed() async throws {
    let (model, mode, _) = try await makeModel()
    await model.update(bongoCat.appID) { $0.runAs = .windows }
    #expect(try mode.currentMappings()["3419430"]?.tool == "macneutron")
    #expect(model.status == .on)
}

@MainActor @Test func runsAsChangeWaitsForARestartWhileSteamRuns() async throws {
    let (model, mode, _) = try await makeModel(steamRunning: true)
    await model.update(bongoCat.appID) { $0.runAs = .windows }
    #expect(try mode.currentMappings()["3419430"]?.tool == "macneutron-native")
    #expect(model.status == .restartNeeded(1))
}

@MainActor @Test func refreshKeepsTheLastGoodAppListWhenSteamsCacheIsUnreadable() async throws {
    let (model, mode, _) = try await makeModel()
    try Data("garbage".utf8).write(to: mode.steam.appInfo)
    await model.refresh()
    #expect(model.appInfoError != nil)
    #expect(model.games.map(\.id).sorted() == [1062090, 2977660, 3419430])
}

@Test func snapshotsLoadOffTheMainActor() async throws {
    let (mode, _) = try makeMode()
    try FileManager.default.createDirectory(at: mode.steam.appInfo.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makeAppInfoV29([cats]).write(to: mode.steam.appInfo)
    let store = GameSettingsStore(directory: try makeTempDir())
    let layout = try makeToolLayout()
    let snapshot = await Task.detached {
        AppModel.loadSnapshot(steam: mode.steam, layout: layout, store: store, mode: mode, fallbackApps: [])
    }.value
    #expect(snapshot.apps.map(\.appID) == [2977660])
    #expect(snapshot.status == .off)
}

@MainActor @Test func loginToggleReportsWhenMacOSWantsApproval() async throws {
    let login = FakeLoginItem(statusAfterRegister: .requiresApproval)
    let (model, _, _) = try await makeModel(loginItem: login.item)
    model.setLaunchAtLogin(true)
    #expect(model.loginItemStatus == .requiresApproval)
    #expect(model.errorMessage == nil)
}

@MainActor @Test func setupWindowStaysClosedOnceSetUp() async throws {
    let (model, mode, _) = try await makeModel()
    try write("runtime-v4.7.3", to: model.layout.runtimeVersionFile)
    let relaunched = AppModel(steam: mode.steam, layout: model.layout, mode: mode, store: model.store,
                              loginItem: model.loginItem)
    #expect(relaunched.setupComplete)  // the scene reads it before any refresh finishes
}

@MainActor @Test func aSnapshotReadBeforeAChangeDoesNotUndoIt() async throws {
    let (model, mode, _) = try await makeModel()
    let token = model.generation
    let stale = AppModel.loadSnapshot(steam: mode.steam, layout: model.layout, store: model.store, mode: mode,
                                      fallbackApps: [])
    await model.update(bongoCat.appID) { $0.runAs = .windows }
    model.apply(stale, generation: token)
    #expect(model.games.first { $0.id == bongoCat.appID }?.settings.runAs == .windows)
}
