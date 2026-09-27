import Foundation

public enum GPTKImportError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case missingFiles([String])
    case versionUnreadable
    case copyFailed(Int32)

    public var description: String {
        switch self {
        case .notFound(let path):
            "no GPTK redist found at \(path); pass the mounted GPTK volume, its redist folder, or redist/lib"
        case .missingFiles(let files): "not a complete GPTK redist, missing: \(files.joined(separator: ", "))"
        case .versionUnreadable: "could not read the D3DMetal version from D3DMetal.framework"
        case .copyFailed(let status): "copying GPTK files failed (ditto exit \(status))"
        }
    }
}

public struct GPTKManifest: Codable, Equatable, Sendable {
    public let version: String
    public let importedAt: Date
}

/// Imports Apple's D3DMetal from a user-downloaded Game Porting Toolkit. We never ship Apple's files.
public enum GPTKImporter {
    /// Present in every supported GPTK `redist/lib` (3.0 and 4.0 beta).
    public static let requiredFiles = [
        "external/D3DMetal.framework",
        "external/libd3dshared.dylib",
        "wine/x86_64-windows/d3d10.dll",
        "wine/x86_64-windows/d3d11.dll",
        "wine/x86_64-windows/d3d12.dll",
        "wine/x86_64-windows/dxgi.dll",
    ]
    /// Unix halves of the forwarders; each is a symlink to `external/libd3dshared.dylib`.
    public static let unixBridges = ["d3d10.so", "d3d11.so", "d3d12.so", "dxgi.so"]

    /// Accepts the mounted volume, its `redist` folder, or `redist/lib`.
    public static func locateLib(from source: URL) -> URL? {
        [source, source.appending(path: "lib"), source.appending(path: "redist/lib")].first {
            FileManager.default.fileExists(
                atPath: $0.appending(path: "external/libd3dshared.dylib").path(percentEncoded: false))
        }
    }

    /// Checks every required file and returns the D3DMetal version.
    public static func validate(lib: URL) throws(GPTKImportError) -> String {
        let missing = requiredFiles.filter {
            !FileManager.default.fileExists(atPath: lib.appending(path: $0).path(percentEncoded: false))
        }
        guard missing.isEmpty else { throw .missingFiles(missing) }
        guard let version = frameworkVersion(lib.appending(path: "external/D3DMetal.framework")) else {
            throw .versionUnreadable
        }
        return version
    }

    static func frameworkVersion(_ framework: URL) -> String? {
        for plist in ["Versions/A/Resources/Info.plist", "Resources/Info.plist"] {
            guard let data = try? Data(contentsOf: framework.appending(path: plist)),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = dict["CFBundleShortVersionString"] as? String, !version.isEmpty
            else { continue }
            return version
        }
        return nil
    }

    /// Validates before copying anything, keeps a pristine copy in the store (so runtime
    /// updates can re-apply it), overlays it onto Wine, then records `gptk.json`.
    @discardableResult
    public static func importGPTK(from source: URL, into layout: ToolLayout,
                                  runner: any ProcessRunner = SystemProcessRunner()) throws -> GPTKManifest {
        guard let lib = locateLib(from: source) else {
            throw GPTKImportError.notFound(source.path(percentEncoded: false))
        }
        let version = try validate(lib: lib)
        let fm = FileManager.default
        let staging = layout.root.appending(path: "gptk.staging", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try ditto(lib, staging.appending(path: "lib"), runner: runner)
        try? fm.removeItem(at: layout.gptkStore)
        try fm.moveItem(at: staging, to: layout.gptkStore)
        try applyOverlay(layout: layout, runner: runner)
        let manifest = GPTKManifest(version: version, importedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: layout.gptkManifest, options: .atomic)
        return manifest
    }

    /// Copies the stored GPTK `lib` over `Libraries/Wine/lib` and points the unix bridges at libd3dshared.
    public static func applyOverlay(layout: ToolLayout, runner: any ProcessRunner = SystemProcessRunner()) throws {
        try ditto(layout.gptkStore.appending(path: "lib"), layout.wineLib, runner: runner)
        let fm = FileManager.default
        let unixDir = layout.wineLib.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory)
        try fm.createDirectory(at: unixDir, withIntermediateDirectories: true)
        for name in unixBridges {
            let link = unixDir.appending(path: name)
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(atPath: link.path(percentEncoded: false),
                                      withDestinationPath: "../../external/libd3dshared.dylib")
        }
    }

    /// `ditto` merges into an existing tree and keeps framework symlinks and signatures intact.
    static func ditto(_ from: URL, _ to: URL, runner: any ProcessRunner) throws {
        let status = try runner.run(URL(filePath: "/usr/bin/ditto"),
                                    [from.path(percentEncoded: false), to.path(percentEncoded: false)],
                                    environment: [:], output: nil)
        guard status == 0 else { throw GPTKImportError.copyFailed(status) }
    }
}
