import Foundation

/// Where the Steam bridge lives inside a prefix, and the small decisions the launcher makes about it.
/// The bridge itself (Proton's lsteamclient) ships with the runtime; `steam.exe` ships with MacNeutron.
public enum SteamBridge {
    /// `steam.exe` inside every prefix.
    public static let steamExe = #"C:\Program Files (x86)\Steam\steam.exe"#

    /// `Z:` is Wine's mapping of `/`; Windows paths pass through.
    public static func windowsPath(_ path: String) -> String {
        path.hasPrefix("/") ? "Z:" + path.replacingOccurrences(of: "/", with: #"\"#) : path
    }

    /// The folder `steam.exe` names in the registry, relative to the prefix.
    static let prefixFolder = "drive_c/Program Files (x86)/Steam"

    /// What the launcher copies into a prefix: (source, destination relative to the prefix).
    static func prefixFiles(layout: ToolLayout) -> [(URL, String)] {
        var files = [(layout.steamHelper, "\(prefixFolder)/steam.exe"),
                     (layout.lsteamclient64, "\(prefixFolder)/steamclient64.dll")]
        if FileManager.default.fileExists(atPath: layout.lsteamclient32.path(percentEncoded: false)) {
            files.append((layout.lsteamclient32, "\(prefixFolder)/steamclient.dll"))
        }
        return files
    }

    /// Steam's `STEAM_COMPAT_CLIENT_INSTALL_PATH` when that folder holds `steamclient.dylib`,
    /// otherwise the Steam bundle's MacOS folder, where macOS Steam keeps it.
    public static func clientDirectory(steamValue: String?, steam: SteamLocation) -> String {
        if let steamValue, FileManager.default.fileExists(atPath: steamValue + "/steamclient.dylib") { return steamValue }
        var bundle = steam.bundleMacOS.path(percentEncoded: false)
        if bundle.hasSuffix("/") { bundle.removeLast() }
        return bundle
    }
}
