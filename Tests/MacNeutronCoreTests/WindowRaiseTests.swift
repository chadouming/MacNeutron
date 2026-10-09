import Testing
@testable import MacNeutronApp

@Test func findsTheRequestedSceneWindow() {
    #expect(isWindow("games-AppWindow-1", of: "games"))
    #expect(isWindow("settings-AppWindow-2", of: "settings"))
    #expect(!isWindow("setup-AppWindow-1", of: "games"))
    #expect(!isWindow("games", of: "games"))
    #expect(!isWindow(nil, of: "games"))  // status-item and menu windows have no identifier
}
