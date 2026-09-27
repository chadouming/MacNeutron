import Foundation
import Testing
@testable import MacNeutronCore

@Test func findsLibrariesAndInstalledApps() throws {
    let (steam, _) = try makeFakeSteam()
    let extra = try makeTempDir().appending(path: "Games Drive", directoryHint: .isDirectory)
    try write("""
        "libraryfolders"
        {
        \t"0"
        {
        \t\t"path"\t\t"\(steam.root.path(percentEncoded: false))"
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"\(extra.path(percentEncoded: false))"
        \t}
        }
        """, to: steam.root.appending(path: "steamapps/libraryfolders.vdf"))
    try write("", to: steam.root.appending(path: "steamapps/appmanifest_1062090.acf"))
    try write("", to: extra.appending(path: "steamapps/appmanifest_2977660.acf"))
    #expect(steam.libraries().count == 2)
    #expect(steam.installedAppIDs() == [1062090, 2977660])
}
