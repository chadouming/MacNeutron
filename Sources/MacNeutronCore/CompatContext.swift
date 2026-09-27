import Foundation

public enum CompatContextError: Error, Equatable, CustomStringConvertible {
    case missing(String)

    public var description: String {
        switch self {
        case .missing(let name): "\(name) is not set; macneutron launch must be started by Steam"
        }
    }
}

/// The per-game paths Steam hands a compatibility tool through its environment.
public struct CompatContext: Equatable, Sendable {
    public let dataPath: URL
    public let appID: String

    public init(environment env: [String: String]) throws(CompatContextError) {
        guard let data = env["STEAM_COMPAT_DATA_PATH"], !data.isEmpty else {
            throw .missing("STEAM_COMPAT_DATA_PATH")
        }
        dataPath = URL(filePath: data, directoryHint: .isDirectory)
        appID = env["SteamAppId"].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
    }

    public var prefix: URL { dataPath.appending(path: "pfx", directoryHint: .isDirectory) }
    public var versionFile: URL { dataPath.appending(path: "version") }
    public var lockFile: URL { dataPath.appending(path: "macneutron.lock") }
}
