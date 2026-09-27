import Foundation
import Testing
@testable import MacProtonCore

@Test func readsSteamCompatEnvironment() throws {
    let context = try CompatContext(environment: [
        "STEAM_COMPAT_DATA_PATH": "/Users/me/Library/Application Support/Steam/steamapps/compatdata/42",
        "SteamAppId": "42",
    ])
    #expect(context.appID == "42")
    #expect(context.prefix.path(percentEncoded: false)
        == "/Users/me/Library/Application Support/Steam/steamapps/compatdata/42/pfx/")
    #expect(context.versionFile.lastPathComponent == "version")
    #expect(context.lockFile.lastPathComponent == "macproton.lock")
}

@Test func appIDDefaultsToZero() throws {
    let context = try CompatContext(environment: ["STEAM_COMPAT_DATA_PATH": "/tmp/x", "SteamAppId": ""])
    #expect(context.appID == "0")
}

@Test func missingDataPathIsAnError() {
    #expect(throws: CompatContextError.missing("STEAM_COMPAT_DATA_PATH")) {
        try CompatContext(environment: ["SteamAppId": "42"])
    }
}

@Test func layoutPathsFollowTheRuntimeTarball() {
    let layout = ToolLayout(root: URL(filePath: "/t/macproton", directoryHint: .isDirectory))
    #expect(layout.wine.path(percentEncoded: false) == "/t/macproton/Libraries/Wine/bin/wine")
    #expect(layout.wineserver.path(percentEncoded: false) == "/t/macproton/Libraries/Wine/bin/wineserver")
    #expect(layout.wineLib.path(percentEncoded: false) == "/t/macproton/Libraries/Wine/lib/")
    #expect(layout.dxmt.path(percentEncoded: false) == "/t/macproton/Libraries/DXMT/")
    #expect(layout.gptkStore.path(percentEncoded: false) == "/t/macproton/gptk/")
}

@Test func layoutFromExecutableIsTwoLevelsUp() {
    let layout = ToolLayout(executable: URL(filePath: "/t/macproton/bin/macproton"))
    #expect(layout.root.path(percentEncoded: false).hasSuffix("/t/macproton/"))
}

@Test func runtimeAndGPTKVersionsComeFromFiles() throws {
    let layout = ToolLayout(root: try makeTempDir())
    #expect(layout.runtimeVersion == nil)
    #expect(!layout.gptkImported)
    try write("runtime-v4.7.3\n", to: layout.runtimeVersionFile)
    try write(#"{"version":"3.0","importedAt":"2026-09-27T00:00:00Z"}"#, to: layout.gptkManifest)
    #expect(layout.runtimeVersion == "runtime-v4.7.3")
    #expect(layout.gptkVersion == "3.0")
    #expect(layout.gptkImported)
}
