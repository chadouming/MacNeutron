import Foundation
import Testing
@testable import MacNeutronCore

/// A tiny tarball shaped like winecx-gptk's `Libraries.tar.gz`, and a pin that matches it.
private func makeRuntimeTarball(includeWineserver: Bool = true) throws -> (URL, RuntimePin) {
    let src = try makeTempDir()
    try write("#!/bin/sh\necho wine\n", to: src.appending(path: "Libraries/Wine/bin/wine"), executable: true)
    if includeWineserver {
        try write("#!/bin/sh\n", to: src.appending(path: "Libraries/Wine/bin/wineserver"), executable: true)
    }
    try write("dxmt", to: src.appending(path: "Libraries/DXMT/x64/d3d11.dll"))
    let tarball = try makeTempDir().appending(path: "Libraries.tar.gz")
    let status = try SystemProcessRunner().run(URL(filePath: "/usr/bin/tar"),
        ["-czf", tarball.path(percentEncoded: false), "-C", src.path(percentEncoded: false), "Libraries"],
        environment: [:], output: nil)
    #expect(status == 0)
    return (tarball, RuntimePin(version: "runtime-test-1", url: tarball, sha256: try RuntimeInstaller.sha256(of: tarball)))
}

/// Stands in for bin/macneutron: prints each argument on its own line.
private func makeEchoLauncher() throws -> URL {
    let url = try makeTempDir().appending(path: "macneutron")
    try write("#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n", to: url, executable: true)
    return url
}

@Test func installsRuntimeAndToolFiles() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = ToolLayout(root: try makeTempDir().appending(path: "compatibilitytools.d/macneutron"))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    let fm = FileManager.default
    #expect(fm.isExecutableFile(atPath: layout.wine.path(percentEncoded: false)))
    #expect(layout.runtimeVersion == "runtime-test-1")
    #expect(fm.isExecutableFile(atPath: layout.root.appending(path: "proton").path(percentEncoded: false)))
    #expect(fm.isExecutableFile(atPath: layout.launcherBinary.path(percentEncoded: false)))
    let tool = try String(contentsOf: layout.root.appending(path: "compatibilitytool.vdf"), encoding: .utf8)
    #expect(tool.contains(#""to_oslist"    "linux""#))
    let manifest = try String(contentsOf: layout.root.appending(path: "toolmanifest.vdf"), encoding: .utf8)
    #expect(manifest.contains(#""commandline" "/proton %verb%""#))
    #expect(!fm.fileExists(atPath: layout.root.appending(path: "runtime.staging").path(percentEncoded: false)))
    #expect(!fm.fileExists(atPath: layout.steamHelper.path(percentEncoded: false)))  // none next to the echo launcher
}

@Test func protonStubForwardsArgumentsFromAPathWithSpaces() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = ToolLayout(root: try makeTempDir().appending(path: "Application Support/macneutron"))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    let out = try makeTempDir().appending(path: "out.txt")
    let status = try SystemProcessRunner().run(layout.root.appending(path: "proton"),
        ["waitforexitandrun", "/Steam Library/Game.exe", "a b", "\"q\""], environment: [:], output: out)
    #expect(status == 0)
    #expect(try String(contentsOf: out, encoding: .utf8)
        == "launch\nwaitforexitandrun\n/Steam Library/Game.exe\na b\n\"q\"\n")
}

@Test func checksumMismatchChangesNothing() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = try makeToolLayout()
    let bad = RuntimePin(version: pin.version, url: pin.url, sha256: String(repeating: "0", count: 64))
    #expect(throws: RuntimeInstallError.self) {
        try RuntimeInstaller.install(tarball: tarball, pin: bad, layout: layout, launcherBinary: try makeEchoLauncher())
    }
    #expect(layout.runtimeVersion == "runtime-test")
}

@Test func archiveWithoutWineserverKeepsOldRuntime() throws {
    let (tarball, pin) = try makeRuntimeTarball(includeWineserver: false)
    let layout = try makeToolLayout()
    #expect(throws: RuntimeInstallError.badArchive("missing Libraries/Wine/bin/wineserver")) {
        try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    }
    #expect(FileManager.default.isExecutableFile(atPath: layout.wineserver.path(percentEncoded: false)))
    #expect(layout.runtimeVersion == "runtime-test")
}

@Test func reinstallReappliesImportedGPTK() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = try makeToolLayout()
    try write("apple dxgi", to: layout.gptkStore.appending(path: "lib/wine/x86_64-windows/dxgi.dll"))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    let dxgi = layout.wineLib.appending(path: "wine/x86_64-windows/dxgi.dll")
    #expect(try String(contentsOf: dxgi, encoding: .utf8) == "apple dxgi")
}

@Test func installPutsSteamExeNextToTheLauncher() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    let launcher = try makeEchoLauncher()
    try write("steam.exe v1", to: launcher.deletingLastPathComponent().appending(path: "steam.exe"))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: launcher)
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
