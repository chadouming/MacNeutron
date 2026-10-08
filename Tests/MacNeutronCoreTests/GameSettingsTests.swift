import Foundation
import Testing
@testable import MacNeutronCore

@Test func settingsBecomeLaunchVariables() {
    #expect(GameSettings(graphics: "dxmt", log: true, msync: false, runAs: .windows, metalFX: false).environment == [
        "MACNEUTRON_GRAPHICS": "dxmt", "MACNEUTRON_LOG": "1", "MACNEUTRON_NO_MSYNC": "1", "MACNEUTRON_NO_METALFX": "1",
    ])
    #expect(GameSettings(log: false, msync: true, metalFX: true).environment.isEmpty)
    #expect(GameSettings(postAA: "cmaa2").environment == ["MACNEUTRON_POST_AA": "cmaa2"])
    #expect(GameSettings(postAA: "off").environment.isEmpty)
}

@Test func storeRoundTripsAndDefaultsWhenMissing() throws {
    let store = GameSettingsStore(directory: try makeTempDir().appending(path: "games"))
    #expect(try store.load("7") == GameSettings())
    try store.save(GameSettings(graphics: "wined3d", runAs: .windows), for: "7")
    #expect(try store.load("7") == GameSettings(graphics: "wined3d", runAs: .windows))
    #expect(store.runAsOverrides() == [7: .windows])
}

@Test func corruptFilesThrowAndAreSkippedByAll() throws {
    let store = GameSettingsStore(directory: try makeTempDir())
    try write("{", to: store.directory.appending(path: "8.json"))
    #expect(throws: (any Error).self) { try store.load("8") }
    #expect(store.all().isEmpty)
}

@Test func oldSettingsFilesStillLoad() throws {
    // Written by a Rosetta-era build: `avx` is gone and is ignored; the launcher reads `d3dmetal` as DXMT.
    let store = GameSettingsStore(directory: try makeTempDir())
    try write(#"{"avx":false,"graphics":"d3dmetal"}"#, to: store.directory.appending(path: "9.json"))
    #expect(try store.load("9") == GameSettings(graphics: "d3dmetal"))
}
