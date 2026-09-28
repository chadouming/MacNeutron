import CryptoKit
import Foundation

/// The Wine runtime release MacNeutron is tested against.
public struct RuntimePin: Equatable, Sendable {
    public let version: String
    public let url: URL
    public let sha256: String

    /// winecx-gptk: CrossOver 26.3 changes on Wine 11.17, with DXMT 0.80 and DXVK-macOS 1.10.3.
    /// ponytail: upstream release; point `url` at the chadouming/winecx-gptk fork before the first public release.
    public static let current = RuntimePin(
        version: "runtime-v4.7.3",
        url: URL(string: "https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.7.3/Libraries.tar.gz")!,
        sha256: "a4b5d63493f80698cce5cad8e7212d9a51c8292037b00c478f4652636fcfd331")
}

public enum RuntimeInstallError: Error, Equatable, CustomStringConvertible {
    case checksumMismatch(expected: String, actual: String)
    case extractFailed(Int32)
    case badArchive(String)

    public var description: String {
        switch self {
        case .checksumMismatch(let expected, let actual): "runtime checksum mismatch: expected \(expected), got \(actual)"
        case .extractFailed(let status): "extracting the runtime failed (tar exit \(status))"
        case .badArchive(let detail): "the runtime archive is not a Wine runtime: \(detail)"
        }
    }
}

/// Installs the Wine runtime and the Steam-facing tool files into a `macneutron` tool folder.
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
    static let toolManifest = """
        "manifest"
        {
          "version" "2"
          "commandline" "/proton %verb%"
        }

        """
    static let protonStub = """
        #!/bin/sh
        exec "$(dirname "$0")/bin/macneutron" launch "$@"

        """

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the tarball, extracts it to a staging folder, and only then replaces the old runtime.
    /// Re-applies an imported GPTK, since the new Wine tree does not contain it.
    public static func install(tarball: URL, pin: RuntimePin, layout: ToolLayout, launcherBinary: URL,
                               runner: any ProcessRunner = SystemProcessRunner()) throws {
        let actual = try sha256(of: tarball)
        guard actual == pin.sha256 else {
            throw RuntimeInstallError.checksumMismatch(expected: pin.sha256, actual: actual)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let staging = layout.root.appending(path: "runtime.staging", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let status = try runner.run(URL(filePath: "/usr/bin/tar"),
                                    ["-xzf", tarball.path(percentEncoded: false), "-C", staging.path(percentEncoded: false)],
                                    environment: [:], output: nil)
        guard status == 0 else { throw RuntimeInstallError.extractFailed(status) }
        let extracted = ToolLayout(root: staging)
        for required in [extracted.wine, extracted.wineserver]
        where !fm.isExecutableFile(atPath: required.path(percentEncoded: false)) {
            throw RuntimeInstallError.badArchive("missing Libraries/Wine/bin/\(required.lastPathComponent)")
        }
        try? fm.removeItem(at: layout.libraries)
        try fm.moveItem(at: extracted.libraries, to: layout.libraries)
        try writeToolFiles(layout: layout, launcherBinary: launcherBinary)
        try pin.version.write(to: layout.runtimeVersionFile, atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: layout.gptkStore.path(percentEncoded: false)) {
            try GPTKImporter.applyOverlay(layout: layout, runner: runner)
        }
    }

    /// Writes Steam's tool files, then installs the launcher and, when it can find one, `steam.exe`.
    /// Safe to repeat (the app calls it at every start): identical files are skipped, and new ones are
    /// renamed into place, so a game Steam launches meanwhile never finds the launcher missing.
    public static func writeToolFiles(layout: ToolLayout, launcherBinary: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try compatibilityTool.write(to: layout.root.appending(path: "compatibilitytool.vdf"), atomically: true, encoding: .utf8)
        try toolManifest.write(to: layout.root.appending(path: "toolmanifest.vdf"), atomically: true, encoding: .utf8)
        let stub = layout.root.appending(path: "proton")
        try protonStub.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path(percentEncoded: false))
        try installFile(launcherBinary, at: layout.launcherBinary)
        // Next to the launcher, or in MacNeutron.app's Contents/Resources: steam.exe isn't Mach-O code,
        // so codesign won't accept it in Contents/Helpers.
        let helpers = launcherBinary.deletingLastPathComponent()
        let candidates = [helpers.appending(path: "steam.exe"),
                          helpers.deletingLastPathComponent().appending(path: "Resources/steam.exe")]
        if let steamExe = candidates.first(where: { fm.fileExists(atPath: $0.path(percentEncoded: false)) }) {
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

    /// The pinned tarball in `~/Library/Caches/MacNeutron`, downloading it on first use.
    public static func cachedDownload(_ pin: RuntimePin) async throws -> URL {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/MacNeutron", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let tarball = cache.appending(path: "\(pin.version).tar.gz")
        if !FileManager.default.fileExists(atPath: tarball.path(percentEncoded: false)) {
            try await download(pin, to: tarball)
        }
        return tarball
    }

    /// Downloads to a temporary file first, so an interrupted download never lands at `destination`.
    public static func download(_ pin: RuntimePin, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: pin.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
