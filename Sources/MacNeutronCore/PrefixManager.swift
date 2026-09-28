import Darwin
import Foundation

public enum PrefixError: Error, Equatable, CustomStringConvertible {
    case lockFailed(String)
    case winebootFailed(Int32)
    case dllCopyFailed(String)
    case steamBridgeCopyFailed(String)

    public var description: String {
        switch self {
        case .lockFailed(let reason): "could not lock the prefix: \(reason)"
        case .winebootFailed(let status): "prefix setup failed (wineboot exit \(status)); the prefix was left unchanged"
        case .dllCopyFailed(let detail): "could not install graphics DLLs: \(detail)"
        case .steamBridgeCopyFailed(let detail): "could not install the Steam bridge: \(detail)"
        }
    }
}

/// Creates, upgrades and equips a game's Wine prefix at `compatdata/<appid>/pfx`.
public struct PrefixManager: Sendable {
    public let context: CompatContext
    public let layout: ToolLayout
    public let runtimeVersion: String
    public let runner: any ProcessRunner

    public init(context: CompatContext, layout: ToolLayout, runtimeVersion: String, runner: any ProcessRunner) {
        self.context = context
        self.layout = layout
        self.runtimeVersion = runtimeVersion
        self.runner = runner
    }

    /// True when the prefix is missing or was last prepared by a different runtime.
    public var needsPreparation: Bool {
        guard FileManager.default.fileExists(atPath: context.prefix.path(percentEncoded: false)) else { return true }
        let recorded = try? String(contentsOf: context.versionFile, encoding: .utf8)
        return recorded?.trimmingCharacters(in: .whitespacesAndNewlines) != runtimeVersion
    }

    /// Runs `wineboot -u` when needed, then installs the backend's DLLs and, when asked, the Steam bridge.
    /// Holds the prefix lock only for this preparation, never while the game runs. On failure the version
    /// is not recorded, so the next launch retries; nothing under `drive_c` is ever deleted.
    public func prepare(backend: GraphicsBackend, environment: [String: String], steamBridge: Bool = false) throws {
        try FileManager.default.createDirectory(at: context.dataPath, withIntermediateDirectories: true)
        try withFileLock(at: context.lockFile) {
            if needsPreparation {
                let status = try runner.run(layout.wine, ["wineboot", "-u"], environment: environment, output: nil)
                guard status == 0 else { throw PrefixError.winebootFailed(status) }
                // A crashing game must exit, not wait behind Wine's crash window while Steam shows it running.
                // ponytail: best effort; if reg fails, crashes still work, they just show the dialog.
                _ = try runner.run(layout.wine, ["reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog",
                                                 "/t", "REG_DWORD", "/d", "0", "/f"], environment: environment, output: nil)
                try runtimeVersion.write(to: context.versionFile, atomically: true, encoding: .utf8)
            }
            try deployDLLs(for: backend)
            if steamBridge { try deploySteamBridge() }
        }
    }

    func deployDLLs(for backend: GraphicsBackend) throws {
        for (source, destination) in backend.prefixDLLs(layout: layout) {
            // A missing file must fail loudly: skipping one once left DXMT's dxgi paired with DXVK.
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                throw PrefixError.dllCopyFailed("\(destination): missing from the runtime (\(source.path(percentEncoded: false)))")
            }
            do { try install(source, at: destination) } catch {
                throw PrefixError.dllCopyFailed("\(destination): \(error.localizedDescription)")
            }
        }
    }

    /// Every launch, like the DLLs: prefixes made before the bridge existed get it too.
    func deploySteamBridge() throws {
        for (source, destination) in SteamBridge.prefixFiles(layout: layout) {
            do { try install(source, at: destination) } catch {
                throw PrefixError.steamBridgeCopyFailed("\(destination): \(error.localizedDescription)")
            }
        }
    }

    /// For `MACNEUTRON_NO_STEAM_BRIDGE`: a game's steam_api loads the client DLL an earlier launch left
    /// (its registry values persist), and without Steam's client path the bridge aborts the game.
    /// Without these files the game just finds no Steam.
    public func removeSteamBridge() throws {
        try withFileLock(at: context.lockFile) {
            for name in ["steam.exe", "steamclient64.dll", "steamclient.dll"] {
                try? FileManager.default.removeItem(at: context.prefix.appending(path: "\(SteamBridge.prefixFolder)/\(name)"))
            }
        }
    }

    private func install(_ source: URL, at destination: String) throws {
        let fm = FileManager.default
        let target = context.prefix.appending(path: destination)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path(percentEncoded: false)) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)
    }
}

/// Exclusive `flock(2)` on `url` for the duration of `body`. Separate `open`s conflict even
/// within one process, so this also serialises threads.
func withFileLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
    let fd = open(url.path(percentEncoded: false), O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw PrefixError.lockFailed(String(cString: strerror(errno))) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw PrefixError.lockFailed(String(cString: strerror(errno))) }
    defer { flock(fd, LOCK_UN) }
    return try body()
}
