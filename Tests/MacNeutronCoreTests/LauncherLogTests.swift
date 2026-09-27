import Foundation
import Testing
@testable import MacNeutronCore

@Test func appendsTimestampedLines() throws {
    let log = LauncherLog(directory: try makeTempDir().appending(path: "Logs"))
    log.append("verb=run exit=0")
    log.append("verb=run exit=1")
    let lines = try String(contentsOf: log.launcherLog, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[1].hasSuffix(" verb=run exit=1"))
    #expect(lines[0].hasPrefix("20"))
}

@Test func rotatesPastOneMegabyte() throws {
    let log = LauncherLog(directory: try makeTempDir())
    try Data(count: LauncherLog.rotateBytes + 1).write(to: log.launcherLog)
    log.append("fresh")
    let rotated = log.directory.appending(path: "launcher.log.1")
    #expect(FileManager.default.fileExists(atPath: rotated.path(percentEncoded: false)))
    #expect(try String(contentsOf: log.launcherLog, encoding: .utf8).hasSuffix(" fresh\n"))
}

@Test func gameLogIsPerApp() throws {
    let log = LauncherLog(directory: try makeTempDir().appending(path: "Logs"))
    #expect(log.gameLog(appID: "42").lastPathComponent == "steam-42.log")
    #expect(FileManager.default.fileExists(atPath: log.directory.path(percentEncoded: false)))
}
