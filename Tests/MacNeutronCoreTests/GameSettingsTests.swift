import Foundation
import Testing
@testable import MacNeutronCore

@Test func settingsBecomeLaunchVariables() {
    #expect(GameSettings(graphics: "dxmt", log: true, avx: false, msync: false, runAs: .windows).environment == [
        "MACNEUTRON_GRAPHICS": "dxmt", "MACNEUTRON_LOG": "1", "MACNEUTRON_NO_AVX": "1", "MACNEUTRON_NO_MSYNC": "1",
    ])
    #expect(GameSettings(log: false, avx: true, msync: true).environment.isEmpty)
}

@Test func storeRoundTripsAndDefaultsWhenMissing() throws {
    let store = GameSettingsStore(directory: try makeTempDir().appending(path: "games"))
    #expect(try store.load("7") == GameSettings())
    try store.save(GameSettings(graphics: "d3dmetal", runAs: .windows), for: "7")
    #expect(try store.load("7") == GameSettings(graphics: "d3dmetal", runAs: .windows))
    #expect(store.runAsOverrides() == [7: .windows])
}

@Test func corruptFilesThrowAndAreSkippedByAll() throws {
    let store = GameSettingsStore(directory: try makeTempDir())
    try write("{", to: store.directory.appending(path: "8.json"))
    #expect(throws: (any Error).self) { try store.load("8") }
    #expect(store.all().isEmpty)
}
