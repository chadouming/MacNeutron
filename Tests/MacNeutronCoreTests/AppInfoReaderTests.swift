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
