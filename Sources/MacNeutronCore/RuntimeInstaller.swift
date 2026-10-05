import Foundation

public enum RuntimeInstallOutcome: Equatable, Sendable {
    case installed
    case unchanged
    /// A process runs from the installed runtime (its kernel path); nothing was changed.
    case deferred(String)
}

public enum RuntimeInstallError: Error, Equatable, CustomStringConvertible {
    /// The source has no `Contents/MacOS/wine`.
    case notAWineApp(String)
    /// `codesign --verify --strict`'s exit status for the copy.
    case signatureInvalid(Int32)
    /// `renamex_np`'s or `rename`'s errno.
    case swapFailed(Int32)

    /// Shown by setup and printed by `macneutron install`.
    public var description: String {
        switch self {
        case .notAWineApp(let path): "\(path) isn't a runtime (it has no Contents/MacOS/wine)."
        case .signatureInvalid(let status): "The runtime's signature check failed (codesign exit \(status))."
        case .swapFailed(let error): "Couldn't put the new runtime in place: \(String(cString: strerror(error)))."
        }
    }
}

/// Installs `wine.app` and the Steam-facing tool files into a `macneutron` tool folder (spec §3.9).
public enum RuntimeInstaller {
    static let compatibilityTool = """
        "compatibilitytools"
        {
          "compat_tools"
          {
            "macneutron"
            {
              "install_path" "."
              "display_name" "MacNeutron"
              "from_oslist"  "windows"
              "to_oslist"    "linux"
            }
          }
        }

        """
    /// Steam runs the thin arm64 CLI directly (R0b passed); there's no `/bin/sh` stub in between.
    static let toolManifest = """
        "manifest"
        {
          "version" "2"
          "commandline" "/bin/macneutron launch %verb%"
        }

        """

    /// Installs `wineApp` into `layout`, unless a process runs from the installed runtime (a new client can't talk to
    /// an older running wineserver). The copy is checked before it replaces the old one in a single swap, so there is
    /// never a moment without a working `wine.app`. Tool files are written on every install that isn't deferred, so
    /// the CLI and the runtime change together.
    @discardableResult
    public static func install(wineApp source: URL, layout: ToolLayout, launcherBinary: URL, steamExe: URL? = nil,
                               force: Bool = false, runner: any ProcessRunner = SystemProcessRunner(),
                               runningExecutables: () -> [String] = RunningProcesses.executablePaths,
                               identity: (URL) -> String? = CodeIdentity.of,
                               log: LauncherLog = .standard) throws -> RuntimeInstallOutcome {
        let fm = FileManager.default
        let sourcePath = source.path(percentEncoded: false)
        guard fm.isExecutableFile(atPath: source.appending(path: "Contents/MacOS/wine").path(percentEncoded: false)) else {
            throw RuntimeInstallError.notAWineApp(sourcePath)
        }
        // 1. The kernel reports real paths (/private/var/…), so compare against the folders' real paths.
        let watched = [layout.wineApp, layout.root.appending(path: "Libraries")].compactMap(realPath).map { $0 + "/" }
        if let running = runningExecutables().first(where: { path in watched.contains { path.hasPrefix($0) } }) {
            log.append("install deferred: \(running) is running")
            return .deferred(running)
        }
        // 2. Leftovers of an interrupted install (`cp -R` into an existing folder would nest the source in it).
        // These paths have no trailing "/", for cp and rename(2).
        let new = layout.root.appending(path: "wine.app.new")
        try? fm.removeItem(at: new)
        try? fm.removeItem(at: layout.root.appending(path: "wine.app.old"))
        // 3.
        let damaged = fm.fileExists(atPath: layout.runtimeDamagedMarker.path(percentEncoded: false))
        let installed = identity(layout.wineApp)
        let outcome: RuntimeInstallOutcome
        if !force, !damaged, let installed, installed == identity(source) {
            outcome = .unchanged
        } else {
            // 4. An APFS clone on the same volume, a full copy otherwise.
            try fm.createDirectory(at: layout.root, withIntermediateDirectories: true)
            let newPath = new.path(percentEncoded: false)
            let copied = try runner.run(URL(filePath: "/bin/cp"), ["-c", "-R", sourcePath, newPath],
                                        environment: [:], output: nil)
            guard copied == 0 else {
                try? fm.removeItem(at: new)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: newPath])
            }
            let verified = try runner.run(URL(filePath: "/usr/bin/codesign"), ["--verify", "--strict", newPath],
                                          environment: [:], output: nil)
            guard verified == 0 else {
                try? fm.removeItem(at: new)
                throw RuntimeInstallError.signatureInvalid(verified)
            }
            let target = layout.root.appending(path: "wine.app").path(percentEncoded: false)
            let swapped = fm.fileExists(atPath: target)
                ? renamex_np(newPath, target, UInt32(RENAME_SWAP)) : rename(newPath, target)
            guard swapped == 0 else {
                let error = errno
                try? fm.removeItem(at: new)
                throw RuntimeInstallError.swapFailed(error)
            }
            try? fm.removeItem(at: new)  // the old copy, after a swap
            try? fm.removeItem(at: layout.runtimeDamagedMarker)
            outcome = .installed
        }
        // 5.
        try writeToolFiles(layout: layout, launcherBinary: launcherBinary, steamExe: steamExe)
        // 6. The Rosetta-era runtime's entries, and its /bin/sh stub.
        for name in ToolLayout.rosettaEraEntries + ["proton"] { try? fm.removeItem(at: layout.root.appending(path: name)) }
        return outcome
    }

    /// `realpath(3)`, or nil when `url` doesn't exist. (`URL.resolvingSymlinksInPath` strips `/private`.)
    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Writes Steam's tool files, then installs the launcher and `steamExe`, or the `steam.exe` it finds beside the
    /// launcher. Safe to repeat: identical files are skipped, and new ones are
    /// renamed into place, so a game Steam launches meanwhile never finds the launcher missing.
    public static func writeToolFiles(layout: ToolLayout, launcherBinary: URL, steamExe: URL? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try installFile(launcherBinary, at: layout.launcherBinary)  // before the manifest that runs it
        try compatibilityTool.write(to: layout.root.appending(path: "compatibilitytool.vdf"), atomically: true, encoding: .utf8)
        try toolManifest.write(to: layout.root.appending(path: "toolmanifest.vdf"), atomically: true, encoding: .utf8)
        // Next to the launcher, or in MacNeutron.app's Contents/Resources: steam.exe isn't Mach-O code,
        // so codesign won't accept it in Contents/Helpers.
        let helpers = launcherBinary.deletingLastPathComponent()
        let candidates = [helpers.appending(path: "steam.exe"),
                          helpers.deletingLastPathComponent().appending(path: "Resources/steam.exe")]
        if let steamExe = steamExe ?? candidates.first(where: { fm.fileExists(atPath: $0.path(percentEncoded: false)) }) {
            try installFile(steamExe, at: layout.steamHelper)
        }
    }

    /// Copies `source` to `destination` through a temporary file and `rename(2)`, unless they already match.
    static func installFile(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else { return }
        let contents = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) == contents { return }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.appendingPathExtension("new")
        try? fm.removeItem(at: temporary)
        try fm.copyItem(at: source, to: temporary)
        guard rename(temporary.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
