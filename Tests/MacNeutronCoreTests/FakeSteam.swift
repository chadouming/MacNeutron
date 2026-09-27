import Foundation
@testable import MacNeutronCore

let okSession = """
    [2026-09-27 12:00:00] Client version: 1788652215
    [2026-09-27 12:00:00] Registering tool macneutron, AppID 0
    [2026-09-27 12:00:00] Registering tool macneutron-native, AppID 0
    [2026-09-27 12:00:01] Recording non-user mapping for 3064690 at priority 100 to tool proton-10

    """
let macModeSession = """
    [2026-09-27 12:00:00] Client version: 1788652215
    [2026-09-27 12:00:00] Registering tool macneutron, AppID 0
    [2026-09-27 12:00:00] Ignoring tool macneutron as it's for a different target platform linux.

    """

/// A Steam install in a temp folder: app bundle, config.vdf, and MacNeutron's runtime tool.
func makeFakeSteam(config: String = steamConfigFixture) throws -> (SteamLocation, URL) {
    let base = try makeTempDir()
    let steam = SteamLocation(root: base.appending(path: "Steam", directoryHint: .isDirectory))
    try FileManager.default.createDirectory(at: steam.bundleMacOS, withIntermediateDirectories: true)
    try write(config, to: steam.configVDF)
    let root = base.appending(path: "MacNeutron", directoryHint: .isDirectory)
    try write("\"manifest\" {}", to: root.appending(path: "compatibilitytools.d/macneutron/toolmanifest.vdf"))
    return (steam, root)
}

/// Stands in for the Steam client: launching appends `session` to compat_log.txt.
final class FakeSteam: SteamControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private var devConfigAtLaunch: [Bool] = []
    private var intentAtLaunch: [Bool] = []
    let steam: SteamLocation
    let session: String
    let intentFile: URL?
    let replaceLogOnLaunch: Bool

    init(steam: SteamLocation, running: Bool = false, session: String = okSession, intentFile: URL? = nil,
         replaceLogOnLaunch: Bool = false) {
        self.replaceLogOnLaunch = replaceLogOnLaunch
        self.steam = steam
        self.running = running
        self.session = session
        self.intentFile = intentFile
    }

    var launchesWithDevConfig: [Bool] { lock.withLock { devConfigAtLaunch } }
    var launchesWithIntent: [Bool] { lock.withLock { intentAtLaunch } }

    func isRunning() -> Bool { lock.withLock { running } }

    func quit(timeout: Duration) async throws { lock.withLock { running = false } }

    func launch() throws {
        let hasDevConfig = FileManager.default.fileExists(atPath: steam.steamDevConfig.path(percentEncoded: false))
        let hasIntent = intentFile.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        lock.withLock {
            running = true
            devConfigAtLaunch.append(hasDevConfig)
            intentAtLaunch.append(hasIntent)
        }
        let old = replaceLogOnLaunch ? "" : (try? String(contentsOf: steam.compatLog, encoding: .utf8)) ?? ""
        try write(old + session, to: steam.compatLog)
    }
}

