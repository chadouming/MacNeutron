import Dispatch
import Foundation

/// `macneutron` subcommands. Kept out of main.swift so they can be tested.
public enum CommandLineTool {
    public static let usage = """
        usage: macneutron launch <verb> <target> [args...]
        """

    public static func run(_ args: [String], environment: [String: String], executable: URL) async -> Int32 {
        guard let command = args.first else { return usageError() }
        let rest = Array(args.dropFirst())
        switch command {
        case "launch":
            let launcher = Launcher(layout: ToolLayout(executable: executable))
            installTerminationHandlers(launcher, environment: environment)
            return launcher.launch(rest, environment: environment)
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
