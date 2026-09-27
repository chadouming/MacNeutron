import Foundation

/// `~/Library/Logs/MacNeutron`: one line per launch in `launcher.log`, plus opt-in per-game Wine logs.
public struct LauncherLog: Sendable {
    public static let rotateBytes = 1_048_576
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var standard: LauncherLog {
        LauncherLog(directory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/MacNeutron", directoryHint: .isDirectory))
    }

    public var launcherLog: URL { directory.appending(path: "launcher.log") }

    /// Creates the log folder and returns `steam-<appid>.log`.
    public func gameLog(appID: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "steam-\(appID).log")
    }

    /// Appends a timestamped line, rotating to `launcher.log.1` past `rotateBytes`.
    /// Never throws: a logging problem must not stop a game from launching.
    public func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = launcherLog.path(percentEncoded: false)
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue > Self.rotateBytes {
            let rotated = directory.appending(path: "launcher.log.1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: launcherLog, to: rotated)
        }
        let data = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: launcherLog) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: launcherLog)
        }
    }
}
