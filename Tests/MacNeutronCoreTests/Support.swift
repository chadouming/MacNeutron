import Foundation
@testable import MacNeutronCore

/// A fresh temp directory whose path contains a space, like Steam's "Application Support".
func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "macneutron tests/\(UUID().uuidString)", directoryHint: .isDirectory)
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
