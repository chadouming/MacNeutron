import Foundation
@testable import MacNeutronCore

/// This test process's folder, removed when it exits. A run that didn't exit (crash, Ctrl-C) leaves its
/// folder behind; the next run sweeps it once it's a day old. Only "run …" folders are swept.
private func runDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "macneutron tests/run \(getpid())", directoryHint: .isDirectory)
}

private let sweptAndCleanedAtExit: Void = {
    let fm = FileManager.default
    let parent = runDir().deletingLastPathComponent()
    let dayAgo = Date(timeIntervalSinceNow: -86_400)
    for name in (try? fm.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) ?? [] where name.hasPrefix("run ") {
        let old = parent.appending(path: name, directoryHint: .isDirectory)
        if let modified = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < dayAgo {
            try? fm.removeItem(at: old)
        }
    }
    atexit { try? FileManager.default.removeItem(at: runDir()) }
}()

/// A fresh temp directory whose path contains a space, like Steam's "Application Support".
func makeTempDir() throws -> URL {
    _ = sweptAndCleanedAtExit
    let dir = runDir().appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func write(_ text: String, to url: URL, executable: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if executable {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }
}

/// Records every process the code under test would start, and answers with `respond`.
final class FakeRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable {
        let tool: String
        let arguments: [String]
        let environment: [String: String]
        let output: URL?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call) -> Int32

    init(respond: @escaping @Sendable (Call) -> Int32 = { _ in 0 }) { self.respond = respond }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String], output: URL?) throws -> Int32 {
        let call = Call(tool: executable.lastPathComponent, arguments: arguments, environment: environment, output: output)
        lock.withLock { recorded.append(call) }
        return respond(call)
    }
}

/// A FakeRunner whose `wineboot` creates the prefix like the real one does.
func winebootCreatingPrefix(status: Int32 = 0, delay: TimeInterval = 0) -> FakeRunner {
    FakeRunner { call in
        if call.arguments.first == "wineboot", let prefix = call.environment["WINEPREFIX"] {
            Thread.sleep(forTimeInterval: delay)
            if status == 0 { try? FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true) }
            return status
        }
        return 0
    }
}

/// A tool folder with a fake runtime: executable wine/wineserver, DXMT and DXVK DLLs, runtime-version.
func makeToolLayout() throws -> ToolLayout {
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron", directoryHint: .isDirectory))
    try write("#!/bin/sh\n", to: layout.wine, executable: true)
    try write("#!/bin/sh\n", to: layout.wineserver, executable: true)
    for arch in ["x64", "x32"] {
        for dll in ["d3d11.dll", "d3d10core.dll", "dxgi.dll"] {
            try write("dxmt \(arch) \(dll)", to: layout.dxmt.appending(path: "\(arch)/\(dll)"))
        }
        // The pinned runtime's DXVK ships only these two; it relies on Wine's own dxgi.
        for dll in ["d3d10core.dll", "d3d11.dll"] {
            try write("dxvk \(arch) \(dll)", to: layout.dxvk.appending(path: "\(arch)/\(dll)"))
        }
    }
    try write("runtime-test", to: layout.runtimeVersionFile)
    return layout
}

func steamEnvironment(dataPath: URL, appID: String = "3419430") -> [String: String] {
    ["STEAM_COMPAT_DATA_PATH": dataPath.path(percentEncoded: false), "SteamAppId": appID, "PATH": "/usr/bin:/bin"]
}

/// A Steam root in a temp folder. `loginUsers` becomes config/loginusers.vdf; `steamClient` puts a
/// steamclient.dylib in the bundle's MacOS folder.
func makeSteamLocation(loginUsers: String? = nil, steamClient: Bool = true) throws -> SteamLocation {
    let steam = SteamLocation(root: try makeTempDir().appending(path: "Steam", directoryHint: .isDirectory))
    if let loginUsers { try write(loginUsers, to: steam.loginUsers) }
    if steamClient { try write("dylib", to: steam.bundleMacOS.appending(path: "steamclient.dylib")) }
    return steam
}

