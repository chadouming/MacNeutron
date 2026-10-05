import Foundation
import Testing
@testable import MacNeutronCore

/// Stands in for bin/macneutron: prints each argument on its own line.
private func makeEchoLauncher() throws -> URL {
    let url = try makeTempDir().appending(path: "macneutron")
    try write("#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n", to: url, executable: true)
    return url
}

@Test func protonStubForwardsArgumentsFromAPathWithSpaces() throws {
    let layout = ToolLayout(root: try makeTempDir().appending(path: "Application Support/macneutron"))
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: try makeEchoLauncher())
    let out = try makeTempDir().appending(path: "out.txt")
    let status = try SystemProcessRunner().run(layout.root.appending(path: "proton"),
        ["waitforexitandrun", "/Steam Library/Game.exe", "a b", "\"q\""], environment: [:], output: out)
    #expect(status == 0)
    #expect(try String(contentsOf: out, encoding: .utf8)
        == "launch\nwaitforexitandrun\n/Steam Library/Game.exe\na b\n\"q\"\n")
}

@Test func installPutsSteamExeNextToTheLauncher() throws {
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    let launcher = try makeEchoLauncher()
    try write("steam.exe v1", to: launcher.deletingLastPathComponent().appending(path: "steam.exe"))
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    #expect(try String(contentsOf: layout.steamHelper, encoding: .utf8) == "steam.exe v1")
}

@Test func toolFilesRefreshReplacesAChangedLauncher() throws {
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    let launcher = try makeEchoLauncher()
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    try write("#!/bin/sh\necho v2\n", to: launcher, executable: true)
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    #expect(try String(contentsOf: layout.launcherBinary, encoding: .utf8) == "#!/bin/sh\necho v2\n")
    #expect(FileManager.default.isExecutableFile(atPath: layout.launcherBinary.path(percentEncoded: false)))
}

@Test func identicalToolFilesAreLeftAlone() throws {
    // The app refreshes tool files at every start; a game Steam launches meanwhile must never
    // find bin/macneutron missing or half-written.
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    let launcher = try makeEchoLauncher()
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    func inode() throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: layout.launcherBinary.path(percentEncoded: false))[.systemFileNumber]
            as? NSNumber)?.intValue
    }
    let before = try inode()
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    #expect(try inode() == before)
}

@Test func installFindsSteamExeInTheAppsResources() throws {
    // In MacNeutron.app the launcher is Contents/Helpers/macneutron; steam.exe isn't Mach-O code,
    // so codesign only accepts it in Contents/Resources.
    let contents = try makeTempDir().appending(path: "MacNeutron.app/Contents", directoryHint: .isDirectory)
    let launcher = contents.appending(path: "Helpers/macneutron")
    try write("#!/bin/sh\n", to: launcher, executable: true)
    try write("steam.exe from resources", to: contents.appending(path: "Resources/steam.exe"))
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    #expect(try String(contentsOf: layout.steamHelper, encoding: .utf8) == "steam.exe from resources")
}

