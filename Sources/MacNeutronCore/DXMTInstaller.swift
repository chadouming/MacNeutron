import Foundation

public enum DXMTInstallError: Error, Equatable, CustomStringConvertible {
    case notABuild(String)
    case noRuntime(String)

    public var description: String {
        switch self {
        case .notABuild(let path): "\(path) is not a DXMT build (`make dxmt` creates build/dxmt)"
        case .noRuntime(let path): "no Wine runtime in \(path); install the runtime first"
        }
    }
}

/// MacNeutron's DXMT build (DXMT fork spec §5): a Windows half (`x86_64-windows`, `i386-windows`, `version`) and a
/// Mac half (`x86_64-unix`). `make dxmt` puts both in `build/dxmt`. MacNeutron.app keeps the Windows half in
/// Contents/Resources/DXMT and the Mac half, which is signed code, in Contents/Frameworks/DXMT.
public struct DXMTBuild: Equatable, Sendable {
    public let windows: URL
    public let unix: URL

    public init?(windows: URL, unix: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: windows.appending(path: "version").path(percentEncoded: false)),
              fm.fileExists(atPath: unix.appending(path: "x86_64-unix/winemetal.so").path(percentEncoded: false))
        else { return nil }
        self.windows = windows
        self.unix = unix
    }

    /// Both halves in one folder, like `build/dxmt`.
    public init?(folder: URL) { self.init(windows: folder, unix: folder) }

    /// `DXMT/` next to the launcher, or MacNeutron.app's Resources/DXMT and Frameworks/DXMT.
    public static func bundled(near launcherBinary: URL) -> DXMTBuild? {
        let helpers = launcherBinary.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        return DXMTBuild(folder: helpers.appending(path: "DXMT", directoryHint: .isDirectory))
            ?? DXMTBuild(windows: contents.appending(path: "Resources/DXMT", directoryHint: .isDirectory),
                         unix: contents.appending(path: "Frameworks/DXMT", directoryHint: .isDirectory))
    }

    /// The fork commit it was built from.
    public var version: String {
        ((try? String(contentsOf: windows.appending(path: "version"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Installs MacNeutron's DXMT over the runtime's DXMT 0.80.
public enum DXMTInstaller {
    /// Front ends that go into `Libraries/DXMT/<dir>`, where prefixes get them. Direct3D 12 is 64-bit only.
    static let frontEnds: [(arch: String, dir: String, dlls: [String])] = [
        ("x86_64-windows", "x64", ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "d3d12.dll"]),
        ("i386-windows", "x32", ["d3d11.dll", "d3d10core.dll", "dxgi.dll"]),
    ]

    /// Installs, in order:
    /// - the Mac half into Wine's `x86_64-unix`;
    /// - `winemetal.dll` into Wine's PE folders;
    /// - the front ends into `Libraries/DXMT`;
    /// - `dxmt-version`.
    /// `dxmt-version` is removed first and written last, so an install that fails part-way is retried at the next app
    /// start instead of leaving mismatched halves that look current.
    public static func install(layout: ToolLayout, from build: DXMTBuild) throws {
        guard layout.runtimeVersion != nil else { throw DXMTInstallError.noRuntime(layout.root.path(percentEncoded: false)) }
        let fm = FileManager.default
        try? fm.removeItem(at: layout.dxmtVersionFile)
        let wine = layout.wineLib.appending(path: "wine", directoryHint: .isDirectory)
        let unix = build.unix.appending(path: "x86_64-unix", directoryHint: .isDirectory)
        for file in try fm.contentsOfDirectory(at: unix, includingPropertiesForKeys: nil) {
            try RuntimeInstaller.installFile(file, at: wine.appending(path: "x86_64-unix/\(file.lastPathComponent)"))
        }
        for (arch, dir, dlls) in frontEnds {
            let from = build.windows.appending(path: arch, directoryHint: .isDirectory)
            try RuntimeInstaller.installFile(from.appending(path: "winemetal.dll"),
                                             at: wine.appending(path: "\(arch)/winemetal.dll"))
            for dll in dlls {
                try RuntimeInstaller.installFile(from.appending(path: dll), at: layout.dxmt.appending(path: "\(dir)/\(dll)"))
            }
        }
        try build.version.write(to: layout.dxmtVersionFile, atomically: true, encoding: .utf8)
    }

    /// Installs the DXMT that ships with this launcher when the tool folder has a different one, or the runtime's own.
    @discardableResult
    public static func installBundled(layout: ToolLayout, launcherBinary: URL) throws -> Bool {
        guard let build = DXMTBuild.bundled(near: launcherBinary), build.version != layout.dxmtVersion else { return false }
        try install(layout: layout, from: build)
        return true
    }
}
