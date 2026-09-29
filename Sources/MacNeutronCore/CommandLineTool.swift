import Dispatch
import Foundation

/// `macneutron` subcommands. Kept out of main.swift so they can be tested.
public enum CommandLineTool {
    public static let usage = """
        usage: macneutron launch <verb> <target> [args...]
               macneutron import-gptk [--tool-dir <dir>] <GPTK volume | redist | redist/lib>
               macneutron install-runtime [--tool-dir <dir>] [--tarball <Libraries.tar.gz>]
               macneutron install-dxmt [--tool-dir <dir>] <build/dxmt>
        """

    public static func run(_ args: [String], environment: [String: String], executable: URL) async -> Int32 {
        guard let command = args.first else { return usageError() }
        var rest = Array(args.dropFirst())
        switch command {
        case "launch":
            let launcher = Launcher(layout: ToolLayout(executable: executable))
            installTerminationHandlers(launcher, environment: environment)
            return launcher.launch(rest, environment: environment)
        case "import-gptk":
            let layout = toolLayout(option("--tool-dir", in: &rest))
            guard rest.count == 1 else { return usageError() }
            do {
                let manifest = try GPTKImporter.importGPTK(from: URL(filePath: rest[0]), into: layout)
                print("Imported D3DMetal \(manifest.version) into \(layout.root.path(percentEncoded: false))")
                return 0
            } catch {
                return failure(error)
            }
        case "install-runtime":
            let layout = toolLayout(option("--tool-dir", in: &rest))
            let tarballPath = option("--tarball", in: &rest)
            guard rest.isEmpty else { return usageError() }
            do {
                if tarballPath == nil { print("Downloading \(RuntimePin.current.url.absoluteString) (first time only)") }
                let tarball = if let tarballPath { URL(filePath: tarballPath) } else { try await RuntimeInstaller.cachedDownload(.current) }
                try RuntimeInstaller.install(tarball: tarball, pin: .current, layout: layout, launcherBinary: executable)
                print("Installed \(RuntimePin.current.version) into \(layout.root.path(percentEncoded: false))")
                return 0
            } catch {
                return failure(error)
            }
        case "install-dxmt":
            let layout = toolLayout(option("--tool-dir", in: &rest))
            guard rest.count == 1 else { return usageError() }
            do {
                guard let build = DXMTBuild(folder: URL(filePath: rest[0], directoryHint: .isDirectory)) else {
                    throw DXMTInstallError.notABuild(rest[0])
                }
                try DXMTInstaller.install(layout: layout, from: build)
                print("Installed DXMT \(build.version) into \(layout.root.path(percentEncoded: false))")
                return 0
            } catch {
                return failure(error)
            }
        default:
            return usageError()
        }
    }

    /// Removes `--name value` from `args` and returns the value.
    static func option(_ name: String, in args: inout [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        args.removeSubrange(index...index + 1)
        return value
    }

    static func toolLayout(_ dir: String?) -> ToolLayout {
        ToolLayout(root: dir.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? ToolLayout.defaultRoot)
    }

    // ponytail: global signal sources for the process's single launch; never mutated after setup.
    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal] = []

    /// Steam's Stop button (SIGTERM) and Ctrl-C kill the game's Wine processes, then exit.
    static func installTerminationHandlers(_ launcher: Launcher, environment: [String: String]) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                launcher.terminate(environment: environment)
                exit(128 + sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func usageError() -> Int32 {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 2
    }

    private static func failure(_ error: any Error) -> Int32 {
        FileHandle.standardError.write(Data("macneutron: \(error)\n".utf8))
        return 1
    }
}
