import Foundation
import Testing
@testable import MacNeutronCore

private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

@Test func installsBothHalvesAndTheFrontEnds() throws {
    let layout = try makeToolLayout()
    try DXMTInstaller.install(layout: layout, from: try makeDXMTBuild(in: try makeTempDir()))
    let wine = layout.wineLib.appending(path: "wine")
    #expect(try read(wine.appending(path: "x86_64-unix/winemetal.so")) == "ours winemetal.so")
    #expect(try read(wine.appending(path: "x86_64-windows/winemetal.dll")) == "ours x86_64-windows winemetal.dll")
    #expect(try read(wine.appending(path: "i386-windows/winemetal.dll")) == "ours i386-windows winemetal.dll")
    #expect(try read(layout.dxmt.appending(path: "x64/d3d12.dll")) == "ours x86_64-windows d3d12.dll")
    #expect(try read(layout.dxmt.appending(path: "x64/d3d11.dll")) == "ours x86_64-windows d3d11.dll")
    #expect(try read(layout.dxmt.appending(path: "x32/dxgi.dll")) == "ours i386-windows dxgi.dll")
    #expect(!exists(layout.dxmt.appending(path: "x32/d3d12.dll")))
    #expect(layout.dxmtVersion == "abc123")
    #expect(layout.dxmtHasD3D12)
}

@Test func dxmtPathsInTheToolFolder() {
    let layout = ToolLayout(root: URL(filePath: "/t/", directoryHint: .isDirectory))
    #expect(layout.dxmtVersionFile.path(percentEncoded: false) == "/t/dxmt-version")
    #expect(layout.dxmtD3D12.path(percentEncoded: false) == "/t/Libraries/DXMT/x64/d3d12.dll")
    #expect(!layout.dxmtHasD3D12)
    #expect(layout.dxmtVersion == nil)
}

@Test func aFailedInstallLeavesNoVersionSoTheNextStartRetries() throws {
    let layout = try makeToolLayout()
    try write("old", to: layout.dxmtVersionFile)
    let build = try makeDXMTBuild(in: try makeTempDir())
    // A copy that fails mid-install: a non-empty folder where d3d12.dll goes.
    try write("x", to: layout.dxmtD3D12.appending(path: "blocker"))
    #expect(throws: (any Error).self) { try DXMTInstaller.install(layout: layout, from: build) }
    #expect(layout.dxmtVersion == nil)
}

@Test func anIncompleteBuildIsNotABuild() throws {
    let folder = try makeTempDir()
    try makeDXMTBuild(in: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "x86_64-windows/dxgi.dll"))
    #expect(DXMTBuild(folder: folder) == nil)
}

@Test func anIncompleteBundleInstallsNothing() throws {
    // Spec §5: both halves always come from the same build, so a bundle missing a file touches nothing.
    let layout = try makeToolLayout()
    let helpers = try makeTempDir()
    try makeDXMTBuild(in: helpers.appending(path: "DXMT", directoryHint: .isDirectory))
    try FileManager.default.removeItem(at: helpers.appending(path: "DXMT/i386-windows/winemetal.dll"))
    #expect(try DXMTInstaller.installBundled(layout: layout, launcherBinary: helpers.appending(path: "macneutron")) == false)
    #expect(!exists(layout.wineLib.appending(path: "wine/x86_64-unix/winemetal.so")))
}

@Test func refusesAToolFolderWithoutARuntime() throws {
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron", directoryHint: .isDirectory))
    let build = try makeDXMTBuild(in: try makeTempDir())
    #expect(throws: DXMTInstallError.noRuntime(layout.root.path(percentEncoded: false))) {
        try DXMTInstaller.install(layout: layout, from: build)
    }
    #expect(!exists(layout.libraries))
}

@Test func findsTheBuildNextToTheLauncher() throws {
    let helpers = try makeTempDir()
    try makeDXMTBuild(in: helpers.appending(path: "DXMT", directoryHint: .isDirectory))
    let build = try #require(DXMTBuild.bundled(near: helpers.appending(path: "macneutron")))
    #expect(build.version == "abc123")
}

@Test func findsTheAppBundlesTwoHalves() throws {
    let contents = try makeTempDir().appending(path: "MacNeutron.app/Contents", directoryHint: .isDirectory)
    try makeDXMTBuild(in: contents.appending(path: "Resources/DXMT", directoryHint: .isDirectory),
                      unixFolder: contents.appending(path: "Frameworks/DXMT", directoryHint: .isDirectory))
    let build = try #require(DXMTBuild.bundled(near: contents.appending(path: "Helpers/macneutron")))
    #expect(build.windows.deletingLastPathComponent().lastPathComponent == "Resources")
    #expect(build.unix.deletingLastPathComponent().lastPathComponent == "Frameworks")
}

@Test func noBuildNearTheLauncherInstallsNothing() throws {
    let layout = try makeToolLayout()
    #expect(try DXMTInstaller.installBundled(layout: layout, launcherBinary: try makeTempDir().appending(path: "macneutron")) == false)
    #expect(layout.dxmtVersion == nil)
}

@Test func theBundledBuildIsInstalledOncePerVersion() throws {
    let layout = try makeToolLayout()
    let helpers = try makeTempDir()
    let launcher = helpers.appending(path: "macneutron")
    try makeDXMTBuild(in: helpers.appending(path: "DXMT", directoryHint: .isDirectory), version: "v1")
    #expect(try DXMTInstaller.installBundled(layout: layout, launcherBinary: launcher))
    #expect(try DXMTInstaller.installBundled(layout: layout, launcherBinary: launcher) == false)
    try makeDXMTBuild(in: helpers.appending(path: "DXMT", directoryHint: .isDirectory), version: "v2")
    #expect(try DXMTInstaller.installBundled(layout: layout, launcherBinary: launcher))
    #expect(layout.dxmtVersion == "v2")
}

@Test func installsTheReplayerBesideD3D12() throws {
    let layout = try makeToolLayout()
    let build = try makeDXMTBuild(in: try makeTempDir())
    try DXMTInstaller.install(layout: layout, from: build)
    #expect(try String(contentsOf: layout.dxmtReplay, encoding: .utf8) == "ours x86_64-windows dxmt-replay.exe")
    #expect(layout.dxmtReplay.path(percentEncoded: false).hasSuffix("/Libraries/DXMT/x64/dxmt-replay.exe"))
}

@Test func aBuildWithoutTheReplayerIsRefused() throws {
    let folder = try makeTempDir()
    try makeDXMTBuild(in: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "x86_64-windows/dxmt-replay.exe"))
    #expect(DXMTBuild(folder: folder) == nil)
}