/// One user block of loginusers.vdf. SteamID64 76561197960265728 + n belongs to account n.
func loginUser(account: Int, timestamp: Int, mostRecent: Bool? = nil) -> String {
    var block = "\t\"\(76561197960265728 + account)\"\n\t{\n"
        + "\t\t\"AccountName\"\t\t\"user\(account)\"\n\t\t\"Timestamp\"\t\t\"\(timestamp)\"\n"
    if let mostRecent { block += "\t\t\"MostRecent\"\t\t\"\(mostRecent ? 1 : 0)\"\n" }
    return block + "\t}\n"
}

func loginUsersFile(_ users: String...) -> String { "\"users\"\n{\n" + users.joined() + "}\n" }

/// The files `ToolLayout.steamBridgeInstalled` looks for; `i386: false` leaves out the 32-bit client.
func installFakeSteamBridge(in layout: ToolLayout, i386: Bool = true) throws {
    try write("steam.exe", to: layout.steamHelper)
    try write("lsteamclient.so", to: layout.lsteamclientUnix)
    try write("lsteamclient x86_64", to: layout.lsteamclient64)
    if i386 { try write("lsteamclient i386", to: layout.lsteamclient32) }
}

/// A stand-in for the MetalFX presenter library in the tool folder.
func installFakePresenter(in layout: ToolLayout) throws {
    try write("presenter", to: layout.presenterLibrary)
}

/// A fake `make dxmt` output. Both halves go in `folder`, or the Mac half goes in `unixFolder`, as in MacNeutron.app.
@discardableResult
func makeDXMTBuild(in folder: URL, unixFolder: URL? = nil, version: String = "abc123") throws -> DXMTBuild {
    try write(version + "\n", to: folder.appending(path: "version"))
    for (arch, dlls) in [("x86_64-windows", ["winemetal.dll", "d3d11.dll", "d3d10core.dll", "dxgi.dll", "d3d12.dll", "dxmt-replay.exe"]),
                         ("i386-windows", ["winemetal.dll", "d3d11.dll", "d3d10core.dll", "dxgi.dll"])] {
        for dll in dlls {
            try write("ours \(arch) \(dll)", to: folder.appending(path: "\(arch)/\(dll)"))
        }
    }
    let unix = unixFolder ?? folder
    try write("ours winemetal.so", to: unix.appending(path: "x86_64-unix/winemetal.so"))
    guard let build = DXMTBuild(windows: folder, unix: unix) else { throw CocoaError(.fileNoSuchFile) }
    return build
}

/// An ad-hoc-signed `dir/wine.app` whose `Contents/MacOS/wine` is a copy of `loader` (never run). Sign it last:
/// anything written into the bundle afterwards breaks `codesign --verify`.
@discardableResult
func makeSignedWineApp(at dir: URL, loader: URL = URL(filePath: "/usr/bin/true"), shortVersion: String = "test",
                       bundleVersion: String = "1") throws -> URL {
    let bundle = dir.appending(path: "wine.app", directoryHint: .isDirectory)
    let macOS = bundle.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: String] = ["CFBundleExecutable": "wine", "CFBundleIdentifier": "test.wine",
                                   "CFBundleShortVersionString": shortVersion, "CFBundleVersion": bundleVersion]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: bundle.appending(path: "Contents/Info.plist"))
    try FileManager.default.copyItem(at: loader, to: macOS.appending(path: "wine"))
    let status = try SystemProcessRunner().run(URL(filePath: "/usr/bin/codesign"),
                                               ["-s", "-", "-f", bundle.path(percentEncoded: false)],
                                               environment: [:], output: URL(filePath: "/dev/null"))  // "replacing existing signature"
    guard status == 0 else { throw CocoaError(.executableLoad) }
    return bundle
}
