import Foundation

/// Where everything lives inside the `macproton` compatibility tool folder.
public struct ToolLayout: Equatable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `<root>/bin/macproton` → `<root>`.
    public init(executable: URL) {
        root = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Application Support/MacProton/compatibilitytools.d/macproton",
            directoryHint: .isDirectory)
    }

    /// The winecx-gptk runtime tarball unpacks to `Libraries/{Wine,DXMT,DXVK}`.
    public var libraries: URL { root.appending(path: "Libraries", directoryHint: .isDirectory) }
    public var wineLib: URL { libraries.appending(path: "Wine/lib", directoryHint: .isDirectory) }
    public var wine: URL { libraries.appending(path: "Wine/bin/wine") }
    public var wineserver: URL { libraries.appending(path: "Wine/bin/wineserver") }
    public var dxmt: URL { libraries.appending(path: "DXMT", directoryHint: .isDirectory) }
    public var dxvk: URL { libraries.appending(path: "DXVK", directoryHint: .isDirectory) }
    /// Pristine copy of the imported GPTK `lib`; outside `Libraries` so a runtime update keeps it.
    public var gptkStore: URL { root.appending(path: "gptk", directoryHint: .isDirectory) }
    public var gptkManifest: URL { root.appending(path: "gptk.json") }
    public var runtimeVersionFile: URL { root.appending(path: "runtime-version") }
    public var launcherBinary: URL { root.appending(path: "bin/macproton") }

    public var runtimeVersion: String? {
        (try? String(contentsOf: runtimeVersionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The imported D3DMetal version from `gptk.json`, or nil when GPTK is not imported.
    public var gptkVersion: String? {
        guard let data = try? Data(contentsOf: gptkManifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }

    public var gptkImported: Bool { gptkVersion != nil }
}
