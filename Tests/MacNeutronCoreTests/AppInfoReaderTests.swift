import Foundation
import Testing
@testable import MacNeutronCore

@Test func readsNameTypeAndPlatforms() throws {
    let apps = [
        AppInfo(appID: 1062090, name: "Timberborn", type: "game", oslist: ["windows", "macos"]),
        AppInfo(appID: 2977660, name: "Cats", type: "game", oslist: ["windows"]),
        AppInfo(appID: 1628350, name: "Steam Linux Runtime", type: "tool", oslist: ["linux"]),
    ]
    #expect(try AppInfoReader.parse(makeAppInfoV29(apps)) == apps)
}

@Test func rejectsOtherFormats() {
    #expect(throws: AppInfoError.unsupportedFormat(0x0756_4428)) {
        try AppInfoReader.parse(makeAppInfoV29([], magic: 0x0756_4428))
    }
}

@Test func rejectsTruncatedFiles() {
    let data = makeAppInfoV29([AppInfo(appID: 1, name: "A", type: "game", oslist: ["windows"])])
    #expect(throws: AppInfoError.self) { try AppInfoReader.parse(data.prefix(40)) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACNEUTRON_REAL_STEAM"] == "1"))
func readsTheRealAppCache() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Steam/appcache/appinfo.vdf")
    let timberborn = try AppInfoReader.read(url).first { $0.appID == 1062090 }
    #expect(timberborn?.oslist == ["windows", "macos"])
    #expect(timberborn?.type == "game")
}

@Test func readingWhileSteamRewritesTheFileNeverCrashes() throws {
    // Seen in acceptance: a memory-mapped read died with SIGBUS when the file shrank mid-parse. Steam
    // rewrites appinfo.vdf on exit, exactly when the app refreshes. A short read may fail; it must not crash.
    let apps = (0..<3000).map { AppInfo(appID: UInt32($0 + 1), name: "Game \($0)", type: "game", oslist: ["windows"]) }
    let big = makeAppInfoV29(apps)
    let url = try makeTempDir().appending(path: "appinfo.vdf")
    try big.write(to: url)
    let deadline = Date().addingTimeInterval(1)
    let writer = Thread {
        while Date() < deadline {
            try? big.prefix(64).write(to: url)  // truncates in place, as a non-atomic writer does
            try? big.write(to: url)
        }
    }
    writer.start()
    while Date() < deadline { _ = try? AppInfoReader.read(url) }
}
