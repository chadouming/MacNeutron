import Foundation

/// Shader pre-caching as Steam does it for Vulkan games (docs/superpowers/specs/2026-09-30-macneutron-pipeline-cache-design.md
/// §3.7): our d3d12.dll records each game's pipelines in `<compatdata>/dxmt-pipelines`, and after a DXMT or macOS
/// update the launcher rebuilds them with `dxmt-replay.exe` before the game starts.
public struct ShaderPrecache: Sendable {
    public let folder: URL
    /// The builds the recordings are compiled for: `<dxmt-version> <macOS build>`.
    public let builds: String

    public init(context: CompatContext, layout: ToolLayout, osBuild: String = ShaderPrecache.macOSBuild()) {
        folder = Self.folder(for: context)
        builds = "\(layout.dxmtVersion ?? "none") \(osBuild)"
    }

    public static func folder(for context: CompatContext) -> URL { context.dataPath.appending(path: "dxmt-pipelines") }

    /// Recording and replay need our DXMT's Direct3D 12; `MACNEUTRON_PRECACHE=0` turns both off.
    public static func enabled(backend: GraphicsBackend, layout: ToolLayout, environment: [String: String]) -> Bool {
        backend == .dxmt && layout.dxmtHasD3D12 && environment["MACNEUTRON_PRECACHE"] != "0"
    }

    public var stampFile: URL { folder.appending(path: "replayed") }

    var stamp: String? {
        (try? String(contentsOf: stampFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var recordings: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pipelines" }
            .map { folder.appending(path: $0.lastPathComponent) } // the folder as given, not symlinks resolved
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Recordings compiled for other builds. No stamp means the recordings came from sessions of these builds.
    public var needsReplay: Bool {
        guard let stamp, stamp != builds else { return false }
        return !recordings.isEmpty
    }

    public func writeStamp() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? (builds + "\n").write(to: stampFile, atomically: true, encoding: .utf8)
    }

    public func writeStampIfMissing() {
        if stamp == nil { writeStamp() }
    }

    /// Runs `dxmt-replay.exe` on every recording in the game's environment, minus recording; one log line each.
    /// Stops before the next recording once `stopped` (Steam's Stop) says so.
    public func replay(layout: ToolLayout, runner: any ProcessRunner, environment: [String: String],
                       stopped: () -> Bool = { false }) -> [String] {
        var env = environment
        env.removeValue(forKey: "DXMT_PIPELINE_RECORD")
        let output = folder.appending(path: "replay.log")
        var lines: [String] = []
        for recording in recordings {
            if stopped() { break }
            try? FileManager.default.removeItem(at: output)
            let status = (try? runner.run(layout.wine, [layout.dxmtReplay.path(percentEncoded: false),
                                                        "Z:" + recording.path(percentEncoded: false)],
                                          environment: env, output: output)) ?? -1
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            let result = text.split(whereSeparator: \.isNewline).last { $0.hasPrefix("replay: ") }
            lines.append("precache: \(recording.lastPathComponent) exit=\(status) \(result.map(String.init) ?? "no result")")
        }
        return lines
    }

    /// `kern.osversion`, the macOS build (e.g. 25A354): Metal's compiler changes with it.
    public static func macOSBuild() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
