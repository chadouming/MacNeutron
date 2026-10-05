import Foundation

/// Installs the Steam-facing tool files into a `macneutron` tool folder.
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

    /// Writes Steam's tool files, then installs the launcher and, when it can find one, `steam.exe`.
    /// Safe to repeat: identical files are skipped, and new ones are
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
        // The presenter is Mach-O code, so in MacNeutron.app it lives in Contents/Frameworks.
        let presenters = [helpers.appending(path: "libmacneutron-present.dylib"),
                          helpers.deletingLastPathComponent().appending(path: "Frameworks/libmacneutron-present.dylib")]
        if let presenter = presenters.first(where: { fm.fileExists(atPath: $0.path(percentEncoded: false)) }) {
            try installFile(presenter, at: layout.presenterLibrary)
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
