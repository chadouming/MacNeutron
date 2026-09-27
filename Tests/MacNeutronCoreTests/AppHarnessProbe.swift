import Testing
@testable import MacNeutronApp
@testable import MacNeutronCore

@MainActor @Test func appModuleIsTestable() {
    let row = GameRow(app: AppInfo(appID: 1, name: "", type: "game", oslist: ["windows", "macos"]), installed: false, settings: GameSettings())
    #expect(row.isDualPlatform)
    #expect(row.name == "App 1")
}
