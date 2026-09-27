import Foundation
import Testing
@testable import MacNeutronCore

@Test func listsOnlyPrefixesOfUninstalledGames() throws {
    let (steam, _) = try makeFakeSteam()
    let compatdata = steam.root.appending(path: "steamapps/compatdata")
    try write("installed", to: compatdata.appending(path: "1062090/pfx/system.reg"))
    try write("appmanifest", to: steam.root.appending(path: "steamapps/appmanifest_1062090.acf"))
    try write(String(repeating: "x", count: 10_000), to: compatdata.appending(path: "2977660/pfx/drive_c/big.bin"))
    try write("shared", to: compatdata.appending(path: "0/pfx/x"))
    let orphans = OrphanPrefixes.find(in: steam)
    #expect(orphans.map(\.appID) == ["2977660"])
    #expect(orphans[0].bytes >= 10_000)
    try OrphanPrefixes.delete(orphans)
    #expect(OrphanPrefixes.find(in: steam).isEmpty)
    #expect(FileManager.default.fileExists(atPath: compatdata.appending(path: "1062090").path(percentEncoded: false)))
}
